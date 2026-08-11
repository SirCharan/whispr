import AppKit

@main
enum Whispr {
    static func main() {
        let args = CommandLine.arguments

        // --- headless gates (loop engineering) ---
        if args.contains("--selftest") {
            // A failed check trips a precondition, which traps. Buffered stdout would be lost
            // with it, leaving CI with an exit code and no idea which check failed.
            setvbuf(stdout, nil, _IONBF, 0)
            WavEncoder.selfTest()
            ResamplingBuffer.selfTest()
            OutputSilencer.selfTest()
            TextProcessor.selfTest()
            DictionaryStore.selfTest()
            SnippetStore.selfTest()
            Stats.selfTest()
            Transliterate.selfTest()
            Task { @MainActor in
                CorrectionsWatcher.selfTest()
                AXEditWatcher.selfTest()
                Diarizer.selfTest()
                MeetingController.selfTest()
                OnboardingModel.selfTest()
                exit(0)
            }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--record-test"), i + 2 < args.count {
            let seconds = Double(args[i + 1]) ?? 3
            let path = args[i + 2]
            runRecordTest(seconds: seconds, path: path)
            exit(0)
        }
        if let i = args.firstIndex(of: "--transcribe-file"), i + 1 < args.count {
            runTranscribeFile(path: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--sysaudio-test"), i + 1 < args.count {
            runSysAudioTest(seconds: Double(args[i + 1]) ?? 5)
            exit(0)
        }
        if let i = args.firstIndex(of: "--concurrency-test"), i + 1 < args.count {
            runConcurrencyTest(path: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--diarize-test"), i + 1 < args.count {
            runDiarizeTest(path: args[i + 1])
            exit(0)
        }
        if args.contains("--mute-test") {
            runMuteTest()
            exit(0)
        }

        // --- single-instance guard: two copies = two fn monitors = every transcript pasted twice ---
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let myID = Bundle.main.bundleIdentifier {
            let twins = NSRunningApplication.runningApplications(withBundleIdentifier: myID)
                .filter { $0.processIdentifier != myPID }
            if let existing = twins.first {
                // tell the running copy to show its home window (activate alone shows nothing
                // for a menu-bar app whose window is closed), then bow out
                DistributedNotificationCenter.default().postNotificationName(
                    .init("org.openwispr.showHome"), object: nil, userInfo: nil, deliverImmediately: true
                )
                existing.activate()
                exit(0)
            }
        }
        // terminate any legacy Whispr-era instance (old bundle id) — same double-paste hazard
        for legacy in NSRunningApplication.runningApplications(withBundleIdentifier: "com.ck.whispr") {
            legacy.terminate()
        }

        // --- normal menu-bar app ---
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // menu-bar-only; pairs with LSUIElement
        Theme.apply()
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// Record `seconds` from the mic, write a WAV to `path`, print sample count + RMS.
    /// Proves the AVAudioEngine → 16 kHz pipeline without the hotkey/GUI.
    private static func runRecordTest(seconds: Double, path: String) {
        let rec = AudioRecorder()
        do {
            try rec.start()
        } catch {
            print("record-test FAIL: \(error)")
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let diag = rec.diagnostics
        let samples = rec.stop()
        let rms = ResamplingBuffer.rms(samples)
        let peak = ResamplingBuffer.maxWindowRMS(samples)
        let wav = WavEncoder.encode(samples)
        try? wav.write(to: URL(fileURLWithPath: path))
        print("""
            record-test: samples=\(samples.count) (~\(String(format: "%.1f", Double(samples.count) / 16000))s) \
            meanRMS=\(String(format: "%.4f", rms)) peakRMS=\(String(format: "%.4f", peak)) \
            buffers=\(diag.appends) dropped=\(diag.convertFailures) \
            format=\(diag.lastFormat ?? "none") wrote=\(path)
            """)
        if diag.appends == 0 { print("record-test WARN: no audio buffers ever arrived from the mic") }
    }

    /// Capture system audio for N seconds and report sample count + RMS.
    /// Proves the ScreenCaptureKit tap without the GUI. Requires Screen Recording permission.
    private static func runSysAudioTest(seconds: Double) {
        Task { @MainActor in
            let rec = SystemAudioRecorder()
            do {
                try await rec.start()
            } catch {
                print("sysaudio-test FAIL: \(error)")
                exit(1)
            }
            try? await Task.sleep(for: .seconds(seconds))
            let diag = rec.diagnostics
            let samples = await rec.stop()
            let rms = ResamplingBuffer.rms(samples)
            let peak = ResamplingBuffer.maxWindowRMS(samples)
            print("""
                sysaudio-test: samples=\(samples.count) (~\(String(format: "%.1f", Double(samples.count) / 16000))s) \
                meanRMS=\(String(format: "%.4f", rms)) peakRMS=\(String(format: "%.4f", peak)) \
                buffers=\(diag.appends) dropped=\(diag.convertFailures) format=\(diag.lastFormat ?? "none")
                """)
            if diag.appends == 0 {
                print("sysaudio-test WARN: stream started but delivered no audio — check Screen Recording permission")
            }
            exit(0)
        }
        dispatchMain()
    }

    /// Two overlapping transcriptions through ONE Transcriber — proves actor serialization
    /// (pre-actor this was the crash/garble class the audit flagged).
    private static func runConcurrencyTest(path: String) {
        Task { @MainActor in
            let mm = ModelManager()
            let t = Transcriber()
            do {
                let folder = try await mm.ensureDownloaded(mm.selectedModel) { _ in }
                try await t.load(model: mm.selectedModel, folder: folder)
                async let a = t.transcribeFile(path)
                async let b = t.transcribeFile(path)
                let (ra, rb) = try await (a, b)
                let ok = !ra.isEmpty && ra == rb
                print(ok ? "concurrency-test PASS: \"\(ra)\"" : "concurrency-test FAIL: \"\(ra)\" vs \"\(rb)\"")
            } catch {
                print("concurrency-test FAIL: \(error)")
            }
            exit(0)
        }
        dispatchMain()
    }

    /// Download diarizer models + diarize a wav — proves the whole FluidAudio path headlessly.
    private static func runDiarizeTest(path: String) {
        Task { @MainActor in
            do {
                let samples = try WavEncoder.decode16kMono(path: path)
                let d = Diarizer()
                print("diarize-test: preparing models…")
                try await d.prepare()
                let segs = try await d.diarize(samples)
                let speakers = Set(segs.map(\.speaker)).sorted()
                print("diarize-test: \(segs.count) segments, speakers=\(speakers)")
                for s in segs.prefix(10) {
                    print("  \(s.speaker) \(String(format: "%.1f–%.1f", s.start, s.end))s")
                }
            } catch {
                print("diarize-test FAIL: \(error)")
            }
            exit(0)
        }
        dispatchMain()
    }

    /// Exercise the real CoreAudio mute path and verify it restores. Prints every step, so a
    /// device that acknowledges a write and ignores it is visible here rather than after the
    /// user has been left with a silent Mac.
    private static func runMuteTest() {
        guard let device = OutputAudio.defaultOutputDevice() else {
            print("mute-test FAIL: no default output device")
            return
        }
        let supported = OutputAudio.muteSupported(device)
        let startedMuted = OutputAudio.isMuted(device)
        let startVolume = OutputAudio.volume(device)
        print("""
            mute-test: device=\(device) muteSupported=\(supported) \
            alreadyMuted=\(startedMuted) volume=\(startVolume.map { String(format: "%.2f", $0) } ?? "n/a") \
            playing=\(OutputAudio.isRunningSomewhere(device))
            """)
        if startedMuted {
            print("mute-test SKIP: device is already muted — unmute it and re-run")
            return
        }

        var ok = true
        if supported {
            OutputAudio.setMute(device, true)
            let muted = OutputAudio.isMuted(device)
            print("mute-test: after setMute(true) isMuted=\(muted)")
            if !muted { ok = false; print("mute-test WARN: device ignored the mute write") }
            OutputAudio.setMute(device, false)
            let restored = !OutputAudio.isMuted(device)
            print("mute-test: after setMute(false) isMuted=\(!restored)")
            if !restored { ok = false; print("mute-test WARN: device did not unmute") }
        } else {
            guard let start = startVolume else {
                print("mute-test FAIL: no mute and no volume property — nothing to drive")
                return
            }
            OutputAudio.setVolume(device, 0)
            let zeroed = (OutputAudio.volume(device) ?? 1) <= 0.01
            print("mute-test: after setVolume(0) zeroed=\(zeroed)")
            OutputAudio.setVolume(device, start)
            let back = OutputAudio.volume(device) ?? -1
            print("mute-test: volume restored to \(String(format: "%.2f", back)) (was \(String(format: "%.2f", start)))")
            if !zeroed || abs(back - start) > 0.02 { ok = false }
        }
        print(ok ? "mute-test PASS" : "mute-test FAIL")
    }

    /// Value of a `--flag value` pair anywhere in the argument list.
    private static func flagValue(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        return v.hasPrefix("--") ? nil : v
    }

    /// Load a model (cached) and transcribe an audio file. Proves the full ASR path.
    ///
    /// `--model` and `--lang` override the saved settings, which is what makes a model A/B on
    /// the same recording possible — the only way to settle whether turbo costs real accuracy
    /// on a given language, since published per-language numbers for the distilled model are
    /// scarce and inconsistent:
    ///
    ///   --transcribe-file clip.wav --model large-v3-v20240930_turbo --lang hi
    ///   --transcribe-file clip.wav --model large-v3 --lang hi
    ///
    /// Drives the main queue via `dispatchMain()` so the @MainActor work runs (never block main with a semaphore).
    private static func runTranscribeFile(path: String) {
        Task { @MainActor in
            let mm = ModelManager()
            let model = flagValue("--model") ?? mm.selectedModel
            let language = flagValue("--lang") ?? Settings.languageCode
            let transcriber = Transcriber()
            do {
                let started = Date()
                let folder = try await mm.ensureDownloaded(model) { _ in }
                let loaded = Date()
                try await transcriber.load(model: model, folder: folder)
                var text = try await transcriber.transcribeFile(path, language: language)
                if Settings.outputMode == "roman" { text = Transliterate.toLatin(text) }
                let elapsed = Date().timeIntervalSince(loaded)
                print("""
                    transcribe-file: model=\(model) lang=\(language ?? "auto") \
                    load=\(String(format: "%.1f", loaded.timeIntervalSince(started)))s \
                    transcribe=\(String(format: "%.1f", elapsed))s
                    "\(text)"
                    """)
            } catch {
                print("transcribe-file FAIL (model=\(model)): \(error)")
            }
            exit(0)
        }
        dispatchMain()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AppController()
        controller?.start()
    }

    /// Finder double-click / `open` on the running instance: show the home window.
    /// Without this, clicking a menu-bar-only app in /Applications appears to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showMainWindow()
        return true
    }

    /// Quitting while dictating must not leave the output device muted.
    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
