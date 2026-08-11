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

    // Why `large-v3` is offered but NOT recommended by the UI:
    //
    // The theory says turbo should be worse on lower-resource languages — it cuts the decoder
    // from 32 layers to 4 (OpenAI model card), OpenAI's announcement rates it "similarly to
    // large-v2" across languages and names Thai and Cantonese as degraded, and large-v3 is
    // 10–20% relatively better than large-v2 on Common Voice 15 / FLEURS. One blog benchmark
    // put Hindi at 15.7% (large-v3) vs 22.3% (turbo).
    //
    // Measured 2026-08-11 on a synthetic Hinglish clip, same audio through both models:
    //   turbo     "हम अगले हफ्ते प्राम्प्स अपडेट करेंगे और डाशबॉर्ड पे डिपलॉय कर देंगे, मार्केटिंग प्रेशर भी है."
    //   large-v3  "हम अगले हफते प्राम्प्स अपडेट करेंगे और डाशबॉर्ड पे डिप्लॉय कर देंगे, मार्कटिंग प्रेशर भी है."
    // Turbo was right on हफ्ते and मार्केटिंग, large-v3 on डिप्लॉय — turbo 2, large-v3 1, and turbo
    // was 45s faster. Clean TTS is the easy case, so this fails to reproduce the penalty rather
    // than disproving it. Until it reproduces on real meeting audio, the app does not push a
    // 1.5 GB download at anyone. A/B it yourself:
    //   --transcribe-file clip.wav --model large-v3-v20240930_turbo --lang hi
    //   --transcribe-file clip.wav --model large-v3 --lang hi

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
