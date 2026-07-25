// ReminderScheduler.cs — port of Sources/Reminders/ReminderScheduler.swift: durable reminder
// scheduling + fire-time delivery (specs/002-workflow-command-center/contracts/phase4-contract.md
// §A, constitution IV).
//
// PERSISTENCE (Wave 3-B / A2): unlike the Swift original (which owns its own SwiftData
// `ModelContainer`/`ModelContext` for `ReminderRecord`), this port stays pure/no-EF-Core-reference
// (this project's own layering rule: Volar.Reminders -> Core + Domain only) by taking an injected
// <see cref="IReminderRecordStore"/> seam instead of opening a database directly. `_records` is
// kept as an in-memory `List` for the scheduler instance's lifetime, exactly as before — but it is
// now a CACHE over that store, not the only copy: every mutation that touches `_records` also
// write-throughs to `_recordStore` (see the `Persist*` helpers below), and the constructor calls
// <see cref="Rehydrate"/> once to load any rows a previous process already persisted. Constitution
// IV's "rebuild everything from durable storage on launch/wake" requirement is therefore satisfied
// the same way the Swift original satisfies it (a fresh read on construction already sees prior
// rows) without this project taking on an EF Core dependency itself —
// <see cref="Volar.Data.ReminderRecordRepository"/> (referenced only in doc comments, never in
// code, to keep this project EF-Core-free) is the real SQLite-backed implementation; the
// constructor's default (<see cref="InMemoryReminderRecordStore"/>) has no durability at all, which
// is exactly the pre-this-wave behavior every existing caller already depends on.
//
// TIME NOTE: every method that needs "now" takes it as an explicit `DateTimeOffset` parameter
// rather than reading the system clock internally (`Date()` in Swift) — matches this project's own
// domain-purity convention (see `Volar.Domain/TaskItem.cs`'s remarks: "mọi thời điểm 'bây giờ' phải
// là tham số truyền vào" / every instant must be supplied explicitly by the caller) and keeps this
// class trivially unit-testable without wall-clock flakiness.
using TaskState = Volar.Core.TaskState;
using Volar.Domain;

namespace Volar.Reminders;

/// <summary>
/// Pure reminder scheduling engine: derives reminder fire-times from task deadlines, decides at
/// fire-time whether to show/speak (fresh-reload suppression, escalation, context-gate voice
/// suppression), and keeps the nearest-N reminders registered with an injected
/// <see cref="IToastChannel"/> under a fixed system-request cap.
/// </summary>
/// <remarks>
/// Constructor mirrors Swift's `ReminderScheduler.init(store: TaskStore, voice: VoiceReminderChannel,
/// gate: ReminderContextGate)`, with `voice: VoiceReminderChannel` replaced by
/// `channel: IToastChannel` — visual toast delivery and spoken delivery are folded into one seam
/// here (see <see cref="IToastChannel"/>'s doc comment for why), and the OS
/// `UNUserNotificationCenter`-delegate self-wiring (`init`'s `UNUserNotificationCenter.current().delegate
/// = self`) has no equivalent here: a Wave-3 Windows toast adapter is expected to route its own
/// OS-level "toast activated"/"action invoked" callbacks into <see cref="PresentationDecision"/> /
/// <see cref="HandleAction"/> respectively, the same way `willPresent`/`didReceive` do in the Swift
/// `UNUserNotificationCenterDelegate` extension at the bottom of the original file.
/// </remarks>
public sealed class ReminderScheduler
{
    /// <summary>
    /// Headroom under `UNUserNotificationCenter`'s documented ~64 pending-local-notification cap
    /// (research.md R2) — leaves room for any other notification source the app might add later and
    /// avoids racing the exact ceiling. Windows' toast-queue limits differ, but this cap is kept
    /// as-is (a conservative, already-researched number) until Wave 3's concrete adapter says
    /// otherwise.
    /// </summary>
    public const int SystemRequestCap = 60;

    private readonly IReminderTaskStore _store;
    private readonly IToastChannel _channel;
    private readonly ReminderContextGate _gate;
    private readonly IReminderSettingsProvider _settings;
    private readonly TimeZoneInfo _timeZone;
    private readonly IReminderRecordStore _recordStore;
    private readonly List<ReminderRecord> _records = new();

    /// <param name="recordStore">Wave 3-B (A2) durability seam — see the class header. Defaults to
    /// <see cref="InMemoryReminderRecordStore"/> (no durability, matching every pre-this-wave
    /// caller's existing behavior) so this parameter is additive: no existing constructor call
    /// site needs to change.</param>
    public ReminderScheduler(
        IReminderTaskStore store,
        IToastChannel channel,
        ReminderContextGate gate,
        IReminderSettingsProvider? settings = null,
        TimeZoneInfo? timeZone = null,
        IReminderRecordStore? recordStore = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _channel = channel ?? throw new ArgumentNullException(nameof(channel));
        _gate = gate ?? throw new ArgumentNullException(nameof(gate));
        _settings = settings ?? new DefaultReminderSettingsProvider();
        _timeZone = timeZone ?? TimeZoneInfo.Utc;
        _recordStore = recordStore ?? new InMemoryReminderRecordStore();
        Rehydrate();
    }

    /// <summary>
    /// Loads every durable row from <see cref="_recordStore"/> into the in-memory cache — the
    /// actual fix for the restart bug this wave exists to close (see class header: the Swift
    /// original gets this "for free" from a fresh SwiftData <c>ModelContext</c> fetch on
    /// <c>init</c>; this port needs an explicit step because <see cref="_records"/> is a plain
    /// in-memory cache, not a live query). Called once, at the end of the constructor — mirrors
    /// the Swift <c>init</c>'s own ordering ("load here; the app shell calls
    /// <see cref="RebuildFromStorage"/> separately, afterward"). Left <see langword="public"/> (not
    /// just constructor-private) so a Wave-3-C caller can re-run it explicitly if it ever needs to
    /// reload from a store mutated out-of-process, though nothing in this project requires that
    /// today. A store failure degrades gracefully — starts/stays with an empty cache rather than
    /// crashing app launch, matching this codebase's established "corrupt/unreadable durable state
    /// starts empty, never throws" convention (e.g. the Wave-3-A JSON settings store).
    /// </summary>
    public void Rehydrate()
    {
        try
        {
            var rows = _recordStore.LoadAll();
            _records.Clear();
            _records.AddRange(rows);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[Volar.Reminders.ReminderScheduler] rehydrate failed: {ex.Message}");
        }
    }

    // MARK: - Write-through helpers (Wave 3-B / A2)
    //
    // Every one of this class's `_records` mutation sites below (Add/AddRange/Remove/in-place
    // field assignment) is paired with exactly one of these three calls, so `_recordStore` can
    // never drift out of sync with the in-memory cache. Mirrors the Swift original's `save()`
    // error-handling philosophy verbatim ("log, never throw into the caller" — see that method's
    // doc comment: `catch { print(...) }`): a persistence failure must not take down a live
    // reminder-scheduling call the way an unhandled exception would.

    private void PersistUpsert(ReminderRecord record)
    {
        try
        {
            _recordStore.Upsert(record);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[Volar.Reminders.ReminderScheduler] save failed: {ex.Message}");
        }
    }

    private void PersistUpsertRange(IEnumerable<ReminderRecord> records)
    {
        try
        {
            _recordStore.UpsertRange(records);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[Volar.Reminders.ReminderScheduler] save failed: {ex.Message}");
        }
    }

    private void PersistDelete(Guid id)
    {
        try
        {
            _recordStore.Delete(id);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[Volar.Reminders.ReminderScheduler] save failed: {ex.Message}");
        }
    }

    // MARK: - Contract §A

    /// <summary>
    /// Rebuilds ALL scheduler state: re-derives reminders for every open, dated task that doesn't
    /// have any <see cref="ReminderRecord"/> yet (covers a task created/edited before this scheduler
    /// existed, or a derivation that never landed), fires any `.scheduled` record already past due
    /// ("due-but-missed" recovery — constitution IV), then refills the system's pending-request
    /// queue with the nearest-N. Call once at launch; the Wave-3 App shell is expected to also call
    /// this on wake (mirrors Swift's `NSWorkspace.didWakeNotification` hook, which lives in
    /// App-wiring, not here).
    /// </summary>
    public void RebuildFromStorage(DateTimeOffset now)
    {
        var tasks = _store.FetchAll();
        var openDatedTasks = new List<TaskItem>();
        foreach (var task in tasks)
        {
            if ((task.Status == TaskState.Todo || task.Status == TaskState.InProgress) && task.Deadline is not null)
            {
                openDatedTasks.Add(task);
            }
        }
        foreach (var task in openDatedTasks)
        {
            EnsureDerived(task.Id, task.Deadline, task.ReminderOverride);
        }

        var byId = new Dictionary<Guid, TaskItem>(tasks.Count);
        foreach (var task in tasks)
        {
            byId[task.Id] = task;
        }

        // FIX B: a notification the OS already delivered while the app was backgrounded/not running
        // never routed through the live presentation path, so its record would be stuck at
        // "scheduled" forever — the due-but-missed pass below would then treat it as missed and
        // re-fire it as a SECOND notification on every future launch/wake. Reconcile against the
        // channel's already-delivered ids first so an already-delivered record is marked
        // "delivered" (not re-fired) before the due-but-missed pass runs.
        ReconcileDeliveredNotifications();

        var dueButMissed = new List<ReminderRecord>();
        foreach (var record in _records)
        {
            if (record.State == "scheduled" && record.FireAt <= now)
            {
                dueButMissed.Add(record);
            }
        }
        foreach (var record in dueButMissed)
        {
            Fire(record, byId, now);
        }

        RefillSystemRequests();
    }

    /// <summary>
    /// FIX B helper: marks every "scheduled" record whose id matches an already-channel-delivered
    /// notification's identifier as "delivered". No-op if nothing was delivered or nothing needs
    /// updating.
    /// </summary>
    private void ReconcileDeliveredNotifications()
    {
        var delivered = _channel.GetDeliveredIds();
        if (delivered.Count == 0)
        {
            return;
        }
        var deliveredIds = new HashSet<Guid>(delivered);
        if (deliveredIds.Count == 0)
        {
            return;
        }
        foreach (var record in _records)
        {
            if (record.State == "scheduled" && deliveredIds.Contains(record.Id))
            {
                record.State = "delivered";
                PersistUpsert(record); // FIX B write-through: durable state must match the cache.
            }
        }
    }

    /// <summary>
    /// Derives + persists this task's reminder set from its deadline × (`reminderOverride` ??
    /// global policy), replacing any not-yet-delivered rows from a prior derivation (deadline edits,
    /// recurrence resets land here). Delivered/satisfied history is left alone — this only ever
    /// touches "scheduled" rows. A closed (done/archived) task gets no reminders at all.
    /// </summary>
    public void ScheduleReminders(TaskItem task)
    {
        DeriveAndSchedule(task.Id, task.Status, task.Deadline, task.ReminderOverride);
    }

    /// <summary>
    /// Resolves the task fresh from the injected store by id and derives from that. A
    /// missing/deleted id is treated as "nothing to schedule," not an error — mirrors every other
    /// not-found fallback in this subsystem.
    /// </summary>
    public void ScheduleReminders(Guid taskId)
    {
        foreach (var task in _store.FetchAll())
        {
            if (task.Id == taskId)
            {
                DeriveAndSchedule(taskId, task.Status, task.Deadline, task.ReminderOverride);
                return;
            }
        }
    }

    /// <summary>Shared body for both <see cref="ScheduleReminders(TaskItem)"/> overloads above, so
    /// the derive logic can't drift apart between them.</summary>
    private void DeriveAndSchedule(Guid taskId, TaskState status, DateTimeOffset? deadline, ReminderPolicy? reminderOverride)
    {
        ClearScheduled(taskId);
        if (status != TaskState.Todo && status != TaskState.InProgress)
        {
            return;
        }
        var records = ReminderRecord.Derive(taskId, deadline, reminderOverride, _settings.CurrentGlobalReminderPolicy);
        _records.AddRange(records);
        PersistUpsertRange(records);
        RefillSystemRequests();
    }

    /// <summary>
    /// Cancels every reminder for <paramref name="taskId"/> — both the in-memory rows and any
    /// request already registered with the channel — so completion/deletion never leaves an
    /// orphaned notification behind (constitution IV's cascade requirement). Safe to call for a task
    /// with no reminders.
    /// </summary>
    public void CancelReminders(Guid taskId)
    {
        var records = RecordsForTask(taskId);
        if (records.Count == 0)
        {
            return;
        }
        var ids = new List<Guid>(records.Count);
        foreach (var record in records)
        {
            ids.Add(record.Id);
        }
        _channel.CancelPending(ids);
        foreach (var record in records)
        {
            _records.Remove(record);
            PersistDelete(record.Id);
        }
        RefillSystemRequests();
    }

    /// <summary>
    /// Fresh reload + fire "right now": reloads the task fresh from the store and suppresses
    /// (resolves the record to "satisfied", delivers nothing) if it's done/archived/deleted;
    /// otherwise posts an immediate delivery and speaks if the escalation rule says to. Used for (1)
    /// due-but-missed recovery (<see cref="RebuildFromStorage"/>) and (2) the immediate-delivery
    /// helpers below (<see cref="ScheduleResurface"/>/<see cref="NotifyUnblocked"/>/
    /// <see cref="OfferReschedule"/>). NOT used for a reminder the channel is already about to
    /// present live on its own schedule — that path is <see cref="PresentationDecision"/>, so a
    /// pre-registered banner is never duplicated.
    /// </summary>
    public void HandleFire(Guid recordId, DateTimeOffset now)
    {
        var record = FetchRecord(recordId);
        if (record is null)
        {
            return;
        }
        Fire(record, snapshot: null, now);
    }

    /// <summary>
    /// FR-017: resurface <paramref name="taskId"/> at <paramref name="date"/> (e.g. an
    /// after-date condition's target). Scheduled ahead like a normal reminder — not fired
    /// immediately.
    /// </summary>
    /// <remarks>
    /// FIX A: a caller re-evaluating this on every mutation of a task with an after-date condition
    /// would, with a naive unconditional insert, pile up a new "scheduled" resurface row (and a
    /// duplicate banner) on every single edit. Dedupe against any existing not-yet-delivered
    /// resurface record for this task first: same fire time -&gt; no-op; different fire time -&gt;
    /// update that one row in place instead of inserting a second.
    /// </remarks>
    public void ScheduleResurface(DateTimeOffset date, Guid taskId)
    {
        ReminderRecord? existing = null;
        foreach (var record in RecordsForTask(taskId))
        {
            if (record.OffsetKind == "resurface" && record.State == "scheduled")
            {
                existing = record;
                break;
            }
        }
        if (existing is not null)
        {
            if (existing.FireAt == date)
            {
                return;
            }
            // The old fire time may already be registered with the channel under this record's
            // identifier — drop it so `RefillSystemRequests` (below) treats the record as
            // unregistered and re-posts it with the new trigger time.
            _channel.CancelPending(new[] { existing.Id });
            existing.FireAt = date;
            PersistUpsert(existing);
            RefillSystemRequests();
            return;
        }
        var newRecord = new ReminderRecord(taskId: taskId, fireAt: date, offsetKind: "resurface");
        _records.Add(newRecord);
        PersistUpsert(newRecord);
        RefillSystemRequests();
    }

    /// <summary>
    /// FR-015: one notification per newly-eligible task, fired immediately — there's nothing to
    /// schedule ahead of time, the unblock just happened. Caller passes the eligibility-diff result
    /// once per mutation so this never double-notifies the same unblock event.
    /// </summary>
    public void NotifyUnblocked(IReadOnlyList<Guid> taskIds, DateTimeOffset now)
    {
        foreach (var taskId in taskIds)
        {
            var record = new ReminderRecord(taskId: taskId, fireAt: now, offsetKind: "unblocked");
            _records.Add(record);
            PersistUpsert(record);
            HandleFire(record.Id, now);
        }
    }

    /// <summary>
    /// FR-016: an overdue nudge offering tonight/tomorrow/weekend reschedule actions
    /// (<see cref="ReminderCategory.OverdueReschedule"/>, reached via the shared "resurface" offset
    /// kind — see <see cref="NotificationActions.CategoryForOffsetKind"/> for how the two are told
    /// apart at delivery time). Fired immediately, same reasoning as <see cref="NotifyUnblocked"/>.
    /// </summary>
    public void OfferReschedule(Guid taskId, DateTimeOffset now)
    {
        var record = new ReminderRecord(taskId: taskId, fireAt: now, offsetKind: "resurface");
        _records.Add(record);
        PersistUpsert(record);
        HandleFire(record.Id, now);
    }

    // MARK: - Toast-adapter callback surface (see the class doc comment: a Wave-3 adapter routes its
    // own OS toast events into these two methods, the same role `NotificationActions.swift` +
    // `ReminderScheduler.swift`'s `UNUserNotificationCenterDelegate` extension play together in
    // Swift.)

    /// <summary>
    /// The channel is already about to show a pre-registered banner live. This does the SAME
    /// fresh-reload + suppress-or-show + maybe-speak evaluation as <see cref="Fire"/>'s private
    /// core, but only returns the decision instead of posting a new request (posting again here
    /// would duplicate the banner the system is already displaying).
    /// </summary>
    /// <remarks>
    /// FIX C (<see cref="VoiceDeliveryMode.VoiceOnly"/>): this method's return value controls
    /// whether the banner should actually be shown, so `.voiceOnly` is honored here by folding
    /// `mode != .voiceOnly` into both return paths below — the record is still marked delivered and
    /// voice still speaks per the existing gates in <see cref="Evaluate"/> either way, only the
    /// visual presentation is suppressed. LIMITATION (inherited from the Swift original): this only
    /// applies when the concrete adapter is alive to route the OS's live-presentation callback into
    /// this method — a notification delivered while the app is fully unlaunched is shown by the OS
    /// with its own default presentation and never reaches this method, so <c>VoiceOnly</c> cannot
    /// suppress that banner.
    /// </remarks>
    public bool PresentationDecision(Guid recordId, DateTimeOffset now)
    {
        var record = FetchRecord(recordId);
        if (record is null)
        {
            return false;
        }
        var mode = _settings.CurrentVoiceDeliveryMode;
        // `Fire` sets `record.State = "delivered"` BEFORE it posts the immediate delivery it fires
        // for (NotifyUnblocked/OfferReschedule/due-but-missed recovery), so by the time the adapter
        // would call this for that same request, this record is already "delivered", not
        // "scheduled" — `Fire` already ran `Evaluate` (and the voice/gate decision) for it moments
        // earlier. Trust the decision `Fire` already made and show it, instead of re-evaluating
        // gates a second time.
        if (record.State == "delivered")
        {
            return mode != VoiceDeliveryMode.VoiceOnly;
        }
        if (record.State != "scheduled")
        {
            return false;
        }
        var evaluation = Evaluate(record, snapshot: null, now);
        if (evaluation is null)
        {
            _records.Remove(record);
            PersistDelete(record.Id);
            return false;
        }
        record.State = evaluation.ShouldShow ? "delivered" : "satisfied";
        PersistUpsert(record);
        if (evaluation.ShouldShow && evaluation.ShouldSpeak)
        {
            var timing = TimingPhrase(record.OffsetKind);
            _channel.Speak(ComposeSpokenSentence(evaluation.Task.Title, timing, evaluation.IsSensitive));
        }
        RefillSystemRequests();
        return evaluation.ShouldShow && mode != VoiceDeliveryMode.VoiceOnly;
    }

    /// <summary>
    /// Routes a tapped action to a task-store mutation or a reschedule, WITHOUT ever opening the app
    /// window (FR-014/015/016 — enforced by <see cref="NotificationActions"/> never declaring a
    /// foreground/activation flag on any action, not by anything here).
    /// </summary>
    public void HandleAction(string actionId, Guid recordId, DateTimeOffset now)
    {
        var record = FetchRecord(recordId);
        if (record is null)
        {
            return;
        }
        switch (actionId)
        {
            case ReminderAction.Done:
                {
                    var taskId = record.TaskId;
                    _store.Toggle(taskId, now);
                    record.State = "satisfied";
                    PersistUpsert(record);
                    // Mirrors the Swift original: `store.Toggle` can leave the task done/archived,
                    // OR reopen it in place (a recurring task resets to todo with a fresh deadline).
                    // Either way this record alone isn't the whole story — cancel the REST of this
                    // task's reminders, and if it's still open, re-derive them from the new
                    // deadline. Without this, a recurring task's future reminders are silently lost
                    // forever: `EnsureDerived` only derives for a task with zero records, so once
                    // this task has any records at all it's skipped on every later
                    // `RebuildFromStorage`.
                    //
                    // (The Swift original also posts `.volarTasksDidChange` here so `AppState`
                    // refreshes its in-memory task list — that's App-wiring pub/sub with no
                    // equivalent in this pure project; Wave 3's app shell must observe store
                    // mutations itself after calling into this method.)
                    if (TryFindTask(taskId, out var fresh))
                    {
                        CancelReminders(taskId);
                        if (fresh.Status != TaskState.Done && fresh.Status != TaskState.Archived)
                        {
                            ScheduleReminders(taskId);
                        }
                    }
                    break;
                }
            case ReminderAction.Snooze10:
                Reschedule(record, now.AddMinutes(10));
                PersistUpsert(record);
                break;
            case ReminderAction.Tomorrow:
            case ReminderAction.RescheduleTomorrow:
                Reschedule(record, TomorrowMorning(now, _timeZone));
                PersistUpsert(record);
                break;
            case ReminderAction.RescheduleTonight:
                Reschedule(record, Tonight(now, _timeZone));
                PersistUpsert(record);
                break;
            case ReminderAction.RescheduleWeekend:
                Reschedule(record, NextWeekend(now, _timeZone));
                PersistUpsert(record);
                break;
            default:
                // Default tap / dismiss identifiers: no state change, no window — a
                // glance-and-dismiss reminder that isn't acted on just stays as-is (constitution V).
                break;
        }
        RefillSystemRequests();
    }

    // MARK: - Shared fire core

    private sealed record FireEvaluation(TaskItem Task, bool IsSensitive, bool ShouldShow, bool ShouldSpeak);

    /// <summary>
    /// The "reload fresh -&gt; suppress-if-done -&gt; decide voice" core shared by
    /// <see cref="HandleFire"/>/<see cref="RebuildFromStorage"/>'s due-but-missed loop and
    /// <see cref="PresentationDecision"/>. <paramref name="snapshot"/>, when provided, avoids a
    /// redundant store fetch for a caller that already fetched one (used by
    /// <see cref="RebuildFromStorage"/> to stay O(n) instead of O(n·m) for m due records);
    /// <see langword="null"/> fetches fresh, which is exactly the "fire-time fresh reload"
    /// constitution IV requires for a single-record call.
    /// </summary>
    private FireEvaluation? Evaluate(ReminderRecord record, IReadOnlyDictionary<Guid, TaskItem>? snapshot, DateTimeOffset now)
    {
        TaskItem? task = null;
        if (snapshot is not null)
        {
            if (snapshot.TryGetValue(record.TaskId, out var found))
            {
                task = found;
            }
        }
        else
        {
            foreach (var candidate in _store.FetchAll())
            {
                if (candidate.Id == record.TaskId)
                {
                    task = candidate;
                    break;
                }
            }
        }
        if (task is not TaskItem taskValue)
        {
            return null; // deleted outright — nothing to show or suppress
        }

        var isSensitive = _store.IsSensitive(taskValue.Id);
        if (taskValue.Status == TaskState.Done || taskValue.Status == TaskState.Archived)
        {
            return new FireEvaluation(taskValue, isSensitive, ShouldShow: false, ShouldSpeak: false);
        }

        var priorUnacknowledged = false;
        foreach (var other in RecordsForTask(record.TaskId))
        {
            if (other.Id != record.Id && other.State == "delivered" && other.FireAt < record.FireAt)
            {
                priorUnacknowledged = true;
                break;
            }
        }
        var mode = _settings.CurrentVoiceDeliveryMode;
        var shouldSpeak = (record.IsHighUrgency || priorUnacknowledged)
            && mode != VoiceDeliveryMode.VisualOnly
            && !_gate.ShouldSuppressVoice(now);
        return new FireEvaluation(taskValue, isSensitive, ShouldShow: true, ShouldSpeak: shouldSpeak);
    }

    /// <summary>
    /// Fires exactly one record: suppress-to-satisfied if the fresh task is done/archived/gone,
    /// otherwise post an immediate delivery (+ speak if escalation says to) and mark delivered.
    /// Guards `record.State == "scheduled"` so this is idempotent — calling it twice on an
    /// already-fired record is a no-op the second time, which is what makes "due-but-missed fires
    /// once" true.
    /// </summary>
    private void Fire(ReminderRecord record, IReadOnlyDictionary<Guid, TaskItem>? snapshot, DateTimeOffset now)
    {
        if (record.State != "scheduled")
        {
            return;
        }
        var evaluation = Evaluate(record, snapshot, now);
        if (evaluation is null)
        {
            _records.Remove(record);
            PersistDelete(record.Id);
            return;
        }
        if (!evaluation.ShouldShow)
        {
            record.State = "satisfied";
            PersistUpsert(record);
            return;
        }
        record.State = "delivered";
        PersistUpsert(record);
        var delivery = BuildDelivery(record, evaluation.Task, evaluation.IsSensitive, evaluation.ShouldSpeak);
        _channel.DeliverNow(delivery);
    }

    private static void Reschedule(ReminderRecord record, DateTimeOffset to)
    {
        record.FireAt = to;
        record.OffsetKind = "resurface";
        record.IsHighUrgency = false;
        record.State = "scheduled";
    }

    // MARK: - Date helpers (explicit local-time math — constitution: never bare
    // DateTimeOffset/TimeSpan arithmetic for wall-clock concepts like "tomorrow morning")
    //
    // `internal` (not `private`) — with `InternalsVisibleTo` granted to Volar.Reminders.Tests below
    // — purely so `SetLocalTime` (the actual DST-risk function) is directly unit-testable against a
    // real spring-forward gap without needing to contrive a public call path that happens to land a
    // fixed 09:00/20:00/10:00 wall-clock time inside one (none of the three callers ever do, since
    // none of their hardcoded hours is 2 AM).

    /// <summary>Next local calendar day at 09:00.</summary>
    internal static DateTimeOffset TomorrowMorning(DateTimeOffset now, TimeZoneInfo timeZone)
    {
        var localTomorrow = ToLocal(now, timeZone).AddDays(1);
        return SetLocalTime(localTomorrow, 9, 0, timeZone);
    }

    /// <summary>Today at 20:00 local if that's still in the future, else tomorrow at 20:00 local.</summary>
    internal static DateTimeOffset Tonight(DateTimeOffset now, TimeZoneInfo timeZone)
    {
        var localToday = ToLocal(now, timeZone);
        var candidate = SetLocalTime(localToday, 20, 0, timeZone);
        return candidate > now ? candidate : SetLocalTime(localToday.AddDays(1), 20, 0, timeZone);
    }

    /// <summary>Next Saturday at 10:00 local, strictly after <paramref name="now"/>.</summary>
    internal static DateTimeOffset NextWeekend(DateTimeOffset now, TimeZoneInfo timeZone)
    {
        var localNow = ToLocal(now, timeZone);
        var daysUntilSaturday = ((int)DayOfWeek.Saturday - (int)localNow.DayOfWeek + 7) % 7;
        var candidateDay = localNow.AddDays(daysUntilSaturday);
        var candidate = SetLocalTime(candidateDay, 10, 0, timeZone);
        if (candidate <= now)
        {
            candidate = SetLocalTime(candidateDay.AddDays(7), 10, 0, timeZone);
        }
        return candidate;
    }

    private static DateTime ToLocal(DateTimeOffset instant, TimeZoneInfo timeZone)
        => TimeZoneInfo.ConvertTime(instant, timeZone).DateTime;

    /// <summary>
    /// DST-safe local-wall-clock -&gt; absolute-instant conversion. Deliberately built on
    /// <see cref="TimeZoneInfo.GetUtcOffset(DateTime)"/> rather than
    /// <see cref="TimeZoneInfo.ConvertTimeToUtc(DateTime, TimeZoneInfo)"/> — this is the same DST
    /// trap already hit and documented at <c>Volar.Domain/LocalCalendar.cs</c>:
    /// <c>ConvertTimeToUtc</c> THROWS <see cref="ArgumentException"/> for a local time that falls in
    /// a spring-forward gap (e.g. 2024-03-10 02:30 America/Los_Angeles, which never occurred), which
    /// would crash a perfectly legitimate "snooze to tomorrow morning" computation that happens to
    /// land in a gap. <c>GetUtcOffset</c> never throws for gap/overlap times: for a gap it returns
    /// the offset in effect just before the transition (shifting the invalid wall-clock instant
    /// forward by exactly the gap's width); for a fall-back overlap it resolves to the later
    /// (post-transition, standard-time) occurrence. Both outcomes are "always a valid instant, never
    /// an exception" — see <c>ReminderSchedulerDstTests</c> for the regression test covering this.
    /// </summary>
    internal static DateTimeOffset SetLocalTime(DateTime localDate, int hour, int minute, TimeZoneInfo timeZone)
    {
        var local = new DateTime(localDate.Year, localDate.Month, localDate.Day, hour, minute, 0, DateTimeKind.Unspecified);
        var offset = timeZone.GetUtcOffset(local);
        return new DateTimeOffset(local, offset).ToUniversalTime();
    }

    // MARK: - Channel plumbing

    /// <summary>
    /// Pulls the current pending-request count, then tops it back up to <see cref="SystemRequestCap"/>
    /// with the earliest-firing "scheduled" records not already registered. Called after every
    /// mutation that could change what "nearest" means (schedule/cancel/deliver/action).
    /// </summary>
    private void RefillSystemRequests()
    {
        var pendingIds = _channel.GetPendingIds();
        var capacity = SystemRequestCap - pendingIds.Count;
        if (capacity <= 0)
        {
            return;
        }
        var candidates = NearestCandidates(_records, pendingIds, capacity);
        var tasksById = new Dictionary<Guid, TaskItem>();
        foreach (var task in _store.FetchAll())
        {
            tasksById[task.Id] = task;
        }
        foreach (var record in candidates)
        {
            if (!tasksById.TryGetValue(record.TaskId, out var task))
            {
                continue;
            }
            var delivery = BuildDelivery(record, task, isSensitive: false, shouldSpeak: false);
            _channel.Schedule(delivery, record.FireAt);
        }
    }

    /// <summary>
    /// Pure selection: earliest-firing "scheduled" records not already registered with the channel,
    /// capped at <paramref name="capacity"/>. No I/O — directly unit-testable without touching a
    /// real <see cref="IToastChannel"/> at all.
    /// </summary>
    public static IReadOnlyList<ReminderRecord> NearestCandidates(
        IReadOnlyList<ReminderRecord> records, IReadOnlyList<Guid> excludingRegisteredIds, int capacity)
    {
        if (capacity <= 0)
        {
            return Array.Empty<ReminderRecord>();
        }
        var excluded = new HashSet<Guid>(excludingRegisteredIds);
        var eligible = new List<ReminderRecord>();
        foreach (var record in records)
        {
            if (record.State == "scheduled" && !excluded.Contains(record.Id))
            {
                eligible.Add(record);
            }
        }
        eligible.Sort((a, b) => a.FireAt.CompareTo(b.FireAt));
        return eligible.Count > capacity ? eligible.GetRange(0, capacity) : eligible;
    }

    private static string TimingPhrase(string offsetKind) => offsetKind switch
    {
        "-1d" => "due tomorrow",
        "-1h" => "due in about an hour",
        "at" => "due now",
        "unblocked" => "ready to start",
        "resurface" => "worth a look",
        _ => "coming up"
    };

    /// <summary>
    /// Port of `VoiceReminderChannel.speakReminder`'s sentence-composition logic: `isSensitive ==
    /// true` speaks a generic phrase and NEVER the task's title — the whole point being that a
    /// sensitive task shouldn't be read aloud where someone else might overhear it, even though the
    /// visual toast banner (rendered by the concrete channel adapter, not this method) still shows
    /// it.
    /// </summary>
    private static string ComposeSpokenSentence(string title, string timing, bool isSensitive) =>
        isSensitive ? $"You have a reminder {timing}." : $"{title}, {timing}.";

    private static ReminderDelivery BuildDelivery(ReminderRecord record, TaskItem task, bool isSensitive, bool shouldSpeak)
    {
        var timing = TimingPhrase(record.OffsetKind);
        return new ReminderDelivery(
            RecordId: record.Id,
            TaskId: task.Id,
            BannerTitle: "Volar",
            BannerBody: $"{task.Title} — {timing}",
            CategoryId: NotificationActions.CategoryForOffsetKind(record.OffsetKind),
            SpokenText: shouldSpeak ? ComposeSpokenSentence(task.Title, timing, isSensitive) : null);
    }

    // MARK: - In-memory record access
    //
    // Public (unlike the Swift original's `internal`, which relied on `@testable import` — this
    // project's tests live in a separate assembly with no such access) — the minimal read surface
    // needed to assert on scheduler state after driving the public API
    // (RebuildFromStorage/ScheduleReminders/HandleFire/CancelReminders/etc.), and a reasonable
    // inspection API for a host app in its own right.

    public ReminderRecord? FetchRecord(Guid id)
    {
        foreach (var record in _records)
        {
            if (record.Id == id)
            {
                return record;
            }
        }
        return null;
    }

    public IReadOnlyList<ReminderRecord> RecordsForTask(Guid taskId)
    {
        var result = new List<ReminderRecord>();
        foreach (var record in _records)
        {
            if (record.TaskId == taskId)
            {
                result.Add(record);
            }
        }
        return result;
    }

    public IReadOnlyList<ReminderRecord> FetchAllRecords() => _records.ToList();

    private void ClearScheduled(Guid taskId)
    {
        var scheduled = new List<ReminderRecord>();
        foreach (var record in RecordsForTask(taskId))
        {
            if (record.State == "scheduled")
            {
                scheduled.Add(record);
            }
        }
        if (scheduled.Count == 0)
        {
            return;
        }
        var ids = new List<Guid>(scheduled.Count);
        foreach (var record in scheduled)
        {
            ids.Add(record.Id);
        }
        _channel.CancelPending(ids);
        foreach (var record in scheduled)
        {
            _records.Remove(record);
            PersistDelete(record.Id);
        }
    }

    /// <summary>
    /// Only derives when NO record exists yet for <paramref name="taskId"/> (any state) — makes
    /// repeated <see cref="RebuildFromStorage"/> calls idempotent instead of re-deriving (and
    /// re-firing) the same offsets on every wake.
    /// </summary>
    private void EnsureDerived(Guid taskId, DateTimeOffset? deadline, ReminderPolicy? reminderOverride)
    {
        if (RecordsForTask(taskId).Count > 0)
        {
            return;
        }
        var records = ReminderRecord.Derive(taskId, deadline, reminderOverride, _settings.CurrentGlobalReminderPolicy);
        _records.AddRange(records);
        PersistUpsertRange(records);
    }

    private bool TryFindTask(Guid taskId, out TaskItem task)
    {
        foreach (var candidate in _store.FetchAll())
        {
            if (candidate.Id == taskId)
            {
                task = candidate;
                return true;
            }
        }
        task = default;
        return false;
    }
}
