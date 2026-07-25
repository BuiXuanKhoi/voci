// ReminderRecordRepository.cs — Wave 3-B (A2): the real, SQLite-backed
// Volar.Reminders.IReminderRecordStore implementation over
// Volar.Data.Entities.ReminderRecordEntity (which already existed from Wave 1 — this is the first
// thing that actually writes to it). Named `ReminderRecordRepository`, not `EfReminderRecordStore`,
// for consistency with TaskRepository/CompletionEventRepository in this same project.
//
// SYNC BY DESIGN: IReminderRecordStore's contract (LoadAll/Upsert/Delete/UpsertRange — no
// `Async`/`Task<>`) is synchronous, matching ReminderScheduler's own pure/synchronous public
// surface (constitution IV — see ReminderScheduler.cs's header: no async, no I/O in the LOGIC layer
// itself; this class is the one sanctioned persistence exception, called through the scheduler's
// write-through helpers). It therefore uses EF Core's synchronous APIs (`SaveChanges`, `ToList`,
// `FirstOrDefault`) rather than this project's usual `...Async` convention — same
// "fresh, short-lived DbContext per call via IDbContextFactory<VolarDbContext>" lifecycle
// TaskRepository documents, just without the suspension points.
//
// FK NOTE: VolarDbContext.OnModelCreating already configures ReminderRecordEntity.TaskId as a
// cascade-delete FK to TaskEntity (Wave 1's own design decision, flagged there for confirmation —
// this wave confirms it: a reminder for a deleted task is meaningless, and ReminderScheduler itself
// never manages that lifecycle). SQLite enforces this FK by default under the Sqlite EF Core
// provider, so Upsert/UpsertRange for a record whose TaskId has no matching row will throw — exactly
// the behavior a real caller wants (a reminder can only ever be derived from a task that already
// exists; see ReminderRecord.Derive's callers, all of which read the task first).
using Microsoft.EntityFrameworkCore;
using Volar.Data.Entities;
using Volar.Reminders;

namespace Volar.Data;

public sealed class ReminderRecordRepository(IDbContextFactory<VolarDbContext> contextFactory) : IReminderRecordStore
{
    private readonly IDbContextFactory<VolarDbContext> _contextFactory = contextFactory;

    /// <summary>Port of the read half of SwiftData's `fetchAllRecords()`. Read-only — no tracking,
    /// since the caller (<see cref="ReminderScheduler.Rehydrate"/>) only ever copies the result into
    /// its own in-memory cache.</summary>
    public IReadOnlyList<ReminderRecord> LoadAll()
    {
        using var context = _contextFactory.CreateDbContext();
        return context.ReminderRecords
            .AsNoTracking()
            .ToList()
            .Select(ToDomain)
            .ToList();
    }

    public void Upsert(ReminderRecord record)
    {
        using var context = _contextFactory.CreateDbContext();
        var existing = context.ReminderRecords.FirstOrDefault(r => r.Id == record.Id);
        if (existing is null)
        {
            context.ReminderRecords.Add(ToEntity(record));
        }
        else
        {
            ApplyTo(existing, record);
        }
        context.SaveChanges();
    }

    public void Delete(Guid id)
    {
        using var context = _contextFactory.CreateDbContext();
        var existing = context.ReminderRecords.FirstOrDefault(r => r.Id == id);
        if (existing is null)
        {
            return; // matches every other "not found -> no-op" convention in this subsystem.
        }
        context.ReminderRecords.Remove(existing);
        context.SaveChanges();
    }

    /// <summary>
    /// Batched upsert in a single DbContext/SaveChanges — the path
    /// <see cref="ReminderScheduler"/> uses for a task's whole newly-derived reminder set (always
    /// the global policy's offset count, 3 today, at once), so this is the call that would otherwise
    /// cost N round-trips without the batching.
    /// </summary>
    public void UpsertRange(IEnumerable<ReminderRecord> records)
    {
        var list = records as IReadOnlyCollection<ReminderRecord> ?? records.ToList();
        if (list.Count == 0)
        {
            return;
        }
        using var context = _contextFactory.CreateDbContext();
        var ids = list.Select(r => r.Id).ToHashSet();
        var existingRows = context.ReminderRecords
            .Where(r => ids.Contains(r.Id))
            .ToDictionary(r => r.Id);
        foreach (var record in list)
        {
            if (existingRows.TryGetValue(record.Id, out var existing))
            {
                ApplyTo(existing, record);
            }
            else
            {
                context.ReminderRecords.Add(ToEntity(record));
            }
        }
        context.SaveChanges();
    }

    private static ReminderRecordEntity ToEntity(ReminderRecord record) => new()
    {
        Id = record.Id,
        TaskId = record.TaskId,
        FireAt = record.FireAt,
        OffsetKind = record.OffsetKind,
        State = record.State,
        IsHighUrgency = record.IsHighUrgency,
    };

    private static void ApplyTo(ReminderRecordEntity entity, ReminderRecord record)
    {
        entity.TaskId = record.TaskId;
        entity.FireAt = record.FireAt;
        entity.OffsetKind = record.OffsetKind;
        entity.State = record.State;
        entity.IsHighUrgency = record.IsHighUrgency;
    }

    private static ReminderRecord ToDomain(ReminderRecordEntity entity) => new(
        taskId: entity.TaskId,
        fireAt: entity.FireAt,
        offsetKind: entity.OffsetKind,
        id: entity.Id,
        state: entity.State,
        isHighUrgency: entity.IsHighUrgency);
}
