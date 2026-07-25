namespace Volar.Reminders.Tests;

/// <summary>
/// In-memory <see cref="IReminderRecordStore"/> fake for verifying <see cref="ReminderScheduler"/>'s
/// Wave-3-B write-through behavior (as opposed to <see cref="InMemoryReminderRecordStore"/>, the
/// production default, which this fake deliberately does NOT reuse).
/// </summary>
/// <remarks>
/// CLONE-ON-WRITE, NOT REFERENCE-SHARING: every stored row is a defensive copy, not the same
/// <see cref="ReminderRecord"/> instance the scheduler holds in its own `_records` cache. This
/// matters for what these tests can actually prove — if this fake stored the exact same mutable
/// object reference the scheduler mutates in place, a MISSING `PersistUpsert` call after a
/// `record.State = ...` assignment would be invisible to any assertion made through
/// <see cref="LoadAll"/> (the fake's copy would already reflect the mutation, since it would BE the
/// mutated object). Cloning on every <see cref="Upsert"/> means a test can only see a state change
/// here if the scheduler actually called <see cref="Upsert"/> (or <see cref="UpsertRange"/>) again
/// after mutating the record — i.e. this fake actually exercises the "write-through" contract
/// instead of trivially satisfying it via shared mutable state.
/// </remarks>
internal sealed class FakeReminderRecordStore : IReminderRecordStore
{
    private readonly Dictionary<Guid, ReminderRecord> _rows = new();

    public int UpsertCalls { get; private set; }

    public int UpsertRangeCalls { get; private set; }

    public int DeleteCalls { get; private set; }

    public IReadOnlyList<ReminderRecord> LoadAll() => _rows.Values.Select(Clone).ToList();

    public void Upsert(ReminderRecord record)
    {
        UpsertCalls++;
        _rows[record.Id] = Clone(record);
    }

    public void Delete(Guid id)
    {
        DeleteCalls++;
        _rows.Remove(id);
    }

    public void UpsertRange(IEnumerable<ReminderRecord> records)
    {
        UpsertRangeCalls++;
        foreach (var record in records)
        {
            _rows[record.Id] = Clone(record);
        }
    }

    /// <summary>Test-only helper: seeds a row directly, bypassing the call-count bookkeeping above
    /// — simulates "already durable from a previous process," i.e. the exact restart scenario this
    /// wave's <see cref="ReminderScheduler.Rehydrate"/> exists to fix.</summary>
    public void Seed(ReminderRecord record) => _rows[record.Id] = Clone(record);

    /// <summary>Direct read of the durable row for <paramref name="id"/>, bypassing the scheduler's
    /// own cache entirely — lets a test assert on exactly what's "on disk" versus what the
    /// scheduler currently thinks, which is the whole point of a write-through test.</summary>
    public ReminderRecord? Find(Guid id) => _rows.TryGetValue(id, out var record) ? Clone(record) : null;

    private static ReminderRecord Clone(ReminderRecord record) => new(
        taskId: record.TaskId,
        fireAt: record.FireAt,
        offsetKind: record.OffsetKind,
        id: record.Id,
        state: record.State,
        isHighUrgency: record.IsHighUrgency);
}

/// <summary>Test-only <see cref="IReminderRecordStore"/> that always throws — proves
/// <see cref="ReminderScheduler"/>'s write-through helpers log and swallow a persistence failure
/// instead of letting it escape into the caller (mirrors the Swift original's `save()` `catch {
/// print(...) }`, per this wave's fixed design).</summary>
internal sealed class ThrowingReminderRecordStore : IReminderRecordStore
{
    public IReadOnlyList<ReminderRecord> LoadAll() => throw new InvalidOperationException("load failed (test double)");

    public void Upsert(ReminderRecord record) => throw new InvalidOperationException("upsert failed (test double)");

    public void Delete(Guid id) => throw new InvalidOperationException("delete failed (test double)");

    public void UpsertRange(IEnumerable<ReminderRecord> records) => throw new InvalidOperationException("upsertRange failed (test double)");
}
