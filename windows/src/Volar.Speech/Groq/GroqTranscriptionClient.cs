// Groq/GroqTranscriptionClient.cs — ported from Sources/Speech/GroqTranscriptionClient.swift
// Pure network layer for Groq Speech-to-Text — no NAudio, no engine state — unit-testable by
// injecting an HttpClient with a fake HttpMessageHandler. Language is deliberately omitted from
// the request so Groq auto-detects the spoken language (required for vi/en code-switching).
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Volar.Speech.Groq;

public sealed partial class GroqTranscriptionClient
{
    // SECURITY (per W1-D brief): reuse one HttpClient instance for the process lifetime rather
    // than `new HttpClient()` per call, which would exhaust sockets under load (well-known .NET
    // pitfall). Used only when the caller doesn't inject its own HttpClient/IHttpClientFactory
    // handle — e.g. the future WinUI 3 app should inject an `IHttpClientFactory`-created client
    // instead of relying on this static fallback.
    private static readonly Lazy<HttpClient> SharedHttpClient = new(() => new HttpClient());

    private readonly IGroqCredentialProvider _credentials;
    private readonly HttpClient _httpClient;

    /// <summary>Reject recordings past Groq's documented free-tier limit (25 MB) before
    /// uploading.</summary>
    public int MaxAudioBytes { get; init; } = 25 * 1024 * 1024;

    public GroqTranscriptionClient(IGroqCredentialProvider credentials, HttpClient? httpClient = null)
    {
        _credentials = credentials;
        _httpClient = httpClient ?? SharedHttpClient.Value;
    }

    public async Task<string> TranscribeAsync(byte[] audio, string filename, GroqModel model, CancellationToken cancellationToken = default)
    {
        if (audio.Length > MaxAudioBytes)
        {
            throw GroqTranscriptionException.AudioTooLarge(audio.Length);
        }

        var baseUrl = await _credentials.GetBaseUrlAsync(cancellationToken).ConfigureAwait(false);
        var authorization = await _credentials.GetAuthorizationAsync(cancellationToken).ConfigureAwait(false);
        var requestUri = new Uri(baseUrl, "audio/transcriptions");

        using var content = new MultipartFormDataContent
        {
            { new StringContent(model.ToApiValue()), "model" },
            { new StringContent("json"), "response_format" },
            // NO "language" part on purpose -> Groq auto-detects (vi/en code-switching, backlog).
        };
        var audioContent = new ByteArrayContent(audio);
        audioContent.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        content.Add(audioContent, "file", filename);

        using var request = new HttpRequestMessage(HttpMethod.Post, requestUri) { Content = content };
        if (authorization is not null)
        {
            request.Headers.TryAddWithoutValidation("Authorization", authorization);
        }

        HttpResponseMessage response;
        try
        {
            response = await _httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw GroqTranscriptionException.Network(ex.Message);
        }

        using (response)
        {
            var bodyBytes = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                var bodyText = System.Text.Encoding.UTF8.GetString(bodyBytes, 0, Math.Min(bodyBytes.Length, 2000));
                throw GroqTranscriptionException.Http((int)response.StatusCode, bodyText);
            }

            GroqTranscriptionResponse? decoded;
            try
            {
                decoded = JsonSerializer.Deserialize(bodyBytes, GroqJsonContext.Default.GroqTranscriptionResponse);
            }
            catch (JsonException)
            {
                throw GroqTranscriptionException.Decoding();
            }
            if (decoded is null)
            {
                throw GroqTranscriptionException.Decoding();
            }

            var text = decoded.Text.Trim();
            if (text.Length == 0)
            {
                throw GroqTranscriptionException.EmptyTranscript();
            }
            return text;
        }
    }

    private sealed class GroqTranscriptionResponse
    {
        [JsonPropertyName("text")]
        public string Text { get; set; } = "";
    }

    [JsonSerializable(typeof(GroqTranscriptionResponse))]
    private partial class GroqJsonContext : JsonSerializerContext;
}
