import Foundation
import WhisperKit

enum TranscriberError: Error { case notLoaded }

/// Wraps a loaded WhisperKit pipeline. Load once, transcribe many times.
/// An actor: WhisperKit is NOT safe under concurrent inference (preview loop, dictation,
/// meeting chunks, and file import all share this instance) — actor isolation serializes them.
actor Transcriber {
    private var pipe: WhisperKit?
    private(set) var loadedModel: String?

    var isReady: Bool { pipe != nil }

    /// Load a model from an already-downloaded folder (no network).
    func load(model: String, folder: URL) async throws {
        let pipe = try await WhisperKit(
            modelFolder: folder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        self.pipe = pipe
        self.loadedModel = model
    }

    /// Dictation is a few seconds of one close voice; a meeting chunk is up to 30 s of
    /// possibly-quiet remote speech. The thresholds that suit the first discard the second.
    enum Preset { case dictation, meeting }

    /// Transcribe 16 kHz mono Float32 samples to plain text. `language` nil = auto-detect.
    func transcribe(_ samples: [Float], language: String? = nil, preset: Preset = .dictation) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: Self.options(language, preset))
        return Self.join(results)
    }

    /// Transcribe an audio file (WhisperKit resamples internally). Used by the headless gates and file import.
    func transcribeFile(_ path: String, language: String? = nil) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        let results = try await pipe.transcribe(audioPath: path, decodeOptions: Self.options(language, .meeting))
        return Self.join(results)
    }

    private static func options(_ language: String?, _ preset: Preset = .dictation) -> DecodingOptions {
        var opts = DecodingOptions()
        opts.language = language
        // `detectLanguage` defaults to `!usePrefillPrompt`, and usePrefillPrompt is true — so
        // "auto" (language == nil) was running with NO detection pass and no language token,
        // which is how an English meeting produced a line of Portuguese. Ask for it explicitly.
        opts.detectLanguage = (language == nil)
        // Whisper's built-in any-language → English translation
        if Settings.outputMode == "translate" { opts.task = .translate }

        if preset == .meeting {
            // 5 fallbacks on a 30 s chunk costs seconds of wall clock; 3 still breaks loops.
            opts.temperatureFallbackCount = 3
            // 2.4 rejects legitimately repetitive meeting speech ("correct, correct").
            opts.compressionRatioThreshold = 2.6
            // -1.0 discarded quiet remote speech as low-confidence — the "Others" side is
            // played through speakers and arrives far below mic level.
            opts.logProbThreshold = -1.2
            opts.noSpeechThreshold = 0.7
        }
        return opts
    }

    private static func join(_ results: [TranscriptionResult]) -> String {
        results.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
