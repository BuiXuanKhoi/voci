// Services/CompositionRoot.cs — builds the app's single IServiceProvider (App.Services). Registers
// every Wave 2 seam named in this task's brief: Volar.Parsing (IntentRouter, ICloudParseGate,
// IParseCredentialProvider, ISlmParser), Volar.Reminders (IToastChannel, IReminderTaskStore,
// IReminderSettingsProvider), Volar.Orchestrator (IEditorTransport, IOrchestratorTaskStore,
// IDelegationMetaStore, AppLinkHandler, DelegationTracker), Volar.Data (VolarDbContext,
// TaskRepository), Volar.Speech (ISpeechEngine, HotkeyManager, AudioCapture).
//
// Every concrete adapter that needs real I/O this shell doesn't provision yet (network credential
// flow, real toast/AppNotification identity, mapped task persistence) is a Stubs/* type with a
// `// TODO(W3-B)` pointing at what replaces it — see each Stubs/*.cs file's header. Types that are
// already genuinely simple/real (Win32EditorTransport, HotkeyManager, VolarDbContextFactory +
// TaskRepository, the in-memory stores Volar.Reminders/Volar.Orchestrator already ship) are wired
// up as themselves, not stubbed.
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Volar.App.Stubs;
using Volar.Data;
using Volar.Orchestrator;
using Volar.Parsing;
using Volar.Reminders;
using Volar.Speech;
using Volar.Speech.Audio;

namespace Volar.App.Services;

public static class CompositionRoot
{
    public static IServiceProvider Build()
    {
        var services = new ServiceCollection();

        // --- Volar.Data --------------------------------------------------------------------
        // Composition-root-only Environment/AppData read, per VolarDbPaths.cs's own doc comment
        // ("only the App composition root should call this").
        var dbPath = VolarDbPaths.GetDefaultDatabasePath();
        Directory.CreateDirectory(Path.GetDirectoryName(dbPath)!);
        var dbContextFactory = VolarDbContextFactory.ForFile(dbPath);
        services.AddSingleton<IDbContextFactory<VolarDbContext>>(dbContextFactory);
        services.AddSingleton(sp => new TaskRepository(sp.GetRequiredService<IDbContextFactory<VolarDbContext>>()));

        // Ensure the schema exists on first run (EF Core migrations are Wave 3-B's concern; for
        // this shell, EnsureCreated is enough to prove the SQLite file opens and TaskRepository is
        // reachable end-to-end).
        using (var context = dbContextFactory.CreateDbContext())
        {
            context.Database.EnsureCreated();
        }

        // --- Volar.Parsing -------------------------------------------------------------------
        services.AddSingleton<ICloudParseGate, StubCloudParseGate>(); // TODO(W3-B)
        services.AddSingleton<IParseCredentialProvider, StubParseCredentialProvider>(); // TODO(W3-B)
        services.AddSingleton<ISlmParser, StubSlmParser>(); // TODO(W3-B) or leave disabled permanently
        services.AddSingleton(sp => new HeuristicIntentParser(TimeZoneInfo.Local));
        services.AddSingleton(sp => new CloudParser(sp.GetRequiredService<IParseCredentialProvider>()));
        services.AddSingleton<IIntentParser>(sp => new IntentRouter(
            heuristic: sp.GetRequiredService<HeuristicIntentParser>(),
            slm: sp.GetRequiredService<ISlmParser>(),
            cloud: sp.GetRequiredService<CloudParser>(),
            cloudGate: sp.GetRequiredService<ICloudParseGate>()));

        // --- Volar.Reminders -------------------------------------------------------------------
        services.AddSingleton<IToastChannel, StubToastChannel>(); // TODO(W3-B)
        services.AddSingleton<IReminderTaskStore, StubReminderTaskStore>(); // TODO(W3-B)
        services.AddSingleton<IReminderSettingsProvider, DefaultReminderSettingsProvider>();
        services.AddSingleton<ReminderContextGate>();
        services.AddSingleton(sp => new ReminderScheduler(
            store: sp.GetRequiredService<IReminderTaskStore>(),
            channel: sp.GetRequiredService<IToastChannel>(),
            gate: sp.GetRequiredService<ReminderContextGate>(),
            settings: sp.GetRequiredService<IReminderSettingsProvider>(),
            timeZone: TimeZoneInfo.Local));

        // --- Volar.Orchestrator ------------------------------------------------------------------
        services.AddSingleton<IEditorTransport, Win32EditorTransport>(); // real (no sandbox on Windows)
        services.AddSingleton<IOrchestratorTaskStore, StubOrchestratorTaskStore>(); // TODO(W3-B)
        services.AddSingleton<IDelegationMetaStore, InMemoryDelegationMetaStore>(); // TODO(W3-B): durable store
        services.AddSingleton(sp => new EditorConnector(sp.GetRequiredService<IEditorTransport>()));
        services.AddSingleton(sp => new DelegationTracker(
            sp.GetRequiredService<IOrchestratorTaskStore>(),
            sp.GetRequiredService<IDelegationMetaStore>()));
        services.AddSingleton(sp => new AppLinkHandler(
            sp.GetRequiredService<IOrchestratorTaskStore>(),
            sp.GetRequiredService<DelegationTracker>()));

        // --- Volar.Speech --------------------------------------------------------------------
        services.AddSingleton<ISpeechEngine, StubSpeechEngine>(); // TODO(W3-B): WhisperNetEngine/GroqEngine
        services.AddSingleton<IAudioCaptureService>(sp => new AudioCaptureService()); // real (WASAPI via NAudio)
        services.AddSingleton<HotkeyService>(); // wraps the real Volar.Speech.Hotkey.HotkeyManager

        return services.BuildServiceProvider();
    }
}
