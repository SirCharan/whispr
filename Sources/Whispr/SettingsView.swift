import SwiftUI
import KeyboardShortcuts

extension Notification.Name {
    static let whisprHotkeyModeChanged = Notification.Name("whispr.hotkeyModeChanged")
}

/// General settings: trigger, behavior, cleanup, appearance, permissions.
/// Model/language live in the home window's Models pane; other former tabs are sidebar panes.
struct SettingsView: View {
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage("removeFillers") private var removeFillers = true
    @AppStorage("cleanUp") private var cleanUp = true
    @AppStorage("soundCues") private var soundCues = true
    @AppStorage("muteWhileDictating") private var muteWhileDictating = true
    @AppStorage("muteMode") private var muteMode = "mute"
    @AppStorage("showIdleWidget") private var showIdleWidget = true
    @AppStorage("diarizationEnabled") private var diarizationEnabled = true
    @AppStorage("hotkeyMode") private var hotkeyMode = "fn"
    @AppStorage("rewriteStyle") private var rewriteStyle = "off"
    @AppStorage("accentHex") private var accentHex = "FF5D54"
    @AppStorage("appearance") private var appearance = "system"
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemFailed = false
    @State private var accessibilityOK = Permissions.hasAccessibility

    var body: some View {
        Form {
            Section("Dictation trigger") {
                Picker("Trigger", selection: $hotkeyMode) {
                    ForEach(Triggers.list, id: \.id) { t in Text(t.label).tag(t.id) }
                    Text("Custom shortcut").tag("custom")
                }
                .onChange(of: hotkeyMode) { _, _ in NotificationCenter.default.post(name: .whisprHotkeyModeChanged, object: nil) }
                if hotkeyMode == "custom" {
                    KeyboardShortcuts.Recorder("Shortcut:", name: .dictate)
                } else {
                    Text("Tip: set System Settings → Keyboard → “Press 🌐 key to” = Do Nothing, so the emoji picker stays out of the way.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Tap the trigger to start — it keeps listening until you tap again. Or hold to talk and release to transcribe. Both always work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("Auto-paste at cursor (off = copy to clipboard only)", isOn: $autoPaste)
                Toggle("Sound cues on record start/stop", isOn: $soundCues)
                Toggle("Silence other audio while dictating", isOn: $muteWhileDictating)
                if muteWhileDictating {
                    Picker("While dictating", selection: $muteMode) {
                        Text("Mute the output").tag("mute")
                        Text("Pause what's playing").tag("pause")
                    }
                    .pickerStyle(.radioGroup)
                    Text(muteMode == "pause"
                         ? "Sends the play/pause key, so you keep your place. It can't read what's playing, so it may occasionally toggle the wrong way."
                         : "Mutes your output device and unmutes it when dictation ends. Only acts if audio is already playing; if you muted it yourself it stays muted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Separate remote meeting speakers (A/B) by voice", isOn: $diarizationEnabled)
                Toggle("Floating mic button (click to dictate)", isOn: $showIdleWidget)
                    .onChange(of: showIdleWidget) { _, _ in NotificationCenter.default.post(name: .whisprHotkeyModeChanged, object: nil) }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if LoginItem.set(on) { loginItemFailed = false }
                        else { launchAtLogin = false; loginItemFailed = true } // register fails outside /Applications
                    }
                if loginItemFailed {
                    Text("Couldn't set launch-at-login. Move OpenWispr to your Applications folder first.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Transcript cleanup") {
                Toggle("Remove filler words (um, uh, er)", isOn: $removeFillers)
                Toggle("Capitalize sentences & tidy spacing", isOn: $cleanUp)
                Picker("AI rewrite (needs AI provider)", selection: $rewriteStyle) {
                    Text("Off").tag("off")
                    Text("Clean grammar").tag("clean")
                    Text("Formal").tag("formal")
                    Text("Concise").tag("concise")
                }
            }
            Section("Appearance") {
                Picker("Accent", selection: $accentHex) {
                    ForEach(Theme.accents, id: \.hex) { a in Text(a.name).tag(a.hex) }
                }
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                .onChange(of: appearance) { _, _ in Theme.apply() }
            }
            Section("Permissions") {
                HStack {
                    Text(accessibilityOK
                         ? "Accessibility: granted ✓"
                         : "Accessibility needed for auto-paste")
                    Spacer()
                    if !accessibilityOK {
                        Button("Grant…") {
                            Permissions.requestAccessibility()
                            accessibilityOK = Permissions.hasAccessibility
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
