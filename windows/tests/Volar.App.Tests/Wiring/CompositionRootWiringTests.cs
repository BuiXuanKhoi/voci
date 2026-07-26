// Wiring/CompositionRootWiringTests.cs — Wave 3-C stage 3 (agent C5), the three tests the wave's
// contract requires by name (specs/003-windows-port/wave3c-services.md's "Stage 3" section + the
// task brief's "Required tests"): (1) EligibilityAndResurfaceService.TaskList is wired, (2) the
// IDelegationHandoff seam actually reaches DelegationOrchestratorService, (3) every interface
// CompositionRoot registers resolves without throwing. Every test builds the REAL graph via
// CompositionRoot.Build() (not a hand-rolled fake graph) — that is the whole point of a wiring test.
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Volar.App.Services;
using Volar.App.Services.Adapters;
using Volar.App.Services.State;
using Volar.Data;
using Volar.Domain;
using Volar.Orchestrator;
using Volar.Parsing;
using Volar.Reminders;
using Volar.Speech;
using Volar.Speech.Audio;
using Volar.Speech.Groq;
using Volar.Speech.Playback;
using Volar.Speech.Whisper;
using Xunit;

namespace Volar.App.Tests.Wiring;

public sealed class CompositionRootWiringTests
{
    /// <summary>
    /// Required test 1. EligibilityAndResurfaceService.cs's own doc comment: "a null TaskList here
    /// is tolerated by design ... but tolerated must not mean invisible" — an unwired graph means
    /// resurface is armed for NO tasks (FIX 2's exact failure mode). This test is the guard against
    /// that ever shipping unnoticed.
    /// </summary>
    [Fact]
    public void Build_WiresEligibilityAndResurfaceServiceTaskListBackReference()
    {
        using var env = new WiringTestEnvironment();
        var provider = CompositionRoot.Build(env.Options);

        var eligibility = Assert.IsType<EligibilityAndResurfaceService>(
            provider.GetRequiredService<IEligibilityAndResurfaceService>());
        var taskList = provider.GetRequiredService<ITaskListService>();

        Assert.NotNull(eligibility.TaskList);
        Assert.Same(taskList, eligibility.TaskList);
    }

    /// <summary>
    /// Required test 2. C3's CaptureFlowService.cs declares IDelegationHandoff and logs-and-continues
    /// when it is null (RouteDelegateActionAsync's own doc comment) — an unwired graph passes
    /// silently otherwise, exactly the failure mode wave3c-services.md's "Opus review notes from
    /// stage 2" flags this agent as owing a regression test for.
    ///
    /// Driving this end-to-end through CaptureFlowService's own public surface would require a real
    /// microphone + a downloaded Whisper model (StartCaptureAsync -&gt; ISpeechEngine.OnFinal -&gt;
    /// FinishRecordingAsync -&gt; ... -&gt; ConfirmVoiceDoneAsync), which is not available in a
    /// hermetic unit test. Instead: resolve CaptureFlowService from the real provider (proves it is
    /// part of the graph and constructed successfully with whatever CompositionRoot wired into it),
    /// then resolve IDelegationHandoff from the SAME provider — CompositionRoot registers that
    /// interface as the literal same singleton instance it passes into CaptureFlowService's
    /// constructor, so this is not a stand-in; it is the exact object CaptureFlowService holds
    /// internally. Driving it directly and asserting the effect lands in the real
    /// DelegationOrchestratorService/DelegationTracker proves the adapter seam actually connects the
    /// two services C3 and C4 could not wire to each other themselves.
    /// </summary>
    [Fact]
    public async Task Build_DelegationHandoffReachesDelegationOrchestratorService()
    {
        using var env = new WiringTestEnvironment();
        var provider = CompositionRoot.Build(env.Options);

        // Proves CaptureFlowService itself resolves as part of the real graph (a missing/incorrect
        // constructor wire-up here would throw at Build() time already, since construction is manual
        // — see CompositionRoot.cs's header comment — but resolving it again here documents the
        // intent literally, per this wave's required-test wording).
        Assert.NotNull(provider.GetRequiredService<CaptureFlowService>());

        var handoff = provider.GetRequiredService<IDelegationHandoff>();
        var orchestrator = provider.GetRequiredService<DelegationOrchestratorService>();
        var taskList = provider.GetRequiredService<ITaskListService>();

        var task = new TaskItem(Guid.NewGuid(), "Delegate me", Priority.Medium, When.Now, DateTimeOffset.UtcNow);
        await taskList.AddAsync(task);
        Assert.Equal(0, orchestrator.WipCount());

        await handoff.DelegateAsync(task.Id, label: "Claude", checkBackMinutes: 10);

        Assert.Equal(1, orchestrator.WipCount());
    }

    /// <summary>
    /// Required test 3. Every interface (and every concrete singleton the shell/tests need to
    /// resolve directly) CompositionRoot registers must resolve without throwing. Listed explicitly
    /// rather than reflecting over the ServiceCollection — Build() only returns the built
    /// IServiceProvider, not the collection, and an explicit list doubles as documentation of
    /// exactly what this composition root promises to provide.
    /// </summary>
    [Fact]
    public void Build_ResolvesEveryRegisteredServiceWithoutThrowing()
    {
        using var env = new WiringTestEnvironment();
        var provider = CompositionRoot.Build(env.Options);

        Type[] registered =
        [
            typeof(ITimeProvider),
            typeof(ISettingsStore),
            typeof(JsonFileSettingsStore),
            typeof(IDbContextFactory<VolarDbContext>),
            typeof(TaskRepository),
            typeof(IReminderRecordStore),

            typeof(ReminderContextGate),
            typeof(VoicePlayback),
            typeof(IToastChannel),
            typeof(IReminderTaskStore),
            typeof(ReminderScheduler),
            typeof(IReminderSettingsProvider),
            typeof(ReminderAndDeliverySettingsService),

            typeof(IEligibilityAndResurfaceService),
            typeof(ITaskListService),

            typeof(IOrchestratorTaskStore),
            typeof(IDelegationMetaStore),
            typeof(IEditorTransport),
            typeof(EditorConnector),
            typeof(DelegationTracker),
            typeof(AppLinkHandler),
            typeof(DelegationOrchestratorService),
            typeof(IDelegationHandoff),

            typeof(Volar.App.Services.Account.IAccountService),
            typeof(Volar.App.Services.Account.AccountService),

            typeof(ICloudParseGate),
            typeof(IParseCredentialProvider),
            typeof(ISlmParser),
            typeof(HeuristicIntentParser),
            typeof(CloudParser),
            typeof(IIntentParser),

            typeof(IAudioCaptureService),
            typeof(WhisperModelManager),
            typeof(WhisperNetEngine),
            typeof(SettingsThenEnvironmentReader),
            typeof(IGroqCredentialProvider),
            typeof(GroqTranscriptionClient),
            typeof(GroqEngine),
            typeof(ISpeechEngineProvider),
            typeof(SpeechEngineService),

            typeof(CaptureFlowService),
            typeof(FocusSessionService),
            typeof(TriageAndSweepService),
            typeof(AppearanceAndPersistenceService),

            typeof(UriSchemeRegistrar),
            typeof(HotkeyService),
        ];

        foreach (var type in registered)
        {
            var resolved = provider.GetService(type);
            Assert.True(resolved is not null, $"{type.FullName} did not resolve from the real CompositionRoot graph.");
        }
    }
}
