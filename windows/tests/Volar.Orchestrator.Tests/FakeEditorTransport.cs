namespace Volar.Orchestrator.Tests;

/// <summary>
/// In-memory fake of <see cref="IEditorTransport"/> for <see cref="EditorConnector"/> unit tests —
/// no real filesystem access, no process launch. Paths are plain dictionary keys (case-sensitive,
/// exactly as given); tests are expected to use consistent path strings.
/// </summary>
internal sealed class FakeEditorTransport : IEditorTransport
{
    private readonly HashSet<string> _directories = new();
    private readonly Dictionary<string, byte[]> _files = new();

    public string? HomeDirectory { get; set; } = @"C:\Users\fake";
    public string CurrentDirectory { get; set; } = @"C:\projects\fake";

    /// <summary>Every URI passed to <see cref="OpenUri"/>, in call order.</summary>
    public List<Uri> OpenedUris { get; } = new();

    public Exception? ThrowOnCopyFile { get; set; }
    public Exception? ThrowOnWrite { get; set; }

    public void AddDirectory(string path) => _directories.Add(path);

    public void SetFile(string path, byte[] contents) => _files[path] = contents;

    public void SetFile(string path, string contents) => SetFile(path, System.Text.Encoding.UTF8.GetBytes(contents));

    public byte[]? GetFile(string path) => _files.TryGetValue(path, out var data) ? data : null;

    public string? GetFileText(string path) => GetFile(path) is byte[] data ? System.Text.Encoding.UTF8.GetString(data) : null;

    public bool DirectoryExists(string path) => _directories.Contains(path);

    public bool FileExists(string path) => _files.ContainsKey(path);

    public byte[]? TryReadAllBytes(string path) => _files.TryGetValue(path, out var data) ? data : null;

    public void CopyFile(string sourcePath, string destinationPath)
    {
        if (ThrowOnCopyFile is not null)
        {
            throw ThrowOnCopyFile;
        }
        if (!_files.TryGetValue(sourcePath, out var data))
        {
            throw new FileNotFoundException(sourcePath);
        }
        _files[destinationPath] = data;
    }

    public void WriteAllBytesAtomic(string path, byte[] data)
    {
        if (ThrowOnWrite is not null)
        {
            throw ThrowOnWrite;
        }
        _files[path] = data;
    }

    public string? GetHomeDirectory() => HomeDirectory;

    public string GetCurrentDirectory() => CurrentDirectory;

    public void OpenUri(Uri uri) => OpenedUris.Add(uri);
}
