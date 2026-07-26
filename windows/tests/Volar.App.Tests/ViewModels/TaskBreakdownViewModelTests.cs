// ViewModels/TaskBreakdownViewModelTests.cs — TaskBreakdownViewModel (Wave 4 Stage B3). Pure
// UI-local state, no service dependency — see TaskBreakdownViewModel.cs's own header for why
// (Stage C wires `TriageAndSweepService.BreakdownRequested` to `Show` externally).
using Volar.App.Tests.State;
using Volar.App.ViewModels;
using Xunit;

namespace Volar.App.Tests.ViewModels;

public sealed class TaskBreakdownViewModelTests
{
    [Fact]
    public void InitialState_IsNotVisible_HasFiveHardcodedSteps_AndSaveIsDisabled()
    {
        var vm = new TaskBreakdownViewModel();

        Assert.False(vm.IsVisible);
        Assert.Equal(5, vm.Steps.Count);
        Assert.Equal("Open Framer", vm.Steps[0].Label);
        Assert.Equal("Publish + share link", vm.Steps[4].Label);
        Assert.Equal("40 min", vm.TotalLabel);
        Assert.Equal(5, vm.StepCount);
        Assert.Equal("5", vm.StepCountText);
        Assert.False(vm.IsSaveEnabled);
    }

    [Fact]
    public void Show_MakesTheSheetVisible_AndRecordsTheTriggeringTask()
    {
        var task = TestTasks.New(title: "Launch landing page");
        var vm = new TaskBreakdownViewModel();

        vm.Show(task);

        Assert.True(vm.IsVisible);
        Assert.Equal(task.Id, vm.TriggerTask?.Id);
    }

    [Fact]
    public void Close_HidesTheSheet()
    {
        var vm = new TaskBreakdownViewModel();
        vm.Show(TestTasks.New(title: "x"));
        Assert.True(vm.IsVisible);

        vm.Close();

        Assert.False(vm.IsVisible);
    }

    [Fact]
    public void EditAndCancelCommands_BothClose()
    {
        var vmEdit = new TaskBreakdownViewModel();
        vmEdit.Show(TestTasks.New(title: "x"));
        vmEdit.EditCommand.Execute(null);
        Assert.False(vmEdit.IsVisible);

        var vmCancel = new TaskBreakdownViewModel();
        vmCancel.Show(TestTasks.New(title: "x"));
        vmCancel.CancelCommand.Execute(null);
        Assert.False(vmCancel.IsVisible);
    }

    /// <summary>FIX G (TaskBreakdownView.swift:185-208): "Save all as tasks" must stay permanently
    /// disabled until a real breakdown generator exists — this is the regression test that protects
    /// against an agent "helpfully" flipping <see cref="TaskBreakdownViewModel.IsSaveEnabled"/>.</summary>
    [Fact]
    public void SaveAllCommand_IsNeverExecutable_EvenWhileVisible()
    {
        var vm = new TaskBreakdownViewModel();
        vm.Show(TestTasks.New(title: "x"));

        Assert.False(vm.IsSaveEnabled);
        Assert.False(vm.SaveAllCommand.CanExecute(null));
    }
}
