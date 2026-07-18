// GroqTranscriptionClientTests.cs — parses fixture JSON through a FakeHttpMessageHandler; never
// touches the real network (per the W1-D brief: "parse response Groq (dùng JSON mẫu, không gọi
// mạng thật)").
using System.Net;
using Volar.Speech.Groq;
using Xunit;

namespace Volar.Speech.Tests;

public class GroqTranscriptionClientTests
{
    private static readonly byte[] SampleAudio = [1, 2, 3, 4];

    private sealed class FixedCredentialProvider(string baseUrl = "https://fake.test/v1", string? authorization = "Bearer test-token")
        : IGroqCredentialProvider
    {
        public Task<Uri> GetBaseUrlAsync(CancellationToken cancellationToken = default) => Task.FromResult(new Uri(baseUrl));
        public Task<string?> GetAuthorizationAsync(CancellationToken cancellationToken = default) => Task.FromResult(authorization);
    }

    [Fact]
    public async Task TranscribeAsync_Success_ReturnsTrimmedText()
    {
        var handler = new FakeHttpMessageHandler(_ =>
            Task.FromResult(FakeHttpMessageHandler.Json(HttpStatusCode.OK, "{\"text\":\"  hello world  \"}")));
        var client = new GroqTranscriptionClient(new FixedCredentialProvider(), new HttpClient(handler));

        var text = await client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3);

        Assert.Equal("hello world", text);
        Assert.Equal(1, handler.RequestCount);
    }

    [Fact]
    public async Task TranscribeAsync_HttpError_ThrowsWithStatusAndBody()
    {
        var handler = new FakeHttpMessageHandler(_ =>
            Task.FromResult(FakeHttpMessageHandler.Json(HttpStatusCode.InternalServerError, "{\"error\":\"boom\"}")));
        var client = new GroqTranscriptionClient(new FixedCredentialProvider(), new HttpClient(handler));

        var ex = await Assert.ThrowsAsync<GroqTranscriptionException>(
            () => client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3));

        Assert.Equal(GroqTranscriptionErrorKind.Http, ex.Kind);
        Assert.Equal(500, ex.HttpStatus);
        Assert.Contains("boom", ex.HttpBody);
    }

    [Fact]
    public async Task TranscribeAsync_EmptyTranscript_Throws()
    {
        var handler = new FakeHttpMessageHandler(_ =>
            Task.FromResult(FakeHttpMessageHandler.Json(HttpStatusCode.OK, "{\"text\":\"   \"}")));
        var client = new GroqTranscriptionClient(new FixedCredentialProvider(), new HttpClient(handler));

        var ex = await Assert.ThrowsAsync<GroqTranscriptionException>(
            () => client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3));

        Assert.Equal(GroqTranscriptionErrorKind.EmptyTranscript, ex.Kind);
    }

    [Fact]
    public async Task TranscribeAsync_MalformedJson_ThrowsDecoding()
    {
        var handler = new FakeHttpMessageHandler(_ =>
            Task.FromResult(FakeHttpMessageHandler.Json(HttpStatusCode.OK, "{not json")));
        var client = new GroqTranscriptionClient(new FixedCredentialProvider(), new HttpClient(handler));

        var ex = await Assert.ThrowsAsync<GroqTranscriptionException>(
            () => client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3));

        Assert.Equal(GroqTranscriptionErrorKind.Decoding, ex.Kind);
    }

    [Fact]
    public async Task TranscribeAsync_MissingTextField_ThrowsDecoding()
    {
        // "text" absent entirely -> deserializes but the required field is missing/defaulted; the
        // client should treat this the same as malformed JSON, not crash with a NullReferenceException.
        var handler = new FakeHttpMessageHandler(_ =>
            Task.FromResult(FakeHttpMessageHandler.Json(HttpStatusCode.OK, "{\"other\":\"field\"}")));
        var client = new GroqTranscriptionClient(new FixedCredentialProvider(), new HttpClient(handler));

        var ex = await Assert.ThrowsAsync<GroqTranscriptionException>(
            () => client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3));

        Assert.Equal(GroqTranscriptionErrorKind.EmptyTranscript, ex.Kind); // "text" defaults to "" -> empty transcript
    }

    [Fact]
    public async Task TranscribeAsync_AudioTooLarge_ThrowsWithoutSendingRequest()
    {
        var handler = new FakeHttpMessageHandler(_ => throw new InvalidOperationException("must not be called"));
        var client = new GroqTranscriptionClient(new FixedCredentialProvider(), new HttpClient(handler)) { MaxAudioBytes = 2 };

        var ex = await Assert.ThrowsAsync<GroqTranscriptionException>(
            () => client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3));

        Assert.Equal(GroqTranscriptionErrorKind.AudioTooLarge, ex.Kind);
        Assert.Equal(0, handler.RequestCount);
    }

    [Fact]
    public async Task TranscribeAsync_MissingCredentials_PropagatesFromProvider()
    {
        var provider = new FixedCredentialProvider(authorization: null);
        var throwingProvider = new ThrowingAuthProvider();
        var handler = new FakeHttpMessageHandler(_ => throw new InvalidOperationException("must not be called"));
        var client = new GroqTranscriptionClient(throwingProvider, new HttpClient(handler));

        var ex = await Assert.ThrowsAsync<GroqTranscriptionException>(
            () => client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3));

        Assert.Equal(GroqTranscriptionErrorKind.MissingCredentials, ex.Kind);
        Assert.Equal(0, handler.RequestCount);
    }

    private sealed class ThrowingAuthProvider : IGroqCredentialProvider
    {
        public Task<Uri> GetBaseUrlAsync(CancellationToken cancellationToken = default) => Task.FromResult(new Uri("https://fake.test/v1"));
        public Task<string?> GetAuthorizationAsync(CancellationToken cancellationToken = default) => throw GroqTranscriptionException.MissingCredentials();
    }

    [Fact]
    public async Task TranscribeAsync_TransportFailure_WrapsAsNetworkError()
    {
        var handler = new FakeHttpMessageHandler(_ => throw new HttpRequestException("DNS lookup failed"));
        var client = new GroqTranscriptionClient(new FixedCredentialProvider(), new HttpClient(handler));

        var ex = await Assert.ThrowsAsync<GroqTranscriptionException>(
            () => client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3));

        Assert.Equal(GroqTranscriptionErrorKind.Network, ex.Kind);
    }

    [Fact]
    public async Task TranscribeAsync_Cancellation_ThrowsOperationCanceled()
    {
        // Pre-cancelled token -> deterministic (no timing race): HttpClient.SendAsync must observe
        // an already-cancelled token and throw before this ever reaches the fake handler.
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();
        var handler = new FakeHttpMessageHandler(_ =>
            throw new InvalidOperationException("must not be reached — cancellation should short-circuit first"));
        var client = new GroqTranscriptionClient(new FixedCredentialProvider(), new HttpClient(handler));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3, cts.Token));
    }

    [Fact]
    public async Task TranscribeAsync_SendsAuthorizationHeader_WhenProvided()
    {
        var handler = new FakeHttpMessageHandler(_ =>
            Task.FromResult(FakeHttpMessageHandler.Json(HttpStatusCode.OK, "{\"text\":\"ok\"}")));
        var client = new GroqTranscriptionClient(new FixedCredentialProvider(authorization: "Bearer secret-token"), new HttpClient(handler));

        await client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3);

        Assert.Equal("Bearer secret-token", handler.LastRequest!.Headers.GetValues("Authorization").Single());
    }

    [Fact]
    public async Task TranscribeAsync_OmitsAuthorizationHeader_WhenNull()
    {
        var handler = new FakeHttpMessageHandler(_ =>
            Task.FromResult(FakeHttpMessageHandler.Json(HttpStatusCode.OK, "{\"text\":\"ok\"}")));
        var client = new GroqTranscriptionClient(new FixedCredentialProvider(authorization: null), new HttpClient(handler));

        await client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3);

        Assert.False(handler.LastRequest!.Headers.Contains("Authorization"));
    }

    [Fact]
    public async Task TranscribeAsync_NeverSendsALanguageField()
    {
        // Regression guard for the deliberate "no language field -> Groq auto-detects" behavior
        // (vi/en code-switching). Reads the actual multipart body sent, not just a mock expectation.
        string? capturedBody = null;
        var handler = new FakeHttpMessageHandler(async req =>
        {
            // Must read the body HERE, inside the handler — GroqTranscriptionClient disposes its
            // request/content immediately after SendAsync returns, so reading it afterward throws
            // ObjectDisposedException.
            capturedBody = await req.Content!.ReadAsStringAsync();
            return FakeHttpMessageHandler.Json(HttpStatusCode.OK, "{\"text\":\"ok\"}");
        });
        var client = new GroqTranscriptionClient(new FixedCredentialProvider(), new HttpClient(handler));

        await client.TranscribeAsync(SampleAudio, "clip.wav", GroqModel.LargeV3);

        Assert.DoesNotContain("language", capturedBody, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("whisper-large-v3", capturedBody);
    }
}
