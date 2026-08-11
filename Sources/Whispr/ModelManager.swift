import Foundation
import WhisperKit

/// Tracks the selected Whisper model and ensures it is downloaded locally.
/// Downloads are cached by WhisperKit, so `ensureDownloaded` is idempotent across launches.
@MainActor
final class ModelManager {
    static let defaultModel = "large-v3-v20240930_turbo"

    /// Offered in the Models pane. Smaller = faster download / lower RAM / lower accuracy.
    static let available = [
        "large-v3-v20240930_turbo", // ~1.5 GB, best accuracy/speed on Apple Silicon
        "large-v3",                 // full large-v3, no turbo distillation — best for Hindi/Hinglish
        "large-v3-v20240930_626MB", // compressed large
        "medium",                   // ~1.5 GB; best translate quality on shelf (use for Hindi→English)
        "small",
        "base",
        "tiny",
    ]

    /// Languages where the turbo distillation costs real accuracy and full `large-v3` is worth
    /// its extra download. Turbo drops ~6.6 WER points on Hindi (FLEURS: 15.7% vs 22.3%),
    /// because distillation hurts lower-resource languages far more than English.
    static let largeV3Languages: Set<String> = ["hi", "bn", "ta", "te", "mr", "gu", "kn", "ml", "pa", "ur"]

    /// A nudge for the Models pane when the chosen language is one the default model handles badly.
    /// Returns nil when the current pairing is already sensible.
    static func recommendation(language: String, selected: String) -> String? {
        guard largeV3Languages.contains(language) else { return nil }
        guard selected != "large-v3", selected != "medium" else { return nil }
        return "For \(Languages.name(for: language)), pick large-v3 — the default turbo model is a distillation and loses noticeable accuracy on non-European languages."
    }

    private let key = "selectedModel"

    var selectedModel: String {
        get { UserDefaults.standard.string(forKey: key) ?? Self.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Download the model if not already cached. `progress` reports 0.0…1.0 on the main actor.
    /// Returns the local model folder to hand to `Transcriber.load`.
    func ensureDownloaded(_ model: String, progress: @escaping (Double) -> Void) async throws -> URL {
        try await WhisperKit.download(variant: model, progressCallback: { p in
            Task { @MainActor in progress(p.fractionCompleted) }
        })
    }
}
