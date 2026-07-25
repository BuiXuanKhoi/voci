// JsonFileSettingsStoreTests.cs — new in Wave 3-B (A3: Local<->Cloud switch). Exercises the
// disk-backed settings store against a real temp file (never a shared/real %LocalAppData% path),
// per the SqliteTestDatabase convention already used elsewhere in this test project.
using Volar.Data;
using Xunit;

namespace Volar.Data.Tests;

/// <summary>A fresh, unique temp file path per test, deleted (plus any stray "*.tmp-*" siblings)
/// on dispose.</summary>
public sealed class TempSettingsFile : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(
        System.IO.Path.GetTempPath(), $"volar-settings-tests-{Guid.NewGuid():N}.json");

    public void Dispose()
    {
        try
        {
            if (File.Exists(Path))
            {
                File.Delete(Path);
            }
            var dir = System.IO.Path.GetDirectoryName(Path)!;
            var prefix = System.IO.Path.GetFileName(Path) + ".tmp-";
            foreach (var stray in Directory.EnumerateFiles(dir, System.IO.Path.GetFileName(Path) + ".tmp-*"))
            {
                File.Delete(stray);
            }
        }
        catch
        {
            // best-effort cleanup only
        }
    }
}

public class JsonFileSettingsStoreTests : IDisposable
{
    private readonly TempSettingsFile _file = new();

    public void Dispose() => _file.Dispose();

    [Fact]
    public void GetString_ReturnsNull_WhenFileDoesNotExist()
    {
        var store = new JsonFileSettingsStore(_file.Path);

        Assert.Null(store.GetString("volar.parseProxyBaseURL"));
        Assert.False(File.Exists(_file.Path), "construction must not create the file — only a write does");
    }

    [Fact]
    public void SetString_ThenGetString_RoundTripsWithinTheSameInstance()
    {
        var store = new JsonFileSettingsStore(_file.Path);

        store.SetString("volar.parseProxyBaseURL", "https://example.supabase.co");

        Assert.Equal("https://example.supabase.co", store.GetString("volar.parseProxyBaseURL"));
    }

    [Fact]
    public void SetString_Persists_AndANewInstanceReadsItBack()
    {
        var first = new JsonFileSettingsStore(_file.Path);
        first.SetString("volar.parseProxyToken", "placeholder-token");
        first.SetBool("volar.cloudParseConsent", true);

        var second = new JsonFileSettingsStore(_file.Path);

        Assert.Equal("placeholder-token", second.GetString("volar.parseProxyToken"));
        Assert.True(second.GetBool("volar.cloudParseConsent", false));
    }

    [Fact]
    public void SetString_Null_RemovesTheKey_AndPersistsTheRemoval()
    {
        var store = new JsonFileSettingsStore(_file.Path);
        store.SetString("volar.parseProxyToken", "secret");

        store.SetString("volar.parseProxyToken", null);

        Assert.Null(store.GetString("volar.parseProxyToken"));
        var reloaded = new JsonFileSettingsStore(_file.Path);
        Assert.Null(reloaded.GetString("volar.parseProxyToken"));
    }

    [Fact]
    public void GetBool_ReturnsDefault_WhenKeyAbsent()
    {
        var store = new JsonFileSettingsStore(_file.Path);

        Assert.False(store.GetBool("volar.cloudParseConsent", false));
        Assert.True(store.GetBool("volar.cloudParseConsent", true));
    }

    [Fact]
    public void Constructor_NeverThrows_WhenFileContainsGarbageBytes()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_file.Path)!);
        File.WriteAllText(_file.Path, "{ this is not valid json ][");

        var store = new JsonFileSettingsStore(_file.Path);

        Assert.Null(store.GetString("anything"));
        Assert.False(store.GetBool("anything", false));
    }

    [Fact]
    public void Constructor_NeverThrows_WhenFileIsValidJsonButNotAnObject()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_file.Path)!);
        File.WriteAllText(_file.Path, "[1, 2, 3]");

        var store = new JsonFileSettingsStore(_file.Path);

        Assert.Null(store.GetString("anything"));
    }

    [Fact]
    public void Save_IsAtomic_NoTempFileSurvivesAWrite()
    {
        var store = new JsonFileSettingsStore(_file.Path);

        store.SetString("volar.parseProxyBaseURL", "https://example.supabase.co");
        store.SetBool("volar.cloudParseConsent", true);

        Assert.True(File.Exists(_file.Path));
        var dir = Path.GetDirectoryName(_file.Path)!;
        var strayTempFiles = Directory.EnumerateFiles(dir, Path.GetFileName(_file.Path) + ".tmp-*");
        Assert.Empty(strayTempFiles);
    }

    [Fact]
    public void GetDefaultSettingsPath_EndsWithVolarSettingsJson()
    {
        var path = JsonFileSettingsStore.GetDefaultSettingsPath();

        Assert.EndsWith(Path.Combine("Volar", "settings.json"), path);
    }

    [Fact]
    public void GetDefaultSettingsPath_HonorsCustomFileName()
    {
        var path = JsonFileSettingsStore.GetDefaultSettingsPath("custom.json");

        Assert.EndsWith(Path.Combine("Volar", "custom.json"), path);
    }

    [Fact]
    public void SetBool_OverwritesPreviousStringValue_LikeUserDefaultsTypeReplacement()
    {
        var store = new JsonFileSettingsStore(_file.Path);
        store.SetString("k", "was-a-string");

        store.SetBool("k", true);

        Assert.Null(store.GetString("k"));
        Assert.True(store.GetBool("k", false));
    }
}
