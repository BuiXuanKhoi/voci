// ViewModels/TodayViewModelSectionsTests.cs — the Upcoming/Inbox sections behind the sidebar's nav
// rows (2026-07-27). Volar.Domain.TaskSectionsTests owns the membership RULES; these tests own what
// the view model does with them: grouping, ordering, headers, counts, and the section switch.
using Volar.App.Services.State;
using Volar.App.Tests.Capture;
using Volar.App.Tests.State;
using Volar.App.Theme;
using Volar.App.ViewModels;
using Volar.Core;
using Volar.Domain;
using Volar.Speech.Playback;
using Xunit;
using TaskState = Volar.Core.TaskState;

namespace Volar.App.Tests.ViewModels;

public class TodayViewModelSectionsTests
{
    // The fake clock's instant, pinned in UTC by CaptureTestData: Saturday 2026-07-25 09:00Z.
    private static readonly DateTimeOffset Now = CaptureTestData.Now;

    // Every test pins UTC so "tomorrow" is 2026-07-26 regardless of the build agent's zone.
    private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;

    private static DateTimeOffset At(int day, int hour) => new(2026, 7, day, hour, 0, 0, TimeSpan.Zero);

    private static TaskItem Task(
        string title,
        DateTimeOffset? deadline = null,
        IReadOnlyList<Condition>? conditions = null,
        DateTimeOffset? createdAt = null) =>
        new(
            id: Guid.NewGuid(),
            title: title,
            priority: Priority.Medium,
            when: When.Later,
            createdAt: createdAt ?? Now,
            status: TaskState.Todo,
            deadline: deadline,
            conditions: conditions);

    private static TodayViewModel CreateViewModel(params TaskItem[] tasks)
    {
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.AddRange(tasks);

        var clock = new FixedTimeProvider(Now);
        var focus = new FocusSessionService(taskList, new VoicePlayback());
        var capture = new CaptureFlowService(
            taskList,
            new RecordingEligibilityService(),
            new FakeIntentParser(),
            new FakeSpeechEngineProvider { SelectedEngine = new FakeSpeechEngine() },
            clock,
            new InMemorySettingsStore(),
            repository: null,
            scheduler: null,
            voice: null,
            delegationHandoff: null,
            timeZone: Utc);
        var delegation = new DelegationOrchestratorService(taskList, new RecordingEligibilityService(), clock);
        var theme = new ThemeState(new AppearanceAndPersistenceService(new InMemorySettingsStore()));

        return new TodayViewModel(taskList, focus, capture, delegation, theme, clock, dispatcherQueue: null, timeZone: Utc);
    }

    // MARK: - Counts (the numbers that were hardcoded 12 and 3 until 2026-07-27)

    [Fact]
    public void NavCounts_AreDerivedFromTheTaskList_NotHardcoded()
    {
        var vm = CreateViewModel(
            Task("due tomorrow", deadline: At(26, 9)),
            Task("due next week", deadline: At(31, 9)),
            Task("no date at all"),
            Task("also undated"),
            Task("undated but blocked", conditions: new Condition[] { new TaskDoneCondition(Guid.NewGuid()) }));

        Assert.Equal(2, vm.UpcomingNavCount);
        Assert.Equal(2, vm.InboxNavCount); // the blocked one is neither: it is a chain, not an unsorted capture.
    }

    [Fact]
    public void NavCounts_DueTodayStaysOnToday()
    {
        var vm = CreateViewModel(Task("due tonight", deadline: At(25, 23)));

        Assert.Equal(0, vm.UpcomingNavCount);
        Assert.Equal(0, vm.InboxNavCount);
        Assert.Equal(1, vm.TodayNavCount);
    }

    // MARK: - Upcoming grouping

    [Fact]
    public void Upcoming_GroupsByLocalDay_EarliestFirst_WithTomorrowNamed()
    {
        var vm = CreateViewModel(
            Task("later that week", deadline: At(28, 9)),
            Task("tomorrow evening", deadline: At(26, 18)),
            Task("tomorrow morning", deadline: At(26, 8)));

        Assert.Equal(2, vm.UpcomingGroups.Count);

        Assert.Equal("Tomorrow", vm.UpcomingGroups[0].Header);
        Assert.Equal(
            new[] { "tomorrow morning", "tomorrow evening" },
            vm.UpcomingGroups[0].Rows.Select(row => row.Title).ToArray());

        Assert.Equal("Tue, Jul 28", vm.UpcomingGroups[1].Header);
        Assert.Single(vm.UpcomingGroups[1].Rows);
    }

    [Fact]
    public void Upcoming_DeferredTaskAppears_UnderItsDeferDate()
    {
        // A task deferred to Monday with no deadline: invisible on Today by design, and invisible
        // everywhere before this section existed.
        var vm = CreateViewModel(Task("call the bank", conditions: new Condition[] { new AfterDateCondition(At(27, 9)) }));

        Assert.Equal(1, vm.UpcomingNavCount);
        Assert.Equal("Mon, Jul 27", Assert.Single(vm.UpcomingGroups).Header);
    }

    // MARK: - Inbox ordering

    [Fact]
    public void Inbox_IsNewestFirst()
    {
        var vm = CreateViewModel(
            Task("said first", createdAt: At(20, 9)),
            Task("said last", createdAt: At(24, 9)),
            Task("said second", createdAt: At(22, 9)));

        Assert.Equal(
            new[] { "said last", "said second", "said first" },
            vm.InboxTasks.Select(row => row.Title).ToArray());
    }

    // MARK: - The section switch itself

    [Fact]
    public void SelectSection_SwitchesTitleAndEmptyState_AndRaisesChange()
    {
        var vm = CreateViewModel(Task("undated"));
        var raised = new List<string?>();
        vm.PropertyChanged += (_, e) => raised.Add(e.PropertyName);

        Assert.Equal(NavSection.Today, vm.SelectedSection);
        Assert.Equal("Today", vm.SectionTitle);

        vm.SelectSection(NavSection.Inbox);

        Assert.Equal(NavSection.Inbox, vm.SelectedSection);
        Assert.Equal("Inbox", vm.SectionTitle);
        Assert.Equal("1 with no date yet", vm.SectionSubtitle);
        Assert.False(vm.IsSectionEmpty);
        Assert.Contains(nameof(TodayViewModel.SelectedSection), raised);
        Assert.Contains(nameof(TodayViewModel.SectionTitle), raised);
    }

    [Fact]
    public void SelectSection_SameSectionTwice_RaisesNothingTheSecondTime()
    {
        var vm = CreateViewModel();
        vm.SelectSection(NavSection.Upcoming);

        var raised = new List<string?>();
        vm.PropertyChanged += (_, e) => raised.Add(e.PropertyName);
        vm.SelectSection(NavSection.Upcoming);

        Assert.Empty(raised);
    }

    [Fact]
    public void EmptySections_ReportEmptyWithTheirOwnCopy()
    {
        var vm = CreateViewModel();

        vm.SelectSection(NavSection.Upcoming);
        Assert.True(vm.IsSectionEmpty);
        Assert.Equal("Nothing scheduled after today", vm.SectionSubtitle);
        Assert.Contains("Say a task with a date", vm.SectionEmptyText);

        vm.SelectSection(NavSection.Inbox);
        Assert.True(vm.IsSectionEmpty);
        Assert.Equal("Nothing waiting to be sorted", vm.SectionSubtitle);
        Assert.Contains("without a date", vm.SectionEmptyText);
    }
}
