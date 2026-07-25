// Stubs/StubParsingAdapters.cs — minimal Wave-2 seam adapters for Volar.Parsing, wired into DI
// solely so the composition root's dependency graph resolves and the shell boots. None of these
// talk to real network/consent/settings state.
//
// TODO(W3-B): replace every type in this file with the real adapter:
//   - StubCloudParseGate       -> real consent + reachability check (Settings + NetworkInterface).
//   - StubParseCredentialProvider -> real StoreKit-equivalent/DeviceCheck-equivalent credential flow
//     (see docs/product-vision-v2.md "freemium speech + backend decision").
//   - StubSlmParser            -> real ONNX Runtime GenAI (Phi-4-mini) tier, or leave permanently
//     disabled if this port never ships an on-device SLM tier.
using System.Diagnostics;
using Volar.Parsing;

namespace Volar.App.Stubs;

/// <summary>Cloud tier permanently closed: never opted in, so <see cref="IntentRouter"/> always
/// falls through to Heuristic. Safe default until Settings/consent UI exists.</summary>
public sealed class StubCloudParseGate : ICloudParseGate
{
    public Task<bool> IsOptedInAsync(CancellationToken cancellationToken = default) => Task.FromResult(false);

    public Task<bool> IsOnlineAsync(CancellationToken cancellationToken = default) => Task.FromResult(true);
}

/// <summary>No credential ever available — matches <see cref="StubCloudParseGate"/> always
/// declining anyway, but implemented honestly (rather than "throw") so this type is safe to wire
/// up on its own if the gate is later replaced independently.</summary>
public sealed class StubParseCredentialProvider : IParseCredentialProvider
{
    public Task<Uri> GetBaseUrlAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(new Uri("https://example.invalid/"));

    public Task<ParseAuthHeader?> GetAuthHeaderAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<ParseAuthHeader?>(null);
}

/// <summary>SLM tier disabled by default (per this port's task brief: "default DISABLED").
/// <see cref="IntentRouter"/> skips this tier entirely whenever <see cref="IsAvailable"/> is
/// <see langword="false"/> — every other member is unreachable and only present to satisfy the
/// interface.</summary>
public sealed class StubSlmParser : ISlmParser
{
    public bool IsAvailable => false;

    public Task<IReadOnlyList<Volar.Domain.ParsedTask>> ParseAsync(
        string transcript,
        DateTimeOffset now,
        IReadOnlyList<string> openTaskTitles,
        CancellationToken cancellationToken = default)
    {
        Debug.WriteLine("[StubSlmParser] ParseAsync called despite IsAvailable=false — unreachable via IntentRouter.");
        return Task.FromResult<IReadOnlyList<Volar.Domain.ParsedTask>>(Array.Empty<Volar.Domain.ParsedTask>());
    }

    public Task<IReadOnlyList<string>> BreakdownAsync(
        string title, string? notes, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>());
}
