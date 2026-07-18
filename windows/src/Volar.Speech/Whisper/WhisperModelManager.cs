// Whisper/WhisperModelManager.cs — on-demand GGML model download/cache for Whisper.net.
//
// No mac equivalent file (WhisperKit downloads its CoreML model internally on first use — see
// WhisperKitEngine.swift's "Model download / readiness" doc comment). This is new plumbing needed
// because Whisper.net does NOT auto-download; the caller must fetch the GGML weights and hand
// WhisperFactory a local path. Per the W1-D brief: model directory is an injected parameter (never
// hardcoded), the model is fetched on demand rather than bundled in the installer, and download
// progress is reported so Settings can show "Downloading model…".
using System.Security.Cryptography;
using Whisper.net.Ggml;

namespace Volar.Speech.Whisper;

/// <summary>Download progress for a model fetch. <see cref="BytesRead"/>/<see cref="TotalBytes"/>
/// may be unknown (<c>null</c> <see cref="TotalBytes"/>) if the server doesn't report
/// Content-Length; UI should fall back to an indeterminate spinner in that case.</summary>
public readonly record struct WhisperModelDownloadProgress(long BytesRead, long? TotalBytes)
{
    public double? FractionComplete => TotalBytes is > 0 ? (double)BytesRead / TotalBytes.Value : null;
}

/// <summary>
/// Resolves a <see cref="WhisperModelSize"/> to a local GGML file path, downloading it into an
/// injected cache directory the first time it's needed and reusing it after. Idempotent and safe
/// to call every time a caller wants to make sure a model is ready (mirrors
/// `WhisperKitEngine.prepare()`'s "idempotent, second call while ready is a no-op" contract).
/// </summary>
public sealed class WhisperModelManager
{
    private readonly string _modelDirectory;

    /// <summary>Optional expected SHA-256 (lowercase hex) per <see cref="WhisperModelSize"/>, used
    /// to verify a freshly-downloaded file. NOT pre-populated: whisper.cpp's own official
    /// `download-ggml-model.sh` does not publish/verify checksums for these files either (only
    /// relies on HTTPS + Hugging Face hosting), and this agent could not obtain a verified-trustworthy
    /// SHA-256 for each model file in this session. Left as an injection point — anh Khôi should
    /// populate this from Hugging Face's file-integrity metadata (the "SHA256" column shown on each
    /// file's page at https://huggingface.co/ggerganov/whisper.cpp/tree/main) before shipping, if
    /// checksum verification is required. Until populated, downloads proceed unverified (HTTPS
    /// transport integrity only) and this is logged via <see cref="OnIntegrityWarning"/>.</summary>
    public IReadOnlyDictionary<WhisperModelSize, string> ExpectedSha256 { get; init; } =
        new Dictionary<WhisperModelSize, string>();

    /// <summary>Fires with a human-readable message whenever a download completes without a known
    /// checksum to verify against, or when verification fails.</summary>
    public event Action<string>? OnIntegrityWarning;

    /// <param name="modelDirectory">Where GGML files are cached. Injected — never hardcoded — so
    /// callers/tests control it. Typical production value:
    /// <c>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Volar", "models")</c>.</param>
    public WhisperModelManager(string modelDirectory)
    {
        _modelDirectory = modelDirectory;
    }

    /// <summary>Absolute path a given model's GGML file would live at, whether or not it has been
    /// downloaded yet.</summary>
    public string GetModelPath(WhisperModelSize size) => Path.Combine(_modelDirectory, size.GgmlFileName());

    public bool IsModelCached(WhisperModelSize size) => File.Exists(GetModelPath(size));

    /// <summary>Ensures the model file exists locally, downloading it if necessary, and returns its
    /// path. Downloads to a <c>.partial</c> sibling file first and only renames it into place on
    /// success, so a crash/cancel mid-download can never leave a corrupt file mistaken for a
    /// complete one on the next launch.</summary>
    public async Task<string> EnsureModelAsync(
        WhisperModelSize size,
        IProgress<WhisperModelDownloadProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(_modelDirectory);
        var finalPath = GetModelPath(size);
        if (File.Exists(finalPath))
        {
            return finalPath;
        }

        var partialPath = finalPath + ".partial";
        using (var downloadStream = await WhisperGgmlDownloader.Default
                   .GetGgmlModelAsync(size.ToGgmlType(), QuantizationType.NoQuantization, cancellationToken)
                   .ConfigureAwait(false))
        await using (var fileStream = new FileStream(partialPath, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            await CopyWithProgressAsync(downloadStream, fileStream, progress, cancellationToken).ConfigureAwait(false);
        }

        if (ExpectedSha256.TryGetValue(size, out var expectedHash))
        {
            var actualHash = await ComputeSha256Async(partialPath, cancellationToken).ConfigureAwait(false);
            if (!string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase))
            {
                File.Delete(partialPath);
                throw new InvalidOperationException(
                    $"Downloaded model '{size}' failed checksum verification (expected {expectedHash}, got {actualHash}).");
            }
        }
        else
        {
            OnIntegrityWarning?.Invoke(
                $"No known checksum configured for model '{size}' — downloaded file was NOT integrity-verified.");
        }

        File.Move(partialPath, finalPath, overwrite: true);
        return finalPath;
    }

    private static async Task CopyWithProgressAsync(
        Stream source, Stream destination, IProgress<WhisperModelDownloadProgress>? progress, CancellationToken cancellationToken)
    {
        long? totalBytes = source.CanSeek ? source.Length : null;
        var buffer = new byte[81920];
        long totalRead = 0;
        int read;
        while ((read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
        {
            await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            totalRead += read;
            progress?.Report(new WhisperModelDownloadProgress(totalRead, totalBytes));
        }
    }

    private static async Task<string> ComputeSha256Async(string path, CancellationToken cancellationToken)
    {
        await using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
        return Convert.ToHexStringLower(hash);
    }
}
