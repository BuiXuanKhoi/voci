// Sources/App/AppState.swift — central @Observable app state (frozen API, spec §4)
import AppKit
import Foundation
import Observation
import VociCore

/// Ambient visual mode — mirrors the prototype's `ambient` prop
/// ('none' | 'rain' | 'snow' | 'embers' | 'custom') from `voci-ambient.jsx`.
/// String-backed + `CaseIterable`/`Identifiable` so Settings → Appearance can drive it straight
/// off a `Segmented<AmbientMode>` control and persist the raw value to `UserDefaults`.
enum AmbientMode: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case none, rain, snow, embers, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .rain: return "Rain"
        case .snow: return "Snow"
        case .embers: return "Fireflies"
        case .custom: return "Custom"
        }
    }
}

/// Which transcription engine drives the NEXT voice capture — the freemium speech tier picker
/// (backlog "★ KIẾN TRÚC CHỐT"). String-backed + `CaseIterable`/`Identifiable` so Settings can
/// drive it off a picker and persist the raw value to `UserDefaults`, same convention as
/// `AmbientMode` above.
enum SpeechEngineChoice: String, Sendable, Equatable, CaseIterable, Identifiable {
    case appleOnDevice, whisperKit, groq
    var id: String { rawValue }
    var label: String {
        switch self {
        case .appleOnDevice: return "Apple (on-device)"
        case .whisperKit: return "WhisperKit (on-device)"
        case .groq: return "Groq (cloud)"
        }
    }
}

@Observable
@MainActor
final class AppState {
    // MARK: - Frozen §4 stored state

    var tasks: [TaskItem]
    var accent: VociAccent
    var density: Density
    var glass: GlassLevel
    var ambient: AmbientMode
    var customImageURL: URL?
    var voiceFeedback: Bool

    // Capture / popover
    enum CaptureState: Sendable, Equatable {
        case idle, recording, parsing, parsed, saving, done, error
    }
    var captureState: CaptureState
    var liveTranscript: String
    var parsed: ParsedTask?
    private(set) var captureErrorDetail: String?
    /// User consented to Apple server-based recognition (audio leaves the Mac). Persisted.
    private(set) var allowServerRecognition: Bool
    /// Speech-recognition language, as a BCP-47/locale identifier (e.g. "en-US", "vi-VN").
    /// Persisted; applied live to `speech` via `setRecognitionLocale`.
    private(set) var recognitionLocaleID: String
    /// Which transcription engine the user picked in Settings (freemium tier). Persisted; the
    /// engine actually used for a given capture is further gated by `selectedEngine` (e.g.
    /// WhisperKit falls back to Apple when unsupported or its model isn't loaded yet).
    private(set) var speechEngineChoice: SpeechEngineChoice
    /// True when capture failed because on-device recognition is unavailable (Dictation off) and
    /// the user hasn't consented to server recognition yet — drives the popover's hint + consent UI.
    private(set) var pendingServerConsent = false

    // Focus session
    var focusActive: Bool
    var focusPaused: Bool
    var focusSecondsLeft: Int
    var focusIndex: Int

    // MARK: - Modal / banner state (Phase 3: mounts MorningFrogView / TaskBreakdownView /
    // NotificationView into the running app; not part of the frozen §4 surface, additive only).

    struct ReminderBanner: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var timing: String
    }

    var showMorningFrog = false
    var showBreakdown = false
    var reminderBanner: ReminderBanner? = nil
    /// The task currently shown in the detail sheet, by id — `nil` means the sheet is closed.
    /// Kept as an id (not a snapshot) so `detailTask` below always reflects live edits/toggles.
    var detailTaskID: UUID?

    // MARK: - Collaborators (implementation detail, not part of the frozen §4 surface)

    private let parser: NLParser
    private let store: TaskStore?
    /// Injected clock so `activeTask` stays pure/testable instead of reading the wall clock
    /// directly; defaults to the live clock so production behavior is unaffected.
    private let clock: () -> Date

    // MARK: - Phase 3: real service instances (VoicePlayback / AmbientSound / HotkeyManager /
    // SpeechCapture are all `@MainActor` classes with no-arg inits — see `Sources/Speech/*` and
    // `Sources/Audio/AmbientSound.swift`).
    let voice = VoicePlayback()
    let ambientSound = AmbientSound()
    let hotkey = HotkeyManager()
    let speech = SpeechCapture()
    /// Free on-device tier (backlog freemium split). Apple (`speech`) remains the default engine
    /// and the fallback whenever WhisperKit isn't supported/ready.
    let whisper = WhisperKitEngine()
    /// Paid cloud tier.
    let groq = GroqEngine()
    /// The `SpeechEngine` actually driving the in-flight (or most recent) capture, so
    /// `stopCapture`/`cancelCapture`/`confirmSave` can address whichever engine `startCapture`
    /// routed to instead of hardcoding `speech`.
    private var runningEngine: SpeechEngine?

    // MARK: - Ambient background persistence (UserDefaults; Settings → Appearance)

    private static let ambientKey = "voci.ambient"
    private static let customImageKey = "voci.customImageURL"
    private static let allowServerRecognitionKey = "voci.allowServerRecognition"
    private static let recognitionLocaleKey = "voci.recognitionLocale"
    private static let speechEngineKey = "voci.speechEngine"

    init(
        store: TaskStore? = nil,
        tasks: [TaskItem]? = nil,
        accent: VociAccent = .indigo,
        density: Density = .comfy,
        glass: GlassLevel = .standard,
        ambient: AmbientMode = .none,
        customImageURL: URL? = nil,
        voiceFeedback: Bool = false,
        parser: NLParser = HeuristicNLParser(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.tasks = tasks ?? store?.loadOrSeed() ?? []
        self.accent = accent
        self.density = density
        self.glass = glass
        self.ambient = ambient
        self.customImageURL = customImageURL
        // Override from persisted user choice, if any — falls back to the caller-supplied
        // defaults above (e.g. previews/tests that construct AppState directly still work).
        if let raw = UserDefaults.standard.string(forKey: Self.ambientKey), let m = AmbientMode(rawValue: raw) {
            self.ambient = m
        }
        if let p = UserDefaults.standard.string(forKey: Self.customImageKey) {
            self.customImageURL = URL(fileURLWithPath: p)
        }
        self.allowServerRecognition = UserDefaults.standard.bool(forKey: Self.allowServerRecognitionKey)
        self.recognitionLocaleID = UserDefaults.standard.string(forKey: Self.recognitionLocaleKey) ?? "en-US"
        self.speechEngineChoice = SpeechEngineChoice(rawValue: UserDefaults.standard.string(forKey: Self.speechEngineKey) ?? "") ?? .appleOnDevice
        self.voiceFeedback = voiceFeedback
        self.captureState = .idle
        self.liveTranscript = ""
        self.parsed = nil
        self.focusActive = false
        self.focusPaused = false
        self.focusSecondsLeft = 25 * 60
        self.focusIndex = 0
        self.parser = parser
        self.clock = clock
        speech.setLocale(Locale(identifier: self.recognitionLocaleID))
    }

    // MARK: - Derived task groupings

    var nowTasks: [TaskItem] { tasks.filter { !$0.done && $0.when == .now } }
    var laterTasks: [TaskItem] { tasks.filter { !$0.done && $0.when == .later } }
    var doneTasks: [TaskItem] { tasks.filter(\.done) }
    var openTasks: [TaskItem] { nowTasks + laterTasks }
    var frogTask: TaskItem? { tasks.first { $0.frog && !$0.done } }

    /// The task currently shown in the detail sheet (looked up live so edits/toggles reflect).
    var detailTask: TaskItem? { detailTaskID.flatMap { id in tasks.first { $0.id == id } } }

    /// THE integration point with feature 001 (VociCore nextTask engine): recomputed from the
    /// live `tasks` snapshot on every access, so there is no cached "active" state that can drift
    /// out of sync with `tasks`.
    var activeTask: TaskItem? {
        let engineTasks = tasks.map { $0.snapshot() }
        guard let winner = VociCore.nextTask(from: engineTasks, now: clock(), calendar: .current) else { return nil }
        return tasks.first { $0.id == winner.id }
    }

    // MARK: - Task CRUD

    func addTask(_ t: TaskItem) {
        tasks.insert(t, at: 0)
        store?.add(t)
    }

    /// Mirrors `voci-mac.jsx`'s `toggleTask`: marking a task done always bumps it to `.later`
    /// (it leaves "Now"); un-marking it leaves the `when` bucket untouched.
    ///
    /// Store-backed path: `TaskStore.toggle` owns strictly more than a plain status flip
    /// (recurrence reset-in-place, parent auto-complete cascade, `CompletionEvent` append — see
    /// `TaskStore.toggle`'s doc comment), so after it runs, `tasks` is refreshed wholesale from
    /// the store instead of hand-patched, keeping the store as the single source of truth for the
    /// UI. No-store fallback (previews/tests without a `TaskStore`) keeps the old in-memory-only
    /// behavior.
    func toggleDone(_ id: UUID) {
        guard let store else {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
            let wasDone = tasks[index].done
            tasks[index].status = wasDone ? .todo : .done
            if !wasDone {
                tasks[index].when = .later
            }
            return
        }
        store.toggle(id)
        tasks = store.fetchAll()
    }

    /// Store-backed path: `TaskStore.delete` strips the id from every other task's `.taskDone`
    /// conditions and nulls children's `parentId` (validation rule 4), so `tasks` is refreshed
    /// from the store afterward rather than just removing the one row — same rationale as
    /// `toggleDone` above. No-store fallback keeps the old in-memory-only behavior.
    func deleteTask(_ id: UUID) {
        guard let store else {
            tasks.removeAll { $0.id == id }
            return
        }
        store.delete(id)
        tasks = store.fetchAll()
    }

    // MARK: - Detail sheet (Phase 1: click a task row to see/hear its full description)

    func openDetail(_ id: UUID) { detailTaskID = id }
    func closeDetail() { detailTaskID = nil }
    /// Speaks a task's description (falls back to its title when there's no description).
    func speakDetails(of task: TaskItem) {
        voice.speak(task.details.isEmpty ? task.title : task.details)
    }

    // MARK: - Capture / popover flow
    // CaptureState walks: .idle -> .recording -> .parsing -> .parsed -> .saving -> .done (or .error)

    /// Monotonic token guarding the *deferred* part of `startCapture()`: authorization is async
    /// (first run blocks on the TCC prompt), so by the time it resolves the user may already have
    /// released the hotkey or hit Esc. Every start/stop/cancel bumps this; a pending start only
    /// proceeds if its captured token is still current — otherwise the mic would be turned on
    /// with nothing left to ever turn it off.
    private var captureSession = 0

    /// Picks the engine for the NEXT capture based on user choice, with safe fallbacks:
    /// WhisperKit only when supported AND its model is loaded, else Apple. Groq used as chosen.
    private var selectedEngine: SpeechEngine {
        switch speechEngineChoice {
        case .appleOnDevice: return speech
        case .whisperKit: return (WhisperKitEngine.isSupported && whisper.isModelReady) ? whisper : speech
        case .groq: return groq
        }
    }

    func startCapture() {
        captureState = .recording
        liveTranscript = ""
        parsed = nil
        captureErrorDetail = nil
        pendingServerConsent = false
        captureSession += 1
        let session = captureSession
        let engine = selectedEngine
        runningEngine = engine
        // Kick off recognition. Must qualify `_Concurrency.Task` because `import VociCore` brings
        // in `VociCore.Task` (the engine's model struct), which shadows `Swift.Task` in this file.
        // Explicitly hopping back onto @MainActor is still intentional (matches
        // AmbientSound.rampVolume's convention elsewhere).
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await engine.requestAuthorization()
            // Stale? The hold ended (key-up/Esc/retry) while the permission flow was in flight.
            guard self.captureSession == session, self.captureState == .recording else { return }
            guard granted else {
                self.captureErrorDetail = Self.describe(.authorizationDenied)
                self.captureState = .error
                return
            }
            engine.onFinal = { [weak self] transcript in self?.finishRecording(transcript: transcript) }
            engine.onError = { [weak self] error in self?.handleCaptureError(error) }
            // Apple-only: server-consent + (locale already applied via setRecognitionLocale).
            // WhisperKit/Groq auto-detect language, so there's nothing analogous to wire for them.
            if let apple = engine as? SpeechCapture {
                apple.allowServerFallback = self.allowServerRecognition
            }
            engine.start(onPartial: { [weak self] partial in self?.liveTranscript = partial })
        }
    }

    /// Shared `onError` handling for whichever engine `startCapture()` routed to — moved out of
    /// the closure verbatim so `startCapture` doesn't have to special-case per-engine errors.
    private func handleCaptureError(_ error: Error) {
        if case SpeechCaptureError.onDeviceUnavailable = error {
            pendingServerConsent = true
            captureErrorDetail = "Dictation is off, so Voci can't recognize speech on-device. Turn on Dictation (System Settings ▸ Keyboard) to keep everything private and offline — or use Apple's servers, which needs internet and sends your audio to Apple."
            print("[Voci.Speech] onError -> onDeviceUnavailable (needs Dictation or server consent)")
            captureState = .error
            return
        }
        let detail = (error as? SpeechCaptureError).map(Self.describe) ?? error.localizedDescription
        captureErrorDetail = detail
        print("[Voci.Speech] onError -> \(detail)")
        captureState = .error
    }

    /// Turns a `SpeechCaptureError` into a user-facing message for `captureErrorDetail` — surfaces
    /// the real failure reason instead of the generic "Didn't catch that." copy (see
    /// `PopoverView`'s `.error` state).
    private static func describe(_ e: SpeechCaptureError) -> String {
        switch e {
        case .recognizerUnavailable: return "Speech recognizer unavailable on this Mac"
        case .authorizationDenied: return "Microphone or Speech permission denied"
        case .recognitionFailed(let msg): return msg
        // The onError handler above sets a longer, actionable message for this case directly;
        // this branch only exists so the switch stays exhaustive.
        case .onDeviceUnavailable: return "On-device speech recognition is unavailable (Dictation is off)"
        }
    }

    func cancelCapture() {
        captureSession += 1 // invalidate any authorization-pending start
        captureState = .idle
        liveTranscript = ""
        parsed = nil
        runningEngine?.stop()
        runningEngine = nil
    }

    /// Stops an in-progress capture (called from `toggleCapture()`'s "stop" branch). If
    /// recognition is actually running, this just ends the utterance (`SpeechCapture.stop()`
    /// flushes one final result -> `finishRecording`). If the mic never started — authorization
    /// was still pending — it invalidates the deferred start and backs out to `.idle` so the mic
    /// is never left hot. Additive method; the frozen §4 surface (`startCapture`/`cancelCapture`)
    /// is untouched.
    func stopCapture() {
        if let engine = runningEngine, engine.isRunning {
            if !engine.supportsPartialResults { captureState = .parsing } // batch: show "working…" while it transcribes
            engine.stop()
        } else if captureState == .recording {
            captureSession += 1
            captureState = .idle
            liveTranscript = ""
        }
    }

    /// Toggle voice capture (⌃⌥M hotkey and the on-screen mic buttons use this): if we're
    /// recording, stop and let the final transcript flow into parsing; otherwise start a fresh
    /// capture. Additive — frozen §4 `startCapture`/`cancelCapture` untouched.
    func toggleCapture() {
        if captureState == .recording {
            stopCapture()
        } else {
            startCapture()
        }
    }

    /// Opens System Settings so the user can enable Dictation (which downloads the on-device
    /// speech model). Pane URL differs across macOS versions; falls back to opening System
    /// Settings generally.
    func openDictationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard"
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    /// User consented to Apple server recognition. Persist it and immediately retry capture.
    func useServerRecognition() {
        allowServerRecognition = true
        UserDefaults.standard.set(true, forKey: Self.allowServerRecognitionKey)
        pendingServerConsent = false
        startCapture()
    }

    /// Change the speech-recognition language (Settings ▸ Language). Persists and applies live.
    func setRecognitionLocale(_ id: String) {
        recognitionLocaleID = id
        UserDefaults.standard.set(id, forKey: Self.recognitionLocaleKey)
        speech.setLocale(Locale(identifier: id))
    }

    /// Change the transcription engine (Settings). Persists; picking WhisperKit on Apple Silicon
    /// kicks off the one-time model download/load so it's ready by the next capture.
    func setSpeechEngine(_ choice: SpeechEngineChoice) {
        speechEngineChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: Self.speechEngineKey)
        if choice == .whisperKit, WhisperKitEngine.isSupported {
            _Concurrency.Task { await whisper.prepare() }
        }
    }

    /// Not part of the frozen §4 method list, but required to actually drive
    /// `.recording -> .parsing -> .parsed`: Phase-2 `SpeechCapture` calls this once the
    /// on-device transcript settles. A pure addition — `startCapture`/`cancelCapture`/
    /// `confirmSave` keep their exact frozen signatures.
    func finishRecording(transcript: String) {
        liveTranscript = transcript
        captureState = .parsing
        parsed = parser.parse(transcript)
        captureState = .parsed
    }

    func confirmSave() {
        guard let parsed else { return }
        captureState = .saving
        let item = TaskItem(
            title: parsed.title,
            details: parsed.details,
            priority: parsed.priority,
            status: .todo,
            deadline: nil,
            conditions: [],
            createdAt: clock(),
            when: .now,
            durationMinutes: parsed.durationMinutes,
            frog: false
        )
        addTask(item)
        captureState = .done
        self.parsed = nil
        runningEngine?.stop()
        // Read the captured description back so the user can confirm by ear (voice-first).
        voice.speak(item.details.isEmpty ? item.title : item.details)
        // Transient "Saved" flash, then close the popover — without this the popover stayed
        // stuck on "Saved" until the user clicked the scrim. Guarded by the session token so a
        // new capture started within the window isn't dismissed by the stale timer.
        captureSession += 1
        let session = captureSession
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.captureSession == session, self.captureState == .done else { return }
            self.captureState = .idle
            self.liveTranscript = ""
        }
    }

    // MARK: - Focus session (mirrors `voci-mac.jsx`'s startFocus/endFocus/completeFocusTask)

    func startFocus() {
        focusSecondsLeft = 25 * 60
        focusPaused = false
        let openNow = openTasks
        focusIndex = openNow.firstIndex { $0.frog } ?? 0
        focusActive = true
        if voiceFeedback {
            voice.speak("Focus session started. \(frogTask?.title ?? "Twenty five minutes.")")
        }
    }

    func endFocus() {
        focusActive = false
        focusSecondsLeft = 25 * 60
        focusPaused = false
    }

    func toggleFocusPause() {
        focusPaused.toggle()
    }

    /// Completes the given task and advances the focus index, clamping into range — mirrors the
    /// prototype's `completeFocusTask`. If that was the last open task, ends the session.
    func completeFocusTask(_ id: UUID) {
        let remaining = max(openTasks.count - 1, 0)
        toggleDone(id)
        focusIndex = remaining > 0 ? max(0, min(focusIndex, remaining - 1)) : 0
        if openTasks.isEmpty {
            focusActive = false
        }
        if voiceFeedback {
            voice.speak(remaining > 0 ? "Done. \(remaining) left today." : "Done. All clear.")
        }
    }

    func readDayAloud() {
        // Mirrors `readDay` in voci-mac.jsx: announces open task count + up to 3 titles, or
        // "All clear" when empty. `VoicePlayback.readDay` reads `openTasks` off this instance.
        voice.readDay(self)
    }

    // MARK: - Ambient background controls (Settings → Appearance → Background)

    /// Sets the ambient visual mode and persists it, so it survives relaunch.
    func setAmbient(_ mode: AmbientMode) {
        ambient = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.ambientKey)
    }

    /// Sets (or clears) the custom background image and persists its path. Picking an image
    /// implicitly switches `ambient` to `.custom`, mirroring the prototype's behavior of
    /// previewing whatever image you just chose. Not sandboxed today, so a plain file path is
    /// fine; if sandboxing is ever enabled, this needs a security-scoped bookmark instead.
    func setCustomImage(_ url: URL?) {
        customImageURL = url
        if let url {
            UserDefaults.standard.set(url.path, forKey: Self.customImageKey)
            ambient = .custom
            UserDefaults.standard.set(AmbientMode.custom.rawValue, forKey: Self.ambientKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.customImageKey)
        }
    }

    // MARK: - Ambient sound (Phase 3: wires `Sources/Audio/AmbientSound.swift`)

    /// Mirrors the prototype's ambient-sound toggle button: toggles playback of whatever the
    /// current `ambient` visual mode implies (defaulting to `.rain` if no ambient mode is set,
    /// so the toolbar button always has *something* to toggle).
    func toggleAmbientSound() {
        ambientSound.toggle(ambient == .none ? .rain : ambient)
    }

    // MARK: - Frog of the day

    /// Sets `id` as the single "frog of the day", clearing the flag on every other task —
    /// mirrors `voci-mac.jsx`'s single-frog invariant.
    func setFrog(_ id: UUID) {
        for index in tasks.indices {
            tasks[index].frog = (tasks[index].id == id)
        }
    }

    // MARK: - Modal / banner actions (Phase 3)

    /// Morning-frog sheet: user picked a candidate — set it as today's frog, then dismiss.
    func pickFrog(_ id: UUID) {
        setFrog(id)
        showMorningFrog = false
    }

    /// Morning-frog sheet: "Skip today" (or answering by voice instead) — just dismiss.
    func dismissMorningFrog() {
        showMorningFrog = false
    }

    /// Task-breakdown sheet: "Save all as tasks" — persists each step title as a real `TaskItem`
    /// (medium priority, `.later`, no deadline/duration — the breakdown generator doesn't produce
    /// those yet), then dismisses.
    func saveBreakdown(_ titles: [String]) {
        for t in titles {
            addTask(TaskItem(
                id: UUID(),
                title: t,
                priority: .medium,
                status: .todo,
                deadline: nil,
                conditions: [],
                createdAt: clock(),
                when: .later,
                durationMinutes: nil,
                frog: false
            ))
        }
        showBreakdown = false
    }

    /// Menu-bar "Preview reminder": surfaces the in-app notification banner for the current
    /// `activeTask` (falling back to the artboard's sample copy when nothing is active).
    func showReminderPreview() {
        if let t = activeTask {
            reminderBanner = ReminderBanner(
                title: t.title,
                timing: t.timeBadge.map { "Coming up · \($0)" } ?? "Coming up"
            )
        } else {
            reminderBanner = ReminderBanner(
                title: "Customer call — Acme onboarding",
                timing: "In 15 minutes · 2:00 PM"
            )
        }
    }

    func dismissBanner() {
        reminderBanner = nil
    }

    // MARK: - Service activation (Phase 3: call once from the main window's `.task`)

    /// Starts the global ⌃⌥M toggle-capture hotkey. `HotkeyManager.start` already calls
    /// `appState.toggleCapture()` directly on key-down (see `Sources/Speech/HotkeyManager.swift`);
    /// toggle mode has no use for key-up, so neither `onKeyDown` nor `onKeyUp` needs wiring here.
    /// `HotkeyManager` registers the hotkey via Carbon's `RegisterEventHotKey` — a sandbox-legal
    /// Carbon Event Manager API that needs no Accessibility permission and has no local-monitor
    /// fallback path (unlike the pre-Carbon `NSEvent` monitor it replaced).
    func activateServices() {
        hotkey.start(appState: self)
    }
}
