// WhisperNetEngineTests.cs — exercises WhisperNetEngine's session/lifecycle state machine against
// a FakeAudioCaptureService. Deliberately never downloads a real GGML model over the network for
// the "happy path" tests (per the brief: no real hardware/network in unit tests) — the one test
// that does touch WhisperModelManager only exercises its cache-HIT path, which never calls the
// network downloader (see WhisperModelManagerTests.cs for that guarantee's own direct test).
using Volar.Speech.Whisper;
using Xunit;

namespace Volar.Speech.Tests;

public class WhisperNetEngineTests
{
    /// <summary>Points a <see cref="WhisperModelManager"/> at a path that is already a plain FILE
    /// (not a directory) — `EnsureModelAsync`'s very first step, `Directory.CreateDirectory(...)`,
    /// then throws `IOException` ("cannot create ... because a file ... already exists") before
    /// ever reaching a cache check OR the network downloader. This is what lets
    /// `WhisperNetEngine.PrepareAsync` reach `EngineState.Failed` deterministically and without any
    /// network access. (An earlier version of this helper pre-seeded a garbage GGML file instead,
    /// expecting `WhisperFactory.FromPath` to reject it — it did not: Whisper.net's `FromPath`
    /// does not eagerly validate the file, so that approach did not actually exercise the failure
    /// path. This blocks earlier, in `WhisperModelManager` itself, which is reliable.)</summary>
    private static WhisperModelManager MakeManagerThatCannotCreateItsDirectory(out string blockingFilePath)
    {
        blockingFilePath = Path.Combine(Path.GetTempPath(), $"volar-whisper-blocker-{Guid.NewGuid():N}");
        File.WriteAllBytes(blockingFilePath, [0]);
        return new WhisperModelManager(blockingFilePath);
    }

    [Fact]
    public void Start_WhenAlreadyRunning_DoesNotRestartCapture()
    {
        var capture = new FakeAudioCaptureService();
        var engine = new WhisperNetEngine(new WhisperModelManager(Path.GetTempPath()), captureService: capture);

        engine.Start();
        engine.Start();

        Assert.Equal(1, capture.StartCallCount);
        Assert.True(engine.IsRunning);
    }

    [Fact]
    public void Stop_WhenNotRunning_DoesNothing()
    {
        var capture = new FakeAudioCaptureService();
        var engine = new WhisperNetEngine(new WhisperModelManager(Path.GetTempPath()), captureService: capture);
        var fired = false;
        engine.OnFinal += _ => fired = true;
        engine.OnError += _ => fired = true;

        engine.Stop();

        Assert.False(fired);
    }

    [Fact]
    public async Task Stop_WithoutPreparedModel_RaisesOnError()
    {
        var wavPath = Path.Combine(Path.GetTempPath(), $"volar-test-{Guid.NewGuid():N}.wav");
        await File.WriteAllBytesAsync(wavPath, [1, 2, 3]);
        var capture = new FakeAudioCaptureService { StopBehavior = _ => Task.FromResult(wavPath) };
        var engine = new WhisperNetEngine(new WhisperModelManager(Path.GetTempPath()), captureService: capture);
        var tcs = new TaskCompletionSource<Exception>();
        engine.OnError += ex => tcs.TrySetResult(ex);
        engine.OnFinal += text => tcs.TrySetException(new Exception($"unexpected success: {text}"));

        engine.Start();
        engine.Stop();
        var error = await tcs.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.IsType<InvalidOperationException>(error);
        Assert.Contains("PrepareAsync", error.Message);
    }

    [Fact]
    public void Cancel_DelegatesToCaptureService()
    {
        var capture = new FakeAudioCaptureService();
        var engine = new WhisperNetEngine(new WhisperModelManager(Path.GetTempPath()), captureService: capture);

        engine.Start();
        engine.Cancel();

        Assert.Equal(1, capture.CancelCallCount);
        Assert.False(engine.IsRunning);
    }

    [Fact]
    public async Task RequestAuthorizationAsync_DelegatesToCaptureService()
    {
        var capture = new FakeAudioCaptureService();
        var engine = new WhisperNetEngine(new WhisperModelManager(Path.GetTempPath()), captureService: capture);

        Assert.True(await engine.RequestAuthorizationAsync());
    }

    [Fact]
    public void InitialState_IsNotReady()
    {
        var engine = new WhisperNetEngine(new WhisperModelManager(Path.GetTempPath()));

        Assert.Equal(WhisperNetEngine.EngineState.NotReady, engine.State);
        Assert.False(engine.IsModelReady);
    }

    [Fact]
    public async Task PrepareAsync_ModelDirectoryUnavailable_TransitionsToFailed_WithoutTouchingNetwork()
    {
        var manager = MakeManagerThatCannotCreateItsDirectory(out var blockingFilePath);
        try
        {
            var engine = new WhisperNetEngine(manager);

            await engine.PrepareAsync();

            Assert.Equal(WhisperNetEngine.EngineState.Failed, engine.State);
            Assert.False(engine.IsModelReady);
            Assert.False(string.IsNullOrEmpty(engine.FailureReason));
        }
        finally
        {
            File.Delete(blockingFilePath);
        }
    }

    [Fact]
    public async Task PrepareAsync_AfterFailure_RetriesRatherThanStayingStuck()
    {
        // Swift's WhisperKitEngine.prepare() only short-circuits while `.preparing`/`.ready` —
        // `.notReady`/`.failed` both fall through and attempt again. Verifies the Windows port
        // kept that "Failed is retryable, not terminal" contract rather than silently going
        // idempotent-forever on the first failure.
        var manager = MakeManagerThatCannotCreateItsDirectory(out var blockingFilePath);
        try
        {
            var engine = new WhisperNetEngine(manager);

            await engine.PrepareAsync();
            Assert.Equal(WhisperNetEngine.EngineState.Failed, engine.State);

            await engine.PrepareAsync(); // must not throw / must not be a permanently-broken no-op
            Assert.Equal(WhisperNetEngine.EngineState.Failed, engine.State);
        }
        finally
        {
            File.Delete(blockingFilePath);
        }
    }
}
