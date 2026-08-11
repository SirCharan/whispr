import AudioToolbox
import AppKit
import CoreAudio

/// Silence other audio while dictating, then put it back exactly as it was.
///
/// Two layers live here: `OutputAudio` is a thin CoreAudio wrapper over the default output
/// device, and `OutputSilencer` is the policy that decides when to touch it and how to undo it.
///
/// The failure mode this is built around: a mute that never restores leaves the Mac silent.
/// VoiceInk hit exactly that (their issue #640) — a DAC acknowledges the mute write but
/// implements it as volume-zero with nothing saved, unmute silently fails, and the app then
/// reads "already muted", decides the user meant it, and never restores again. So every
/// restore here is verified by reading the value back, and the intent is persisted to disk so
/// a crash or a force-quit is recovered on the next launch.
enum OutputAudio {

    // MARK: - Device queries

    static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return err == noErr && device != AudioDeviceID(kAudioObjectUnknown) ? device : nil
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// True when something is actually playing through the device. The whole feature is gated on
    /// this: silencing a device nobody is using has no upside and every downside.
    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var addr = outputAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr && running != 0
    }

    /// Many devices — aggregates, plenty of USB interfaces, some Bluetooth — expose no settable
    /// mute at all, so this must be checked rather than assumed.
    static func muteSupported(_ device: AudioDeviceID) -> Bool {
        var addr = outputAddress(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        var addr = outputAddress(kAudioDevicePropertyMute)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted) == noErr && muted == 1
    }

    @discardableResult
    static func setMute(_ device: AudioDeviceID, _ on: Bool) -> OSStatus {
        var addr = outputAddress(kAudioDevicePropertyMute)
        var value: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func volume(_ device: AudioDeviceID) -> Float32? {
        var addr = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func setVolume(_ device: AudioDeviceID, _ level: Float32) -> OSStatus {
        var addr = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = max(0, min(1, level))
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    // MARK: - Pause mode

    /// Synthesised play/pause media key.
    ///
    /// MediaRemote would report actual playback state, but it is private API and since roughly
    /// macOS 15.4 `mediaremoted` refuses unentitled clients. So this is a blind toggle: it
    /// cannot read whether anything is playing, which is why pause is opt-in and mute is the
    /// default. A crash mid-dictation can leave media paused — irritating, unlike a silent Mac.
    static func sendPlayPause() {
        let playKey: Int32 = 16   // NX_KEYTYPE_PLAY, IOKit/hidsystem/ev_keymap.h
        for isDown in [true, false] {
            let state: Int32 = isDown ? 0xA : 0xB
            let data1 = Int((playKey << 16) | (state << 8))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Decides when to silence output for a dictation and how to undo it.
///
/// Policy, copied from Wispr Flow because it limits the damage a bug here can do: act only when
/// audio is already playing, and if the user had already muted the device, leave it muted and
/// restore nothing.
@MainActor
final class OutputSilencer {

    /// What we did, persisted so a crash or force-quit can be undone on the next launch.
    struct Record: Codable, Equatable {
        var deviceID: UInt32
        var wasAlreadyMuted: Bool
        var usedVolumePath: Bool
        var savedVolume: Float?
        var startedAt: Date
    }

    /// The undo action for a record, given what the device looks like right now.
    enum Restore: Equatable {
        case nothing
        case unmute
        case volume(Float)
    }

    /// Open-ended tap-mode sessions mean a silence can outlive its dictation. After this long
    /// with no active recording, restore regardless.
    nonisolated static let watchdogSeconds: TimeInterval = 300

    private let key = "outputSilencerRecord"
    private var active: Record?

    // MARK: - Pure policy (self-tested; no CoreAudio involved)

    /// Never fight the user: if they had muted the device themselves, leave it alone. On the
    /// volume path only write the saved level back if the level is still where we left it,
    /// so a volume change made mid-dictation survives.
    nonisolated static func restoreAction(for record: Record, currentlyMuted: Bool, currentVolume: Float?) -> Restore {
        if record.wasAlreadyMuted { return .nothing }
        if record.usedVolumePath {
            guard let saved = record.savedVolume else { return .nothing }
            guard let current = currentVolume, current <= 0.01 else { return .nothing }
            return .volume(saved)
        }
        return currentlyMuted ? .unmute : .nothing
    }

    nonisolated static func isStale(_ record: Record, now: Date = Date()) -> Bool {
        now.timeIntervalSince(record.startedAt) > watchdogSeconds
    }

    // MARK: - Persistence

    private func persist(_ record: Record?) {
        guard let record else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadPersisted() -> Record? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    // MARK: - Public API

    /// Silence other audio for a dictation. No-op unless enabled, and only when audio is playing.
    func silence() {
        guard Settings.muteWhileDictating, active == nil else { return }
        guard let device = OutputAudio.defaultOutputDevice() else {
            Log.audio.error("silencer: no default output device")
            return
        }
        guard OutputAudio.isRunningSomewhere(device) else { return } // nothing playing — leave it alone

        if Settings.muteMode == "pause" {
            OutputAudio.sendPlayPause()
            active = Record(deviceID: device, wasAlreadyMuted: false, usedVolumePath: false,
                            savedVolume: nil, startedAt: Date())
            persist(active)
            Log.audio.info("silencer: sent play/pause")
            return
        }

        let alreadyMuted = OutputAudio.isMuted(device)
        let canMute = OutputAudio.muteSupported(device)
        var record = Record(deviceID: device, wasAlreadyMuted: alreadyMuted,
                            usedVolumePath: !canMute, savedVolume: nil, startedAt: Date())

        if alreadyMuted {
            active = record            // remember so we do NOT unmute something the user muted
            persist(record)
            return
        }
        if canMute {
            let status = OutputAudio.setMute(device, true)
            if status != noErr { Log.audio.error("silencer: setMute failed status=\(status, privacy: .public)") }
        } else {
            record.savedVolume = OutputAudio.volume(device)
            OutputAudio.setVolume(device, 0)
        }
        active = record
        persist(record)
        Log.audio.info("""
            silencer: silenced device=\(device, privacy: .public) \
            path=\(record.usedVolumePath ? "volume" : "mute", privacy: .public) \
            saved=\(record.savedVolume ?? -1, format: .fixed(precision: 2), privacy: .public)
            """)
    }

    /// Put the output back. Safe to call when nothing was silenced.
    func restore() {
        guard let record = active ?? loadPersisted() else { return }
        active = nil
        defer { persist(nil) }

        if Settings.muteMode == "pause", !record.usedVolumePath, record.savedVolume == nil,
           !record.wasAlreadyMuted, OutputAudio.isMuted(AudioDeviceID(record.deviceID)) == false,
           Settings.muteWhileDictating {
            // pause-mode record: toggle playback back on
            OutputAudio.sendPlayPause()
            Log.audio.info("silencer: sent play/pause to resume")
            return
        }

        let device = AudioDeviceID(record.deviceID)
        apply(OutputSilencer.restoreAction(for: record,
                                           currentlyMuted: OutputAudio.isMuted(device),
                                           currentVolume: OutputAudio.volume(device)),
              on: device)

        // Read back. A device that acknowledges the write and ignores it is the documented
        // failure here, so verify and fall back to the volume path once.
        if !record.wasAlreadyMuted, OutputAudio.isMuted(device) {
            Log.audio.error("silencer: still muted after restore — forcing volume path")
            OutputAudio.setMute(device, false)
            OutputAudio.setVolume(device, record.savedVolume ?? 0.5)
            if OutputAudio.isMuted(device) {
                Log.audio.error("silencer: device refuses to unmute — user must unmute manually")
            }
        }
    }

    private func apply(_ action: Restore, on device: AudioDeviceID) {
        switch action {
        case .nothing:
            Log.audio.info("silencer: nothing to restore")
        case .unmute:
            OutputAudio.setMute(device, false)
            Log.audio.info("silencer: unmuted")
        case .volume(let level):
            OutputAudio.setVolume(device, level)
            Log.audio.info("silencer: volume restored to \(level, format: .fixed(precision: 2), privacy: .public)")
        }
    }

    /// Called at launch: undo a silence that outlived the process.
    func recoverAfterCrash() {
        guard let record = loadPersisted() else { return }
        Log.audio.error("silencer: found an unfinished silence from \(record.startedAt, privacy: .public) — restoring")
        active = record
        restore()
    }

    /// Called on a timer while idle: undo a silence whose dictation never ended.
    func expireIfStale(isRecording: Bool) {
        guard !isRecording, let record = active ?? loadPersisted() else { return }
        guard OutputSilencer.isStale(record) else { return }
        Log.audio.error("silencer: silence exceeded \(Int(OutputSilencer.watchdogSeconds))s with no dictation — restoring")
        active = record
        restore()
    }

    // MARK: - Self-test (pure policy only)

    nonisolated static func selfTest() {
        let now = Date()
        func rec(wasMuted: Bool = false, volumePath: Bool = false, saved: Float? = nil,
                 age: TimeInterval = 0) -> Record {
            Record(deviceID: 1, wasAlreadyMuted: wasMuted, usedVolumePath: volumePath,
                   savedVolume: saved, startedAt: now.addingTimeInterval(-age))
        }

        // The user muted it themselves — never touch it.
        precondition(restoreAction(for: rec(wasMuted: true), currentlyMuted: true, currentVolume: 0) == .nothing,
                     "must not unmute a user-muted device")
        // Normal mute path.
        precondition(restoreAction(for: rec(), currentlyMuted: true, currentVolume: nil) == .unmute,
                     "should unmute what we muted")
        // Already unmuted by someone else — nothing to do.
        precondition(restoreAction(for: rec(), currentlyMuted: false, currentVolume: nil) == .nothing,
                     "already unmuted needs no action")
        // Volume path restores only while the level is still where we left it.
        precondition(restoreAction(for: rec(volumePath: true, saved: 0.7),
                                   currentlyMuted: false, currentVolume: 0.0) == .volume(0.7),
                     "should restore saved volume")
        precondition(restoreAction(for: rec(volumePath: true, saved: 0.7),
                                   currentlyMuted: false, currentVolume: 0.4) == .nothing,
                     "must not clobber a volume the user changed mid-dictation")
        precondition(restoreAction(for: rec(volumePath: true, saved: nil),
                                   currentlyMuted: false, currentVolume: 0.0) == .nothing,
                     "no saved level means no write")

        // Watchdog.
        precondition(!isStale(rec(age: 10), now: now), "fresh record is not stale")
        precondition(isStale(rec(age: watchdogSeconds + 1), now: now), "old record is stale")

        // Round-trip through Codable, since the crash-recovery path depends on it.
        let original = rec(volumePath: true, saved: 0.42)
        let data = try! JSONEncoder().encode(original)
        let back = try! JSONDecoder().decode(Record.self, from: data)
        precondition(back.savedVolume == 0.42 && back.usedVolumePath, "record must survive encoding")

        print("OutputSilencer.selfTest PASS")
    }
}
