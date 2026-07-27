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

/// One step of a real (server- or on-device-generated) task breakdown, as rendered by
/// `TaskBreakdownView`. `id` is the step's position, not a UUID — `IntentRouter.breakdown(title:
/// notes:)` (the frozen `IntentParser` seam this is built from, `Sources/Parsing/
/// IntentParsing.swift`) returns bare `[String]` titles only; the backend's `POST /parse` with
/// `mode: "breakdown"` also returns a per-step `estimateMinutes`, but that number never survives
/// the trip through `CloudParser.breakdown(title:notes:) -> [String]` (it discards everything but
/// the title before returning — see that file, out of this task's allowed files, for the decode).
/// So there is no real per-step duration available through this seam today; `TaskBreakdownView`
/// intentionally shows none rather than inventing one (the OLD hard-coded "10 min"/"5 min" labels
/// this view used to show were exactly the kind of fake-looking content this feature removes).
struct BreakdownStep: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
}

/// State machine for `AppState.fetchBreakdown` (Change 3: real "Save all as tasks"). `TaskBreakdownView`
/// renders directly off this rather than owning any fetch state of its own.
enum BreakdownFetchState: Equatable, Sendable {
    /// No breakdown sheet open, or a fresh `openBreakdown(for:)` hasn't kicked off its fetch yet.
    case idle
    /// Request in flight (or about to be — set synchronously by `fetchBreakdown` before the async
    /// hop, so the sheet never shows a blank frame between opening and "loading").
    case loading
    /// Real steps, from either the on-device FoundationModels tier or the actual cloud call —
    /// never the hard-coded heuristic template (see `fetchBreakdown`'s doc comment for how that's
    /// ruled out). Empty is not a valid case here; `fetchBreakdown` maps an empty result to `.failed`.
    case loaded([BreakdownStep])
    /// Cloud parsing isn't usable AT ALL right now for a KNOWN reason determined before ever
    /// calling the router — not signed in, or never opted into cloud parsing
    /// (`AppState.cloudParseConsent != true`). Deliberately distinguished from `.failed` (which
    /// means an attempt was actually made) so `TaskBreakdownView` can point the user at Settings/
    /// sign-in instead of suggesting "try again."
    case unavailable
    /// Cloud was attempted (preconditions were met) but produced nothing usable — offline, quota
    /// exhausted server-side, or a decode failure. (2026-07-28: `IntentRouter.breakdown` used to
    /// have an unconditional hard-coded heuristic-template fallback here too — `HeuristicNLParser
    /// .breakdown`, `NLParser.swift` — which `fetchBreakdown` diffed the result against to catch
    /// it in disguise; that fallback is now disconnected from the router entirely, so an empty/
    /// non-real result reaches here as a plain empty array, not a template needing a diff.)
    case failed
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
    /// 2026-07-28 (confirm-list data layer, Việc 1): ticked by default — the common case is the
    /// user wants every drafted task in the batch saved. Unticking (future `PopoverView` checkbox,
    /// lượt 2b) excludes this draft from `confirmSave()` entirely: not created, not eligible as an
    /// intra-batch `.taskDone` target (see `intraBatchTaskDone` below), nothing. Defaulting `true`
    /// is exactly what makes today's behavior fall out unchanged — every existing call site
    /// builds a fresh `ConfirmDraft` and never touches this field, so `confirmSave()` still saves
    /// every draft it's handed, same as before this field existed.
    var isIncluded: Bool = true
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
    /// 2026-07-28 (confirm-list data layer, Việc 2 — real gap fix, not a new feature toggle):
    /// `task.conditions` indices of `.taskDone` cases resolved against ANOTHER DRAFT in the SAME
    /// batch rather than an already-persisted task — "xong task A thì tạo task B" said in one
    /// breath makes A and B together, so A is nowhere in `openTasks` for `preResolveConditions` to
    /// find; without this, that dependency was silently dropped at save (see that method's own
    /// doc comment). The value is the OTHER `ConfirmDraft`'s `id`, deliberately NOT a real task
    /// UUID — that task doesn't exist until `confirmSave()`'s first pass creates it. Kept as a
    /// SEPARATE map from `resolvedTaskDone` (never both set for the same index) so a real,
    /// already-persisted resolution can never be confused with a same-batch one that still needs
    /// `confirmSave()`'s second pass to become a real edge — see that method's doc comment for
    /// the two-pass save this drives.
    var intraBatchTaskDone: [Int: ConfirmDraft.ID] = [:]
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
    /// 2026-07-28 (confirm-list data layer, Việc 3): up to 3 already-persisted tasks whose title
    /// looks like it might BE this same task, worth surfacing so the user can say "oh, I already
    /// have that" instead of ending up with two rows for the same thing. Computed EXACTLY ONCE,
    /// right when this draft is created (`AppState.buildConfirmDrafts`) — never recomputed as the
    /// user edits chips/title (self-review "performance": that would be an O(n) `openTasks` scan
    /// per keystroke). See `AppState.duplicateCandidates(for:in:)` for the threshold and why it's
    /// deliberately looser than `preResolveConditions`'s auto-resolve bar.
    var duplicateCandidates: [UUID] = []
    /// The user's call on what to do about `duplicateCandidates` — constitution II forbids ever
    /// picking `.useExisting` FOR the user, so this always starts (and stays, absent explicit
    /// input from a future `PopoverView` picker, lượt 2b) at `.addNew`. `Equatable` is declared
    /// explicitly (rather than relying on synthesis) per this task's own technical constraints.
    enum DuplicateResolution: Equatable {
        /// Default: create a brand-new task, exactly like today (no duplicate handling existed
        /// before this field).
        case addNew
        /// The user explicitly said "that's the same task" — `confirmSave()` merges this draft's
        /// resolved attributes/conditions INTO the existing task at this id instead of creating a
        /// second row. Never reached without an explicit user choice.
        case useExisting(UUID)
    }
    var duplicateResolution: DuplicateResolution = .addNew
    /// User-edited title from the confirm card's editable title field (`PopoverView.taskDraftCard`).
    /// `nil` until the user actually types something — mirrors the Windows port's
    /// `ConfirmDraft.EditedTitle` (`voci-windows/windows/.../CaptureFlowService.cs:126-134`), but
    /// written through `AppState.updateDraftTitle(_:forDraft:)` rather than an object reference,
    /// since this is a `struct` (see below). Never written into `task.title` directly — `ParsedTask`
    /// stays exactly what the parser/router produced, same "never mutated in place" contract this
    /// whole struct's header comment already documents for every other field.
    var editedTitle: String?
    /// The title actually rendered and saved: the user's edit if there is one and it isn't blank
    /// after trimming, else the parser's original `task.title`. A whitespace-only edit silently
    /// falls back rather than blocking Save or showing an error (constitution V — glance-and-dismiss,
    /// never a dead end).
    var effectiveTitle: String {
        guard let editedTitle else { return task.title }
        // Newlines are flattened, not just trimmed at the ends: the confirm card's title field is
        // multi-line so it can WRAP, never so a task title can contain line breaks. If Return ever
        // reaches the field instead of saving (see PopoverView's own note on `.onKeyPress`), the
        // break dies here rather than in the task list.
        let flattened = editedTitle
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? task.title : trimmed
    }
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

// MARK: - Sidebar navigation sections (2026-07-27 — port of the Windows reference:
// voci-windows/windows/src/Volar.App/ViewModels/NavSection.cs)
//
// The sidebar's three rows (Sidebar.swift) existed since Wave 1 but only Today did anything;
// Upcoming/Inbox rendered hardcoded counts (12/3) with empty `{}` actions. This enum is what makes
// them navigation rather than decoration. Membership rules live in `Sources/Model/TaskSections.swift`
// — deliberately NOT here, same separation the Windows original draws between `NavSection.cs` and
// `TaskSections.cs`.
enum NavSection: Sendable, Equatable {
    case today, upcoming, inbox
}

/// One day's worth of Upcoming rows. `header` is pre-formatted ("Tomorrow" / "Wed, Mar 18") so
/// `TodayView` stays free of date formatting, matching how `todayDateLabel` is already handed over
/// ready to render there. Mirrors Windows `UpcomingDayGroup` (NavSection.cs:19-26) — `tasks` stands
/// in for that type's `Rows` of row view-models, since this app reuses `TaskItem`/`TaskRow` directly
/// rather than a separate row view-model layer.
struct UpcomingDayGroup: Identifiable, Equatable {
    /// The header text is unique per computation (one entry per calendar day) and stable across
    /// re-renders of the same day, unlike a freshly-minted `UUID()` would be — using it as `id`
    /// keeps SwiftUI's diffing from treating every recompute as an all-new list.
    var id: String { header }
    let header: String
    let tasks: [TaskItem]
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

    // MARK: - Typed capture (⌃⌥T, `Sources/Views/TextCapturePanel.swift`) — "type one line, hit
    // Add task, done." A SEPARATE state machine from `captureState` above, deliberately: the typed
    // popup is a smaller surface with no recording/parsing-in-place/multi-second-wave visuals, and
    // — for the genuinely simple case (2026-07-28, Việc 4: one task, no duplicate hint, no
    // condition) — skips the confirm-card review pause `captureState == .parsed` exists for (see
    // `submitTextCapture()`'s doc comment for exactly why and how it still reuses the SAME
    // underlying save path). Anything more complex hands off to that SAME review pause instead of
    // guessing (`applyTextCaptureParseResult`'s own doc comment). Mutually exclusive with
    // `captureState`'s voice surface by construction (`openTextCapture()`/`handleHotkey()` below,
    // and `VolarApp.swift`'s `syncCapturePanel()`) — never both non-idle/non-closed at once.
    enum TextCaptureState: Sendable, Equatable {
        case closed
        case editing
        case saving
        case saved(titles: [String])
        case failed(String)
    }
    var textCapture: TextCaptureState = .closed
    var textCaptureInput: String = ""
    /// Monotonic guard mirroring `captureSession`'s role (see that property's doc comment) but
    /// scoped to the text-capture surface only. Kept as its OWN counter — never shared with
    /// `captureSession` — because a text capture and a voice capture can never be in flight at the
    /// same time (mutual exclusion is enforced by tearing the OTHER surface down before opening
    /// this one; see `openTextCapture()`), so there is no scenario where one counter needs to
    /// invalidate the other's in-flight work; keeping them separate just avoids one surface's
    /// cancel/retry accidentally bumping — and thereby invalidating — the other's guard for no
    /// reason.
    private var textCaptureSession = 0

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
    /// Which task the "Break down into steps…" context-menu action (`TaskRow.swift`,
    /// `TodayView.swift` x2, `triageBreakdown(_:)` below) was invoked on — `nil` while the sheet
    /// is closed. Kept as a SEPARATE property rather than folding it into `showBreakdown` itself
    /// (e.g. `showBreakdown: TaskItem?`) because `VolarApp.swift` (outside this change's allowed
    /// files) already binds `.sheet(isPresented:)` to the bare `Bool` and constructs
    /// `TaskBreakdownView(onSave:onClose:)` from it; changing that shape would require editing a
    /// file this task is not permitted to touch. `TaskBreakdownView` already receives the full
    /// `AppState` via `.environment(appState)` in that same `VolarApp.swift` wiring, so it reads
    /// this property directly instead of needing a new init parameter — no seam is actually
    /// missing, just routed differently than a single merged property would be.
    ///
    /// Every call site that sets `showBreakdown = true` MUST also set this in the same call
    /// (`openBreakdown(for:)` below is the one place that does both, and is now the only way to
    /// open the sheet) — the two are logically one piece of state, split only by the file-
    /// boundary constraint above. A plain (not `private(set)`) `var`, same convention as
    /// `captureState`/`confirmDrafts`/`textCapture` above: this codebase keeps state-machine
    /// properties directly test-drivable rather than encapsulated behind a setter method, and
    /// `Tests/` (this task's one other allowed location) relies on exactly that to unit-test the
    /// breakdown state machine without awaiting a real network round trip.
    var breakdownTask: TaskItem?
    /// Monotonic token guarding the async breakdown fetch (`fetchBreakdown`, mirrors
    /// `captureSession`/`textCaptureSession`'s exact shape) — bumped by every `openBreakdown(for:)`
    /// and by `closeBreakdown()`, so a fetch already in flight when the sheet is dismissed (by
    /// Cancel/Edit, Esc, or the system sheet-close control — `TaskBreakdownView`'s `.onDisappear`
    /// calls `closeBreakdown()` on ALL of those paths, since `VolarApp.swift`'s `.sheet(
    /// isPresented:)` binding only flips the bare `Bool` and cannot be taught to call back into
    /// this file) can never land on — or worse, silently populate — a DIFFERENT task's freshly
    /// reopened sheet.
    private var breakdownSession = 0
    /// State machine for the real (cloud-routed) breakdown fetch — `TaskBreakdownView` renders
    /// directly off this instead of ever holding its own copy, same "single source of truth,
    /// View is a pure function of AppState" convention as `confirmDrafts`/`captureState` above.
    /// Plain `var`, same test-drivability reasoning as `breakdownTask` above.
    var breakdownFetchState: BreakdownFetchState = .idle
    /// T034/FR-018: the weekly stale-task triage batch card (`TriageView`, sibling-owned §D).
    /// `VolarApp`'s main-window `.task` gates setting this `true` to once per ISO week (mirrors
    /// `frogLastShown`'s once-per-day pattern) and only when `staleTasks` is non-empty — this flag
    /// itself carries no additional gating so previews/tests can drive it directly.
    var showTriage = false
    var reminderBanner: ReminderBanner? = nil
    /// The task currently shown in the detail sheet, by id — `nil` means the sheet is closed.
    /// Kept as an id (not a snapshot) so `detailTask` below always reflects live edits/toggles.
    var detailTaskID: UUID?

    // MARK: - Guided tour (coach-mark walkthrough shown right after onboarding; `TourOverlay`,
    // `TourModel`, `TourAnchor` — `Sources/Views/Tour/*`). Same "additive, not part of the frozen
    // §4 surface" category as the modal/banner state directly above.

    /// True while `TourOverlay` is mounted over the real `TodayView`. `VolarApp.swift`'s main-
    /// window `.task` also reads this as an extra guard on the morning-frog/triage/evening-sweep
    /// sheet gates, so a modal sheet can never stack on top of a running tour.
    var tourActive = false
    /// Index into `TourStop.all` (`TourModel.swift`). `private(set)` — `tourNext()`/`tourBack()`/
    /// `endTour()` below are the only mutators, mirroring `focusIndex`'s own single-writer
    /// convention elsewhere in this file (clamped only through its own dedicated methods).
    private(set) var tourStepIndex = 0
    /// Persisted under `hasSeenTourKey`. The tour auto-starts (`startTourIfNeeded()`) at most once
    /// per install unless the user explicitly re-runs it (`replayTour()`, Settings → "Replay guided
    /// tour").
    private(set) var hasSeenTour: Bool

    // MARK: - Sidebar navigation (2026-07-27) — see the `NavSection`/`UpcomingDayGroup` doc comments
    // above this class for the port note. Same "additive, not part of the frozen §4 surface"
    // category as `tourActive`/`showTriage` above.

    /// Which sidebar section `TodayView`'s main column shows. Today until the user picks otherwise;
    /// deliberately NEVER persisted — reopening the app lands on Today, which is the whole point of
    /// the app (mirrors Windows `TodayViewModel.SelectedSection`'s own doc comment).
    var selectedSection: NavSection = .today

    // MARK: - Collaborators (implementation detail, not part of the frozen §4 surface)

    /// Replaces the v1 `NLParser` direct call (contract "Confirm + materialize" / T025: "Replace
    /// any v1 direct-HeuristicNLParser call with the router"). `IntentRouter` is owned by the
    /// T019 agent (`Sources/Parsing/IntentParsing.swift`, landed) — constructed with its own
    /// default for `foundationModel` (2026-07-28: no more `heuristic:` parameter to default —
    /// that tier was disconnected from the router; see `IntentRouter.init`'s doc comment), wired
    /// here with a real `cloudGate:` (`DefaultCloudParseGate`, bottom of this file) so the
    /// Local↔Cloud choice this file owns
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
    /// Bare type annotation, NOT a declaration-site default (`= VoicePlayback()`) — `voiceChannel`
    /// further down needs to be built from this instance, and Swift's two-phase init rule forbids
    /// reading ANY `self.` stored property (even one with its own default expression) until every
    /// stored property of the class has been assigned. Constructed into a local constant in `init`
    /// instead — see that section's comment for why.
    let voice: VoicePlayback
    let ambientSound = AmbientSound()
    let hotkey = HotkeyManager()
    let speech = SpeechCapture()
    /// Free on-device tier (backlog freemium split). Apple (`speech`) remains the default engine
    /// and the fallback whenever WhisperKit isn't supported/ready.
    let whisper = WhisperKitEngine()
    /// Paid cloud tier.
    let groq = GroqEngine()
    /// Read-only EventKit access (feature: guided-tour "Enable Calendar" step,
    /// `Sources/Views/Tour/TourOverlay.swift`'s final stop). Owned/implemented in
    /// `Sources/Integrations/CalendarAccess.swift` (sibling-owned) — bare type annotation rather
    /// than a declaration-site default (`= CalendarAccess()`) because `calendarSync` below is built
    /// FROM this instance, and a stored property's own default-value expression can't reference a
    /// sibling instance property. Constructed into a local constant in `init` instead (same reason
    /// as `voice` above) so `SettingsView` and `TourOverlay` are still guaranteed to observe the
    /// exact same access/status instance rather than two independently drifting ones.
    let calendarAccess: CalendarAccess
    /// One-way (Volar → Calendar) task mirroring into an app-created "Volar" calendar. Owned/
    /// implemented in `Sources/Integrations/CalendarSync.swift` (sibling-owned) — shares this
    /// exact `calendarAccess` instance (constructed on the line directly above) rather than each
    /// holding its own, so there is exactly one source of truth for EventKit authorization status
    /// across the app. See `syncCalendarMirror()`/`setCalendarMirror(_:)`/`enableCalendarAccess()`
    /// below for how this gets driven — `reconcile(tasks:)` itself is never called from a property
    /// observer or timer, only from explicit choke points after a task-list mutation.
    let calendarSync: CalendarSync

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
    /// Backlog "1 free month of Pro" promo codes: set by a SUCCESSFUL `redeemPromoCode(_:)` so
    /// `SettingsView` can show a one-line "Pro until <date>" confirmation, mirroring how
    /// `accountError` already gives that same method's FAILURE path somewhere to land instead of
    /// inventing a parallel notification/toast mechanism. `nil` = nothing to confirm (fresh
    /// session, or the last redeem attempt failed/hasn't happened) — deliberately never cleared
    /// automatically on the NEXT unrelated account action (matches `accountEmail`/`accountTier`'s
    /// own "stays until explicitly replaced" convention elsewhere in this section), only ever
    /// overwritten by another successful redeem.
    var lastRedeemedUntil: Date?
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
    /// Guided-tour "seen" flag (`Sources/Views/Tour/*`). `V1` suffix mirrors `VolarApp.swift`'s own
    /// `hasOnboardedV1` `@AppStorage` key versioning convention, so a future tour redesign can force
    /// everyone through it again just by bumping the suffix, without touching this file's read/write
    /// call sites (`init` below / `endTour()` further down).
    private static let hasSeenTourKey = "volar.hasSeenTourV1"

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
        // Cloud-first default (product decision, 2026-07-27): a NEVER-PERSISTED user gets `.groq`
        // now, not `.appleOnDevice` — the server side (Groq speech, free tier at 20/day) is live,
        // so defaulting to on-device meant it went unused. This ONLY changes the fallback on the
        // right of `??`; `SpeechEngineChoice(rawValue:)` still parses whatever string is ACTUALLY
        // persisted first, so a user who already picked an engine (in Settings, `setSpeechEngine`
        // below) keeps exactly that choice on every future launch — this line only fires for a key
        // that was never written. The existing degradation ladder is untouched: `selectedEngine`
        // (below) still falls back to `speech` (Apple on-device) whenever Groq isn't actually usable
        // — not configured (no signed-in session: `GroqEngine.isConfigured` requires
        // `KeychainStore.loadSession() != nil`, and ONLY that as of 2026-07-27 — the `&&
        // Entitlements.cachedIsPro` half was removed when cloud speech opened to the free tier at
        // 20/day, see `GroqTranscriptionClient.swift`) or `groqDegradedThisSession` (a mid-run
        // 403/429). So a signed-out user with this
        // new default still transcribes 100% on-device on every capture, exactly as before — the
        // default only changes WHICH engine gets attempted first once an account is configured.
        self.speechEngineChoice = SpeechEngineChoice(rawValue: UserDefaults.standard.string(forKey: Self.speechEngineKey) ?? "") ?? .groq
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
        // Guided tour: read-only override, same shape as every other persisted-choice read above —
        // absent means "never run before" (the honest default for a fresh install), so `Bool` here
        // needs no fallback expression the way `speechEngineChoice`/`voiceDeliveryMode` do.
        self.hasSeenTour = UserDefaults.standard.bool(forKey: Self.hasSeenTourKey)
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
        // FIX 6: `calendarSync` takes `calendarAccess` as a constructor argument, so — same
        // reasoning as the `voice`/`voiceChannel`/`reminderGate` locals a few lines below — it
        // must be assigned here inside `init`'s body rather than at its own declaration site
        // (`let calendarSync = CalendarSync(access: calendarAccess)` right next to
        // `calendarAccess`'s declaration would not compile: a stored property's own default-value
        // expression cannot reference a sibling instance property, since `self` isn't fully
        // available yet at that point).
        //
        // 2026-07-27 FIX: this used to read `self.calendarAccess` directly here, on the theory that
        // a stored property with its own declaration-site default expression is "already
        // initialized" and therefore safe to read early. That's wrong — Swift's two-phase init
        // rule (the compiler's "safety check 4") forbids reading ANY `self.` stored property, no
        // matter how it's initialized, until EVERY stored property of the class has been assigned;
        // at this point `voiceChannel`/`reminderGate`/`scheduler`/`delegation`/`appLinkHandler`
        // (all assigned further down this same init) are still unset, so the read was illegal and
        // would fail to compile the first time this file was ever built on a Mac (it never had
        // been — see backlog.md). Fixed by building `calendarAccess` into a LOCAL constant first
        // and passing the LOCAL (never `self.calendarAccess`) into `CalendarSync`.
        let calendarAccess = CalendarAccess()
        self.calendarAccess = calendarAccess
        self.calendarSync = CalendarSync(access: calendarAccess)
        // Phase 4 (T033): construct the reminder subsystem once `store` (the init parameter,
        // already mirrored into `self.store` at the very top of this init) is settled.
        //
        // 2026-07-27 FIX: same bug and same fix as `calendarAccess` immediately above — `voice`,
        // `voiceChannel`, and `reminderGate` are all built into LOCAL constants and passed as
        // locals (never as `self.voice` / `self.voiceChannel` / `self.reminderGate`) into whatever
        // needs them, because at this point in `init` the class's stored properties are still only
        // partially assigned (`delegation`/`appLinkHandler` come later), so no `self.` property
        // read is legal yet regardless of whether that particular property already holds a value.
        let voice = VoicePlayback()
        self.voice = voice
        let voiceChannel = VoiceReminderChannel(playback: voice)
        self.voiceChannel = voiceChannel
        let reminderGate = ReminderContextGate()
        self.reminderGate = reminderGate
        if let store {
            let realScheduler = ReminderScheduler(store: store, voice: voiceChannel, gate: reminderGate)
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
            // Must pair with the line above: `AccountService.signOut()` only clears the SESSION.
            // The tier snapshot lives in `Entitlements` (UserDefaults), and leaving it behind
            // makes `Entitlements.cachedIsPro` report Pro for a signed-out user at next launch.
            await Entitlements.shared.clearEntitlementCache()
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
                // Same pairing as `signOutAccount()` above — the account is gone server-side, so
                // the cached Pro snapshot must go with it.
                await Entitlements.shared.clearEntitlementCache()
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

    /// Backlog "1 free month of Pro" promo codes. Same shape as every other method in this
    /// section — `accountBusy` flip, one `_Concurrency.Task`, `defer` clears the busy flag, result
    /// mirrored into `@Observable` state, failure into `accountError`. `code` is passed straight
    /// through to `AccountService.redeemPromoCode` UNTOUCHED (no trimming/uppercasing here) — that
    /// method owns the ONE normalization step for the whole client (see its doc comment); this
    /// method only trims to decide whether the field is blank, which is a UI no-op guard, not a
    /// second normalization site feeding the network request.
    func redeemPromoCode(_ code: String) {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        accountBusy = true
        accountError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                let result = try await AccountService.shared.redeemPromoCode(code)
                // Source of truth stays the SERVER: never hand-set `accountTier = .pro` (or
                // anything else) from `result` directly — `refreshAccountState()` re-reads tier/
                // quota from `subscription/status` exactly like every other successful account
                // action above does, so a local guess about what was just granted can never drift
                // from what the account actually has.
                self.refreshAccountState()
                // `lastRedeemedUntil` is purely a display convenience for the confirmation banner —
                // reuses the SAME ISO8601-with-fractional-seconds fallback `ParsedTaskValidation`
                // already defines (`Sources/Parsing/IntentParsing.swift`) rather than hand-rolling a
                // second date parser, since `RedeemResult.expiresAt` is the same
                // Supabase-timestamp-shaped string every other `expiresAt` field in this file's
                // sibling `AccountModels.swift` already is. A parse failure just leaves the prior
                // confirmation (or `nil`) in place — the redemption itself already succeeded
                // (`refreshAccountState()` above is unaffected), so this is display-only best effort.
                if let expiresAt = result.expiresAt, let date = ParsedTaskValidation.parseISO8601(expiresAt) {
                    self.lastRedeemedUntil = date
                }
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

    // MARK: - Sidebar sections (Upcoming/Inbox) — 2026-07-27, port of Windows
    // `TodayViewModel.RefreshSections` (ViewModels/TodayViewModel.cs:609-647). Membership itself
    // lives in `TaskSections` (Sources/Model/TaskSections.swift); everything here is just deriving
    // the sidebar's live counts + `TodayView`'s Upcoming/Inbox bodies from the same `openTasks`
    // snapshot Today already uses, so the three sections can never disagree about what exists.

    /// Local-midnight-tomorrow cutoff, recomputed from the live clock on every access (same
    /// no-cached-state convention as `activeTask` above) — `TimeZone.current`, since "after today"
    /// is inherently a LOCAL calendar concept (mirrors Windows `TodayViewModel`'s own
    /// `TimeZoneInfo.Local` default, wired at the same call-site layer rather than baked into the
    /// pure `TaskSections` functions themselves).
    private var startOfTomorrow: Date {
        TaskSections.startOfTomorrow(now: clock(), timeZone: .current)
    }

    /// Upcoming's rows, grouped by local calendar day and ordered earliest-first — the sidebar
    /// nav count is `dated.count` (`upcomingNavCount` below), not `upcomingGroups.count` (one per
    /// GROUP, not per task).
    var upcomingGroups: [UpcomingDayGroup] {
        let cutoff = startOfTomorrow
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let dated: [(date: Date, task: TaskItem)] = openTasks.compactMap { task in
            guard let date = TaskSections.upcomingDate(task, startOfTomorrow: cutoff) else { return nil }
            return (date, task)
        }

        // Bucket by local calendar day while preserving ascending date order within (and across)
        // buckets — `order` records first-seen-day order so groups themselves come out earliest-day
        // first, matching the Windows `OrderBy(...).GroupBy(...)` pipeline this ports.
        var order: [Date] = []
        var buckets: [Date: [TaskItem]] = [:]
        for entry in dated.sorted(by: { $0.date < $1.date }) {
            let day = calendar.startOfDay(for: entry.date)
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(entry.task)
        }

        let tomorrow = calendar.startOfDay(for: cutoff)
        return order.map { day in
            let header = day == tomorrow
                ? "Tomorrow"
                : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            return UpcomingDayGroup(header: header, tasks: buckets[day] ?? [])
        }
    }

    /// Sidebar nav count for Upcoming — one per TASK, not per day group (a day with 3 tasks counts
    /// as 3, mirroring Windows `UpcomingNavCount = dated.Count`).
    var upcomingNavCount: Int {
        openTasks.filter { TaskSections.isUpcoming($0, startOfTomorrow: startOfTomorrow) }.count
    }

    /// Inbox's rows — a flat list, deliberately: the whole definition of Inbox is "has no date and
    /// no dependency", so there is nothing to group BY. Newest first, because in a voice-first app
    /// the thing you just said is the thing you are still thinking about (mirrors Windows
    /// `InboxTasks`'s own `OrderByDescending(CreatedAt)`).
    var inboxTasks: [TaskItem] {
        openTasks.filter { TaskSections.isInbox($0) }.sorted { $0.createdAt > $1.createdAt }
    }

    var inboxNavCount: Int { inboxTasks.count }

    // MARK: - Task CRUD

    func addTask(_ t: TaskItem) {
        let before = tasks
        tasks.insert(t, at: 0)
        store?.add(t)
        // WG-1 (constitution IV): every newly created dated task must actually get its reminders
        // scheduled — a no-op for an undated task (`ReminderRecord.derive` returns empty).
        scheduler?.scheduleReminders(taskId: t.id)
        notifyEligibilityAndScheduleResurface(before: before, now: clock())
        // FIX 6: a new task can carry a deadline from the moment it's created (membership change
        // + possible new deadline) — keep the calendar mirror in step.
        syncCalendarMirror()
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
            // FIX 6: done-state just flipped (the exact field `isDesired` filters on) — no-store
            // fallback (previews/tests) still needs this so `calendarSync`'s self-guards see it.
            syncCalendarMirror()
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
        // FIX 6: done-state changed (T037's completion funnel — `confirmVoiceDone`'s `.complete`,
        // `sweepComplete`, and the plain UI toggle all route through here), and `TaskStore.toggle`
        // can also reset a recurring task back to `.todo` with a FRESH deadline in place — both are
        // exactly the fields `CalendarSync.isDesired`/`eventWindow` key off of.
        syncCalendarMirror()
    }

    /// Store-backed path: `TaskStore.delete` strips the id from every other task's `.taskDone`
    /// conditions and nulls children's `parentId` (validation rule 4), so `tasks` is refreshed
    /// from the store afterward rather than just removing the one row — same rationale as
    /// `toggleDone` above. No-store fallback keeps the old in-memory-only behavior.
    func deleteTask(_ id: UUID) {
        guard let store else {
            tasks.removeAll { $0.id == id }
            // FIX 6: membership change (no-store fallback) — see `toggleDone`'s own no-store
            // branch for why this still needs calling even without a real `TaskStore`.
            syncCalendarMirror()
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
        // FIX 6: membership change — `reconcile(tasks:)`'s own "no longer desired" pass (which a
        // deleted task's id will now fall into, since it's not in `tasks` at all anymore) is what
        // actually removes its mirrored event, if any.
        syncCalendarMirror()
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
        // FIX 6: `tasks` just changed (possibly, if `refreshFromStore` picked up an out-of-band
        // mutation — see this method's own doc comment above) — keep the mirror in step. Cheap/
        // safe even when nothing actually changed: `reconcile(tasks:)` self-guards on
        // `mirrorEnabled`/access and diffs against `eventMap`, so a no-op refresh costs one
        // `isDesired` filter pass and nothing else.
        syncCalendarMirror()
    }

    // MARK: - Calendar mirroring wiring (FIX 6: nothing called `CalendarSync.reconcile(tasks:)`
    // before this — the mirror was constructed but never actually driven).

    /// Thin wrapper around `calendarSync.reconcile(tasks:)` — the single seam every task-list
    /// mutation choke point below calls through, so there is exactly one line to read to see what
    /// "keep the calendar mirror in sync" means. Safe to call often: `reconcile(tasks:)` itself
    /// never throws, and no-ops almost immediately when access isn't granted or mirroring is off
    /// (see that method's own early guards, `CalendarSync.swift`).
    private func syncCalendarMirror() {
        calendarSync.reconcile(tasks: tasks)
    }

    /// Settings' mirror toggle routes here (never straight to `calendarSync.setMirrorEnabled(_:)`)
    /// so flipping it ON mirrors immediately — persisting the flag alone wouldn't create any
    /// events until whatever task mutation happens to come next, which could be a while for a user
    /// who just enabled the feature and is now looking at their calendar for the first result.
    func setCalendarMirror(_ enabled: Bool) {
        calendarSync.setMirrorEnabled(enabled)
        syncCalendarMirror()
    }

    /// The tour's "Enable Calendar" button and Settings' permission button both call this instead
    /// of `calendarAccess.requestAccess()` directly, for the same "don't wait for the next
    /// coincidental task edit" reasoning as `setCalendarMirror(_:)` above: a fresh grant should let
    /// an already-enabled mirror populate the calendar right away, not just update `status`.
    func enableCalendarAccess() async {
        await calendarAccess.requestAccess()
        syncCalendarMirror()
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

    /// The REAL "user pressed the hotkey / tapped the create-task button" entry point — ⌃⌥M
    /// (`HotkeyManager`), the sidebar mic button, and the morning-frog voice CTA all route here
    /// instead of `toggleCapture()` above (kept as-is for whatever else still calls it directly;
    /// see call-site notes in `HotkeyManager.swift`/`Sidebar.swift`/`MorningFrogView.swift`).
    ///
    /// `toggleCapture()`'s plain two-way branch (`.recording` -> stop, everything else -> start)
    /// has no case for "a confirm card is already up": pressing the hotkey again while
    /// `captureState == .parsed` used to blow the pending confirm away and open a brand-new
    /// recording session instead of doing what a user pressing "the capture key" again obviously
    /// means — save what's already parsed. This method fixes exactly that, and adds the guard the
    /// old code never had: several other states are ALSO a pending yes/no question the hotkey must
    /// never silently answer for the user (constitution II) —
    /// `voiceDoneConfirm`/`voiceDoneNoMatchTranscript` (T036's glance-and-dismiss voice-done card)
    /// and `pendingCloudConsent`/`pendingServerConsent` (the one-time privacy opt-ins, both of
    /// which reuse `captureState == .error` as their prompt surface — see those properties' own
    /// doc comments). None of those four are things "press capture again" should resolve, so this
    /// bails out before even looking at `captureState` when any of them is active.
    func handleHotkey() {
        // Mutual exclusion with the typed-capture popup (⌃⌥T, `openTextCapture()` below): pressing
        // ⌃⌥M while that popup is open closes it first — "whichever hotkey the user pressed wins"
        // (task brief). Falls through to the exact same guard/switch below afterward, so ⌃⌥M's own
        // toggle semantics are completely unchanged by this; it only ever adds "and also close the
        // OTHER capture surface first" as a side effect when there's something to close.
        if textCapture != .closed {
            cancelTextCapture()
        }

        guard voiceDoneConfirm == nil,
              voiceDoneNoMatchTranscript == nil,
              !pendingCloudConsent,
              !pendingServerConsent
        else { return }

        switch captureState {
        case .recording:
            stopCapture()
        case .parsed:
            confirmSave()
        case .parsing, .saving:
            // Mid-flight — nothing sane to toggle to; a stray hotkey press here is a no-op rather
            // than racing `finishRecording`/`confirmSave`.
            break
        case .idle, .done, .error:
            startCapture()
        }
    }

    // MARK: - Typed capture (⌃⌥T) — "type one line, hit Add task, done."
    //
    // Voice capture's pipeline (unchanged, see above): `finishRecording` -> `proceedToCapture`
    // (one-time cloud-parse consent gate) -> `runParse` (parses, builds `confirmDrafts`) ->
    // user reviews the confirm card -> `confirmSave()` commits (batching / `store.addBatch`
    // chunking / `tasks = store.fetchAll()` / `notifyEligibilityAndScheduleResurface` /
    // `scheduleRemindersForSavedItems` / `syncCalendarMirror` / `finishSaveUI`). The typed flow
    // below shares that exact same `buildConfirmDrafts`/`confirmSave()` pipeline — parse -> build
    // `confirmDrafts` the way `runParse` does -> either save immediately (the genuinely simple
    // case: one task, no duplicate hint, no condition of any kind) or hand off to the SAME
    // confirm-card review the voice flow uses (2026-07-28, Việc 4 — see
    // `applyTextCaptureParseResult`'s own doc comment for exactly which case is "simple" and why).
    // Either way this reuses `confirmSave()` verbatim (not a parallel save path) when it does
    // save — every side effect `confirmSave()` produces for a voice save (reminders scheduled,
    // calendar mirror synced, eligibility/resurface diff computed, `TaskStore.maxBatchSize`-
    // chunked `addBatch` commits) happens exactly the same way for a typed save.

    /// Opens the typed-capture popup. ⌃⌥T (`HotkeyManager`) is the only real caller.
    func openTextCapture() {
        // Mutual exclusion (task brief: "whichever hotkey the user pressed wins" — never show
        // both capture surfaces at once): opening the typed popup while ANY voice-side surface is
        // pending — an in-progress recording, a parsed-but-unsaved confirm card, a voice-done
        // confirm, or a cloud/server consent prompt — tears all of it down uniformly via the
        // existing `cancelCapture()` (see that method's own doc comment for the exact list it
        // clears). `captureState != .idle` is true for every one of those cases, so this single
        // check covers all of them without re-deriving the list here.
        if captureState != .idle {
            cancelCapture()
        }
        textCaptureSession += 1
        textCapture = .editing
        textCaptureInput = ""
    }

    /// Esc, or ⌃⌥M stealing the surface back (`handleHotkey()` above) — closes the popup and
    /// discards whatever was typed. Bumping `textCaptureSession` invalidates any parse still in
    /// flight from a `submitTextCapture()` call the user is backing out of (see that method's
    /// stale-result guard).
    func cancelTextCapture() {
        textCaptureSession += 1
        textCapture = .closed
        textCaptureInput = ""
    }

    /// Parses `textCaptureInput` and saves it — the typed equivalent of the voice flow's
    /// `finishRecording` -> `runParse` -> (review pause) -> `confirmSave()`. Skips the review
    /// pause ONLY for the genuinely simple case (see this section's header comment and
    /// `applyTextCaptureParseResult`'s own doc comment for exactly which case that is, 2026-07-28
    /// Việc 4); anything more complex hands off to the same review pause the voice flow uses.
    /// Sync entry point; the actual parse is async, so
    /// this hops through `_Concurrency.Task { @MainActor in ... }` exactly like `runParse` does,
    /// with the same before-the-`await` session-token capture/guard pattern (`textCaptureSession`,
    /// mirroring `captureSession`) so a user who hits Esc mid-parse can never have a stale result
    /// land back on a popup they've already closed/reopened.
    ///
    /// CLOUD-CONSENT DIFFERENCE FROM THE VOICE PATH (deliberate — task brief): voice capture routes
    /// through `proceedToCapture`, which interrupts with the one-time cloud-parse consent prompt
    /// (`pendingCloudConsent`/`captureState = .error`) the FIRST time a parse is ever attempted.
    /// This method deliberately does NOT do that — a tiny "type one line" popup is the wrong
    /// surface to interrupt with a privacy decision; the whole point of this feature is "type →
    /// Add task → done" with no PRIVACY pause (unrelated to the separate confirm-card review pause
    /// a complex parse can still trigger, Việc 4 above). Instead this calls `router.parse` directly.
    /// `IntentRouter` still applies its own `cloudGate.isOptedIn()` (+ `isOnline()`) gate
    /// internally regardless of caller (see `IntentRouter.parse` in `IntentParsing.swift`), so an
    /// un-opted-in user simply gets on-device (Heuristic/FoundationModel) parsing here — nothing
    /// about their text ever reaches Cloud without the SAME consent the voice flow's one-time sheet
    /// (or the Settings parse-engine picker) already gates. The user can opt in from either of
    /// those two existing surfaces; this popup just never asks.
    func submitTextCapture() {
        // Defensive: the "Add task" button/`.onSubmit` are both disabled/no-ops while `.saving`
        // per `TextCaptureView`, but this guards the method itself against a double-submit race
        // (e.g. Return arriving a frame after a click already started saving).
        guard textCapture != .saving else { return }
        let trimmed = textCaptureInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        textCapture = .saving
        textCaptureSession += 1
        let session = textCaptureSession
        let now = clock()
        let titles = openTasks.map(\.title)

        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let results = await self.router.parse(trimmed, now: now, openTaskTitles: titles)
            self.applyTextCaptureParseResult(results, session: session)
        }
    }

    /// The synchronous back half of `submitTextCapture()` — split out from the `await
    /// router.parse(...)` call above SPECIFICALLY so it's directly unit-testable without awaiting
    /// a real (async, even if not truly network-bound for the on-device tiers) parse call, same
    /// precedent as `resolveCloudMatch` elsewhere in this file (see that method's own doc comment).
    /// Tests can simulate "the parse came back with N results" or "the session went stale before
    /// the parse returned" by calling this directly with a hand-built `[ParsedTask]` and/or a
    /// stale `session` token, instead of needing a real `IntentRouter` round trip.
    ///
    /// Not `private` for exactly that reason — every OTHER piece of `submitTextCapture()`'s logic
    /// (the empty-input guard, the `.saving` re-entrancy guard, the session bump, the delayed
    /// auto-dismiss) is either trivially pure or already covered indirectly through this method,
    /// but the stale-session guard and the zero-drafts failure path specifically live here because
    /// they can only be exercised AFTER an (async) parse result exists.
    func applyTextCaptureParseResult(_ results: [ParsedTask], session: Int) {
        // Stale? Esc (`cancelTextCapture`) or a second submit happened while this parse was in
        // flight — mirrors `runParse`'s own `captureSession`/`captureState` guard exactly, just
        // against the text-capture counter/state instead of the voice ones.
        guard textCaptureSession == session, textCapture == .saving else { return }

        // Same construction `runParse` uses: cap to `TaskStore.maxBatchSize`, pre-resolve the
        // "easy" `.taskDone` conditions (intra-batch included, Việc 2), and compute the conflict
        // advisory + duplicate hint (Việc 3) ONCE against a single shared `conflictNow` clock read
        // shared by every draft in the batch (T074 — never recomputed per draft). Shared with
        // `runParse` via `buildConfirmDrafts` so the two entry points can't drift apart.
        let capped = Array(results.prefix(TaskStore.maxBatchSize))
        let conflictNow = clock()
        let drafts = buildConfirmDrafts(from: capped, conflictNow: conflictNow)

        guard !drafts.isEmpty else {
            // Never close the popup and silently lose what the user typed (task brief) — the
            // field stays populated (`textCaptureInput` untouched) so they can fix and retry. In
            // practice every current `IntentParser` tier guarantees a non-empty result for
            // non-empty input (`IntentRouter.parse`'s own floor fallback,
            // `Sources/Parsing/IntentParsing.swift`), same as `runParse`'s analogous branch — this
            // exists as the defensive floor for whatever a future parser tier might legitimately
            // fail to extract anything from, not a reachable path today.
            textCapture = .failed("Didn't catch that.")
            return
        }

        // Việc 4 (2026-07-28, task brief: "chỉ đi qua confirm khi phức tạp"): the typed popup's
        // whole pitch is "type -> Add task -> done" with NO review pause — but that pitch only
        // holds for the genuinely simple case. The instant there's more than one drafted task, a
        // possible duplicate (Việc 3), or ANY condition at all (including one only resolvable
        // intra-batch, Việc 2) the user is facing a real decision this tiny popup has no UI for
        // (no checkbox, no dependency picker, no merge choice) — silently auto-resolving it here
        // would be exactly the "guess instead of ask" constitution II forbids. So: hand off to the
        // SAME confirm-card review the voice flow already has instead.
        let isSimpleCase = drafts.count == 1
            && (drafts.first?.duplicateCandidates.isEmpty ?? false)
            && (drafts.first?.task.conditions.isEmpty ?? false)
        guard isSimpleCase else {
            // Populate `confirmDrafts` and flip `captureState` to `.parsed` — EXACTLY what
            // `runParse` does on a successful voice parse. `VolarApp.swift`'s existing
            // `observeCaptureState()`/`observeTextCaptureState()` pair (already wired, no view
            // changes needed here — see this method's header comment) reacts to both property
            // changes: closing the typed popup (`textCapture == .closed` hides it, mirroring
            // `cancelTextCapture()`) and presenting the voice popover's confirm-card review
            // (`captureState != .idle` shows it). This file only needs to set the two properties;
            // the mutual-exclusion plumbing (`syncCapturePanel()`/`syncTextCapturePanel()`)
            // already exists and requires no changes.
            confirmDrafts = drafts
            captureState = .parsed
            textCapture = .closed
            textCaptureInput = ""
            return
        }

        // THE REUSE: hand the exact same drafts `runParse` would have produced straight to
        // `confirmSave()` — no parallel materialize/save/schedule/sync logic lives here.
        // `confirmSave()` is synchronous end-to-end except its own trailing 900ms auto-dismiss
        // (`finishSaveUI`, guarded by `captureSession` — untouched by anything in this method), so
        // by the time this call returns, `captureState` already reflects the real outcome: `.done`
        // on success, or `.error` (with `captureErrorDetail` set) if `TaskStore.addBatch` rejected
        // the batch (e.g. a dependency cycle).
        let addedTitles = drafts.map(\.effectiveTitle)
        confirmDrafts = drafts
        confirmSave()

        if captureState == .error {
            // A genuine `TaskStore` rejection (e.g. a dependency cycle) — surface it on the TEXT
            // popup instead, since the user never saw a voice surface for this save.
            // `textCaptureInput` is still untouched at this point (only cleared on the success
            // path below), so — same as the zero-drafts branch above — the field stays populated
            // for the user to fix and retry.
            textCapture = .failed(captureErrorDetail ?? "Couldn't save.")
            // `captureState == .error` here is purely an artifact of routing through the shared
            // voice-flow method — nothing about the voice popover should be left sitting in an
            // error state for a failure that surfaced through the TEXT popup instead (see the
            // mutual-exclusion note on `syncCapturePanel()` in `VolarApp.swift`: the voice panel
            // is suppressed the whole time `textCapture != .closed` regardless, but there is no
            // reason to also leave stale error state behind for whenever `textCapture` eventually
            // closes and voice capture becomes visible again).
            captureState = .idle
            captureErrorDetail = nil
            confirmDrafts = []
            return
        }

        textCaptureInput = ""
        textCapture = .saved(titles: addedTitles)
        // Same delayed-dismiss convention `finishSaveUI` uses for the voice popover (900ms flash
        // before returning to the closed state), guarded by the SAME `textCaptureSession` token
        // captured above rather than a new timer mechanism.
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.textCaptureSession == session else { return }
            self.textCapture = .closed
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
    /// friendlier presentation of that one bit — no second source of truth.
    ///
    /// Cloud-first default (same product decision as `speechEngineChoice`'s `init` fallback
    /// above): `cloudParseConsent == nil` — NEVER asked, e.g. an install that predates the
    /// onboarding cloud-consent step, or a corrupted/cleared default — now reads as `.cloud`
    /// instead of `.onDevice`. An EXPLICIT decision is untouched either way: `false` (the user
    /// affirmatively declined, either via the voice-capture consent popover's "no" or by picking
    /// on-device in Settings) still reads `.onDevice`; `true` still reads `.cloud`. So this is a
    /// three-way match, not a `== true` binary check — flip only the `nil` case.
    ///
    /// IMPORTANT — this is a DISPLAY default only, not a consent bypass: `parseEnginePreference`
    /// is read by `SettingsView`'s picker, never by the actual gate. The real gate a `nil` value
    /// still trips is `proceedToCapture`'s `guard cloudParseConsent != nil` (below) — an
    /// un-consented user still sees the one-time cloud-parse consent prompt before the FIRST
    /// parse, and `DefaultCloudParseGate.isOptedIn()` (bottom of file) still reads the literal
    /// persisted `UserDefaults` bool, which defaults `false` for an unset key regardless of what
    /// this computed property displays. So a user who has never actually answered the consent
    /// question sees "Cloud" pre-highlighted here (matching the new onboarding default) but Cloud
    /// is still never ATTEMPTED until they explicitly consent somewhere (onboarding's new step,
    /// the in-flow popover, or this same Settings picker) — no opt-in principle is bypassed.
    var parseEnginePreference: ParseEnginePreference {
        cloudParseConsent == false ? .onDevice : .cloud
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
        case .complete(let candidates) where candidates.isEmpty:
            // T0xx: local Jaccard matching found the "xong/done" cue but nothing above the floor —
            // try a cloud semantic-paraphrase rescue before giving up (see
            // `resolveCompletionViaCloud`'s header comment). Every non-empty case below this one is
            // untouched: local matches are never second-guessed by a network round trip.
            resolveCompletionViaCloud(action: .complete, kind: .complete, transcript: transcript)
        case .complete(let candidates):
            presentVoiceDoneConfirm(action: .complete, candidates: candidates)
        case .clearExternal(let candidates) where candidates.isEmpty:
            resolveCompletionViaCloud(action: .clearExternal, kind: .clearExternal, transcript: transcript)
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

    // MARK: - T0xx: cloud completion-paraphrase rescue (empty-candidate case only)
    //
    // `VoiceDone.classify` detects a "xong"/"done"/"hoàn thành" cue and Jaccard-matches the rest of
    // the utterance against open-task titles. A paraphrase ("xong cái vụ report rồi" vs. the real
    // title "Viết báo cáo Q3") shares no tokens and scores 0.0 — `VoiceDone` correctly reports
    // "cue present, nothing matched" as EMPTY candidates (not `.notACompletion`; see
    // `VoiceDoneIntent`'s own doc comment). `finishRecording`'s switch above routes exactly that
    // empty-candidates outcome here instead of straight to `presentVoiceDoneConfirm`, so a cloud
    // semantic-match gets one shot before the user has to complete the task by hand.
    //
    // Quota/consent (self-review point 5): this is the ONLY call site for
    // `IntentRouter.resolveCompletion`, and it is reached ONLY from the two empty-candidates switch
    // arms above — a local match (any non-empty candidate list) never pays a round trip or a quota
    // unit. `IntentRouter.resolveCompletion` itself re-applies the same `cloudGate.isOptedIn()` +
    // `isOnline()` gate `parse` uses, so an un-opted-in user never has a transcript leave the Mac
    // here either.

    /// Confidence bar for a CLOUD-resolved completion match. This is a MODEL-PROBABILITY scale (the
    /// LLM's own reported confidence that its chosen `matchIndex` is correct) — it is deliberately
    /// NOT `VoiceDone.highConfidenceThreshold`, which lives on the JACCARD TOKEN-OVERLAP scale (the
    /// fraction of shared tokens between transcript and title). The two numbers measure different
    /// things on different scales and are never comparable or interchangeable; this constant exists
    /// specifically so nobody is tempted to reuse `VoiceDone.highConfidenceThreshold` here instead.
    /// Not `private` — `resolveCloudMatch` below is exposed for direct unit-testing and tests
    /// reference this constant rather than duplicating the literal.
    static let cloudCompletionConfidenceThreshold = 0.7

    /// `finishRecording`'s `.complete`/`.clearExternal` cases call this INSTEAD of
    /// `presentVoiceDoneConfirm` directly when local Jaccard matching (`VoiceDone`) came back with
    /// ZERO candidates. Cloud is asked to semantically match the utterance against the SAME
    /// open-task titles the local matcher already tried and failed on. A decline/failure/low-
    /// confidence/mismatched-echo/stale-session result all fall through to exactly today's
    /// behavior — `presentVoiceDoneConfirm(action:candidates: [])`, i.e. "no matching task, offer
    /// capture instead." No new UI, no new error banner, no new alert.
    ///
    /// Never marks a task done automatically (self-review point 4): every exit path below either
    /// hands a SINGLE resolved `VoiceMatch` to the EXISTING `presentVoiceDoneConfirm` (same one-tap
    /// confirm the local-match path already uses) or hands it an empty list — there is no path here
    /// that calls `toggleDone`/`confirmVoiceDone` or otherwise mutates a task directly.
    private func resolveCompletionViaCloud(action: VoiceDoneAction, kind: CloudParser.CompletionKind, transcript: String) {
        // Snapshot taken ONCE, before the network call (self-review point 3): the candidate titles
        // sent to Cloud and the task ids resolved back out of the response MUST come from the exact
        // same read of `openTasks`. Rebuilding after the `await` would let a reminder firing or a
        // sync landing mid-flight shift task ordering/membership, so `matchIndex` could end up
        // pointing at a DIFFERENT task than the one the model actually saw. `snapshot` is capped at
        // 100 entries up front (matching `CloudParser.resolveCompletion`'s own internal cap) so the
        // bounds this method re-checks below (`1...snapshot.count`) are checking against the exact
        // same list whose titles were actually put on the wire — not a longer, uncapped list that
        // would let an in-range server index silently resolve against the wrong local task.
        let snapshot: [(id: UUID, title: String)] = Array(openTasks.prefix(100)).map { ($0.id, $0.title) }
        guard !snapshot.isEmpty else {
            presentVoiceDoneConfirm(action: action, candidates: [])
            return
        }

        // Concurrency (self-review point 2): `finishRecording` is synchronous but resolution is
        // async, so this hops through `_Concurrency.Task { @MainActor in ... }` — the same pattern
        // `runParse` uses immediately below for the analogous new-task-parse round trip.
        // `captureState = .parsing` keeps the UI from looking frozen on a stale state during the
        // round trip; `captureSession` is bumped and captured BEFORE the `await` (stale-result
        // guard) so a user who cancels and immediately re-records can never have THIS utterance's
        // cloud match presented against the NEW recording — every exit path below either calls
        // `presentVoiceDoneConfirm` (which sets `captureState = .parsed`, a sane terminal state) or,
        // on a stale session, returns without touching `captureState` at all (the superseding
        // action already put it wherever it needs to be) — never leaves it stuck in `.parsing`.
        captureState = .parsing
        captureSession += 1
        let session = captureSession
        let now = clock()
        let titles = snapshot.map(\.title)

        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let resolution = await self.router.resolveCompletion(transcript, now: now, kind: kind, candidates: titles)
            // Stale? Cancel/a fresh capture/anything else that bumps `captureSession` happened
            // while the cloud round trip was in flight — drop this result entirely rather than
            // presenting a match for an utterance the user already walked away from (mirrors
            // `runParse`'s identical guard).
            guard self.captureSession == session, self.captureState == .parsing else { return }

            guard let match = Self.resolveCloudMatch(resolution, snapshot: snapshot) else {
                // `.none` (model looked, found nothing), `.unavailable` (never got a trustworthy
                // answer), or a failed local safety check — all degrade identically to today's "no
                // matching task" outcome. See `CloudParser.CompletionResolution`'s doc comment for
                // why the transport layer keeps `.none`/`.unavailable` distinct even though this
                // call site does not.
                self.presentVoiceDoneConfirm(action: action, candidates: [])
                return
            }
            // Single resolved match still goes through the EXISTING one-tap confirm card — the
            // user confirms with one tap/word exactly as they would for a local match.
            self.presentVoiceDoneConfirm(action: action, candidates: [match])
        }
    }

    /// Pure decision logic for `resolveCompletionViaCloud`'s safety checks — split out as a
    /// `static` function (not `private`) so it is unit-testable directly, without spinning up a
    /// live `AppState`/`IntentRouter`/network stack (mirrors the file's existing `nonisolated
    /// static` helper convention, e.g. `IntentRouter.cap`/`isValidBreakdown` in
    /// `IntentParsing.swift`, for the same testability reason).
    ///
    /// Off-by-one (self-review point 1): `resolution`'s `index` is the wire's 1-BASED position.
    /// The ONLY conversion to a 0-based array index happens right here, at `snapshot[index - 1]` —
    /// `index == 1` picks `snapshot[0]`, the FIRST candidate, matching the locked contract
    /// ("`candidates[matchIndex - 1]` is the chosen title"). Every other touch point in this
    /// feature (`CloudParser.resolveCompletion`, `IntentRouter.resolveCompletion`) passes `index`
    /// through unchanged — this is deliberately the single place the arithmetic happens, so there
    /// is exactly one place to audit for the off-by-one class of bug this task calls out by name.
    ///
    /// Applies TWO independent safety checks before trusting a server-reported match, plus the
    /// confidence bar, and returns `nil` (⇒ caller treats identically to "no candidates") unless
    /// ALL of the following hold:
    ///   1. `confidence >= cloudCompletionConfidenceThreshold` (model-probability scale, see that
    ///      constant's own doc comment).
    ///   2. `index` is in `1...snapshot.count` — re-checked here even though `CloudParser` already
    ///      validated it against the list length it sent, because `snapshot` (this call's own
    ///      local state) is never trusted to still agree with what the server saw without a fresh,
    ///      local bounds check (constitution II: never trust a remote response transitively).
    ///   3. `title` (the model's verbatim echo of the title it chose) matches, after trimming,
    ///      `snapshot[index - 1].title` exactly. A disagreement means the model hallucinated/
    ///      misindexed — or a candidate title was UTF-16-truncated before being sent (see
    ///      `CloudParser.resolveCompletion`'s 200-unit-per-title cap) and the model echoed back the
    ///      truncated form. Either way this is treated as NO match, never as "trust whichever of
    ///      the two disagreeing values looks more plausible" — the failure mode is a false
    ///      negative (falls back to "no matching task," never wrong), not a false positive.
    static func resolveCloudMatch(
        _ resolution: CloudParser.CompletionResolution,
        snapshot: [(id: UUID, title: String)]
    ) -> VoiceMatch? {
        guard case .resolved(let index, let title, let confidence) = resolution else { return nil }
        guard confidence.isFinite, confidence >= cloudCompletionConfidenceThreshold else { return nil }
        // Bounds check written as two plain comparisons, not `(1...snapshot.count).contains(index)`:
        // `ClosedRange(1...0)` (an empty `snapshot`) TRAPS at range construction before `.contains`
        // ever runs. `resolveCompletionViaCloud` never calls this with an empty snapshot (guarded
        // before the network call), but this function is `static` specifically so it's exercised
        // directly from unit tests too — it must not crash on a malicious/malformed input the caller
        // didn't happen to pre-filter.
        guard index >= 1, index <= snapshot.count else { return nil }
        let expected = snapshot[index - 1] // the ONE off-by-one conversion point, see doc comment above
        guard expected.title.trimmingCharacters(in: .whitespacesAndNewlines)
                == title.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // `VoiceMatch.score` is documented (`VoiceDone.swift`) as a Jaccard token-overlap value in
        // [0, 1]; there is no separate field to carry a match's provenance (local-Jaccard vs.
        // cloud-model-confidence). Both are already bounded to [0, 1] so this never breaks any
        // existing consumer's range assumptions, but it IS a different scale under the same field
        // — flagged here since this is the one place that substitution happens, and `VoiceDone.swift`
        // itself (out of scope for this change) is not touched.
        return VoiceMatch(taskId: expected.id, title: expected.title, score: confidence)
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
            self.confirmDrafts = self.buildConfirmDrafts(from: capped, conflictNow: conflictNow)
            if self.confirmDrafts.isEmpty {
                self.captureErrorDetail = "Didn't catch that."
                self.captureState = .error
            } else {
                self.captureState = .parsed
            }
        }
    }

    /// Shared "parsed tasks -> confirm drafts" pipeline for BOTH `runParse` (voice) and
    /// `applyTextCaptureParseResult` (typed) — kept as ONE implementation (2026-07-28) so Việc 2's
    /// intra-batch `.taskDone` resolution and Việc 3's duplicate hint can never drift between the
    /// two entry points. For a single-task batch with no matching duplicate/condition this reduces
    /// to exactly the original `capped.map { preResolveConditions(ConfirmDraft(task:)) }`
    /// pipeline — nothing else in a 1-draft batch to intra-batch-match against, and an empty
    /// `duplicateCandidates` never changes `confirmSave()`'s outcome — so the default/simple case
    /// is byte-for-byte unchanged.
    private func buildConfirmDrafts(from parsed: [ParsedTask], conflictNow: Date) -> [ConfirmDraft] {
        // Single read, reused for BOTH the duplicate hint and the intra-batch/openTasks
        // `.taskDone` resolution below, so every draft in this batch is scored against the exact
        // same snapshot (the previous code read `openTasks` twice, once inside
        // `preResolveConditions` and implicitly again via `computeConflicts`'s own `tasks` read —
        // harmless since nothing `await`s in between, but one read is simpler to reason about).
        let existingTasks = openTasks
        var drafts = parsed.map { ConfirmDraft(task: $0) }
        // Việc 3.1: duplicate hint computed ONCE here, at draft-creation time — never recomputed
        // per chip edit (self-review "performance"; see `ConfirmDraft.duplicateCandidates`'s doc
        // comment).
        for i in drafts.indices {
            drafts[i].duplicateCandidates = Self.duplicateCandidates(for: drafts[i].effectiveTitle, in: existingTasks).map(\.id)
        }
        drafts = preResolveConditions(drafts, openTasks: existingTasks)
        for i in drafts.indices {
            drafts[i].conflicts = computeConflicts(for: drafts[i], now: conflictNow)
        }
        return drafts
    }

    /// Auto-resolves `.taskDone` conditions the router was itself confident about (>=0.7) — first
    /// against a confident fuzzy title match in `openTasks` (exactly the original v1 behavior),
    /// and — Việc 2 (2026-07-28, closing a real gap, not a new feature): if THAT comes up empty,
    /// against the OTHER drafts in this SAME batch (excluding itself). "Xong task A thì tạo task
    /// B" said in one breath makes A and B together — A is nowhere in `openTasks` yet because it
    /// doesn't exist until `confirmSave()` creates it, so without this second lookup the condition
    /// was silently dropped at save (see `ConfirmDraft.intraBatchTaskDone`'s doc comment). SAME
    /// 0.7 bar for both lookups — constitution II: matching within the batch is a convenience for
    /// what the user already said, never a reason to lower the confidence floor. A batch match is
    /// recorded in `intraBatchTaskDone` (the OTHER DRAFT's id), never `resolvedTaskDone` (which
    /// promises an already-persisted task id) and never a fabricated UUID.
    ///
    /// Takes the WHOLE batch (rather than one draft, the original signature) specifically so each
    /// draft's condition can see every OTHER draft's stable `id`/title before any of them exist as
    /// real tasks — a single-draft signature has no way to look sideways at its siblings. Both
    /// call sites (`buildConfirmDrafts` above) already have the full batch in hand, so this is a
    /// call-site-local change, not a wider API break.
    private func preResolveConditions(_ drafts: [ConfirmDraft], openTasks: [TaskItem]) -> [ConfirmDraft] {
        var drafts = drafts
        for i in drafts.indices {
            for (index, condition) in drafts[i].task.conditions.enumerated() {
                guard case .taskDone(let titleQuery, let confidence) = condition, confidence >= 0.7 else { continue }
                if let match = Self.bestFuzzyMatch(for: titleQuery, in: openTasks), match.score >= 0.7 {
                    drafts[i].resolvedTaskDone[index] = match.id
                    continue
                }
                let siblings: [(id: UUID, title: String)] = drafts.indices
                    .filter { $0 != i }
                    .map { (drafts[$0].id, drafts[$0].effectiveTitle) }
                if let match = Self.scoredMatches(for: titleQuery, candidates: siblings).first, match.score >= 0.7 {
                    drafts[i].intraBatchTaskDone[index] = match.id
                }
            }
        }
        return drafts
    }

    private struct FuzzyMatch { let id: UUID; let score: Double }

    /// Shared token-overlap scorer (Jaccard over whitespace tokens, case/diacritic-insensitive so
    /// Vietnamese input matches sensibly) used by `bestFuzzyMatch` (single best, threshold checked
    /// by the caller) and `duplicateCandidates` (top-3 above a lower bar) — one formula, two
    /// thresholds, rather than two copies of the same loop. Returns every candidate with a
    /// nonzero-union score, sorted by score DESCENDING; `Array.sorted` is stable (Swift 5+), so
    /// candidates tied on score keep `candidates`' original relative order — matching the original
    /// `bestFuzzyMatch`'s "first max-scoring entry wins" behavior exactly for that caller.
    /// // UNVERIFIED: a deliberately simple placeholder heuristic — swap for a real string-
    /// distance/fuzzy library later if parsing quality demands it (backlog candidate).
    /// Which formula `scoredMatches` uses. The two callers want opposite error profiles, so they
    /// must NOT share one — this used to be a single Jaccard score for both, and loosening it
    /// globally would have silently loosened dependency auto-resolution too.
    private enum Similarity {
        /// Jaccard only: `shared / union`. Strict, and strictness is the point for
        /// `preResolveConditions` — a wrong match there commits a real `.taskDone` edge with no
        /// further confirmation, so a false positive is a wrong task graph.
        case strict
        /// `max(jaccard, overlap)` where overlap is `shared / min(|a|, |b|)`. Overlap is the one
        /// that handles "one title is a subset of the other" — restating a stored task more briefly
        /// is the single most common way a real duplicate shows up, and Jaccard scores it terribly
        /// because it counts every extra word in the longer title against the match. Concretely:
        /// "sanitize html tag" vs "sanitize html tags this afternoon" is 2/6 = 0.33 by Jaccard —
        /// under the 0.45 duplicate bar, so the app would silently create a second copy — but
        /// 2/min(3,5) = 0.67 by overlap, which surfaces it.
        case lenient
    }

    private static func scoredMatches(
        for query: String,
        candidates: [(id: UUID, title: String)],
        similarity: Similarity = .strict
    ) -> [FuzzyMatch] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return [] }
        var scored: [FuzzyMatch] = []
        for candidate in candidates {
            let titleTokens = tokenize(candidate.title)
            guard !titleTokens.isEmpty else { continue }
            let union = queryTokens.union(titleTokens).count
            guard union > 0 else { continue }
            let shared = queryTokens.intersection(titleTokens).count
            let jaccard = Double(shared) / Double(union)
            var score = jaccard
            if similarity == .lenient {
                let smaller = min(queryTokens.count, titleTokens.count)
                // `smaller >= 2` guard: with a one-token side, overlap is 1.0 the moment that single
                // token appears anywhere in the other title — "html" would score a perfect match
                // against every task mentioning html, burying the real candidates. Two shared tokens
                // is the cheapest thing that means more than coincidence here.
                if smaller >= 2 {
                    score = max(jaccard, Double(shared) / Double(smaller))
                }
            }
            scored.append(FuzzyMatch(id: candidate.id, score: score))
        }
        return scored.sorted { $0.score > $1.score }
    }

    /// Việc 3.1 (2026-07-28): up to 3 already-persisted tasks that look like they might BE `title`
    /// — a glance-and-decide HINT for the confirm card, never auto-applied (see
    /// `ConfirmDraft.duplicateResolution`'s doc comment: it always starts at `.addNew`). Threshold
    /// (0.45) is DELIBERATELY LOWER than `preResolveConditions`'s 0.7 auto-resolve bar — that's not
    /// a bug, it's the opposite risk profile: an auto-resolved `.taskDone` that's wrong silently
    /// commits a real, wrong dependency edge, so it needs a high bar. This is just a suggestion a
    /// human glances at and can ignore — a false positive here costs one glance; a false negative
    /// costs a full duplicate task silently created (exactly the gap this whole feature closes).
    /// Bounded to 3 so the card never has to render an unbounded list (same defensive-cap
    /// philosophy as `VoiceDoneConfirm`'s candidate list elsewhere in this file).
    private static func duplicateCandidates(for title: String, in openTasks: [TaskItem]) -> [FuzzyMatch] {
        Array(
            scoredMatches(for: title, candidates: openTasks.map { ($0.id, $0.title) }, similarity: .lenient)
                .filter { $0.score >= 0.45 }
                .prefix(3)
        )
    }

    /// O(n) over `openTasks` per condition — at most ~10 conditions in a confirm batch, so this
    /// stays cheap even at hundreds of tasks (self-review "performance"; no picker-side O(n²) —
    /// the picker itself just lists titles). Single best match; `scoredMatches`'s stable sort
    /// means a tie keeps whichever candidate appeared first in `openTasks`, matching this
    /// function's pre-refactor "first max-scoring entry wins" behavior exactly.
    private static func bestFuzzyMatch(for query: String, in openTasks: [TaskItem]) -> FuzzyMatch? {
        scoredMatches(for: query, candidates: openTasks.map { ($0.id, $0.title) }).first
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
        // Việc 2: dismiss wins over EITHER resolution kind — a dropped condition must not linger
        // as an intra-batch target `confirmSave()`'s second pass would otherwise still attach.
        confirmDrafts[index].intraBatchTaskDone[conditionIndex] = nil
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
            // Việc 2: an explicit picker choice always overrides whatever `preResolveConditions`
            // may have auto-matched intra-batch — the two must never both be set for one index.
            confirmDrafts[index].intraBatchTaskDone[conditionIndex] = nil
            confirmDrafts[index].dismissedConditions.remove(conditionIndex)
        } else {
            confirmDrafts[index].dismissedConditions.insert(conditionIndex)
            confirmDrafts[index].intraBatchTaskDone[conditionIndex] = nil
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

    /// The confirm card's editable title `TextField` (`PopoverView.taskDraftCard`) calls this on
    /// every keystroke. `ConfirmDraft` is a VALUE type (`struct`, unlike the Windows port's
    /// `ConfirmDraft` class) — mutating a local copy of the draft would silently lose the edit the
    /// instant that copy goes out of scope, so this MUST reach through `confirmDrafts[index]` the
    /// same way every other chip mutator in this section already does (self-review "value-type
    /// trap": the array is the only thing `PopoverView`/`materialize` actually read back from).
    /// Deliberately does NOT call `logCorrection` — a title edit isn't a chip attribute correction,
    /// it's free-text authorship, same reason `task.title` itself was never a `ChipKind`.
    func updateDraftTitle(_ title: String, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].editedTitle = title
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
    ///
    /// 2026-07-28 (confirm-list data layer): now a THREE-part save rather than a flat map —
    ///
    /// 1. Việc 1: `confirmDrafts.filter(\.isIncluded)` first. An unticked draft is saved nowhere,
    ///    isn't a candidate to merge into, and can't be an intra-batch `.taskDone` target (handled
    ///    below by simply never appearing in `targetID`).
    /// 2. Việc 3: every included draft gets its post-save IDENTITY decided up front — a freshly
    ///    minted id for `.addNew` (explicit, not left to `TaskItem.init`'s own default, so this
    ///    method can look it up again below), or the ALREADY-PERSISTED id for `.useExisting` (that
    ///    draft creates nothing; it merges into the existing task instead, see `mergeTransform`).
    ///    A `.useExisting` target that no longer exists in `before` (deleted between the confirm
    ///    card appearing and Save — this data layer has no live re-poll yet) degrades to `.addNew`
    ///    rather than merging into a dangling id or losing the draft (self-review "no crash/no
    ///    dangling id").
    /// 3. Việc 2: intra-batch `.taskDone` conditions are resolved to real ids via that SAME
    ///    `targetID` map — which is exactly why it has to exist before anything is created: the
    ///    referenced draft can appear later in `confirmDrafts` than the one depending on it. A
    ///    reference to a draft that isn't in `targetID` (unticked, or never existed) is simply
    ///    dropped, never attached to a nonexistent id (self-review "explicit handling of both
    ///    branches", task brief Việc 2.4).
    ///
    /// The store path commits in THREE ordered steps — new tasks (`addBatch`, chunked exactly as
    /// before), then merges (`TaskStore.mergeIntoExisting`), then intra-batch conditions
    /// (`TaskStore.addCondition`) — because step 3 needs every id from steps 1 and 2 to already be
    /// real. A failure in step 1 aborts before steps 2/3 ever run (same "leave `confirmDrafts`
    /// intact, let the user retry" contract the pre-existing catch block already had); a rejected
    /// edge in step 3 drops just that one edge (`try?`) rather than unwinding tasks that, by then,
    /// have already committed — same "partial success beats losing everything over one bad edge"
    /// precedent `TaskStore.sanitizedConditions` already sets for bulk inserts.
    func confirmSave() {
        guard !confirmDrafts.isEmpty else { return }
        captureState = .saving
        let now = clock()
        // T031: snapshot taken BEFORE this batch materializes, so the eligibility diff below sees
        // exactly what this save changed (and nothing from a concurrent mutation elsewhere, since
        // this whole method runs synchronously on @MainActor).
        let before = tasks

        // Việc 1: unticked drafts are saved nowhere and can never be an intra-batch target —
        // simply excluding them from every list below (`targetID`, `itemsToSave`, merges) is
        // enough; nothing downstream needs a separate "is this included?" check.
        let includedDrafts = confirmDrafts.filter(\.isIncluded)
        guard !includedDrafts.isEmpty else {
            // Every draft was unticked (unreachable today — no UI sets `isIncluded = false` yet,
            // see that field's doc comment — but handled explicitly rather than left to crash or
            // silently misbehave once lượt 2b's checkbox exists). Nothing to persist; close out
            // quietly rather than announcing "0 tasks saved" via `finishSaveUI`.
            confirmDrafts = []
            captureState = .idle
            liveTranscript = ""
            return
        }

        // Việc 3 self-review: a `.useExisting` target that vanished since the draft was built
        // (deleted from `before` — this confirm-list has no live re-poll) degrades to `.addNew`
        // rather than merging into a dangling id.
        let currentTaskIDs = Set(before.map(\.id))
        func effectiveResolution(_ draft: ConfirmDraft) -> ConfirmDraft.DuplicateResolution {
            if case .useExisting(let id) = draft.duplicateResolution, !currentTaskIDs.contains(id) {
                return .addNew
            }
            return draft.duplicateResolution
        }

        // Việc 2/3: every included draft's post-save identity, decided BEFORE anything is created
        // so intra-batch `.taskDone` conditions (which may reference a draft appearing later in
        // `confirmDrafts`) always have a real id to resolve against.
        var targetID: [ConfirmDraft.ID: UUID] = [:]
        for draft in includedDrafts {
            switch effectiveResolution(draft) {
            case .addNew: targetID[draft.id] = UUID()
            case .useExisting(let existingID): targetID[draft.id] = existingID
            }
        }

        var itemsToSave: [TaskItem] = []
        var mergeDrafts: [ConfirmDraft] = []
        for draft in includedDrafts {
            guard let id = targetID[draft.id] else { continue } // unreachable: built from includedDrafts above
            let parentTitle: String
            let parentSourceTranscript: String?
            switch effectiveResolution(draft) {
            case .addNew:
                let item = materialize(draft, id: id, now: now)
                itemsToSave.append(item)
                parentTitle = item.title
                parentSourceTranscript = item.sourceTranscript
            case .useExisting:
                mergeDrafts.append(draft)
                // No new `TaskItem` for a merge — but the followUpReview chip below still needs
                // something to name the derived review after; the utterance's own resolved title
                // reads fine even though the merge itself may keep the OLDER task's title.
                parentTitle = draft.effectiveTitle
                parentSourceTranscript = draft.task.sourceTranscript
            }
            // Mi-1: the "+ review after done" chip is dismissible (defaults on, per
            // `ChipKind.followUpReview`'s doc comment) — only materialize the derived `.review`
            // task when the user hasn't dismissed it. `id` here is the SAME post-save identity
            // (fresh or merge-target) an intra-batch condition elsewhere in this batch would also
            // resolve to — a follow-up review is just as valid a dependent either way.
            if draft.task.followUpReview, !draft.dismissed.contains(.followUpReview) {
                itemsToSave.append(materializeFollowUpReview(
                    parentID: id, parentTitle: parentTitle, sourceTranscript: parentSourceTranscript, now: now
                ))
            }
        }

        // Việc 2, pass two's payload: every intra-batch `.taskDone` this batch resolved, translated
        // from "the OTHER draft's id" into "the other draft's REAL post-save id" via `targetID`.
        // Computed once here (pure — no store/`tasks` mutation yet) so both the store and no-store
        // branches below can apply the identical list.
        var intraBatchAttachments: [(ownID: UUID, condition: VolarCore.Condition)] = []
        for draft in includedDrafts {
            guard let ownID = targetID[draft.id] else { continue }
            for (index, referencedDraftID) in draft.intraBatchTaskDone {
                // Dismiss always wins (constitution II) — same guard `resolvedConditions` applies
                // to every other condition kind.
                guard !draft.dismissedConditions.contains(index) else { continue }
                // The referenced draft is unticked, was removed from the batch, or (defensively)
                // never existed: Việc 2.4 says drop the condition rather than point at nothing.
                guard let refID = targetID[referencedDraftID], refID != ownID else { continue }
                intraBatchAttachments.append((ownID: ownID, condition: .taskDone(refID)))
            }
        }

        let mergedTitles = mergeDrafts.map(\.effectiveTitle)
        let mergedIDs = mergeDrafts.compactMap { targetID[$0.id] }
        let savedTitles = itemsToSave.map(\.title) + mergedTitles
        let remindersTargetIDs = itemsToSave.map(\.id) + mergedIDs

        guard let store else {
            // No-store fallback (previews/tests without a TaskStore) — mirrors `addTask`'s own
            // no-store branch: in-memory only, no validation (there is no store to validate against).
            tasks.insert(contentsOf: itemsToSave.reversed(), at: 0)
            // Việc 3: apply each merge directly onto its `tasks` entry — same "no validation, this
            // is the no-store fallback" convention the rest of this branch already follows.
            for draft in mergeDrafts {
                guard let existingID = targetID[draft.id],
                      let index = tasks.firstIndex(where: { $0.id == existingID })
                else { continue }
                tasks[index] = mergeTransform(for: draft)(tasks[index])
            }
            // Việc 2 pass two, in-memory: append each resolved intra-batch condition directly.
            for attachment in intraBatchAttachments {
                guard let index = tasks.firstIndex(where: { $0.id == attachment.ownID }) else { continue }
                if !tasks[index].conditions.contains(attachment.condition) {
                    tasks[index].conditions.append(attachment.condition)
                }
            }
            notifyEligibilityAndScheduleResurface(before: before, now: now)
            scheduleRemindersForSavedItems(remindersTargetIDs) // no-op: `scheduler` is nil without a store
            finishSaveUI(titles: savedTitles)
            // FIX 6: membership change (new tasks, possibly with new deadlines).
            syncCalendarMirror()
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
            // Việc 3: merges only ever touch an ALREADY-persisted task, so they never depend on
            // anything the chunk loop above just created — but doing them right after keeps every
            // store mutation for this `confirmSave()` grouped before the single refresh below.
            for draft in mergeDrafts {
                guard let existingID = targetID[draft.id] else { continue }
                store.mergeIntoExisting(existingID, applying: mergeTransform(for: draft))
            }
            // Việc 2, pass two: attach every intra-batch `.taskDone` now that both ends (new OR
            // merged) are real, persisted ids. `try?` — see this method's own doc comment for why
            // a rejected edge here (e.g. two drafts in the same utterance depending on each other)
            // drops just that one edge instead of unwinding an already-committed save.
            for attachment in intraBatchAttachments {
                try? store.addCondition(attachment.condition, to: attachment.ownID)
            }
            // Phase-2 refresh-from-store convention (auto-advance + menu bar stay correct).
            tasks = store.fetchAll()
            notifyEligibilityAndScheduleResurface(before: before, now: now)
            scheduleRemindersForSavedItems(remindersTargetIDs)
            finishSaveUI(titles: savedTitles)
            // FIX 6: membership change (new tasks, possibly with new deadlines) — every chunk
            // committed successfully by this point.
            syncCalendarMirror()
        } catch {
            // Cycle rejection / batch-too-large / any other `TaskStoreError` surfaces its
            // human-readable message instead of crashing; `confirmDrafts` is left intact so the
            // user can adjust (e.g. drop a condition) and retry rather than losing the capture.
            // A failure on a LATER chunk (after earlier chunks already committed) is refreshed
            // from the store here too, so the UI never shows stale/duplicate state for the part
            // that did save — the user only re-confirms what's genuinely still outstanding.
            // Merges/intra-batch conditions never ran (they're only reached after the `do` block's
            // chunk loop finishes without throwing), so there is nothing further to unwind here.
            tasks = store.fetchAll()
            notifyEligibilityAndScheduleResurface(before: before, now: now)
            scheduleRemindersForSavedItems(itemsToSave.map(\.id))
            captureErrorDetail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            captureState = .error
            // FIX 6: an earlier chunk may have committed successfully before this failure (see the
            // comment above `tasks = store.fetchAll()` just above) — keep the mirror in step with
            // whatever partial state actually persisted, same as every other refresh in this catch.
            syncCalendarMirror()
        }
    }

    /// Việc 3: the merge-into-existing overlay, as a PURE `TaskItem -> TaskItem` transform so it
    /// can be shared verbatim between the store path (`TaskStore.mergeIntoExisting`, which applies
    /// it via `VolarTask.apply(_:)` behind its own cycle/rule-2 guards) and the no-store fallback
    /// (which applies it directly to a `tasks` element, matching that branch's existing "no
    /// validation" convention). Scalar attributes overwrite the existing value ONLY when
    /// `AppState.resolvedValue` says this draft actually resolved one (present, not dismissed, and
    /// accepted if uncertain — the SAME gate a brand-new task's `materialize(_:id:now:)` already
    /// applies) — `nil` from `resolvedValue` here means "this utterance said nothing about this
    /// attribute," so the existing task's value is left exactly as it was, never cleared. Anh Khôi
    /// deliberately did NOT ask for title/kind/notes to be touched by a merge, so this leaves those
    /// alone. Conditions are UNIONED (de-duplicated), never replaced — anh Khôi: "có thể merge tất
    /// cả condition vào" — intra-batch `.taskDone` entries are excluded from this union on purpose
    /// (same as a brand-new task, `resolvedConditions` never includes them) since they're attached
    /// separately, after every draft's real/merge-target id is known (`confirmSave`'s second pass).
    private func mergeTransform(for draft: ConfirmDraft) -> (TaskItem) -> TaskItem {
        { existing in
            var merged = existing
            if let deadline = resolvedValue(draft.task.deadline, kind: .deadline, draft: draft) {
                merged.deadline = deadline
            }
            if let priorityRaw = resolvedValue(draft.task.priority, kind: .priority, draft: draft) {
                merged.priority = Self.uiPriority(from: priorityRaw)
            }
            if let estimate = resolvedValue(draft.task.estimateMinutes, kind: .estimate, draft: draft) {
                merged.durationMinutes = estimate
            }
            if let reminder = resolvedValue(draft.task.reminderOverride, kind: .reminder, draft: draft) {
                merged.reminderOverride = reminder
            }
            if let recurrence = resolvedValue(draft.task.recurrence, kind: .recurrence, draft: draft) {
                merged.recurrence = recurrence
            }
            for condition in resolvedConditions(draft) where !merged.conditions.contains(condition) {
                merged.conditions.append(condition)
            }
            return merged
        }
    }

    /// WG-1 (constitution IV): schedules reminders for exactly the ids that actually made it into
    /// `tasks` — filtering against the just-refreshed `tasks` snapshot (rather than assuming every
    /// id in `ids` saved) so a partial-chunk failure in `confirmSave`'s catch branch never
    /// schedules a reminder for a task that was never actually persisted. Takes bare ids (rather
    /// than `[TaskItem]`, the pre-2026-07-28 signature) since `ReminderScheduler.scheduleReminders
    /// (taskId:)` re-reads the task fresh from the store anyway — this lets `confirmSave` pass a
    /// MERGED task's id (whose deadline/reminderOverride may have just changed) alongside brand-new
    /// ones without needing a `TaskItem` for something that was never newly materialized.
    private func scheduleRemindersForSavedItems(_ ids: [UUID]) {
        guard let scheduler else { return }
        let savedIds = Set(tasks.map(\.id))
        for id in ids where savedIds.contains(id) {
            scheduler.scheduleReminders(taskId: id)
        }
    }

    /// One draft -> one `TaskItem`, resolving every `ParsedValue`/`ParsedCondition` per the
    /// contract's "Confirm + materialize" rules. `sourceTranscript` is ALWAYS persisted (closes
    /// the backlog item where `confirmSave` used to hardcode `deadline: nil` for voice tasks —
    /// deadlines, like every other attribute, now come resolved from `ParsedTask`). `id` is now an
    /// explicit parameter (2026-07-28, was `TaskItem.init`'s own default `UUID()`) so
    /// `confirmSave` can mint it BEFORE calling this, record it in `targetID`, and have an
    /// intra-batch `.taskDone` condition elsewhere in the same batch resolve to the exact id this
    /// task ends up with.
    private func materialize(_ draft: ConfirmDraft, id: UUID, now: Date) -> TaskItem {
        let task = draft.task
        let deadline = resolvedValue(task.deadline, kind: .deadline, draft: draft)
        let estimate = resolvedValue(task.estimateMinutes, kind: .estimate, draft: draft)
        let priorityInt = resolvedValue(task.priority, kind: .priority, draft: draft)
        let reminder = resolvedValue(task.reminderOverride, kind: .reminder, draft: draft)
        let recurrence = resolvedValue(task.recurrence, kind: .recurrence, draft: draft)
        let kind = draft.dismissed.contains(.kind) ? .task : task.kind

        return TaskItem(
            id: id,
            title: draft.effectiveTitle,
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

    /// `followUpReview` (contract): a second `.review`-kind task depending on `parentID` via
    /// `.taskDone`. Appended immediately after its parent in `confirmSave`'s batch, so
    /// `TaskStore.addBatch`'s intra-batch snapshot (documented to grow as earlier items in the
    /// SAME batch are accepted) validates the edge without a second pass — and for a Việc 3 merge
    /// target, `parentID` already refers to an ALREADY-persisted task, so the edge validates
    /// trivially against the store's existing snapshot regardless. Takes `parentID`/`parentTitle`/
    /// `sourceTranscript` directly (2026-07-28, was a full `parent: TaskItem`) so `confirmSave` can
    /// call this the same way whether the parent is a brand-new item it just materialized OR an
    /// existing task being merged into (which never gets its own `TaskItem` from this save).
    private func materializeFollowUpReview(parentID: UUID, parentTitle: String, sourceTranscript: String?, now: Date) -> TaskItem {
        TaskItem(
            title: "Review: \(parentTitle)",
            details: "",
            priority: .medium,
            status: .todo,
            deadline: nil,
            conditions: [.taskDone(parentID)],
            createdAt: now,
            when: .later,
            durationMinutes: nil,
            frog: false,
            sourceTranscript: sourceTranscript,
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

    /// Task-breakdown sheet entry point: EVERY "Break down into steps…" call site (`TaskRow.swift`,
    /// `TodayView.swift` x2, `triageBreakdown` below) routes through here now, instead of the old
    /// bare `showBreakdown = true` that opened the sheet onto 5 hard-coded sample rows
    /// ("Open Framer", "Draft headline + subhead", …) regardless of which task — or whether ANY
    /// task — was actually clicked. Kicks off the real fetch immediately so the sheet opens
    /// straight into `.loading` rather than needing a second explicit trigger from the View.
    func openBreakdown(for task: TaskItem) {
        breakdownTask = task
        showBreakdown = true
        fetchBreakdown(title: task.title, notes: task.notes)
    }

    /// `TaskBreakdownView`'s `.onDisappear` calls this on EVERY dismissal path (Cancel, Edit-as-
    /// cancel, Esc, the system sheet-close control) — not just the `onClose()` closure
    /// `VolarApp.swift` wires to the Cancel/Edit buttons, since SwiftUI can tear a sheet down
    /// without that closure ever running. Bumping `breakdownSession` here is what stops a fetch
    /// already in flight for the task just dismissed from landing on — or silently populating —
    /// whichever task's sheet opens next: same stale-token shape as `captureSession`/
    /// `textCaptureSession` elsewhere in this file.
    func closeBreakdown() {
        breakdownSession += 1
        breakdownTask = nil
        breakdownFetchState = .idle
    }

    /// The actual async breakdown fetch, split out of `openBreakdown(for:)` so the session bump +
    /// `.loading` assignment happen SYNCHRONOUSLY before the `_Concurrency.Task` hop — exactly
    /// `runParse`'s own shape (`captureSession`/`captureState = .parsing` set synchronously, THEN
    /// the async router call, further down this file). Routes through the SAME `IntentRouter` the
    /// rest of cloud parsing already uses (`router.breakdown(title:notes:)`, alongside the
    /// existing `router.parse`/`router.resolveCompletion`) rather than a second networking path
    /// opened directly from a View.
    ///
    /// `router.breakdown` itself tries FM (on-device, macOS 26+) -> Cloud -> `[]`.
    ///
    /// (2026-07-28, anh Khôi chốt: `router.breakdown` USED to fall through, unconditionally, to a
    /// hard-coded heuristic floor — `HeuristicNLParser.breakdown`, `Sources/Model/NLParser.swift`:
    /// literally "Gather what's needed for X" / "Start the first small piece" / … / "Wrap up X",
    /// a fixed template, not real per-task content. That call is now removed from
    /// `IntentRouter.breakdown` itself (see the doc comment on `IntentRouter.init` in
    /// `IntentParsing.swift`) — `HeuristicNLParser`'s code is untouched, just no longer wired in.
    /// So `steps` below is now genuinely `[]`, not a disguised template, whenever neither FM nor
    /// Cloud produced a valid breakdown.)
    ///
    /// This method still adds two safeguards on top of `router.breakdown`:
    ///   1. A pre-flight check of the same two cloud preconditions the rest of the app already
    ///      surfaces (`cloudParseConsent == true` — the opt-in flag both the onboarding consent
    ///      toggle and the Settings parse-engine picker write — AND `ConfigParseCredentialProvider
    ///      .isConfigured`, i.e. signed in; mirrors `SettingsView`'s own "Cloud parsing status"
    ///      hint). Not signed in, or never opted in, -> `.unavailable` WITHOUT ever calling the
    ///      router.
    ///   2. Even when both preconditions hold, the live network call can still fail right now
    ///      (offline, quota just exhausted server-side) — `router.breakdown` now returns `[]` in
    ///      that case (no more hard-coded floor to fall through to), which `applyBreakdownFetchResult`
    ///      below maps to `.failed` via its plain "steps is empty" guard. The `heuristicFloor`
    ///      parameter/comparison further down is kept ONLY because `applyBreakdownFetchResult` is
    ///      also called directly by `CloudFirstDefaultsAndBreakdownTests.swift` to exercise that
    ///      exact disguised-floor scenario in isolation — from THIS call site it is now passed `[]`
    ///      and the comparison is dead weight (never true, since `steps` is non-empty by the time
    ///      it's reached). Left in place rather than reworking that test's signature, which is out
    ///      of scope for this change (see backlog.md).
    private func fetchBreakdown(title: String, notes: String?) {
        breakdownSession += 1
        let session = breakdownSession
        breakdownFetchState = .loading

        guard cloudParseConsent == true, ConfigParseCredentialProvider.isConfigured else {
            breakdownFetchState = .unavailable
            return
        }

        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = await self.router.breakdown(title: title, notes: notes)
            // No more `HeuristicNLParser().breakdown(...)` floor to diff against (removed
            // 2026-07-28 — see doc comment above): pass `[]` for `heuristicFloor` so
            // `applyBreakdownFetchResult`'s legacy disguised-floor comparison is a no-op from this
            // call site, while keeping that parameter's signature intact for the existing tests in
            // `CloudFirstDefaultsAndBreakdownTests.swift` that call it directly with real values.
            self.applyBreakdownFetchResult(steps, heuristicFloor: [], session: session)
        }
    }

    /// The synchronous tail of `fetchBreakdown` above, split out SPECIFICALLY so it's directly
    /// unit-testable without awaiting a real `IntentRouter.breakdown` round trip — same precedent
    /// as `applyTextCaptureParseResult(_:session:)` (`TextCaptureTests.swift` already documents
    /// this pattern for the typed-capture flow) and `resolveCloudMatch` elsewhere in this file.
    /// Tests can simulate "the router came back with these steps" (optionally identical to what
    /// the old heuristic floor would have produced, to exercise the `.failed` branch below) and/or
    /// "the session went stale before the fetch returned" by calling this directly with hand-built
    /// `[String]` arrays and/or a stale `session` token, instead of needing a real network round
    /// trip or a real `HeuristicNLParser` call.
    ///
    /// (2026-07-28: `IntentRouter.breakdown` no longer has a heuristic floor to disguise itself as
    /// — see `fetchBreakdown` above — so from the real call site `heuristicFloor` always arrives
    /// as `[]` and the `steps == heuristicFloor` check below is unreachable dead weight in
    /// production. It stays because `CloudFirstDefaultsAndBreakdownTests.swift` still calls this
    /// method directly with non-empty `heuristicFloor` values to test that exact comparison in
    /// isolation, and reworking that test's signature is out of scope for this change.)
    ///
    /// Not `private` for exactly that reason.
    func applyBreakdownFetchResult(_ steps: [String], heuristicFloor: [String], session: Int) {
        // Stale? The sheet was dismissed (`closeBreakdown()`) or reopened on a different task
        // while this request was in flight — mirrors `runParse`'s own `captureSession` guard.
        guard breakdownSession == session else { return }
        guard !steps.isEmpty else {
            // No steps at all -> `.failed` ("Couldn't reach the breakdown service", TaskBreakdownView).
            // This is now the ONLY path that matters from the real `fetchBreakdown` call site: FM
            // and Cloud both failed/unavailable, and there is no heuristic floor left to fall back
            // to (2026-07-28) — never invent step titles, tell the user honestly instead.
            breakdownFetchState = .failed
            return
        }
        // Legacy check, kept for the direct-call tests only (see doc comment above) — same content
        // as the hard-coded heuristic floor would mean "this WAS that floor in disguise," but the
        // real call site can no longer produce that situation since the floor itself is gone.
        if steps == heuristicFloor {
            breakdownFetchState = .failed
            return
        }
        breakdownFetchState = .loaded(
            steps.enumerated().map { BreakdownStep(id: $0.offset, title: $0.element) }
        )
    }

    /// Task-breakdown sheet: "Save all as tasks" — persists each REAL step title `fetchBreakdown`
    /// produced as its own `TaskItem` (medium priority, `.later`, no deadline/duration — the
    /// breakdown generator doesn't produce those yet), then dismisses and resets the breakdown
    /// state so the next `openBreakdown(for:)` starts clean.
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
        breakdownTask = nil
        breakdownSession += 1
        breakdownFetchState = .idle
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

    /// Triage "Break down": opens the real per-task breakdown sheet for `item` via
    /// `openBreakdown(for:)` (Change 3 fix — this call site used to just set `showBreakdown =
    /// true` with no per-task target, same bug the context-menu entry points had; see
    /// `openBreakdown(for:)`'s doc comment for the full fix).
    func triageBreakdown(_ item: TaskItem) {
        openBreakdown(for: item)
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
    /// `appState.handleHotkey()` directly on key-down (see `Sources/Speech/HotkeyManager.swift`);
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
        // FIX 6 (launch/window-reopen path): nothing else runs `reconcile(tasks:)` at launch
        // otherwise — a Mac that slept through a task's deadline changing (e.g. a reminder
        // reschedule while the app wasn't running) would show a stale "Volar" calendar until the
        // next in-app mutation. Idempotent for the same reason every other call site here is: a
        // no-op reconcile costs one filter pass when nothing actually changed.
        syncCalendarMirror()
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

    // MARK: - Guided tour actions (`TourOverlay.swift`)

    /// The stop currently on screen, or `nil` if `tourStepIndex` ever drifted out of
    /// `TourStop.all`'s bounds. Defensive rather than load-bearing: every mutator below
    /// (`startTourIfNeeded`/`replayTour`/`tourNext`/`tourBack`/`endTour`) keeps `tourStepIndex` in
    /// range by construction, so this should never actually read `nil` while `tourActive` is
    /// `true` — but `TourOverlay` reads THIS instead of subscripting `TourStop.all` directly, so a
    /// future bug here degrades to "the overlay quietly renders nothing" instead of a crash.
    var tourStop: TourStop? {
        TourStop.all.indices.contains(tourStepIndex) ? TourStop.all[tourStepIndex] : nil
    }

    /// Called once, right after onboarding completes (`VolarApp.swift`'s `OnboardingView
    /// onComplete:` and its sheet-dismissal binding) — a no-op if the tour has already run this
    /// install (or a previous one; `hasSeenTour` is persisted), so a relaunch never re-triggers it
    /// uninvited. `replayTour()` below is the explicit, always-runs Settings re-entry point.
    func startTourIfNeeded() {
        guard !hasSeenTour else { return }
        tourStepIndex = 0
        tourActive = true
    }

    /// Settings' "Replay guided tour" row (agent-B-owned call site, `SettingsView.swift`) — always
    /// restarts from the first stop, unconditionally, even though `hasSeenTour` is necessarily
    /// already `true` by the time a user can reach this row at all.
    func replayTour() {
        tourStepIndex = 0
        tourActive = true
    }

    /// "Next →" on every non-final stop. Advances one stop, or — if already on the last stop —
    /// ends the tour exactly like Skip/Esc would. In practice `TourOverlay` never shows a "Next →"
    /// button on the final stop (its footer swaps in the calendar-connect actions instead, each of
    /// which calls `endTour()` directly), so the "past the last stop" branch here is a defensive
    /// fallback, not a normally-reached path.
    func tourNext() {
        let next = tourStepIndex + 1
        if TourStop.all.indices.contains(next) {
            tourStepIndex = next
        } else {
            endTour()
        }
    }

    /// "Back". Clamped at 0 — mirrors `FocusOverlay`'s own `goToPrevious()` clamp (`AppState`
    /// itself has no analogous clamp today since `focusIndex` is clamped view-side; this one lives
    /// here instead so `Tests/TourFlowTests.swift` can exercise it without a view).
    func tourBack() {
        tourStepIndex = max(0, tourStepIndex - 1)
    }

    /// Skip / Esc / the final stop's "Maybe later"/"Finish" — ends the tour and marks it seen for
    /// good, so `startTourIfNeeded()` never auto-starts it again this install. `replayTour()` is
    /// the only way back in once this has run.
    func endTour() {
        tourActive = false
        tourStepIndex = 0
        hasSeenTour = true
        UserDefaults.standard.set(true, forKey: Self.hasSeenTourKey)
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
