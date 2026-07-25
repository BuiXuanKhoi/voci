namespace Volar.Reminders.Tests;

/// <summary>
/// In-memory <see cref="IToastChannel"/> fake for verifying <see cref="ReminderScheduler"/>'s
/// delivery plumbing without any real Windows toast/speech adapter (which is Wave 3's job — see
/// <c>IToastChannel</c>'s class doc comment). Records everything the scheduler sends through the
/// seam so tests can assert on exact banner/category/spoken-text content, not just "something
/// happened."
/// </summary>
internal sealed class FakeToastChannel : IToastChannel
{
    public List<ReminderDelivery> Delivered { get; } = new();

    public List<(ReminderDelivery Delivery, DateTimeOffset FireAt)> Scheduled { get; } = new();

    public List<string> Spoken { get; } = new();

    private readonly HashSet<Guid> _pendingIds = new();
    private readonly HashSet<Guid> _deliveredIds = new();

    public void DeliverNow(ReminderDelivery delivery)
    {
        Delivered.Add(delivery);
        _deliveredIds.Add(delivery.RecordId);
        _pendingIds.Remove(delivery.RecordId);
        if (delivery.SpokenText is not null)
        {
            Spoken.Add(delivery.SpokenText);
        }
    }

    public void Schedule(ReminderDelivery delivery, DateTimeOffset fireAt)
    {
        Scheduled.Add((delivery, fireAt));
        _pendingIds.Add(delivery.RecordId);
    }

    public void Speak(string text) => Spoken.Add(text);

    public void CancelPending(IReadOnlyList<Guid> recordIds)
    {
        foreach (var id in recordIds)
        {
            _pendingIds.Remove(id);
        }
    }

    public IReadOnlyList<Guid> GetPendingIds() => _pendingIds.ToList();

    public IReadOnlyList<Guid> GetDeliveredIds() => _deliveredIds.ToList();

    /// <summary>Test helper (FIX B scenario): simulate the OS having already shown a notification
    /// the scheduler doesn't yet know about — e.g. delivered while the app process was dead.</summary>
    public void SimulateAlreadyDelivered(Guid recordId) => _deliveredIds.Add(recordId);
}
