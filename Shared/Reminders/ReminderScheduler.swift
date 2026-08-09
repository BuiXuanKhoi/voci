// Sources/Reminders/ReminderScheduler.swift — durable reminder scheduling + fire-time delivery
// (specs/002-workflow-command-center/contracts/phase4-contract.md §A, constitution IV, T029).
//
// PERSISTENCE DESIGN NOTE: this scheduler owns its own `ModelContainer`/`ModelContext` for
// `ReminderRecord`, kept separate from `TaskStore`'s container (`Sources/Model/TaskStore.swift`,
// schema `[VolarTask.self, CompletionEvent.self, ParseCorrection.self]`). This task owns
// `Model/ReminderRecord.swift` but explicitly not `TaskStore.swift`, so extending TaskStore's
// schema/init wasn't an option without touching a file outside this task's ownership. A single
// shared container would be a reasonable future consolidation (worth a backlog line — flagged in
// this task's final report rather than written to `backlog.md` directly, per this task's "do not
// edit backlog" constraint) but is NOT required for correctness: `ReminderRecord` rows are just as
// durable in their own named SwiftData store, and `rebuildFromStorage()` reconciles against
// `TaskStore.fetchAll()` regardless of which container either side lives in.
import Foundation
import SwiftData
import UserNotifications
#if os(iOS)
import UIKit
#endif
// i-2: this file uses `TaskStatus`/`TaskItem` (both re-exported via the `Volar` module's own
// `Sources/Model/TaskItem.swift`, which itself does `import VolarCore`) — importing VolarCore
// directly here too, rather than relying on the same-module typealias visibility, so this
// compiles even if that indirection is ever narrowed.
import VolarCore

// `NSObject` inheritance is load-bearing, not decorative: this class self-assigns as
// `UNUserNotificationCenter.current().delegate` in `init` (see below) and conforms to
// `UNUserNotificationCenterDelegate` (an `@objc` protocol with optional methods) in the extension
// at the bottom of this file — optional-method `@objc` dispatch requires `NSObject` lineage.
@MainActor
final class ReminderScheduler: NSObject {
    private let store: TaskStore
    private let voice: VoiceReminderChannel
    private let gate: ReminderContextGate
    private let context: ModelContext
    private let center = UNUserNotificationCenter.current()

    /// Headroom under `UNUserNotificationCenter`'s documented ~64 pending-local-notification cap
    /// (research.md R2) — leaves room for any other notification source the app might add later
    /// and avoids racing the exact ceiling.
    static let systemRequestCap = 60

    #if os(iOS)
    /// iOS equivalent of the macOS wake path this file's `init` doc comment describes (and
    /// deliberately does NOT itself register any more — that responsibility moved to
    /// `VolarApp.swift`'s `NSWorkspace.shared.notificationCenter` observer after the `m-2` fix).
    /// There is no `VolarIOS/Sources/App/*` file yet (Phase 1, out of this task's scope) to own an
    /// app-lifetime foreground observer the way `VolarApp.swift` owns the macOS one, so this
    /// self-registers instead — the same idiom macOS's `init` tried and abandoned, but WITHOUT
    /// that idiom's actual bug: macOS's problem was `NSWorkspace.didWakeNotification` posting on
    /// `NSWorkspace.shared.notificationCenter`, not `NotificationCenter.default` — `UIApplication
    /// .didBecomeActiveNotification` is documented to post on `NotificationCenter.default`, so
    /// there is no equivalent "wrong center" trap here.
    private var foregroundObserverToken: NSObjectProtocol?
    #endif

    init(store: TaskStore, voice: VoiceReminderChannel, gate: ReminderContextGate) {
        self.store = store
        self.voice = voice
        self.gate = gate
        self.context = Self.makeContext()
        super.init()

        // Self-wire as the notification-center delegate right here: `AppState` (App-wiring,
        // sibling-owned) constructs exactly one `ReminderScheduler` for the app's lifetime and
        // retains it (`AppState.scheduler`), so `self` is already the long-lived instance the
        // delegate property needs a strong-enough reference to keep working — no separate
        // delegate object for another agent to construct/retain (see `AppDelegate.swift`'s own
        // comment: it deliberately did NOT assign this, leaving it to "contract A/B's own
        // initializer"). See the `UNUserNotificationCenterDelegate` conformance at the bottom of
        // this file.
        UNUserNotificationCenter.current().delegate = self

        #if os(iOS)
        // R2 (plan.md §8) / T5a: rebuild on every foreground, not just launch — this is iOS's
        // wake-recovery equivalent of the macOS `NSWorkspace.didWakeNotification` path. `@Sendable`
        // + explicit `_Concurrency.Task { @MainActor in }` hop mirrors this file's own
        // `willPresent`/`didReceive` convention below (system-invoked closures on this
        // `@MainActor` class must not be inferred MainActor-isolated, or Swift 6's runtime
        // isolation check traps). Qualified `_Concurrency.Task` — not plain `Task` — for the same
        // reason every other call site in this file is: `import VolarCore` (top of file) brings in
        // `VolarCore.Task` (the engine's model struct), which shadows `Swift.Task` here.
        foregroundObserverToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            _Concurrency.Task { @MainActor in
                self?.rebuildFromStorage()
            }
        }
        #endif

        // Constitution IV: rebuild on wake as well as launch. LAUNCH is the constructing caller's
        // responsibility — call `rebuildFromStorage()` once right after building this scheduler
        // (kept out of `init` itself so the initializer stays synchronous/side-effect-light and
        // testable). WAKE recovery is intentionally NOT wired here (m-2): this used to register an
        // observer on `NotificationCenter.default`, but `NSWorkspace.didWakeNotification` actually
        // posts on `NSWorkspace.shared.notificationCenter` — that observer never fired and was
        // deleted rather than fixed in place, since `VolarApp.swift` (App-wiring, sibling-owned)
        // already has the correct wake path wired via `NSWorkspace.shared.notificationCenter` and
        // calls `scheduler?.rebuildFromStorage()` from there.
    }

    // MARK: - Contract §A

    /// Rebuilds ALL scheduler state from durable storage: re-derives reminders for every open,
    /// dated task that doesn't have any `ReminderRecord` yet (covers a task created/edited before
    /// this scheduler existed, or a derivation that never landed), fires any `.scheduled` record
    /// already past due ("due-but-missed" recovery — constitution IV), then refills the system's
    /// pending-request queue with the nearest-N. Call once at launch; also called automatically on
    /// `NSWorkspace.didWakeNotification` (see `init`). O(n) in the number of persisted tasks/
    /// records: one `TaskStore.fetchAll()`, one records fetch, one dictionary build — no nested
    /// re-fetching per record.
    func rebuildFromStorage() {
        let now = Date()
        let tasks = store.fetchAll()
        let openDatedTasks = tasks.filter { ($0.status == .todo || $0.status == .inProgress) && $0.deadline != nil }
        for task in openDatedTasks {
            ensureDerived(taskId: task.id, deadline: task.deadline, reminderOverride: task.reminderOverride)
        }

        let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        // FIX B: a notification the OS already delivered while the app was backgrounded/not
        // running never routed through `willPresent`/`presentationDecision` (those only fire
        // when the app is alive to receive the delegate callback), so its record is stuck at
        // `.scheduled` forever — the due-but-missed pass below would then treat it as missed and
        // re-fire it as a SECOND notification on every future launch/wake. Reconcile against
        // `UNUserNotificationCenter.deliveredNotifications()` first so an already-delivered record
        // is marked `.delivered` (not re-fired) before the due-but-missed pass runs.
        // `deliveredNotifications()` is async-only, so this whole rebuild (reconciliation +
        // due-but-missed pass + refill, in that order) moves inside a single `_Concurrency.Task`
        // hop — same fire-and-forget pattern `refillSystemRequests()` already uses elsewhere in
        // this file — so callers keep calling this as a plain synchronous method.
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileDeliveredNotifications()

            let dueButMissed = self.fetchAllRecords().filter { $0.state == "scheduled" && $0.fireAt <= now }
            for record in dueButMissed {
                self.fire(record, using: byId)
            }

            self.refillSystemRequests()
        }
    }

    /// FIX B helper: marks every `.scheduled` record whose id matches an already-OS-delivered
    /// notification's identifier as `.delivered`, in a single batched save (one `fetchAllRecords()`
    /// — no fetch-in-loop). No-op if nothing was delivered or nothing needs updating.
    private func reconcileDeliveredNotifications() async {
        let delivered = await center.deliveredNotifications()
        guard !delivered.isEmpty else { return }
        let deliveredIds = Set(delivered.compactMap { UUID(uuidString: $0.request.identifier) })
        guard !deliveredIds.isEmpty else { return }
        var didChange = false
        for record in fetchAllRecords() where record.state == "scheduled" && deliveredIds.contains(record.id) {
            record.state = "delivered"
            didChange = true
        }
        if didChange { save() }
    }

    /// Derives + persists this task's reminder set from its deadline × (`reminderOverride` ??
    /// global `ReminderPolicy`), replacing any not-yet-delivered rows from a prior derivation
    /// (deadline edits, recurrence resets land here). Delivered/satisfied history is left alone —
    /// this only ever touches `.scheduled` rows. A closed (`done`/`archived`) task gets no
    /// reminders at all.
    func scheduleReminders(for task: VolarTask) {
        deriveAndSchedule(
            taskId: task.id, status: task.status, deadline: task.deadline, reminderOverride: task.reminderOverride
        )
    }

    /// WG-1/M-3 (constitution IV, ship-blocker): `scheduleReminders(for: VolarTask)` above can't
    /// actually be called from `AppState` — `VolarTask` is the SwiftData persistence model this
    /// file/`TaskStore` own; `AppState` only ever holds `TaskItem` snapshots and has no way to
    /// obtain a live `VolarTask` instance (`TaskStore.fetchModel` is private). This is the real
    /// seam the App-wiring agent needs: resolve the task fresh from `store` by id (same "read
    /// `TaskItem`, not `VolarTask`" convention every other method on this class already uses — see
    /// `evaluate(_:snapshot:)`) and derive from that. A missing/deleted id is treated as "nothing
    /// to schedule," not an error — mirrors every other not-found fallback in this subsystem.
    func scheduleReminders(taskId: UUID) {
        guard let task = store.fetchAll().first(where: { $0.id == taskId }) else { return }
        deriveAndSchedule(
            taskId: taskId, status: task.status, deadline: task.deadline, reminderOverride: task.reminderOverride
        )
    }

    /// Shared body for both `scheduleReminders` overloads above, so the derive logic can't drift
    /// apart between them.
    private func deriveAndSchedule(taskId: UUID, status: TaskStatus, deadline: Date?, reminderOverride: ReminderPolicy?) {
        clearScheduled(taskId: taskId)
        guard status == .todo || status == .inProgress else { return }
        let records = ReminderRecord.derive(
            taskId: taskId, deadline: deadline, reminderOverride: reminderOverride,
            globalPolicy: Self.currentGlobalReminderPolicy()
        )
        for record in records { context.insert(record) }
        save()
        refillSystemRequests()
    }

    /// Cancels every reminder for `taskId` — both the durable rows and any request already
    /// registered with the system — so completion/deletion never leaves an orphaned notification
    /// behind (constitution IV's cascade requirement). Safe to call for a task with no reminders.
    func cancelReminders(taskId: UUID) {
        let records = recordsForTask(taskId)
        guard !records.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: records.map(\.id.uuidString))
        for record in records { context.delete(record) }
        save()
        refillSystemRequests()
    }

    /// Fresh reload + fire "right now": reloads the task fresh from `store` and suppresses
    /// (resolves the record to `.satisfied`, delivers nothing) if it's done/archived/deleted;
    /// otherwise posts an immediate system notification and speaks if the escalation rule says to.
    /// Used for (1) due-but-missed recovery (`rebuildFromStorage`) and (2) the immediate-delivery
    /// helpers below (`scheduleResurface`/`notifyUnblocked`/`offerReschedule`). NOT used for a
    /// reminder the OS is already about to present live on its own schedule — that path is
    /// `presentationDecision(for:)`, so a pre-registered system banner is never duplicated.
    func handleFire(recordId: UUID) {
        guard let record = fetchRecord(recordId) else { return }
        fire(record, using: nil)
    }

    /// FR-017: resurface `taskId` at `date` (e.g. an `.afterDate` condition's target, per
    /// `VolarCore.nextResurfaceDate`). Scheduled ahead like a normal reminder — not fired
    /// immediately.
    ///
    /// FIX A: `AppState` calls this after EVERY mutation on a task with an `.afterDate`
    /// condition, so a naive unconditional insert would pile up a new `.scheduled` "resurface"
    /// row (and a duplicate system banner) on every single edit. Dedupe against any existing
    /// not-yet-delivered resurface record for this task first: same `fireAt` -> no-op; different
    /// `fireAt` -> update that one row in place instead of inserting a second.
    func scheduleResurface(at date: Date, taskId: UUID) {
        if let existing = recordsForTask(taskId).first(where: { $0.offsetKind == "resurface" && $0.state == "scheduled" }) {
            guard existing.fireAt != date else { return }
            // The old `fireAt` may already be registered as a pending `UNNotificationRequest`
            // under this record's identifier — drop it so `refillSystemRequests()` (below) treats
            // the record as unregistered and re-posts it with the new trigger time, instead of
            // leaving the stale-time request in place forever.
            center.removePendingNotificationRequests(withIdentifiers: [existing.id.uuidString])
            existing.fireAt = date
            save()
            refillSystemRequests()
            return
        }
        let record = ReminderRecord(taskId: taskId, fireAt: date, offsetKind: "resurface")
        context.insert(record)
        save()
        refillSystemRequests()
    }

    /// FR-015: one notification per newly-eligible task, fired immediately — there's nothing to
    /// schedule ahead of time, the unblock just happened. Caller passes the `eligibilityDiff`
    /// result once per mutation so this never double-notifies the same unblock event.
    func notifyUnblocked(taskIds: [UUID]) {
        for taskId in taskIds {
            let record = ReminderRecord(taskId: taskId, fireAt: Date(), offsetKind: "unblocked")
            context.insert(record)
            save()
            handleFire(recordId: record.id)
        }
    }

    /// FR-016: an overdue nudge offering tonight/tomorrow/weekend reschedule actions
    /// (`ReminderCategory.overdueReschedule`, reached via the shared `"resurface"` offset kind —
    /// see `NotificationActions.category(forOffsetKind:)`). Fired immediately, same reasoning as
    /// `notifyUnblocked`.
    func offerReschedule(taskId: UUID) {
        let record = ReminderRecord(taskId: taskId, fireAt: Date(), offsetKind: "resurface")
        context.insert(record)
        save()
        handleFire(recordId: record.id)
    }

    // MARK: - Notification-center delegate (see the `UNUserNotificationCenterDelegate`
    // conformance at the bottom of this file; `NotificationActions.swift` owns the
    // category/action identifiers these two methods read/switch on)

    /// For this class's own `willPresent` conformance: the OS is already about to show a
    /// pre-registered system banner for `recordId`. This does the SAME fresh-reload +
    /// suppress-or-show + maybe-speak evaluation as `fire(_:using:)`, but only returns the
    /// decision instead of posting a new request (posting again here would duplicate the banner
    /// the system is already displaying).
    func presentationDecision(for recordId: UUID) -> Bool {
        guard let record = fetchRecord(recordId) else { return false }
        // FIX C (`VoiceDeliveryMode.voiceOnly`): this method's return value controls whether the
        // OS shows the visual banner (`willPresent`'s completion handler passes `[.banner, .sound]`
        // vs `[]`), so `.voiceOnly` is honored here by folding `mode != .voiceOnly` into both
        // return paths below — the record is still marked delivered and voice still speaks per the
        // existing gates in `evaluate(_:)` either way, only the visual presentation is suppressed.
        // LIMITATION: `willPresent` only fires when the app process is alive to receive the
        // delegate callback — a notification delivered while the app is fully unlaunched is shown
        // by the OS with its own default presentation and never reaches this method, so
        // `.voiceOnly` cannot suppress that banner.
        let mode = Self.currentVoiceDeliveryMode()
        // `fire(_:using:)` sets `record.state = "delivered"` BEFORE it posts the immediate
        // `UNNotificationRequest` it fires for (notifyUnblocked/offerReschedule/due-but-missed
        // recovery), so by the time the OS calls `willPresent` for that request, this record is
        // already "delivered", not "scheduled" — `fire()` already ran `evaluate(_:)` (and the
        // voice/gate decision) for it moments earlier. The old `state == "scheduled"` guard below
        // therefore returned `false` here for EVERY immediate notification, silently suppressing
        // all of them whenever the app was frontmost. Trust the decision `fire()` already made and
        // show it, instead of re-evaluating gates a second time.
        if record.state == "delivered" { return mode != .voiceOnly }
        guard record.state == "scheduled" else { return false }
        guard let evaluation = evaluate(record, snapshot: nil) else {
            context.delete(record)
            save()
            return false
        }
        record.state = evaluation.shouldShow ? "delivered" : "satisfied"
        if evaluation.shouldShow, evaluation.shouldSpeak {
            voice.speakReminder(
                title: evaluation.task.title,
                timing: Self.timingPhrase(offsetKind: record.offsetKind),
                isSensitive: evaluation.isSensitive
            )
        }
        save()
        refillSystemRequests()
        return evaluation.shouldShow && mode != .voiceOnly
    }

    /// For this class's own `didReceive` conformance: routes a tapped action to a `TaskStore`
    /// mutation or a reschedule, WITHOUT ever opening the app window (FR-014/015/016 — enforced by
    /// `NotificationActions` never declaring `.foreground` on any action, not by anything here).
    func handleAction(_ actionId: String, recordId: UUID) {
        guard let record = fetchRecord(recordId) else { return }
        let now = Date()
        switch actionId {
        case ReminderAction.done:
            let taskId = record.taskId
            store.toggle(taskId, now: now)
            record.state = "satisfied"
            // WG-C (FR-020 gap fix): this path deliberately bypasses `AppState.toggleDone` (its own
            // doc comment explains why — FR-014/015/016 forbid a notification action from touching
            // the app/window directly), which otherwise refreshes `AppState.tasks` atomically after
            // every store mutation. Post the fact instead: `VolarApp.swift` observes
            // `.volarTasksDidChange` and calls `AppState.refreshFromStore()` on the main actor, so
            // `MenuBarLabel.activeTask` catches up without needing the window foregrounded first.
            NotificationCenter.default.post(name: .volarTasksDidChange, object: nil)
            // Mirrors `AppState.toggleDone` (`Sources/App/AppState.swift:542-548`, App-wiring-owned
            // — read for reference only, not edited here): `store.toggle` can leave the task
            // done/archived, OR reopen it in place (a recurring task resets to `.todo` with a fresh
            // deadline). Either way this record alone isn't the whole story — cancel the REST of
            // this task's reminders, and if it's still open, re-derive them from the new deadline.
            // Without this, a recurring task's future reminders are silently lost forever:
            // `ensureDerived` only derives for a task with zero records, so once this task has any
            // records at all it's skipped on every later `rebuildFromStorage`.
            if let fresh = store.fetchAll().first(where: { $0.id == taskId }) {
                cancelReminders(taskId: taskId)
                if fresh.status != .done, fresh.status != .archived {
                    scheduleReminders(taskId: taskId)
                }
            }
        case ReminderAction.snooze10:
            reschedule(record, to: now.addingTimeInterval(10 * 60))
        case ReminderAction.tomorrow, ReminderAction.rescheduleTomorrow:
            reschedule(record, to: Self.tomorrowMorning(from: now))
        case ReminderAction.rescheduleTonight:
            reschedule(record, to: Self.tonight(from: now))
        case ReminderAction.rescheduleWeekend:
            reschedule(record, to: Self.nextWeekend(from: now))
        default:
            // Default tap / dismiss identifiers: no state change, no window — a glance-and-dismiss
            // reminder that isn't acted on just stays as-is (constitution V).
            break
        }
        save()
        refillSystemRequests()
    }

    // MARK: - Shared fire core

    private struct FireEvaluation {
        var task: TaskItem
        var isSensitive: Bool
        var shouldShow: Bool
        var shouldSpeak: Bool
    }

    /// The "reload fresh -> suppress-if-done -> decide voice" core shared by `handleFire`/
    /// `rebuildFromStorage`'s due-but-missed loop and `presentationDecision`. `snapshot`, when
    /// provided, avoids a redundant `store.fetchAll()` for a caller that already fetched one (used
    /// by `rebuildFromStorage` to stay O(n) instead of O(n·m) for m due records); `nil` fetches
    /// fresh, which is exactly the "fire-time fresh reload" constitution IV requires for a
    /// single-record call. `isSensitive` is read separately via `store.isSensitive(_:)`
    /// (`VolarTask.isSensitive` is deliberately not carried on `TaskItem` — see that field's doc
    /// comment in `VolarTask.swift`).
    private func evaluate(_ record: ReminderRecord, snapshot: [UUID: TaskItem]?) -> FireEvaluation? {
        let task: TaskItem?
        if let snapshot {
            task = snapshot[record.taskId]
        } else {
            task = store.fetchAll().first { $0.id == record.taskId }
        }
        guard let task else { return nil } // deleted outright — nothing to show or suppress
        let isSensitive = store.isSensitive(task.id)
        guard task.status != .done, task.status != .archived else {
            return FireEvaluation(task: task, isSensitive: isSensitive, shouldShow: false, shouldSpeak: false)
        }

        let priorUnacknowledged = recordsForTask(record.taskId).contains {
            $0.id != record.id && $0.state == "delivered" && $0.fireAt < record.fireAt
        }
        let mode = Self.currentVoiceDeliveryMode()
        let shouldSpeak = (record.isHighUrgency || priorUnacknowledged)
            && mode != .visualOnly
            && !gate.shouldSuppressVoice(now: Date())
        return FireEvaluation(task: task, isSensitive: isSensitive, shouldShow: true, shouldSpeak: shouldSpeak)
    }

    /// Fires exactly one record: suppress-to-satisfied if the fresh task is done/archived/gone,
    /// otherwise post an immediate system notification (+ speak if escalation says to) and mark
    /// delivered. Guards `record.state == "scheduled"` so this is idempotent — calling it twice on
    /// an already-fired record (e.g. two overlapping `rebuildFromStorage` calls) is a no-op the
    /// second time, which is what makes "due-but-missed fires once" true.
    private func fire(_ record: ReminderRecord, using snapshot: [UUID: TaskItem]?) {
        guard record.state == "scheduled" else { return }
        guard let evaluation = evaluate(record, snapshot: snapshot) else {
            context.delete(record)
            save()
            return
        }
        guard evaluation.shouldShow else {
            record.state = "satisfied"
            save()
            return
        }
        record.state = "delivered"
        if evaluation.shouldSpeak {
            voice.speakReminder(
                title: evaluation.task.title,
                timing: Self.timingPhrase(offsetKind: record.offsetKind),
                isSensitive: evaluation.isSensitive
            )
        }
        save()
        // Extract plain Sendable values (`UUID`/`String`/the `TaskItem` struct) BEFORE spawning
        // the Task: `Task {}`'s closure must be `@Sendable`, and capturing `record` itself (a
        // non-`Sendable` SwiftData `@Model` class) directly would violate that — this mirrors the
        // Sendable-primitive-extraction pattern already used in `Sources/Speech/SpeechCapture.swift`.
        let recordId = record.id
        let offsetKind = record.offsetKind
        let task = evaluation.task
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            await self.postImmediateRequest(recordId: recordId, offsetKind: offsetKind, task: task)
        }
    }

    private func reschedule(_ record: ReminderRecord, to date: Date) {
        record.fireAt = date
        record.offsetKind = "resurface"
        record.isHighUrgency = false
        record.state = "scheduled"
    }

    // MARK: - Settings seam
    //
    // Both keys below are read directly from `AppState`'s own `static let ...Key` constants
    // (`Sources/App/AppState.swift`, App-wiring-owned — not edited by this task) rather than
    // duplicated string literals, so the two sides can never drift apart. `AppState` is the
    // documented owner of both settings (contract §B: "`VoiceDeliveryMode` ... lives in a
    // settings source read by the scheduler"; T033 adds the matching global `ReminderPolicy`
    // setting) — this file only ever READS them, never writes.

    private static func currentVoiceDeliveryMode() -> VoiceDeliveryMode {
        let raw = UserDefaults.standard.string(forKey: AppState.voiceDeliveryModeKey)
        return raw.flatMap(VoiceDeliveryMode.init(rawValue:)) ?? .visualPlusVoice
    }

    private static func currentGlobalReminderPolicy() -> ReminderPolicy {
        guard
            let data = UserDefaults.standard.data(forKey: AppState.globalReminderPolicyKey),
            let policy = try? JSONDecoder().decode(ReminderPolicy.self, from: data)
        else { return .defaultPolicy }
        return policy
    }

    // MARK: - Date helpers (explicit `Calendar` math — constitution: never bare Date arithmetic)

    private static func tomorrowMorning(from now: Date, calendar: Calendar = .current) -> Date {
        let base = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: base) ?? base
    }

    private static func tonight(from now: Date, calendar: Calendar = .current) -> Date {
        let candidate = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
        return candidate > now ? candidate : (calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate)
    }

    private static func nextWeekend(from now: Date, calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.weekday = 7 // Gregorian: 1 = Sunday ... 7 = Saturday
        components.hour = 10
        components.minute = 0
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now
    }

    // MARK: - System request plumbing

    /// Pulls the current pending-request count, then tops it back up to `systemRequestCap` with
    /// the earliest-firing `.scheduled` records not already registered. Called after every
    /// mutation that could change what "nearest" means (schedule/cancel/deliver/action).
    private func refillSystemRequests() {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let pending = await self.center.pendingNotificationRequests()
            let pendingIds = pending.compactMap { UUID(uuidString: $0.identifier) }
            let capacity = Self.systemRequestCap - pending.count
            guard capacity > 0 else { return }
            let candidates = Self.nearestCandidates(self.fetchAllRecords(), excluding: pendingIds, capacity: capacity)
            let tasksById = Dictionary(uniqueKeysWithValues: self.store.fetchAll().map { ($0.id, $0) })
            for record in candidates {
                guard let task = tasksById[record.taskId] else { continue }
                await self.postScheduledRequest(record: record, task: task)
            }
        }
    }

    /// Pure selection: earliest-firing `.scheduled` records not already registered with the
    /// system, capped at `capacity`. No I/O — directly unit-testable
    /// (`ReminderSchedulerTests.testNearestNRefillUnderCap`) without touching
    /// `UNUserNotificationCenter` at all.
    static func nearestCandidates(_ records: [ReminderRecord], excluding registeredIds: [UUID], capacity: Int) -> [ReminderRecord] {
        guard capacity > 0 else { return [] }
        let excluded = Set(registeredIds)
        return Array(
            records
                .filter { $0.state == "scheduled" && !excluded.contains($0.id) }
                .sorted { $0.fireAt < $1.fireAt }
                .prefix(capacity)
        )
    }

    private func postScheduledRequest(record: ReminderRecord, task: TaskItem) async {
        let content = Self.buildContent(task: task, offsetKind: record.offsetKind)
        // `UNTimeIntervalNotificationTrigger` requires a strictly positive interval even for a
        // record whose `fireAt` has already technically passed at registration time (e.g. one
        // just created by `notifyUnblocked` racing this refill) — 1s is effectively "now".
        let interval = max(record.fireAt.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: trigger)
        try? await center.add(request)
    }

    private func postImmediateRequest(recordId: UUID, offsetKind: String, task: TaskItem) async {
        let content = Self.buildContent(task: task, offsetKind: offsetKind)
        let request = UNNotificationRequest(identifier: recordId.uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    private static func buildContent(task: TaskItem, offsetKind: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Volar"
        content.body = "\(task.title) \u{2014} \(timingPhrase(offsetKind: offsetKind))"
        content.sound = .default
        content.categoryIdentifier = NotificationActions.category(forOffsetKind: offsetKind)
        return content
    }

    /// Calm, non-alarming phrasing (constitution V) — no "OVERDUE"/"MISSED" shouting.
    private static func timingPhrase(offsetKind: String) -> String {
        switch offsetKind {
        case "-1d": return "due tomorrow"
        case "-1h": return "due in about an hour"
        case "at": return "due now"
        case "unblocked": return "ready to start"
        case "resurface": return "worth a look"
        default: return "coming up"
        }
    }

    // MARK: - Persistence internals

    private static func makeContext() -> ModelContext {
        let schema = Schema([ReminderRecord.self])
        let configuration = ModelConfiguration("VolarReminders", schema: schema)
        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return ModelContext(container)
        }
        // Degrade gracefully (mirrors `TaskStore.init()`'s documented fallback philosophy): an
        // in-memory container keeps the scheduler functional for the running session even if the
        // persistent store can't be opened, rather than crashing the app at launch.
        let fallback = ModelConfiguration("VolarReminders-fallback", schema: schema, isStoredInMemoryOnly: true)
        // Force-try is safe here: an in-memory `ModelContainer` for a schema that's already known
        // to be well-formed (it just failed for an on-disk reason above) has no plausible failure
        // mode short of an out-of-memory condition, which would already be fatal elsewhere.
        let container = try! ModelContainer(for: schema, configurations: [fallback])
        return ModelContext(container)
    }

    // Deliberately `internal` (not `private`), unlike the rest of this section: `@testable import
    // Volar` gives `ReminderSchedulerTests` access to `internal` symbols only, and these three are
    // the minimal read-only surface the tests need to assert on persisted `ReminderRecord` state
    // after driving the frozen public API (`rebuildFromStorage`/`scheduleReminders`/`handleFire`/
    // `cancelReminders`) — nothing here is exported outside the module.

    func fetchRecord(_ id: UUID) -> ReminderRecord? {
        var descriptor = FetchDescriptor<ReminderRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func recordsForTask(_ taskId: UUID) -> [ReminderRecord] {
        let descriptor = FetchDescriptor<ReminderRecord>(predicate: #Predicate { $0.taskId == taskId })
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchAllRecords() -> [ReminderRecord] {
        (try? context.fetch(FetchDescriptor<ReminderRecord>())) ?? []
    }

    private func clearScheduled(taskId: UUID) {
        let scheduled = recordsForTask(taskId).filter { $0.state == "scheduled" }
        guard !scheduled.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: scheduled.map(\.id.uuidString))
        for record in scheduled { context.delete(record) }
    }

    /// Only derives when NO record exists yet for `taskId` (any state) — makes repeated
    /// `rebuildFromStorage()` calls idempotent instead of re-deriving (and re-firing) the same
    /// offsets on every wake.
    private func ensureDerived(taskId: UUID, deadline: Date?, reminderOverride: ReminderPolicy?) {
        guard recordsForTask(taskId).isEmpty else { return }
        let records = ReminderRecord.derive(
            taskId: taskId, deadline: deadline, reminderOverride: reminderOverride,
            globalPolicy: Self.currentGlobalReminderPolicy()
        )
        for record in records { context.insert(record) }
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            print("[Volar.ReminderScheduler] save failed: \(error)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

/// Concurrency note (mirrors `Sources/Speech/SpeechCapture.swift`'s documented pattern for the
/// same underlying issue): `UNUserNotificationCenterDelegate`'s methods are invoked by the system
/// on an arbitrary background queue, not necessarily the main actor. A non-`nonisolated` method on
/// this `@MainActor` class would be inferred main-actor-isolated, and Swift 6's runtime isolation
/// check traps (`dispatch_assert_queue(main)`) when the system calls it off-main. Both methods
/// below are therefore `nonisolated` and hop to `@MainActor` themselves before touching any
/// scheduler state.
extension ReminderScheduler: UNUserNotificationCenterDelegate {
    /// The OS is about to show a pre-registered system banner live — routes to
    /// `presentationDecision(for:)` for the fresh-reload suppress/show call, per contract §A.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let identifier = notification.request.identifier
        // `completionHandler` is not `@Sendable` (the UserNotifications SDK doesn't annotate it), so
        // capturing it into the `@MainActor` Task below crosses an isolation boundary and Swift 6
        // flags "sending 'completionHandler' risks causing data races". The OS invokes this delegate
        // method once and we call the handler exactly once, on the main actor — box it in a
        // `nonisolated(unsafe) let` to assert that safety, matching this file's/`SpeechCapture.swift`'s
        // established convention for sending a non-Sendable system value across an isolation hop.
        nonisolated(unsafe) let handler = completionHandler
        _Concurrency.Task { @MainActor [weak self] in
            guard let self, let recordId = UUID(uuidString: identifier) else {
                // Not one of ours (foreign identifier) or the scheduler is gone — show it as the
                // system would by default rather than silently eating a notification.
                handler([.banner, .sound])
                return
            }
            handler(self.presentationDecision(for: recordId) ? [.banner, .sound] : [])
        }
    }

    /// Routes a tapped action (or the default tap/dismiss) to `handleAction(_:recordId:)` —
    /// TaskStore mutations only, NEVER opens the app window (FR-014/015/016; enforced by
    /// `NotificationActions` never declaring `.foreground` on any action, not by anything here).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let actionId = response.actionIdentifier
        // Same non-Sendable-completion-handler-across-isolation fix as `willPresent` above — box it
        // in a `nonisolated(unsafe) let` so sending it into the `@MainActor` Task doesn't trip
        // Swift 6's data-race diagnostic; called exactly once via `defer` on the main actor.
        nonisolated(unsafe) let handler = completionHandler
        _Concurrency.Task { @MainActor [weak self] in
            defer { handler() }
            guard let self, let recordId = UUID(uuidString: identifier) else { return }
            self.handleAction(actionId, recordId: recordId)
        }
    }
}
