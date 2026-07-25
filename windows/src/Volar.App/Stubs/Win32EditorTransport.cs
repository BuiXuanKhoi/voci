// Stubs/Win32EditorTransport.cs — IEditorTransport implementation.
//
// Not actually a stub: IEditorTransport.cs's own doc comment says Windows has no App Sandbox, so
// (unlike the Swift original's security-scoped-bookmark dance) every operation here is a direct,
// literal System.IO/Process.Start call — there's no meaningful "fake" version worth writing
// instead. Kept in the Stubs namespace/folder for discoverability alongside this file's siblings.
using System.Diagnostics;
using Volar.Orchestrator;

namespace Volar.App.Stubs;

public sealed class Win32EditorTransport : IEditorTransport
{
    public bool DirectoryExists(string path) => Directory.Exists(path);

    public bool FileExists(string path) => File.Exists(path);

    public byte[]? TryReadAllBytes(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllBytes(path) : null;
        }
        catch
        {
            return null;
        }
    }

    public void CopyFile(string sourcePath, string destinationPath) =>
        File.Copy(sourcePath, destinationPath, overwrite: true);

    public void WriteAllBytesAtomic(string path, byte[] data)
    {
        var tempPath = path + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllBytes(tempPath, data);
        File.Move(tempPath, path, overwrite: true);
    }

    public string? GetHomeDirectory()
    {
        var path = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return string.IsNullOrEmpty(path) ? null : path;
    }

    public string GetCurrentDirectory() => Environment.CurrentDirectory;

    public void OpenUri(Uri uri)
    {
        try
        {
            Process.Start(new ProcessStartInfo(uri.ToString()) { UseShellExecute = true });
        }
        catch
        {
            // Best-effort, mirrors the Swift original's NSWorkspace.open never throwing.
        }
    }
}
