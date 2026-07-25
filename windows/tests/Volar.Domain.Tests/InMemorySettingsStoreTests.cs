// InMemorySettingsStoreTests.cs — new in Wave 3-B (A3: Local<->Cloud switch). Volatile store used
// by tests and by any composition root not yet wired to the disk-backed Volar.Data implementation.
using Volar.Domain;
using Xunit;

namespace Volar.Domain.Tests;

public class InMemorySettingsStoreTests
{
    [Fact]
    public void GetString_ReturnsNull_WhenKeyAbsent()
    {
        var store = new InMemorySettingsStore();

        Assert.Null(store.GetString("missing"));
    }

    [Fact]
    public void SetString_ThenGetString_RoundTrips()
    {
        var store = new InMemorySettingsStore();

        store.SetString("volar.parseProxyBaseURL", "https://example.supabase.co");

        Assert.Equal("https://example.supabase.co", store.GetString("volar.parseProxyBaseURL"));
    }

    [Fact]
    public void SetString_Null_RemovesTheKey()
    {
        var store = new InMemorySettingsStore();
        store.SetString("volar.parseProxyToken", "secret-token");

        store.SetString("volar.parseProxyToken", null);

        Assert.Null(store.GetString("volar.parseProxyToken"));
    }

    [Fact]
    public void GetBool_ReturnsDefault_WhenKeyAbsent()
    {
        var store = new InMemorySettingsStore();

        Assert.False(store.GetBool("volar.cloudParseConsent", false));
        Assert.True(store.GetBool("volar.cloudParseConsent", true));
    }

    [Fact]
    public void SetBool_ThenGetBool_RoundTrips()
    {
        var store = new InMemorySettingsStore();

        store.SetBool("volar.cloudParseConsent", true);

        Assert.True(store.GetBool("volar.cloudParseConsent", false));
    }

    [Fact]
    public void GetString_ReturnsNull_WhenKeyWasLastStoredAsBool()
    {
        // Type confusion guard: a key that was set via SetBool must not be silently reinterpreted
        // as a string (mirrors UserDefaults.string(forKey:) returning nil for a non-string value).
        var store = new InMemorySettingsStore();
        store.SetBool("volar.cloudParseConsent", true);

        Assert.Null(store.GetString("volar.cloudParseConsent"));
    }

    [Fact]
    public void GetBool_ReturnsDefault_WhenKeyWasLastStoredAsString()
    {
        var store = new InMemorySettingsStore();
        store.SetString("volar.parseProxyToken", "abc");

        Assert.False(store.GetBool("volar.parseProxyToken", false));
        Assert.True(store.GetBool("volar.parseProxyToken", true));
    }

    [Fact]
    public void SetString_OverwritesPreviousValue()
    {
        var store = new InMemorySettingsStore();
        store.SetString("k", "first");

        store.SetString("k", "second");

        Assert.Equal("second", store.GetString("k"));
    }

    [Fact]
    public void SetBool_OverwritesPreviousValue()
    {
        var store = new InMemorySettingsStore();
        store.SetBool("k", true);

        store.SetBool("k", false);

        Assert.False(store.GetBool("k", true));
    }

    [Fact]
    public void KeysAreCaseSensitive_LikeUserDefaults()
    {
        var store = new InMemorySettingsStore();
        store.SetString("volar.parseEngine", "cloud");

        Assert.Null(store.GetString("Volar.ParseEngine"));
    }
}
