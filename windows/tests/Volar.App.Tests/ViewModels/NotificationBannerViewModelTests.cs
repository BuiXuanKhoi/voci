// ViewModels/NotificationBannerViewModelTests.cs — NotificationBannerViewModel (Wave 4 Stage B5).
// Constructed with a null DispatcherQueue (callbacks run inline — see UiDispatch.Post's own doc
// comment) and an injected fake delay so the 5s auto-dismiss never actually waits 5 real seconds.
using Volar.App.ViewModels;
using Xunit;

namespace Volar.App.Tests.ViewModels;

public sealed class NotificationBannerViewModelTests
{
    [Fact]
    public void InitialState_IsNotVisible()
    {
        var vm = new NotificationBannerViewModel();
        Assert.False(vm.IsVisible);
    }

    [Fact]
    public void Show_SetsFieldsAndBecomesVisible()
    {
        var vm = new NotificationBannerViewModel(delay: (_, _) => new TaskCompletionSource().Task); // never completes — no auto-dismiss race in this test.
        var id = Guid.NewGuid();

        vm.Show(id, "Customer call", "In 15 minutes · 2:00 PM");

        Assert.True(vm.IsVisible);
        Assert.Equal(id, vm.RecordId);
        Assert.Equal("Customer call", vm.Title);
        Assert.Equal("In 15 minutes · 2:00 PM", vm.Timing);
    }

    [Fact]
    public void Dismiss_HidesTheBanner_AndIsIdempotent()
    {
        var vm = new NotificationBannerViewModel(delay: (_, _) => new TaskCompletionSource().Task);
        vm.Show(Guid.NewGuid(), "t", "when");

        vm.Dismiss();
        Assert.False(vm.IsVisible);

        vm.Dismiss(); // must not throw a second time.
        Assert.False(vm.IsVisible);
    }

    [Fact]
    public void DoneCommand_DismissesTheBanner_AndRaisesDoneWithTheRecordId()
    {
        var vm = new NotificationBannerViewModel(delay: (_, _) => new TaskCompletionSource().Task);
        var id = Guid.NewGuid();
        vm.Show(id, "t", "when");
        Guid? raised = null;
        vm.Done += recordId => raised = recordId;

        vm.DoneCommand.Execute(null);

        Assert.False(vm.IsVisible);
        Assert.Equal(id, raised);
    }

    [Fact]
    public void SnoozeCommand_DismissesTheBanner_AndRaisesSnoozedWithTheRecordId()
    {
        var vm = new NotificationBannerViewModel(delay: (_, _) => new TaskCompletionSource().Task);
        var id = Guid.NewGuid();
        vm.Show(id, "t", "when");
        Guid? raised = null;
        vm.Snoozed += recordId => raised = recordId;

        vm.SnoozeCommand.Execute(null);

        Assert.False(vm.IsVisible);
        Assert.Equal(id, raised);
    }

    [Fact]
    public void RescheduleCommand_DismissesTheBanner_AndRaisesRescheduledWithTheRecordId()
    {
        var vm = new NotificationBannerViewModel(delay: (_, _) => new TaskCompletionSource().Task);
        var id = Guid.NewGuid();
        vm.Show(id, "t", "when");
        Guid? raised = null;
        vm.Rescheduled += recordId => raised = recordId;

        vm.RescheduleCommand.Execute(null);

        Assert.False(vm.IsVisible);
        Assert.Equal(id, raised);
    }

    [Fact]
    public void Show_ReArmsAutoDismiss_ANewBannerIdCancelsTheOldTimer()
    {
        // The key assertion is simply that a second Show() doesn't leave two competing dismiss
        // timers racing — each Show() arms a fresh delay call, and the FIRST one's token must have
        // been cancelled by the second Show() (asserted via the registered callback below).
        var callCount = 0;
        var firstTokenWasCancelled = false;
        var isFirstCall = true;
        var vm = new NotificationBannerViewModel(delay: (_, ct) =>
        {
            callCount++;
            if (isFirstCall)
            {
                isFirstCall = false;
                ct.Register(() => firstTokenWasCancelled = true);
            }
            var tcs = new TaskCompletionSource();
            ct.Register(() => tcs.TrySetCanceled());
            return tcs.Task;
        });

        vm.Show(Guid.NewGuid(), "first", "when");
        vm.Show(Guid.NewGuid(), "second", "when"); // re-arms — the first delay's token must be cancelled.

        Assert.Equal(2, callCount);
        Assert.True(firstTokenWasCancelled);
        Assert.True(vm.IsVisible);
        Assert.Equal("second", vm.Title);
    }

    [Fact]
    public void AutoDismiss_FiresAfterTheDelayElapses_ForTheSameBanner()
    {
        var vm = new NotificationBannerViewModel(delay: (_, _) => Task.CompletedTask); // already-elapsed fake delay.
        var id = Guid.NewGuid();

        vm.Show(id, "t", "when");

        SpinWaitUntil(() => !vm.IsVisible, TimeSpan.FromSeconds(5));
        Assert.False(vm.IsVisible);
    }

    private static void SpinWaitUntil(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (!condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException("Condition was not met within the timeout.");
            }
            Thread.Sleep(5);
        }
    }
}
