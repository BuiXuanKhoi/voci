// JsonFileSettingsStore.cs — disk-backed settings store, new in Wave 3-B (A3: Local<->Cloud
// switch for parse/speech, macOS commit f88d5e5). Plays the role `UserDefaults.standard` plays on
// macOS for this feature's keys (`volar.parseProxyBaseURL`, `volar.parseProxyToken`,
// `volar.cloudParseConsent`, `volar.groqToken`, ...): a plain, durable, process-external key/value
// store the rest of the app reads/writes through.
//
// LAYERING NOTE (read before wiring this into DI): this wave's rules pin Volar.Data's only project
// reference to Volar.Core ("Volar.Data -> Core", specs/003-windows-port/wave3b-parity.md). The
// seam this feature actually wants to inject is `Volar.Domain.ISettingsStore`
// (windows/src/Volar.Domain/ISettingsStore.cs) — but Volar.Domain is out of reach from here under
// that rule, and this file's owner is not permitted to edit Volar.Data.csproj to add the
// reference. So this class deliberately does NOT declare `: ISettingsStore` — it exposes the
// IDENTICAL method shapes (GetString/SetString/GetBool/SetBool) structurally, so adapting it is a
// one-line forwarding wrapper. **Wave 3-C must do one of:**
//   (a) add `<ProjectReference Include="..\Volar.Domain\Volar.Domain.csproj" />` to
//       Volar.Data.csproj and add `: ISettingsStore` to this class's declaration, or
//   (b) write a trivial `SettingsStoreAdapter : ISettingsStore` in Volar.App that forwards every
//       member to an injected `JsonFileSettingsStore` instance.
// Either is a few lines; neither changes any behavior in this file.
//
// Path convention mirrors `VolarDbPaths.GetDefaultDatabasePath` deliberately: same
// `%LocalAppData%\Volar\` folder, same "helper computes the path, caller decides when/whether to
// use it" contract (this class itself never reads Environment/AppData implicitly — the path is
// always an explicit constructor argument, exactly like `VolarDbContextFactory.ForFile(...)`).
using System.Text.Json.Nodes;
using Volar.Domain;

namespace Volar.Data;

/// <summary>
/// Real, file-backed settings store: <c>%LocalAppData%\Volar\settings.json</c> by convention (see
/// <see cref="GetDefaultSettingsPath"/>), though the path is always passed in explicitly.
/// </summary>
/// <remarks>
/// <para>
/// <b>Load:</b> read once at construction into an in-memory dictionary. A missing file starts
/// empty (first run). A corrupt/unreadable file (bad JSON, permission error, anything) ALSO starts
/// empty rather than throwing — per this feature's fixed contract, a settings problem must never
/// crash the app, only degrade to "as if nothing were configured yet" (which for every key this
/// feature defines is itself the safe, privacy-preserving default).
/// </para>
/// <para>
/// <b>Save:</b> every <see cref="SetString"/>/<see cref="SetBool"/> call rewrites the whole file
/// atomically — write the full JSON to a sibling temp file, then <see cref="File.Move(string,
/// string, bool)"/> with <c>overwrite: true</c> onto the real path. A crash or power loss between
/// those two steps leaves either the OLD file or the NEW file on disk, never a half-written one.
/// Persistence is best-effort: if the write itself fails (locked file, no permission, disk full),
/// the exception is swallowed and the in-memory value the caller just set stands for the rest of
/// this process's lifetime — mirrors `UserDefaults.set(...)`, which cannot fail from the caller's
/// perspective either.
/// </para>
/// <para>
/// <b>Thread-safety:</b> a single lock guards both the in-memory dictionary and the file write —
/// settings reads/writes are rare and cheap, so a single lock is not a contention concern.
/// </para>
/// <para>
/// <b>Security:</b> values are stored as plain JSON text, matching `UserDefaults`'s own
/// no-encryption-by-default behavior for this feature's placeholder credential keys
/// (`volar.parseProxyToken`, `volar.groqToken`) — this is an inherited property of the "code
/// first, key later" design (see `ConfigParseCredentialProvider`'s header comment), not a new
/// regression introduced by this port. Never logged: this file contains no logging calls at all.
/// </para>
/// </remarks>
public sealed class JsonFileSettingsStore : ISettingsStore
{
    private readonly object _gate = new();
    private readonly string _filePath;
    private readonly Dictionary<string, object?> _values;

    public JsonFileSettingsStore(string filePath)
    {
        _filePath = filePath ?? throw new ArgumentNullException(nameof(filePath));
        _values = Load(_filePath);
    }

    public string? GetString(string key)
    {
        lock (_gate)
        {
            return _values.TryGetValue(key, out var value) && value is string s ? s : null;
        }
    }

    public void SetString(string key, string? value)
    {
        lock (_gate)
        {
            if (value is null)
            {
                _values.Remove(key);
            }
            else
            {
                _values[key] = value;
            }
            Save();
        }
    }

    public bool GetBool(string key, bool defaultValue)
    {
        lock (_gate)
        {
            return _values.TryGetValue(key, out var value) && value is bool b ? b : defaultValue;
        }
    }

    public void SetBool(string key, bool value)
    {
        lock (_gate)
        {
            _values[key] = value;
            Save();
        }
    }

    /// <summary>
    /// The default settings file path: <c>%LocalAppData%\Volar\settings.json</c>. Does not create
    /// the directory or the file — <see cref="Save"/> creates the directory on first write, exactly
    /// as <c>VolarDbPaths.GetDefaultDatabasePath</c>'s callers are responsible for the database
    /// file's directory.
    /// </summary>
    public static string GetDefaultSettingsPath(string fileName = "settings.json")
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(root, "Volar", fileName);
    }

    // MARK: - Load (never throws)

    private static Dictionary<string, object?> Load(string filePath)
    {
        var result = new Dictionary<string, object?>();
        try
        {
            if (!File.Exists(filePath))
            {
                return result;
            }
            var text = File.ReadAllText(filePath);
            if (JsonNode.Parse(text) is not JsonObject obj)
            {
                // Valid JSON but not an object (e.g. "null", "[]", a bare number) — treat exactly
                // like a corrupt file: start empty, never throw.
                return result;
            }
            foreach (var (key, node) in obj)
            {
                if (node is not JsonValue value)
                {
                    continue; // nested object/array — not a shape this store ever writes; skip it.
                }
                if (value.TryGetValue(out string? s))
                {
                    result[key] = s;
                }
                else if (value.TryGetValue(out bool b))
                {
                    result[key] = b;
                }
                // Any other JSON scalar (number, etc.) is not a type this store round-trips —
                // dropped silently rather than failing the whole load.
            }
        }
        catch
        {
            // Corrupt/unreadable file (malformed JSON, I/O error, access denied, ...) -> start
            // empty. Never throw out of the constructor.
            return new Dictionary<string, object?>();
        }
        return result;
    }

    // MARK: - Save (best-effort, atomic, never throws)

    private void Save()
    {
        try
        {
            var directory = Path.GetDirectoryName(_filePath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var obj = new JsonObject();
            foreach (var (key, value) in _values)
            {
                switch (value)
                {
                    case string s:
                        obj[key] = JsonValue.Create(s);
                        break;
                    case bool b:
                        obj[key] = JsonValue.Create(b);
                        break;
                }
            }

            var tempPath = _filePath + ".tmp-" + Guid.NewGuid().ToString("N");
            File.WriteAllText(tempPath, obj.ToJsonString());
            File.Move(tempPath, _filePath, overwrite: true);
        }
        catch
        {
            // Best-effort persistence — never throw into a SetString/SetBool caller. Worst case:
            // this particular write is lost, but the in-memory value already set stands for the
            // rest of the process's lifetime (mirrors UserDefaults.set, which cannot fail from the
            // caller's perspective either).
        }
    }
}
