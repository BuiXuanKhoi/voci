using System.Net;
using System.Text.Json.Nodes;
using Xunit;

namespace Volar.Parsing.Tests;

public class CloudParserTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 20, 9, 30, 15, TimeSpan.Zero);

    private static HttpResponseMessage JsonResponse(int statusCode, string body)
        => new((HttpStatusCode)statusCode)
        {
            Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json")
        };

    // MARK: - Request shape (must match supabase/functions/_shared/schema.ts byte-for-byte)

    [Fact]
    public async Task ParseDetailedAsync_RequestBody_UsesExactWireFieldNames()
    {
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(200, "[]") };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        await parser.ParseDetailedAsync("buy milk", Now, new[] { "task A", "task B" });

        Assert.NotNull(handler.LastRequestBody);
        var node = JsonNode.Parse(handler.LastRequestBody!)!.AsObject();
        Assert.Equal("buy milk", node["transcript"]!.GetValue<string>());
        Assert.Equal("2026-07-20T09:30:15Z", node["now"]!.GetValue<string>());
        // Snake_case on the wire — matches _shared/schema.ts's `body.open_task_titles` read exactly,
        // NOT the camelCase `openTaskTitles` that appears only in the server's internal TS type name.
        Assert.True(node.ContainsKey("open_task_titles"));
        Assert.False(node.ContainsKey("openTaskTitles"));
        var titles = node["open_task_titles"]!.AsArray();
        Assert.Equal(2, titles.Count);
        Assert.Equal("task A", titles[0]!.GetValue<string>());
    }

    [Fact]
    public async Task ParseDetailedAsync_NoOpenTaskTitles_OmitsFieldEntirely()
    {
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(200, "[]") };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        var node = JsonNode.Parse(handler.LastRequestBody!)!.AsObject();
        Assert.False(node.ContainsKey("open_task_titles"));
    }

    [Fact]
    public async Task ParseDetailedAsync_TranscriptOverCap_TruncatedClientSide()
    {
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(200, "[]") };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler)) { MaxTranscriptChars = 10 };

        await parser.ParseDetailedAsync("this transcript is definitely longer than ten characters", Now, Array.Empty<string>());

        var node = JsonNode.Parse(handler.LastRequestBody!)!.AsObject();
        Assert.Equal("this trans", node["transcript"]!.GetValue<string>());
    }

    [Fact]
    public async Task ParseDetailedAsync_PaidJws_SetsAuthorizationBearerHeader()
    {
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(200, "[]") };
        var credentials = new FakeCredentialProvider { AuthHeader = new ParseAuthHeader.PaidJws("jws-token-123") };
        var parser = new CloudParser(credentials, new HttpClient(handler));

        await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        Assert.Equal("Bearer", handler.LastRequest!.Headers.Authorization!.Scheme);
        Assert.Equal("jws-token-123", handler.LastRequest.Headers.Authorization!.Parameter);
    }

    [Fact]
    public async Task ParseDetailedAsync_FreeDeviceToken_SetsDeviceTokenHeader()
    {
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(200, "[]") };
        var credentials = new FakeCredentialProvider { AuthHeader = new ParseAuthHeader.FreeDeviceToken("device-abc") };
        var parser = new CloudParser(credentials, new HttpClient(handler));

        await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        Assert.True(handler.LastRequest!.Headers.TryGetValues("X-Device-Token", out var values));
        Assert.Equal("device-abc", values!.Single());
        Assert.Null(handler.LastRequest.Headers.Authorization);
    }

    [Fact]
    public async Task ParseDetailedAsync_RequestUrl_AppendsFunctionsV1Parse()
    {
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(200, "[]") };
        var credentials = new FakeCredentialProvider { BaseUrl = new Uri("https://proj.supabase.co") };
        var parser = new CloudParser(credentials, new HttpClient(handler));

        await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        Assert.Equal("https://proj.supabase.co/functions/v1/parse", handler.LastRequest!.RequestUri!.ToString());
    }

    // MARK: - No credential -> never sends a request

    [Fact]
    public async Task ParseDetailedAsync_NoAuthHeader_ReturnsUnavailable_NeverCallsNetwork()
    {
        var handler = new RecordingHttpMessageHandler();
        var credentials = new FakeCredentialProvider { AuthHeader = null };
        var parser = new CloudParser(credentials, new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        Assert.IsType<CloudParseOutcome.Unavailable>(outcome);
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task ParseDetailedAsync_BaseUrlThrows_ReturnsUnavailable()
    {
        var handler = new RecordingHttpMessageHandler();
        var credentials = new FakeCredentialProvider { ThrowOnBaseUrl = true };
        var parser = new CloudParser(credentials, new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        Assert.IsType<CloudParseOutcome.Unavailable>(outcome);
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task ParseDetailedAsync_EmptyTranscript_ReturnsUnavailable_NeverCallsNetwork()
    {
        var handler = new RecordingHttpMessageHandler();
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("   ", Now, Array.Empty<string>());

        Assert.IsType<CloudParseOutcome.Unavailable>(outcome);
        Assert.Equal(0, handler.CallCount);
    }

    // MARK: - Response parsing (schema.ts ParsedTaskOut wire shape, camelCase)

    [Fact]
    public async Task ParseDetailedAsync_200_DecodesFullShape()
    {
        const string body = """
        [
          {
            "title": {"value": "Call the dentist", "confidence": 0.95},
            "notes": {"value": "reschedule cleaning", "confidence": 0.7},
            "deadline": {"value": "2026-07-21T15:00:00Z", "confidence": 0.8},
            "estimateMinutes": {"value": 15, "confidence": 0.6},
            "priority": {"value": 2, "confidence": 0.75},
            "recurrence": {"value": {"type": "weekly"}, "confidence": 0.7},
            "reminderOverride": {"value": {"offsetsMinutes": [-60, 0], "repeatEveryMinutes": 30}, "confidence": 0.65},
            "conditions": [{"value": {"kind": "external", "description": "waiting for callback"}, "confidence": 0.6}],
            "kind": {"value": "review", "confidence": 0.5},
            "subtasks": [{"title": {"value": "find number", "confidence": 0.5}, "estimateMinutes": {"value": 5, "confidence": 0.4}}],
            "followUpReview": {"value": true, "confidence": 0.5}
          }
        ]
        """;
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(200, body) };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("call the dentist weekly", Now, Array.Empty<string>());

        var tasks = Assert.IsType<CloudParseOutcome.Tasks>(outcome).Value;
        var task = Assert.Single(tasks);
        Assert.Equal("Call the dentist", task.Title);
        Assert.Equal("reschedule cleaning", task.Notes);
        Assert.Equal(new DateTimeOffset(2026, 7, 21, 15, 0, 0, TimeSpan.Zero), task.Deadline!.Value.Value);
        Assert.Equal(15, task.EstimateMinutes!.Value.Value);
        Assert.Equal(2, task.Priority!.Value.Value);
        Assert.IsType<Domain.Recurrence.Weekly>(task.Recurrence!.Value.Value);
        Assert.Equal(2, task.ReminderOverride!.Value.Value.Offsets.Count);
        Assert.Equal(TimeSpan.FromMinutes(30), task.ReminderOverride.Value.Value.RepeatEvery);
        var condition = Assert.Single(task.Conditions);
        var external = Assert.IsType<Domain.ParsedCondition.External>(condition);
        Assert.Equal("waiting for callback", external.Description);
        Assert.Equal(Domain.TaskKind.Review, task.Kind);
        Assert.Equal(new[] { "find number" }, task.Subtasks);
        Assert.True(task.FollowUpReview);
    }

    [Fact]
    public async Task ParseDetailedAsync_200_EmptyArray_ReturnsUnavailable()
    {
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(200, "[]") };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        Assert.IsType<CloudParseOutcome.Unavailable>(outcome);
    }

    [Fact]
    public async Task ParseDetailedAsync_200_MalformedJson_ReturnsUnavailable()
    {
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(200, "not json") };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        Assert.IsType<CloudParseOutcome.Unavailable>(outcome);
    }

    [Fact]
    public async Task ParseDetailedAsync_200_MissingRequiredTitle_ReturnsUnavailable()
    {
        var handler = new RecordingHttpMessageHandler
        {
            ResponseFactory = _ => JsonResponse(200, """[{"notes": {"value": "x", "confidence": 0.5}}]""")
        };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        Assert.IsType<CloudParseOutcome.Unavailable>(outcome);
    }

    [Fact]
    public async Task ParseDetailedAsync_200_MoreThan10Tasks_CappedTo10()
    {
        var tasksJson = string.Join(",", Enumerable.Range(0, 15)
            .Select(i => $$$"""{"title": {"value": "task {{{i}}}", "confidence": 0.9}}"""));
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(200, $"[{tasksJson}]") };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("many tasks", Now, Array.Empty<string>());

        var tasks = Assert.IsType<CloudParseOutcome.Tasks>(outcome).Value;
        Assert.Equal(10, tasks.Count);
    }

    [Fact]
    public async Task ParseDetailedAsync_ResponseTooLarge_ReturnsUnavailable()
    {
        var hugeTitle = new string('a', 300);
        var body = $$$"""[{"title": {"value": "{{{hugeTitle}}}", "confidence": 0.9}}]""";
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(200, body) };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler)) { MaxResponseBytes = 50 };

        var outcome = await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        Assert.IsType<CloudParseOutcome.Unavailable>(outcome);
    }

    // MARK: - Status codes

    [Fact]
    public async Task ParseDetailedAsync_429_ReturnsQuotaExceeded_WithResetAt()
    {
        var handler = new RecordingHttpMessageHandler
        {
            ResponseFactory = _ => JsonResponse(429, """{"reason":"quota","resetAt":"2026-07-21T00:00:00Z"}""")
        };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        var quota = Assert.IsType<CloudParseOutcome.QuotaExceeded>(outcome);
        Assert.Equal(new DateTimeOffset(2026, 7, 21, 0, 0, 0, TimeSpan.Zero), quota.ResetAt);
    }

    [Fact]
    public async Task ParseDetailedAsync_429_MalformedBody_ReturnsQuotaExceeded_WithNullResetAt()
    {
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(429, "not json") };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        var quota = Assert.IsType<CloudParseOutcome.QuotaExceeded>(outcome);
        Assert.Null(quota.ResetAt);
    }

    [Theory]
    [InlineData(401)]
    [InlineData(403)]
    [InlineData(500)]
    [InlineData(502)]
    [InlineData(503)]
    public async Task ParseDetailedAsync_NonSuccessStatus_ReturnsUnavailable(int statusCode)
    {
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(statusCode, "{}") };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        Assert.IsType<CloudParseOutcome.Unavailable>(outcome);
    }

    [Fact]
    public async Task ParseDetailedAsync_TransportFailure_ReturnsUnavailable()
    {
        var handler = new RecordingHttpMessageHandler
        {
            ResponseFactory = _ => throw new HttpRequestException("offline")
        };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var outcome = await parser.ParseDetailedAsync("buy milk", Now, Array.Empty<string>());

        Assert.IsType<CloudParseOutcome.Unavailable>(outcome);
    }

    // MARK: - IIntentParser conformance surface

    [Fact]
    public async Task ParseAsync_ViaIIntentParser_ReturnsSameTasksAsParseDetailedAsync()
    {
        var handler = new RecordingHttpMessageHandler
        {
            ResponseFactory = _ => JsonResponse(200, """[{"title": {"value": "T", "confidence": 0.9}}]""")
        };
        IIntentParser parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var tasks = await parser.ParseAsync("buy milk", Now, Array.Empty<string>());

        Assert.Single(tasks);
        Assert.Equal("T", tasks[0].Title);
    }

    [Fact]
    public async Task ParseAsync_ViaIIntentParser_QuotaOrUnavailable_ReturnsEmptyNeverThrows()
    {
        var handler = new RecordingHttpMessageHandler { ResponseFactory = _ => JsonResponse(429, "{}") };
        IIntentParser parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var tasks = await parser.ParseAsync("buy milk", Now, Array.Empty<string>());

        Assert.Empty(tasks);
    }

    // MARK: - Breakdown mode

    [Fact]
    public async Task BreakdownDetailedAsync_RequestBody_UsesSnakeCaseTaskTitle()
    {
        var handler = new RecordingHttpMessageHandler
        {
            ResponseFactory = _ => JsonResponse(200, """{"steps":[{"title":"a","estimateMinutes":10},{"title":"b","estimateMinutes":10},{"title":"c","estimateMinutes":10}]}""")
        };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        await parser.BreakdownDetailedAsync("Plan a trip", "some notes");

        var node = JsonNode.Parse(handler.LastRequestBody!)!.AsObject();
        Assert.Equal("breakdown", node["mode"]!.GetValue<string>());
        Assert.Equal("Plan a trip", node["task_title"]!.GetValue<string>());
        Assert.Equal("some notes", node["notes"]!.GetValue<string>());
        Assert.False(node.ContainsKey("taskTitle"));
    }

    [Fact]
    public async Task BreakdownDetailedAsync_200_ValidStepCount_ReturnsSteps()
    {
        var handler = new RecordingHttpMessageHandler
        {
            ResponseFactory = _ => JsonResponse(200, """{"steps":[{"title":"a","estimateMinutes":10},{"title":"b","estimateMinutes":10},{"title":"c","estimateMinutes":10}]}""")
        };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var steps = await parser.BreakdownDetailedAsync("Plan a trip", null);

        Assert.Equal(new[] { "a", "b", "c" }, steps);
    }

    [Fact]
    public async Task BreakdownDetailedAsync_200_TooFewSteps_ReturnsNull()
    {
        var handler = new RecordingHttpMessageHandler
        {
            ResponseFactory = _ => JsonResponse(200, """{"steps":[{"title":"a","estimateMinutes":10}]}""")
        };
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var steps = await parser.BreakdownDetailedAsync("Plan a trip", null);

        Assert.Null(steps);
    }

    [Fact]
    public async Task BreakdownDetailedAsync_EmptyTitle_ReturnsNull_NeverCallsNetwork()
    {
        var handler = new RecordingHttpMessageHandler();
        var parser = new CloudParser(new FakeCredentialProvider(), new HttpClient(handler));

        var steps = await parser.BreakdownDetailedAsync("   ", null);

        Assert.Null(steps);
        Assert.Equal(0, handler.CallCount);
    }
}
