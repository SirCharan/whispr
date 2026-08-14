import Foundation

/// Thin UserDefaults-backed preferences. Single source for keys used by @AppStorage bindings.
enum Settings {
    /// Auto-paste transcript at the cursor (Cmd+V). If false, text is left on the clipboard only.
    static var autoPaste: Bool {
        get { UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPaste") }
    }

    /// First-run onboarding completed. When false, the wizard shows on launch.
    static var onboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "onboarded") }
    }

    /// The Snippets coach-mark has been seen. Shown once under the sidebar row, because a user
    /// who never opens the tab otherwise never learns snippets exist.
    static var snippetsTipSeen: Bool {
        get { UserDefaults.standard.bool(forKey: "snippetsTipSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "snippetsTipSeen") }
    }

    /// Separate remote meeting voices into Speaker A/B via on-device diarization.
    static var diarizationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "diarizationEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "diarizationEnabled") }
    }

    /// Silence other audio while dictating, then put it back. Dictation only — meetings never
    /// touch the output, because the remote party's audio IS the system output we capture.
    static var muteWhileDictating: Bool {
        get { UserDefaults.standard.object(forKey: "muteWhileDictating") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "muteWhileDictating") }
    }

    /// How to silence: "mute" the output device (default, deterministic) or "pause" whatever is
    /// playing via the play/pause media key (keeps your place, but it is a blind toggle).
    static var muteMode: String {
        get { UserDefaults.standard.string(forKey: "muteMode") ?? "mute" }
        set { UserDefaults.standard.set(newValue, forKey: "muteMode") }
    }

    /// Days to keep the raw meeting audio (16 kHz mono WAV, ~115 MB/hour/stream) so a bad
    /// transcript can be re-run offline. 0 disables retention entirely.
    static var meetingAudioRetentionDays: Int {
        get { UserDefaults.standard.object(forKey: "meetingAudioRetentionDays") as? Int ?? 7 }
        set { UserDefaults.standard.set(newValue, forKey: "meetingAudioRetentionDays") }
    }

    /// Loudest-half-second RMS a meeting chunk must reach before it is sent to Whisper.
    ///
    /// Measured on the 19-minute meeting of 11 Aug 2026 (39 chunks per stream): room tone plus
    /// speaker bleed peaks at 0.0029–0.0093, while real speech peaks at 0.059–0.200 on the mic
    /// and above 0.020 on the system stream. Nothing lands in between. The old 0.0035 floor sat
    /// inside the noise band, so 97% of chunks reached Whisper and the silent ones came back as
    /// "Thank you." / "Gracias." — Whisper fills near-silence with training-set filler.
    ///
    /// One meeting is one room and one mic gain, so this is a knob, not a law:
    /// `defaults write org.openwispr.app meetingSpeechFloor -float 0.008` to loosen it.
    static var meetingSpeechFloor: Double {
        get { UserDefaults.standard.object(forKey: "meetingSpeechFloor") as? Double ?? 0.015 }
        set { UserDefaults.standard.set(newValue, forKey: "meetingSpeechFloor") }
    }

    /// Show the small persistent floating mic pill (click to dictate).
    static var showIdleWidget: Bool {
        get { UserDefaults.standard.object(forKey: "showIdleWidget") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showIdleWidget") }
    }

    /// Play a short sound when recording starts/stops (useful when the pill is hidden).
    static var soundCues: Bool {
        get { UserDefaults.standard.object(forKey: "soundCues") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundCues") }
    }

    /// Bundle IDs of apps where Whispr dictation is disabled.
    static var disabledApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: "disabledApps") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "disabledApps") }
    }

    /// Output for non-English speech: "original" script · "roman" letters (Hinglish) · "translate" to English.
    static var outputMode: String {
        get { UserDefaults.standard.string(forKey: "outputMode") ?? "original" }
        set { UserDefaults.standard.set(newValue, forKey: "outputMode") }
    }

    /// Dictation language: "auto" (detect) or a WhisperKit code ("en", "es", …).
    static var language: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }
    static var languageCode: String? { language == "auto" ? nil : language }

    /// Dictation trigger: "fn" (default, hold the fn/🌐 key) or "custom" (KeyboardShortcuts recorder).
    static var hotkeyMode: String {
        get { UserDefaults.standard.string(forKey: "hotkeyMode") ?? "fn" }
        set { UserDefaults.standard.set(newValue, forKey: "hotkeyMode") }
    }


    /// Remove filler words (um/uh/er) from transcripts.
    static var removeFillers: Bool {
        get { UserDefaults.standard.object(forKey: "removeFillers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "removeFillers") }
    }

    /// Capitalize sentences + normalize spacing.
    static var cleanUp: Bool {
        get { UserDefaults.standard.object(forKey: "cleanUp") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cleanUp") }
    }

    static var textOptions: TextProcessor.Options {
        TextProcessor.Options(removeFillers: removeFillers, cleanUp: cleanUp)
    }

    /// AI rewrite applied after the text pipeline: "off", "clean", "formal", "concise".
    static var rewriteStyle: String {
        get { UserDefaults.standard.string(forKey: "rewriteStyle") ?? "off" }
        set { UserDefaults.standard.set(newValue, forKey: "rewriteStyle") }
    }
}
