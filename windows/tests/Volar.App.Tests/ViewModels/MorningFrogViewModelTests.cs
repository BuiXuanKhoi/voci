// ViewModels/MorningFrogViewModelTests.cs — MorningFrogViewModel (Wave 4 Stage B3), backed by a
// real TriageAndSweepService (over this folder's fakes) plus a real CaptureFlowService constructed
// against Volar.App.Tests.Capture's existing fakes (FakeIntentParser/FakeSpeechEngineProvider —
// `internal` in the same test assembly, reused per that folder's own "Capture/** is C3's"
// convention rather than duplicated a 3rd time; see CaptureFlowServiceTests.cs for the identical
// construction shape this file mirrors). Deliberately uses `Volar.App.Tests.Workflow`'s
// `FakeTaskListService` (not Capture's own same-named class — the two folders each keep their own
// copy per WorkflowTestSupport.cs's precedent) for the shared task list, so only
// FakeIntentParser/FakeSpeechEngineProvider/FakeSpeechEngine are pulled in from Capture, referenced
// by fully-qualified name below to avoid a `FakeTaskListService` name collision between the two
// `using`s.
using System.Linq;
using Volar.App.Services.State;
using Volar.App.Tests.State;
using Volar.App.Tests.Workflow;
using Volar.App.ViewModels;
using Volar.Domain;
using Xunit;

namespace Volar.App.Tests.ViewModels;

public sealed class MorningFrogViewModelTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 26, 7, 0, 0, TimeSpan.Zero);

    private static (MorningFrogViewModel Vm, TriageAndSweepService Service, FakeTaskListService TaskList, Volar.App.Tests.Capture.FakeSpeechEngineProvider EngineProvider)
        MakeHarness(IEnumerable<TaskItem>? tasks = null)
    {
        var taskList = new FakeTaskListService(tasks);
        var clock = new FixedTimeProvider(Now);
        var service = new TriageAndSweepService(
            taskList,
            new FakeOrchestratorTaskStore(),
            new RecordingEligibilityService(),
            new InMemorySettingsStore(),
            clock,
            timeZone: TimeZoneInfo.Utc);
        var engineProvider = new Volar.App.Tests.Capture.FakeSpeechEngineProvider();
        var capture = new CaptureFlowService(
            taskList,
            new RecordingEligibilityService(),
            new Volar.App.Tests.Capture.FakeIntentParser(),
            engineProvider,
            clock,
            new InMemorySettingsStore(),
            timeZone: TimeZoneInfo.Utc);
        var vm = new MorningFrogViewModel(service, taskList, capture);
        return (vm, service, taskList, engineProvider);
    }

    [Fact]
    public void Refresh_ExposesEveryOpenTask_AsACandidate()
    {
        var a = TestTasks.New(title: "a", priority: Priority.Medium);
        var b = TestTasks.New(title: "urgent one", priority: Priority.High);
        var (vm, _, _, _) = MakeHarness(new[] { a, b });

        Assert.True(vm.HasCandidates);
        Assert.Equal(2, vm.Candidates.Count);
        Assert.Contains(vm.Candidates, c => c.Id == a.Id && c.Priority == Priority.Medium);
        Assert.Contains(vm.Candidates, c => c.Id == b.Id && c.Priority == Priority.High);
    }

    [Fact]
    public void Refresh_WithNoOpenTasks_HasCandidatesIsFalse()
    {
        var (vm, _, _, _) = MakeHarness();

        Assert.False(vm.HasCandidates);
        Assert.Empty(vm.Candidates);
    }

    [Fact]
    public void Refresh_AfterMaybeShowMorningFrog_BecomesVisible()
    {
        var a = TestTasks.New(title: "a");
        var (vm, service, _, _) = MakeHarness(new[] { a });

        service.MaybeShowMorningFrog(Now);
        vm.Refresh();

        Assert.True(vm.IsVisible);
    }

    [Fact]
    public async Task PickCommand_SetsTheFrogAndDismisses()
    {
        var a = TestTasks.New(title: "pick me");
        var (vm, service, taskList, _) = MakeHarness(new[] { a });
        service.MaybeShowMorningFrog(Now);
        vm.Refresh();
        Assert.True(vm.IsVisible);

        vm.PickCommand.Execute(a.Id);
        await AsyncPoll.WaitUntilAsync(() => !vm.IsVisible);

        Assert.False(vm.IsVisible);
        Assert.True(taskList.Tasks.Single(t => t.Id == a.Id).Frog);
        Assert.Equal(a.Id, vm.SelectedId);
    }

    [Fact]
    public void SkipCommand_DismissesWithoutPickingAnyFrog()
    {
        var a = TestTasks.New(title: "a");
        var (vm, service, taskList, _) = MakeHarness(new[] { a });
        service.MaybeShowMorningFrog(Now);
        vm.Refresh();

        vm.SkipCommand.Execute(null);

        Assert.False(vm.IsVisible);
        Assert.False(taskList.Tasks.Single().Frog);
    }

    [Fact]
    public async Task VoiceCommand_TogglesCaptureAndDismisses()
    {
        var a = TestTasks.New(title: "a");
        var (vm, service, _, engineProvider) = MakeHarness(new[] { a });
        service.MaybeShowMorningFrog(Now);
        vm.Refresh();
        Assert.True(vm.IsVisible);

        vm.VoiceCommand.Execute(null);
        await AsyncPoll.WaitUntilAsync(() => !vm.IsVisible);

        Assert.False(vm.IsVisible);
        Assert.Equal(1, ((Volar.App.Tests.Capture.FakeSpeechEngine)engineProvider.SelectedEngine).StartCallCount);
    }
}
