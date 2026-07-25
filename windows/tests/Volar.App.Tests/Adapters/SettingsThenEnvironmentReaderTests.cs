using Volar.App.Services.Adapters;
using Volar.Domain;
using Xunit;

namespace Volar.App.Tests.Adapters;

public class SettingsThenEnvironmentReaderTests
{
    [Fact]
    public void Read_PrefersSettings_OverEnvironment()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString("K", "from-settings");
        var reader = new SettingsThenEnvironmentReader(settings, _ => "from-env");

        Assert.Equal("from-settings", reader.Read("K"));
    }

    [Fact]
    public void Read_FallsBackToEnvironment_WhenSettingsAbsent()
    {
        var settings = new InMemorySettingsStore();
        var reader = new SettingsThenEnvironmentReader(settings, key => key == "K" ? "from-env" : null);

        Assert.Equal("from-env", reader.Read("K"));
    }

    [Fact]
    public void Read_ReturnsNull_WhenNeitherSourceHasIt()
    {
        var settings = new InMemorySettingsStore();
        var reader = new SettingsThenEnvironmentReader(settings, _ => null);

        Assert.Null(reader.Read("K"));
    }

    [Fact]
    public void Read_DefaultsToRealEnvironmentVariable_WhenNoReaderInjected()
    {
        var variableName = "VOLAR_TEST_" + Guid.NewGuid().ToString("N");
        Environment.SetEnvironmentVariable(variableName, "real-env-value");
        try
        {
            var reader = new SettingsThenEnvironmentReader(new InMemorySettingsStore());

            Assert.Equal("real-env-value", reader.Read(variableName));
        }
        finally
        {
            Environment.SetEnvironmentVariable(variableName, null);
        }
    }

    [Fact]
    public void AsFunc_IsBoundToTheSameInstance_AndBehavesIdenticallyToRead()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString("K", "value");
        var reader = new SettingsThenEnvironmentReader(settings, _ => null);

        Func<string, string?> asFunc = reader.AsFunc();

        Assert.Equal(reader.Read("K"), asFunc("K"));
    }

    [Fact]
    public void Read_TreatsEmptyStringInSettings_AsPresent_NotAbsent()
    {
        // Matches ISettingsStore.GetString's own "null only when truly absent" contract — an empty
        // string configured deliberately must not silently fall through to the environment.
        var settings = new InMemorySettingsStore();
        settings.SetString("K", "");
        var reader = new SettingsThenEnvironmentReader(settings, _ => "from-env");

        Assert.Equal("", reader.Read("K"));
    }
}
