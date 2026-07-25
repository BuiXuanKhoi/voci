// IEditorTransport.cs — external I/O seam for EditorConnector (port of
// Sources/Orchestrator/ClaudeCodeConnector.swift's direct FileManager/NSWorkspace usage).
//
// Swift's original talks directly to FileManager (file existence/read/copy/atomic-write) and
// NSWorkspace (launching a URL) inside an App-Sandboxed, security-scoped-bookmark world that has
// no Windows equivalent. This interface is the seam that keeps `EditorConnector`'s MERGE/BACKUP/
// MARKER logic pure and unit-testable: every method here is a thin, literal capability
// (`DirectoryExists`, `TryReadAllBytes`, ...), not a bundled macOS-shaped operation. The concrete
// Win32 implementation (plain `System.IO` + `Process.Start`/`ShellExecute` for `OpenUri`) is
// DEFERRED to Wave 3 (App shell) per this task's brief — this file defines the contract plus a
// fake used by this project's own tests.
namespace Volar.Orchestrator;

/// <summary>
/// The filesystem + "launch something" operations <see cref="EditorConnector"/> needs. Windows has
/// no App Sandbox, so — unlike Swift's security-scoped-bookmark dance — every path here is a plain
/// string the caller already has access to; there is nothing to "start/stop accessing".
/// </summary>
public interface IEditorTransport
{
    /// <summary>Whether a directory exists at <paramref name="path"/>.</summary>
    bool DirectoryExists(string path);

    /// <summary>Whether a file exists at <paramref name="path"/>.</summary>
    bool FileExists(string path);

    /// <summary>
    /// Tolerant read: <see langword="null"/> if the file doesn't exist or can't be read for any
    /// reason (mirrors Swift's <c>(try? Data(contentsOf:)) ?? Data()</c> — callers here treat
    /// <see langword="null"/> the same way that idiom treats an empty <c>Data</c>).
    /// </summary>
    byte[]? TryReadAllBytes(string path);

    /// <summary>
    /// Copies <paramref name="sourcePath"/> to <paramref name="destinationPath"/> — used for the
    /// settings.json backup-before-write. Throws on failure (the caller wraps this in a
    /// <see cref="EditorConnector.ConnectorException"/>, mirroring Swift's <c>fm.copyItem</c> +
    /// <see langword="catch"/>).
    /// </summary>
    void CopyFile(string sourcePath, string destinationPath);

    /// <summary>
    /// Atomic write: implementers write-to-temp + rename so a crash mid-write can never leave a
    /// truncated file (mirrors Swift's <c>Data.write(options: .atomic)</c>). Throws on failure.
    /// </summary>
    void WriteAllBytesAtomic(string path, byte[] data);

    /// <summary>
    /// The real user home directory (mirrors <c>NSHomeDirectoryForUser(NSUserName())</c>; on
    /// Windows there is no App Sandbox / container redirection, so the Wave-3 implementation is
    /// simply <c>Environment.GetFolderPath(SpecialFolder.UserProfile)</c>). <see langword="null"/>
    /// if it cannot be determined — callers fail closed on that, exactly as the Swift original
    /// does when its own home-directory lookup returns <see langword="nil"/>.
    /// </summary>
    string? GetHomeDirectory();

    /// <summary>
    /// The process's current working directory (mirrors <c>FileManager.default.currentDirectoryPath</c>).
    /// </summary>
    string GetCurrentDirectory();

    /// <summary>
    /// Launches/opens <paramref name="uri"/> via the OS shell (mirrors
    /// <c>NSWorkspace.shared.open(_:)</c>) — used only by <see cref="EditorConnector.SendTestSignal"/>.
    /// Never expected to throw; a failure here is a best-effort no-op on the Swift side too.
    /// </summary>
    void OpenUri(Uri uri);
}
