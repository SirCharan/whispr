import AVFoundation

/// Thread-safe sample buffer that resamples incoming PCM to 16 kHz mono Float32
/// (Whisper's input format). Shared by the mic and system-audio recorders — the
/// converter feed dance lives in exactly one place.
final class ResamplingBuffer {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    /// Arrival diagnostics. A stream that starts but delivers nothing used to be
    /// indistinguishable from a silent room; these counters make the difference visible.
    struct Diagnostics {
        var appends = 0
        var convertFailures = 0
        var firstAppend: Date?
        var lastFormat: String?
    }
    private var diag = Diagnostics()
    /// Label used in log lines ("mic" / "others") so two streams are tellable apart.
    var label = "audio"

    var diagnostics: Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return diag
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        diag = Diagnostics()
        lock.unlock()
    }

    /// Convert and append one PCM buffer (any input format; converter renews on format change).
    func append(_ pcm: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != pcm.format {
            let made = AVAudioConverter(from: pcm.format, to: Self.targetFormat)
            // AVAudioConverter cannot downmix MORE THAN TWO channels to mono: it reports no
            // error and writes digital silence. The MacBook Air's built-in mic is a 3-channel
            // beamforming array, so every mic sample became zeros — measured raw channels at
            // ~0.011 RMS while the converted mono output was exactly 0.000000. An explicit
            // channel map restores it. Stereo (2ch) downmix works correctly and is left alone,
            // because averaging L+R beats picking one side on the system-audio stream.
            // ponytail: takes the first mic; average all channels if SNR ever matters.
            if pcm.format.channelCount > 2 {
                made?.channelMap = [0]
            }
            converter = made
            let desc = "\(pcm.format.sampleRate)Hz \(pcm.format.channelCount)ch"
            lock.lock(); diag.lastFormat = desc; lock.unlock()
            Log.audio.info("""
                \(self.label, privacy: .public): negotiated input format \(desc, privacy: .public)\
                \(pcm.format.channelCount > 2 ? " (channelMap=[0] — multichannel downmix workaround)" : "", privacy: .public)
                """)
        }
        guard let converter else {
            countFailure("converter init failed")
            return
        }
        let ratio = Self.targetFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            countFailure("output buffer alloc failed")
            return
        }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        if let error {
            countFailure("convert failed: \(error.localizedDescription)")
            return
        }
        guard let ch = out.floatChannelData else {
            countFailure("no float channel data")
            return
        }
        let n = Int(out.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
        diag.appends += 1
        let isFirst = diag.firstAppend == nil
        if isFirst { diag.firstAppend = Date() }
        lock.unlock()
        if isFirst {
            Log.audio.info("\(self.label, privacy: .public): first buffer arrived (\(n) frames)")
        }
    }

    private func countFailure(_ reason: String) {
        lock.lock(); diag.convertFailures += 1; let n = diag.convertFailures; lock.unlock()
        Log.audio.error("\(self.label, privacy: .public): dropped buffer (\(reason, privacy: .public)) — total \(n)")
    }

    /// All samples so far, leaving the buffer intact.
    func snapshot(last seconds: Double? = nil) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard let seconds else { return samples }
        let n = min(samples.count, Int(seconds * 16000))
        return Array(samples.suffix(n))
    }

    /// Take everything and clear (for chunked live transcription).
    func drain() -> [Float] {
        lock.lock(); let out = samples; samples.removeAll(keepingCapacity: true); lock.unlock()
        return out
    }

    var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16000
    }

    /// RMS of the trailing `seconds` — low value = the speaker paused.
    func tailRMS(_ seconds: Double) -> Float {
        lock.lock(); defer { lock.unlock() }
        let n = min(samples.count, Int(seconds * 16000))
        guard n > 0 else { return 0 }
        return Self.rms(samples.suffix(n))
    }

    // MARK: - Level math (one copy; was inlined in four places)

    static func rms<S: Sequence>(_ s: S) -> Float where S.Element == Float {
        var sum: Float = 0
        var n = 0
        for v in s { sum += v * v; n += 1 }
        guard n > 0 else { return 0 }
        return sqrt(sum / Float(n))
    }

    /// Guards the gate that was silently deleting speech. The case that matters is a short
    /// burst of quiet speech inside a long silence: its chunk mean falls under the old
    /// `0.002` floor while its loudest window stays well above it.
    static func selfTest() {
        let sr = 16000
        var chunk = [Float](repeating: 0, count: sr * 30)   // 30 s of silence
        for i in 0..<(sr * 4) {                            // 4 s of quiet speech at the front
            chunk[i] = 0.006 * sin(Float(i) * 0.1)
        }
        let mean = rms(chunk)
        let peak = maxWindowRMS(chunk)
        precondition(mean < 0.002, "mean RMS \(mean) should fall below the old floor")
        precondition(peak > 0.0035, "peak window RMS \(peak) should clear the speech floor")
        precondition(peak > mean, "peak must exceed mean")

        precondition(rms([Float]()) == 0, "empty rms should be 0")
        precondition(maxWindowRMS([Float]()) == 0, "empty peak should be 0")
        precondition(maxWindowRMS([Float](repeating: 0, count: sr)) == 0, "silence peak should be 0")

        let steady = [Float](repeating: 0.5, count: sr * 3)
        precondition(abs(maxWindowRMS(steady) - 0.5) < 0.001, "steady tone peak should equal its level")
        print("ResamplingBuffer.selfTest PASS")
    }

    /// Loudest `window`-sample slice, as RMS.
    ///
    /// Mean RMS over a whole chunk is the wrong measure for a speech gate: four seconds of
    /// quiet remote speech inside twenty-six seconds of room silence averages below any useful
    /// threshold, which is exactly how the old `rms > 0.002` guard silently discarded real
    /// speech. The loudest window survives that dilution.
    static func maxWindowRMS(_ s: [Float], window: Int = 8000) -> Float {
        guard !s.isEmpty else { return 0 }
        guard s.count > window, window > 0 else { return rms(s) }
        var best: Float = 0
        var i = 0
        while i < s.count {
            let end = min(i + window, s.count)
            best = max(best, rms(s[i..<end]))
            i = end
        }
        return best
    }
}
