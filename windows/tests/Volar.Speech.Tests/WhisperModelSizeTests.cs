using Whisper.net.Ggml;
using Volar.Speech.Whisper;
using Xunit;

namespace Volar.Speech.Tests;

public class WhisperModelSizeTests
{
    [Theory]
    [InlineData(WhisperModelSize.Base, GgmlType.Base, "ggml-base.bin")]
    [InlineData(WhisperModelSize.Small, GgmlType.Small, "ggml-small.bin")]
    public void MapsToExpectedGgmlTypeAndFileName(WhisperModelSize size, GgmlType expectedType, string expectedFileName)
    {
        Assert.Equal(expectedType, size.ToGgmlType());
        Assert.Equal(expectedFileName, size.GgmlFileName());
    }
}
