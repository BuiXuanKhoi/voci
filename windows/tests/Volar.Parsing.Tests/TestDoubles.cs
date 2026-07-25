// Shared test doubles for Volar.Parsing.Tests.
using System.Net;
using Volar.Domain;

namespace Volar.Parsing.Tests;

/// <summary>Configurable <see cref="IIntentParser"/> stand-in for the heuristic tier.</summary>
internal sealed class FakeIntentParser : IIntentParser
{
    public int ParseCallCount { get; private set; }
    public int BreakdownCallCount { get; private set; }
    public IReadOnlyList<ParsedTask> ParseResult { get; set; } = Array.Empty<ParsedTask>();
    public IReadOnlyList<string> BreakdownResult { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string>? LastOpenTaskTitles { get; private set; }

    public Task<IReadOnlyList<ParsedTask>> ParseAsync(
        string transcript, DateTimeOffset now, IReadOnlyList<string> openTaskTitles, CancellationToken cancellationToken = default)
    {
        ParseCallCount++;
        LastOpenTaskTitles = openTaskTitles;
        return Task.FromResult(ParseResult);
    }

    public Task<IReadOnlyList<string>> BreakdownAsync(
        string title, string? notes, CancellationToken cancellationToken = default)
    {
        BreakdownCallCount++;
        return Task.FromResult(BreakdownResult);
    }
}

/// <summary>Configurable <see cref="ISlmParser"/> stand-in.</summary>
internal sealed class FakeSlmParser : ISlmParser
{
    public bool IsAvailable { get; set; }
    public int ParseCallCount { get; private set; }
    public int BreakdownCallCount { get; private set; }
    public IReadOnlyList<ParsedTask> ParseResult { get; set; } = Array.Empty<ParsedTask>();
    public IReadOnlyList<string> BreakdownResult { get; set; } = Array.Empty<string>();

    public Task<IReadOnlyList<ParsedTask>> ParseAsync(
        string transcript, DateTimeOffset now, IReadOnlyList<string> openTaskTitles, CancellationToken cancellationToken = default)
    {
        ParseCallCount++;
        return Task.FromResult(ParseResult);
    }

    public Task<IReadOnlyList<string>> BreakdownAsync(
        string title, string? notes, CancellationToken cancellationToken = default)
    {
        BreakdownCallCount++;
        return Task.FromResult(BreakdownResult);
    }
}

/// <summary>Configurable <see cref="ICloudParseGate"/> stand-in.</summary>
internal sealed class FakeCloudParseGate : ICloudParseGate
{
    public bool OptedIn { get; set; } = true;
    public bool Online { get; set; } = true;

    public Task<bool> IsOptedInAsync(CancellationToken cancellationToken = default) => Task.FromResult(OptedIn);

    public Task<bool> IsOnlineAsync(CancellationToken cancellationToken = default) => Task.FromResult(Online);
}

/// <summary>Configurable <see cref="IParseCredentialProvider"/> stand-in.</summary>
internal sealed class FakeCredentialProvider : IParseCredentialProvider
{
    public Uri BaseUrl { get; set; } = new("https://example.supabase.co");
    public ParseAuthHeader? AuthHeader { get; set; } = new ParseAuthHeader.FreeDeviceToken("stub-device-token");
    public bool ThrowOnBaseUrl { get; set; }

    public Task<Uri> GetBaseUrlAsync(CancellationToken cancellationToken = default)
        => ThrowOnBaseUrl ? throw new InvalidOperationException("no base url configured") : Task.FromResult(BaseUrl);

    public Task<ParseAuthHeader?> GetAuthHeaderAsync(CancellationToken cancellationToken = default)
        => Task.FromResult(AuthHeader);
}

/// <summary>
/// Records the last outgoing request and returns a scripted response — lets CloudParser tests assert
/// on exact request shape (headers, body) without a real network call.
/// </summary>
internal sealed class RecordingHttpMessageHandler : HttpMessageHandler
{
    public HttpRequestMessage? LastRequest { get; private set; }
    public string? LastRequestBody { get; private set; }
    public Func<HttpRequestMessage, HttpResponseMessage> ResponseFactory { get; set; }
        = _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("[]") };
    public int CallCount { get; private set; }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        CallCount++;
        LastRequest = request;
        LastRequestBody = request.Content is null
            ? null
            : await request.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        return ResponseFactory(request);
    }
}
