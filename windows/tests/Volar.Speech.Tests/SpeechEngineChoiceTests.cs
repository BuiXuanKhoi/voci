// SpeechEngineChoiceTests.cs — Wave 3-B (A3: Local<->Cloud switch, macOS commit f88d5e5).
using Xunit;

namespace Volar.Speech.Tests;

public class SpeechEngineChoiceTests
{
    [Fact]
    public void HasExactlyTwoCases_NoAppleOnDeviceEquivalent()
    {
        var values = Enum.GetValues<SpeechEngineChoice>();

        Assert.Equal(2, values.Length);
        Assert.Contains(SpeechEngineChoice.WhisperOnDevice, values);
        Assert.Contains(SpeechEngineChoice.GroqCloud, values);
    }

    [Fact]
    public void Default_IsWhisperOnDevice()
    {
        Assert.Equal(SpeechEngineChoice.WhisperOnDevice, SpeechEngineChoiceDefaults.Default);
    }
}
