// ViewModels/TodayViewModel.cs — port of TodayView.swift's bindable state/actions (views-inventory.md
// §1.16 — "CRITICAL SCOPE" section: the CURRENT NOW/NEXT/LATER spotlight grammar, not the stale flat
// list wave4-slice.md described). wave4-contract.md Stage B1 deliverable. Also backs SidebarControl
// (Sidebar.swift, §1.5) — one shared VM for the whole Today surface, per the contract's file list
// (no separate SidebarViewModel is named).
//
// SCOPE (wave4-contract.md "YOUR FILES"/"SCOPE"): toolbar, greeting header + running-focus/frog pill,
// NOW spotlight (+ 3 actions + context menu), NEXT peek, 2 collapsible drawers (Later/Completed, cap
// 6 visible rows), EmptyTodayCard gating, DelegationAmbientSection (T043, phase6-contract.md §C),
// hotkey footer, Sidebar (capture button, nav counts, privacy footer). Does NOT mount Popover/Focus/
// Notification/Ambient overlays — see TodayView.xaml's "STAGE C" comment for the insertion point;
// this VM only exposes what those overlays need to be driven from (CaptureState-derived flags,
// FocusActive, etc.), never the overlay controls themselves.
//
// VM RULES (wave4-contract.md decision 12): INPC; commands call straight into a service then
// Refresh() re-reads and raises the changed properties; subscribes to TaskListService.TasksChanged +
// CaptureFlowService.CaptureChanged, marshaled via UiDispatch.Post before touching VM state (those
// events may fire off the UI thread — CaptureFlowService.cs's own header comment says so explicitly).
// FocusSessionService raises no event of its own (plain class, see FocusSessionService.cs) — its
// countdown is timer-driven, and per the contract that timer is "owned by the VM's host": TodayView's
// code-behind arms a DispatcherQueueTimer and calls Refresh() on tick while FocusActive, this VM does
// not own a timer itself. No XAML control types appear below (Priority/AmbientMode/GlassLevel/Density
// are plain Volar.Domain/Volar.App.Theme enums, not XAML types; ThemeState is a plain observable
// class, not a control — XAML views convert enums to brushes/converters at the call site).
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Dispatching;
using Volar.App.Services;
using Volar.App.Services.State;
using Volar.App.Theme;
using Volar.Domain;
using Volar.Speech.Ambient;

namespace Volar.App.ViewModels;

/// <summary>Plain data snapshot for the NOW spotlight hero card (TodayView.swift's `nowSpotlight`,
/// views-inventory.md §1.16 item 4) — no INPC of its own; <see cref="TodayViewModel"/> replaces the
/// whole instance (raising <see cref="TodayViewModel.NowSpotlight"/>'s change) on every
/// <see cref="TodayViewModel.Refresh"/> rather than mutating one in place. Actions live on
/// <see cref="TodayViewModel"/> (StartFocus/ToggleActiveDone/DelegateActive/OpenActiveDetail/
/// RequestActiveBreakdown/DeleteActive), applied against <see cref="Id"/> — this type is intentionally
/// just presentation data.</summary>
public sealed class NowSpotlightViewModel
{
    public required Guid Id { get; init; }
    public required string Title { get; init; }
    public required bool IsDone { get; init; }
    public string? DurationLabel { get; init; }
    public string? TimeBadgeText { get; init; }

    /// <summary>Mirrors `SpotlightChip(value: "Hardest task today", style: .frog)` (TodayView.swift
    /// `nowChips`, gated on `task.frog`).</summary>
    public bool ShowFrogChip { get; init; }

    /// <summary>Mirrors the `!task.conditions.isEmpty` dependency chip (TodayView.swift `nowChips`).</summary>
    public bool ShowDependencyChip { get; init; }
}

/// <summary>One row of the T043 "needs review" ambient card (TodayView.swift's `needsReviewCard`) —
/// pure data, actions live on <see cref="TodayViewModel"/> keyed by <see cref="Id"/>.</summary>
public sealed record DelegationReviewItemViewModel(Guid Id, string Title);

/// <summary>One candidate row of the "an AI run finished — which task was it?" disambiguation card
/// (TodayView.swift's `disambiguationCard`) — pure data, actions live on <see cref="TodayViewModel"/>.</summary>
public sealed record DisambiguationCandidateViewModel(Guid Id, string Title);

/// <summary>The Views-layer front door onto Today's service graph — see this file's header for scope
/// and threading rules.</summary>
public sealed class TodayViewModel : INotifyPropertyChanged
{
    /// <summary>Swift's hardcoded WIP soft-limit (`DelegationAmbientSection.wipSoftLimit`,
    /// TodayView.swift:811).</summary>
    private const int WipSoftLimit = 4;

    // The Upcoming/Inbox nav counts were hardcoded 12/3 placeholders here (ported from Sidebar.swift's
    // own literals, where the rows had empty `{}` actions). They are live as of 2026-07-27 — see
    // UpcomingNavCount/InboxNavCount below and Volar.Domain.TaskSections for what each section means.

    private readonly ITaskListService _taskList;
    private readonly FocusSessionService _focus;
    private readonly CaptureFlowService _capture;
    private readonly DelegationOrchestratorService _delegation;
    private readonly ITimeProvider _clock;
    private readonly TimeZoneInfo _timeZone;
    private readonly DispatcherQueue? _dispatcherQueue;

    private bool _wipHintDismissed;
    private bool _laterExpanded;
    private bool _completedExpanded;

    public TodayViewModel(
        ITaskListService taskList,
        FocusSessionService focus,
        CaptureFlowService capture,
        DelegationOrchestratorService delegation,
        ThemeState theme,
        ITimeProvider clock,
        DispatcherQueue? dispatcherQueue = null,
        TimeZoneInfo? timeZone = null)
    {
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _focus = focus ?? throw new ArgumentNullException(nameof(focus));
        _capture = capture ?? throw new ArgumentNullException(nameof(capture));
        _delegation = delegation ?? throw new ArgumentNullException(nameof(delegation));
        Theme = theme ?? throw new ArgumentNullException(nameof(theme));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _dispatcherQueue = dispatcherQueue;
        // Upcoming's "after today" boundary is a LOCAL calendar day, so it needs a zone. Injectable
        // (defaulted, not required) so tests can pin one instead of inheriting the build agent's.
        _timeZone = timeZone ?? TimeZoneInfo.Local;

        LaterTasks = new ObservableCollection<TaskRowViewModel>();
        CompletedTasks = new ObservableCollection<TaskRowViewModel>();
        DueDelegationTasks = new ObservableCollection<DelegationReviewItemViewModel>();
        DisambiguationCandidates = new ObservableCollection<DisambiguationCandidateViewModel>();

        _taskList.TasksChanged += OnTasksChanged;
        _capture.CaptureChanged += OnCaptureChanged;
        Theme.Changed += OnThemeChanged;

        Refresh();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Aggregated from every row VM this class creates (NEXT peek + Later + Completed rows)
    /// plus the NOW spotlight's own open-detail action — the ONE seam Stage C needs to wire the
    /// TaskDetailView overlay to (see file header "SCOPE").</summary>
    public event Action<Guid>? OpenDetailRequested;

    /// <summary>Aggregated the same way as <see cref="OpenDetailRequested"/> — the seam Stage C wires
    /// the TaskBreakdownView overlay to.</summary>
    public event Action<Guid>? BreakdownRequested;

    // ------------------------------------------------------------------------------------------
    // MARK: Theme passthrough (x:Bind target for density-dependent paddings, per decision 10)
    // ------------------------------------------------------------------------------------------

    public ThemeState Theme { get; }

    // ------------------------------------------------------------------------------------------
    // MARK: Greeting header
    // ------------------------------------------------------------------------------------------

    public string TodayDateLabel { get; private set; } = string.Empty;

    public int OpenTaskCount { get; private set; }

    public int DoneTaskCount { get; private set; }

    public bool HasOpenTasks => OpenTaskCount > 0;

    // ------------------------------------------------------------------------------------------
    // MARK: Running-focus pill / frog pill
    // ------------------------------------------------------------------------------------------

    public bool FocusActive { get; private set; }

    public bool FocusPaused { get; private set; }

    public int FocusSecondsLeft { get; private set; }

    /// <summary>"m:ss" — mirrors `fmtClock(_:)` (TodayView.swift:526-528).</summary>
    public string FocusClockLabel { get; private set; } = "0:00";

    /// <summary>Running-focus pill title. Mirrors `appState.frogTask?.title ?? "Focus"`
    /// (TodayView.swift:411).</summary>
    public string RunningFocusTitle { get; private set; } = "Focus";

    /// <summary>Idle frog pill title. Mirrors `appState.frogTask?.title ?? "Ship the auth fix"`
    /// (TodayView.swift:465) — the literal fallback string is Swift's own placeholder copy, kept
    /// as-is (faithful port, not a copy edit).</summary>
    public string FrogPillTitle { get; private set; } = "Ship the auth fix";

    // ------------------------------------------------------------------------------------------
    // MARK: NOW spotlight / NEXT peek / Later / Completed
    // ------------------------------------------------------------------------------------------

    public NowSpotlightViewModel? NowSpotlight { get; private set; }

    public TaskRowViewModel? NextPeek { get; private set; }

    public ObservableCollection<TaskRowViewModel> LaterTasks { get; }

    public ObservableCollection<TaskRowViewModel> CompletedTasks { get; }

    public bool HasLaterTasks => LaterTasks.Count > 0;

    public bool HasCompletedTasks => CompletedTasks.Count > 0;

    public bool LaterExpanded
    {
        get => _laterExpanded;
        set
        {
            if (_laterExpanded == value)
            {
                return;
            }
            _laterExpanded = value;
            Raise(nameof(LaterExpanded));
        }
    }

    public bool CompletedExpanded
    {
        get => _completedExpanded;
        set
        {
            if (_completedExpanded == value)
            {
                return;
            }
            _completedExpanded = value;
            Raise(nameof(CompletedExpanded));
        }
    }

    /// <summary>Mirrors `CollapsibleTaskSection`'s `min(tasks.count, maxVisibleRows) * (approxRowHeight
    /// + rowGap)` (TodayView.swift:723-724,742) — UNVERIFIED estimate carried over from the Swift
    /// source's own doc comment (`approxRowHeight` was never measured against a running app either
    /// side of this port).</summary>
    public double LaterDrawerMaxHeight { get; private set; }

    public double CompletedDrawerMaxHeight { get; private set; }

    public void ToggleLaterExpanded() => LaterExpanded = !LaterExpanded;

    public void ToggleCompletedExpanded() => CompletedExpanded = !CompletedExpanded;

    // ------------------------------------------------------------------------------------------
    // MARK: NOW spotlight actions (TodayView.swift `nowSpotlight`'s 3 buttons + 4-item context menu)
    // ------------------------------------------------------------------------------------------

    /// <summary>"Start focus" — only shown/enabled while `!FocusActive` (TodayView.swift:217), the
    /// view enforces that, not this method.</summary>
    public void StartFocus()
    {
        _focus.StartFocus();
        Refresh();
    }

    public async Task ToggleActiveDoneAsync()
    {
        if (NowSpotlight is not NowSpotlightViewModel active)
        {
            return;
        }
        await _taskList.ToggleDoneAsync(active.Id).ConfigureAwait(false);
        PostRefresh();
    }

    public async Task DelegateActiveAsync()
    {
        if (NowSpotlight is not NowSpotlightViewModel active)
        {
            return;
        }
        await _delegation.DelegateTaskAsync(active.Id).ConfigureAwait(false);
        PostRefresh();
    }

    public void OpenActiveDetail()
    {
        if (NowSpotlight is NowSpotlightViewModel active)
        {
            OpenDetailRequested?.Invoke(active.Id);
        }
    }

    public void RequestActiveBreakdown()
    {
        if (NowSpotlight is NowSpotlightViewModel active)
        {
            BreakdownRequested?.Invoke(active.Id);
        }
    }

    public async Task DeleteActiveAsync()
    {
        if (NowSpotlight is not NowSpotlightViewModel active)
        {
            return;
        }
        await _taskList.DeleteAsync(active.Id).ConfigureAwait(false);
        PostRefresh();
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Running-focus pill controls
    // ------------------------------------------------------------------------------------------

    public void ToggleFocusPause()
    {
        _focus.ToggleFocusPause();
        Refresh();
    }

    public void EndFocus()
    {
        _focus.EndFocus();
        Refresh();
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Toolbar (TodayView.swift's `.toolbar` — 4 ToolButtons)
    // ------------------------------------------------------------------------------------------

    public bool IsAmbientSoundPlaying { get; private set; }

    public void ToggleAmbientSound()
    {
        Theme.ToggleAmbientSound();
        Refresh();
    }

    public void ReadDayAloud() => _focus.ReadDayAloud();

    /// <summary>Mirrors the toolbar `+` button. DEVIATION from Swift (flagged, wave4-contract.md
    /// frozen decision — Stage B1 brief): Swift's `+` calls `startCapture()` unconditionally
    /// (TodayView.swift:83-85); this port calls <see cref="CaptureFlowService.ToggleCaptureAsync"/>
    /// per the contract's explicit instruction, so the same button also stops an in-flight
    /// capture.</summary>
    public async Task ToggleCaptureAsync()
    {
        await _capture.ToggleCaptureAsync().ConfigureAwait(false);
        PostRefresh();
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Ambient background gating (background BRUSH CHOICE only — TodayView/Sidebar do not
    // mount AmbientBackground itself, see file header "SCOPE")
    // ------------------------------------------------------------------------------------------

    public bool IsAmbientBackgroundActive => Theme.Ambient != AmbientMode.None;

    // ------------------------------------------------------------------------------------------
    // MARK: Sidebar
    // ------------------------------------------------------------------------------------------

    public bool IsCapturing { get; private set; }

    public string CaptureButtonLabel => IsCapturing ? "Tap to stop" : "Tap to speak";

    public int TodayNavCount => OpenTaskCount;

    /// <summary>Which nav section the main column is showing. Today until the user picks otherwise;
    /// never persisted — reopening the app lands on Today, which is the whole point of the app.</summary>
    public NavSection SelectedSection { get; private set; } = NavSection.Today;

    public int UpcomingNavCount { get; private set; }

    public int InboxNavCount { get; private set; }

    /// <summary>Upcoming's rows, already grouped by local day and ordered earliest-first.</summary>
    public IReadOnlyList<UpcomingDayGroup> UpcomingGroups { get; private set; } = Array.Empty<UpcomingDayGroup>();

    /// <summary>Inbox's rows — a flat list, deliberately: the whole definition of Inbox is "has no
    /// date and no dependency", so there is nothing to group BY. Newest first, because in a
    /// voice-first app the thing you just said is the thing you are still thinking about.</summary>
    public ObservableCollection<TaskRowViewModel> InboxTasks { get; } = new();

    public string SectionTitle => SelectedSection switch
    {
        NavSection.Upcoming => "Upcoming",
        NavSection.Inbox => "Inbox",
        _ => "Today",
    };

    /// <summary>Sub-header under the section title. Today keeps its own date + open/done counters
    /// (rendered separately by the view); these two describe what the section holds, in the same
    /// plain register.</summary>
    public string SectionSubtitle => SelectedSection switch
    {
        NavSection.Upcoming => UpcomingNavCount == 0
            ? "Nothing scheduled after today"
            : $"{UpcomingNavCount} scheduled after today",
        NavSection.Inbox => InboxNavCount == 0
            ? "Nothing waiting to be sorted"
            : $"{InboxNavCount} with no date yet",
        _ => string.Empty,
    };

    public string SectionEmptyText => SelectedSection switch
    {
        NavSection.Upcoming => "Nothing scheduled after today. Say a task with a date and it lands here.",
        _ => "Inbox is empty. Anything you capture without a date waits here.",
    };

    public bool IsSectionEmpty => SelectedSection switch
    {
        NavSection.Upcoming => UpcomingGroups.Count == 0,
        NavSection.Inbox => InboxTasks.Count == 0,
        _ => false,
    };

    public void SelectSection(NavSection section)
    {
        if (SelectedSection == section)
        {
            return;
        }
        SelectedSection = section;
        Raise(nameof(SelectedSection), nameof(SectionTitle), nameof(SectionSubtitle), nameof(SectionEmptyText), nameof(IsSectionEmpty));
    }

    // ------------------------------------------------------------------------------------------
    // MARK: DelegationAmbientSection (T043, phase6-contract.md §C)
    // ------------------------------------------------------------------------------------------

    public int WipCount { get; private set; }

    public bool ShowWipHint => WipCount > WipSoftLimit && !_wipHintDismissed;

    public ObservableCollection<DelegationReviewItemViewModel> DueDelegationTasks { get; }

    public ObservableCollection<DisambiguationCandidateViewModel> DisambiguationCandidates { get; }

    public bool HasDisambiguationCandidates => DisambiguationCandidates.Count > 0;

    public void DismissWipHint()
    {
        _wipHintDismissed = true;
        Raise(nameof(ShowWipHint));
    }

    public async Task ResolveDisambiguationAsync(Guid taskId)
    {
        await _delegation.ResolveAppLinkDisambiguationAsync(taskId, _clock.Now).ConfigureAwait(false);
        PostRefresh();
    }

    public void DismissDisambiguation()
    {
        _delegation.DismissAppLinkDisambiguation();
        Refresh();
    }

    public async Task ResolveDelegationDoneAsync(Guid taskId)
    {
        await _delegation.ResolveDelegationDoneAsync(taskId).ConfigureAwait(false);
        PostRefresh();
    }

    public void ResolveDelegationStillWaiting(Guid taskId)
    {
        _delegation.ResolveDelegationStillWaiting(taskId, _clock.Now);
        Refresh();
    }

    public void ResolveDelegationCheckLater(Guid taskId)
    {
        _delegation.ResolveDelegationCheckLater(taskId, _clock.Now);
        Refresh();
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Refresh — the one place every bindable property is recomputed from live service state
    // ------------------------------------------------------------------------------------------

    /// <summary>Re-derives every bindable property from the injected services' CURRENT state and
    /// raises <see cref="PropertyChanged"/> for each. Safe to call from any thread that already holds
    /// the UI-thread affinity WinUI expects (mirrors every Wave 3-C service's own "raised on the UI
    /// thread" contract) — callers reacting to a service event use <see cref="PostRefresh"/> instead,
    /// which marshals first.</summary>
    public void Refresh()
    {
        // T043 WG3-adjacent: catch up the ambient recheck queue on every refresh (activation-scale
        // refresh, not a full 60s timer — the contract leaves the periodic cadence to Stage C's
        // shell; see DelegationOrchestratorService.cs's own "shell owns the Timer" header note).
        _delegation.RefreshDelegationQueue(_clock.Now);

        var now = _clock.Now;
        TodayDateLabel = now.ToString("ddd, MMM d", CultureInfo.InvariantCulture);

        var openTasks = _taskList.OpenTasks;
        var doneTasks = _taskList.DoneTasks;
        OpenTaskCount = openTasks.Count;
        DoneTaskCount = doneTasks.Count;

        var active = _taskList.ActiveTask;
        NowSpotlight = active is TaskItem activeTask
            ? new NowSpotlightViewModel
            {
                Id = activeTask.Id,
                Title = activeTask.Title,
                IsDone = activeTask.Done,
                DurationLabel = activeTask.DurationLabel,
                TimeBadgeText = activeTask.TimeBadge,
                ShowFrogChip = activeTask.Frog,
                ShowDependencyChip = activeTask.Conditions.Count > 0,
            }
            : null;

        // "remainingOpenTasks" (TodayView.swift:174-177): every open task except NOW's.
        var remaining = active is TaskItem a
            ? openTasks.Where(t => t.Id != a.Id).ToList()
            : openTasks.ToList();

        NextPeek = remaining.Count > 0 ? CreateRowViewModel(remaining[0], isActive: false) : null;

        LaterTasks.Clear();
        for (var i = 1; i < remaining.Count; i++)
        {
            LaterTasks.Add(CreateRowViewModel(remaining[i], isActive: false));
        }

        CompletedTasks.Clear();
        foreach (var task in doneTasks)
        {
            CompletedTasks.Add(CreateRowViewModel(task, isActive: false));
        }

        LaterDrawerMaxHeight = DrawerMaxHeight(LaterTasks.Count);
        CompletedDrawerMaxHeight = DrawerMaxHeight(CompletedTasks.Count);

        RefreshSections(openTasks, now);

        FocusActive = _focus.FocusActive;
        FocusPaused = _focus.FocusPaused;
        FocusSecondsLeft = _focus.FocusSecondsLeft;
        FocusClockLabel = string.Create(
            CultureInfo.InvariantCulture,
            $"{FocusSecondsLeft / 60}:{(FocusSecondsLeft % 60).ToString("D2", CultureInfo.InvariantCulture)}");

        var frogTitle = _taskList.FrogTask?.Title;
        RunningFocusTitle = frogTitle ?? "Focus";
        FrogPillTitle = frogTitle ?? "Ship the auth fix";

        IsAmbientSoundPlaying = Theme.IsAmbientSoundPlaying;
        IsCapturing = _capture.State == CaptureState.Recording;

        WipCount = _delegation.WipCount();

        DueDelegationTasks.Clear();
        foreach (var id in _delegation.DueDelegationRechecks)
        {
            if (FindTask(id) is TaskItem due)
            {
                DueDelegationTasks.Add(new DelegationReviewItemViewModel(due.Id, due.Title));
            }
        }

        DisambiguationCandidates.Clear();
        foreach (var id in _delegation.PendingDisambiguationTaskIds)
        {
            if (FindTask(id) is TaskItem candidate)
            {
                DisambiguationCandidates.Add(new DisambiguationCandidateViewModel(candidate.Id, candidate.Title));
            }
        }

        RaiseAllChanged();
    }

    /// <summary>Marshals onto the UI thread (via <see cref="UiDispatch"/>) before calling
    /// <see cref="Refresh"/> — used by command methods and service-event handlers alike, since a
    /// command method may itself run as a continuation of an <see langword="await"/> on a
    /// background-thread-completing service call (e.g. <see cref="CaptureFlowService"/>'s
    /// engine-callback-driven continuations, per that class's own header comment).</summary>
    private void PostRefresh() => UiDispatch.Post(_dispatcherQueue, Refresh);

    private TaskItem? FindTask(Guid id)
    {
        foreach (var task in _taskList.Tasks)
        {
            if (task.Id == id)
            {
                return task;
            }
        }
        return null;
    }

    private TaskRowViewModel CreateRowViewModel(TaskItem task, bool isActive)
    {
        var vm = new TaskRowViewModel(task, isActive, _taskList, Theme.RowPadY, Theme.RowGap);
        vm.OpenDetailRequested += OnRowOpenDetailRequested;
        vm.BreakdownRequested += OnRowBreakdownRequested;
        return vm;
    }

    private void OnRowOpenDetailRequested(Guid id) => OpenDetailRequested?.Invoke(id);

    private void OnRowBreakdownRequested(Guid id) => BreakdownRequested?.Invoke(id);

    /// <summary>Mirrors `CollapsibleTaskSection`'s literal constants (TodayView.swift:723-724) — see
    /// <see cref="LaterDrawerMaxHeight"/>'s doc comment.</summary>
    private double DrawerMaxHeight(int taskCount)
    {
        const double maxVisibleRows = 6;
        const double approxRowHeight = 56;
        return Math.Min(taskCount, maxVisibleRows) * (approxRowHeight + Theme.RowGap);
    }

    private void OnTasksChanged() => PostRefresh();

    private void OnCaptureChanged() => PostRefresh();

    private void OnThemeChanged(object? sender, EventArgs e) => PostRefresh();

    /// <summary>
    /// Rebuilds Upcoming/Inbox from the same open-task snapshot Today just used, so the three
    /// sections can never disagree about what exists. Sorting: Upcoming ascending by date (the next
    /// thing you have to care about first); Inbox newest-first, because in a voice-first app the
    /// capture you just made is the one still in your head.
    /// </summary>
    private void RefreshSections(IReadOnlyList<TaskItem> openTasks, DateTimeOffset now)
    {
        var startOfTomorrow = TaskSections.StartOfTomorrow(now, _timeZone);

        var dated = new List<(DateTimeOffset Date, TaskItem Task)>();
        var inbox = new List<TaskItem>();
        foreach (var task in openTasks)
        {
            if (TaskSections.UpcomingDate(task, startOfTomorrow) is DateTimeOffset date)
            {
                dated.Add((date, task));
            }
            else if (TaskSections.IsInbox(task))
            {
                inbox.Add(task);
            }
        }

        var groups = new List<UpcomingDayGroup>();
        foreach (var dayGroup in dated
            .OrderBy(entry => entry.Date)
            .GroupBy(entry => TimeZoneInfo.ConvertTime(entry.Date, _timeZone).Date))
        {
            groups.Add(new UpcomingDayGroup
            {
                Header = UpcomingGroupHeader(dayGroup.Key, now),
                Rows = dayGroup.Select(entry => CreateRowViewModel(entry.Task, isActive: false)).ToList(),
            });
        }
        UpcomingGroups = groups;
        UpcomingNavCount = dated.Count;

        InboxTasks.Clear();
        foreach (var task in inbox.OrderByDescending(task => task.CreatedAt))
        {
            InboxTasks.Add(CreateRowViewModel(task, isActive: false));
        }
        InboxNavCount = InboxTasks.Count;
    }

    /// <summary>"Tomorrow" for the next day and a weekday-qualified date after that. Deliberately no
    /// "in 3 days"-style relative phrasing beyond tomorrow: past that, a weekday is what people
    /// actually plan against.</summary>
    private string UpcomingGroupHeader(DateTime localDay, DateTimeOffset now)
    {
        var today = TimeZoneInfo.ConvertTime(now, _timeZone).Date;
        return localDay == today.AddDays(1)
            ? "Tomorrow"
            : localDay.ToString("ddd, MMM d", CultureInfo.InvariantCulture);
    }

    private void RaiseAllChanged()
    {
        foreach (var name in new[]
        {
            nameof(TodayDateLabel), nameof(OpenTaskCount), nameof(DoneTaskCount), nameof(HasOpenTasks),
            nameof(FocusActive), nameof(FocusPaused), nameof(FocusSecondsLeft), nameof(FocusClockLabel),
            nameof(RunningFocusTitle), nameof(FrogPillTitle), nameof(NowSpotlight), nameof(NextPeek),
            nameof(HasLaterTasks), nameof(HasCompletedTasks), nameof(LaterDrawerMaxHeight),
            nameof(CompletedDrawerMaxHeight), nameof(IsAmbientSoundPlaying), nameof(IsAmbientBackgroundActive),
            nameof(IsCapturing), nameof(CaptureButtonLabel), nameof(TodayNavCount), nameof(WipCount),
            nameof(SelectedSection), nameof(UpcomingNavCount), nameof(InboxNavCount), nameof(UpcomingGroups),
            nameof(SectionTitle), nameof(SectionSubtitle), nameof(SectionEmptyText), nameof(IsSectionEmpty),
            nameof(ShowWipHint), nameof(HasDisambiguationCandidates),
        })
        {
            Raise(name);
        }
    }

    private void Raise(string propertyName) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));

    private void Raise(params string[] propertyNames)
    {
        foreach (var name in propertyNames)
        {
            Raise(name);
        }
    }
}
