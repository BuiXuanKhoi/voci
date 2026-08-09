// Sources/Reminders/VoiceReminderChannel.swift — spoken reminder delivery (contract §B, T072).
// Thin wrapper over the existing on-device `VoicePlayback` (AVSpeechSynthesizer,
// Sources/Speech/VoicePlayback.swift) — no network, no new audio pipeline. Constitution I: this
// entire channel is on-device speech synthesis only; nothing here ever transmits audio or text.
import Foundation

@MainActor
final class VoiceReminderChannel {
    private let playback: VoicePlayback

    init(playback: VoicePlayback) {
        self.playback = playback
    }

    /// One calm sentence, spoken immediately (interrupts any in-flight utterance — see
    /// `VoicePlayback.speak`, which itself calls `stopSpeaking(at: .immediate)` first). No
    /// urgency/alarm phrasing — matches constitution V's no-shame, glance-and-dismiss tone.
    func speak(_ text: String) {
        playback.speak(text)
    }

    /// `isSensitive == true` speaks a generic phrase and NEVER the task's title — the whole point
    /// being that a sensitive task (contract §B / `VolarTask.isSensitive`, owned by the App-wiring
    /// agent) shouldn't be read aloud where someone else might overhear it, even though the
    /// visual notification banner (which the OS — not this channel — renders) still shows it.
    func speakReminder(title: String, timing: String, isSensitive: Bool) {
        let sentence = isSensitive
            ? "You have a reminder \(timing)."
            : "\(title), \(timing)."
        speak(sentence)
    }
}
