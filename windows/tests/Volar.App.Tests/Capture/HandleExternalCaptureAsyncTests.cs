// Capture/HandleExternalCaptureAsyncTests.cs — Wave 4, Stage C task 8. Covers
// CaptureFlowService.HandleExternalCaptureAsync: the volar://capture?text= entry point Stage C wires
// AppLinkHandler.OnCapture to (see App.xaml.cs's WireAppLinkCapture and CaptureFlowService.cs's own
// doc comment on the method under test). Deliberately its own file (not appended to
// CaptureFlowServiceTests.cs) since it is Stage C's addition, layered on top of C3's original test
// file rather than editing it.
using Volar.App.Services.State;
using Volar.App.Tests.State;
using Volar.Core;
using Volar.Data;
using Volar.Domain;
using Xunit;

namespace Volar.App.Tests.Capture;

public sealed class HandleExternalCaptureAsyncTests
{
    private static readonly DateTimeOffset Now = CaptureTestData.Now;

    private sealed record Fixture(CaptureFlowService Service, FakeTaskListService TaskList, FakeIntentParser Parser);

    private static Fixture CreateService(FakeTaskListService? taskList = null, FakeIntentParser? parser = null)
    {
        var resolvedTaskList = taskList ?? new FakeTaskListService();
        var resolvedParser = parser ?? new FakeIntentParser();
        var provider = new FakeSpeechEngineProvider { SelectedEngine = new FakeSpeechEngine() };
        var service = new CaptureFlowService(
            resolvedTaskList,
            new RecordingEligibilityService(),
            resolvedParser,
            provider,
            new FixedTimeProvider(Now),
            new InMemorySettingsStore(),
            repository: null,
            scheduler: null,
            voice: null,
            delegationHandoff: null,
            timeZone: TimeZoneInfo.Utc);
        // Skip the one-time cloud-parse consent gate, same convention CaptureFlowServiceTests.cs's
        // own CreateService helper uses — this test cares about the external-entry seam, not the
        // consent gate (covered separately in CaptureFlowServiceTests.cs).
        service.SetParseEngine(Volar.Parsing.ParseEnginePreference.OnDevice);
        return new Fixture(service, resolvedTaskList, resolvedParser);
    }

    [Fact]
    public async Task HandleExternalCaptureAsync_FromIdle_ParsesAndProducesAConfirmDraft()
    {
        var (service, _, parser) = CreateService(
            parser: new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Buy milk", "buy milk") } });

        Assert.Equal(CaptureState.Idle, service.State);

        await service.HandleExternalCaptureAsync("buy milk");

        // Reused the exact same finish pipeline a real engine OnFinal would reach — RunParseAsync
        // (via FinishRecordingAsync -> ProceedToCaptureAsync) lands on .Parsed with one draft, never
        // bypassing the confirm card.
        Assert.Equal(CaptureState.Parsed, service.State);
        Assert.Single(service.ConfirmDrafts);
        Assert.Equal("Buy milk", service.ConfirmDrafts[0].Task.Title);
        Assert.Single(parser.ParseCalls);
        Assert.Equal("buy milk", parser.ParseCalls[0]);
        Assert.Equal("buy milk", service.Transcript);
    }

    [Fact]
    public async Task HandleExternalCaptureAsync_WhileAlreadyRecording_IsANoOp()
    {
        var (service, _, parser) = CreateService();
        await service.StartCaptureAsync();
        Assert.Equal(CaptureState.Recording, service.State);

        await service.HandleExternalCaptureAsync("some external text");

        // Never steals an in-flight capture — mirrors every other entry point's "no-op unless
        // preconditions hold" discipline (StopCaptureAsync's double-stop no-op, etc.).
        Assert.Equal(CaptureState.Recording, service.State);
        Assert.Empty(parser.ParseCalls);
    }

    [Fact]
    public async Task HandleExternalCaptureAsync_WhileParsing_IsANoOp()
    {
        var engine = new FakeSpeechEngine();
        var parser = new FakeIntentParser();
        var provider = new FakeSpeechEngineProvider { SelectedEngine = engine };
        var service = new CaptureFlowService(
            new FakeTaskListService(),
            new RecordingEligibilityService(),
            parser,
            provider,
            new FixedTimeProvider(Now),
            new InMemorySettingsStore(),
            repository: null,
            scheduler: null,
            voice: null,
            delegationHandoff: null,
            timeZone: TimeZoneInfo.Utc);
        service.SetParseEngine(Volar.Parsing.ParseEnginePreference.OnDevice);

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        Assert.Equal(CaptureState.Parsing, service.State);

        await service.HandleExternalCaptureAsync("some external text");

        Assert.Equal(CaptureState.Parsing, service.State);
        Assert.Empty(parser.ParseCalls);
    }

    [Fact]
    public async Task HandleExternalCaptureAsync_NoMatchingBatch_EntersErrorNotCrash()
    {
        var (service, _, _) = CreateService(parser: new FakeIntentParser { Result = Array.Empty<ParsedTask>() });

        await service.HandleExternalCaptureAsync("garbled nonsense");

        Assert.Equal(CaptureState.Error, service.State);
        Assert.Equal("Didn't catch that.", service.CaptureErrorDetail);
    }

    [Fact]
    public async Task HandleExternalCaptureAsync_RaisesCaptureChanged()
    {
        var (service, _, parser) = CreateService(
            parser: new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Buy milk", "buy milk") } });
        var changeCount = 0;
        service.CaptureChanged += () => changeCount++;

        await service.HandleExternalCaptureAsync("buy milk");

        Assert.True(changeCount >= 2); // at least the Parsing transition + the Parsed transition.
    }
}
