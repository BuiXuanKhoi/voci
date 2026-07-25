// Services/Adapters/FileDelegationMetaStore.cs — durable IDelegationMetaStore, replacing
// Volar.Orchestrator.InMemoryDelegationMetaStore (which loses AI-handoff scheduling state — check-
// back time, backoff stage, cwd hint — every restart). Mirrors Swift's real default
// (`UserDefaults.standard`-backed `DelegationMetaStore`): plain JSON file under
// `%LocalAppData%\Volar\`, same "load once, rewrite the whole file atomically on every write,
// corrupt/missing file starts empty, never throws" contract as
// `Volar.Data.JsonFileSettingsStore` (this file deliberately reproduces that contract rather than
// inventing a new one — see that file's own doc comment for the reasoning).
//
// Lives in Volar.App (not Volar.Data) because Volar.Orchestrator's IDelegationMetaStore seam
// exists specifically so Volar.Orchestrator never needs a Volar.Data reference (see that
// interface's header) — the App-shell layer is exactly where this wiring is supposed to happen.
using System.Text.Json;
using Volar.Domain;
using Volar.Orchestrator;

namespace Volar.App.Services.Adapters;

public sealed class FileDelegationMetaStore : IDelegationMetaStore
{
    private readonly object _gate = new();
    private readonly string _filePath;
    private readonly Dictionary<Guid, DelegationMeta> _entries;

    public FileDelegationMetaStore(string filePath)
    {
        _filePath = filePath ?? throw new ArgumentNullException(nameof(filePath));
        _entries = Load(_filePath);
    }

    /// <summary>Default path: <c>%LocalAppData%\Volar\delegation-meta.json</c> — sibling of
    /// <see cref="Volar.Data.JsonFileSettingsStore.GetDefaultSettingsPath"/>'s
    /// <c>settings.json</c> and <see cref="Volar.Data.VolarDbPaths"/>'s database file, same
    /// folder-computation convention (caller decides when/whether to use it; this method performs
    /// no I/O itself).</summary>
    public static string GetDefaultPath(string fileName = "delegation-meta.json")
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(root, "Volar", fileName);
    }

    public DelegationMeta? Get(Guid taskId)
    {
        lock (_gate)
        {
            return _entries.TryGetValue(taskId, out var meta) ? meta : null;
        }
    }

    public void Set(Guid taskId, DelegationMeta meta)
    {
        lock (_gate)
        {
            _entries[taskId] = meta;
            Save();
        }
    }

    public void Remove(Guid taskId)
    {
        lock (_gate)
        {
            if (_entries.Remove(taskId))
            {
                Save();
            }
        }
    }

    public IReadOnlyDictionary<Guid, DelegationMeta> All()
    {
        lock (_gate)
        {
            return new Dictionary<Guid, DelegationMeta>(_entries);
        }
    }

    public void PruneKeys(IReadOnlySet<Guid> liveIds)
    {
        lock (_gate)
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
            Save();
        }
    }

    // MARK: - Load (never throws) -----------------------------------------------------------------

    private static Dictionary<Guid, DelegationMeta> Load(string filePath)
    {
        try
        {
            if (!File.Exists(filePath))
            {
                return new Dictionary<Guid, DelegationMeta>();
            }
            var text = File.ReadAllText(filePath);
            var dtoMap = JsonSerializer.Deserialize<Dictionary<string, DelegationMetaDto>>(text);
            if (dtoMap is null)
            {
                return new Dictionary<Guid, DelegationMeta>();
            }
            var result = new Dictionary<Guid, DelegationMeta>();
            foreach (var (key, dto) in dtoMap)
            {
                if (Guid.TryParse(key, out var id) && dto.ToDelegationMeta() is DelegationMeta meta)
                {
                    result[id] = meta;
                }
                // A single malformed entry is dropped, not fatal to the whole file — matches this
                // store's "corrupt input never crashes a read path" contract.
            }
            return result;
        }
        catch
        {
            // Corrupt/unreadable file (malformed JSON, I/O error, access denied, ...) -> start
            // empty. Never throw out of the constructor — mirrors JsonFileSettingsStore.Load.
            return new Dictionary<Guid, DelegationMeta>();
        }
    }

    // MARK: - Save (best-effort, atomic, never throws) ---------------------------------------------

    private void Save()
    {
        try
        {
            var directory = Path.GetDirectoryName(_filePath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var dtoMap = _entries.ToDictionary(
                kv => kv.Key.ToString(),
                kv => DelegationMetaDto.FromDelegationMeta(kv.Value));

            var json = JsonSerializer.Serialize(dtoMap);
            var tempPath = _filePath + ".tmp-" + Guid.NewGuid().ToString("N");
            File.WriteAllText(tempPath, json);
            File.Move(tempPath, _filePath, overwrite: true);
        }
        catch
        {
            // Best-effort persistence — never throw into a Set/Remove/PruneKeys caller. Worst case:
            // this particular write is lost, but the in-memory value already set stands for the
            // rest of this process's lifetime (mirrors JsonFileSettingsStore.Save's contract).
        }
    }

    /// <summary>Plain serializable DTO — avoids depending on <see cref="DelegationMeta"/> (a
    /// <see langword="readonly record struct"/>) round-tripping cleanly through
    /// <see cref="JsonSerializer"/>'s constructor-matching rules across framework versions; this
    /// mapping is explicit and stable regardless.</summary>
    private sealed class DelegationMetaDto
    {
        /// <summary>Nullable despite <see cref="DelegationMeta.Label"/> being non-null: a hostile or
        /// truncated JSON file can legally deserialize a JSON <c>null</c> into this property
        /// regardless of the C# nullable-reference annotation (System.Text.Json does not enforce
        /// nullable-reference attributes at runtime) — <see cref="ToDelegationMeta"/>'s null check
        /// below is reachable, not dead code.</summary>
        public string? Label { get; set; }
        public DateTimeOffset CheckBackAt { get; set; }
        public int BackoffStage { get; set; }
        public string? CwdHint { get; set; }
        public DateTimeOffset DelegatedAt { get; set; }

        public static DelegationMetaDto FromDelegationMeta(DelegationMeta meta) => new()
        {
            Label = meta.Label,
            CheckBackAt = meta.CheckBackAt,
            BackoffStage = meta.BackoffStage,
            CwdHint = meta.CwdHint,
            DelegatedAt = meta.DelegatedAt,
        };

        public DelegationMeta? ToDelegationMeta()
        {
            if (Label is null)
            {
                return null;
            }
            return new DelegationMeta(Label, CheckBackAt, BackoffStage, CwdHint, DelegatedAt);
        }
    }
}
