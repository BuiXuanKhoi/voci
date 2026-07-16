// Sources/Speech/VoicePlayback.swift — AVSpeechSynthesizer wrapper (readDay, voice feedback)
import AVFoundation

/// Wraps `AVSpeechSynthesizer` for spoken feedback — mirrors `volarSpeak`/`volarStopSpeak` in
/// `volar-ambient.jsx` plus the `readDay` behavior from `volar-mac.jsx`.
@MainActor
final class VoicePlayback {
    private let synthesizer = AVSpeechSynthesizer()

    /// `volarSpeak(text)`. The JS prototype sets `utterance.rate = 1.03` against the Web Speech
    /// API's "1.0 is normal" scale. `AVSpeechUtterance.rate` instead uses a 0...1 scale where
    /// `AVSpeechUtteranceDefaultSpeechRate` (~0.5) is "normal" — so rather than reusing `1.03` as
    /// an absolute value (which would read as near-fastest on this scale), this carries over the
    /// prototype's *relative* +3% bump on top of the natural default rate.
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.03
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }

    /// `volarStopSpeak()`.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Mirrors `volar-mac.jsx`'s `readDay`: announces the open-task count and up to the first 3
    /// titles, or "All clear" when there is nothing open.
    ///
    /// NOTE: `AppState.readDayAloud()` (`Sources/App/AppState.swift`) is currently an empty stub.
    /// Per the Phase-2 brief, wiring it up is Phase-3 work: the app-assembly step should give
    /// `AppState` (or its owner) a `VoicePlayback` instance and have `readDayAloud()` call
    /// `voicePlayback.readDay(self)`. Not done here so this file doesn't reach into `AppState`'s
    /// frozen §4 stored-property list.
    func readDay(_ appState: AppState) {
        let open = appState.openTasks
        guard !open.isEmpty else {
            speak("All clear. Nothing scheduled.")
            return
        }
        let upNext = open.prefix(3).map(\.title).joined(separator: ", ")
        let taskWord = open.count == 1 ? "task" : "tasks"
        speak("You have \(open.count) open \(taskWord). Up next: \(upNext).")
    }
}
