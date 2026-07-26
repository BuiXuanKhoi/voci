// Services/Account/TokenStore.cs — encrypted-at-rest persistence for the account session
// (access/refresh token pair). Task brief: "Do NOT put tokens in plain settings/JSON/registry" —
// this is a SEPARATE file from Volar.Data.JsonFileSettingsStore's plaintext settings.json,
// deliberately never sharing that file, so a plaintext settings backup/sync tool can never leak a
// token. Same `%LocalAppData%\Volar\` root convention as every other per-user Volar state file
// (VolarDbPaths.GetDefaultDatabasePath, JsonFileSettingsStore.GetDefaultSettingsPath,
// FileDelegationMetaStore.GetDefaultPath) — just a different filename.
using System.Text.Json;

namespace Volar.App.Services.Account;

public interface ITokenStore
{
    /// <summary>The persisted session, or <see langword="null"/> if none is stored / the stored
    /// blob is corrupt / undecryptable (wrong user, wrong machine, tampered file). A missing or
    /// broken token store is NOT an error — it degrades to signed-out, exactly like a missing
    /// settings.json degrades to defaults.</summary>
    StoredSession? Load();

    /// <summary>Best-effort persistence — mirrors <c>JsonFileSettingsStore.Save</c>'s contract
    /// exactly (atomic temp-file-then-move, swallows any I/O failure). A failed save leaves the
    /// caller's in-memory session as the source of truth for the rest of this process's life.</summary>
    void Save(StoredSession session);

    /// <summary>Removes any persisted session. Never throws.</summary>
    void Clear();
}

/// <summary>Real, file-backed, DPAPI-encrypted token store: <c>%LocalAppData%\Volar\account.dat</c>
/// by convention, though the path is always passed in explicitly (same "helper computes the path,
/// caller decides whether to use it" contract <c>JsonFileSettingsStore</c>/<c>VolarDbPaths</c>
/// already establish).</summary>
public sealed class DpapiTokenStore : ITokenStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.General);

    private readonly object _gate = new();
    private readonly string _filePath;

    public DpapiTokenStore(string? filePath = null)
    {
        _filePath = filePath ?? GetDefaultPath();
    }

    public static string GetDefaultPath() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Volar", "account.dat");

    public StoredSession? Load()
    {
        lock (_gate)
        {
            try
            {
                if (!File.Exists(_filePath))
                {
                    return null;
                }
                var ciphertext = File.ReadAllBytes(_filePath);
                var plaintext = Dpapi.Unprotect(ciphertext);
                if (plaintext is null)
                {
                    return null;
                }
                return JsonSerializer.Deserialize<StoredSession>(plaintext, JsonOptions);
            }
            catch
            {
                // Corrupt/unreadable/undecryptable file -> treat exactly like "no session stored."
                // Never throw out of a Load() call (mirrors JsonFileSettingsStore.Load's own
                // documented convention).
                return null;
            }
        }
    }

    public void Save(StoredSession session)
    {
        lock (_gate)
        {
            try
            {
                var directory = Path.GetDirectoryName(_filePath);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                var plaintext = JsonSerializer.SerializeToUtf8Bytes(session, JsonOptions);
                var ciphertext = Dpapi.Protect(plaintext);

                var tempPath = _filePath + ".tmp-" + Guid.NewGuid().ToString("N");
                File.WriteAllBytes(tempPath, ciphertext);
                File.Move(tempPath, _filePath, overwrite: true);
            }
            catch
            {
                // Best-effort persistence — never throw into a Save() caller (same convention as
                // JsonFileSettingsStore.Save). The in-memory session the caller already has stands
                // for the rest of this process's lifetime even if the write itself failed.
            }
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            try
            {
                if (File.Exists(_filePath))
                {
                    File.Delete(_filePath);
                }
            }
            catch
            {
                // Best-effort — a leftover encrypted file with no in-memory session backing it is
                // harmless (Load() will simply be called again next launch and re-populate memory).
            }
        }
    }
}
