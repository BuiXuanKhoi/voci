// Sources/App/AppState.swift — central @Observable app state (frozen API, spec §4)
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

    // MARK: - Ambient background persistence (UserDefaults; Settings → Appearance)

    private static let ambientKey = "voci.ambient"
    private static let customImageKey = "voci.customImageURL"

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
        self.tasks = tasks ?? store?.loadOrSeed() ?? SampleData.tasks
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
    }

    // MARK: - Derived task groupings

    var nowTasks: [TaskItem] { tasks.filter { !$0.done && $0.when == .now } }
    var laterTasks: [TaskItem] { tasks.filter { !$0.done && $0.when == .later } }
    var doneTasks: [TaskItem] { tasks.filter(\.done) }
    var openTasks: [TaskItem] { nowTasks + laterTasks }
    var frogTask: TaskItem? { tasks.first { $0.frog && !$0.done } }

    /// THE integration point with feature 001 (VociCore nextTask engine): recomputed from the
    /// live `tasks` snapshot on every access, so there is no cached "active" state that can drift
    /// out of sync with `tasks`.
    var activeTask: TaskItem? {
        let engineTasks = tasks.map { $0.toEngineTask() }
        guard let winner = VociCore.nextTask(from: engineTasks, now: clock()) else { return nil }
        return tasks.first { $0.id == winner.id }
    }

    // MARK: - Task CRUD

    func addTask(_ t: TaskItem) {
        tasks.insert(t, at: 0)
        store?.add(t)
    }

    /// Mirrors `voci-mac.jsx`'s `toggleTask`: marking a task done always bumps it to `.later`
    /// (it leaves "Now"); un-marking it leaves the `when` bucket untouched.
    func toggleDone(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let wasDone = tasks[index].done
        tasks[index].status = wasDone ? .todo : .done
        if !wasDone {
            tasks[index].when = .later
        }
        store?.toggle(id)
    }

    func deleteTask(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        store?.delete(id)
    }

    // MARK: - Capture / popover flow
    // CaptureState walks: .idle -> .recording -> .parsing -> .parsed -> .saving -> .done (or .error)

    func startCapture() {
        captureState = .recording
        liveTranscript = ""
        parsed = nil
        // Kick off on-device recognition. Must qualify `_Concurrency.Task` because
        // `import VociCore` brings in `VociCore.Task` (the engine's model struct), which
        // shadows `Swift.Task` in this file. Explicitly hopping back onto @MainActor is
        // still intentional (matches AmbientSound.rampVolume's convention elsewhere).
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.speech.requestAuthorization() {
                self.speech.onFinal = { [weak self] transcript in self?.finishRecording(transcript: transcript) }
                self.speech.onError = { [weak self] _ in self?.captureState = .error }
                self.speech.start(onPartial: { [weak self] partial in self?.liveTranscript = partial })
            } else {
                self.captureState = .error
            }
        }
    }

    func cancelCapture() {
        captureState = .idle
        liveTranscript = ""
        parsed = nil
        speech.stop()
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
            priority: parsed.priority,
            status: .todo,
            deadline: nil,
            dependsOn: [],
            createdAt: clock(),
            when: .now,
            durationMinutes: parsed.durationMinutes,
            frog: false
        )
        addTask(item)
        captureState = .done
        self.parsed = nil
        speech.stop()
        if voiceFeedback {
            voice.speak("Added. \(item.title).")
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
                dependsOn: [],
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

    /// Starts the global ⌃⌥Space hold-to-talk hotkey. `HotkeyManager.start` already calls
    /// `appState.startCapture()` directly on key-down (see `Sources/Speech/HotkeyManager.swift`),
    /// so `onKeyDown` is intentionally omitted here to avoid double-invoking `startCapture()`;
    /// only `onKeyUp` is wired, to stop the in-flight `SpeechCapture` session. Safe to call even
    /// without Accessibility permission — `HotkeyManager` degrades to local-only monitoring.
    func activateServices() {
        hotkey.start(appState: self, onKeyUp: { [weak self] in self?.speech.stop() })
    }
}
