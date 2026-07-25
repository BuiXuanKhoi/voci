// EditorConnector.cs — port of Sources/Orchestrator/ClaudeCodeConnector.swift (feature 002,
// Phase 6, T041, "Connector agent"). Installs/removes the single Claude Code "Stop" hook that lets
// an external `claude` CLI run signal Volar (`volar://ai-done?cwd=...`) when it finishes, and
// offers a manual test-signal.
//
// Contract: specs/002-workflow-command-center/contracts/phase6-contract.md section B, behavior per
// contracts/app-links.md "Claude Code hook" section.
//
// Self-contained: JSON + the small set of filesystem/launch operations behind
// <see cref="IEditorTransport"/> (see that file for why). No dependency on any task store/UI.
//
// PLATFORM DEVIATION FROM SWIFT (documented, not silent): Swift's `detect()`/`connect()`/
// `disconnect()` are built around macOS App Sandbox security-scoped bookmarks — a whole
// grant/resolve/stale-refresh protocol that exists ONLY because a sandboxed process cannot see
// paths outside its container without one. Windows has no equivalent sandbox restriction for this
// kind of user-granted folder access, so that entire bookmark-persistence layer (Swift's private
// `claudeDirBookmarkKey` UserDefaults entry + `persistBookmark`) has no port here: every method
// below simply takes the `.claude` directory path as a plain string and uses it directly via
// <see cref="IEditorTransport"/>. The MERGE/BACKUP/MARKER logic itself (the part with actual
// product behavior) is ported 1:1. Because that sandbox is also what stopped a stray/malicious
// `claudeDirPath` from ever pointing outside the user's own folder on macOS, `Connect`/`Disconnect`
// add an explicit equivalent here (see `EnsureWithinUserProfile`) that Swift never needed.
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Volar.Orchestrator;

/// <summary>
/// Installs/removes the Claude Code Stop hook. Constitution I: this type only ever WRITES that one
/// marker hook into the user's own settings file — macOS's <c>~/.claude/settings.json</c>, Windows's
/// <c>%USERPROFILE%\.claude\settings.json</c> (the caller resolves and passes the <c>.claude</c>
/// directory; see <see cref="Connect"/>/<see cref="Disconnect"/>) — always backs the file up first,
/// and never reads or touches anything else under that directory.
/// </summary>
public sealed class EditorConnector
{
    /// <summary>Snapshot for a Settings UI to render connect/disconnect state.</summary>
    public readonly record struct State(bool Installed, bool ClaudeDetected);

    /// <summary>
    /// Human-readable failure for every throwing path here. Never a crash — malformed input,
    /// missing files, and access failures all resolve to one of these (mirrors Swift's
    /// <c>ConnectorError: LocalizedError</c>).
    /// </summary>
    public sealed class ConnectorException : Exception
    {
        public ConnectorException(string message) : base(message) { }
    }

    // MARK: - Constants

    private const string Scheme = "volar";

    /// <summary>
    /// Marker substring used both to *detect* our hook (dedupe on connect) and to *remove only our
    /// hook* on disconnect. Any command containing this substring is considered ours; everything
    /// else — however it's shaped — is left completely untouched.
    /// </summary>
    private const string MarkerSubstring = $"{Scheme}://";

    /// <summary>
    /// <c>$PWD</c> (here, PowerShell's <c>Get-Location</c>) is base64-encoded before being embedded
    /// in the <c>cwd=</c> query param — an un-encoded path containing a space/<c>#</c>/<c>&amp;</c>/
    /// non-ASCII byte would otherwise break the URL Claude Code's hook runner constructs.
    /// <see cref="AppLinkHandler"/> decodes it back on receipt (falling back to the raw value for a
    /// hook installed by a previous build) — same wire format as macOS's hook (base64 of the UTF-8
    /// cwd bytes), so that decode side needed no change here.
    /// </summary>
    /// <remarks>
    /// PLATFORM DEVIATION FROM SWIFT (see also the file header): macOS's hook is the POSIX shell
    /// one-liner <c>open "volar://ai-done?cwd=$(printf %s \"$PWD\" | base64)"</c>
    /// (<c>Volar/Sources/Orchestrator/ClaudeCodeConnector.swift</c>'s <c>hookCommand</c>), using
    /// <c>open</c>(1) and <c>base64</c>(1) — neither exists on Windows, so that line installed a hook
    /// that could never fire here. This is the Windows-native replacement: a single-line PowerShell
    /// invocation. <c>Start-Process &lt;uri&gt;</c> resolves through the OS's registered protocol
    /// handler exactly the way <c>open</c> does on macOS (URI scheme registration itself is Wave
    /// 3-C's job, not this file's); <c>[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(...))</c>
    /// reproduces the exact same base64(UTF8(cwd)) bytes <c>base64</c>(1) would, so
    /// <see cref="AppLinkHandler"/>'s <c>DecodedCwd</c> keeps working completely unmodified.
    /// <c>-NoProfile -NonInteractive -WindowStyle Hidden</c> mirror <c>open</c>'s silence: no profile
    /// script, no prompt, no flashing console window when the hook runner fires it.
    ///
    /// // UNVERIFIED: exactly which process Claude Code uses to execute a <c>hooks.Stop</c>
    /// "command" entry on Windows — <c>cmd.exe /c</c>, a shell invoked via node's/whatever runtime's
    /// `spawn(..., { shell: true })`, or <c>CreateProcess</c> directly with no shell at all — has not
    /// been independently confirmed from this worktree (no Windows Claude Code install available
    /// here). The command below is written defensively so it tolerates any of those: it names its
    /// own interpreter (<c>powershell ...</c>) instead of assuming it already runs inside one, avoids
    /// any <c>cmd</c>-only syntax (no unescaped <c>%VAR%</c>, no bare <c>&amp;</c>/<c>|</c> a naive
    /// <c>cmd /c</c> tokenizer could mis-split), and stays a single balanced-quote line. The
    /// "Chạy thử" / test-connection path (<see cref="SendTestSignal"/>, plus actually running
    /// <c>claude</c> so its real Stop hook fires) is what proves on anh Khôi's machine whether this
    /// assumption holds — if it doesn't, only this one constant needs to change.
    /// </remarks>
    private const string HookCommand = "powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command \"Start-Process ('volar://ai-done?cwd=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Location).Path)))\"";

    private const string SettingsFileName = "settings.json";

    private readonly IEditorTransport _transport;

    public EditorConnector(IEditorTransport transport)
    {
        _transport = transport;
    }

    // MARK: - Detect()

    /// <summary>
    /// Best-effort "does <c>~/.claude</c> exist" check, per contract B.
    /// </summary>
    /// <param name="claudeDirPath">
    /// A previously-known/granted path to check directly (the authoritative case, mirroring
    /// Swift's bookmark-resolved branch — minus the bookmark machinery itself, see file header).
    /// <see langword="null"/> falls back to resolving <c>&lt;home&gt;\.claude</c> via
    /// <see cref="IEditorTransport.GetHomeDirectory"/> (mirrors Swift's raw-fallback branch).
    /// </param>
    /// <remarks>Never throws.</remarks>
    public bool Detect(string? claudeDirPath = null)
    {
        if (claudeDirPath is not null)
        {
            return _transport.DirectoryExists(claudeDirPath);
        }
        var home = _transport.GetHomeDirectory();
        if (home is null)
        {
            return false;
        }
        var path = System.IO.Path.Combine(home, ".claude");
        return _transport.DirectoryExists(path);
    }

    // MARK: - PreviewHookEntry()

    /// <summary>
    /// The exact JSON hook-group entry that <see cref="Connect"/> will append into
    /// <c>hooks.Stop</c>, for the preview UI.
    /// </summary>
    /// <remarks>
    /// Claude Code's real settings schema requires Stop-hook entries to be matcher-group objects —
    /// <c>{"hooks":[{"type":"command","command":"..."}]}</c> — not a bare
    /// <c>{"type":"command","command":"..."}</c> dict placed directly in the <c>Stop</c> array.
    ///
    /// CONTRACT DIVERGENCE (documented, not silent): <c>specs/002-workflow-command-center/contracts/
    /// app-links.md</c> "Claude Code hook" section pins the byte-for-byte JSON example to macOS's
    /// <c>open ".../$(... | base64)"</c> command. That document is macOS-specific and was left
    /// unedited (out of this file's ownership/scope) rather than silently rewritten; on Windows this
    /// method instead renders <see cref="HookCommand"/>'s PowerShell invocation (see its doc comment
    /// for why), so the JSON *shape* (matcher-group array) matches the contract exactly but the
    /// *command string* inside it intentionally does not match app-links.md's literal example.
    /// </remarks>
    public string PreviewHookEntry() =>
        "{\"hooks\":[{\"type\":\"command\",\"command\":\"" + JsonEscape(HookCommand) + "\"}]}";

    // MARK: - Connect()

    /// <summary>
    /// Installs the hook against the <c>.claude</c> directory at <paramref name="claudeDirPath"/>.
    /// Sequence, matching the install contract in app-links.md:
    /// <list type="number">
    /// <item>Parse tolerantly (read-only, no side effects yet): missing file, empty file, or JSON
    /// that fails to parse, or whose root isn't an object, all resolve to an empty root object.</item>
    /// <item>If a marker entry is already present, return without creating a backup or rewriting
    /// the file at all, since nothing would change.</item>
    /// <item>Otherwise, if <c>settings.json</c> exists, copy it byte-for-byte to
    /// <c>settings.json.volar-backup-&lt;timestamp&gt;</c> BEFORE the write that's about to happen.</item>
    /// <item>Additive-merge: read <c>hooks.Stop</c> as an array (creating <c>hooks</c>/<c>Stop</c>
    /// if absent), keep every existing element exactly as-is, and append our entry (if
    /// <c>hooks.Stop</c> exists but isn't an array, throw instead of silently replacing whatever's
    /// there). Every other key under <c>hooks</c> and every other entry in <c>Stop</c> is passed
    /// through untouched. Then serialize and write atomically.</item>
    /// </list>
    /// Idempotent: calling this again when already connected is a read-only no-op.
    /// </summary>
    /// <exception cref="ConnectorException">
    /// Also thrown up front, before any file is touched, if <paramref name="claudeDirPath"/> does
    /// not resolve inside the real user profile directory — see <see cref="EnsureWithinUserProfile"/>.
    /// </exception>
    public void Connect(string claudeDirPath, DateTimeOffset now)
    {
        EnsureWithinUserProfile(claudeDirPath);

        var settingsPath = System.IO.Path.Combine(claudeDirPath, SettingsFileName);

        var existingBytes = _transport.TryReadAllBytes(settingsPath) ?? Array.Empty<byte>();
        var root = ParseTolerant(existingBytes);

        var hooksNode = root["hooks"] as JsonObject;
        if (hooksNode is null)
        {
            hooksNode = new JsonObject();
            root["hooks"] = hooksNode;
        }

        // `hooks.Stop` present but not an array (some other, unexpected shape) must not be
        // silently clobbered with `[ourEntry]` — that would destroy user data. Fail loudly instead.
        if (hooksNode["Stop"] is JsonNode existingStopValue && existingStopValue is not JsonArray)
        {
            throw new ConnectorException(
                "Volar found hooks.Stop in your settings.json but it isn't an array (unexpected shape), so nothing was changed. Please check settings.json manually.");
        }

        var stopArray = hooksNode["Stop"] as JsonArray;
        if (stopArray is null)
        {
            stopArray = new JsonArray();
            hooksNode["Stop"] = stopArray;
        }

        var alreadyConnected = stopArray.Any(IsMarkerEntry);
        if (alreadyConnected)
        {
            // Nothing to change — skip the backup/write entirely.
            return;
        }

        // Backup first, always, before the write about to happen — even if what's on disk turns
        // out to be malformed. If there's no existing file there's nothing to protect.
        if (_transport.FileExists(settingsPath))
        {
            var backupPath = System.IO.Path.Combine(claudeDirPath, $"{SettingsFileName}.volar-backup-{TimestampToken(now)}");
            try
            {
                _transport.CopyFile(settingsPath, backupPath);
            }
            catch (Exception error)
            {
                throw new ConnectorException(
                    $"Volar couldn't back up your existing settings.json, so nothing was changed. ({error.Message})");
            }
        }

        stopArray.Add(HookEntryObject());

        byte[] outBytes;
        try
        {
            outBytes = Encoding.UTF8.GetBytes(root.ToJsonString(SerializerOptions));
        }
        catch (Exception error)
        {
            throw new ConnectorException(
                $"Volar built a hook entry it couldn't encode as JSON, so nothing was written. ({error.Message})");
        }

        try
        {
            _transport.WriteAllBytesAtomic(settingsPath, outBytes);
        }
        catch (Exception error)
        {
            throw new ConnectorException(
                $"Volar couldn't write settings.json (your original is safe in the backup). ({error.Message})");
        }
    }

    // MARK: - SendTestSignal()

    /// <summary>
    /// Opens <c>volar://ai-done?cwd=&lt;current dir&gt;</c> via <see cref="IEditorTransport.OpenUri"/>
    /// so the user sees the app register a "received" round-trip after connecting. Never throws —
    /// if URL construction or the launch itself somehow fails, this is a silent no-op.
    /// </summary>
    public void SendTestSignal()
    {
        try
        {
            var cwd = _transport.GetCurrentDirectory();
            if (!Uri.TryCreate($"{Scheme}://ai-done?cwd={Uri.EscapeDataString(cwd)}", UriKind.Absolute, out var uri))
            {
                return;
            }
            _transport.OpenUri(uri);
        }
        catch
        {
            // Intentionally swallowed — see doc comment above.
        }
    }

    // MARK: - Disconnect()

    /// <summary>
    /// Removes ONLY marker-matching entries (command contains <c>volar://</c>) from
    /// <c>hooks.Stop</c>, leaving every other entry — and every other key under <c>hooks</c> —
    /// exactly as found. Idempotent/safe no-ops: missing <c>settings.json</c>, missing/malformed
    /// <c>hooks</c>, or a <c>Stop</c> array with no marker entries all return without throwing and
    /// without touching the file. A backup is created only when there is an actual marker entry to
    /// remove, immediately before the resulting write.
    /// </summary>
    /// <exception cref="ConnectorException">
    /// Also thrown up front, before any file is touched, if <paramref name="claudeDirPath"/> does
    /// not resolve inside the real user profile directory — see <see cref="EnsureWithinUserProfile"/>.
    /// </exception>
    public void Disconnect(string claudeDirPath, DateTimeOffset now)
    {
        EnsureWithinUserProfile(claudeDirPath);

        var settingsPath = System.IO.Path.Combine(claudeDirPath, SettingsFileName);
        if (!_transport.FileExists(settingsPath))
        {
            return; // Nothing installed, nothing to disconnect.
        }

        var existingBytes = _transport.TryReadAllBytes(settingsPath) ?? Array.Empty<byte>();
        var root = ParseTolerant(existingBytes);

        if (root["hooks"] is not JsonObject hooksNode)
        {
            return; // No `hooks` object at all — nothing of ours to remove.
        }

        var stopArray = hooksNode["Stop"] as JsonArray ?? new JsonArray();
        var originalCount = stopArray.Count;
        for (var i = stopArray.Count - 1; i >= 0; i--)
        {
            if (IsMarkerEntry(stopArray[i]))
            {
                stopArray.RemoveAt(i);
            }
        }
        if (stopArray.Count == originalCount)
        {
            return; // No marker entries present — nothing changed, nothing written.
        }

        var backupPath = System.IO.Path.Combine(claudeDirPath, $"{SettingsFileName}.volar-backup-{TimestampToken(now)}");
        try
        {
            _transport.CopyFile(settingsPath, backupPath);
        }
        catch (Exception error)
        {
            throw new ConnectorException(
                $"Volar couldn't back up your existing settings.json, so nothing was changed. ({error.Message})");
        }

        byte[] outBytes;
        try
        {
            outBytes = Encoding.UTF8.GetBytes(root.ToJsonString(SerializerOptions));
        }
        catch (Exception error)
        {
            throw new ConnectorException(
                $"Volar couldn't encode the updated settings.json, so nothing was written. ({error.Message})");
        }

        try
        {
            _transport.WriteAllBytesAtomic(settingsPath, outBytes);
        }
        catch (Exception error)
        {
            throw new ConnectorException(
                $"Volar couldn't write settings.json (your original is safe in the backup). ({error.Message})");
        }
    }

    // MARK: - Real-home guard

    /// <summary>
    /// Rejects a <paramref name="claudeDirPath"/> that does not resolve to (or under) the caller's
    /// real user profile directory. Called first thing by <see cref="Connect"/>/<see cref="Disconnect"/>,
    /// before any file is read or written.
    /// </summary>
    /// <remarks>
    /// PLATFORM DEVIATION FROM SWIFT (see file header): on macOS, App Sandbox itself is what stops
    /// <c>connect(bookmarkedClaudeDir:)</c>/<c>disconnect(bookmarkedClaudeDir:)</c> from ever writing
    /// outside a directory the user explicitly granted via NSOpenPanel — the OS enforces it, so
    /// Swift's connect()/disconnect() never needed an explicit check (only <c>detect()</c>'s
    /// fallback branch has a "real home" concern at all, via <c>NSHomeDirectoryForUser(NSUserName())</c>
    /// — FIX D in <c>ClaudeCodeConnector.swift</c> — solving a *different* problem: the sandbox
    /// container's redirected <c>$HOME</c> causing false negatives). Windows has no such sandbox, so
    /// there is nothing stopping a wrongly-derived or maliciously-supplied <paramref
    /// name="claudeDirPath"/> from pointing this type's backup/write/delete-marker logic at an
    /// arbitrary directory. This method is the explicit Windows-side equivalent of the protection
    /// the sandbox provided for free on macOS, applying the same "fail closed rather than trust an
    /// unverifiable path" spirit as FIX D: unable to determine the real home, or the path resolves
    /// outside it (including via <c>..</c> traversal, since <see cref="System.IO.Path.GetFullPath(string)"/>
    /// collapses those first) → throw, before touching anything.
    /// </remarks>
    private void EnsureWithinUserProfile(string claudeDirPath)
    {
        var home = _transport.GetHomeDirectory();
        if (string.IsNullOrEmpty(home))
        {
            throw new ConnectorException(
                "Volar couldn't determine your user profile directory, so nothing was changed.");
        }

        string fullClaudeDir;
        string fullHome;
        try
        {
            fullClaudeDir = System.IO.Path.GetFullPath(claudeDirPath);
            fullHome = System.IO.Path.GetFullPath(home);
        }
        catch (Exception error)
        {
            throw new ConnectorException(
                $"Volar couldn't resolve the .claude folder path, so nothing was changed. ({error.Message})");
        }

        var homeWithSeparator = fullHome.EndsWith(System.IO.Path.DirectorySeparatorChar)
            ? fullHome
            : fullHome + System.IO.Path.DirectorySeparatorChar;
        var isWithinHome =
            string.Equals(fullClaudeDir, fullHome, StringComparison.OrdinalIgnoreCase) ||
            fullClaudeDir.StartsWith(homeWithSeparator, StringComparison.OrdinalIgnoreCase);
        if (!isWithinHome)
        {
            throw new ConnectorException(
                "Volar only writes inside your own user profile's .claude folder, and the given folder is outside it, so nothing was changed.");
        }
    }

    // MARK: - Shared JSON helpers

    private static readonly JsonSerializerOptions SerializerOptions = new() { WriteIndented = true };

    /// <summary>
    /// Parses <paramref name="data"/> as a JSON object. Missing/empty data, JSON that fails to
    /// parse, and JSON whose root isn't an object (e.g. an array or a bare string) all collapse to
    /// an empty object — this never throws.
    /// </summary>
    private static JsonObject ParseTolerant(byte[] data)
    {
        if (data.Length == 0)
        {
            return new JsonObject();
        }
        try
        {
            return JsonNode.Parse(data) as JsonObject ?? new JsonObject();
        }
        catch (JsonException)
        {
            return new JsonObject();
        }
    }

    /// <summary>
    /// True for entries that contain a <c>command</c> string mentioning our scheme marker, in
    /// EITHER of two shapes so <see cref="Disconnect"/> cleans up entries written by either build:
    /// the current matcher-group shape (<c>{"hooks":[{"type":"command","command":"volar://…"}]}</c>)
    /// or the old flat shape (<c>{"type":"command","command":"volar://…"}</c>), for backward-compat
    /// cleanup of entries written by a previous build. Anything else is never considered "ours".
    /// </summary>
    private static bool IsMarkerEntry(JsonNode? element)
    {
        if (element is not JsonObject dict)
        {
            return false;
        }

        // New shape: {"hooks": [{"type": "command", "command": "..."}]}
        if (dict["hooks"] is JsonArray innerHooks)
        {
            foreach (var inner in innerHooks)
            {
                if (inner is JsonObject innerDict
                    && innerDict["command"] is JsonValue innerCommandValue
                    && innerCommandValue.TryGetValue<string>(out var innerCommand)
                    && innerCommand.Contains(MarkerSubstring, StringComparison.Ordinal))
                {
                    return true;
                }
            }
        }

        // Old (pre-matcher-group) flat shape: {"type": "command", "command": "..."}
        if (dict["command"] is JsonValue commandValue
            && commandValue.TryGetValue<string>(out var command)
            && command.Contains(MarkerSubstring, StringComparison.Ordinal))
        {
            return true;
        }

        return false;
    }

    private static JsonObject HookEntryObject() => new()
    {
        ["hooks"] = new JsonArray(new JsonObject
        {
            ["type"] = "command",
            ["command"] = HookCommand
        })
    };

    private static string TimestampToken(DateTimeOffset now) =>
        now.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture);

    /// <summary>
    /// Minimal, correct JSON string-escaping for building <see cref="PreviewHookEntry"/>'s literal
    /// text by hand (needed to pin the exact <c>"type"</c> then <c>"command"</c> key order;
    /// <see cref="JsonSerializer"/> only offers alphabetical-or-unspecified key ordering).
    /// </summary>
    private static string JsonEscape(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var ch in s)
        {
            switch (ch)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (ch < 0x20)
                    {
                        sb.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        sb.Append(ch);
                    }
                    break;
            }
        }
        return sb.ToString();
    }
}
