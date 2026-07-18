// Groq/GroqTranscriptionError.cs — ported from Sources/Speech/GroqTranscriptionClient.swift
namespace Volar.Speech.Groq;

/// <summary>Failure kind from the Groq transcription network layer — mirrors the Swift
/// <c>GroqTranscriptionError</c> enum's cases exactly (see <see cref="GroqTranscriptionException"/>
/// for the exception type carrying this).</summary>
public enum GroqTranscriptionErrorKind
{
    /// <summary>No endpoint credential available (proxy token / dev key). The engine surfaces this
    /// instead of sending an unauthenticated request.</summary>
    MissingCredentials,
    /// <summary>Recording exceeds Groq's per-request size limit — rejected before upload to avoid
    /// a certain 413.</summary>
    AudioTooLarge,
    /// <summary>Non-2xx HTTP response.</summary>
    Http,
    /// <summary>2xx but the JSON body couldn't be decoded into a transcript.</summary>
    Decoding,
    /// <summary>Transport-level failure (offline, DNS, TLS, timeout…).</summary>
    Network,
    /// <summary>Server returned an empty transcript (nothing recognized).</summary>
    EmptyTranscript,
}

/// <summary>Carries a <see cref="GroqTranscriptionErrorKind"/> plus the extra data each case
/// needs (audio byte count, HTTP status + body, network message) — the C# equivalent of Swift's
/// associated-value enum cases.</summary>
public sealed class GroqTranscriptionException : Exception
{
    public GroqTranscriptionErrorKind Kind { get; }
    public int? AudioBytes { get; }
    public int? HttpStatus { get; }
    public string? HttpBody { get; }

    private GroqTranscriptionException(GroqTranscriptionErrorKind kind, string message, int? audioBytes = null, int? httpStatus = null, string? httpBody = null)
        : base(message)
    {
        Kind = kind;
        AudioBytes = audioBytes;
        HttpStatus = httpStatus;
        HttpBody = httpBody;
    }

    public static GroqTranscriptionException MissingCredentials() =>
        new(GroqTranscriptionErrorKind.MissingCredentials, "No Groq credentials are configured.");

    public static GroqTranscriptionException AudioTooLarge(int bytes) =>
        new(GroqTranscriptionErrorKind.AudioTooLarge, $"Recording is too large to upload ({bytes} bytes).", audioBytes: bytes);

    /// <summary><paramref name="body"/> is the (truncated) server message for logging/diagnosis —
    /// callers must NOT log this verbatim if it could ever echo back user transcript content; Groq's
    /// error bodies are diagnostic JSON, not transcript text, so this is safe as-is.</summary>
    public static GroqTranscriptionException Http(int status, string body) =>
        new(GroqTranscriptionErrorKind.Http, $"Groq request failed (HTTP {status}).", httpStatus: status, httpBody: body);

    public static GroqTranscriptionException Decoding() =>
        new(GroqTranscriptionErrorKind.Decoding, "Couldn't read Groq's transcription response.");

    public static GroqTranscriptionException Network(string message) =>
        new(GroqTranscriptionErrorKind.Network, $"Network error talking to Groq: {message}");

    public static GroqTranscriptionException EmptyTranscript() =>
        new(GroqTranscriptionErrorKind.EmptyTranscript, "Nothing was recognized in the recording.");
}
