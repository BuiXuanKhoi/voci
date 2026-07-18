using Volar.Speech.Whisper;
using Xunit;

namespace Volar.Speech.Tests;

public class WhisperModelManagerTests
{
    private static string NewTempDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"volar-model-mgr-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        return dir;
    }

    [Fact]
    public void GetModelPath_UsesInjectedDirectory_NeverHardcoded()
    {
        var dir = NewTempDir();
        try
        {
            var manager = new WhisperModelManager(dir);

            var path = manager.GetModelPath(WhisperModelSize.Base);

            Assert.StartsWith(dir, path);
            Assert.EndsWith("ggml-base.bin", path);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void IsModelCached_ReturnsFalse_WhenFileAbsent()
    {
        var dir = NewTempDir();
        try
        {
            var manager = new WhisperModelManager(dir);
            Assert.False(manager.IsModelCached(WhisperModelSize.Base));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public async Task EnsureModelAsync_ReturnsExistingFile_WithoutDownloading_WhenAlreadyCached()
    {
        var dir = NewTempDir();
        try
        {
            var manager = new WhisperModelManager(dir);
            var expectedPath = manager.GetModelPath(WhisperModelSize.Base);
            await File.WriteAllBytesAsync(expectedPath, [9, 9, 9]);
            var warningFired = false;
            manager.OnIntegrityWarning += _ => warningFired = true;

            // Cache-hit branch returns before ever consulting the network downloader — this
            // completes near-instantly regardless of network availability, which is itself part
            // of what this test verifies (a network-dependent implementation would be slow/flaky
            // here; this one always finishes fast).
            var path = await manager.EnsureModelAsync(WhisperModelSize.Base).WaitAsync(TimeSpan.FromSeconds(2));

            Assert.Equal(expectedPath, path);
            Assert.Equal(new byte[] { 9, 9, 9 }, await File.ReadAllBytesAsync(path));
            Assert.False(warningFired, "the cache-hit path must not run checksum verification/warning logic at all");
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void IsModelCached_TrueAfterManualFileWrite_ForBothSizes()
    {
        var dir = NewTempDir();
        try
        {
            var manager = new WhisperModelManager(dir);
            File.WriteAllBytes(manager.GetModelPath(WhisperModelSize.Small), [1]);

            Assert.True(manager.IsModelCached(WhisperModelSize.Small));
            Assert.False(manager.IsModelCached(WhisperModelSize.Base));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
