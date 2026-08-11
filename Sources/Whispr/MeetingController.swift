import Foundation

struct MeetingLine: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var speaker: String   // "You" (mic), "Others"/"Speaker A/B…" (system), or a user label
    var text: String
    var start: Double = 0 // stream-timeline seconds (system stream for remote lines)
    var end: Double = 0
}

/// Records a meeting from two streams — mic ("You") and system audio (remote) — rotating
/// chunks at natural speech pauses. At Stop, the FULL system recording is diarized
/// (FluidAudio/pyannote, on-device) so remote lines become Speaker A/B/…, then the user
/// can rename speakers. Transcript checkpoints to disk after every line.
@MainActor
final class MeetingController: ObservableObject {
    @Published private(set) var lines: [MeetingLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var status = "idle"
    @Published var summary: String?
    @Published private(set) var summarizing = false
    @Published private(set) var needsScreenRec = false
    @Published private(set) var savedTo: String?
    @Published var showRenameSheet = false
    /// Per-stream capture health, shown in MeetingView so a dead stream never reads as a quiet room.
    @Published private(set) var micHealthy = true
    @Published private(set) var systemHealthy = true
    /// Per-meeting language override ("auto" = follow the global setting). Read per chunk, editable live.
    @Published var meetingLanguage = "auto"

    private let mic = AudioRecorder()
    private let system = SystemAudioRecorder()
    private let transcriber: Transcriber
    private let diarizer = Diarizer()
    private var timer: Timer?
    private let minSamples = 3200        // ignore chunks under 0.2 s
    private let minChunkSeconds = 6.0
    private let maxChunkSeconds = 30.0
    private let pauseWindow = 0.7
    private let pauseRMS: Float = 0.004
    /// Speech floor applied to the loudest half-second of a chunk (not its mean).
    private let speechPeakRMS: Float = 0.0035

    /// Meeting cleanup keeps capitalization and spacing but never deletes words.
    static let meetingTextOptions = TextProcessor.Options(removeFillers: false, cleanUp: true)

    // stream timelines (cumulative across pause/resume) + full system audio for stop-time diarization
    private var micOffset = 0.0
    private var sysOffset = 0.0
    private var fullSysAudio: [Float] = []
    // ponytail: full floats in RAM ≈ 230MB/hour — fine for normal meetings; stream-to-disk if ever needed
    private var meetingFile: URL?

    // raw-audio retention
    private var micWav: WavEncoder.Writer?
    private var sysWav: WavEncoder.Writer?

    // liveness tracking (buffer arrival, not energy)
    private let stallTicks = 5            // seconds of no buffers before a stream is called dead
    private let maxSysRestarts = 8
    private var lastMicAppends = 0
    private var lastSysAppends = 0
    private var micQuietTicks = 0
    private var sysQuietTicks = 0
    private var sysRestartAttempts = 0
    private var sysRestartCooldown = 0

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    private var starting = false

    func start() async {
        guard !isRunning, !starting else { return }
        starting = true // synchronous, before any await — a second tap during startup must bounce
        defer { starting = false }
        status = Settings.diarizationEnabled ? "preparing speaker model…" : "starting…"
        if Settings.diarizationEnabled {
            do { try await diarizer.prepare() } // idempotent; first run downloads ~100MB
            catch {
                Log.audio.error("diarizer prepare failed, falling back to Others: \(error.localizedDescription, privacy: .public)")
                status = "speaker separation unavailable — using Others"
            }
        }
        // Assigned BEFORE start: a teardown during startup used to land in the gap between
        // system.start() and this line, and was lost.
        system.onUnexpectedStop = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isPaused else { return }
                self.systemHealthy = false
                self.status = "the other side's audio dropped — reconnecting…"
                await self.restartSystemAudio()
            }
        }
        do {
            try mic.start(voiceProcessing: true) // AEC: keep speaker playback out of "You"
            try await system.start()
        } catch {
            needsScreenRec = (error as NSError).domain.contains("ScreenCaptureKit")
            status = needsScreenRec ? "needs Screen Recording permission" : "start failed: \(error.localizedDescription)"
            _ = mic.stop()
            return
        }
        isRunning = true
        isPaused = false
        needsScreenRec = false
        status = "recording"
        summary = nil
        savedTo = nil
        lines.removeAll()
        micOffset = 0; sysOffset = 0
        fullSysAudio.removeAll()
        // fix the checkpoint file at start so every save hits the same path
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        meetingFile = dir.appendingPathComponent("meeting-\(stamp).md")
        openAudioWriters(dir: dir, stamp: stamp)
        micHealthy = true
        systemHealthy = true
        lastMicAppends = 0; lastSysAppends = 0
        micQuietTicks = 0; sysQuietTicks = 0
        sysRestartAttempts = 0; sysRestartCooldown = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHealth()
                self?.checkRotation()
            }
        }
    }

    // MARK: - Raw audio retention

    /// Keep the raw 16 kHz mono audio so a bad transcript can be re-run offline with
    /// `--transcribe-file` instead of being lost. 115 MB/hour/stream.
    private func openAudioWriters(dir: URL, stamp: String) {
        guard Settings.meetingAudioRetentionDays > 0 else { return }
        let audioDir = dir.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        pruneOldAudio(in: audioDir)
        do {
            micWav = try WavEncoder.Writer(url: audioDir.appendingPathComponent("meeting-\(stamp)-you.wav"))
            sysWav = try WavEncoder.Writer(url: audioDir.appendingPathComponent("meeting-\(stamp)-others.wav"))
            Log.app.info("meeting audio retention on → \(audioDir.path, privacy: .public)")
        } catch {
            Log.app.error("could not open meeting audio writers: \(error.localizedDescription, privacy: .public)")
            micWav = nil; sysWav = nil
        }
    }

    private func pruneOldAudio(in dir: URL) {
        let days = Settings.meetingAudioRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files where f.pathExtension == "wav" {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: f)
                Log.app.info("pruned old meeting audio \(f.lastPathComponent, privacy: .public)")
            }
        }
    }

    private func closeAudioWriters() {
        micWav?.close(); sysWav?.close()
        micWav = nil; sysWav = nil
    }

    // MARK: - Stream liveness

    /// A stream that starts and then delivers nothing used to be indistinguishable from a
    /// silent room. Watch buffer ARRIVAL (not energy) and say so out loud.
    private func checkHealth() {
        guard isRunning, !isPaused else { return }

        let micAppends = mic.diagnostics.appends
        if micAppends == lastMicAppends {
            micQuietTicks += 1
            if micQuietTicks == stallTicks {
                micHealthy = false
                Log.audio.error("mic: no buffers for \(self.stallTicks)s — input device stalled")
                status = "your microphone stopped delivering audio"
            }
        } else {
            if !micHealthy { Log.audio.info("mic: buffers resumed") }
            micQuietTicks = 0; micHealthy = true
        }
        lastMicAppends = micAppends

        if sysRestartCooldown > 0 { sysRestartCooldown -= 1 }
        let sysAppends = system.diagnostics.appends
        if sysAppends == lastSysAppends {
            sysQuietTicks += 1
            if sysQuietTicks == stallTicks {
                systemHealthy = false
                Log.audio.error("others: no buffers for \(self.stallTicks)s — stream stalled")
                Task { await self.restartSystemAudio() }
            }
        } else {
            if !systemHealthy {
                Log.audio.info("others: buffers resumed")
                status = "recording"
            }
            sysQuietTicks = 0; systemHealthy = true; sysRestartAttempts = 0
        }
        lastSysAppends = sysAppends
    }

    /// Reconnect the system-audio tap with exponential backoff, keeping buffered audio.
    private func restartSystemAudio() async {
        guard isRunning, !isPaused, sysRestartCooldown == 0 else { return }
        guard sysRestartAttempts < maxSysRestarts else {
            status = "the other side's audio is unavailable — this transcript will be mic-only"
            return
        }
        sysRestartAttempts += 1
        let backoff = min(30, Int(pow(2.0, Double(sysRestartAttempts - 1))))
        sysRestartCooldown = backoff
        sysQuietTicks = 0
        Log.audio.info("others: restart attempt \(self.sysRestartAttempts)/\(self.maxSysRestarts), next retry in \(backoff)s")
        do {
            try await system.restart()
            status = "recording"
        } catch {
            Log.audio.error("others: restart failed: \(error.localizedDescription, privacy: .public)")
            status = "reconnecting the other side's audio…"
        }
    }

    /// Pause: transcribe what's buffered, stop both engines. Resume restarts them; timeline stays cumulative.
    func pause() async {
        guard isRunning, !isPaused else { return }
        isPaused = true
        timer?.invalidate(); timer = nil
        status = "pausing…"
        let micTail = mic.stop()
        let sysTail = await system.stop()
        await ingest(micTail, speaker: "You", stream: .mic)
        await ingest(sysTail, speaker: "Others", stream: .system)
        status = "paused"
    }

    func resume() async {
        guard isRunning, isPaused else { return }
        do {
            try mic.start(voiceProcessing: true)
            try await system.start()
        } catch {
            status = "resume failed: \(error.localizedDescription)"
            return
        }
        isPaused = false
        status = "recording"
        lastMicAppends = mic.diagnostics.appends
        lastSysAppends = system.diagnostics.appends
        micQuietTicks = 0; sysQuietTicks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHealth()
                self?.checkRotation()
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false // clear before awaits so a double-stop can't re-enter teardown
        timer?.invalidate(); timer = nil
        status = "finishing…"
        if !isPaused {
            let micTail = mic.stop()
            let sysTail = await system.stop()
            await ingest(micTail, speaker: "You", stream: .mic)
            await ingest(sysTail, speaker: "Others", stream: .system)
        }
        isPaused = false
        closeAudioWriters()
        await applyDiarization()
        status = "done"
        if !lines.isEmpty {
            Stats.recordMeeting()
            autosave()
            showRenameSheet = true // ck's flow: label speakers right after the transcript is done
        }
    }

    /// Split "Others" lines into Speaker A/B/… using the full system recording. Falls back silently.
    private func applyDiarization() async {
        guard Settings.diarizationEnabled, !fullSysAudio.isEmpty else { return }
        status = "separating speakers…"
        let audio = fullSysAudio
        do {
            let segments = try await diarizer.diarize(audio)
            guard !segments.isEmpty else { return }
            for i in lines.indices where lines[i].speaker == "Others" {
                if let who = Diarizer.assign(start: lines[i].start, end: lines[i].end, segments: segments) {
                    lines[i].speaker = who
                }
            }
        } catch {
            Log.audio.error("diarization failed, keeping Others: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rename speakers (post-meeting labeling). Map old label -> new name; rewrites transcript + file.
    func renameSpeakers(_ mapping: [String: String]) {
        for i in lines.indices {
            if let new = mapping[lines[i].speaker], !new.trimmingCharacters(in: .whitespaces).isEmpty {
                lines[i].speaker = new.trimmingCharacters(in: .whitespaces)
            }
        }
        autosave()
    }

    var distinctSpeakers: [String] {
        var seen: [String] = []
        for l in lines where !seen.contains(l.speaker) { seen.append(l.speaker) }
        return seen
    }

    /// Checkpoint after every line: crash/quit loses at most one chunk.
    private func autosave() {
        guard let url = meetingFile else { return }
        do {
            try exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
            savedTo = url.path
        } catch {
            Log.app.error("meeting autosave failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func checkRotation() {
        guard isRunning, !isPaused else { return }
        rotateIfDue(label: "mic", buffered: mic.bufferedSeconds, tail: mic.tailRMS(pauseWindow)) {
            let chunk = self.mic.drain()
            Task { await self.ingest(chunk, speaker: "You", stream: .mic) }
        }
        rotateIfDue(label: "others", buffered: system.bufferedSeconds, tail: system.tailRMS(pauseWindow)) {
            let chunk = self.system.drain()
            Task { await self.ingest(chunk, speaker: "Others", stream: .system) }
        }
    }

    /// True when two lines from opposite streams overlap ≥50% of the shorter one and read the same
    /// (JW > 0.82) — i.e. the mic heard the speaker. Pure; self-tested.
    nonisolated static func isEchoPair(_ a: MeetingLine, _ b: MeetingLine) -> Bool {
        let overlap = min(a.end, b.end) - max(a.start, b.start)
        let shorter = min(a.end - a.start, b.end - b.start)
        guard shorter > 0, overlap >= shorter * 0.5 else { return false }
        return DictionaryStore.jaroWinkler(a.text.lowercased(), b.text.lowercased()) > 0.82
    }

    nonisolated static func selfTest() {
        func line(_ s: String, _ t0: Double, _ t1: Double) -> MeetingLine {
            MeetingLine(speaker: "x", text: s, start: t0, end: t1)
        }
        precondition(isEchoPair(line("we should add a card for delta global", 7, 12),
                          line("We should add a card for the delta global here", 7, 13)), "echo not caught")
        precondition(!isEchoPair(line("we should add a card", 7, 12),
                           line("now we can go to the call", 7, 12)), "different text flagged")
        precondition(!isEchoPair(line("we should add a card", 0, 5),
                           line("we should add a card", 40, 45)), "non-overlapping flagged")
        print("MeetingController.selfTest PASS")
    }

    private func rotateIfDue(label: String, buffered: Double, tail: Float, rotate: () -> Void) {
        guard buffered >= minChunkSeconds else { return }
        let forced = buffered >= maxChunkSeconds
        guard tail < pauseRMS || forced else { return }
        Log.audio.info("""
            rotate \(label, privacy: .public) buffered=\(buffered, format: .fixed(precision: 1), privacy: .public)s \
            tailRMS=\(tail, format: .fixed(precision: 4), privacy: .public) \
            reason=\(forced ? "maxDuration" : "pause", privacy: .public)
            """)
        rotate()
    }

    // MARK: - Chunk ingestion (timeline-stamped)

    private enum Stream { case mic, system }

    private func ingest(_ samples: [Float], speaker: String, stream: Stream) async {
        let duration = Double(samples.count) / 16000
        let start: Double
        switch stream {
        case .mic:
            start = micOffset; micOffset += duration
            micWav?.append(samples)
        case .system:
            start = sysOffset; sysOffset += duration
            fullSysAudio.append(contentsOf: samples) // kept for stop-time diarization
            sysWav?.append(samples)
        }
        let which = stream == .mic ? "mic" : "others"
        let meanRMS = ResamplingBuffer.rms(samples)
        let peakRMS = ResamplingBuffer.maxWindowRMS(samples)
        Log.audio.info("""
            chunk \(which, privacy: .public) t=\(start, format: .fixed(precision: 1), privacy: .public)s \
            dur=\(duration, format: .fixed(precision: 1), privacy: .public)s \
            meanRMS=\(meanRMS, format: .fixed(precision: 4), privacy: .public) \
            peakRMS=\(peakRMS, format: .fixed(precision: 4), privacy: .public)
            """)
        guard samples.count >= minSamples else {
            Log.audio.info("drop \(which, privacy: .public) t=\(start, format: .fixed(precision: 1), privacy: .public)s — too short (\(samples.count) samples)")
            return
        }
        // Gate on the LOUDEST half-second, not the chunk mean. The old `mean > 0.002` test
        // discarded any chunk where real speech was diluted by surrounding silence — the
        // mechanism behind the multi-minute blank gaps. Both levels are logged so the
        // threshold can be set from real meeting data rather than guessed.
        guard peakRMS > speechPeakRMS else {
            Log.audio.info("""
                drop \(which, privacy: .public) t=\(start, format: .fixed(precision: 1), privacy: .public)s — \
                below speech floor (peak \(peakRMS, format: .fixed(precision: 4), privacy: .public) \
                <= \(self.speechPeakRMS, format: .fixed(precision: 4), privacy: .public))
                """)
            return
        }
        do {
            let language = meetingLanguage == "auto" ? Settings.languageCode : meetingLanguage
            var raw = try await transcriber.transcribe(samples, language: language)
            if Settings.outputMode == "roman" { raw = Transliterate.toLatin(raw) }
            raw = TextProcessor.collapseRepeats(raw) // hallucination loops on short call chunks
            // A meeting is a record, not dictated prose: filler removal deletes real words
            // (and mangles Hindi tokens). Keep only the non-destructive cleanup.
            let text = TextProcessor.process(raw, options: Self.meetingTextOptions)
            guard !text.isEmpty else {
                Log.audio.info("drop \(which, privacy: .public) t=\(start, format: .fixed(precision: 1), privacy: .public)s — empty after cleanup (raw was \(raw.count) chars)")
                return
            }
            let line = MeetingLine(speaker: speaker, text: text, start: start, end: start + duration)
            // Echo dedup is DISABLED. It deleted a "You" line whenever a system line read the
            // same — and on speakers-plus-built-in-mic the mic hears every remote voice, so it
            // erased the entire mic stream (zero "You" lines in every meeting since 27 Jul).
            // Deleting a real line is unrecoverable; a duplicate is merely untidy. Still logged,
            // because a hit here means the mic is picking up room playback (an AEC problem).
            if let twin = lines.first(where: { $0.speaker != speaker && Self.isEchoPair($0, line) }) {
                Log.audio.info("""
                    echo overlap kept (was deleted before): \(which, privacy: .public) \
                    "\(text, privacy: .public)" vs \(twin.speaker, privacy: .public) "\(twin.text, privacy: .public)"
                    """)
            }
            lines.append(line)
            lines.sort { $0.start < $1.start } // interleave You/Others in spoken order
            autosave() // live checkpoint
        } catch {
            Log.audio.error("""
                meeting chunk failed (\(which, privacy: .public) t=\(start, format: .fixed(precision: 1), privacy: .public)s): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    // MARK: - AI summary (BYOK, optional)

    func summarize() async {
        guard !lines.isEmpty, !summarizing else { return }
        summarizing = true
        defer { summarizing = false }
        guard await LLMClient.available() else {
            summary = "_No AI provider configured. Install Ollama from ollama.com (then `ollama pull llama3.2`), or add an API key in the AI settings — then click Summarize again._"
            return
        }
        let transcript = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        do {
            summary = try await LLMClient.complete(
                system: """
                You summarize meeting transcripts. "You" is the local user; other names/speakers are remote participants.
                Reply in Markdown with exactly these sections: ## Summary (2-4 sentences),
                ## Decisions (bullets, or "None"), ## Action items (bullets with owner if known, or "None").
                """,
                user: transcript
            )
            autosave()
        } catch {
            summary = "_\(error.localizedDescription)_"
        }
    }

    // MARK: - Export

    static func mmss(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func exportMarkdown() -> String {
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short
        let duration = lines.map(\.end).max() ?? 0
        var md = "# Meeting transcript — \(df.string(from: lines.first?.date ?? Date()))\n"
        md += "Duration: \(Self.mmss(duration)) · \(distinctSpeakers.joined(separator: " · "))\n\n"
        if let summary, !summary.isEmpty {
            md += summary + "\n\n---\n\n"
        }
        for line in lines {
            md += "[\(Self.mmss(line.start))] **\(line.speaker)**: \(line.text)\n\n"
        }
        return md
    }
}
