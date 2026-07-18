// Groq/GroqModel.cs — ported from Sources/Speech/GroqTranscriptionClient.swift (GroqModel enum)
namespace Volar.Speech.Groq;

/// <summary>Groq Whisper models exposed at the OpenAI-compatible <c>/audio/transcriptions</c>
/// route. <see cref="LargeV3"/> is the accuracy primary (best vi/en code-switching per backlog);
/// <see cref="LargeV3Turbo"/> is the cheaper/faster fallback (~$0.04/hr audio, ~216x realtime).</summary>
public enum GroqModel
{
    LargeV3,
    LargeV3Turbo,
}

public static class GroqModelExtensions
{
    public static string ToApiValue(this GroqModel model) => model switch
    {
        GroqModel.LargeV3 => "whisper-large-v3",
        GroqModel.LargeV3Turbo => "whisper-large-v3-turbo",
        _ => throw new ArgumentOutOfRangeException(nameof(model), model, null),
    };
}
