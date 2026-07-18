// Whisper/WhisperModelSize.cs — GGML model-size choice for the on-device engine.
//
// Ported concept from Sources/Speech/WhisperKitEngine.swift's "Model" doc comment: mac defaults to
// "base" (~145MB) rather than "small" (~480MB) to honor the backlog's "keep the free tier light"
// call, while noting "small" is a meaningfully better English-accuracy option if that tradeoff is
// ever revisited. Same default kept here for the Windows/whisper.cpp GGML equivalent.
using Whisper.net.Ggml;

namespace Volar.Speech.Whisper;

/// <summary>Small, stable wrapper around <see cref="GgmlType"/> exposing only the sizes Volar
/// actually offers in Settings, so the rest of the app doesn't take a direct dependency on the
/// Whisper.net.Ggml enum shape.</summary>
public enum WhisperModelSize
{
    /// <summary>~148 MB (ggml-base.bin). DEFAULT — matches the mac free-tier default.</summary>
    Base,
    /// <summary>~488 MB (ggml-small.bin). Meaningfully better accuracy, especially non-English —
    /// offered as an opt-in per the mac doc comment's tradeoff note.</summary>
    Small,
}

internal static class WhisperModelSizeExtensions
{
    public static GgmlType ToGgmlType(this WhisperModelSize size) => size switch
    {
        WhisperModelSize.Base => GgmlType.Base,
        WhisperModelSize.Small => GgmlType.Small,
        _ => throw new ArgumentOutOfRangeException(nameof(size), size, null),
    };

    /// <summary>File name Whisper.net's downloader/GGML convention uses for this model — needed so
    /// <see cref="WhisperModelManager"/> can name the cached file on disk without downloading it
    /// first just to find out.</summary>
    public static string GgmlFileName(this WhisperModelSize size) => size switch
    {
        WhisperModelSize.Base => "ggml-base.bin",
        WhisperModelSize.Small => "ggml-small.bin",
        _ => throw new ArgumentOutOfRangeException(nameof(size), size, null),
    };
}
