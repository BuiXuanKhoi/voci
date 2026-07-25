// Volar.Parsing/OnnxSlmParser.cs — local on-device SLM parsing tier. Plays the ROLE of
// Sources/Parsing/FoundationModelParser.swift (on-device intent parsing) on Windows; it is NOT an
// API port of that file, since Apple's FoundationModels framework (macOS 26+, Apple Silicon only)
// has no Windows equivalent. Target model per this port's task brief: Phi-4-mini via
// Microsoft.ML.OnnxRuntimeGenAI.
using Volar.Domain;

namespace Volar.Parsing;

/// <summary>An <see cref="IIntentParser"/> tier that additionally reports whether it's actually usable right now.</summary>
/// <remarks>
/// Mirrors the shape of Swift's <c>FoundationModelParser.makeIfAvailable()</c> capability probe:
/// <see cref="IntentRouter"/> selects this tier purely by <see cref="IsAvailable"/>, never by
/// re-deriving availability itself.
/// </remarks>
public interface ISlmParser : IIntentParser
{
    /// <summary>
    /// <see langword="true"/> only when the tier is explicitly enabled AND its model is actually
    /// present. <see cref="IntentRouter"/> skips this tier entirely (no call, no exception) whenever
    /// this is <see langword="false"/>.
    /// </summary>
    bool IsAvailable { get; }
}

/// <summary>
/// Local ONNX Runtime GenAI SLM parser tier (target model: Phi-4-mini). Default DISABLED per this
/// port's task brief — the router must skip this tier unless explicitly enabled AND the model file is
/// present, and must never throw when disabled/missing.
/// </summary>
/// <remarks>
/// <para>
/// <b>STATUS — guarded stub, flagged for lead review.</b> The task brief asked for a reference to
/// <c>Microsoft.ML.OnnxRuntimeGenAI</c> wired to a real generation session. This port does NOT add
/// that NuGet package: this project (<c>Volar.Parsing</c>) builds with
/// <c>TreatWarningsAsErrors=true</c> and is a dependency of every other porting wave's tests; pulling
/// in an unverified native-interop package (this environment cannot verify the real GenAI C# API
/// surface — no docs/SDK access here) risked breaking the build for everyone downstream, for a tier
/// that is default-disabled anyway. The brief explicitly permits this fallback: "If the ONNX NuGet
/// causes build friction, implement the interface + a guarded stub that reports 'model not
/// downloaded'... but still wire the interface cleanly" — that is exactly what this class does.
/// </para>
/// <para>
/// The PUBLIC SHAPE is final and safe to build <see cref="IntentRouter"/> against today: constructor
/// options, <see cref="IsAvailable"/> gating (enabled flag AND <see cref="File.Exists(string?)"/> on
/// the model path), and "return empty, never throw" on every failure path, exactly mirroring
/// <c>FoundationModelParser.parse</c>'s catch-all-and-return-empty behavior. Only the body of
/// <see cref="RunParseSessionAsync"/>/<see cref="RunBreakdownSessionAsync"/> needs replacing with a
/// real GenAI session call once the package is verified/added — see backlog.md.
/// </para>
/// <para>
/// Because <see cref="IsAvailable"/> is <see langword="false"/> by default (the <c>enabled</c>
/// constructor parameter defaults to <see langword="false"/>), <see cref="IntentRouter"/> never
/// invokes this class at all out of the box — identical, from the router's perspective, to "model not
/// downloaded" on any platform.
/// </para>
/// </remarks>
public sealed class OnnxSlmParser : ISlmParser
{
    private readonly string _modelPath;
    private readonly bool _enabled;

    /// <param name="modelPath">Path to the on-device model file/directory (e.g. a Phi-4-mini ONNX export).</param>
    /// <param name="enabled">
    /// Explicit opt-in switch, independent of <paramref name="modelPath"/>'s existence. Defaults to
    /// <see langword="false"/> — this tier is off by default per the task brief.
    /// </param>
    public OnnxSlmParser(string modelPath, bool enabled = false)
    {
        _modelPath = modelPath ?? throw new ArgumentNullException(nameof(modelPath));
        _enabled = enabled;
    }

    public bool IsAvailable => _enabled && File.Exists(_modelPath);

    public async Task<IReadOnlyList<ParsedTask>> ParseAsync(
        string transcript,
        DateTimeOffset now,
        IReadOnlyList<string> openTaskTitles,
        CancellationToken cancellationToken = default)
    {
        if (!IsAvailable)
        {
            return Array.Empty<ParsedTask>();
        }
        try
        {
            var raws = await RunParseSessionAsync(transcript, now, openTaskTitles, cancellationToken).ConfigureAwait(false);
            if (raws.Count == 0)
            {
                return Array.Empty<ParsedTask>();
            }
            var capped = raws.Take(IntentRouter.MaxTaskCap).ToArray();
            return ParsedTaskValidation.ValidateAll(capped, transcript);
        }
        catch
        {
            // Any SLM failure (session error, generation timeout, decode mismatch) -> empty result.
            // IntentRouter falls through to the next tier. Never crash, never execute/persist a
            // partially-generated raw object — matches FoundationModelParser.parse's catch block.
            return Array.Empty<ParsedTask>();
        }
    }

    public async Task<IReadOnlyList<string>> BreakdownAsync(
        string title, string? notes, CancellationToken cancellationToken = default)
    {
        if (!IsAvailable)
        {
            return Array.Empty<string>();
        }
        try
        {
            var steps = await RunBreakdownSessionAsync(title, notes, cancellationToken).ConfigureAwait(false);
            return IntentRouter.IsValidBreakdown(steps) ? steps : Array.Empty<string>();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }

    /// <summary>
    /// TODO(real ONNX wiring, tracked in backlog.md): replace this guarded stub with an actual
    /// <c>Microsoft.ML.OnnxRuntimeGenAI</c> generation session against the model at
    /// <see cref="_modelPath"/>, prompted analogously to
    /// <c>FoundationModelParser.runParseSession</c>/<c>buildParsePrompt</c> in the Swift source, then
    /// mapped into <see cref="RawParsedTask"/> the way <c>FoundationModelParser.toRaw</c> does.
    /// Currently unreachable in practice because <see cref="IsAvailable"/> is <see langword="false"/>
    /// whenever <c>enabled</c> is <see langword="false"/> (the default) — this body only runs if a
    /// caller manually constructs this class with <c>enabled: true</c> AND a model file actually
    /// exists at <c>modelPath</c>, in which case it still reports "no result" rather than fabricating
    /// output.
    /// </summary>
    private Task<IReadOnlyList<RawParsedTask>> RunParseSessionAsync(
        string transcript, DateTimeOffset now, IReadOnlyList<string> openTaskTitles, CancellationToken cancellationToken)
        => Task.FromResult<IReadOnlyList<RawParsedTask>>(Array.Empty<RawParsedTask>());

    /// <summary>TODO(real ONNX wiring, tracked in backlog.md): see <see cref="RunParseSessionAsync"/>.</summary>
    private Task<IReadOnlyList<string>> RunBreakdownSessionAsync(
        string title, string? notes, CancellationToken cancellationToken)
        => Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>());
}
