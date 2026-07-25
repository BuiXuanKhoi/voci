// IDelegationMetaStore.cs — persistence seam for DelegationTracker's scheduling metadata.
//
// Swift's `DelegationTracker.swift` persists `DelegationMeta` (checkBackAt/backoffStage/cwdHint/
// label/delegatedAt) itself, in a private `DelegationMetaStore` nested class backed by
// `UserDefaults` — chosen there because `TaskStore`'s public surface has no write path for
// `VolarTask.delegation` on an EXISTING task (see that file's header comment). `UserDefaults` has
// no Windows equivalent and is I/O this pure/testable project must not perform directly (per this
// project's dependency rules: external I/O stays behind an interface). This interface is that
// seam: Wave 3 (App shell) is expected to implement it against a local settings file or the
// registry, mirroring how `Volar.Reminders/IReminderSettingsProvider.cs` defers its own
// UserDefaults-shaped seam the same way.
using Volar.Domain;

namespace Volar.Orchestrator;

/// <summary>
/// Keyed persistence for one <see cref="DelegationMeta"/> per delegated task id. Every member here
/// mirrors one operation of Swift's private `DelegationMetaStore` (`get`/`set`/`remove`/`all`/
/// `pruneKeys`) so `DelegationTracker`'s logic ports 1:1 against it.
/// </summary>
public interface IDelegationMetaStore
{
    DelegationMeta? Get(Guid taskId);

    void Set(Guid taskId, DelegationMeta meta);

    void Remove(Guid taskId);

    /// <summary>All persisted entries. Order is not significant — callers sort as needed.</summary>
    IReadOnlyDictionary<Guid, DelegationMeta> All();

    /// <summary>
    /// Drops every entry whose key is not in <paramref name="liveIds"/> (mirrors Swift's
    /// `pruneKeys(notIn:)`).
    /// </summary>
    void PruneKeys(IReadOnlySet<Guid> liveIds);
}

/// <summary>
/// In-memory default — deliberately NOT durable across process restarts. Swift's real default
/// (`UserDefaults.standard`) IS durable; this stand-in exists purely so
/// <see cref="DelegationTracker"/> has a working default constructor for tests and for any caller
/// that hasn't wired a real store yet, mirroring <c>Volar.Reminders.DefaultReminderSettingsProvider</c>'s
/// same "usable default, real persistence deferred" role. Wave 3 must supply a durable
/// implementation (local settings file / registry) before this ships — flagged in this task's
/// final report, not a silent gap.
/// </summary>
public sealed class InMemoryDelegationMetaStore : IDelegationMetaStore
{
    private readonly Dictionary<Guid, DelegationMeta> _entries = new();

    public DelegationMeta? Get(Guid taskId) => _entries.TryGetValue(taskId, out var meta) ? meta : null;

    public void Set(Guid taskId, DelegationMeta meta) => _entries[taskId] = meta;

    public void Remove(Guid taskId) => _entries.Remove(taskId);

    public IReadOnlyDictionary<Guid, DelegationMeta> All() => new Dictionary<Guid, DelegationMeta>(_entries);

    public void PruneKeys(IReadOnlySet<Guid> liveIds)
    {
        List<Guid>? stale = null;
        foreach (var key in _entries.Keys)
        {
            if (!liveIds.Contains(key))
            {
                (stale ??= new List<Guid>()).Add(key);
            }
        }
        if (stale is null)
        {
            return;
        }
        foreach (var key in stale)
        {
            _entries.Remove(key);
        }
    }
}
