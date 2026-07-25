// Services/State/TriageAndSweepService.cs — port of AppState.swift's weekly stale-task triage
// (§1.19, lines 1931-2016) and evening sweep (§1.20, lines 2017-2129). Inventory cluster H.
//
// GATE METHODS (Opus decision 4, wave3c-services.md): macOS's `VolarApp.swift` sets
// `showTriage`/`showSweep`/`showMorningFrog` directly from a `.task` block, and the day/week gate
// keys for two of those three (`morningFrogLastShown`/`triageLastShownWeek`) live on a SECOND
// persistence surface entirely outside `AppState` (`VolarApp.swift`'s own `@AppStorage`, see
// appstate-inventory.md §8 — "two persistence surfaces exist, not one"). This port does not
// reproduce either wart: `MaybeShowEveningSweep`/`MaybeShowTriage`/`MaybeShowMorningFrog` below own
// their day/week gate keys AND their own presentation flags, and the shell (Wave 4/C5) calls these
// gates instead of assigning booleans. Because ownership moved, the settings keys for the triage/
// frog day-gates are NEW (`volar.triageLastShownWeek`/`volar.morningFrogLastShownDay`) — they are
// not literals from the inventory's key table, which only documents `AppState`'s OWN keys; the
// Swift originals for these two specifically lived on the shell's now-defunct `@AppStorage` surface.
// `volar.sweepLastShownDay` and `volar.triageKeptAt`, by contrast, ARE inventory literals
// (`AppState.sweepLastShownDayKey`/`triageKeptAtKey`) and are reused byte-for-byte.
//
// `hasOnboarded` and the evening sweep's `hour >= 18` gate (both applied at `VolarApp.swift`'s
// `.task` CALL SITE, never inside `maybeShowEveningSweep()` itself — see that method's own doc
// comment) are deliberately NOT reproduced here: `hasOnboarded` has no service-owned home in this
// wave (it is pure shell/onboarding-flow state), and the hour check is a presentation-layer
// decision about WHEN to call a gate, not something the gate itself should second-guess. The shell
// must gate its `MaybeShowEveningSweep` call on both conditions itself, exactly mirroring the
// Swift call site — see this task's final report, "gate methods the shell must call."
//
// BREAKDOWN SHEET (flagged, not silently invented): `triageBreakdown(_:)` is one of the four named
// triage actions (keep/breakdown/defer/drop) and is fully ported below — but `showBreakdown`'s
// bool/sheet-presentation ownership is NOT part of this file's scope (the frozen wave3c-services.md
// text for cluster H names only the gate methods for sweep/triage/morning-frog, not breakdown, and
// `showBreakdown` is one of Swift's own admittedly dual-owned flags per appstate-inventory.md §3's
// cluster-H flag). `TriageBreakdown` below raises <see cref="BreakdownRequested"/> instead of
// flipping a local bool, so Wave 4's shell/ViewModel owns "is the breakdown sheet open" the same way
// it already owns the detail-sheet trio per Opus's stage-1 review.
using System.Globalization;
using System.Text.Json;
using Volar.Core;
using Volar.Domain;
using Volar.Orchestrator;
using Volar.Reminders;

namespace Volar.App.Services.State;

public sealed class TriageAndSweepService
{
    /// <summary>`AppState.staleThreshold` (`AppState.swift:1933`) — 7 days.</summary>
    private static readonly TimeSpan StaleThreshold = TimeSpan.FromDays(7);

    /// <summary>`AppState.triageDeferInterval` (`AppState.swift:1934`) — 3 days.</summary>
    private static readonly TimeSpan TriageDeferInterval = TimeSpan.FromDays(3);

    /// <summary>`AppState.triageKeptAtKey` (`AppState.swift:380`) — inventory literal, reused as-is.</summary>
    public const string TriageKeptAtKey = "volar.triageKeptAt";

    /// <summary>`AppState.sweepLastShownDayKey` (`AppState.swift:2025`) — inventory literal, reused as-is.</summary>
    public const string SweepLastShownDayKey = "volar.sweepLastShownDay";

    /// <summary>NEW key — see this file's header "GATE METHODS" note.</summary>
    public const string TriageLastShownWeekKey = "volar.triageLastShownWeek";

    /// <summary>NEW key — see this file's header "GATE METHODS" note.</summary>
    public const string MorningFrogLastShownDayKey = "volar.morningFrogLastShownDay";

    private readonly ITaskListService _taskList;
    private readonly IOrchestratorTaskStore _orchestratorStore;
    private readonly IEligibilityAndResurfaceService _eligibility;
    private readonly ISettingsStore _settings;
    private readonly ITimeProvider _clock;
    private readonly TimeZoneInfo _timeZone;
    private readonly ReminderScheduler? _scheduler;
    private readonly DelegationOrchestratorService? _delegationOrchestrator;
    private readonly Dictionary<Guid, DateTimeOffset> _triageKeptAt;

    /// <param name="orchestratorStore">The same seam `Volar.Orchestrator.DelegationTracker` uses for
    /// its own store-backed mutations (frozen, Wave 2) — reused here for `TriageDeferAsync`'s
    /// `.afterDate` condition append, exactly the operation this interface exists for. Mutating
    /// through it and then calling <see cref="ITaskListService.RefreshAsync"/> preserves decision
    /// 5's "one owner of the in-memory list" rule: the repository is the durable source of truth,
    /// <see cref="ITaskListService"/> is the single cache over it, and this service never keeps a
    /// second `TaskItem` collection of its own.</param>
    /// <param name="scheduler">Nullable — mirrors every other `scheduler?.` call site in this
    /// codebase.</param>
    /// <param name="delegationOrchestrator">Nullable — <see cref="MaybeShowEveningSweep"/>'s
    /// delegation-reconcile step (mirrors `AppState.swift:2077-2081`) is a genuine cross-cluster call
    /// from H into I; both clusters are this agent's own files, so this is a plain constructor
    /// reference rather than a new frozen interface. A <see langword="null"/> value degrades that one
    /// step to a no-op, same convention as every other nullable collaborator here.</param>
    /// <param name="timeZone">Defaults to UTC; the real app (C5) should pass
    /// <see cref="TimeZoneInfo.Local"/> — matches the Swift original's day/week keys being computed
    /// against the SYSTEM-LOCAL calendar (its `DateFormatter`/`Calendar` never set an explicit
    /// `timeZone`, which defaults to `.autoupdatingCurrent`), not UTC.</param>
    public TriageAndSweepService(
        ITaskListService taskList,
        IOrchestratorTaskStore orchestratorStore,
        IEligibilityAndResurfaceService eligibility,
        ISettingsStore settings,
        ITimeProvider clock,
        ReminderScheduler? scheduler = null,
        DelegationOrchestratorService? delegationOrchestrator = null,
        TimeZoneInfo? timeZone = null)
    {
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _orchestratorStore = orchestratorStore ?? throw new ArgumentNullException(nameof(orchestratorStore));
        _eligibility = eligibility ?? throw new ArgumentNullException(nameof(eligibility));
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _scheduler = scheduler;
        _delegationOrchestrator = delegationOrchestrator;
        _timeZone = timeZone ?? TimeZoneInfo.Utc;
        _triageKeptAt = LoadTriageKeptAt(_settings.GetString(TriageKeptAtKey));
    }

    // MARK: - Gate-owned presentation flags (Opus decision 4)

    public bool ShowTriage { get; private set; }

    public bool ShowSweep { get; private set; }

    public bool ShowMorningFrog { get; private set; }

    /// <summary>Raised by <see cref="TriageBreakdown"/> — see this file's header "BREAKDOWN SHEET"
    /// note for why this is an event rather than an owned bool.</summary>
    public event Action<TaskItem>? BreakdownRequested;

    // MARK: - Weekly stale-task triage (T034/FR-018)

    /// <summary>Mirrors `staleTasks` (`AppState.swift:1946-1949`): open tasks untouched for at least
    /// <see cref="StaleThreshold"/>, using each task's explicit "kept" instant (if any) or its
    /// <c>CreatedAt</c> as the staleness proxy — same documented limitation as the Swift original
    /// (no per-task `lastTouchedAt` field exists yet).</summary>
    public IReadOnlyList<TaskItem> StaleTasks(DateTimeOffset now)
    {
        var cutoff = now - StaleThreshold;
        var result = new List<TaskItem>();
        foreach (var task in _taskList.OpenTasks)
        {
            var reference = _triageKeptAt.TryGetValue(task.Id, out var keptAt) ? keptAt : task.CreatedAt;
            if (reference <= cutoff)
            {
                result.Add(task);
            }
        }
        return result;
    }

    /// <summary>Mirrors `dismissBatchSheetsIfEmpty()` (`AppState.swift:1958-1961`).</summary>
    private void DismissBatchSheetsIfEmpty()
    {
        var now = _clock.Now;
        if (ShowSweep && SweepItems.Count == 0)
        {
            ShowSweep = false;
        }
        if (ShowTriage && StaleTasks(now).Count == 0)
        {
            ShowTriage = false;
        }
    }

    /// <summary>Mirrors `triageKeep(_:)` (`AppState.swift:1965-1969`).</summary>
    public void TriageKeep(TaskItem item)
    {
        _triageKeptAt[item.Id] = _clock.Now;
        PersistTriageKeptAt();
        DismissBatchSheetsIfEmpty();
    }

    /// <summary>Mirrors `triageBreakdown(_:)` (`AppState.swift:1979-1982`) — see this file's header
    /// "BREAKDOWN SHEET" note.</summary>
    public void TriageBreakdown(TaskItem item)
    {
        BreakdownRequested?.Invoke(item);
        DismissBatchSheetsIfEmpty();
    }

    /// <summary>Mirrors `triageDefer(_:)` (`AppState.swift:1987-2003`): appends an `.afterDate`
    /// condition <see cref="TriageDeferInterval"/> out (FR-017's resurface mechanism automatically
    /// picks this up once that date passes), re-derives this task's reminders, and runs the shared
    /// eligibility/resurface tail.</summary>
    public async Task TriageDeferAsync(TaskItem item)
    {
        var now = _clock.Now;
        var before = _taskList.Tasks;
        _orchestratorStore.AddCondition(new AfterDateCondition(now + TriageDeferInterval), item.Id);
        await _taskList.RefreshAsync().ConfigureAwait(false);
        // WG-1: this task's condition state just changed — re-derive its reminders, same as every
        // other condition-adding path in this codebase.
        _scheduler?.ScheduleReminders(item.Id);
        await _eligibility.NotifyEligibilityAndScheduleResurfaceAsync(before, _taskList.Tasks).ConfigureAwait(false);
        DismissBatchSheetsIfEmpty();
    }

    /// <summary>NEW method (flagged, not silently invented) — Swift never needed a dedicated
    /// dismiss for the triage sheet because `VolarApp.swift`'s own `.sheet` binding assigned
    /// `showTriage = false` directly on dismissal. Opus decision 4 explicitly forbids the shell from
    /// assigning gate-owned flags directly, and `DismissSweep`/`DismissMorningFrog` already establish
    /// the symmetric pattern for this cluster's other two gates — this fills the one gap that left
    /// (a user closing the triage sheet without having acted on every stale item) rather than leaving
    /// the shell with no legal way to do so.</summary>
    public void DismissTriage() => ShowTriage = false;

    /// <summary>Mirrors `triageDrop(_:)` (`AppState.swift:2007-2010`) — a plain delete via the
    /// single owner of task state (decision 5), which itself already runs the FR-015 eligibility
    /// notification.</summary>
    public async Task TriageDropAsync(TaskItem item)
    {
        await _taskList.DeleteAsync(item.Id).ConfigureAwait(false);
        DismissBatchSheetsIfEmpty();
    }

    // MARK: - Evening sweep (T038)

    /// <summary>Mirrors `sweepItems` (`AppState.swift:2032`) — deliberately `openTasks`, not just
    /// `nowTasks` (the Swift file's own MINORS fix comment at that line: `nowTasks` alone silently
    /// dropped every `.later`-bucket open task from the evening sweep).</summary>
    public IReadOnlyList<TaskItem> SweepItems => _taskList.OpenTasks;

    /// <summary>Mirrors `maybeShowEveningSweep()` (`AppState.swift:2063-2086`). The caller (shell) is
    /// responsible for the `hour >= 18` gate `VolarApp.swift`'s own call site applies — see this
    /// file's header comment. This method itself only self-gates on once-per-day + non-empty
    /// <see cref="SweepItems"/>, exactly like the Swift original.</summary>
    public void MaybeShowEveningSweep(DateTimeOffset now)
    {
        // WG3 (Swift's own reviewer fix, carried over verbatim): stage-2 (backoff-bumped-past-30')
        // delegations are deliberately excluded from `DueForRecheck`'s cutoff and would otherwise
        // never resurface anywhere — this evening touchpoint is `ReconcileBatch`'s documented
        // intended trigger. Independent of the day-gate below (a DIFFERENT feature's throttle), so
        // it still runs even when the sweep card itself was already shown today.
        _delegationOrchestrator?.ReconcileEveningBatch();

        var day = DayKey(now);
        if (_settings.GetString(SweepLastShownDayKey) == day)
        {
            return;
        }
        if (SweepItems.Count == 0)
        {
            return;
        }
        ShowSweep = true;
        _settings.SetString(SweepLastShownDayKey, day);
    }

    /// <summary>Mirrors `sweepComplete(_:)` (`AppState.swift:2103-2106`) — routes through the SAME
    /// completion funnel as every other completion source (decision 5 / T037).</summary>
    public async Task SweepCompleteAsync(TaskItem item)
    {
        await _taskList.ToggleDoneAsync(item.Id).ConfigureAwait(false);
        DismissBatchSheetsIfEmpty();
    }

    /// <summary>Mirrors `sweepSkip(_:)` (`AppState.swift:2112-2114`) — intentionally empty. "Skip"
    /// means "didn't get to it today," carried over silently (FR-036/constitution V: never
    /// destructive, never a silent completion, no shame styling). Named explicitly (rather than
    /// leaving the shell's future wiring an inline no-op) so this seam is documented and
    /// independently callable.</summary>
    public void SweepSkip(TaskItem item)
    {
        // Intentionally empty — see doc comment above.
    }

    /// <summary>Mirrors `dismissSweep()` (`AppState.swift:2117-2119`).</summary>
    public void DismissSweep() => ShowSweep = false;

    // MARK: - Morning frog gate (Opus decision 4 — NOT ported from AppState.swift directly; the
    // Swift day-gate lived on VolarApp.swift's own @AppStorage, see this file's header comment)

    /// <summary>Once-per-day (local calendar day), skipped when there is nothing open to pick from —
    /// mirrors the gating `VolarApp.swift`'s `.task` block applied inline
    /// (`VolarApp.swift:65-75`), now owned here per decision 4.</summary>
    public void MaybeShowMorningFrog(DateTimeOffset now)
    {
        var day = DayKey(now);
        if (_settings.GetString(MorningFrogLastShownDayKey) == day)
        {
            return;
        }
        if (_taskList.OpenTasks.Count == 0)
        {
            return;
        }
        ShowMorningFrog = true;
        _settings.SetString(MorningFrogLastShownDayKey, day);
    }

    /// <summary>Mirrors `pickFrog(_:)` (`AppState.swift:1756-1759`) — `setFrog` itself is
    /// `ITaskListService.SetFrogAsync` (cluster A, decision 5); this only adds the dismiss.</summary>
    public async Task PickFrogAsync(Guid id)
    {
        await _taskList.SetFrogAsync(id).ConfigureAwait(false);
        ShowMorningFrog = false;
    }

    /// <summary>Mirrors `dismissMorningFrog()` (`AppState.swift:1762-1764`).</summary>
    public void DismissMorningFrog() => ShowMorningFrog = false;

    // MARK: - Day/week key formatting
    //
    // Mirrors `AppState.isoDayKey(from:)` (`AppState.swift:2091-2097`, en_US_POSIX locale +
    // Gregorian calendar, "yyyy-MM-dd") and `VolarApp.swift`'s inline ISO-week computation
    // (`Calendar(identifier: .iso8601)`, "{year}-W{week}") — both against the injected
    // <see cref="_timeZone"/>, never the machine's implicit local zone, so this is deterministic
    // under a fixed clock in tests exactly like the wave-wide rule requires.

    private string DayKey(DateTimeOffset now) =>
        TimeZoneInfo.ConvertTime(now, _timeZone).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    /// <summary>ISO-8601 year-week key ("2026-W29"), matching `VolarApp.swift`'s
    /// `Calendar(identifier: .iso8601)` + `yearForWeekOfYear`/`weekOfYear` components exactly —
    /// <see cref="System.Globalization.ISOWeek"/> implements the identical ISO-8601 week-numbering
    /// rule (week 1 is the week containing the year's first Thursday).</summary>
    private string WeekKey(DateTimeOffset now)
    {
        var local = TimeZoneInfo.ConvertTime(now, _timeZone).DateTime;
        var year = System.Globalization.ISOWeek.GetYear(local);
        var week = System.Globalization.ISOWeek.GetWeekOfYear(local);
        return string.Create(CultureInfo.InvariantCulture, $"{year}-W{week}");
    }

    /// <summary>Mirrors the gating `VolarApp.swift`'s `.task` block applied inline for triage
    /// (`VolarApp.swift:77-90`) — once per ISO week, skipped when there is nothing stale.</summary>
    public void MaybeShowTriage(DateTimeOffset now)
    {
        var week = WeekKey(now);
        if (_settings.GetString(TriageLastShownWeekKey) == week)
        {
            return;
        }
        if (StaleTasks(now).Count == 0)
        {
            return;
        }
        ShowTriage = true;
        _settings.SetString(TriageLastShownWeekKey, week);
    }

    // MARK: - triageKeptAt persistence
    //
    // Mirrors `persistTriageKeptAt()` (`AppState.swift:2012-2015`, a `[String: Double]` dictionary
    // of `uuidString -> epoch-seconds`) and `init`'s load-back (`AppState.swift:448-455`). Stored as
    // a JSON string via ISettingsStore.SetString rather than the raw `UserDefaults` dictionary type
    // Swift used — `ISettingsStore` has no dictionary accessor (only string/bool, per that
    // interface's own doc comment: "all this feature needs"), so this is the smallest faithful
    // encoding.

    private void PersistTriageKeptAt()
    {
        var raw = new Dictionary<string, double>(_triageKeptAt.Count);
        foreach (var (id, at) in _triageKeptAt)
        {
            raw[id.ToString()] = at.ToUnixTimeSeconds();
        }
        _settings.SetString(TriageKeptAtKey, JsonSerializer.Serialize(raw));
    }

    /// <summary>Corrupt/absent JSON degrades to an empty dictionary — never throws, matching this
    /// codebase's "corrupt persisted state never crashes a read path" convention. A single malformed
    /// entry (bad GUID) is dropped, not fatal to the whole file — same per-entry tolerance
    /// <see cref="Adapters.FileDelegationMetaStore"/> uses.</summary>
    private static Dictionary<Guid, DateTimeOffset> LoadTriageKeptAt(string? raw)
    {
        var result = new Dictionary<Guid, DateTimeOffset>();
        if (string.IsNullOrEmpty(raw))
        {
            return result;
        }
        try
        {
            var dict = JsonSerializer.Deserialize<Dictionary<string, double>>(raw);
            if (dict is null)
            {
                return result;
            }
            foreach (var (key, seconds) in dict)
            {
                if (Guid.TryParse(key, out var id))
                {
                    result[id] = DateTimeOffset.FromUnixTimeSeconds((long)seconds);
                }
            }
        }
        catch (JsonException)
        {
            return new Dictionary<Guid, DateTimeOffset>();
        }
        return result;
    }
}
