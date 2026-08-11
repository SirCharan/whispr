import AppKit
import KeyboardShortcuts

/// Central wiring object: owns the menu bar, model, and transcriber, and runs the boot sequence.
/// Owns the dictation flow, onboarding, windows, and trigger monitors.
@MainActor
final class AppController {
    private lazy var menuBar = MenuBarController(
        onSettings: { [weak self] in self?.showSettings() },
        onMeeting: { [weak self] in self?.showMeeting() },
        onImport: { [weak self] in self?.showImport() },
        onOpen: { [weak self] in self?.showMainWindow() },
        onRetry: { [weak self] in self?.retryLastTranscription() }
    )
    let state = AppState()
    private let mainWindow = MainWindowController()
    private var fnMonitor: ModifierKeyMonitor?
    private lazy var meetingCtrl = MeetingController(transcriber: transcriber)
    private lazy var importModel = FileImportModel(transcriber: transcriber)
    private let corrections = CorrectionsWatcher()
    private let axWatcher = AXEditWatcher()
    /// Silences other audio for the duration of a dictation. Dictation only — never meetings.
    private let silencer = OutputSilencer()
    private var silencerWatchdog: Timer?
    private var previewTimer: Timer?
    private var previewBusy = false
    private var previewTask: Task<Void, Never>?
    /// Mirrors the actor's readiness for synchronous UI guards.
    private var modelReady = false
    /// Samples of the last dictation whose transcription failed — recoverable via "Retry".
    private var failedSamples: [Float]?
    /// Bundle id of the app being dictated into (captured at start, used for Insights per-app stats).
    private var dictatingInto: String?
    private let modelManager = ModelManager()
    private let transcriber = Transcriber()
    private let recorder = AudioRecorder()
    private var hotkeys: HotkeyManager?
    private let indicator = RecordingIndicator()
    private lazy var idleWidget = IdleWidget(onTap: { [weak self] in self?.startDictation() })
    private var onboarding: OnboardingWindowController?

    func start() {
        Stats.syncOnLaunch() // restore aggregates from Application Support after a defaults wipe
        Self.migrateFromWhisprIfNeeded()
        // A silence that outlived the last run (crash, force-quit) is undone here, before
        // anything else can decide the device was "already muted" and leave it that way.
        silencer.recoverAfterCrash()
        // Backstop for tap-mode sessions that never end: restore after the watchdog window.
        silencerWatchdog = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.silencer.expireIfStale(isRecording: self.recorder.isRecording)
            }
        }
        // Sleep is a quit we do not control: restore before the machine goes down.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.silencer.restore() }
        }
        NotificationCenter.default.addObserver(forName: .whisprHotkeyModeChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.modelReady else { return }
                self.attachHotkeys()
                self.setStatus("ready — tap or hold \(Self.hotkeyHint)")
                if Settings.showIdleWidget { self.idleWidget.show() } else { self.idleWidget.hide() }
            }
        }
        NotificationCenter.default.addObserver(forName: .whisprModelChanged, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let name = note.object as? String,
                      name != self.modelManager.selectedModel else { return }
                self.modelManager.selectedModel = name
                await self.loadSelectedModel()
            }
        }
        NotificationCenter.default.addObserver(forName: .whisprReloadModel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.loadSelectedModel() }
        }
        // toast suggested vocabulary → open the Dictionary pane with it staged, never write silently
        NotificationCenter.default.addObserver(forName: .whisprStageVocab, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.state.pane = .dictionary
                self?.showMainWindow()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // a second launch attempt (open -n) asks us to surface the home window before it exits
        DistributedNotificationCenter.default().addObserver(
            forName: .init("org.openwispr.showHome"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showMainWindow()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        if Settings.onboarded {
            showMainWindow()
            Task { await bootModel() }
        } else {
            showOnboarding()
        }
    }

    func showMainWindow() {
        // wizard closed mid-way? "Open OpenWispr" resumes it instead of dead-ending
        guard Settings.onboarded else {
            if let onboarding { onboarding.show() } else { showOnboarding() }
            return
        }
        mainWindow.show(state: state, meetingController: meetingCtrl, importModel: importModel)
    }

    private func bootModel() async {
        await loadSelectedModel()
        attachHotkeys()
        if Settings.autoPaste && !Permissions.hasAccessibility {
            Permissions.requestAccessibility() // one-time prompt so auto-paste works
        }
    }

    // MARK: - First-run onboarding

    private func showOnboarding() {
        setStatus("setup…")
        let vm = OnboardingModel()
        vm.onStartModel = { [weak self, weak vm] in
            Task { await self?.loadModelForOnboarding(vm) }
        }
        vm.onMoveToApplications = { Self.moveToApplicationsAndRelaunch() }
        vm.onPracticeStart = { [weak self, weak vm] in
            guard let self, let vm else { return }
            do {
                try self.recorder.start()
                vm.practice = .recording
            } catch {
                vm.practice = .result("(microphone error — check permission)")
            }
        }
        vm.onPracticeStop = { [weak self, weak vm] in
            guard let self, let vm else { return }
            let samples = self.recorder.stop()
            vm.practice = .transcribing
            Task {
                do {
                    let raw = try await self.transcriber.transcribe(samples, language: Settings.languageCode)
                    vm.practice = .result(TextProcessor.process(raw, options: Settings.textOptions))
                } catch {
                    vm.practice = .result("(transcription failed — you can still continue)")
                }
            }
        }
        vm.onFinish = { [weak self] in
            Settings.onboarded = true
            self?.attachHotkeys()
            self?.setStatus("ready — tap or hold \(Self.hotkeyHint)")
            self?.idleWidget.show() // first-run: pill appears now, not after the first dictation
            self?.onboarding?.close()
            self?.onboarding = nil
            self?.showMainWindow()
        }
        onboarding = OnboardingWindowController(model: vm)
        onboarding?.show()
    }

    private func loadModelForOnboarding(_ vm: OnboardingModel?) async {
        guard let vm else { return }
        let model = modelManager.selectedModel
        do {
            let folder = try await modelManager.ensureDownloaded(model) { frac in vm.downloadProgress = frac }
            try await transcriber.load(model: model, folder: folder)
            modelReady = true
            vm.modelReady = true
        } catch {
            vm.modelError = error.localizedDescription
            NSLog("[Whispr] onboarding model load failed: \(error)")
        }
    }

    /// Download (if needed) and load the currently-selected model. Reused for live model switches.
    // ponytail: no guard against overlapping reloads — worst case two loads race; last write wins. Add a flag if it matters.
    private func loadSelectedModel() async {
        let model = modelManager.selectedModel
        do {
            setStatus("downloading \(model)…")
            let folder = try await modelManager.ensureDownloaded(model) { [weak self] frac in
                self?.setStatus("downloading \(Int(frac * 100))%")
            }
            setStatus("loading model…")
            modelReady = false
            try await transcriber.load(model: model, folder: folder)
            modelReady = true
            state.modelReady = true
            state.modelError = nil
            setStatus("ready — tap or hold \(Self.hotkeyHint)")
            idleWidget.show()
        } catch {
            modelReady = false
            state.modelReady = false
            state.modelError = error.localizedDescription
            setStatus("model error — open OpenWispr to reload")
            NSLog("[Whispr] model load failed: \(error)")
        }
    }

    private func showMeeting() {
        state.pane = .meetings
        showMainWindow()
    }

    private func showImport() {
        state.pane = .importFile
        showMainWindow()
    }

    private func showSettings() {
        state.pane = .settings
        showMainWindow()
    }

    /// Attach the active trigger: fn monitor (default) or the custom shortcut. Re-call on mode change.
    /// Last chance before the process dies. Quit used to tear down nothing, which is harmless
    /// for a recorder but not for a muted output device — that would survive us.
    func shutdown() {
        silencerWatchdog?.invalidate(); silencerWatchdog = nil
        if recorder.isRecording { _ = recorder.stop() }
        silencer.restore()
    }

    func attachHotkeys() {
        if recorder.isRecording { stopDictation() } // never swap monitors mid-recording (drops the key-up)
        hotkeys = nil
        fnMonitor = nil
        if Self.effectiveMode == "custom" {
            hotkeys = HotkeyManager(
                onKeyDown: { [weak self] in self?.handleKeyDown() },
                onKeyUp: { [weak self] in self?.handleKeyUp() }
            )
        } else {
            fnMonitor = ModifierKeyMonitor(
                trigger: Triggers.trigger(for: Self.effectiveMode),
                onKeyDown: { [weak self] in self?.handleKeyDown() },
                onKeyUp: { [weak self] in self?.handleKeyUp() }
            )
        }
    }

    /// Hybrid trigger (Wispr Flow pattern): a quick tap toggles a session that stays open
    /// until the next tap; press-and-hold is classic push-to-talk (release transcribes).
    private static let holdThreshold: TimeInterval = 0.5
    private var keyDownAt: Date?

    /// Key-down: starts when idle; a tap while a session is open closes it.
    private func handleKeyDown() {
        if recorder.isRecording {
            stopDictation()
        } else {
            keyDownAt = Date()
            startDictation()
        }
    }

    /// Key-up after a hold (>0.5s) is push-to-talk — stop and transcribe.
    /// Key-up after a tap keeps the session open.
    private func handleKeyUp() {
        guard recorder.isRecording, let down = keyDownAt else { return }
        keyDownAt = nil
        if Date().timeIntervalSince(down) > Self.holdThreshold { stopDictation() }
    }

    // MARK: - Dictation flow (hold hotkey → record → release → transcribe → paste)

    private func startDictation() {
        guard modelReady, !recorder.isRecording else { return }
        if let front = AppMonitor.frontmostBundleID(), Settings.disabledApps.contains(front) {
            setStatus("disabled for \(AppMonitor.name(for: front))")
            return
        }
        dictatingInto = AppMonitor.frontmostBundleID() // for the Insights per-app breakdown
        axWatcher.stop() // new dictation supersedes the previous watch
        do {
            try recorder.start()
            menuBar.setRecording(true)
            indicator.show(
                onCancel: { [weak self] in self?.cancelDictation() },
                onStop: { [weak self] in self?.stopDictation() }
            )
            if Settings.soundCues { NSSound(named: "Pop")?.play() }
            // Silence AFTER the cue (muting first would swallow our own Pop) and after the
            // per-app-disabled return above, so a skipped dictation never leaves audio muted.
            // Meetings are excluded: there, the system output IS the remote party we transcribe.
            if !meetingCtrl.isRunning { silencer.silence() }
            idleWidget.hide() // the recording pill takes its spot
            setStatus("listening…")
            startPreviewLoop()
        } catch {
            setStatus("mic error")
            Log.audio.error("mic start failed: \(error.localizedDescription, privacy: .public)")
            silencer.restore() // never strand the output on a failed start
        }
    }

    /// Eager preview: every 2s re-transcribe the last ~10s of buffer (greedy) and show
    /// the tail in the pill. ponytail: re-transcribe loop, not a realtime model — skip
    /// ticks while the previous one runs; upgrade path = dedicated streaming backend.
    private func startPreviewLoop() {
        previewTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.previewTick() }
        }
    }

    private func stopPreviewLoop() {
        previewTimer?.invalidate(); previewTimer = nil
        previewTask?.cancel(); previewTask = nil
        previewBusy = false
    }

    private func previewTick() {
        guard recorder.isRecording, !previewBusy else { return }
        let samples = recorder.snapshot(last: 10)
        guard samples.count > 16000 else { return } // need >1s
        previewBusy = true
        previewTask = Task {
            defer { previewBusy = false }
            guard !Task.isCancelled,
                  let raw = try? await transcriber.transcribe(samples, language: Settings.languageCode),
                  !Task.isCancelled, recorder.isRecording else { return }
            let words = raw.split(separator: " ").suffix(8).joined(separator: " ")
            indicator.model.preview = words
        }
    }

    /// Discard the current recording without transcribing.
    private func cancelDictation() {
        guard recorder.isRecording else { return }
        stopPreviewLoop()
        _ = recorder.stop()
        silencer.restore()
        menuBar.setRecording(false)
        indicator.hide()
        idleWidget.show()
        setStatus("ready — tap or hold \(Self.hotkeyHint)")
    }

    /// "custom" with nothing recorded falls back to fn — a trigger must always exist.
    static var effectiveMode: String {
        Settings.hotkeyMode == "custom" && KeyboardShortcuts.getShortcut(for: .dictate) == nil
            ? "fn" : Settings.hotkeyMode
    }

    static var hotkeyHint: String {
        effectiveMode == "custom"
            ? (KeyboardShortcuts.getShortcut(for: .dictate).map(String.init(describing:)) ?? "fn")
            : Triggers.trigger(for: effectiveMode).label
    }

    private func stopDictation() {
        guard recorder.isRecording else { return }
        stopPreviewLoop()
        let samples = recorder.stop()
        silencer.restore() // before the Tink, so the cue is audible again
        menuBar.setRecording(false)
        indicator.hide()
        idleWidget.show()
        if Settings.soundCues { NSSound(named: "Tink")?.play() }
        setStatus("transcribing…")
        transcribeAndDeliver(samples)
    }

    /// Retry the last failed transcription (menu item).
    func retryLastTranscription() {
        guard let samples = failedSamples else { setStatus("nothing to retry"); return }
        failedSamples = nil
        setStatus("retrying…")
        transcribeAndDeliver(samples)
    }

    private func transcribeAndDeliver(_ samples: [Float]) {
        Task {
            do {
                var raw = try await transcriber.transcribe(samples, language: Settings.languageCode)
                if Settings.outputMode == "roman" { raw = Transliterate.toLatin(raw) }
                let corrected = DictionaryStore.apply(raw, DictionaryStore.load())
                let cleaned = TextProcessor.process(corrected, options: Settings.textOptions)
                // Snippets expand into sentinels, the rewrite runs around them, then the
                // expansions go back. An email address or URL therefore reaches the cursor
                // verbatim even with a rewrite style on. If the model eats a sentinel the
                // rewrite is dropped whole rather than pasting a half-expanded line.
                let expansion = SnippetStore.expand(cleaned, SnippetStore.load())
                let rewritten = await Self.rewriteIfEnabled(expansion.protectedText) { [weak self] in self?.setStatus($0) }
                let text = SnippetStore.restore(rewritten, tokens: expansion.tokens) ?? expansion.expandedText
                if text.isEmpty {
                    setStatus("ready (no speech)")
                } else {
                    Paster.deliver(text, autoPaste: Settings.autoPaste)
                    let seconds = Double(samples.count) / 16000
                    HistoryStore.add(text, seconds: seconds)
                    Stats.record(words: text.split(separator: " ").count, seconds: seconds, appBundleID: dictatingInto)
                    corrections.notePaste(text)
                    if Settings.autoPaste {
                        // watch the field we pasted into for in-place spelling fixes (~0.7s: after Cmd+V lands)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                            self?.axWatcher.watch(transcript: text)
                        }
                    }
                    if Settings.autoPaste && !Permissions.hasAccessibility {
                        // grant missing (or invalidated by a rebuild) — say so instead of failing silently
                        setStatus("copied — grant Accessibility to auto-paste")
                        Permissions.requestAccessibility()
                    } else {
                        setStatus("ready")
                    }
                }
            } catch {
                failedSamples = samples // recoverable via Retry Last Transcription
                setStatus("transcribe error — Retry from the menu")
                NSLog("[Whispr] transcribe failed: \(error)")
            }
        }
    }

    private func setStatus(_ text: String) {
        menuBar.setStatus(text)
        state.status = text
        state.isRecording = recorder.isRecording
        NSLog("[Whispr] status: \(text)")
    }

    /// One-shot migration from the Whispr era (bundle id com.ck.whispr, App Support "Whispr"):
    /// copies old UserDefaults keys we don't already have and old JSON stores into the new locations.
    static func migrateFromWhisprIfNeeded() {
        let flag = "migratedFromWhispr"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        if let old = UserDefaults.standard.persistentDomain(forName: "com.ck.whispr") {
            for (k, v) in old where UserDefaults.standard.object(forKey: k) == nil {
                UserDefaults.standard.set(v, forKey: k)
            }
        }
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = appSupport.appendingPathComponent("Whispr", isDirectory: true)
        let newDir = appSupport.appendingPathComponent("OpenWispr", isDirectory: true)
        if fm.fileExists(atPath: oldDir.path) {
            try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(atPath: oldDir.path)) ?? [] {
                let dst = newDir.appendingPathComponent(file)
                if !fm.fileExists(atPath: dst.path) {
                    try? fm.copyItem(at: oldDir.appendingPathComponent(file), to: dst)
                }
            }
        }
        UserDefaults.standard.set(true, forKey: flag)
        NSLog("[Whispr] migrated Whispr-era data")
    }

    /// Copy the running bundle to /Applications and relaunch from there.
    /// ditto preserves the bundle + signature; TCC grants stick to the /Applications copy.
    static func moveToApplicationsAndRelaunch() {
        let src = Bundle.main.bundlePath
        let dst = "/Applications/OpenWispr.app"
        guard src != dst else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = [src, dst]
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                NSLog("[Whispr] move failed: ditto exit \(p.terminationStatus)"); return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: dst), configuration: config) { _, _ in
                Task { @MainActor in NSApp.terminate(nil) }
            }
        } catch {
            NSLog("[Whispr] move failed: \(error)")
        }
    }

    /// Apply the configured AI rewrite style; on any failure return the original text (paste never blocks on AI errors).
    static func rewriteIfEnabled(_ text: String, status: @escaping (String) -> Void) async -> String {
        let style = Settings.rewriteStyle
        guard style != "off", !text.isEmpty else { return text }
        guard await LLMClient.available() else { return text }
        status("rewriting (\(style))…")
        let prompts = [
            "clean": "Fix grammar and punctuation. Keep the meaning, wording, and tone. Reply with only the corrected text.",
            "formal": "Rewrite in a professional, formal tone. Keep the meaning. Reply with only the rewritten text.",
            "concise": "Rewrite as concisely as possible without losing meaning. Reply with only the rewritten text.",
        ]
        guard let system = prompts[style] else { return text }
        do {
            let out = try await LLMClient.complete(system: system, user: text)
            return out.isEmpty ? text : out
        } catch {
            NSLog("[Whispr] rewrite failed, pasting original: \(error)")
            return text
        }
    }
}
