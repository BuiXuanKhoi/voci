using Volar.App.Services.Adapters;
using Volar.Domain;
using Volar.Speech;
using Xunit;

namespace Volar.App.Tests.Adapters;

public class SpeechEngineChoiceStoreTests
{
    [Fact]
    public void Get_ReturnsDefault_WhenKeyAbsent()
    {
        var settings = new InMemorySettingsStore();

        Assert.Equal(SpeechEngineChoiceDefaults.Default, SpeechEngineChoiceStore.Get(settings));
    }

    [Fact]
    public void Get_ReturnsDefault_ForUnrecognizedRawValue()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(SpeechEngineChoiceStore.SpeechEngineKey, "appleOnDevice"); // Swift-only case

        Assert.Equal(SpeechEngineChoiceDefaults.Default, SpeechEngineChoiceStore.Get(settings));
    }

    [Theory]
    [InlineData(SpeechEngineChoice.WhisperOnDevice)]
    [InlineData(SpeechEngineChoice.GroqCloud)]
    public void SetThenGet_RoundTrips(SpeechEngineChoice choice)
    {
        var settings = new InMemorySettingsStore();

        SpeechEngineChoiceStore.Set(settings, choice);

        Assert.Equal(choice, SpeechEngineChoiceStore.Get(settings));
    }

    [Fact]
    public void Set_PersistsUnderTheDocumentedKey()
    {
        var settings = new InMemorySettingsStore();

        SpeechEngineChoiceStore.Set(settings, SpeechEngineChoice.GroqCloud);

        Assert.Equal("volar.speechEngine", SpeechEngineChoiceStore.SpeechEngineKey);
        Assert.NotNull(settings.GetString(SpeechEngineChoiceStore.SpeechEngineKey));
    }
}
