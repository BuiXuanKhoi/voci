// Sources/Reminders/MicrophoneActivityMonitor.swift — "is anyone using the microphone right now"
// signal (contract §B), Volar's best-effort proxy for "anh Khôi is on a call/in a meeting" before
// ever taking over the whole screen. macOS has no public, unprivileged API that reads Focus/Do Not
// Disturb state from inside an App Sandbox — `com.apple.donotdisturb` defaults do NOT work
// sandboxed (`Sources/Reminders/ReminderContextGate.swift`'s own header comment documents this
// exact limitation for the same reason: reading Focus status requires the restricted
// `com.apple.developer.focus-status` entitlement, which needs Apple approval and is deliberately
// not added speculatively to a MAS-first app). `kAudioDevicePropertyDeviceIsRunningSomewhere` on
// the system default input device is the closest available substitute: it goes `true` the moment
// ANY process (including this one) starts pulling audio from that device, with no extra
// entitlement and no permission prompt beyond whatever mic access already exists on the machine.
import Foundation
import CoreAudio

enum MicrophoneActivityMonitor {
    /// `true` if the system's current default audio input device reports as actively running for
    /// ANY client process — not just Volar. Fails toward "not in use" (`false`) on every lookup
    /// error (no resolvable default device, unsupported property, etc.) rather than blocking the
    /// takeover forever on a machine where this signal can't be read at all.
    ///
    /// UNVERIFIED — CoreAudio's `AudioObjectGetPropertyData` C API, authored on Windows with no
    /// Xcode/CoreAudio headers available to compile against. Confirm on Mac:
    /// (1) this reads `true` while e.g. FaceTime/Zoom/Volar's own capture has the mic open, and
    ///     back to `false` once it closes;
    /// (2) `kAudioObjectPropertyElementMain` is the correct element constant for this SDK/
    ///     deployment target (macOS 14) — older code used the now-deprecated
    ///     `kAudioObjectPropertyElementMaster`, functionally equivalent, in case this doesn't
    ///     compile as written.
    static func isMicrophoneInUseSystemWide() -> Bool {
        guard let deviceID = defaultInputDeviceID() else { return false }
        return isDeviceRunningSomewhere(deviceID)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func isDeviceRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &isRunning
        )
        guard status == noErr else { return false }
        return isRunning != 0
    }
}
