import ScreenCaptureKit
import AVFoundation

enum SystemAudioError: Error { case noDisplay }

/// Captures system-output audio (the "Others" side of a meeting) via ScreenCaptureKit
/// into a shared ResamplingBuffer. Requires the Screen Recording TCC permission
/// (audio ride-along; video frames are discarded).
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let buffer = ResamplingBuffer()
    private(set) var isRecording = false

    override init() {
        super.init()
        buffer.label = "others"
    }

    /// Buffer-arrival counters, for the CLI gates and for diagnosing a dead stream.
    var diagnostics: ResamplingBuffer.Diagnostics { buffer.diagnostics }
    /// Fired if the OS tears the stream down mid-meeting (permission revoked, display change).
    /// Lets MeetingController surface it instead of silently freezing "Others".
    var onUnexpectedStop: (@Sendable () -> Void)?

    func start() async throws {
        buffer.reset()
        try await begin()
    }

    /// Re-open the stream after the OS tore it down, KEEPING whatever is already buffered.
    /// A display change or a sleep/wake used to end the "Others" side of a meeting permanently.
    func restart() async throws {
        try? await stream?.stopCapture()
        stream = nil
        try await begin()
    }

    private func begin() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Ask explicitly instead of inheriting defaults. queueDepth defaulted to 3, which drops
        // audio buffers whenever the handler queue falls behind — invisible sample loss.
        config.sampleRate = 48000
        config.channelCount = 2
        config.queueDepth = 8
        // minimal video so the stream runs; frames are ignored
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "whispr.sysaudio"))
        try await stream.startCapture()
        self.stream = stream
        isRecording = true
        Log.audio.info("others: SCStream started (48000Hz 2ch, queueDepth 8)")
    }

    /// Stop and return all captured 16 kHz mono samples.
    func stop() async -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        try? await stream?.stopCapture()
        stream = nil
        return buffer.snapshot()
    }

    /// Take buffered samples and clear (live chunked transcription).
    func drain() -> [Float] { buffer.drain() }

    var bufferedSeconds: Double { buffer.bufferedSeconds }
    func tailRMS(_ seconds: Double) -> Float { buffer.tailRMS(seconds) }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        buffer.append(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasRecording = isRecording
        Log.audio.error("""
            others: SCStream stopped mid-capture=\(wasRecording, privacy: .public) \
            error=\(error.localizedDescription, privacy: .public) \
            buffersReceived=\(self.buffer.diagnostics.appends, privacy: .public)
            """)
        isRecording = false
        if wasRecording { onUnexpectedStop?() } // only if it died mid-capture, not on normal stop()
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else {
            Log.audio.error("others: sample buffer has no usable format description")
            return nil
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            Log.audio.error("others: PCM buffer alloc failed for \(frames) frames")
            return nil
        }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList
        )
        if status != noErr {
            Log.audio.error("others: CMSampleBufferCopyPCMData failed status=\(status, privacy: .public)")
            return nil
        }
        return buf
    }
}
