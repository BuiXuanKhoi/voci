// Sources/App/AppState.swift — central @Observable app state (frozen API, spec §4)
import AppKit
import Foundation
import Network
import Observation
import UserNotifications
import VolarCore

/// WG-C (FR-020 gap fix): posted by `ReminderScheduler.handleAction` (`Sources/Reminders/
/// ReminderScheduler.swift`) right after a notification action mutates `TaskStore` state (e.g. the
/// "Done" action's `store.toggle(...)`), since that path deliberately bypasses `AppState` entirely
/// (FR-014/015/016 forbid a notification action from touching the app window/state directly).
/// `VolarApp.swift` observes this and calls `AppState.refreshFromStore()` so `tasks` — and
/// `MenuBarLabel.activeTask`, derived from it — catch back up without the app needing to be
/// foregrounded first.
extension Notification.Name {
    static let volarTasksDidChange = Notification.Name("volarTasksDidChange")
}

/// Ambient visual mode — mirrors the prototype's `ambient` prop
/// ('none' | 'rain' | 'snow' | 'embers' | 'custom') from `volar-ambient.jsx`.
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

/// How reminders are delivered (Phase 4 contract B): the visual `UNUserNotificationCenter`
/// notification always fires; this only gates the ADDITIONAL spoken channel
/// (`VoiceReminderChannel`, sibling-owned). Persisted under `AppState.voiceDeliveryModeKey` — the
/// exact seam `ReminderScheduler`/`VoiceReminderChannel` are expected to read directly from
/// `UserDefaults`, since the frozen `ReminderScheduler.init(store:voice:gate:)` takes no policy
/// parameter (read out-of-band rather than injected).
enum VoiceDeliveryMode: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case visualOnly, visualPlusVoice, voiceOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .visualOnly: return "Visual only"
        case .visualPlusVoice: return "Visual + voice"
        case .voiceOnly: return "Voice only"
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
    /// Mi-1 (constitution II): `ParsedTask.followUpReview` used to materialize a second `.review`
    /// task in `confirmSave` with no confirm-card representation at all — an unconfirmed task the
    /// user never explicitly saw or could dismiss. This chip makes it visible and dismissible like
    /// every other attribute, defaulting ON (dismissing it is the exception, not the rule) but
    /// removable before Save.
    case followUpReview
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
    /// T074 (conflict advisory, `contracts/phase4-contract.md` §C/§E): computed ONCE, right when
    /// this draft is created from a fresh parse (`AppState.runParse`) — never recomputed per chip
    /// edit (self-review "performance"). Empty = clean capture; `PopoverView` renders AT MOST the
    /// first entry as a single calm line. Never re-derived at Save time either: the advisory is
    /// informational only and never blocks/gates `confirmSave()` (constitution II — never
    /// auto-act on it).
    var conflicts: [VolarCore.TaskConflict] = []
    /// User tapped the advisory row to dismiss it (glance-and-dismiss, same one-way convention as
    /// every other chip on this card — see `PopoverView.conflictAdvisoryRow`). Never re-surfaces
    /// within this confirm session; recording again starts fresh, same as every other draft field.
    var conflictDismissed: Bool = false
}

// MARK: - Phase 5 (T036): voice-done confirm state (contract A `VoiceDoneIntent`/`VoiceMatch`)

/// Which voice-done intent (contract A) a `VoiceDoneConfirm` answers — mirrors
/// `VoiceDoneIntent`'s two actionable cases (`.notACompletion` never reaches this type; it falls
/// straight through to the ordinary capture flow in `finishRecording` instead).
enum VoiceDoneAction: Sendable, Equatable {
    case complete
    case clearExternal
}

/// The pending glance-and-dismiss confirm for a `.complete`/`.clearExternal` voice-done match
/// (constitution II: never silently complete/clear a task — always surfaced here for an explicit
/// tap first). One candidate -> `PopoverView` renders a single one-tap/one-word confirm; several
/// -> a bounded disambiguation list (the defensive cap is applied where this is constructed, in
/// `presentVoiceDoneConfirm` below — self-review "client-exploit").
struct VoiceDoneConfirm: Identifiable, Equatable {
    let id = UUID()
    let action: VoiceDoneAction
    let candidates: [VoiceMatch]
}

@Observable
@MainActor
final class AppState {
    // MARK: - Frozen §4 stored state

    var tasks: [TaskItem]
    var accent: VolarAccent
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
    /// T036: populated INSTEAD OF `confirmDrafts` when `finishRecording` classifies the transcript
    /// as `.complete`/`.clearExternal` (contract A) — routes to a distinct one-tap/disambiguation
    /// card in `PopoverView` rather than the normal parsed-task confirm card. `nil` = no voice-done
    /// confirm pending. Additive state (not part of the frozen §4 surface), mutually exclusive
    /// with `confirmDrafts` (a given `finishRecording` call populates at most one of the two).
    var voiceDoneConfirm: VoiceDoneConfirm?
    /// T036: set INSTEAD OF `voiceDoneConfirm` when a done/clear phrasing was detected but ZERO
    /// candidates matched (constitution II: state it, never guess) — holds the original transcript
    /// so `captureVoiceDoneAsNewTask()` can resume it into the normal capture flow. `nil` = not
    /// showing the "no matching task" row.
    var voiceDoneNoMatchTranscript: String?
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

    // MARK: - Phase 4: reminder / voice-delivery / triage settings (contract E)

    /// Persisted (`voiceDeliveryModeKey`); default `.visualPlusVoice` per contract B.
    private(set) var voiceDeliveryMode: VoiceDeliveryMode
    /// Persisted (`globalReminderPolicyKey`); default `ReminderPolicy.defaultPolicy`.
    private(set) var globalReminderPolicy: ReminderPolicy
    /// FR-018 weekly triage: task id -> instant last explicitly "kept" via `triageKeep(_:)`, so
    /// `staleTasks` doesn't immediately re-offer something the user just decided to keep. Falls
    /// back to `createdAt` for any task never explicitly kept (best available staleness proxy —
    /// see `staleTasks`'s doc comment for the full seam note). Lightly persisted so a relaunch
    /// mid-week doesn't lose "just kept" state.
    private var triageKeptAt: [UUID: Date]

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
    /// T034/FR-018: the weekly stale-task triage batch card (`TriageView`, sibling-owned §D).
    /// `VolarApp`'s main-window `.task` gates setting this `true` to once per ISO week (mirrors
    /// `frogLastShown`'s once-per-day pattern) and only when `staleTasks` is non-empty — this flag
    /// itself carries no additional gating so previews/tests can drive it directly.
    var showTriage = false
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
    /// T036 (phase5-contract.md §C, contract A `VoiceDone`, `Sources/Speech/VoiceDone.swift`,
    /// sibling-owned — landed). Pure/stateless matcher; constructed once here like every other
    /// collaborator on this line.
    private let voiceDone = VoiceDone()
    /// The `SpeechEngine` actually driving the in-flight (or most recent) capture, so
    /// `stopCapture`/`cancelCapture`/`confirmSave` can address whichever engine `startCapture`
    /// routed to instead of hardcoding `speech`.
    private var runningEngine: SpeechEngine?

    // MARK: - Phase 4: reminder subsystem (contract A/B, sibling-owned types) — constructed once
    // here at init so the whole app shares one instance. `store` may be `nil` (container-init
    // failure degrades gracefully — see `VolarApp.init`'s doc comment), so `scheduler` is optional
    // too rather than requiring a non-optional `TaskStore` the app doesn't always have.
    // `voiceChannel`/`reminderGate` are unconditional (they don't need a store) so Settings/other
    // call sites can always reach them even in the no-store fallback.
    let voiceChannel: VoiceReminderChannel
    let reminderGate: ReminderContextGate
    let scheduler: ReminderScheduler?

    // MARK: - Ambient background persistence (UserDefaults; Settings → Appearance)

    private static let ambientKey = "volar.ambient"
    private static let customImageKey = "volar.customImageURL"
    private static let allowServerRecognitionKey = "volar.allowServerRecognition"
    private static let recognitionLocaleKey = "volar.recognitionLocale"
    private static let speechEngineKey = "volar.speechEngine"
    /// One-time cloud-parse consent. `fileprivate` (not `private`) so `DefaultCloudParseGate`
    /// (bottom of this file) can read the same key from `isOptedIn()`.
    fileprivate static let cloudParseConsentKey = "volar.cloudParseConsent"
    /// Phase 4 (T033): `static`/internal, NOT `private` — this is the exact key
    /// `ReminderScheduler`/`VoiceReminderChannel` (contract A/B, `Sources/Reminders/**`,
    /// sibling-owned) are expected to read directly, since their frozen inits take no policy
    /// parameter. Raw values match `VoiceDeliveryMode`'s cases exactly.
    static let voiceDeliveryModeKey = "volar.voiceDeliveryMode"
    /// Same seam as above, for the global default `ReminderPolicy` (used when a task has no
    /// `reminderOverride`) — JSON-encoded `ReminderPolicy` (`Recurrence.swift`).
    static let globalReminderPolicyKey = "volar.globalReminderPolicy"
    /// FR-018 weekly triage "keep" bookkeeping — see `triageKeptAt`'s doc comment. Local to this
    /// file; no sibling reads this one.
    private static let triageKeptAtKey = "volar.triageKeptAt"

    init(
        store: TaskStore? = nil,
        tasks: [TaskItem]? = nil,
        accent: VolarAccent = .indigo,
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
        self.voiceDeliveryMode = VoiceDeliveryMode(
            rawValue: UserDefaults.standard.string(forKey: Self.voiceDeliveryModeKey) ?? ""
        ) ?? .visualPlusVoice
        if let policyData = UserDefaults.standard.data(forKey: Self.globalReminderPolicyKey),
           let decodedPolicy = try? JSONDecoder().decode(ReminderPolicy.self, from: policyData) {
            self.globalReminderPolicy = decodedPolicy
        } else {
            self.globalReminderPolicy = .defaultPolicy
        }
        if let raw = UserDefaults.standard.dictionary(forKey: Self.triageKeptAtKey) as? [String: Double] {
            self.triageKeptAt = raw.reduce(into: [:]) { partial, pair in
                guard let id = UUID(uuidString: pair.key) else { return }
                partial[id] = Date(timeIntervalSince1970: pair.value)
            }
        } else {
            self.triageKeptAt = [:]
        }
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
        // Phase 4 (T033): construct the reminder subsystem once `self.store` (assigned at the
        // very top of this init) is settled. `self.voice` is safe to read here even though it
        // isn't assigned inside this init body — like every other stored property with a default
        // expression (`let voice = VoicePlayback()`), it's already initialized as part of this
        // instance's construction before any of this init's own statements run.
        self.voiceChannel = VoiceReminderChannel(playback: self.voice)
        self.reminderGate = ReminderContextGate()
        // M-1 (constitution I): wire the one cheaply-detectable, no-extra-entitlement signal this
        // file has direct access to — our own `AmbientSound` instance's public `isPlaying` flag —
        // so a voice reminder never talks over ambient sound already playing. Mic contention is
        // already wired unconditionally inside `ReminderContextGate` itself
        // (`AVCaptureDevice.isInUseByAnotherApplication`); DND/screen-share have no public,
        // unprivileged API on macOS (see `ReminderContextGate.swift`'s own doc comment) and are
        // deliberately left non-suppressing rather than failing the whole gate open silently.
        // // UNVERIFIED: this only covers OUR OWN ambient playback, not other apps' audio in
        // general (no public system-wide "is any app playing audio" API without an entitlement)
        // — calendar-busy (P3) + call/mic remain the real guards for that case.
        self.reminderGate.isOtherAudioPlaying = { [weak self] in self?.ambientSound.isPlaying ?? false }
        if let store {
            let realScheduler = ReminderScheduler(store: store, voice: self.voiceChannel, gate: self.reminderGate)
            self.scheduler = realScheduler
        } else {
            self.scheduler = nil
        }
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

    /// THE integration point with feature 001 (VolarCore nextTask engine): recomputed from the
    /// live `tasks` snapshot on every access, so there is no cached "active" state that can drift
    /// out of sync with `tasks`.
    var activeTask: TaskItem? {
        let engineTasks = tasks.map { $0.snapshot() }
        guard let winner = VolarCore.nextTask(from: engineTasks, now: clock(), calendar: .current) else { return nil }
        return tasks.first { $0.id == winner.id }
    }

    // MARK: - Task CRUD

    func addTask(_ t: TaskItem) {
        let before = tasks
        tasks.insert(t, at: 0)
        store?.add(t)
        // WG-1 (constitution IV): every newly created dated task must actually get its reminders
        // scheduled — a no-op for an undated task (`ReminderRecord.derive` returns empty).
        scheduler?.scheduleReminders(taskId: t.id)
        notifyEligibilityAndScheduleResurface(before: before, now: clock())
    }

    /// Mirrors `volar-mac.jsx`'s `toggleTask`: marking a task done always bumps it to `.later`
    /// (it leaves "Now"); un-marking it leaves the `when` bucket untouched.
    ///
    /// Store-backed path: `TaskStore.toggle` owns strictly more than a plain status flip
    /// (recurrence reset-in-place, parent auto-complete cascade, `CompletionEvent` append — see
    /// `TaskStore.toggle`'s doc comment), so after it runs, `tasks` is refreshed wholesale from
    /// the store instead of hand-patched, keeping the store as the single source of truth for the
    /// UI. No-store fallback (previews/tests without a `TaskStore`) keeps the old in-memory-only
    /// behavior.
    ///
    /// T037 (phase5-contract.md §C, FR-020): THIS is the one consolidated completion+advance
    /// funnel every reachable completion source routes through — the plain UI toggle (its own
    /// original caller), `confirmVoiceDone`'s `.complete` case (T036), and `sweepComplete` (T038)
    /// all call this method directly rather than each re-implementing store.toggle + refresh +
    /// reminder-cancel + eligibility-diff. The single atomic `tasks = store.fetchAll()` assignment
    /// below is what gives `MenuBarLabel.activeTask` (a computed property re-deriving
    /// `VolarCore.nextTask` from `tasks` on every read) its "no intermediate empty/list state"
    /// property for free — there is no separate cached "active task" to go stale in between.
    /// KNOWN GAP (self-review "conflict", flagged rather than fixed — `Sources/Reminders/**` is
    /// out of this task's 5 owned files): `ReminderScheduler.handleAction` (the notification
    /// "Done" action) calls `store.toggle(...)` DIRECTLY, bypassing this method entirely, by
    /// design (FR-014/015/016: notification actions must never open/touch the app window). While
    /// the main window is open, that leaves `AppState.tasks` briefly stale until some other
    /// mutation refreshes it — `MenuBarLabel` isn't wrong forever, just not instantly live for
    /// that one background source. Fixing it needs a hook in `VolarApp.swift` (e.g. refresh
    /// `tasks` on window-foreground/menu-open), which is also outside this task's 3 owned files.
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
        let before = tasks
        let now = clock()
        store.toggle(id, now: now)
        tasks = store.fetchAll()
        // WG-2 (constitution IV): a backgrounded reminder delivery bypasses `willPresent`, so a
        // completed/archived task must have its outstanding reminders actively cancelled here
        // rather than relying solely on the fire-time fresh-reload suppression. The flip side also
        // applies: `TaskStore.toggle` can REOPEN a task (un-marking done) or reset a recurring
        // task back to `.todo` in place with a fresh deadline — either way it needs its reminders
        // re-derived, not left cancelled.
        if let toggled = tasks.first(where: { $0.id == id }) {
            if toggled.status == .done || toggled.status == .archived {
                scheduler?.cancelReminders(taskId: id)
            } else {
                scheduler?.scheduleReminders(taskId: id)
            }
        }
        notifyEligibilityAndScheduleResurface(before: before, now: now)
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
        let now = clock()
        // `TaskStore.delete` already computes its own before/after `eligibilityDiff` internally
        // (stripping this id from every other task's `.taskDone` conditions first) — reuse that
        // result directly instead of recomputing the same diff a second time here (self-review
        // "performance": exactly one `eligibilityDiff` per mutation).
        let newlyEligible = store.delete(id, now: now)
        tasks = store.fetchAll()
        // WG-2 (constitution IV): cascade cancellation — a deleted task's reminders must never
        // orphan-fire (the fresh-reload guard in `evaluate(_:snapshot:)` treats "not found" as
        // "nothing to show," but the durable rows/system requests should still be reaped promptly
        // rather than waiting for the next due-but-missed sweep).
        scheduler?.cancelReminders(taskId: id)
        if !newlyEligible.isEmpty {
            scheduler?.notifyUnblocked(taskIds: newlyEligible)
        }
        scheduleNextResurface(from: tasks.map { $0.snapshot() }, now: now)
    }

    /// WG-C (FR-020 gap fix): `ReminderScheduler.handleAction`'s notification "Done" action calls
    /// `store.toggle(...)` directly rather than routing through this file's `toggleDone` funnel (by
    /// design — FR-014/015/016 forbid the notification path from touching the app/AppState
    /// directly). That leaves `tasks` — and therefore `MenuBarLabel.activeTask`, which re-derives
    /// `VolarCore.nextTask` from `tasks` on every read — stale until some other mutation happens to
    /// refresh it. `ReminderScheduler` now posts `.volarTasksDidChange` after any such store
    /// mutation; `VolarApp.swift` observes it and calls this to catch `tasks` back up. Mirrors the
    /// exact `tasks = store.fetchAll()` refresh every other store-backed mutation above already
    /// does — no-op (not an error) when there's no store, same as every other no-store fallback in
    /// this file.
    func refreshFromStore() {
        guard let store else { return }
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
        voiceDoneConfirm = nil
        voiceDoneNoMatchTranscript = nil
        captureErrorDetail = nil
        pendingServerConsent = false
        pendingCloudConsent = false
        pendingParseTranscript = nil
        captureSession += 1
        let session = captureSession
        let engine = selectedEngine
        runningEngine = engine
        // Kick off recognition. Must qualify `_Concurrency.Task` because `import VolarCore` brings
        // in `VolarCore.Task` (the engine's model struct), which shadows `Swift.Task` in this file.
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
            captureErrorDetail = "Dictation is off, so Volar can't recognize speech on-device. Turn on Dictation (System Settings ▸ Keyboard) to keep everything private and offline — or use Apple's servers, which needs internet and sends your audio to Apple."
            print("[Volar.Speech] onError -> onDeviceUnavailable (needs Dictation or server consent)")
            captureState = .error
            return
        }
        let detail = (error as? SpeechCaptureError).map(Self.describe) ?? error.localizedDescription
        captureErrorDetail = detail
        print("[Volar.Speech] onError -> \(detail)")
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
        voiceDoneConfirm = nil
        voiceDoneNoMatchTranscript = nil
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
        // T036 (phase5-contract.md §C): classify BEFORE treating this as new-task capture.
        // `voiceDoneOpenTasks` is rebuilt fresh from the live `tasks` snapshot on every call (never
        // cached) so a completion classified here always reflects the CURRENT open-task list, and
        // is always exactly the user's own tasks (self-review "security" — no cross-user/global
        // data reaches `VoiceDone`).
        switch voiceDone.classify(transcript, openTasks: voiceDoneOpenTasks) {
        case .complete(let candidates):
            presentVoiceDoneConfirm(action: .complete, candidates: candidates)
        case .clearExternal(let candidates):
            presentVoiceDoneConfirm(action: .clearExternal, candidates: candidates)
        case .notACompletion:
            // Existing Phase-3 new-task confirm flow, unchanged.
            proceedToCapture(transcript: transcript)
        }
    }

    /// The pre-existing Phase-3 new-task confirm flow (one-time cloud-parse consent gate ->
    /// `runParse`), split out of `finishRecording` so `captureVoiceDoneAsNewTask()` (the "no
    /// matching task, capture instead" escape hatch, T036) can resume the SAME transcript through
    /// the exact same gate rather than duplicating it.
    private func proceedToCapture(transcript: String) {
        guard cloudParseConsent != nil else {
            // Never asked: pause for the consent sheet instead of parsing yet. Reuses the same
            // `.error`-state-as-consent-prompt pattern as `pendingServerConsent` above (see
            // `PopoverView.errorActionsRow`) rather than adding a new `CaptureState` case (frozen
            // §4 enum).
            pendingParseTranscript = transcript
            pendingCloudConsent = true
            captureErrorDetail = "Volar can parse on-device for free, or use a cloud AI for trickier phrasing. Cloud parsing sends only the TEXT of what you said (never audio) to our server — see contracts/parse-proxy.md."
            captureState = .error
            return
        }
        runParse(transcript: transcript)
    }

    // MARK: - T036: voice-done confirm (contract A/C)

    /// T036 (contract A `VoiceDoneTask`): id/title + each task's UNSATISFIED `.external`
    /// descriptions only (a satisfied one is nothing left for a "client đã ký"-style utterance to
    /// clear). Rebuilt fresh from `openTasks` every `finishRecording` call.
    private var voiceDoneOpenTasks: [VoiceDoneTask] {
        openTasks.map { task in
            VoiceDoneTask(
                id: task.id,
                title: task.title,
                externalDescriptions: task.conditions.compactMap { condition in
                    if case .external(let description, let satisfied) = condition, !satisfied { return description }
                    return nil
                }
            )
        }
    }

    /// Routes a `.complete`/`.clearExternal` classification into the glance-and-dismiss confirm
    /// surface — one confident candidate -> one-tap/one-word confirm; several -> a bounded
    /// disambiguation list (constitution II: multiple matches ALWAYS disambiguate, never guess);
    /// ZERO -> STATE "no matching task" and offer capture instead (never silently fall through to
    /// a guess, and never silently fall through to new-task capture either — the user must
    /// explicitly choose that). `captureState = .parsed` reuses the existing non-idle/non-error
    /// state; `PopoverView` gates its OWN voice-done card on `voiceDoneConfirm`/
    /// `voiceDoneNoMatchTranscript` being non-nil rather than on this state value, so this is just
    /// "not idle, not error, not recording" bookkeeping consistent with the rest of the enum.
    private func presentVoiceDoneConfirm(action: VoiceDoneAction, candidates: [VoiceMatch]) {
        guard !candidates.isEmpty else {
            voiceDoneNoMatchTranscript = liveTranscript
            captureState = .parsed
            return
        }
        // Defensive cap (self-review "client-exploit"): disambiguation stays bounded even against
        // a hostile/corrupted matcher result — mirrors `runParse`'s own defense-in-depth cap.
        voiceDoneConfirm = VoiceDoneConfirm(action: action, candidates: Array(candidates.prefix(10)))
        captureState = .parsed
    }

    /// User tapped the one-tap confirm, or picked one candidate from the disambiguation list.
    /// `.complete` routes through `toggleDone` — the SAME funnel every other completion source
    /// uses (T037/FR-020: one consolidated completion+advance path, no divergent refresh logic) —
    /// which already appends the `CompletionEvent`, cancels reminders, and refreshes `tasks`
    /// atomically so `MenuBarLabel`'s `activeTask` advances with no intermediate empty/list state.
    /// `.clearExternal` clears the condition instead (never a completion — no `CompletionEvent`),
    /// per the contract's explicit "or clear the `.external` condition" wording.
    func confirmVoiceDone(taskId: UUID) {
        guard let confirm = voiceDoneConfirm else { return }
        let action = confirm.action
        // Cleared FIRST — mirrors `finishSaveUI`'s "empty the source of truth before the async
        // tail" convention, so a stray double-tap on the (about-to-vanish) confirm button can't
        // re-fire this (self-review "client-exploit": completion is idempotent — once cleared,
        // there is no pending confirm left for a second tap to act on).
        voiceDoneConfirm = nil
        switch action {
        case .complete:
            toggleDone(taskId)
        case .clearExternal:
            clearExternalCondition(taskId: taskId, now: clock())
        }
        finishVoiceDoneUI(action: action)
    }

    /// Glance-and-dismiss "not this" / cancel — leaves every task untouched (constitution II: a
    /// declined confirm must never partially act). Also used as the no-match row's "Dismiss".
    func dismissVoiceDoneConfirm() {
        captureSession += 1
        voiceDoneConfirm = nil
        voiceDoneNoMatchTranscript = nil
        captureState = .idle
        liveTranscript = ""
        runningEngine?.stop()
        runningEngine = nil
    }

    /// The "no matching task" escape hatch (constitution II: zero matches states it, then offers
    /// capture — never guesses). Resumes the original transcript through the exact same
    /// consent-gated path a normal `.notACompletion` capture would take.
    func captureVoiceDoneAsNewTask() {
        guard let transcript = voiceDoneNoMatchTranscript else { return }
        voiceDoneNoMatchTranscript = nil
        proceedToCapture(transcript: transcript)
    }

    /// T036 `.clearExternal`: clears the FIRST unsatisfied `.external` condition on `taskId` — see
    /// `TaskStore.clearFirstExternalCondition`'s doc comment for why "first" (contract A's
    /// `VoiceMatch` only resolves to a task id, not which specific external description matched).
    /// Mirrors `deleteTask`'s pattern of reusing the store's own already-computed eligibility diff
    /// instead of a second `notifyEligibilityAndScheduleResurface` pass (self-review "performance").
    private func clearExternalCondition(taskId: UUID, now: Date) {
        guard let store else {
            // No-store fallback (previews/tests without a TaskStore) — mirrors `triageDefer`'s own
            // no-store branch: in-memory only, no eligibility/reminder side effects to drive.
            guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
            guard let conditionIndex = tasks[index].conditions.firstIndex(where: {
                if case .external(_, let satisfied) = $0 { return !satisfied }
                return false
            }), case .external(let description, _) = tasks[index].conditions[conditionIndex] else { return }
            tasks[index].conditions[conditionIndex] = .external(description: description, satisfied: true)
            return
        }
        let newlyEligible = store.clearFirstExternalCondition(on: taskId, now: now)
        tasks = store.fetchAll()
        // WG-1: this task's own condition state just changed — re-derive its reminders, same as
        // `triageDefer` does after adding a condition.
        scheduler?.scheduleReminders(taskId: taskId)
        if !newlyEligible.isEmpty {
            scheduler?.notifyUnblocked(taskIds: newlyEligible)
        }
        scheduleNextResurface(from: tasks.map { $0.snapshot() }, now: now)
    }

    /// Shared "flash a result + auto-dismiss" tail for `confirmVoiceDone` — mirrors
    /// `finishSaveUI`'s timing/guard convention exactly (900ms flash, `captureSession`-guarded so a
    /// superseded flash never clobbers a fresh capture already in flight).
    private func finishVoiceDoneUI(action: VoiceDoneAction) {
        captureState = .done
        runningEngine?.stop()
        voice.speak(action == .complete ? "Done." : "Cleared.")
        captureSession += 1
        let session = captureSession
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.captureSession == session, self.captureState == .done else { return }
            self.captureState = .idle
            self.liveTranscript = ""
        }
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
            // T074: conflict advisory computed ONCE per parse, right here — never per keystroke/
            // per chip-edit (self-review "performance"). `conflictNow` is a single fresh clock
            // read shared by every draft in the batch so a multi-task confirm scores consistently
            // against the same "now" instant.
            let conflictNow = self.clock()
            self.confirmDrafts = capped.map { parsed in
                var draft = self.preResolveConditions(ConfirmDraft(task: parsed))
                draft.conflicts = self.computeConflicts(for: draft, now: conflictNow)
                return draft
            }
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

    /// T074: dismisses the (at most one) conflict advisory line for one draft — never re-derives
    /// or re-runs `conflicts(...)`; just stops rendering it, exactly like every other chip's
    /// dismiss (constitution II — this is the user acting, not the system auto-modifying).
    func dismissConflictAdvisory(forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].conflictDismissed = true
    }

    /// Constitution V / FR-044: every chip edit is logged locally (never egressed) as the signal
    /// for improving parsing over time. Goes through `TaskStore.recordCorrection` (added
    /// alongside this task, since `ParseCorrectionLog.record` — the real T026 API,
    /// `Volar/Sources/Model/ParseCorrection.swift` — needs a `ModelContext` this file has no other
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
        case .followUpReview: return "\(task.followUpReview)"
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
        // T031: snapshot taken BEFORE this batch materializes, so the eligibility diff below sees
        // exactly what this save changed (and nothing from a concurrent mutation elsewhere, since
        // this whole method runs synchronously on @MainActor).
        let before = tasks

        var itemsToSave: [TaskItem] = []
        for draft in confirmDrafts {
            let item = materialize(draft, now: now)
            itemsToSave.append(item)
            // Mi-1: the "+ review after done" chip is dismissible (defaults on, per
            // `ChipKind.followUpReview`'s doc comment) — only materialize the derived `.review`
            // task when the user hasn't dismissed it.
            if draft.task.followUpReview, !draft.dismissed.contains(.followUpReview) {
                itemsToSave.append(materializeFollowUpReview(for: item, now: now))
            }
        }

        guard let store else {
            // No-store fallback (previews/tests without a TaskStore) — mirrors `addTask`'s own
            // no-store branch: in-memory only, no validation (there is no store to validate against).
            tasks.insert(contentsOf: itemsToSave.reversed(), at: 0)
            notifyEligibilityAndScheduleResurface(before: before, now: now)
            scheduleRemindersForSavedItems(itemsToSave) // no-op: `scheduler` is nil without a store
            finishSaveUI(titles: itemsToSave.map(\.title))
            return
        }

        // M-1: a `followUpReview` draft appends a SECOND item (the derived `.review` task), so
        // `itemsToSave.count` can exceed `TaskStore.maxBatchSize` even though the parse itself
        // stayed within the FR-012 ≤10-PARSED-tasks cap (e.g. 6 parsed tasks each with a
        // follow-up review = 12 items). `addBatch` throws `.batchTooLarge` above that limit, so a
        // single call here would make an otherwise-valid parse unsaveable. Splitting into
        // sequential ≤`maxBatchSize` chunks — each committed via its own `addBatch` call, in
        // order — fixes that without raising the parse cap itself. Order is preserved across
        // chunks, so a parent always commits at or before the chunk containing its dependent
        // review: if a chunk boundary falls between them, the parent's chunk has already `save()`d
        // by the time the review's chunk builds its `allEngineSnapshot()`, so the review's
        // `.taskDone(parent.id)` condition still validates correctly.
        let chunks = stride(from: 0, to: itemsToSave.count, by: TaskStore.maxBatchSize).map {
            Array(itemsToSave[$0..<min($0 + TaskStore.maxBatchSize, itemsToSave.count)])
        }

        do {
            for chunk in chunks {
                try store.addBatch(chunk)
            }
            // Phase-2 refresh-from-store convention (auto-advance + menu bar stay correct).
            tasks = store.fetchAll()
            notifyEligibilityAndScheduleResurface(before: before, now: now)
            scheduleRemindersForSavedItems(itemsToSave)
            finishSaveUI(titles: itemsToSave.map(\.title))
        } catch {
            // Cycle rejection / batch-too-large / any other `TaskStoreError` surfaces its
            // human-readable message instead of crashing; `confirmDrafts` is left intact so the
            // user can adjust (e.g. drop a condition) and retry rather than losing the capture.
            // A failure on a LATER chunk (after earlier chunks already committed) is refreshed
            // from the store here too, so the UI never shows stale/duplicate state for the part
            // that did save — the user only re-confirms what's genuinely still outstanding.
            tasks = store.fetchAll()
            notifyEligibilityAndScheduleResurface(before: before, now: now)
            scheduleRemindersForSavedItems(itemsToSave)
            captureErrorDetail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            captureState = .error
        }
    }

    /// WG-1 (constitution IV): schedules reminders for exactly the drafts that actually made it
    /// into `tasks` — filtering against the just-refreshed `tasks` snapshot (rather than assuming
    /// every item in `items` saved) so a partial-chunk failure in `confirmSave`'s catch branch
    /// never schedules a reminder for a task that was never actually persisted.
    private func scheduleRemindersForSavedItems(_ items: [TaskItem]) {
        guard let scheduler else { return }
        let savedIds = Set(tasks.map(\.id))
        for item in items where savedIds.contains(item.id) {
            scheduler.scheduleReminders(taskId: item.id)
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

    /// Resolves `task.conditions` into `VolarCore.Condition`s per the contract: `.afterDate`/
    /// `.external` map directly once past the same uncertain-accept gate as scalar attributes;
    /// `.taskDone` only ever comes from `resolvedTaskDone` (confident fuzzy match or explicit
    /// picker choice — `preResolveConditions`/`resolveTaskDone`), so an unresolved one is simply
    /// absent here, i.e. DROPPED rather than guessed (constitution II).
    private func resolvedConditions(_ draft: ConfirmDraft) -> [VolarCore.Condition] {
        var result: [VolarCore.Condition] = []
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

    // MARK: - Focus session (mirrors `volar-mac.jsx`'s startFocus/endFocus/completeFocusTask)

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
        // Mirrors `readDay` in volar-mac.jsx: announces open task count + up to 3 titles, or
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
    /// mirrors `volar-mac.jsx`'s single-frog invariant.
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

    // MARK: - Phase 4: eligibility auto-unblock + afterDate resurface (T031/T032, FR-015/FR-017)

    /// One monotonic guard for the local resurface-refresh continuation in `scheduleNextResurface`
    /// below — mirrors `captureSession`'s pattern: every mutation recomputes the next resurface
    /// date, so a still-pending sleep from an earlier (now-superseded) computation must not fire.
    private var resurfaceSession = 0

    /// Shared tail for every real task mutation (T031): diffs eligibility across the snapshot
    /// just before/after the mutation and notifies the scheduler once per newly-unblocked task
    /// (FR-015), then recomputes the next `.afterDate` resurface (FR-017/T032). Centralizing this
    /// here — rather than repeating the diff+notify+reschedule sequence at every call site — keeps
    /// every mutation path honest as more get added. `deleteTask` is the one exception: it reuses
    /// `TaskStore.delete`'s own already-computed diff instead of calling this (self-review
    /// "performance": exactly one `eligibilityDiff` per mutation, never two).
    ///
    /// NOTE (self-review "conflict"): the task brief describes this as
    /// `VolarCore.eligibilityDiff(before:after:now:calendar:)`; the actual landed signature in
    /// `VolarCore/Sources/VolarCore/Snapshots.swift` is `eligibilityDiff(before:after:now:)` — no
    /// `calendar` parameter. This wiring follows the real, already-compiled signature.
    private func notifyEligibilityAndScheduleResurface(before: [TaskItem], now: Date) {
        let beforeSnapshot = before.map { $0.snapshot() }
        let afterSnapshot = tasks.map { $0.snapshot() }
        let newlyEligible = VolarCore.eligibilityDiff(before: beforeSnapshot, after: afterSnapshot, now: now)
        if !newlyEligible.isEmpty {
            scheduler?.notifyUnblocked(taskIds: newlyEligible)
        }
        scheduleNextResurface(from: afterSnapshot, now: now)
    }

    /// T032/FR-017: finds the earliest strictly-future `.afterDate` across the CURRENT snapshot
    /// (pure `VolarCore.nextResurfaceDate`), tells the durable scheduler about it (contract A), and
    /// ALSO arms a local one-shot continuation so the menu bar (`activeTask`, derived from `tasks`)
    /// updates the instant it passes even while the app stays running and nothing else happens to
    /// touch `tasks` in the meantime. This is NOT polling — a single scheduled continuation per
    /// mutation, invalidated by `resurfaceSession` the moment a later mutation supersedes it, not
    /// a repeating timer/re-check loop.
    private func scheduleNextResurface(from snapshot: [VolarCore.Task], now: Date) {
        resurfaceSession += 1
        let session = resurfaceSession
        guard let date = VolarCore.nextResurfaceDate(in: snapshot, after: now) else { return }
        // `nextResurfaceDate` only returns the winning `Date`, not which task owns it — recover
        // the owner by re-scanning for the first task carrying that exact date (deterministic:
        // same snapshot, same earliest-date rule `nextResurfaceDate` itself applies).
        guard let taskId = snapshot.first(where: { task in
            task.conditions.contains { condition in
                if case .afterDate(let d) = condition { return d == date }
                return false
            }
        })?.id else { return }
        scheduler?.scheduleResurface(at: date, taskId: taskId)

        // Defensive cap (self-review "client-exploit"): a corrupted/hostile store could carry an
        // absurd far-future `.afterDate`; clamp the LOCAL convenience wake so `UInt64(seconds *
        // 1e9)` can never come close to overflowing. The durable scheduler above already has the
        // real, un-clamped date — this only bounds the optional live-refresh nicety.
        let delaySeconds = min(max(date.timeIntervalSince(now), 0), 60 * 60 * 24 * 365 * 5)
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self, self.resurfaceSession == session else { return }
            if let store = self.store {
                self.tasks = store.fetchAll()
            } else {
                // No store to refresh from (previews/tests) — still nudge Observation so any
                // observer recomputing `activeTask` at this instant actually re-renders.
                self.tasks = self.tasks
            }
        }
    }

    // MARK: - Phase 4: capture-time conflict advisory (T074, FR-011c)

    /// Builds the throwaway `VolarCore.Task` `conflicts(forAdding:...)` needs, from exactly the
    /// same resolved/dismissed/accepted state `materialize`/`resolvedConditions` would use, so the
    /// advisory reflects what would ACTUALLY be saved — not the raw unconfirmed parse. Never
    /// persisted; reuses `draft.id` (a `Swift.UUID`, collision-safe) as the candidate's id purely
    /// as a stable placeholder. `busyIntervals: []` until the P3 calendar integration lands
    /// (contract C); `frogId` comes from today's frog if one is set, else `nil`.
    private func computeConflicts(for draft: ConfirmDraft, now: Date) -> [VolarCore.TaskConflict] {
        let deadline = resolvedValue(draft.task.deadline, kind: .deadline, draft: draft)
        let estimate = resolvedValue(draft.task.estimateMinutes, kind: .estimate, draft: draft)
        let priorityInt = resolvedValue(draft.task.priority, kind: .priority, draft: draft)
        let candidate = VolarCore.Task(
            id: draft.id,
            title: draft.task.title,
            status: .todo,
            priority: priorityInt,
            deadline: deadline,
            conditions: resolvedConditions(draft),
            estimateMinutes: estimate,
            parentId: nil,
            createdAt: now
        )
        return VolarCore.conflicts(
            forAdding: candidate,
            into: tasks.map { $0.snapshot() },
            now: now,
            calendar: .current,
            busyIntervals: [],
            frogId: frogTask?.id
        )
    }

    // MARK: - Phase 4: weekly stale-task triage (T034, FR-018)

    private static let staleThreshold: TimeInterval = 7 * 24 * 60 * 60
    private static let triageDeferInterval: TimeInterval = 3 * 24 * 60 * 60

    /// Open tasks eligible for the weekly triage batch (`TriageView`, sibling-owned §D): untouched
    /// for at least `staleThreshold`.
    ///
    /// NOTE (self-review "conflict"/seam, flagged in this task's final report): there is no
    /// `lastTouchedAt`/staleness field on `TaskItem`/`VolarTask` today — `TaskItem.swift` isn't one
    /// of this task's 5 owned files, so adding one is out of scope here. `createdAt` is used as
    /// the best available proxy for "untouched," and `triageKeep(_:)` below tracks an explicit
    /// "kept" instant in `triageKeptAt` (this file only) so a kept task doesn't immediately
    /// re-qualify. A real per-task `lastTouchedAt` (bumped on any edit) would be materially more
    /// accurate and is a good follow-up.
    var staleTasks: [TaskItem] {
        let cutoff = clock().addingTimeInterval(-Self.staleThreshold)
        return openTasks.filter { (triageKeptAt[$0.id] ?? $0.createdAt) <= cutoff }
    }

    /// Triage "Keep": no destructive/creative side effect on the task itself — just resets this
    /// task's staleness clock so it doesn't reappear in next week's batch.
    func triageKeep(_ item: TaskItem) {
        triageKeptAt[item.id] = clock()
        persistTriageKeptAt()
    }

    /// Triage "Break down": opens the existing breakdown sheet.
    ///
    /// NOTE (self-review "conflict"/seam, flagged in final report): the current `TaskBreakdownView`
    /// sheet (mounted in `VolarApp.swift`, pre-existing Phase-3 wiring, `backlog.md` ~line 50) has
    /// no per-task target yet — it always shows its fixed sample content regardless of which task
    /// triggered it, exactly like the existing context-menu "Break down into steps…" entry point.
    /// This reuses that same limitation rather than fixing it (fixing it touches
    /// `TaskBreakdownView.swift`, not one of this task's 5 owned files).
    func triageBreakdown(_ item: TaskItem) {
        showBreakdown = true
    }

    /// Triage "Defer": adds a `.afterDate` condition `triageDeferInterval` out, matching FR-017's
    /// resurface mechanism exactly — a deferred task automatically resurfaces (no polling) once
    /// that date passes, same as any other `.afterDate` task.
    func triageDefer(_ item: TaskItem) {
        let now = clock()
        guard let store else {
            if let index = tasks.firstIndex(where: { $0.id == item.id }) {
                tasks[index].conditions.append(.afterDate(now.addingTimeInterval(Self.triageDeferInterval)))
            }
            return
        }
        let before = tasks
        try? store.addCondition(.afterDate(now.addingTimeInterval(Self.triageDeferInterval)), to: item.id)
        tasks = store.fetchAll()
        // WG-1: re-derive this task's reminders (deadline/condition state just changed).
        scheduler?.scheduleReminders(taskId: item.id)
        notifyEligibilityAndScheduleResurface(before: before, now: now)
    }

    /// Triage "Drop": a plain delete — same path (and same FR-015 re-eligibility notification) as
    /// any other task deletion.
    func triageDrop(_ item: TaskItem) {
        deleteTask(item.id)
    }

    private func persistTriageKeptAt() {
        let raw = Dictionary(uniqueKeysWithValues: triageKeptAt.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) })
        UserDefaults.standard.set(raw, forKey: Self.triageKeptAtKey)
    }

    // MARK: - Phase 5 (T038): evening sweep (contract B `SweepView`, sibling-owned, landed)

    /// Drives `SweepView`'s presentation — mirrors `VolarApp.swift`'s `showTriage` pattern
    /// (day-gated flag owned here, actual `.sheet` mount point lives in `VolarApp.swift`). WG-A/B
    /// ship-blocker fix: now actually mounted + triggered there (see `VolarApp.swift`'s main-window
    /// `.sheet`/`.task`) — was previously wired here but never surfaced.
    var showSweep = false

    private static let sweepLastShownDayKey = "volar.sweepLastShownDay"

    /// `SweepView.items`: "today's open/in-progress tasks" (contract B) — MINORS fix: was
    /// `nowTasks` only, which silently dropped every `.later`-bucket open task from the evening
    /// sweep. `openTasks` (`nowTasks + laterTasks`) is this app's full still-open set, matching the
    /// contract's "today's open/in-progress tasks" wording without inventing a narrower notion of
    /// "today" than the rest of the app already uses.
    var sweepItems: [TaskItem] { openTasks }

    /// T038: once-daily schedule (ISO-day gate, mirroring `VolarApp.swift`'s `frogLastShown`/
    /// `triageLastShownWeek` `@AppStorage` pattern — kept here as plain `UserDefaults` instead
    /// since `AppState` isn't a `View` and every other persisted setting in this file already uses
    /// `UserDefaults` directly, e.g. `triageKeptAt`/`voiceDeliveryMode`), skip-if-empty
    /// (`sweepItems.isEmpty` — `SweepView` itself also self-guards on an empty `items` as a second
    /// line of defense per its own doc comment).
    ///
    /// WG-A/B ship-blocker fix: `VolarApp.swift`'s main-window `.task` now calls this (gated to
    /// evening hours ≥18:00 at that call site — this method itself only self-gates on ISO-day +
    /// non-empty `sweepItems`) and mounts a `.sheet` presenting `SweepView` bound to `showSweep`,
    /// mirroring `showTriage`'s exact shape:
    /// ```swift
    /// appState.maybeShowEveningSweep()
    /// ```
    /// ```swift
    /// .sheet(isPresented: Binding(
    ///     get: { appState.showSweep },
    ///     set: { presented in if !presented { appState.dismissSweep() } }
    /// )) {
    ///     SweepView(
    ///         items: appState.sweepItems,
    ///         onComplete: { appState.sweepComplete($0) },
    ///         onSkip: { appState.sweepSkip($0) },
    ///         onDismiss: { appState.dismissSweep() }
    ///     )
    ///     .environment(appState)
    ///     .frame(minWidth: 560, minHeight: 480)
    /// }
    /// ```
    func maybeShowEveningSweep() {
        let day = Self.isoDayKey(from: clock())
        guard UserDefaults.standard.string(forKey: Self.sweepLastShownDayKey) != day, !sweepItems.isEmpty else { return }
        showSweep = true
        UserDefaults.standard.set(day, forKey: Self.sweepLastShownDayKey)
    }

    /// POSIX/Gregorian day key, identical formula to `VolarApp.swift`'s own `day` computation (so
    /// the two stay in lockstep) — duplicated locally rather than shared across files since this
    /// task can't touch `VolarApp.swift` to extract a common helper.
    private static func isoDayKey(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// `SweepView.onComplete`: one-tap complete, routed through the SAME funnel as every other
    /// completion (T037) — `toggleDone` (store.toggle + `CompletionEvent` + refresh + auto-advance,
    /// so `MenuBarLabel` advances immediately even while the sweep card stays open for the rest of
    /// the batch).
    func sweepComplete(_ item: TaskItem) {
        toggleDone(item.id)
    }

    /// `SweepView.onSkip`: no-op — "Skip" means "didn't get to it today," carried over silently
    /// (FR-036/constitution V: never destructive, never a silent completion, no shame styling).
    /// Named explicitly (rather than leaving `VolarApp.swift`'s future sheet wiring pass an inline
    /// `{ _ in }`) so this seam is documented and independently testable.
    func sweepSkip(_ item: TaskItem) {
        // Intentionally empty — see doc comment above.
    }

    /// `SweepView.onDismiss`: closes the sweep card ("Done for today").
    func dismissSweep() {
        showSweep = false
    }

    /// Voice answering during the sweep (contract C: "nice-to-have; the one-tap path is the
    /// requirement"). Deliberately NOT a separate sweep-specific mic/parallel `VoiceDone` path:
    /// the ⌃⌥M hotkey / popover mic keep working exactly as they always do while `showSweep` is
    /// true, so "xong cái A" during a sweep flows through the SAME T036
    /// `finishRecording` -> `presentVoiceDoneConfirm` -> `confirmVoiceDone` -> `toggleDone` pipeline
    /// as any other voice-done completion — which already refreshes `tasks` atomically, so
    /// `sweepItems` (read live by whatever mounts `SweepView`) drops the just-completed item on its
    /// own. No extra wiring needed here beyond what T036 already provides.

    // MARK: - Phase 4: settings (T033 VoiceDeliveryMode + global ReminderPolicy)

    /// Persists the delivery-mode choice at the exact key `voiceDeliveryModeKey` documents
    /// `ReminderScheduler`/`VoiceReminderChannel` are expected to read.
    func setVoiceDeliveryMode(_ mode: VoiceDeliveryMode) {
        voiceDeliveryMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.voiceDeliveryModeKey)
    }

    /// Persists the global default `ReminderPolicy` at `globalReminderPolicyKey`.
    func setGlobalReminderPolicy(_ policy: ReminderPolicy) {
        globalReminderPolicy = policy
        if let data = try? JSONEncoder().encode(policy) {
            UserDefaults.standard.set(data, forKey: Self.globalReminderPolicyKey)
        }
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
        // T033 (constitution IV): rebuild the reminder heap from durable storage on every
        // launch — no reminder may exist only in memory. Sleep/wake recovery is handled by
        // `VolarApp.swift`'s `.onReceive(NSWorkspace.shared.notificationCenter.publisher(for:
        // .didWakeNotification))`, which calls `scheduler?.rebuildFromStorage()` directly on wake
        // (m-2: `ReminderScheduler.init` used to register its OWN wake observer, but on the wrong
        // notification center — `NotificationCenter.default` instead of
        // `NSWorkspace.shared.notificationCenter`, where `didWakeNotification` actually posts —
        // so it never fired; that dead observer has been deleted from `ReminderScheduler.swift`,
        // leaving `VolarApp.swift`'s correct path as the only wake trigger).
        scheduler?.rebuildFromStorage()
        // CB-1: `ReminderScheduler` self-assigns as `UNUserNotificationCenter.current().delegate`
        // inside its own `init` (`ReminderScheduler.swift`) — there is no separate
        // `ReminderNotificationDelegate` type for this file to construct/assign (that symbol was
        // referenced here but never defined anywhere in the codebase; removed rather than
        // resurrected, per this fix's instruction). Reassigning it a second time here would only
        // double-assign the same delegate, so this call is deleted, not replaced.
        offerRescheduleForOverdueTasks(now: clock())
    }

    // MARK: - Phase 4: overdue-reschedule scan (WG-3, FR-016)

    /// FR-016: on launch, offer a reschedule nudge once per overdue open task — deduped against
    /// any already-outstanding resurface/reschedule record for that task so a re-run of this scan
    /// doesn't pile up a second offer on top of one the user hasn't acted on yet (`offsetKind ==
    /// "resurface"` covers both `scheduleResurface`'s FR-017 afterDate path and
    /// `offerReschedule`'s own records — either way, an outstanding one already covers this task).
    ///
    /// // UNVERIFIED / known gap: this is only reachable from `activateServices()` (launch).
    /// `VolarApp.swift`'s wake handler calls `scheduler?.rebuildFromStorage()` directly rather than
    /// routing back through `AppState` (see that file's own comment on the wake path), and
    /// `VolarApp.swift` is outside this fix's 5 owned files — so a wake-triggered rescan for
    /// newly-overdue tasks isn't wired. Flagged for whoever next touches `VolarApp.swift`'s wake
    /// observer, not written to `backlog.md` per this task's own "do not edit backlog" constraint.
    private func offerRescheduleForOverdueTasks(now: Date) {
        guard let scheduler else { return }
        for task in openTasks {
            guard let deadline = task.deadline, deadline < now else { continue }
            let alreadyOutstanding = scheduler.recordsForTask(task.id).contains {
                $0.offsetKind == "resurface" && $0.state != "satisfied"
            }
            guard !alreadyOutstanding else { continue }
            scheduler.offerReschedule(taskId: task.id)
        }
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
        monitor.start(queue: DispatchQueue(label: "volar.cloudParseGate.reachability"))
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
