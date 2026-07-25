// IReminderRecordStore.cs — Wave 3-B (A2) persistence seam for ReminderScheduler.cs's
// `_records` heap. Closes the gap documented (pre-this-wave) on ReminderScheduler.cs's header:
// the Swift original gets durability "for free" from its own SwiftData `ModelContainer`/
// `ModelContext` (a fresh `ModelContext` fetch on `init` already sees prior rows — see
// `Volar/Sources/Reminders/ReminderScheduler.swift`'s own header + `makeContext()`); this port kept
// `_records` as a plain in-memory `List` with nothing behind it, so every reminder was lost on
// process restart. This interface — plus `ReminderScheduler`'s new write-through calls and
// `Rehydrate()` step — is the fix.
//
// LIVES IN Volar.Reminders (not Volar.Data): keeps this project's declared dependency-free-of-
// infrastructure stance intact (layering rule: Volar.Reminders -> Core + Domain only, never EF
// Core/SQLite directly). `Volar.Data.ReminderRecordRepository` is the real, SQLite-backed
// implementation (see that file); `InMemoryReminderRecordStore` below is the zero-dependency
// default so every existing caller — all 30 pre-Wave-3-B Reminders tests, and
// `Volar.App.Services.CompositionRoot`'s current `new ReminderScheduler(...)` call, which does not
// yet pass a `recordStore` argument — keeps compiling and behaving exactly as before until Wave
// 3-C wires the real one in.
namespace Volar.Reminders;

/// <summary>
/// Durable storage seam for <see cref="ReminderRecord"/> rows. Narrows SwiftData's
/// <c>ModelContext</c> surface (<c>fetchAllRecords()</c> / <c>context.insert</c> /
/// <c>context.delete</c> / <c>save()</c>) down to exactly what <see cref="ReminderScheduler"/>
/// needs. Every method is synchronous, deliberately: it mirrors the scheduler's own
/// pure/synchronous public contract (see that class's header — the original brief was "no async,
/// no I/O" for the LOGIC; this is the one sanctioned persistence exception, and it stays
/// synchronous rather than forcing the whole scheduler async just to save a row). An
/// implementation backed by a real database (see <see cref="Volar.Data.ReminderRecordRepository"/
/// > — referenced only in that file's own doc comment, not from here, to keep this project
/// EF-Core-free) is expected to open-and-dispose its own short-lived connection/context per call,
/// same "one unit of work per call" discipline <c>Volar.Data.TaskRepository</c> already documents.
/// </summary>
public interface IReminderRecordStore
{
    /// <summary>
    /// Every persisted record, any state. <see cref="ReminderScheduler"/> calls this exactly once
    /// per instance lifetime, from its constructor (<see cref="ReminderScheduler.Rehydrate"/>), to
    /// rebuild the in-memory cache after a restart — the direct fix for the bug this seam exists
    /// to close.
    /// </summary>
    IReadOnlyList<ReminderRecord> LoadAll();

    /// <summary>Insert-or-replace by <see cref="ReminderRecord.Id"/>.</summary>
    void Upsert(ReminderRecord record);

    /// <summary>No-op if <paramref name="id"/> doesn't exist — matches every other
    /// "not found -&gt; no-op" convention in this subsystem.</summary>
    void Delete(Guid id);

    /// <summary>
    /// Batched <see cref="Upsert"/>. An implementation SHOULD do this as a single
    /// transaction/<c>SaveChanges</c> rather than one round-trip per record (this is the path
    /// <see cref="ReminderScheduler"/> uses for a task's whole newly-derived reminder set, which is
    /// always the global policy's offset count — 3 today — at once).
    /// </summary>
    void UpsertRange(IEnumerable<ReminderRecord> records);
}

/// <summary>
/// Default, dependency-free implementation: a plain in-memory dictionary that forgets everything on
/// process exit — i.e. exactly the behavior <see cref="ReminderScheduler"/> had before this seam
/// existed. This is the constructor default (see <see cref="ReminderScheduler"/>'s constructor) so
/// every pre-existing caller keeps compiling and behaving unchanged; Wave 3-C's
/// <c>CompositionRoot</c> is expected to register <c>Volar.Data.ReminderRecordRepository</c> in its
/// place for the real app.
/// </summary>
public sealed class InMemoryReminderRecordStore : IReminderRecordStore
{
    private readonly Dictionary<Guid, ReminderRecord> _rows = new();

    public IReadOnlyList<ReminderRecord> LoadAll() => _rows.Values.ToList();

    public void Upsert(ReminderRecord record) => _rows[record.Id] = record;

    public void Delete(Guid id) => _rows.Remove(id);

    public void UpsertRange(IEnumerable<ReminderRecord> records)
    {
        foreach (var record in records)
        {
            _rows[record.Id] = record;
        }
    }
}
