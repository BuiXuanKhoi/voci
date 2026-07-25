// SettingsStoreAdapterTests.cs — verifies the forwarding wrapper over JsonFileSettingsStore
// (see SettingsStoreAdapter.cs's header for why this exists). Uses a real, temp-path-backed
// JsonFileSettingsStore per this wave's rule ("do NOT write to the real
// %LocalAppData%\Volar\ during tests") — every path here lives under Path.GetTempPath().
using Volar.App.Services.Adapters;
using Volar.Data;
using Xunit;

namespace Volar.App.Tests.Adapters;

public sealed class SettingsStoreAdapterTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"volar-app-tests-settings-{Guid.NewGuid():N}.json");

    [Fact]
    public void GetString_ForwardsToInner()
    {
        var inner = new JsonFileSettingsStore(_path);
        inner.SetString("k", "v");
        var adapter = new SettingsStoreAdapter(inner);

        Assert.Equal("v", adapter.GetString("k"));
    }

    [Fact]
    public void SetString_Null_RemovesKey()
    {
        var inner = new JsonFileSettingsStore(_path);
        var adapter = new SettingsStoreAdapter(inner);
        adapter.SetString("k", "v");
        Assert.Equal("v", adapter.GetString("k"));

        adapter.SetString("k", null);

        Assert.Null(adapter.GetString("k"));
    }

    [Fact]
    public void GetBool_DefaultsWhenAbsent()
    {
        var inner = new JsonFileSettingsStore(_path);
        var adapter = new SettingsStoreAdapter(inner);

        Assert.True(adapter.GetBool("missing", true));
        Assert.False(adapter.GetBool("missing", false));
    }

    [Fact]
    public void SetBool_ThenGetBool_RoundTrips()
    {
        var inner = new JsonFileSettingsStore(_path);
        var adapter = new SettingsStoreAdapter(inner);

        adapter.SetBool("flag", true);

        Assert.True(adapter.GetBool("flag", false));
    }

    [Fact]
    public void WritesThroughToTheSameFile_ANewInstanceCanReadBack()
    {
        var adapter = new SettingsStoreAdapter(new JsonFileSettingsStore(_path));
        adapter.SetString("volar.groqToken", "should-not-be-in-any-log");

        var reopened = new SettingsStoreAdapter(new JsonFileSettingsStore(_path));

        Assert.Equal("should-not-be-in-any-log", reopened.GetString("volar.groqToken"));
    }

    public void Dispose()
    {
        if (File.Exists(_path))
        {
            File.Delete(_path);
        }
    }
}
