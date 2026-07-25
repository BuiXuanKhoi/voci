// AppNotificationToastChannelTests.cs — exercises AppNotificationToastChannel entirely against
// FakeNativeGateway (see AdapterTestSupport.cs); no test in this file ever touches the real
// Microsoft.Windows.AppNotifications stack or posts a real toast on the machine running the suite.
// A real Volar.Speech.Playback.VoicePlayback is used for the spoken half (cheap, local SAPI5,
// already covered by its own tests elsewhere) — these tests only assert it never throws through
// this channel's wrapping, not on what it actually speaks.
using Volar.App.Services.Adapters;
using Volar.Reminders;
using Volar.Speech.Playback;
using Xunit;

namespace Volar.App.Tests.Adapters;

public sealed class AppNotificationToastChannelTests : IDisposable
{
    private readonly VoicePlayback _voice = new();
    private readonly List<AppNotificationToastChannel> _channels = [];

    private AppNotificationToastChannel CreateChannel(FakeNativeGateway gateway)
    {
        var channel = new AppNotificationToastChannel(_voice, gateway);
        _channels.Add(channel);
        return channel;
    }

    private static ReminderDelivery Delivery(
        Guid? recordId = null,
        string category = ReminderCategory.Deadline,
        string? spokenText = null) => new(
            RecordId: recordId ?? Guid.NewGuid(),
            TaskId: Guid.NewGuid(),
            BannerTitle: "Volar",
            BannerBody: "Pay rent — due today",
            CategoryId: category,
            SpokenText: spokenText);

    private static void WaitUntil(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (!condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                Assert.Fail("Condition was not met within the timeout.");
            }
            Thread.Sleep(10);
        }
    }

    // MARK: - DeliverNow / degrade contract

    [Fact]
    public void DeliverNow_ShowsThroughTheGateway_WithMatchingTitleAndBody()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);
        var delivery = Delivery();

        channel.DeliverNow(delivery);

        var call = Assert.Single(gateway.ShowCalls);
        Assert.Equal(delivery.RecordId, call.RecordId);
        Assert.Equal(delivery.BannerTitle, call.Title);
        Assert.Equal(delivery.BannerBody, call.Body);
    }

    [Theory]
    [InlineData(ReminderCategory.Deadline, 3)]
    [InlineData(ReminderCategory.OverdueReschedule, 3)]
    [InlineData(ReminderCategory.UnblockedReady, 0)]
    public void DeliverNow_MapsCategoryToTheContractDeclaredButtonSet(string category, int expectedButtonCount)
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);

        channel.DeliverNow(Delivery(category: category));

        Assert.Equal(expectedButtonCount, gateway.ShowCalls.Single().Buttons.Count);
    }

    [Fact]
    public void DeliverNow_DeadlineCategory_UsesTheThreeDocumentedActionIds()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);

        channel.DeliverNow(Delivery(category: ReminderCategory.Deadline));

        var actionIds = gateway.ShowCalls.Single().Buttons.Select(b => b.ActionId).ToList();
        Assert.Equal(new[] { ReminderAction.Done, ReminderAction.Snooze10, ReminderAction.Tomorrow }, actionIds);
    }

    [Fact]
    public void DeliverNow_OverdueRescheduleCategory_UsesTheThreeDocumentedActionIds()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);

        channel.DeliverNow(Delivery(category: ReminderCategory.OverdueReschedule));

        var actionIds = gateway.ShowCalls.Single().Buttons.Select(b => b.ActionId).ToList();
        Assert.Equal(
            new[] { ReminderAction.RescheduleTonight, ReminderAction.RescheduleTomorrow, ReminderAction.RescheduleWeekend },
            actionIds);
    }

    [Fact]
    public void DeliverNow_NeverThrows_WhenGatewayShowThrows()
    {
        var gateway = new FakeNativeGateway { ThrowOnShow = true };
        var channel = CreateChannel(gateway);

        channel.DeliverNow(Delivery()); // must not throw
    }

    [Fact]
    public void DeliverNow_DoesNotSpeak_WhenSpokenTextIsNull()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);

        channel.DeliverNow(Delivery(spokenText: null)); // must not throw regardless
    }

    [Fact]
    public void DeliverNow_SpeaksWithoutThrowing_WhenSpokenTextIsSet()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);

        channel.DeliverNow(Delivery(spokenText: "Pay rent is due today.")); // must not throw
    }

    [Fact]
    public void Constructor_NeverThrows_WhenGatewayRegisterThrows()
    {
        var gateway = new FakeNativeGateway { ThrowOnRegister = true };

        var channel = CreateChannel(gateway); // must not throw

        // Still usable afterward — degrade quietly, not a dead object.
        channel.DeliverNow(Delivery());
        Assert.Single(gateway.ShowCalls);
    }

    // MARK: - Speak

    [Fact]
    public void Speak_NeverThrows()
    {
        var channel = CreateChannel(new FakeNativeGateway());

        channel.Speak("Done. All clear.");
    }

    // MARK: - GetDeliveredIds (FIX B reconciliation)

    [Fact]
    public void GetDeliveredIds_ReflectsWhatTheGatewayReportsAsStillDelivered()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);
        var delivery = Delivery();
        channel.DeliverNow(delivery);

        var delivered = channel.GetDeliveredIds();

        Assert.Contains(delivery.RecordId, delivered);
    }

    [Fact]
    public void GetDeliveredIds_DegradesToEmpty_WhenGatewayThrows()
    {
        var gateway = new FakeNativeGateway { ThrowOnGetDeliveredIds = true };
        var channel = CreateChannel(gateway);

        var delivered = channel.GetDeliveredIds();

        Assert.Empty(delivered);
    }

    // MARK: - CancelPending / GetPendingIds

    [Fact]
    public void CancelPending_UnknownId_NeverThrows_AndStillAsksGatewayToRemoveByTag()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);
        var id = Guid.NewGuid();

        channel.CancelPending(new[] { id });

        Assert.Contains(id, gateway.RemoveByTagCalls);
    }

    [Fact]
    public void CancelPending_NeverThrows_WhenGatewayRemoveByTagThrows()
    {
        var gateway = new FakeNativeGateway { ThrowOnRemoveByTag = true };
        var channel = CreateChannel(gateway);

        channel.CancelPending(new[] { Guid.NewGuid() }); // must not throw
    }

    [Fact]
    public void GetPendingIds_EmptyInitially()
    {
        var channel = CreateChannel(new FakeNativeGateway());

        Assert.Empty(channel.GetPendingIds());
    }

    // MARK: - Schedule (immediate vs. future)

    [Fact]
    public void Schedule_FireAtInThePast_DeliversImmediately_AndIsNotPending()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);
        var delivery = Delivery();

        channel.Schedule(delivery, DateTimeOffset.UtcNow.AddSeconds(-1));

        Assert.Single(gateway.ShowCalls);
        Assert.DoesNotContain(delivery.RecordId, channel.GetPendingIds());
    }

    [Fact]
    public void Schedule_FutureFireAt_IsPending_AndNotYetDelivered()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);
        var delivery = Delivery();

        channel.Schedule(delivery, DateTimeOffset.UtcNow.AddSeconds(30));

        Assert.Contains(delivery.RecordId, channel.GetPendingIds());
        Assert.Empty(gateway.ShowCalls);
    }

    [Fact]
    public void Schedule_FutureFireAt_EventuallyDelivers_AndClearsFromPending()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);
        var delivery = Delivery();

        channel.Schedule(delivery, DateTimeOffset.UtcNow.AddMilliseconds(150));

        WaitUntil(() => gateway.ShowCalls.Count > 0, TimeSpan.FromSeconds(5));
        Assert.Single(gateway.ShowCalls);
        Assert.DoesNotContain(delivery.RecordId, channel.GetPendingIds());
    }

    [Fact]
    public void Schedule_ThenCancelBeforeFiring_NeverDelivers()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);
        var delivery = Delivery();
        channel.Schedule(delivery, DateTimeOffset.UtcNow.AddSeconds(5));

        channel.CancelPending(new[] { delivery.RecordId });

        Assert.DoesNotContain(delivery.RecordId, channel.GetPendingIds());
        Assert.Contains(delivery.RecordId, gateway.RemoveByTagCalls);
        // Give any errant background continuation a moment to (incorrectly) fire, then assert it didn't.
        Thread.Sleep(120);
        Assert.Empty(gateway.ShowCalls);
    }

    [Fact]
    public void Schedule_CalledTwiceForTheSameRecord_CancelsTheFirstPendingTimer()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);
        var id = Guid.NewGuid();

        channel.Schedule(Delivery(id), DateTimeOffset.UtcNow.AddSeconds(5));
        channel.Schedule(Delivery(id), DateTimeOffset.UtcNow.AddMilliseconds(100));

        WaitUntil(() => gateway.ShowCalls.Count > 0, TimeSpan.FromSeconds(5));
        // Exactly one delivery — the stale 5-second timer must not ALSO fire later for the same id.
        Assert.Single(gateway.ShowCalls);
    }

    // MARK: - ActionInvoked routing

    [Fact]
    public void ActionInvoked_FiresWhenTheGatewayReportsAnInvocation()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);
        string? seenAction = null;
        Guid? seenRecordId = null;
        channel.ActionInvoked += (action, recordId) =>
        {
            seenAction = action;
            seenRecordId = recordId;
        };
        var recordId = Guid.NewGuid();

        gateway.RaiseInvoked(ReminderAction.Snooze10, recordId);

        Assert.Equal(ReminderAction.Snooze10, seenAction);
        Assert.Equal(recordId, seenRecordId);
    }

    [Fact]
    public void ActionInvoked_SubscriberThrowing_NeverPropagatesOutOfTheGatewayCallback()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);
        channel.ActionInvoked += (_, _) => throw new InvalidOperationException("subscriber bug");

        gateway.RaiseInvoked(ReminderAction.Done, Guid.NewGuid()); // must not throw
    }

    // MARK: - Dispose

    [Fact]
    public void Dispose_CancelsOutstandingPendingTimers()
    {
        var gateway = new FakeNativeGateway();
        var channel = CreateChannel(gateway);
        var delivery = Delivery();
        channel.Schedule(delivery, DateTimeOffset.UtcNow.AddSeconds(5));

        channel.Dispose();
        Thread.Sleep(50);

        Assert.Empty(gateway.ShowCalls);
    }

    public void Dispose()
    {
        foreach (var channel in _channels)
        {
            channel.Dispose();
        }
        _voice.Dispose();
    }
}
