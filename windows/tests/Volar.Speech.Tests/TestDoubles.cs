// TestDoubles.cs — fakes for the hardware/network-touching seams, per the W1-D brief: "Phần chạm
// phần cứng (mic, hook, mạng) không unit-test được — hãy đặt sau interface và test bằng
// fake/mock." Nothing in this file ever opens a real microphone, installs a real keyboard hook, or
// makes a real network call.
using System.Net;
using Volar.Speech.Audio;

namespace Volar.Speech.Tests;

/// <summary>Fakes <see cref="IAudioCaptureService"/> so <see cref="Volar.Speech.Groq.GroqEngine"/>
/// and <see cref="Volar.Speech.Whisper.WhisperNetEngine"/> can be unit-tested without a real
/// microphone.</summary>
internal sealed class FakeAudioCaptureService : IAudioCaptureService
{
    public int StartCallCount { get; private set; }
    public int CancelCallCount { get; private set; }
    public bool DisposeCalled { get; private set; }

    public bool IsRunning { get; private set; }
    public TimeSpan? MaxDuration { get; set; }
    public event Action<Exception>? OnError;

    /// <summary>What <see cref="StopAsync"/> returns/throws next. Set by the test before calling
    /// Stop() on the engine under test.</summary>
    public Func<CancellationToken, Task<string>>? StopBehavior { get; set; }

    public Task<bool> RequestAuthorizationAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(true);

    public void Start()
    {
        StartCallCount++;
        IsRunning = true;
    }

    public Task<string> StopAsync(CancellationToken cancellationToken = default)
    {
        IsRunning = false;
        return StopBehavior?.Invoke(cancellationToken)
               ?? throw new InvalidOperationException("Test did not configure StopBehavior.");
    }

    public void Cancel()
    {
        CancelCallCount++;
        IsRunning = false;
    }

    public void RaiseError(Exception ex) => OnError?.Invoke(ex);

    public void Dispose() => DisposeCalled = true;
}

/// <summary>Fakes <see cref="HttpMessageHandler"/> so <see cref="Volar.Speech.Groq.GroqTranscriptionClient"/>
/// can be unit-tested without a real network call. Records the last request for assertions (e.g.
/// "was the Authorization header set", "was a request even sent").</summary>
internal sealed class FakeHttpMessageHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
{
    public int RequestCount { get; private set; }
    public HttpRequestMessage? LastRequest { get; private set; }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        RequestCount++;
        LastRequest = request;
        cancellationToken.ThrowIfCancellationRequested();
        return await respond(request).ConfigureAwait(false);
    }

    public static HttpResponseMessage Json(HttpStatusCode status, string json) => new(status)
    {
        Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json"),
    };
}
