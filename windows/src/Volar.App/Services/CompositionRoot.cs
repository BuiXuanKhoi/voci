// Services/CompositionRoot.cs — builds the app's single IServiceProvider (App.Services). Wave 3-C
// stage 3 (agent C5): replaces every Stubs/* placeholder with the real service graph decided across
// this wave — specs/003-windows-port/wave3c-services.md's "Stage 3: C5" section, plus the "Opus
// review notes from stage 1/2" binding on this agent by name. Read that file before touching this
// one; every constructor call below cites the file it is wiring.
//
// CONSTRUCTION IS MANUAL, NOT CONTAINER-RESOLVED, for the interdependent Wave-3-C service graph.
// Two genuine constructor cycles exist in this graph and neither owning agent could resolve them
// inside their own file (both are documented, binding constraints from this wave's contract):
//   1. IEligibilityAndResurfaceService.TaskList is late-bound (C2's own doc comment on that
//      property): EligibilityAndResurfaceService needs a live ITaskListService reference to re-read
//      the task list when a resurface wake fires, but TaskListService's constructor needs a
//      constructed IEligibilityAndResurfaceService. Broken by constructing the eligibility service
//      first, then TaskListService, then assigning `eligibility.TaskList = taskListService`
//      afterward — exactly the sequence C2's doc comment prescribes for whoever wires this (this
//      agent). A wiring test below pins that this assignment actually happens.
//   2. ReminderScheduler needs a constructed IReminderSettingsProvider; C4's
//      ReminderAndDeliverySettingsService — the real implementation — needs a constructed
//      ITaskListService (to power OfferRescheduleForOverdueTasks); TaskListService's reminder
//      side-effects need a constructed ReminderScheduler to actually schedule/cancel anything (its
//      `scheduler` constructor parameter is optional, but the backing field is read-only, so a
//      *real* scheduler must exist BEFORE TaskListService is built or every task-CRUD reminder
//      side-effect silently no-ops for the rest of the process's life — a correctness regression,
//      not a style choice). Neither C4's nor C2's file may be edited to add a late-bound seam like
//      #1's, so this file breaks the cycle itself with LateBoundReminderSettingsProvider (below): a
//      tiny local IReminderSettingsProvider proxy constructed first and handed to ReminderScheduler,
//      whose Inner is assigned to the real ReminderAndDeliverySettingsService once IT is
//      constructable. Nothing calls into the scheduler during this construction window, so the
//      proxy's "not wired yet" fallback (matching Volar.Reminders' own DefaultReminderSettingsProvider
//      default) is never actually observed in practice.
//
// Every finished object is registered into the DI container via the AddSingleton(instance) overload
// rather than a `services.AddSingleton<T>(sp => new T(...))` factory chain — the ordering above is
// exactly what a container's own constructor-injection resolution cannot express for these two
// cycles, so this file resolves the graph by hand and only uses the container as the FINAL lookup
// table Wave 4/tests read from. This also means a construction-time failure (bad DB path, corrupt
// settings file that somehow throws, ...) surfaces immediately from Build() itself, not later on
// first resolve — consistent with "the parameterless default must behave exactly as production."
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
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

namespace Volar.App.Services;

/// <summary>
/// Optional overrides so <c>Build()</c> can run hermetically in a test process — every field
/// defaults to whatever production would use (<see langword="null"/>/<see langword="false"/> means
/// "use the real default"), so <c>Build(null)</c> and <c>Build()</c> are always identical to
/// production. CompositionRoot otherwise touches real <c>%LocalAppData%</c> (database, settings
/// file, delegation-meta file) and real <c>HKCU</c> (the <c>volar://</c> registration) — tests MUST
/// supply <see cref="DatabasePath"/>/<see cref="SettingsFilePath"/>/<see cref="DelegationMetaFilePath"/>
/// pointed at a disposable temp location and set <see cref="SkipRegistryRegistration"/> so no test
/// run ever writes to the real machine state.
/// </summary>
public sealed class CompositionRootOptions
{
    public string? DatabasePath { get; init; }

    public string? SettingsFilePath { get; init; }

    public string? DelegationMetaFilePath { get; init; }

    /// <summary>When <see langword="true"/>, skips the one HKCU write this file makes
    /// (<see cref="UriSchemeRegistrar.EnsureRegistered"/>). Never set outside a test.</summary>
    public bool SkipRegistryRegistration { get; init; }

    /// <summary>Test-only override for <see cref="AppNotificationToastChannel"/>'s real gateway
    /// (<see cref="WinAppSdkNotificationGateway"/>). That type's constructor touches
    /// <c>Microsoft.Windows.AppNotifications.AppNotificationManager.Default</c>, which requires the
    /// Windows App SDK bootstrapper to have already initialized — a real running WinUI app process
    /// does this automatically, but a plain unit-test host process never does, so constructing it
    /// there throws <see cref="System.Runtime.InteropServices.COMException"/> (REGDB_E_CLASSNOTREG).
    /// Tests MUST supply a fake <see cref="INativeAppNotificationGateway"/> here — exactly the seam
    /// <c>AppNotificationToastChannel.cs</c>'s own header comment calls out ("TESTABILITY SEAM" —
    /// public specifically so a composition root/test can construct one). Production leaves this
    /// <see langword="null"/>, which defaults to the real gateway.</summary>
    public INativeAppNotificationGateway? ToastGateway { get; init; }
}

public static class CompositionRoot
{
    public static IServiceProvider Build(CompositionRootOptions? options = null)
    {
        options ??= new CompositionRootOptions();
        var services = new ServiceCollection();

        // --- Cross-cutting: clock, settings ---------------------------------------------------
        ITimeProvider clock = new SystemTimeProvider();

        var settingsPath = options.SettingsFilePath ?? JsonFileSettingsStore.GetDefaultSettingsPath();
        Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)!);
        var settingsStore = new JsonFileSettingsStore(settingsPath);

        // --- Volar.Data --------------------------------------------------------------------
        // Composition-root-only Environment/AppData read, per VolarDbPaths.cs's own doc comment
        // ("only the App composition root should call this").
        var dbPath = options.DatabasePath ?? VolarDbPaths.GetDefaultDatabasePath();
        Directory.CreateDirectory(Path.GetDirectoryName(dbPath)!);
        var dbContextFactory = VolarDbContextFactory.ForFile(dbPath);

        // Migrate (not EnsureCreated) — this is now the real production graph, not a "prove SQLite
        // opens" shell, and EF's migration-history table only exists on a Migrate()'d database. Every
        // other project in this solution (SqliteFixture, Volar.Data.Tests) already uses Migrate();
        // EnsureCreated() here would leave a schema Migrate() could never be safely run against later.
        using (var context = dbContextFactory.CreateDbContext())
        {
            context.Database.Migrate();
        }

        var taskRepository = new TaskRepository(dbContextFactory);
        var reminderRecordRepository = new ReminderRecordRepository(dbContextFactory); // IReminderRecordStore

        // --- Volar.Reminders (cycle #2 — see file header) -------------------------------------
        var reminderContextGate = new ReminderContextGate();
        var voice = new VoicePlayback();
        var toastChannel = new AppNotificationToastChannel(voice, gateway: options.ToastGateway); // IToastChannel
        var reminderTaskStoreAdapter = new ReminderTaskStoreAdapter(taskRepository); // IReminderTaskStore
        var reminderSettingsProxy = new LateBoundReminderSettingsProvider();
        var reminderScheduler = new ReminderScheduler(
            store: reminderTaskStoreAdapter,
            channel: toastChannel,
            gate: reminderContextGate,
            settings: reminderSettingsProxy,
            timeZone: TimeZoneInfo.Local,
            recordStore: reminderRecordRepository);

        // WG-C parity: ReminderScheduler.HandleAction's own doc comment says a notification action
        // mutates the task store directly, bypassing ITaskListService, and that "Wave 3's app shell
        // must observe store mutations itself after calling into this method" — the C# equivalent of
        // macOS's `.volarTasksDidChange` NotificationCenter pair (appstate-inventory.md §6.1/§5.1).
        // Wired here (not App.xaml.cs) so it holds regardless of which shell entry point is active.
        toastChannel.ActionInvoked += (actionId, recordId) =>
        {
            try
            {
                reminderScheduler.HandleAction(actionId, recordId, clock.Now);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[Volar.App.Services.CompositionRoot] HandleAction failed: {ex.GetType().Name}");
            }
        };

        // --- Cycle #1: eligibility <-> task list ----------------------------------------------
        var eligibility = new EligibilityAndResurfaceService(clock, reminderScheduler); // IEligibilityAndResurfaceService
        var taskListService = new TaskListService(eligibility, clock, taskRepository, reminderScheduler, TimeZoneInfo.Local); // ITaskListService
        eligibility.TaskList = taskListService; // closes cycle #1 — required, see EligibilityAndResurfaceService.cs's own doc comment.

        // A store mutation made from ReminderScheduler.HandleAction (above) must still flow back
        // through the single owner of task state (decision 5) once it fires — completes the WG-C
        // wiring started above now that taskListService exists.
        toastChannel.ActionInvoked += (_, _) => { _ = taskListService.RefreshAsync(); };

        // --- Closes cycle #2: the real settings provider now that taskListService exists ------
        var reminderAndDeliverySettingsService = new ReminderAndDeliverySettingsService(settingsStore, taskListService, reminderScheduler);
        reminderSettingsProxy.Inner = reminderAndDeliverySettingsService;

        // --- Volar.Orchestrator ------------------------------------------------------------------
        var orchestratorTaskStoreAdapter = new OrchestratorTaskStoreAdapter(taskRepository); // IOrchestratorTaskStore
        var delegationMetaPath = options.DelegationMetaFilePath ?? FileDelegationMetaStore.GetDefaultPath();
        Directory.CreateDirectory(Path.GetDirectoryName(delegationMetaPath)!);
        var delegationMetaStore = new FileDelegationMetaStore(delegationMetaPath); // IDelegationMetaStore
        var editorTransport = new Win32EditorTransport(); // IEditorTransport — real (no App Sandbox on Windows)
        var editorConnector = new EditorConnector(editorTransport);
        var delegationTracker = new DelegationTracker(orchestratorTaskStoreAdapter, delegationMetaStore);
        var appLinkHandler = new AppLinkHandler(orchestratorTaskStoreAdapter, delegationTracker);
        var delegationOrchestratorService = new DelegationOrchestratorService(
            taskListService, eligibility, clock, delegationTracker, appLinkHandler, reminderScheduler);
        // NOTE (flagged, not silently skipped): AppLinkHandler.OnCapture — the volar://capture?text=
        // app-link hook into the capture pipeline — is left unwired. CaptureFlowService.cs (C3)
        // exposes no PUBLIC entry point that accepts a bare transcript string outside its own
        // mic-driven pipeline (ProceedToCaptureAsync is private, reachable only via the engine
        // OnFinal callback or the voice-done no-match escape hatch); wiring OnCapture would require
        // either editing C3's file (out of scope) or reaching into its private surface. Left for
        // Wave 4 in the final report's leftovers list. AppLinkHandler.Handle degrades gracefully
        // without it (logs "capture link received before the capture pipeline hook was wired —
        // dropped", per that method's own doc comment) — never throws.
        var delegationHandoffAdapter = new DelegationHandoffAdapter(delegationOrchestratorService); // IDelegationHandoff

        // --- Volar.Parsing -------------------------------------------------------------------
        var cloudParseGate = new DefaultCloudParseGate(settingsStore); // ICloudParseGate
        var parseCredentialProvider = new ConfigParseCredentialProvider(settingsStore); // IParseCredentialProvider
        // SLM stays default-OFF (wave3c-services.md, "Parsing" checklist) — enabled: false regardless
        // of whether a model file ever ends up at this path; IsAvailable short-circuits on the flag.
        var slmModelPath = Path.Combine(VolarLocalAppDataRoot(), "models", "slm", "phi4-mini.onnx");
        var slmParser = new OnnxSlmParser(slmModelPath, enabled: false); // ISlmParser
        var heuristicParser = new HeuristicIntentParser(TimeZoneInfo.Local);
        var cloudParser = new CloudParser(parseCredentialProvider);
        var intentRouter = new IntentRouter(
            heuristic: heuristicParser,
            slm: slmParser,
            cloud: cloudParser,
            cloudGate: cloudParseGate); // IIntentParser

        // --- Volar.Speech --------------------------------------------------------------------
        var audioCapture = new AudioCaptureService(); // IAudioCaptureService — shared: only one engine
        // ever records at a time (SpeechEngineService.SelectedEngine picks exactly one per capture).
        var whisperModelManager = new WhisperModelManager(Path.Combine(VolarLocalAppDataRoot(), "models"));
        var whisperEngine = new WhisperNetEngine(whisperModelManager, WhisperModelSize.Base, audioCapture);

        // Contract requirement (wave3c-services.md, "Speech"): build ONE SettingsThenEnvironmentReader
        // and inject THAT SAME instance's reader into both Groq types, so they can never disagree
        // about whether cloud speech is configured. Going one step further: the SAME
        // IGroqCredentialProvider instance (built from that one reader) is handed to both
        // GroqTranscriptionClient and GroqEngine below, which trivially guarantees agreement (same
        // object, not just same-shaped readers).
        var settingsThenEnvironmentReader = new SettingsThenEnvironmentReader(settingsStore);
        var groqCredentialProvider = new EnvironmentGroqCredentialProvider(settingsThenEnvironmentReader.AsFunc()); // IGroqCredentialProvider
        var groqTranscriptionClient = new GroqTranscriptionClient(groqCredentialProvider);
        var groqEngine = new GroqEngine(groqTranscriptionClient, captureService: audioCapture, credentialProvider: groqCredentialProvider);

        var speechEngineService = new SpeechEngineService(whisperEngine, groqEngine, settingsStore); // ISpeechEngineProvider

        // --- Volar.App/Services/State — the remaining service-graph members ------------------
        var captureFlowService = new CaptureFlowService(
            taskListService,
            eligibility,
            intentRouter,
            speechEngineService,
            clock,
            settingsStore,
            taskRepository,
            reminderScheduler,
            voice,
            delegationHandoffAdapter,
            TimeZoneInfo.Local);

        var focusSessionService = new FocusSessionService(taskListService, voice, voiceFeedback: false);

        var triageAndSweepService = new TriageAndSweepService(
            taskListService,
            orchestratorTaskStoreAdapter,
            eligibility,
            settingsStore,
            clock,
            reminderScheduler,
            delegationOrchestratorService,
            TimeZoneInfo.Local);

        var appearanceAndPersistenceService = new AppearanceAndPersistenceService(settingsStore);
        // Cross-cluster wire (appstate-inventory.md §4): J's ambient-sound playback state feeds G's
        // reminder-context gate, exactly as Swift's `init` wires `reminderGate.isOtherAudioPlaying`
        // once, at construction (AppState.swift:502).
        reminderContextGate.IsOtherAudioPlaying = () => appearanceAndPersistenceService.IsAmbientSoundPlaying;

        // --- volar:// URI scheme (HKCU\Software\Classes\volar) --------------------------------
        var uriSchemeRegistrar = new UriSchemeRegistrar();
        if (!options.SkipRegistryRegistration)
        {
            uriSchemeRegistrar.EnsureRegistered();
        }

        // --- Register the finished graph -------------------------------------------------------
        // NOTE: no Adapters.SettingsStoreAdapter registration here (C1's wrapper over
        // JsonFileSettingsStore) — see this file's closing doc comment for why it is redundant now
        // that JsonFileSettingsStore implements Volar.Domain.ISettingsStore directly.
        services.AddSingleton(clock);
        services.AddSingleton<Volar.Domain.ISettingsStore>(settingsStore);
        services.AddSingleton(settingsStore);

        services.AddSingleton<IDbContextFactory<VolarDbContext>>(dbContextFactory);
        services.AddSingleton(taskRepository);
        services.AddSingleton<IReminderRecordStore>(reminderRecordRepository);

        services.AddSingleton(reminderContextGate);
        services.AddSingleton(voice);
        services.AddSingleton<IToastChannel>(toastChannel);
        services.AddSingleton<IReminderTaskStore>(reminderTaskStoreAdapter);
        services.AddSingleton(reminderScheduler);
        services.AddSingleton<IReminderSettingsProvider>(reminderAndDeliverySettingsService);
        services.AddSingleton(reminderAndDeliverySettingsService);

        services.AddSingleton<IEligibilityAndResurfaceService>(eligibility);
        services.AddSingleton<ITaskListService>(taskListService);

        services.AddSingleton<IOrchestratorTaskStore>(orchestratorTaskStoreAdapter);
        services.AddSingleton<IDelegationMetaStore>(delegationMetaStore);
        services.AddSingleton<IEditorTransport>(editorTransport);
        services.AddSingleton(editorConnector);
        services.AddSingleton(delegationTracker);
        services.AddSingleton(appLinkHandler);
        services.AddSingleton(delegationOrchestratorService);
        services.AddSingleton<IDelegationHandoff>(delegationHandoffAdapter);

        services.AddSingleton<ICloudParseGate>(cloudParseGate);
        services.AddSingleton<IParseCredentialProvider>(parseCredentialProvider);
        services.AddSingleton<ISlmParser>(slmParser);
        services.AddSingleton(heuristicParser);
        services.AddSingleton(cloudParser);
        services.AddSingleton<IIntentParser>(intentRouter);

        services.AddSingleton<IAudioCaptureService>(audioCapture);
        services.AddSingleton(whisperModelManager);
        services.AddSingleton(whisperEngine);
        services.AddSingleton(settingsThenEnvironmentReader);
        services.AddSingleton<IGroqCredentialProvider>(groqCredentialProvider);
        services.AddSingleton(groqTranscriptionClient);
        services.AddSingleton(groqEngine);
        services.AddSingleton<ISpeechEngineProvider>(speechEngineService);
        services.AddSingleton(speechEngineService);

        services.AddSingleton(captureFlowService);
        services.AddSingleton(focusSessionService);
        services.AddSingleton(triageAndSweepService);
        services.AddSingleton(appearanceAndPersistenceService);

        services.AddSingleton(uriSchemeRegistrar);

        services.AddSingleton<HotkeyService>();

        return services.BuildServiceProvider();
    }

    /// <summary><c>%LocalAppData%\Volar</c> — the same root <see cref="VolarDbPaths"/>/
    /// <see cref="Volar.Data.JsonFileSettingsStore"/>/<see cref="FileDelegationMetaStore"/> each
    /// compute independently for their own default file. Not overridable via
    /// <see cref="CompositionRootOptions"/>: nothing under it is written to at <see cref="Build"/>
    /// time (the model-manager/SLM-parser constructors below only store the path string — no I/O
    /// happens until a capture/prepare call actually reads it), so it needs no test-hermeticity
    /// seam the way the database/settings/delegation-meta FILES do.</summary>
    private static string VolarLocalAppDataRoot() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Volar");

    /// <summary>Breaks the ReminderScheduler -&gt; IReminderSettingsProvider -&gt; ITaskListService
    /// -&gt; ReminderScheduler constructor cycle described in this file's header (cycle #2).
    /// Constructed first and handed to <see cref="ReminderScheduler"/>; <see cref="Inner"/> is
    /// assigned to the real <see cref="ReminderAndDeliverySettingsService"/> once that in turn has
    /// been constructed with the by-then-real <see cref="ITaskListService"/>. Before <see cref="Inner"/>
    /// is set, forwards to the same library defaults <see cref="DefaultReminderSettingsProvider"/>
    /// already uses — harmless, since nothing calls into the scheduler during this composition-root
    /// construction window.</summary>
    private sealed class LateBoundReminderSettingsProvider : IReminderSettingsProvider
    {
        private static readonly DefaultReminderSettingsProvider Fallback = new();

        public IReminderSettingsProvider? Inner { get; set; }

        public VoiceDeliveryMode CurrentVoiceDeliveryMode => (Inner ?? Fallback).CurrentVoiceDeliveryMode;

        public ReminderPolicy CurrentGlobalReminderPolicy => (Inner ?? Fallback).CurrentGlobalReminderPolicy;
    }

}
