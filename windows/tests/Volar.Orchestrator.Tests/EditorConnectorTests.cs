using System.Text;
using System.Text.Json.Nodes;
using Xunit;

namespace Volar.Orchestrator.Tests;

public class EditorConnectorTests
{
    private const string ClaudeDir = @"C:\Users\fake\.claude";
    private const string SettingsPath = @"C:\Users\fake\.claude\settings.json";
    private static readonly DateTimeOffset Now = new(2026, 7, 15, 12, 0, 0, TimeSpan.Zero);

    // MARK: - Detect

    [Fact]
    public void Detect_ExplicitPathExists_ReturnsTrue()
    {
        var transport = new FakeEditorTransport();
        transport.AddDirectory(ClaudeDir);
        var connector = new EditorConnector(transport);

        Assert.True(connector.Detect(ClaudeDir));
    }

    [Fact]
    public void Detect_ExplicitPathMissing_ReturnsFalse()
    {
        var transport = new FakeEditorTransport();
        var connector = new EditorConnector(transport);

        Assert.False(connector.Detect(ClaudeDir));
    }

    [Fact]
    public void Detect_NoPath_ResolvesFromHomeDirectory()
    {
        var transport = new FakeEditorTransport { HomeDirectory = @"C:\Users\fake" };
        transport.AddDirectory(@"C:\Users\fake\.claude");
        var connector = new EditorConnector(transport);

        Assert.True(connector.Detect());
    }

    [Fact]
    public void Detect_NoHomeDirectory_ReturnsFalse()
    {
        var transport = new FakeEditorTransport { HomeDirectory = null };
        var connector = new EditorConnector(transport);

        Assert.False(connector.Detect());
    }

    // MARK: - PreviewHookEntry

    [Fact]
    public void PreviewHookEntry_MatchesWindowsPowerShellCommandByteForByte()
    {
        var connector = new EditorConnector(new FakeEditorTransport());

        var preview = connector.PreviewHookEntry();

        Assert.Equal(
            """
            {"hooks":[{"type":"command","command":"powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command \"Start-Process ('volar://ai-done?cwd=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Location).Path)))\""}]}
            """,
            preview);
    }

    [Fact]
    public void PreviewHookEntry_EmittedCommandHasNoOpenOrBase64BinaryDependency()
    {
        // The whole point of this port: neither macOS's `open` nor `base64` exists on Windows, so
        // the emitted command must not depend on either — it must be a self-contained PowerShell
        // invocation instead.
        var connector = new EditorConnector(new FakeEditorTransport());

        var preview = connector.PreviewHookEntry();

        Assert.DoesNotContain("open \"", preview, StringComparison.Ordinal);
        Assert.DoesNotContain("| base64", preview, StringComparison.Ordinal);
        Assert.Contains("powershell", preview, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Start-Process", preview, StringComparison.Ordinal);
        Assert.Contains("[Convert]::ToBase64String", preview, StringComparison.Ordinal);
        // Still contains the marker substring the dedupe/removal logic keys on.
        Assert.Contains("volar://", preview, StringComparison.Ordinal);
    }


    // MARK: - Connect

    [Fact]
    public void Connect_NoExistingFile_CreatesHooksStopWithMarkerEntry()
    {
        var transport = new FakeEditorTransport();
        var connector = new EditorConnector(transport);

        connector.Connect(ClaudeDir, Now);

        var written = transport.GetFileText(SettingsPath);
        Assert.NotNull(written);
        var root = JsonNode.Parse(written!)!.AsObject();
        var stop = root["hooks"]!["Stop"]!.AsArray();
        Assert.Single(stop);
        var command = stop[0]!["hooks"]![0]!["command"]!.GetValue<string>();
        Assert.Contains("volar://", command, StringComparison.Ordinal);
    }

    [Fact]
    public void Connect_ExistingUnrelatedSettings_AdditiveMerge_PreservesEverythingElse()
    {
        var transport = new FakeEditorTransport();
        transport.SetFile(SettingsPath, """
            {"otherKey": "untouched", "hooks": {"PreToolUse": [{"type": "command", "command": "echo hi"}], "Stop": [{"type": "command", "command": "echo bye"}]}}
            """);
        var connector = new EditorConnector(transport);

        connector.Connect(ClaudeDir, Now);

        var root = JsonNode.Parse(transport.GetFileText(SettingsPath)!)!.AsObject();
        Assert.Equal("untouched", root["otherKey"]!.GetValue<string>());
        Assert.Single(root["hooks"]!["PreToolUse"]!.AsArray());
        var stop = root["hooks"]!["Stop"]!.AsArray();
        Assert.Equal(2, stop.Count);
        Assert.Equal("echo bye", stop[0]!["command"]!.GetValue<string>());
    }

    [Fact]
    public void Connect_AlreadyConnected_IsReadOnlyNoOp_NoBackupCreated()
    {
        var transport = new FakeEditorTransport();
        transport.SetFile(SettingsPath, """
            {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "open \"volar://ai-done?cwd=$PWD\""}]}]}}
            """);
        var connector = new EditorConnector(transport);
        var originalBytes = transport.GetFile(SettingsPath);

        connector.Connect(ClaudeDir, Now);

        Assert.Equal(originalBytes, transport.GetFile(SettingsPath));
        Assert.False(transport.FileExists(SettingsPath + $".volar-backup-{Now.ToUnixTimeMilliseconds()}"));
    }

    [Fact]
    public void Connect_StopExistsButIsNotAnArray_ThrowsAndWritesNothing()
    {
        var transport = new FakeEditorTransport();
        transport.SetFile(SettingsPath, """{"hooks": {"Stop": "not-an-array"}}""");
        var connector = new EditorConnector(transport);
        var originalBytes = transport.GetFile(SettingsPath);

        Assert.Throws<EditorConnector.ConnectorException>(() => connector.Connect(ClaudeDir, Now));
        Assert.Equal(originalBytes, transport.GetFile(SettingsPath));
    }

    [Fact]
    public void Connect_BacksUpExistingFileBeforeWriting()
    {
        var transport = new FakeEditorTransport();
        transport.SetFile(SettingsPath, """{"hooks": {}}""");
        var connector = new EditorConnector(transport);
        var originalBytes = transport.GetFile(SettingsPath);

        connector.Connect(ClaudeDir, Now);

        var backupPath = SettingsPath + $".volar-backup-{Now.ToUnixTimeMilliseconds()}";
        Assert.Equal(originalBytes, transport.GetFile(backupPath));
    }

    [Fact]
    public void Connect_NoExistingFile_CreatesNoBackup()
    {
        var transport = new FakeEditorTransport();
        var connector = new EditorConnector(transport);

        connector.Connect(ClaudeDir, Now);

        Assert.False(transport.FileExists(SettingsPath + $".volar-backup-{Now.ToUnixTimeMilliseconds()}"));
    }

    [Fact]
    public void Connect_MalformedExistingJson_IsTreatedAsEmptyObject_NeverThrows()
    {
        var transport = new FakeEditorTransport();
        transport.SetFile(SettingsPath, "{ this is not valid json");
        var connector = new EditorConnector(transport);

        var ex = Record.Exception(() => connector.Connect(ClaudeDir, Now));

        Assert.Null(ex);
        var root = JsonNode.Parse(transport.GetFileText(SettingsPath)!)!.AsObject();
        Assert.Single(root["hooks"]!["Stop"]!.AsArray());
    }

    [Fact]
    public void Connect_CopyFileFails_ThrowsConnectorException()
    {
        var transport = new FakeEditorTransport { ThrowOnCopyFile = new IOException("disk full") };
        transport.SetFile(SettingsPath, """{"hooks": {}}""");
        var connector = new EditorConnector(transport);

        Assert.Throws<EditorConnector.ConnectorException>(() => connector.Connect(ClaudeDir, Now));
    }

    [Fact]
    public void Connect_WriteFails_ThrowsConnectorException()
    {
        var transport = new FakeEditorTransport { ThrowOnWrite = new IOException("disk full") };
        var connector = new EditorConnector(transport);

        Assert.Throws<EditorConnector.ConnectorException>(() => connector.Connect(ClaudeDir, Now));
    }

    // MARK: - SendTestSignal

    [Fact]
    public void SendTestSignal_OpensAiDoneUriWithCurrentDirectory()
    {
        var transport = new FakeEditorTransport { CurrentDirectory = "/some/project" };
        var connector = new EditorConnector(transport);

        connector.SendTestSignal();

        Assert.Single(transport.OpenedUris);
        var uri = transport.OpenedUris[0];
        Assert.Equal("volar", uri.Scheme);
        Assert.Equal("ai-done", uri.Host);
        Assert.Contains("cwd=", uri.Query, StringComparison.Ordinal);
    }

    [Fact]
    public void SendTestSignal_TransportThrows_NeverPropagates()
    {
        var transport = new FakeEditorTransport();
        var throwingTransport = new ThrowingOpenUriTransport(transport);
        var connector = new EditorConnector(throwingTransport);

        var ex = Record.Exception(() => connector.SendTestSignal());

        Assert.Null(ex);
    }

    private sealed class ThrowingOpenUriTransport : IEditorTransport
    {
        private readonly IEditorTransport _inner;
        public ThrowingOpenUriTransport(IEditorTransport inner) => _inner = inner;
        public bool DirectoryExists(string path) => _inner.DirectoryExists(path);
        public bool FileExists(string path) => _inner.FileExists(path);
        public byte[]? TryReadAllBytes(string path) => _inner.TryReadAllBytes(path);
        public void CopyFile(string sourcePath, string destinationPath) => _inner.CopyFile(sourcePath, destinationPath);
        public void WriteAllBytesAtomic(string path, byte[] data) => _inner.WriteAllBytesAtomic(path, data);
        public string? GetHomeDirectory() => _inner.GetHomeDirectory();
        public string GetCurrentDirectory() => _inner.GetCurrentDirectory();
        public void OpenUri(Uri uri) => throw new InvalidOperationException("boom");
    }

    // MARK: - Disconnect

    [Fact]
    public void Disconnect_NoSettingsFile_IsNoOp()
    {
        var transport = new FakeEditorTransport();
        var connector = new EditorConnector(transport);

        var ex = Record.Exception(() => connector.Disconnect(ClaudeDir, Now));

        Assert.Null(ex);
        Assert.False(transport.FileExists(SettingsPath));
    }

    [Fact]
    public void Disconnect_NoHooksKey_IsNoOp()
    {
        var transport = new FakeEditorTransport();
        transport.SetFile(SettingsPath, """{"otherKey": "value"}""");
        var connector = new EditorConnector(transport);
        var originalBytes = transport.GetFile(SettingsPath);

        connector.Disconnect(ClaudeDir, Now);

        Assert.Equal(originalBytes, transport.GetFile(SettingsPath));
    }

    [Fact]
    public void Disconnect_NoMarkerEntries_IsNoOp_NoBackup()
    {
        var transport = new FakeEditorTransport();
        transport.SetFile(SettingsPath, """{"hooks": {"Stop": [{"type": "command", "command": "echo hi"}]}}""");
        var connector = new EditorConnector(transport);
        var originalBytes = transport.GetFile(SettingsPath);

        connector.Disconnect(ClaudeDir, Now);

        Assert.Equal(originalBytes, transport.GetFile(SettingsPath));
        Assert.False(transport.FileExists(SettingsPath + $".volar-backup-{Now.ToUnixTimeMilliseconds()}"));
    }

    [Fact]
    public void Disconnect_RemovesOnlyMarkerEntries_PreservesOthers()
    {
        var transport = new FakeEditorTransport();
        transport.SetFile(SettingsPath, """
            {"hooks": {"Stop": [
                {"type": "command", "command": "echo keep-me"},
                {"hooks": [{"type": "command", "command": "open \"volar://ai-done?cwd=$PWD\""}]}
            ]}}
            """);
        var connector = new EditorConnector(transport);

        connector.Disconnect(ClaudeDir, Now);

        var root = JsonNode.Parse(transport.GetFileText(SettingsPath)!)!.AsObject();
        var stop = root["hooks"]!["Stop"]!.AsArray();
        Assert.Single(stop);
        Assert.Equal("echo keep-me", stop[0]!["command"]!.GetValue<string>());
    }

    [Fact]
    public void Disconnect_OldFlatShapeMarker_IsRemovedForBackwardCompat()
    {
        var transport = new FakeEditorTransport();
        transport.SetFile(SettingsPath, """{"hooks": {"Stop": [{"type": "command", "command": "open \"volar://ai-done?cwd=$PWD\""}]}}""");
        var connector = new EditorConnector(transport);

        connector.Disconnect(ClaudeDir, Now);

        var root = JsonNode.Parse(transport.GetFileText(SettingsPath)!)!.AsObject();
        Assert.Empty(root["hooks"]!["Stop"]!.AsArray());
    }

    [Fact]
    public void Disconnect_BacksUpBeforeRemoving()
    {
        var transport = new FakeEditorTransport();
        transport.SetFile(SettingsPath, """{"hooks": {"Stop": [{"type": "command", "command": "open \"volar://ai-done?cwd=$PWD\""}]}}""");
        var connector = new EditorConnector(transport);
        var originalBytes = transport.GetFile(SettingsPath);

        connector.Disconnect(ClaudeDir, Now);

        var backupPath = SettingsPath + $".volar-backup-{Now.ToUnixTimeMilliseconds()}";
        Assert.Equal(originalBytes, transport.GetFile(backupPath));
    }

    // MARK: - Real-home guard (Windows-only hardening — no App Sandbox to enforce this for us)

    [Fact]
    public void Connect_ClaudeDirOutsideUserProfile_ThrowsAndWritesNothing()
    {
        var transport = new FakeEditorTransport { HomeDirectory = @"C:\Users\fake" };
        var connector = new EditorConnector(transport);
        const string outsidePath = @"C:\Windows\System32\.claude";

        Assert.Throws<EditorConnector.ConnectorException>(() => connector.Connect(outsidePath, Now));

        Assert.False(transport.FileExists(System.IO.Path.Combine(outsidePath, "settings.json")));
    }

    [Fact]
    public void Connect_ClaudeDirLooksLikeItsUnderProfileButTraversesOut_ThrowsAndWritesNothing()
    {
        // "C:\Users\fake\..\other\.claude" textually starts with the home directory but resolves
        // (via `..`) to a sibling directory outside it — Path.GetFullPath collapses the traversal
        // before the prefix check runs, so this must still be rejected.
        var transport = new FakeEditorTransport { HomeDirectory = @"C:\Users\fake" };
        var connector = new EditorConnector(transport);
        const string traversalPath = @"C:\Users\fake\..\other\.claude";

        Assert.Throws<EditorConnector.ConnectorException>(() => connector.Connect(traversalPath, Now));
    }

    [Fact]
    public void Connect_HomeDirectoryUnavailable_ThrowsAndWritesNothing()
    {
        var transport = new FakeEditorTransport { HomeDirectory = null };
        var connector = new EditorConnector(transport);

        Assert.Throws<EditorConnector.ConnectorException>(() => connector.Connect(ClaudeDir, Now));
    }

    [Fact]
    public void Connect_ClaudeDirEqualToUserProfileItself_IsAllowed()
    {
        // Boundary case: the claimed ".claude" dir IS the home directory itself, not a
        // subdirectory of it — should still be treated as "within", not rejected.
        var transport = new FakeEditorTransport { HomeDirectory = @"C:\Users\fake" };
        var connector = new EditorConnector(transport);

        var ex = Record.Exception(() => connector.Connect(@"C:\Users\fake", Now));

        Assert.Null(ex);
    }

    [Fact]
    public void Disconnect_ClaudeDirOutsideUserProfile_ThrowsAndWritesNothing()
    {
        var transport = new FakeEditorTransport { HomeDirectory = @"C:\Users\fake" };
        transport.SetFile(@"C:\Windows\System32\.claude\settings.json", """{"hooks": {"Stop": [{"type": "command", "command": "volar://ai-done"}]}}""");
        var connector = new EditorConnector(transport);
        var originalBytes = transport.GetFile(@"C:\Windows\System32\.claude\settings.json");

        Assert.Throws<EditorConnector.ConnectorException>(
            () => connector.Disconnect(@"C:\Windows\System32\.claude", Now));

        Assert.Equal(originalBytes, transport.GetFile(@"C:\Windows\System32\.claude\settings.json"));
    }

    [Fact]
    public void Disconnect_HomeDirectoryUnavailable_ThrowsAndWritesNothing()
    {
        var transport = new FakeEditorTransport { HomeDirectory = null };
        transport.SetFile(SettingsPath, """{"hooks": {"Stop": [{"type": "command", "command": "volar://ai-done"}]}}""");
        var connector = new EditorConnector(transport);
        var originalBytes = transport.GetFile(SettingsPath);

        Assert.Throws<EditorConnector.ConnectorException>(() => connector.Disconnect(ClaudeDir, Now));

        Assert.Equal(originalBytes, transport.GetFile(SettingsPath));
    }
}
