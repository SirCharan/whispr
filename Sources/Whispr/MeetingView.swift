import SwiftUI
import AppKit

/// Live meeting transcript: start/pause/stop, timestamped speaker lines, rename-at-stop, export.
struct MeetingView: View {
    @ObservedObject var controller: MeetingController
    @State private var screenRecOK = CGPreflightScreenCaptureAccess()
    @State private var renames: [String: String] = [:]

    /// Small labelled dot: green while audio buffers keep arriving on that stream, red once
    /// they stop. Text carries the state too, so it does not rely on colour alone.
    private func streamDot(_ label: String, healthy: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(healthy ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(healthy ? .secondary : Color.red)
        }
        .help(healthy ? "\(label): audio arriving" : "\(label): no audio arriving")
        .accessibilityLabel("\(label) audio \(healthy ? "arriving" : "stopped")")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(controller.isRunning ? (controller.isPaused ? Color.orange : Color.red) : Color.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
                if controller.isRunning {
                    // Per-stream capture health. Without this a stalled stream is
                    // indistinguishable from a room where nobody is talking.
                    streamDot("You", healthy: controller.micHealthy)
                    streamDot("Others", healthy: controller.systemHealthy)
                }
                Spacer()
                Picker("Language", selection: $controller.meetingLanguage) {
                    ForEach(Languages.list, id: \.code) { lang in Text(lang.name).tag(lang.code ?? "auto") }
                }
                .labelsHidden()
                .frame(maxWidth: 130)
                .help("Meeting language — lock to Hindi/English for mixed calls; Auto re-detects per chunk")
                if controller.isRunning {
                    Button(controller.isPaused ? "Resume" : "Pause") {
                        Task { controller.isPaused ? await controller.resume() : await controller.pause() }
                    }
                    Button("Stop") { Task { await controller.stop() } }
                        .tint(.red)
                } else {
                    Button("Start recording") { Task { await controller.start() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!screenRecOK) // pre-start check: no surprises at meeting time
                }
                Button(controller.summarizing ? "Summarizing…" : "Summarize") {
                    Task { await controller.summarize() }
                }
                .disabled(controller.lines.isEmpty || controller.isRunning || controller.summarizing)
                Button("Export…") { export() }
                    .disabled(controller.lines.isEmpty)
            }
            .padding(12)
            Divider()

            if let summary = controller.summary {
                ScrollView {
                    Text(LocalizedStringKey(summary))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 160)
                .background(Color.accentColor.opacity(0.06))
                Divider()
            }

            if controller.lines.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: !screenRecOK || controller.needsScreenRec ? "exclamationmark.shield" : "person.2.wave.2")
                        .font(.system(size: 36)).foregroundStyle(!screenRecOK || controller.needsScreenRec ? .orange : .secondary)
                    if !screenRecOK || controller.needsScreenRec {
                        Text("Meetings need Screen Recording permission (that's how macOS exposes system audio). Click below — that adds OpenWispr to the list — then switch it ON and relaunch. A leftover \"Whispr\" entry from the old app can be removed.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Request permission + open settings") {
                            CGRequestScreenCaptureAccess() // registers OpenWispr in the pane; without this the row never appears
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        Button("I've enabled it — re-check") { screenRecOK = CGPreflightScreenCaptureAccess() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Start recording to capture your mic (You) and the other side's audio — remote voices are separated into Speaker A/B after you stop.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text("Transcript checkpoints to Documents/OpenWispr after every line. First meeting downloads the speaker model (~100 MB) once.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding()
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List(controller.lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(MeetingController.mmss(line.start))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                .frame(width: 38, alignment: .trailing)
                            Text(line.speaker)
                                .font(.caption.bold())
                                .foregroundStyle(line.speaker == "You" ? Color.accentColor : .orange)
                                .frame(width: 70, alignment: .trailing)
                            Text(line.text)
                        }
                        .id(line.id)
                        .padding(.vertical, 2)
                    }
                    .onChange(of: controller.lines.count) { _, _ in
                        if let last = controller.lines.last { proxy.scrollTo(last.id) }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .onAppear { screenRecOK = CGPreflightScreenCaptureAccess() }
        .sheet(isPresented: $controller.showRenameSheet) { renameSheet }
    }

    /// Post-meeting labeling: name each detected speaker (ck's flow).
    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Label the speakers").font(.title3.bold())
            Text("Type real names — the transcript and the saved file update everywhere.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(controller.distinctSpeakers, id: \.self) { s in
                HStack {
                    Text(s).font(.system(size: 12, design: .monospaced))
                        .frame(width: 90, alignment: .trailing).foregroundStyle(.secondary)
                    TextField(s == "You" ? "your name (optional)" : "e.g. Priya", text: Binding(
                        get: { renames[s] ?? "" },
                        set: { renames[s] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Skip") { controller.showRenameSheet = false; renames = [:] }
                Button("Apply names") {
                    controller.renameSpeakers(renames)
                    controller.showRenameSheet = false
                    renames = [:]
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renames.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "meeting-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? controller.exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

