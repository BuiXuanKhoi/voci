// Sources/App/AppState.swift — central @Observable app state (frozen API, spec §4)
import AppKit
import Foundation
import Network
import Observation
import StoreKit
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

/// Local (on-device) vs Cloud task-parsing preference — the Settings switch this feature adds.
/// A thin bridge OVER the existing one-time cloud-parse consent (`cloudParseConsent` /
/// `cloudParseConsentKey`), which already gates the router's Cloud tier via
/// `DefaultCloudParseGate.isOptedIn()`: `.cloud` == opted in, `.onDevice` == not. Keeping that key
/// as the single source of truth means the voice-capture consent popover and this Settings picker
/// can never disagree. String-backed + `CaseIterable`/`Identifiable` so Settings drives it off a
/// picker, same convention as `SpeechEngineChoice` above.
enum ParseEnginePreference: String, Sendable, Equatable, CaseIterable, Identifiable {
    case onDevice, cloud
    var id: String { rawValue }
    var label: String {
        switch self {
        case .onDevice: return "On-device (private, free)"
        case .cloud: return "Cloud AI (better quality)"
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
    /// T042 (phase6-contract.md §C, US4): "giao cho Claude rồi" / "handed to Claude" — routes
    /// through `AppState.delegateTask` via `confirmVoiceDone`, reusing the SAME one-tap confirm
    /// card `VoiceDoneConfirm` already provides rather than inventing a parallel UI surface.
    /// `checkBackMinutes` is whatever `AppState.classifyDelegationIntent` parsed out of the
    /// utterance (e.g. "check sau 10 phút"), defaulting to `DelegationTracker`'s own 10'.
    case delegate(checkBackMinutes: Int)
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
    /// Speech-recognition language, as a BCP-47/locale identifier (e.g. "en-US", "vi-VN") or the
    /// `autoRecognitionLocaleID` ("auto") sentinel for "let each engine auto-detect". Persisted;
    /// applied live to both `speech` and `groq` via `setRecognitionLocale`.
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
    /// defaults for `foundationModel`/`heuristic`, wired here with a real `cloudGate:`
    /// (`DefaultCloudParseGate`, bottom of this file) so the Local↔Cloud choice this file owns
    /// (`parseEnginePreference` / `cloudParseConsent` / `resolveCloudConsent`) reaches the router.
    /// `cloud:` is now wired with `ConfigParseCredentialProvider` (a placeholder credential source):
    /// the Cloud tier is fully connected and user-switchable from Settings, but stays inert
    /// (falls back to on-device) until a parse-proxy base URL + token are configured — "code first,
    /// key later". The real StoreKit paid-JWS + `DeviceCheckProvider.swift` free-token composite
    /// (Phase 8/T051) supersedes that placeholder when it lands.
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

    // MARK: - Account & Entitlements (specs/002-workflow-command-center/contracts/account-auth.md)
    //
    // Every property below is a `@MainActor`-observable MIRROR of `AccountService.shared`/
    // `Entitlements.shared` (both plain, non-`@MainActor` `actor`s so their networking stays off
    // the main actor per this feature's constraints) — refreshed by the methods further down
    // right after each one awaits its actor. `SettingsView`'s Account tab reads these directly
    // instead of awaiting an actor itself, matching how every other `SettingsView` tab only ever
    // touches plain `AppState` properties/methods.
    var accountEmail: String?
    var accountTier: AccountTier = .free
    var subscriptionStatus: SubscriptionStatus?
    /// Inline error text for the Account tab (Apple sign-in / OTP / purchase / delete failures).
    /// Deliberately separate from any other error surface in this file — account actions are
    /// user-initiated from Settings, not part of the capture pipeline's error states.
    var accountError: String?
    /// True while an account/entitlement network action is in flight — drives a disabled/spinner
    /// state on the Account tab's buttons so a slow network can't be raced into a double sign-in/
    /// double-purchase.
    var accountBusy = false
    /// Hydrated by `startAccountLifecycle()`/`refreshAccountState()` so `SettingsView` can show
    /// `product.displayPrice` (never a hardcoded "$6.99" — wrong in every non-US storefront).
    var monthlyProduct: Product?
    var yearlyProduct: Product?
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

    // MARK: - Phase 6 (US4): AI-delegation orchestrator subsystem (phase6-contract.md §A/§B,
    // Volar/Sources/Orchestrator/*.swift, sibling-owned/landed). `delegation`/`appLinkHandler`
    // degrade to `nil` in the no-store fallback (mirrors `scheduler` above), since
    // `DelegationTracker.init(store:)` requires a real `TaskStore` — delegation state has nowhere
    // durable to live without one. `claudeConnector` is self-contained (file I/O only, no store
    // dependency per its own doc comment), so it's always constructed.
    let delegation: DelegationTracker?
    let appLinkHandler: AppLinkHandler?
    let claudeConnector = ClaudeCodeConnector()

    /// T043: tasks whose delegated check-back came due — THE ambient menu-bar queue (constitution
    /// I: never a system notification). Refreshed by `refreshDelegationQueue()` off a minute-scale
    /// timer (`startDelegationTimer()`, started from `activateServices()`) and after any mutation
    /// that could change due-ness. `TodayView` renders this as an ordinary, dismissible in-app card.
    var dueDelegationRechecks: [UUID] = []
    /// Mirrors `AppLinkHandler.pendingDisambiguation` into an `@Observable`-tracked property —
    /// `AppLinkHandler` itself is a plain (non-`@Observable`) class per its frozen contract seam, so
    /// SwiftUI can't react to its internal mutations directly. `onAppLinkHandled()` (called from
    /// `VolarApp.swift`'s `.onOpenURL`) and `resolveAppLinkDisambiguation`/
    /// `dismissAppLinkDisambiguation` below keep this in lockstep — same bridging idiom this file
    /// already uses for `ReminderScheduler`'s out-of-band mutations (`refreshFromStore()`/
    /// `.volarTasksDidChange`).
    var pendingDisambiguationTaskIDs: [UUID] = []
    /// Bumped whenever `.onOpenURL` routes an inbound `volar://` link, purely so Settings' "Connect
    /// Claude Code" test-signal round trip (T044) can observe a real receipt instead of a fake
    /// timed flash.
    private(set) var lastAppLinkAt: Date?
    private var delegationTimer: Timer?
    /// FIX B: owns the focus-session 1s countdown — moved here from `FocusOverlay`'s own
    /// `Timer.publish`, which stopped firing the instant the overlay window closed (the menu bar's
    /// `focusSecondsLeft` readout froze and the session never auto-ended). Mirrors
    /// `delegationTimer`'s exact construction pattern (`startDelegationTimer()`) so this survives
    /// the same way regardless of which window/view is on screen. See `startFocus()`/`endFocus()`/
    /// `focusTick()`.
    private var focusTimer: Timer?

    // MARK: - Ambient background persistence (UserDefaults; Settings → Appearance)

    private static let ambientKey = "volar.ambient"
    private static let customImageKey = "volar.customImageURL"
    private static let allowServerRecognitionKey = "volar.allowServerRecognition"
    private static let recognitionLocaleKey = "volar.recognitionLocale"
    /// Sentinel value for `recognitionLocaleID` meaning "no fixed language — let each engine
    /// auto-detect": `SpeechCapture`/`WhisperKit` get `Locale.current` (the system language),
    /// `GroqEngine` gets a nil `languageCode` so `GroqTranscriptionClient` omits the `language`
    /// field entirely (Groq's own auto-detect, best for vi↔en code-switching). It's a magic string
    /// rather than making `recognitionLocaleID` optional because that property is persisted
    /// directly and used as a SwiftUI `Picker` `tag` (`SettingsView.swift`). `static`/internal (not
    /// `private`) so `SettingsView` can tag its "Automatic (multilingual)" picker row with the same
    /// constant instead of duplicating the string.
    static let autoRecognitionLocaleID = "auto"
    private static let speechEngineKey = "volar.speechEngine"

    /// Resolves the persisted `recognitionLocaleID` to a concrete `Locale` for `SpeechCapture`/
    /// `WhisperKit`: `.current` (system locale) for the `autoRecognitionLocaleID` sentinel, the
    /// literal locale otherwise (unchanged behavior for an explicit picker choice). `static` (not
    /// an instance method) so it's safe to call from `init` before `self` is fully initialized.
    private static func appleRecognitionLocale(for recognitionLocaleID: String) -> Locale {
        recognitionLocaleID == autoRecognitionLocaleID ? Locale.current : Locale(identifier: recognitionLocaleID)
    }

    /// Resolves the persisted `recognitionLocaleID` to the ISO-639-1 code `GroqEngine`/
    /// `GroqTranscriptionClient` expect in their `language` field (e.g. "vi-VN" -> "vi"). Returns
    /// `nil` for the `autoRecognitionLocaleID` sentinel (Groq auto-detects when no `language` field
    /// is sent) or if the locale identifier doesn't resolve to a known language code.
    private static func groqLanguageCode(for recognitionLocaleID: String) -> String? {
        guard recognitionLocaleID != autoRecognitionLocaleID else { return nil }
        return Locale(identifier: recognitionLocaleID).language.languageCode?.identifier
    }

    /// One-time cloud-parse consent. `fileprivate` (not `private`) so `DefaultCloudParseGate`
    /// (bottom of this file) can read the same key from `isOptedIn()`. `nonisolated` because a
    /// `static let` declared inside a `@MainActor` type inherits that isolation (only statics at
    /// global/file scope are implicitly `nonisolated`), and `DefaultCloudParseGate` is deliberately
    /// NOT main-actor-isolated — without this, `isOptedIn()` fails to compile with "main
    /// actor-isolated static property ... cannot be accessed from outside of the actor".
    fileprivate nonisolated static let cloudParseConsentKey = "volar.cloudParseConsent"
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
    /// FIX 4: `accent`/`density` used to only ever be assigned from this `init`'s parameters —
    /// there was no read-back from `UserDefaults` here (unlike every other Settings → Appearance
    /// control: `ambientKey`/`customImageKey` right above both get one) and no write anywhere
    /// either, so a real launch (`VolarApp.swift` calls `AppState(store:)` with neither parameter
    /// supplied) silently reset both to their compiled-in defaults (`.indigo`/`.comfy`) every
    /// time, discarding whatever `SettingsView` had set last session.
    private static let accentKey = "volar.accent"
    /// `Density` (Theme.swift) is NOT `RawRepresentable`/`String`-backed like `VolarAccent` is, so
    /// there's no `.rawValue` to persist directly. Rather than invent a new ad hoc encoding, this
    /// reuses the EXACT `"cozy"`/`"comfy"`/`"roomy"` string mapping `SettingsView.densityID(_:)`/
    /// `density(fromID:)` already define for its own `Segmented` binding (`SettingsView.swift`) —
    /// same values, same default-to-`.comfy` fallback — so this is the established convention,
    /// not a new one.
    private static let densityKey = "volar.density"

    init(
        store: TaskStore? = nil,
        tasks: [TaskItem]? = nil,
        accent: VolarAccent = .indigo,
        density: Density = .comfy,
        glass: GlassLevel = .standard,
        ambient: AmbientMode = .none,
        customImageURL: URL? = nil,
        voiceFeedback: Bool = false,
        router: IntentRouter = IntentRouter(
            cloud: CloudParser(credentials: ConfigParseCredentialProvider()),
            cloudGate: DefaultCloudParseGate()
        ),
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
        // FIX 4: same override convention as `ambient`/`customImageURL` immediately above —
        // persisted choice wins, caller-supplied parameter is only the previews/tests fallback.
        if let raw = UserDefaults.standard.string(forKey: Self.accentKey), let a = VolarAccent(rawValue: raw) {
            self.accent = a
        }
        if let raw = UserDefaults.standard.string(forKey: Self.densityKey),
           let d = Self.densityFromPersistedID(raw) {
            self.density = d
        }
        self.allowServerRecognition = UserDefaults.standard.bool(forKey: Self.allowServerRecognitionKey)
        // FIX (backlog 2026-07-26): default was hardcoded "en-US", silently ignoring the user's
        // system language on first launch. "auto" lets both engines auto-detect until the user
        // picks a specific locale in Settings (see `autoRecognitionLocaleID`'s doc comment).
        self.recognitionLocaleID = UserDefaults.standard.string(forKey: Self.recognitionLocaleKey) ?? Self.autoRecognitionLocaleID
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
        if let store {
            let realScheduler = ReminderScheduler(store: store, voice: self.voiceChannel, gate: self.reminderGate)
            self.scheduler = realScheduler
        } else {
            self.scheduler = nil
        }
        // Phase 6 (US4): construct the delegation subsystem once `store` is settled, same
        // conditional-construction convention as `scheduler` immediately above.
        if let store {
            let tracker = DelegationTracker(store: store)
            self.delegation = tracker
            self.appLinkHandler = AppLinkHandler(store: store, delegation: tracker)
        } else {
            self.delegation = nil
            self.appLinkHandler = nil
        }
        // M-1 (constitution I): wire the one cheaply-detectable, no-extra-entitlement signal this
        // file has direct access to — our own `AmbientSound` instance's public `isPlaying` flag —
        // so a voice reminder never talks over ambient sound already playing. Assigned HERE, after
        // every stored property above is initialized: this closure captures `self`, and Swift
        // forbids capturing `self` in a closure until the instance is fully initialized (doing it
        // earlier produced "variable 'self.scheduler' used before being initialized"). Mic
        // contention is already wired unconditionally inside `ReminderContextGate` itself
        // (`AVCaptureDevice.isInUseByAnotherApplication`); DND/screen-share have no public,
        // unprivileged API on macOS (see `ReminderContextGate.swift`'s own doc comment) and are
        // deliberately left non-suppressing rather than failing the whole gate open silently.
        // // UNVERIFIED: this only covers OUR OWN ambient playback, not other apps' audio in
        // general (no public system-wide "is any app playing audio" API without an entitlement)
        // — calendar-busy (P3) + call/mic remain the real guards for that case.
        self.reminderGate.isOtherAudioPlaying = { [weak self] in self?.ambientSound.isPlaying ?? false }
        speech.setLocale(Self.appleRecognitionLocale(for: self.recognitionLocaleID))
        groq.languageCode = Self.groqLanguageCode(for: self.recognitionLocaleID)
        // CAPTURE SEAM (AppLinkHandler.swift's own file header): wire `volar://capture?text=...`
        // into the SAME confirm-card-gated pipeline every other capture uses — never a bypass.
        // Assigned last (after every stored property above is set) since the closure captures
        // `self` and calls an instance method (`proceedToCapture`). `source` (FR-040's optional
        // origin reference) is folded into the transcript itself rather than a separate `notes`
        // field — `proceedToCapture`'s only parameter is the transcript, and the parser's own
        // `ParsedTask.notes` is what actually ends up in `TaskItem.notes`/`sourceTranscript`, so
        // this is the closest available seam to "stored in notes" without widening
        // `proceedToCapture`'s frozen-adjacent signature. // UNVERIFIED
        appLinkHandler?.onCapture = { [weak self] text, source in
            guard let self else { return }
            let transcript = source.map { "\(text) (via \($0))" } ?? text
            self.proceedToCapture(transcript: transcript)
        }
        // Account & Entitlements launch-time hydration — see that section below for what this
        // kicks off. Called last, same reasoning as `appLinkHandler?.onCapture` immediately above:
        // every stored property is settled by this point, and this call captures `self`.
        startAccountLifecycle()
    }

    // MARK: - Account & Entitlements actions
    //
    // Every method below follows the same shape: flip `accountBusy`, run one `_Concurrency.Task`
    // (qualified because `import VolarCore` shadows `Swift.Task` in this file — see the capture
    // flow's own comment on this a few hundred lines down), await the actor call, mirror the
    // result into the `@Observable` properties above, and clear `accountBusy` via `defer`.

    /// Launch-time hydration: start-once `Transaction.updates` listener (renewals/refunds/Ask-to-
    /// Buy), load the two products for the Account tab's upgrade rows, re-link every currently-
    /// active StoreKit entitlement (contract §8 — no server-side App Store Notifications yet, so
    /// this re-link-at-launch IS the renewal-propagation mechanism), then hydrate the mirrored
    /// state below. Called once from the end of `init` above.
    func startAccountLifecycle() {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            await Entitlements.shared.startTransactionUpdatesListener()
            await Entitlements.shared.loadProducts()
            self.monthlyProduct = await Entitlements.shared.product(.monthly)
            self.yearlyProduct = await Entitlements.shared.product(.yearly)
            await Entitlements.shared.relinkCurrentEntitlements()
            self.refreshAccountState()
        }
    }

    /// Re-mirrors `AccountService`/`Entitlements`'s current state into this `@Observable` — called
    /// after every sign-in/verify/purchase/restore action below, and at launch.
    func refreshAccountState() {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            self.accountEmail = await AccountService.shared.currentEmail
            let status = await Entitlements.shared.refreshStatus()
            self.subscriptionStatus = status
            self.accountTier = status?.tier ?? (Entitlements.cachedIsPro ? .pro : .free)
        }
    }

    func signInWithApple() {
        accountBusy = true
        accountError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                let user = try await AccountService.shared.signInWithApple()
                self.accountEmail = user.email
                await Entitlements.shared.relinkCurrentEntitlements()
                self.refreshAccountState()
            } catch AccountError.cancelled {
                // Not a real failure — user dismissed the sheet. No error text shown.
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func sendEmailOTP(email: String) {
        accountBusy = true
        accountError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                try await AccountService.shared.sendEmailOTP(email: email)
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func verifyEmailOTP(email: String, code: String) {
        accountBusy = true
        accountError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                let user = try await AccountService.shared.verifyEmailOTP(email: email, code: code)
                self.accountEmail = user.email
                await Entitlements.shared.relinkCurrentEntitlements()
                self.refreshAccountState()
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func signOutAccount() {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            await AccountService.shared.signOut()
            self.accountEmail = nil
            self.accountTier = .free
            self.subscriptionStatus = nil
            self.accountError = nil
        }
    }

    /// Contract §3 `delete-account` — Apple Guideline 5.1.1(v). `SettingsView` is responsible for
    /// the confirmation step before calling this; by the time this runs, deletion is final.
    func deleteAccount() {
        accountBusy = true
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                try await AccountService.shared.deleteAccount()
                self.accountEmail = nil
                self.accountTier = .free
                self.subscriptionStatus = nil
                self.accountError = nil
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func purchase(_ product: VolarProduct) {
        accountBusy = true
        accountError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                _ = try await Entitlements.shared.purchase(product)
                self.refreshAccountState()
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func restorePurchases() {
        accountBusy = true
        accountError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                try await Entitlements.shared.restorePurchases()
                self.refreshAccountState()
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
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

    /// Session-only (never persisted, never touches `speechEngineChoice`): set by
    /// `handleCloudSpeechUnavailable` the moment Groq reports a `403`/`429` mid-flight. Stops
    /// `selectedEngine` from retrying Groq for the REST OF THIS RUN without waiting on a second
    /// network round trip each capture — a lapsed subscription or a spent daily quota is a
    /// transient condition, not a user preference change, so the Settings picker stays exactly as
    /// the user left it. Never reset back to `false` within a run: the next thing that legitimately
    /// re-arms Groq is the user relaunching (fresh `AppState`) or explicitly re-picking it in
    /// Settings after fixing the underlying issue (resubscribing, waiting for the daily reset).
    private var groqDegradedThisSession = false

    /// Picks the engine for the NEXT capture based on user choice, with safe fallbacks:
    /// WhisperKit only when supported AND its model is loaded, else Apple; Groq (cloud) only when a
    /// credential is configured AND it hasn't degraded this session, else Apple on-device — so
    /// choosing cloud before a key exists (or after a `403`/`429` mid-capture, see
    /// `groqDegradedThisSession`) degrades quietly to local instead of hard-erroring at upload time
    /// ("code first, key later", mirrors the Local↔Cloud parse switch's fallback).
    private var selectedEngine: SpeechEngine {
        switch speechEngineChoice {
        case .appleOnDevice: return speech
        case .whisperKit: return (WhisperKitEngine.isSupported && whisper.isModelReady) ? whisper : speech
        case .groq: return (GroqEngine.isConfigured && !groqDegradedThisSession) ? groq : speech
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
            // FIX 2b (privacy seam): guard against a late callback landing after this session was
            // superseded (Esc/cancel/a fresh capture already started) — without this, a `.stop()`
            // caller (`stopCapture`/`confirmSave`'s siblings) that genuinely wants the final result
            // is unaffected, but a callback arriving after `cancelCapture`/`dismissVoiceDoneConfirm`
            // already moved on (now routed through `.cancel()`, see those methods below) can no
            // longer resurrect a confirm card the user already dismissed.
            engine.onFinal = { [weak self] transcript in
                guard let self, self.captureSession == session else { return }
                self.finishRecording(transcript: transcript)
            }
            engine.onError = { [weak self] error in
                guard let self, self.captureSession == session else { return }
                self.handleCaptureError(error)
            }
            // Apple-only: server-consent. (Locale/language is already applied live by
            // `setRecognitionLocale`/init — but only for `speech` (Apple, via `setLocale`) and
            // `groq` (via `languageCode`); WhisperKit takes no locale input at all and always
            // auto-detects the spoken language, so there is nothing to apply to it here or there.)
            // WhisperKit also has no server-consent concept at all; Groq is cloud-only already (its
            // consent gate is the paid-tier check in `selectedEngine`, not this on-device/server
            // toggle) — so there's nothing analogous to wire for either of them here.
            if let apple = engine as? SpeechCapture {
                apple.allowServerFallback = self.allowServerRecognition
            }
            // Groq-only: 403/429 mid-flight routes here instead of `onError` — see
            // `handleCloudSpeechUnavailable`'s doc comment.
            if let groqEngine = engine as? GroqEngine {
                groqEngine.onCloudUnavailable = { [weak self] fileURL in
                    await self?.handleCloudSpeechUnavailable(session: session, salvageAudioURL: fileURL)
                }
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

    /// `GroqEngine.onCloudUnavailable` lands here (403 `upgrade_required` / 429 `quota_exceeded`)
    /// instead of `handleCaptureError` — see that property's doc comment in `GroqEngine.swift`. The
    /// no-shame UI rule (FR-016/FR-036) makes this a routing decision, never a visible error:
    /// `captureState` must never become `.error` for either status.
    ///
    /// 1. Marks `groqDegradedThisSession` so `selectedEngine` stops retrying Groq for the rest of
    ///    this run (see that property's doc comment) — independent of whether the refresh below
    ///    actually observes the change, since a spent daily quota doesn't necessarily flip the
    ///    cached tier that `GroqEngine.isConfigured` reads.
    /// 2. Best-effort refreshes the entitlement cache via `Entitlements.shared.refreshStatus()` —
    ///    the same "refresh affordance" `SettingsView`/app-launch already use, not a new mechanism —
    ///    so `EnvironmentGroqCredentialProvider.isConfigured`'s cached tier stops being stale.
    /// 3. Only when WhisperKit is genuinely `.ready` does it salvage the just-recorded utterance by
    ///    handing Groq's temp audio file to it; on success this calls `groq.onFinal` — the SAME
    ///    closure `startCapture()` already wired for this session — so the salvaged transcript flows
    ///    through the exact normal `finishRecording` path exactly once, never a second/parallel one.
    /// 4. If salvage isn't possible (hardware/model not ready) or fails (empty/throws), the
    ///    recording is discarded and, if this session is still the current one and still sitting in
    ///    `.parsing` (where `stopCapture()` leaves it while Groq's upload is in flight), capture
    ///    quietly returns to `.idle` — never `.error`, and never left stuck on "Parsing…" forever.
    ///
    /// `session` is the `AppState.captureSession` token captured at `startCapture()` time (NOT
    /// `GroqEngine`'s own private `session` counter) — re-checked after every `await` below exactly
    /// like `onFinal`/`onError`'s own guards, so a `cancelCapture()`/a fresh capture superseding this
    /// one while this method is mid-flight can never resurrect or clobber state for a session the
    /// user has already moved on from.
    private func handleCloudSpeechUnavailable(session: Int, salvageAudioURL: URL) async {
        groqDegradedThisSession = true
        // Calm, developer-facing log line only — this product has no non-error notice channel
        // wired up yet (`IntentParsing.lastCloudQuotaNote` is the analogous parse-side signal and
        // is itself not consumed by any view today), so per the no-shame UI rule this prefers
        // silence over inventing a banner.
        print("[Volar.Speech] cloud unavailable (stale entitlement or quota) -> falling back on-device")
        _ = await Entitlements.shared.refreshStatus()

        guard captureSession == session, captureState == .parsing else { return }

        if WhisperKitEngine.isSupported, whisper.isModelReady,
           let text = try? await whisper.transcribe(audioPath: salvageAudioURL.path),
           !text.isEmpty {
            guard captureSession == session else { return }
            groq.onFinal?(text)
            return
        }

        guard captureSession == session, captureState == .parsing else { return }
        captureState = .idle
        liveTranscript = ""
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
        // FIX 2a (privacy seam): `.stop()` means "finish and deliver" — Groq would still upload the
        // in-flight audio and a late `onFinal` could pop a confirm card after Esc. `.cancel()`
        // immediately abandons capture and discards the audio; neither `onFinal` nor `onError` fires
        // for it (the `captureSession` guard on both closures in `startCapture()` is defense-in-depth
        // on top of that contract, not a substitute for it).
        runningEngine?.cancel()
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
            // FIX 1: `SpeechCapture.stop()` sets `isRunning = false` SYNCHRONOUSLY
            // (SpeechCapture.swift:308) but the final transcript still arrives async via
            // `onFinal`. This used to only flip to `.parsing` for a batch engine
            // (`!supportsPartialResults`), so a partial-results engine (Apple) stayed stuck in
            // `.recording` for that whole gap. A second `stopCapture()` call landing in that
            // window then fell through to the `else if captureState == .recording` branch below,
            // which bumps `captureSession` — invalidating the very session `onFinal`'s guard
            // checks — and silently swallowed the transcript. `.parsing` is the correct state for
            // EVERY engine here: it means "mic is off, waiting on the final result," which is
            // just as true with partial results as without. It is also what disarms the second
            // call: with `isRunning` already false AND `captureState` no longer `.recording`,
            // neither branch matches, so `stopCapture()` becomes a clean no-op that leaves the
            // in-flight session intact instead of taking the destructive `else if`.
            captureState = .parsing
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

    /// Change the speech-recognition language (Settings ▸ Language). Persists and applies live to
    /// BOTH engines: `speech` (Apple/WhisperKit path) gets a concrete `Locale`, `groq` gets the
    /// matching ISO-639-1 `languageCode` — `id == autoRecognitionLocaleID` resolves to
    /// `Locale.current` / `nil` respectively so each engine auto-detects instead.
    func setRecognitionLocale(_ id: String) {
        recognitionLocaleID = id
        UserDefaults.standard.set(id, forKey: Self.recognitionLocaleKey)
        speech.setLocale(Self.appleRecognitionLocale(for: id))
        groq.languageCode = Self.groqLanguageCode(for: id)
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

    /// Local↔cloud parsing switch surfaced in Settings. Reads the SAME `cloudParseConsent` the
    /// router's Cloud tier is already gated on (`DefaultCloudParseGate`), so this is purely a
    /// friendlier presentation of that one bit — no second source of truth. A `nil` consent
    /// (never asked) reads as `.onDevice`, matching the privacy-first "decline ⇒ never cloud" default.
    var parseEnginePreference: ParseEnginePreference {
        cloudParseConsent == true ? .cloud : .onDevice
    }

    /// Change the parsing engine from Settings. Persists to the existing `cloudParseConsentKey` so
    /// the router's Cloud gate picks it up immediately and the one-time voice-capture consent
    /// popover never re-appears once the user has made a Settings choice. Picking `.cloud` is
    /// itself the informed opt-in — the Settings row's hint states cloud parsing sends only the
    /// TEXT (never audio) of the utterance to our proxy.
    func setParseEngine(_ preference: ParseEnginePreference) {
        let allow = (preference == .cloud)
        cloudParseConsent = allow
        UserDefaults.standard.set(allow, forKey: Self.cloudParseConsentKey)
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
        // T042 (phase6-contract.md §C): classify a delegation-handoff utterance BEFORE the T036
        // voice-done classification below — "giao cho Claude rồi" is neither a completion nor a
        // new-task capture, and must never fall through to either.
        if let minutes = classifyDelegationIntent(transcript) {
            presentDelegationConfirm(checkBackMinutes: minutes)
            return
        }
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

    // MARK: - T042: voice delegation intent (phase6-contract.md §C, US4)

    /// Trigger phrases for "I handed this off to Claude" (Vietnamese + English), matched via
    /// `Self.foldForMatch`'s diacritic/case-insensitive folding. Deliberately name-scoped ("...
    /// claude") rather than a bare "delegated"/"giao việc" to keep the false-positive rate low — an
    /// unrelated utterance (e.g. "giao hàng", deliver goods) must not be swallowed as a delegation
    /// intent. // UNVERIFIED: a fixed phrase list, same class of heuristic as `VoiceDone`'s own cue
    /// words — not exercised against real ASR output on this machine (Windows, no Xcode).
    private static let delegationTriggerPhrases = [
        "giao cho claude", "giao viec cho claude", "da giao cho claude", "chuyen cho claude",
        "gui cho claude", "nho claude lam", "handed to claude", "handed off to claude",
        "gave it to claude", "gave this to claude", "delegated to claude", "delegated this to claude",
        "assigned to claude", "assigned this to claude",
    ]

    /// Detects a delegation-handoff phrase and, if present, the spoken check-back interval ("check
    /// sau 10 phút" / "check back in 15 minutes") — defaulting to `DelegationTracker`'s own 10'
    /// when no interval is spoken. `nil` = not a delegation utterance at all (falls through to the
    /// normal `VoiceDone`/new-task classification in `finishRecording`).
    private func classifyDelegationIntent(_ transcript: String) -> Int? {
        let folded = Self.foldForMatch(transcript)
        guard Self.delegationTriggerPhrases.contains(where: { folded.contains(Self.foldForMatch($0)) }) else {
            return nil
        }
        return Self.extractCheckBackMinutes(from: folded) ?? 10
    }

    private static func foldForMatch(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    }

    /// Pulls the first "<N> phut/minutes/min" style interval out of an already-folded transcript.
    /// Defensive cap (self-review "client-exploit"): clamps to 1...240 minutes so a garbled/
    /// adversarial ASR result (e.g. a stray huge number) can never schedule a wildly-out-of-range
    /// check-back — mirrors `presentVoiceDoneConfirm`'s own defensive cap on candidate count.
    private static func extractCheckBackMinutes(from folded: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d{1,4})\\s*(phut|minutes?|mins?|min)\\b") else {
            return nil
        }
        let range = NSRange(folded.startIndex..<folded.endIndex, in: folded)
        guard let match = regex.firstMatch(in: folded, range: range),
              let numberRange = Range(match.range(at: 1), in: folded),
              let value = Int(folded[numberRange]) else { return nil }
        return min(max(value, 1), 240)
    }

    /// Routes a detected delegation utterance to the SAME glance-and-dismiss confirm surface
    /// `presentVoiceDoneConfirm` uses (constitution II applies to every voice action, not only
    /// completions — never silently act). Always targets the current `activeTask`: a bare "giao
    /// cho Claude rồi" names no task, and the single NOW slot IS the thing the user is working on
    /// — same "act on the one active task" convention as `startFocus`/`completeFocusTask` and the
    /// `TodayView` delegate button (`delegateTask`), rather than fuzzy-matching the utterance
    /// against every open title the way `VoiceDone` does for actual completion phrasing.
    private func presentDelegationConfirm(checkBackMinutes: Int) {
        guard let active = activeTask else {
            // Nothing to delegate — state it (constitution II: never guess), reusing the same
            // "no matching task" row `presentVoiceDoneConfirm` already renders.
            voiceDoneNoMatchTranscript = liveTranscript
            captureState = .parsed
            return
        }
        voiceDoneConfirm = VoiceDoneConfirm(
            action: .delegate(checkBackMinutes: checkBackMinutes),
            candidates: [VoiceMatch(taskId: active.id, title: active.title, score: 1.0)]
        )
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
        case .delegate(let minutes):
            delegateTask(taskId, checkBackMinutes: minutes)
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
        // FIX 2a (privacy seam): same rationale as `cancelCapture()` above — this is a decline/
        // dismiss path, not a "give me the final transcript" path, so it must not leave Groq
        // uploading audio (or any engine still capturing) behind it.
        runningEngine?.cancel()
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
        let spoken: String
        switch action {
        case .complete: spoken = "Done."
        case .clearExternal: spoken = "Cleared."
        case .delegate: spoken = "Handed off."
        }
        voice.speak(spoken)
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
        // FIX B: (re)start the countdown owned by this instance — invalidate any timer left over
        // from a previous session first so two overlapping sessions can never double-decrement.
        // Mirrors `startDelegationTimer()`'s exact construction (`Timer(timeInterval:repeats:
        // block:)` + `RunLoop.main.add(_:forMode:.common)`) — the `@Sendable` block hops back onto
        // `@MainActor` via `_Concurrency.Task` for the same Swift 6 isolation reason documented
        // there.
        focusTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { @Sendable [weak self] _ in
            _Concurrency.Task { @MainActor [weak self] in
                self?.focusTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusTimer = timer
    }

    /// FIX B: 1s tick, moved verbatim from `FocusOverlay.tick()` (see that file's git history) so
    /// the countdown keeps running even while the fullscreen overlay isn't mounted — only the
    /// visuals stayed behind in `FocusOverlay`, not the timing logic.
    private func focusTick() {
        guard focusActive, !focusPaused else { return }
        guard focusSecondsLeft > 0 else {
            endFocus()
            return
        }
        focusSecondsLeft -= 1
        if focusSecondsLeft <= 0 {
            endFocus()
        }
    }

    func endFocus() {
        focusTimer?.invalidate()
        focusTimer = nil
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
        // FIX 3: `remaining` used to be computed as `openTasks.count - 1` BEFORE calling
        // `toggleDone`, assuming completing one task always drops the open count by exactly one.
        // That's not true: `TaskStore.completeOne` (TaskStore.swift:394) resets a task with a
        // `recurrence` back to `.status == .todo` in place rather than closing it — it stays in
        // `openTasks`, a delta of 0, not -1 — and `TaskStore.toggle`'s parent auto-complete
        // cascade (TaskStore.swift:367-369) can additionally close the now-childless parent in
        // the same call, a delta of -2. Reading `openTasks.count` fresh AFTER `toggleDone` (which
        // itself refreshes `tasks` from the store) reports whichever of those actually happened
        // instead of guessing "-1".
        toggleDone(id)
        let remaining = openTasks.count
        focusIndex = remaining > 0 ? max(0, min(focusIndex, remaining - 1)) : 0
        if remaining == 0 {
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

    // MARK: - Appearance controls (Settings → Appearance)

    /// FIX 4: sets the accent color and persists it, so it survives relaunch — same "mutate +
    /// persist together" shape as `setAmbient` right below. A plain stored-property `didSet` was
    /// considered instead (would avoid touching `SettingsView.swift` at all), but this file has
    /// zero existing `didSet`/`willSet` usage anywhere, `@Observable`'s macro expansion turns a
    /// stored property into a computed one and the exact interaction with property observers
    /// isn't exercised anywhere else in this codebase to lean on — an explicit setter method
    /// mirrors the established, already-proven convention every other persisted Settings control
    /// in this file uses (`setAmbient`/`setSpeechEngine`/`setRecognitionLocale`/
    /// `setVoiceDeliveryMode`/`setGlobalReminderPolicy`), so it's the safer choice here.
    /// `SettingsView.swift`'s tap handler calls this instead of assigning `appState.accent`
    /// directly.
    func setAccent(_ a: VolarAccent) {
        accent = a
        UserDefaults.standard.set(a.rawValue, forKey: Self.accentKey)
    }

    /// FIX 4: sets the row/section density and persists it — same rationale/shape as `setAccent`
    /// above. `Density` has no `.rawValue` (see `densityKey`'s doc comment), so persistence goes
    /// through the two small string-mapping helpers below instead.
    func setDensity(_ d: Density) {
        density = d
        UserDefaults.standard.set(Self.densityPersistedID(d), forKey: Self.densityKey)
    }

    /// `Density -> String`, for persistence — deliberately the exact same three values as
    /// `SettingsView.densityID(_:)` (that method stays private to its view; this is the
    /// AppState-side mirror `setDensity`/`init` need for `UserDefaults`, not a second source of
    /// truth — see `densityKey`'s doc comment).
    private static func densityPersistedID(_ d: Density) -> String {
        switch d {
        case .cozy: return "cozy"
        case .comfy: return "comfy"
        case .roomy: return "roomy"
        }
    }

    /// The inverse of `densityPersistedID(_:)` above. Returns `nil` — rather than defaulting to
    /// `.comfy` — for an unrecognized/corrupted stored value, so `init` can leave the
    /// caller-supplied `density:` argument standing instead of stomping it with a hardcoded
    /// default. That matters because the init parameters are documented as the fallback for
    /// previews/tests, and it keeps this path symmetric with `accent`'s
    /// `VolarAccent(rawValue:)`, which is already `nil`-on-garbage for the same reason. Named
    /// distinctly from the `density` stored property (rather than overloading that name, as
    /// `densityPersistedID(_:)`'s counterpart does with `accent`/`setAccent`) purely so this static
    /// helper reads unambiguously at its one call site in `init` above.
    private static func densityFromPersistedID(_ id: String) -> Density? {
        switch id {
        case "cozy": return .cozy
        case "comfy": return .comfy
        case "roomy": return .roomy
        default: return nil
        }
    }

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
    ///
    /// FIX 6 (data hygiene): used to only mutate the in-memory `tasks` array, never the store — the
    /// very next `tasks = store.fetchAll()` (any other mutation) silently wiped the flag, and it
    /// never survived relaunch at all. Store-backed path now routes through `TaskStore.setFrog(_:)`
    /// (persists, and is itself the single source of truth for the invariant) and refreshes `tasks`
    /// from it, same "mutate via store, refresh tasks" convention every other store-backed mutation
    /// in this file already follows. No-store fallback (previews/tests) keeps the old in-memory-only
    /// loop.
    func setFrog(_ id: UUID) {
        guard let store else {
            for index in tasks.indices {
                tasks[index].frog = (tasks[index].id == id)
            }
            return
        }
        store.setFrog(id)
        tasks = store.fetchAll()
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
        // FIX 2: `VolarCore.nextResurfaceDate` returns only the SINGLE earliest `.afterDate`
        // across the whole snapshot, so registering just that one task with the durable scheduler
        // left every OTHER task's `.afterDate` completely unregistered. There's no safety net for
        // those either: `ReminderScheduler.rebuildFromStorage()` only rescans tasks with
        // `deadline != nil`, never `.afterDate` conditions, and a local in-memory wake (the sleep
        // below) doesn't survive an app quit. A task whose `.afterDate` isn't the single nearest
        // one across the whole store would then simply never resurface. Scan the snapshot
        // ourselves instead and register EVERY task's own earliest future `.afterDate`
        // individually — safe to call on every mutation because `ReminderScheduler.scheduleResurface`
        // (ReminderScheduler.swift:200-217) already dedupes per task (same `fireAt` -> no-op,
        // different `fireAt` -> updates the existing row in place), so this never piles up
        // duplicate durable records or duplicate system notifications.
        var earliestOverall: Date?
        for task in snapshot {
            var earliestForTask: Date?
            for condition in task.conditions {
                guard case .afterDate(let date) = condition, date > now else { continue }
                if earliestForTask == nil || date < earliestForTask! { earliestForTask = date }
            }
            guard let taskDate = earliestForTask else { continue }
            scheduler?.scheduleResurface(at: taskDate, taskId: task.id)
            if earliestOverall == nil || taskDate < earliestOverall! { earliestOverall = taskDate }
        }
        guard let date = earliestOverall else { return }

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
            // FIX 2 (chain): the refresh above only advances `tasks` past the resurface moment
            // that just fired — on its own it does NOT re-arm whichever `.afterDate` comes next.
            // Re-running this same method against a fresh snapshot/`now` is what chains forward.
            // This cannot loop forever: the moment that just fired is now <= `now` (this closure
            // only runs once the sleep above has elapsed), and the scan above requires strictly
            // `date > now` to even be a candidate, so that same moment can never be picked again —
            // each recursive call either lands on a strictly later date (and stops after that
            // one sleep) or finds none left at all (and returns immediately, ending the chain).
            self.scheduleNextResurface(from: self.tasks.map { $0.snapshot() }, now: self.clock())
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

    /// FIX A (compile break): processing the last item of a sweep/triage batch used to leave an
    /// open blank sheet with no dismiss control — `showSweep`/`showTriage` only ever got set to
    /// `false` by their own explicit dismiss actions (`dismissSweep()`, or nothing at all for
    /// triage), never by the batch simply running out of items. Called at the tail of every
    /// mutating triage/sweep action (`triageKeep`/`triageBreakdown`/`triageDefer`/`triageDrop`/
    /// `sweepComplete`) so the sheet closes itself the instant its backing list empties out — a
    /// pure UI convenience, no store/model side effects.
    private func dismissBatchSheetsIfEmpty() {
        if showSweep, sweepItems.isEmpty { showSweep = false }
        if showTriage, staleTasks.isEmpty { showTriage = false }
    }

    /// Triage "Keep": no destructive/creative side effect on the task itself — just resets this
    /// task's staleness clock so it doesn't reappear in next week's batch.
    func triageKeep(_ item: TaskItem) {
        triageKeptAt[item.id] = clock()
        persistTriageKeptAt()
        dismissBatchSheetsIfEmpty()
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
        dismissBatchSheetsIfEmpty()
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
            dismissBatchSheetsIfEmpty()
            return
        }
        let before = tasks
        try? store.addCondition(.afterDate(now.addingTimeInterval(Self.triageDeferInterval)), to: item.id)
        tasks = store.fetchAll()
        // WG-1: re-derive this task's reminders (deadline/condition state just changed).
        scheduler?.scheduleReminders(taskId: item.id)
        notifyEligibilityAndScheduleResurface(before: before, now: now)
        dismissBatchSheetsIfEmpty()
    }

    /// Triage "Drop": a plain delete — same path (and same FR-015 re-eligibility notification) as
    /// any other task deletion.
    func triageDrop(_ item: TaskItem) {
        deleteTask(item.id)
        dismissBatchSheetsIfEmpty()
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
        // WG3 (major, reviewer fix): `DelegationTracker.reconcileBatch()` was defined but had zero
        // call sites — stage-2 (bumped past 30' → batch-only) delegations are deliberately excluded
        // from `dueForRecheck` (see that method's own backoff-stage cutoff) and were consequently
        // never resurfaced anywhere. `reconcileBatch()`'s own doc comment names its intended trigger
        // as "natural touchpoints (popover open / evening)" — this evening-sweep call IS that
        // touchpoint. Deliberately NOT unioned into the every-60s timer tick
        // (`refreshDelegationQueue`): `reconcileBatch()` is independent of backoff stage, so
        // surfacing it every tick would show every in-flight delegation immediately regardless of
        // its check-back schedule, defeating the whole point of the 10'/30'/batch-only backoff.
        // Once/evening (this call site) matches the contract's own "evening" touchpoint instead.
        // Independent of the sweep-day gate below (a `showSweep` throttle for a DIFFERENT feature)
        // so it still runs even when the sweep card itself was already shown today, or
        // `sweepItems` is empty — a delegation-only evening still deserves its reconcile pass.
        if let delegation {
            let batchIds = delegation.reconcileBatch()
            let alreadyQueued = Set(dueDelegationRechecks)
            dueDelegationRechecks += batchIds.filter { !alreadyQueued.contains($0) }
        }
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
        dismissBatchSheetsIfEmpty()
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
        // FIX 2 (re-arm on launch): `scheduleNextResurface`'s local one-shot wake (the sleep
        // continuation inside it) lives only in memory, so it doesn't survive a quit/relaunch —
        // without this call, a task with a future `.afterDate` would sit unregistered (durably
        // AND locally) until some other mutation happened to touch `tasks` first. Idempotent if
        // `activateServices()` is ever called twice: each call bumps `resurfaceSession`, which
        // invalidates any still-pending sleep from the previous call, and every
        // `scheduler?.scheduleResurface` it issues is itself deduped per task (see that method's
        // own doc comment) — so a repeat call just re-arms the same state, never a duplicate.
        scheduleNextResurface(from: tasks.map { $0.snapshot() }, now: clock())
        // T043 (phase6-contract.md §C): starts the minute-scale ambient recheck timer.
        startDelegationTimer()
        // FIX 3: a persisted `.whisperKit` engine choice used to only ever call `whisper.prepare()`
        // from `setSpeechEngine` (Settings) — so on relaunch, `speechEngineChoice` restores from
        // `UserDefaults` correctly but the model itself was never (re)loaded, silently falling back
        // to Apple on-device for the whole session (see `selectedEngine`'s `isModelReady` gate).
        // `WhisperKitEngine.prepare()` is documented idempotent (self-guards on `.preparing`/`.ready`
        // — see its own doc comment), so no extra guard is needed here.
        if speechEngineChoice == .whisperKit, WhisperKitEngine.isSupported {
            _Concurrency.Task { await whisper.prepare() }
        }
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

    // MARK: - Phase 6 (US4): AI-delegation orchestrator (phase6-contract.md §C, T042/T043/T044)

    /// T043: minute-scale ambient recheck timer (constitution I — the resurface queue is an
    /// in-app ambient card, NEVER a `UNUserNotificationCenter` notification). Idempotent:
    /// invalidates any previous timer first so a second `activateServices()` call can't leak a
    /// duplicate `Timer` (self-review "runtime"). No-op when there's no `delegation` tracker
    /// (no-store fallback) beyond the one immediate `refreshDelegationQueue()` call, which itself
    /// no-ops the same way.
    private func startDelegationTimer() {
        delegationTimer?.invalidate()
        refreshDelegationQueue()
        guard delegation != nil else { return }
        // `Timer(timeInterval:repeats:block:)`'s block is `@Sendable` — capturing `[weak self]`
        // (a plain reference, not touching actor-isolated state) is safe, but actually CALLING
        // `refreshDelegationQueue()` must hop back onto `@MainActor` explicitly, exactly like
        // `AppDelegate.applicationDidFinishLaunching`'s own documented `@Sendable`/MainActor note
        // (UserNotifications invoking a MainActor-inferred closure off-main traps at runtime under
        // Swift 6's isolation checking) — this timer callback is the same failure class.
        let timer = Timer(timeInterval: 60, repeats: true) { @Sendable [weak self] _ in
            _Concurrency.Task { @MainActor [weak self] in
                self?.refreshDelegationQueue()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        delegationTimer = timer
    }

    /// Refreshes the ambient "needs review" queue from `DelegationTracker.dueForRecheck` — called
    /// by the minute-scale timer, once at `activateServices()`, and after any mutation here that
    /// could change due-ness (`delegateTask`/`resolveDelegation*`/`onAppLinkHandled`). Never a
    /// system notification (constitution I) — `TodayView` renders `dueDelegationRechecks` as an
    /// ordinary, dismissible in-app card.
    func refreshDelegationQueue(now: Date? = nil) {
        dueDelegationRechecks = delegation?.dueForRecheck(now: now ?? clock()) ?? []
    }

    /// T042: `TodayView`'s delegate affordance on the NOW spotlight, and `confirmVoiceDone`'s
    /// `.delegate` action — delegates task `id` (there is only ever one NOW slot at a time, so
    /// both call sites already know exactly which task). No-op if there's no `delegation` tracker
    /// (no-store fallback) or `store` — delegation state has nowhere durable to live without one.
    /// Mirrors `triageDefer`/`clearExternalCondition`'s existing "mutate via store, refresh
    /// `tasks`, re-derive reminders, run the shared eligibility/resurface tail" pattern: adding the
    /// unsatisfied `.external` waiting-condition makes this task INELIGIBLE for
    /// `VolarCore.nextTask()`, which is what actually moves it out of the active slot and lets the
    /// next eligible task advance in — the SAME `tasks = store.fetchAll()` funnel every other
    /// mutation here uses, no bespoke advance logic needed.
    func delegateTask(_ id: UUID, label: String? = nil, checkBackMinutes: Int = 10) {
        guard let delegation, let store else { return }
        let before = tasks
        let resolvedLabel = label ?? tasks.first { $0.id == id }?.title ?? "Claude"
        delegation.delegate(taskId: id, label: resolvedLabel, checkBackMinutes: checkBackMinutes, cwdHint: nil)
        tasks = store.fetchAll()
        let now = clock()
        // WG-1: this task's condition state just changed — re-derive its reminders, same as every
        // other condition-adding path.
        scheduler?.scheduleReminders(taskId: id)
        notifyEligibilityAndScheduleResurface(before: before, now: now)
        refreshDelegationQueue(now: now)
    }

    /// T043 ambient card action: [Done] — routes through the SAME completion funnel as every other
    /// completion source (T037/FR-020), never a bespoke completion path.
    func resolveDelegationDone(_ id: UUID) {
        toggleDone(id)
        refreshDelegationQueue()
    }

    /// T043 ambient card action: [Still waiting] — the user looked and it's genuinely still in
    /// flight; bumps backoff (10' -> 30' -> batch-only) rather than re-asking every minute.
    func resolveDelegationStillWaiting(_ id: UUID) {
        delegation?.bumpBackoff(taskId: id)
        refreshDelegationQueue()
    }

    /// T043 ambient card action: [Check later] — an explicit user-directed snooze (never a silent
    /// auto-reschedule): re-delegates the SAME task under its current title and cwd hint with a
    /// fresh check-back. `DelegationTracker.delegate` is documented idempotent for an
    /// already-waiting task (updates the schedule in place rather than piling up a second
    /// condition), so this is safe to call on a task that's already mid-delegation.
    func resolveDelegationCheckLater(_ id: UUID, minutes: Int = 10) {
        guard let delegation else { return }
        let label = tasks.first { $0.id == id }?.title ?? "Claude"
        delegation.delegate(taskId: id, label: label, checkBackMinutes: minutes, cwdHint: delegation.cwdHint(for: id))
        refreshDelegationQueue()
    }

    /// `VolarApp.swift`'s `.onOpenURL` calls this right after `appLinkHandler?.handle(url)` —
    /// `AppLinkHandler` is a plain (non-`@Observable`) class, so this is what actually makes its
    /// resulting state changes visible to SwiftUI: mirrors `pendingDisambiguation` into this file's
    /// own `@Observable` `pendingDisambiguationTaskIDs`, stamps `lastAppLinkAt` (Settings' test-
    /// signal "✓ received" confirmation, T044), and refreshes the ambient queue (an `ai-done` match
    /// can clear a delegation, which changes what's due).
    func onAppLinkHandled() {
        // WG1 (major, reviewer fix): `AppLinkHandler.handle(_:)` (called just before this, in
        // `VolarApp.swift`'s `.onOpenURL`) already ran the resolve chain (→ `markNeedsReview` →
        // `store.clearFirstExternalCondition`) if it matched a task — but that mutates the STORE,
        // not this file's `tasks` snapshot. Without this refresh, `activeTask`/`MenuBarLabel`
        // (both derived from `tasks`) stay stale until some unrelated mutation happens to catch
        // them up. The mutation (if any) already happened by the time this method runs, so
        // refreshing first is correct here.
        refreshFromStore()
        lastAppLinkAt = clock()
        pendingDisambiguationTaskIDs = appLinkHandler?.pendingDisambiguation ?? []
        refreshDelegationQueue()
    }

    /// One-tap disambiguation resolve (`TodayView`'s ambient card) — delegates straight to
    /// `AppLinkHandler.resolveDisambiguation`, which itself routes through
    /// `DelegationTracker.markNeedsReview` (never completes, per constitution II), then
    /// re-syncs the mirrored `pendingDisambiguationTaskIDs`/queue exactly like `onAppLinkHandled`.
    func resolveAppLinkDisambiguation(taskId: UUID) {
        appLinkHandler?.resolveDisambiguation(taskId: taskId)
        // WG1 (major, reviewer fix): same staleness gap as `onAppLinkHandled` above, for the
        // disambiguation-card tap path — `resolveDisambiguation` above mutates the store via
        // `markNeedsReview`, so the refresh runs AFTER that call (not literally the method's first
        // statement) so `tasks` actually reflects what this call just changed, still strictly
        // before `refreshDelegationQueue()`.
        refreshFromStore()
        pendingDisambiguationTaskIDs = appLinkHandler?.pendingDisambiguation ?? []
        refreshDelegationQueue()
    }

    /// "None of these" — purely local UI state, no task touched (mirrors
    /// `AppLinkHandler.dismissDisambiguation`'s own doc comment).
    func dismissAppLinkDisambiguation() {
        appLinkHandler?.dismissDisambiguation()
        pendingDisambiguationTaskIDs = []
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
            // Same scoped form as `isOnline()` below — this closure is synchronous so the manual
            // pair would compile here, but keeping one locking idiom means a future edit can't
            // accidentally leave an early return between `lock()` and `unlock()`.
            self.lock.withLock { self.pathSatisfied = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "volar.cloudParseGate.reachability"))
    }

    deinit {
        monitor.cancel()
    }

    func isOptedIn() async -> Bool {
        UserDefaults.standard.bool(forKey: AppState.cloudParseConsentKey)
    }

    /// Scoped `withLock` rather than a manual `lock()`/`defer { unlock() }` pair: `NSLock`'s
    /// `lock()`/`unlock()` are `@available(*, noasync)`, so calling them directly in an `async`
    /// method is a compile error — a suspension between the two could resume on a different
    /// thread and unlock from the wrong one. `withLock`'s body is synchronous and cannot suspend,
    /// which is exactly why it stays available here.
    func isOnline() async -> Bool {
        lock.withLock { pathSatisfied }
    }
}
