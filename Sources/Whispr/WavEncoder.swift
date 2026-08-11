import Foundation

/// Encode 16 kHz mono Float32 samples to a 16-bit PCM WAV file.
/// Used for debug dumps and the --record-test gate.
enum WavEncoder {
    static func encode(_ samples: [Float], sampleRate: Int = 16000) -> Data {
        let numChannels = 1
        let bitsPerSample = 16
        let blockAlign = numChannels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = samples.count * blockAlign

        var data = Data(capacity: 44 + dataSize)
        func str(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(numChannels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        str("data"); u32(UInt32(dataSize))
        for f in samples {
            let clamped = max(-1.0, min(1.0, f))
            u16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }

    /// Decode a 16 kHz mono 16-bit PCM WAV (our own encode format) back to floats — test helper.
    static func decode16kMono(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count > 44 else { return [] }
        let pcm = data.dropFirst(44)
        var out: [Float] = []
        out.reserveCapacity(pcm.count / 2)
        var i = pcm.startIndex
        while i + 1 < pcm.endIndex {
            let v = Int16(littleEndian: Int16(bitPattern: UInt16(pcm[i]) | (UInt16(pcm[i + 1]) << 8)))
            out.append(Float(v) / 32767)
            i += 2
        }
        return out
    }

    /// Appends 16 kHz mono samples to a WAV on disk as a meeting runs, so the raw audio
    /// survives a bad transcription and can be re-run through `--transcribe-file`. Writes a
    /// placeholder header up front and patches the two size fields on close; a crash therefore
    /// leaves a file whose header understates its length rather than an unreadable one.
    final class Writer {
        private let handle: FileHandle
        private let url: URL
        private(set) var samplesWritten = 0

        init(url: URL) throws {
            self.url = url
            try WavEncoder.encode([]).write(to: url)   // 44-byte header, zero data
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        }

        func append(_ samples: [Float]) {
            guard !samples.isEmpty else { return }
            let pcm = WavEncoder.encode(samples).dropFirst(44)
            do {
                try handle.write(contentsOf: pcm)
                samplesWritten += samples.count
            } catch {
                Log.audio.error("wav writer append failed for \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        /// Patch RIFF size (offset 4) and data size (offset 40), then close.
        func close() {
            let dataSize = UInt32(samplesWritten * 2)
            func le(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
            do {
                try handle.seek(toOffset: 4);  try handle.write(contentsOf: le(36 + dataSize))
                try handle.seek(toOffset: 40); try handle.write(contentsOf: le(dataSize))
                try handle.close()
            } catch {
                Log.audio.error("wav writer close failed for \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Assert-based self-check (ponytail: one runnable check for the money/parse path).
    static func selfTest() {
        let wav = encode([0, 0.5, -0.5, 1.0, -1.0], sampleRate: 16000)
        precondition(wav.count == 44 + 5 * 2, "header+data size wrong: \(wav.count)")
        precondition(Array(wav[0..<4]) == Array("RIFF".utf8), "missing RIFF")
        precondition(Array(wav[8..<12]) == Array("WAVE".utf8), "missing WAVE")
        // sampleRate field at offset 24, little-endian == 16000
        let sr = UInt32(wav[24]) | UInt32(wav[25]) << 8 | UInt32(wav[26]) << 16 | UInt32(wav[27]) << 24
        precondition(sr == 16000, "sampleRate wrong: \(sr)")

        // Writer round-trip: appended chunks must decode back to the same samples, which is
        // what makes an offline re-transcription of a bad meeting trustworthy.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openwispr-wavwriter-selftest.wav")
        let first: [Float] = [0, 0.25, -0.25]
        let second: [Float] = [0.5, -0.5]
        do {
            let w = try Writer(url: tmp)
            w.append(first)
            w.append(second)
            w.close()
            let back = try decode16kMono(path: tmp.path)
            precondition(back.count == first.count + second.count,
                         "writer round-trip length \(back.count) != \(first.count + second.count)")
            for (i, want) in (first + second).enumerated() {
                precondition(abs(back[i] - want) < 0.001, "writer sample \(i): \(back[i]) != \(want)")
            }
            let size = try Data(contentsOf: tmp).count
            precondition(size == 44 + (first.count + second.count) * 2, "writer file size wrong: \(size)")
            try? FileManager.default.removeItem(at: tmp)
        } catch {
            preconditionFailure("WavEncoder.Writer selfTest threw: \(error)")
        }
        print("WavEncoder.selfTest PASS")
    }
}
