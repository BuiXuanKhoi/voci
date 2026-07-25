using Xunit;

namespace Volar.Parsing.Tests;

public class OnnxSlmParserTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 20, 9, 0, 0, TimeSpan.Zero);

    [Fact]
    public void IsAvailable_DisabledByDefault_IsFalse_EvenWhenModelFileExists()
    {
        var modelPath = Path.GetTempFileName();
        try
        {
            var parser = new OnnxSlmParser(modelPath); // enabled defaults to false
            Assert.False(parser.IsAvailable);
        }
        finally
        {
            File.Delete(modelPath);
        }
    }

    [Fact]
    public void IsAvailable_EnabledButModelMissing_IsFalse()
    {
        var missingPath = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".onnx");
        var parser = new OnnxSlmParser(missingPath, enabled: true);

        Assert.False(parser.IsAvailable);
    }

    [Fact]
    public void IsAvailable_EnabledAndModelPresent_IsTrue()
    {
        var modelPath = Path.GetTempFileName();
        try
        {
            var parser = new OnnxSlmParser(modelPath, enabled: true);
            Assert.True(parser.IsAvailable);
        }
        finally
        {
            File.Delete(modelPath);
        }
    }

    [Fact]
    public async Task ParseAsync_Disabled_ReturnsEmpty_NeverThrows()
    {
        var parser = new OnnxSlmParser(Path.Combine(Path.GetTempPath(), "nope.onnx"));

        var result = await parser.ParseAsync("buy milk", Now, Array.Empty<string>());

        Assert.Empty(result);
    }

    [Fact]
    public async Task ParseAsync_EnabledButModelMissing_ReturnsEmpty_NeverThrows()
    {
        var missingPath = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".onnx");
        var parser = new OnnxSlmParser(missingPath, enabled: true);

        var result = await parser.ParseAsync("buy milk", Now, Array.Empty<string>());

        Assert.Empty(result);
    }

    [Fact]
    public async Task ParseAsync_EnabledAndModelPresent_StubStillReturnsEmpty_NeverThrows()
    {
        // Guarded stub (see class doc comment): even when structurally "available", the session body
        // is not wired to a real ONNX Runtime GenAI call yet, so it must still degrade to "no result"
        // rather than fabricate output or throw.
        var modelPath = Path.GetTempFileName();
        try
        {
            var parser = new OnnxSlmParser(modelPath, enabled: true);

            var result = await parser.ParseAsync("buy milk", Now, Array.Empty<string>());

            Assert.Empty(result);
        }
        finally
        {
            File.Delete(modelPath);
        }
    }

    [Fact]
    public async Task BreakdownAsync_Disabled_ReturnsEmpty_NeverThrows()
    {
        var parser = new OnnxSlmParser(Path.Combine(Path.GetTempPath(), "nope.onnx"));

        var result = await parser.BreakdownAsync("Plan a trip", null);

        Assert.Empty(result);
    }
}
