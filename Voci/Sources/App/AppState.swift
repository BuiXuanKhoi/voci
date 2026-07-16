// Sources/App/AppState.swift — central @Observable app state (frozen API, spec §4)
import AppKit
import Foundation
import Network
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

/// One attribute a confirm-card chip governs (T024). Deliberately narrower than `ParsedTask`'s
/// full field list — `title`/`notes`/`subtasks` have no chip (title is the always-shown headline,
/// notes/subtasks aren't part of the v2 chip set per the contract's "Confirm + materialize"
/// section) and `conditions` are tracked separately (`dismissedConditions`/`acceptedConditions`/
/// `resolvedTaskDone`, keyed by index, since a task can carry several).
enum ChipKind: String, CaseIterable, Hashable, Sendable {
    case deadline, estimate, priority, reminder, recurrence, kind
}

/// One confirmed task's editable confirm-card state, layered OVER a router-parsed `ParsedTask`
/// (the sibling-owned contract type, never mutated in place) so every chip edit is reversible
/// before Save and `ParsedTask` itself stays exactly what the parser/router produced. This is
/// UI/materialization-only state; `AppState.confirmSave()` reads it to decide what actually gets
/// persisted (see `resolvedValue`/`resolvedConditions`).
struct ConfirmDraft: Identifiable, Equatable {
    let id = UUID()
    var task: ParsedTask
    /// Scalar attribute chips the user explicitly removed — dismissed attributes are never saved,
    /// regardless of confidence (constitution II: dismiss always wins).
    var dismissed: Set<ChipKind> = []
    /// Scalar attribute chips that were uncertain (<0.7) and the user explicitly tapped to accept
    /// — required before an uncertain value is ever committed (constitution II).
    var accepted: Set<ChipKind> = []
    /// `task.conditions` indices the user removed (dismissed chip, or "Skip" in the taskDone picker).
    var dismissedConditions: Set<Int> = []
    /// `task.conditions` indices for non-taskDone conditions (afterDate/external) that were
    /// uncertain (<0.7) and explicitly accepted — same gate as `accepted` above, per-condition.
    var acceptedConditions: Set<Int> = []
    /// `task.conditions` indices of `.taskDone` cases resolved to a REAL existing task id — either
    /// a confident (>=0.7 parser-confidence) fuzzy title match, or the user's explicit picker
    /// choice. Never populated by a guess below that bar (constitution II) — an unresolved
    /// `.taskDone` is simply absent here and gets dropped at save, not committed.
    var resolvedTaskDone: [Int: UUID] = [:]
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
    /// Up to 10 (`TaskStore.maxBatchSize`) confirm-card drafts from the last parse — replaces the
    /// v1 single `ParsedTask?` now that one utterance can yield a compound/multi-task result
    /// (contract "Confirm + materialize": multi-task confirm, ≤10). Empty = nothing to confirm.
    var confirmDrafts: [ConfirmDraft] = []
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
    /// One-time cloud-parse privacy opt-in (T024/contract R5): `nil` = never asked. Persisted so
    /// the decision survives relaunch; a decline is permanent (never asked again, never routes to
    /// Cloud) until the user changes it in Settings. Read by `DefaultCloudParseGate.isOptedIn()`
    /// below — the REAL seam with `IntentRouter` is that injected `CloudParseGate` protocol
    /// (`Sources/Parsing/IntentParsing.swift`, landed), not a convention this file has to guess at.
    private(set) var cloudParseConsent: Bool?
    /// Drives the popover's one-time cloud-parse consent row (mirrors `pendingServerConsent`'s
    /// reuse of the `.error` capture state for a non-error consent prompt).
    private(set) var pendingCloudConsent = false
    /// The transcript awaiting a decision in `pendingCloudConsent`, resumed by `resolveCloudConsent`.
    private var pendingParseTranscript: String?

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

    /// Replaces the v1 `NLParser` direct call (contract "Confirm + materialize" / T025: "Replace
    /// any v1 direct-HeuristicNLParser call with the router"). `IntentRouter` is owned by the
    /// T019 agent (`Sources/Parsing/IntentParsing.swift`, landed) — constructed with its own
    /// defaults for `foundationModel`/`heuristic`, but wired here with a real `cloudGate:`
    /// (`DefaultCloudParseGate`, defined at the bottom of this file) so the one-time consent
    /// decision this file owns (`cloudParseConsent`/`resolveCloudConsent`) actually reaches the
    /// router. `cloud:` is left at its own default (`nil`) — a working `CloudParser` needs a real
    /// `ParseCredentialProvider` (StoreKit paid JWS + `DeviceCheckProvider.swift`'s free-tier
    /// token composed together), which is explicitly "NOT built in `CloudParser.swift`" and isn't
    /// part of this task's scope (T051 StoreKit is Phase 8, not yet landed) — Cloud is
    /// consequently inert today (FM -> Heuristic only) regardless of consent; the gate is wired
    /// correctly for the moment that composite exists. See this task's final report for the
    /// backlog note.
    private let router: IntentRouter
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
    /// One-time cloud-parse consent. `fileprivate` (not `private`) so `DefaultCloudParseGate`
    /// (bottom of this file) can read the same key from `isOptedIn()`.
    fileprivate static let cloudParseConsentKey = "voci.cloudParseConsent"

    init(
        store: TaskStore? = nil,
        tasks: [TaskItem]? = nil,
        accent: VociAccent = .indigo,
        density: Density = .comfy,
        glass: GlassLevel = .standard,
        ambient: AmbientMode = .none,
        customImageURL: URL? = nil,
        voiceFeedback: Bool = false,
        router: IntentRouter = IntentRouter(cloudGate: DefaultCloudParseGate()),
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
        self.cloudParseConsent = UserDefaults.standard.object(forKey: Self.cloudParseConsentKey) as? Bool
        self.voiceFeedback = voiceFeedback
        self.captureState = .idle
        self.liveTranscript = ""
        self.confirmDrafts = []
        self.focusActive = false
        self.focusPaused = false
        self.focusSecondsLeft = 25 * 60
        self.focusIndex = 0
        self.router = router
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
        confirmDrafts = []
        captureErrorDetail = nil
        pendingServerConsent = false
        pendingCloudConsent = false
        pendingParseTranscript = nil
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
        confirmDrafts = []
        pendingCloudConsent = false
        pendingParseTranscript = nil
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
    ///
    /// T025: routes the parse itself through `IntentRouter` (replaces the v1 direct
    /// `HeuristicNLParser` call) — gated by the one-time cloud-parse consent sheet (T024) the
    /// FIRST time this ever runs, per contract R5 ("Cloud ... IF: user opted in").
    func finishRecording(transcript: String) {
        liveTranscript = transcript
        guard cloudParseConsent != nil else {
            // Never asked: pause for the consent sheet instead of parsing yet. Reuses the same
            // `.error`-state-as-consent-prompt pattern as `pendingServerConsent` above (see
            // `PopoverView.errorActionsRow`) rather than adding a new `CaptureState` case (frozen
            // §4 enum).
            pendingParseTranscript = transcript
            pendingCloudConsent = true
            captureErrorDetail = "Voci can parse on-device for free, or use a cloud AI for trickier phrasing. Cloud parsing sends only the TEXT of what you said (never audio) to our server — see contracts/parse-proxy.md."
            captureState = .error
            return
        }
        runParse(transcript: transcript)
    }

    /// User answered the one-time cloud-parse consent sheet (`PopoverView`'s consent row).
    /// Persists the decision (decline ⇒ never asked again, never routes to Cloud — see
    /// `cloudParseConsent`'s doc comment for the seam note with `IntentRouter`) and resumes the
    /// transcript that was waiting on it, if any (a cancel in the meantime already cleared it).
    func resolveCloudConsent(allow: Bool) {
        cloudParseConsent = allow
        UserDefaults.standard.set(allow, forKey: Self.cloudParseConsentKey)
        pendingCloudConsent = false
        guard let transcript = pendingParseTranscript else { return }
        pendingParseTranscript = nil
        runParse(transcript: transcript)
    }

    /// The actual `IntentRouter.parse` call, split out of `finishRecording` so the one-time
    /// consent gate above can defer it. Builds up to `TaskStore.maxBatchSize` `ConfirmDraft`s and
    /// pre-resolves the "easy" `.taskDone` conditions (parser-confidence >= 0.7 AND a confident
    /// fuzzy title match) so the confirm card doesn't show a picker for those — anything left
    /// unresolved is exactly the < 0.7 / no-match case constitution II requires a picker for
    /// (`PopoverView`'s `dependencyPicker`).
    private func runParse(transcript: String) {
        captureState = .parsing
        captureSession += 1
        let session = captureSession
        let now = clock()
        let titles = openTasks.map(\.title)
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let results = await self.router.parse(transcript, now: now, openTaskTitles: titles)
            // Stale? The hold ended (Esc/cancel/a second capture) while the parse was in flight —
            // mirrors `startCapture`'s authorization-pending guard.
            guard self.captureSession == session, self.captureState == .parsing else { return }
            // Defense-in-depth cap (self-review "client-exploit"): the contract promises the
            // router already enforces the 10-task cap; this survives a malformed/hostile result
            // regardless.
            let capped = Array(results.prefix(TaskStore.maxBatchSize))
            self.confirmDrafts = capped.map { self.preResolveConditions(ConfirmDraft(task: $0)) }
            if self.confirmDrafts.isEmpty {
                self.captureErrorDetail = "Didn't catch that."
                self.captureState = .error
            } else {
                self.captureState = .parsed
            }
        }
    }

    /// Auto-resolves `.taskDone` conditions the router was itself confident about (>=0.7) against
    /// a confident fuzzy title match in `openTasks` — never a guess below either bar (constitution
    /// II); anything short of both stays unresolved for `PopoverView`'s picker.
    private func preResolveConditions(_ draft: ConfirmDraft) -> ConfirmDraft {
        var draft = draft
        let candidates = openTasks
        for (index, condition) in draft.task.conditions.enumerated() {
            guard case .taskDone(let titleQuery, let confidence) = condition, confidence >= 0.7 else { continue }
            if let match = Self.bestFuzzyMatch(for: titleQuery, in: candidates), match.score >= 0.7 {
                draft.resolvedTaskDone[index] = match.id
            }
        }
        return draft
    }

    private struct FuzzyMatch { let id: UUID; let score: Double }

    /// Token-overlap similarity (case/diacritic-insensitive, so Vietnamese input matches
    /// sensibly): scores each open task's title against `query` as a Jaccard index over
    /// whitespace tokens, returning the single best match. O(n) over `openTasks` per condition —
    /// at most ~10 conditions in a confirm batch, so this stays cheap even at hundreds of tasks
    /// (self-review "performance"; no picker-side O(n²) — the picker itself just lists titles).
    /// // UNVERIFIED: a deliberately simple placeholder heuristic — swap for a real string-
    /// distance/fuzzy library later if parsing quality demands it (backlog candidate).
    private static func bestFuzzyMatch(for query: String, in openTasks: [TaskItem]) -> FuzzyMatch? {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return nil }
        var best: FuzzyMatch?
        for task in openTasks {
            let titleTokens = tokenize(task.title)
            guard !titleTokens.isEmpty else { continue }
            let shared = queryTokens.intersection(titleTokens).count
            let union = queryTokens.union(titleTokens).count
            guard union > 0 else { continue }
            let score = Double(shared) / Double(union)
            if score > (best?.score ?? 0) {
                best = FuzzyMatch(id: task.id, score: score)
            }
        }
        return best
    }

    private static func tokenize(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .folding(options: .diacriticInsensitive, locale: nil)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
        )
    }

    // MARK: - Confirm-card chip interactions (T024)
    //
    // Every mutation here edits a `ConfirmDraft` overlay, never the underlying `ParsedTask` (the
    // sibling-owned contract type) — see `ConfirmDraft`'s doc comment. Each is a one-way action
    // (dismissed/resolved chips disappear from the card, matching `PopoverView`'s rendering —
    // there is no re-surface-to-undo affordance within one confirm session; recording again
    // starts fresh). Every edit that actually changes what gets saved logs a `ParseCorrection`
    // (constitution V / FR-044).

    /// Removes a scalar attribute chip (deadline/estimate/priority/reminder/recurrence/kind) —
    /// it will not be saved regardless of confidence.
    func dismissAttribute(_ kind: ChipKind, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].dismissed.insert(kind)
        logCorrection(kind: kind, task: confirmDrafts[index].task, correctedValue: "dismissed")
    }

    /// Explicit tap-to-accept for an uncertain (<0.7) scalar attribute chip — required before it
    /// is ever committed (constitution II).
    func acceptUncertainAttribute(_ kind: ChipKind, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].accepted.insert(kind)
        logCorrection(kind: kind, task: confirmDrafts[index].task, correctedValue: "accepted")
    }

    /// Removes a condition (any kind) at `conditionIndex` — dropped rather than guessed
    /// (constitution II); also how the taskDone picker's "Skip" resolves.
    func dismissCondition(at conditionIndex: Int, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].dismissedConditions.insert(conditionIndex)
        confirmDrafts[index].resolvedTaskDone[conditionIndex] = nil
        logCorrection(
            kind: nil, attribute: "condition[\(conditionIndex)]",
            task: confirmDrafts[index].task, correctedValue: "dropped"
        )
    }

    /// Explicit tap-to-accept for an uncertain (<0.7) `.afterDate`/`.external` condition chip.
    /// `.taskDone` never uses this path — it always resolves via `resolveTaskDone` (picker or
    /// confident fuzzy match), never a bare accept, per constitution II's explicit picker
    /// requirement for dependencies.
    func acceptUncertainCondition(at conditionIndex: Int, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].acceptedConditions.insert(conditionIndex)
        logCorrection(
            kind: nil, attribute: "condition[\(conditionIndex)]",
            task: confirmDrafts[index].task, correctedValue: "accepted"
        )
    }

    /// The dependency picker's resolution (constitution II: NEVER auto-attach below 0.7 — the
    /// user always makes this choice explicitly). `taskID == nil` drops the condition (picker's
    /// "Skip — no dependency").
    func resolveTaskDone(at conditionIndex: Int, to taskID: UUID?, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        if let taskID {
            confirmDrafts[index].resolvedTaskDone[conditionIndex] = taskID
            confirmDrafts[index].dismissedConditions.remove(conditionIndex)
        } else {
            confirmDrafts[index].dismissedConditions.insert(conditionIndex)
        }
        logCorrection(
            kind: nil, attribute: "condition[\(conditionIndex)].taskDone",
            task: confirmDrafts[index].task, correctedValue: taskID?.uuidString ?? "dropped"
        )
    }

    /// Multi-task confirm (T024): removes one task from the batch entirely (the compact
    /// reviewable set's per-task "x") without discarding the rest.
    func removeDraft(_ draftID: ConfirmDraft.ID) {
        confirmDrafts.removeAll { $0.id == draftID }
    }

    /// Constitution V / FR-044: every chip edit is logged locally (never egressed) as the signal
    /// for improving parsing over time. Goes through `TaskStore.recordCorrection` (added
    /// alongside this task, since `ParseCorrectionLog.record` — the real T026 API,
    /// `Voci/Sources/Model/ParseCorrection.swift` — needs a `ModelContext` this file has no other
    /// way to reach). No-op (skipped, not crashed) in the no-store fallback used by
    /// previews/tests — logging is a best-effort local record, never load-bearing for save.
    private func logCorrection(kind: ChipKind?, attribute: String? = nil, task: ParsedTask, correctedValue: String) {
        let attributeName = attribute ?? kind?.rawValue ?? "unknown"
        store?.recordCorrection(
            attribute: attributeName,
            parsed: parsedValueDescription(kind: kind, task: task),
            corrected: correctedValue,
            transcript: task.sourceTranscript
        )
    }

    private func parsedValueDescription(kind: ChipKind?, task: ParsedTask) -> String {
        switch kind {
        case .deadline: return task.deadline.map { "\($0.value)" } ?? ""
        case .estimate: return task.estimateMinutes.map { "\($0.value)" } ?? ""
        case .priority: return task.priority.map { "\($0.value)" } ?? ""
        case .reminder: return task.reminderOverride.map { "\($0.value)" } ?? ""
        case .recurrence: return task.recurrence.map { "\($0.value)" } ?? ""
        case .kind: return task.kind.rawValue
        case nil: return "" // condition corrections describe themselves via `attribute`
        }
    }

    /// T025: materializes every confirmed draft through `TaskStore` validation (cycle rejection
    /// surfaces its human-readable message rather than crashing; the 10-task cap is enforced by
    /// `addBatch` itself). Preserves glance-and-dismiss + Enter-to-save (`PopoverView`'s
    /// `.keyboardShortcut(.defaultAction)` on the Save button, unchanged) and the frozen
    /// zero-argument signature.
    func confirmSave() {
        guard !confirmDrafts.isEmpty else { return }
        captureState = .saving
        let now = clock()

        var itemsToSave: [TaskItem] = []
        for draft in confirmDrafts {
            let item = materialize(draft, now: now)
            itemsToSave.append(item)
            if draft.task.followUpReview {
                itemsToSave.append(materializeFollowUpReview(for: item, now: now))
            }
        }

        guard let store else {
            // No-store fallback (previews/tests without a TaskStore) — mirrors `addTask`'s own
            // no-store branch: in-memory only, no validation (there is no store to validate against).
            tasks.insert(contentsOf: itemsToSave.reversed(), at: 0)
            finishSaveUI(titles: itemsToSave.map(\.title))
            return
        }

        do {
            try store.addBatch(itemsToSave)
            // Phase-2 refresh-from-store convention (auto-advance + menu bar stay correct).
            tasks = store.fetchAll()
            finishSaveUI(titles: itemsToSave.map(\.title))
        } catch {
            // Cycle rejection / batch-too-large / any other `TaskStoreError` surfaces its
            // human-readable message instead of crashing; `confirmDrafts` is left intact so the
            // user can adjust (e.g. drop a condition) and retry rather than losing the capture.
            captureErrorDetail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            captureState = .error
        }
    }

    /// One draft -> one `TaskItem`, resolving every `ParsedValue`/`ParsedCondition` per the
    /// contract's "Confirm + materialize" rules. `sourceTranscript` is ALWAYS persisted (closes
    /// the backlog item where `confirmSave` used to hardcode `deadline: nil` for voice tasks —
    /// deadlines, like every other attribute, now come resolved from `ParsedTask`).
    private func materialize(_ draft: ConfirmDraft, now: Date) -> TaskItem {
        let task = draft.task
        let deadline = resolvedValue(task.deadline, kind: .deadline, draft: draft)
        let estimate = resolvedValue(task.estimateMinutes, kind: .estimate, draft: draft)
        let priorityInt = resolvedValue(task.priority, kind: .priority, draft: draft)
        let reminder = resolvedValue(task.reminderOverride, kind: .reminder, draft: draft)
        let recurrence = resolvedValue(task.recurrence, kind: .recurrence, draft: draft)
        let kind = draft.dismissed.contains(.kind) ? .task : task.kind

        return TaskItem(
            title: task.title,
            // `details` is the voice read-back copy (`AppState.speakDetails`'s frozen-field
            // meaning, distinct from `notes` — see TaskItem.swift) — prefer explicit notes, else
            // fall back to the verbatim transcript so read-back is never empty.
            details: task.notes ?? task.sourceTranscript,
            priority: Self.uiPriority(from: priorityInt),
            status: .todo,
            deadline: deadline,
            conditions: resolvedConditions(draft),
            createdAt: now,
            when: .now,
            durationMinutes: estimate,
            frog: false,
            notes: task.notes,
            sourceTranscript: task.sourceTranscript,
            kind: kind,
            recurrence: recurrence,
            reminderOverride: reminder
        )
    }

    /// A `ParsedValue` only materializes if PRESENT, not dismissed, and either confident (>=0.7)
    /// or explicitly accepted (constitution II — never silently commit an uncertain attribute).
    private func resolvedValue<T>(_ value: ParsedValue<T>?, kind: ChipKind, draft: ConfirmDraft) -> T? {
        guard let value, !draft.dismissed.contains(kind) else { return nil }
        guard !value.isUncertain || draft.accepted.contains(kind) else { return nil }
        return value.value
    }

    /// Resolves `task.conditions` into `VociCore.Condition`s per the contract: `.afterDate`/
    /// `.external` map directly once past the same uncertain-accept gate as scalar attributes;
    /// `.taskDone` only ever comes from `resolvedTaskDone` (confident fuzzy match or explicit
    /// picker choice — `preResolveConditions`/`resolveTaskDone`), so an unresolved one is simply
    /// absent here, i.e. DROPPED rather than guessed (constitution II).
    private func resolvedConditions(_ draft: ConfirmDraft) -> [VociCore.Condition] {
        var result: [VociCore.Condition] = []
        for (index, condition) in draft.task.conditions.enumerated() {
            guard !draft.dismissedConditions.contains(index) else { continue }
            switch condition {
            case .afterDate(let date, let confidence):
                guard confidence >= 0.7 || draft.acceptedConditions.contains(index) else { continue }
                result.append(.afterDate(date))
            case .external(let description, let confidence):
                guard confidence >= 0.7 || draft.acceptedConditions.contains(index) else { continue }
                result.append(.external(description: description, satisfied: false))
            case .taskDone:
                if let resolved = draft.resolvedTaskDone[index] {
                    result.append(.taskDone(resolved))
                }
            }
        }
        return result
    }

    /// Engine `priority` is `1...4` (contract/data-model.md); the UI `Priority` enum only spans
    /// `1...3` (`TaskItem.swift`'s documented reasoning: "this app never produces those" — until
    /// now, a voice parse legitimately can). Clamp 4 into `.low` rather than crash/force-unwrap;
    /// absent/dismissed/unaccepted-uncertain priority falls back to the existing neutral default.
    private static func uiPriority(from raw: Int?) -> Priority {
        switch raw {
        case 1: return .high
        case 2: return .medium
        case 3, 4: return .low
        default: return .medium
        }
    }

    /// `followUpReview` (contract): a second `.review`-kind task depending on the just-created
    /// one via `.taskDone`. Appended immediately after its parent in `confirmSave`'s batch, so
    /// `TaskStore.addBatch`'s intra-batch snapshot (documented to grow as earlier items in the
    /// SAME batch are accepted) validates the edge without a second pass.
    private func materializeFollowUpReview(for parent: TaskItem, now: Date) -> TaskItem {
        TaskItem(
            title: "Review: \(parent.title)",
            details: "",
            priority: .medium,
            status: .todo,
            deadline: nil,
            conditions: [.taskDone(parent.id)],
            createdAt: now,
            when: .later,
            durationMinutes: nil,
            frog: false,
            sourceTranscript: parent.sourceTranscript,
            kind: .review
        )
    }

    /// Shared "Saved" flash + auto-dismiss tail for `confirmSave`'s two success paths (store /
    /// no-store fallback) — unchanged timing/guard behavior from the v1 implementation, just
    /// reading back a task-count-aware phrase for the multi-task case.
    private func finishSaveUI(titles: [String]) {
        captureState = .done
        confirmDrafts = []
        runningEngine?.stop()
        voice.speak(titles.count == 1 ? (titles.first ?? "Saved") : "\(titles.count) tasks saved.")
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

// MARK: - DefaultCloudParseGate (T024 seam: wires the one-time consent decision into `IntentRouter`)

/// `IntentRouter`'s injected `CloudParseGate` (`Sources/Parsing/IntentParsing.swift`, T019,
/// landed) — the REAL mechanism the Cloud tier is gated by, not a bare shared UserDefaults
/// convention. Deliberately a standalone type (not `AppState` itself conforming) so it can be
/// constructed as a default parameter expression in `AppState.init` before `self` exists.
///
/// `isOptedIn()` reads the exact key `AppState.resolveCloudConsent(allow:)` writes
/// (`AppState.cloudParseConsentKey`, `fileprivate` to this file) — `false` (never opted in, or
/// declined) is the safe default for an unset key, matching "decline ⇒ never cloud."
///
/// `isOnline()` is a best-effort `NWPathMonitor` snapshot. The protocol's own doc comment
/// sanctions "`true` when unknown/unable to determine" as a valid answer (it's "purely an
/// optimization ... not a security gate") — this defaults `pathSatisfied` to `true` until the
/// monitor's first callback lands, rather than blocking `isOnline()` on that first update.
/// `@unchecked Sendable`: the only mutable state (`pathSatisfied`) is lock-protected; `NWPathMonitor`
/// itself delivers `pathUpdateHandler` on an arbitrary background queue, which is exactly why the
/// lock exists instead of, say, `@MainActor`-isolating this type.
final class DefaultCloudParseGate: CloudParseGate, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var pathSatisfied = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.pathSatisfied = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "voci.cloudParseGate.reachability"))
    }

    deinit {
        monitor.cancel()
    }

    func isOptedIn() async -> Bool {
        UserDefaults.standard.bool(forKey: AppState.cloudParseConsentKey)
    }

    func isOnline() async -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pathSatisfied
    }
}
