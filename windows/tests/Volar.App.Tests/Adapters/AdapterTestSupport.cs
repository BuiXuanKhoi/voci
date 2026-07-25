// AdapterTestSupport.cs — small shared test double for AppNotificationToastChannelTests, kept in
// this folder (not State/) per the wave-wide "file-disjoint per agent" rule.
using Volar.App.Services.Adapters;

namespace Volar.App.Tests.Adapters;

/// <summary>Fully in-memory stand-in for <see cref="INativeAppNotificationGateway"/> — no real
/// Microsoft.Windows.AppNotifications call is ever made by this fake, so
/// <see cref="AppNotificationToastChannelTests"/> never posts a real toast to the machine running
/// the test suite.</summary>
internal sealed class FakeNativeGateway : INativeAppNotificationGateway
{
    public bool RegisterResult { get; set; } = true;
    public bool ThrowOnRegister { get; set; }
    public bool ThrowOnShow { get; set; }
    public bool ThrowOnGetDeliveredIds { get; set; }
    public bool ThrowOnRemoveByTag { get; set; }
    public bool Disposed { get; private set; }

    public List<(Guid RecordId, string Title, string Body, IReadOnlyList<ToastButtonSpec> Buttons)> ShowCalls { get; } = [];
    public List<Guid> RemoveByTagCalls { get; } = [];
    public HashSet<Guid> DeliveredIds { get; } = [];

    public event Action<string, Guid>? Invoked;

    public bool Register()
    {
        if (ThrowOnRegister)
        {
            throw new InvalidOperationException("simulated Register() failure");
        }
        return RegisterResult;
    }

    public void Show(Guid recordId, string title, string body, IReadOnlyList<ToastButtonSpec> buttons)
    {
        if (ThrowOnShow)
        {
            throw new InvalidOperationException("simulated Show() failure");
        }
        ShowCalls.Add((recordId, title, body, buttons));
        DeliveredIds.Add(recordId);
    }

    public IReadOnlyList<Guid> GetDeliveredIds()
    {
        if (ThrowOnGetDeliveredIds)
        {
            throw new InvalidOperationException("simulated GetDeliveredIds() failure");
        }
        return DeliveredIds.ToList();
    }

    public void RemoveByTag(Guid recordId)
    {
        if (ThrowOnRemoveByTag)
        {
            throw new InvalidOperationException("simulated RemoveByTag() failure");
        }
        RemoveByTagCalls.Add(recordId);
        DeliveredIds.Remove(recordId);
    }

    public void RaiseInvoked(string actionId, Guid recordId) => Invoked?.Invoke(actionId, recordId);

    public void Dispose() => Disposed = true;
}
