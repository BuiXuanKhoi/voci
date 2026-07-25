// Wiring/WiringTestEnvironment.cs — a hermetic CompositionRootOptions pointed at a fresh temp
// directory per instance, so every wiring test builds the REAL service graph (real SQLite, real
// EF migrations, real settings file) without ever touching the developer/CI machine's actual
// %LocalAppData%\Volar or HKCU\Software\Classes\volar (SkipRegistryRegistration: true). Deliberately
// its own small support type rather than reusing State/SqliteFixture.cs — this folder's tests
// exercise CompositionRoot.Build() itself (the whole graph), not TaskRepository in isolation.
using Microsoft.Data.Sqlite;
using Volar.App.Services;
using Volar.App.Services.Adapters;

namespace Volar.App.Tests.Wiring;

internal sealed class WiringTestEnvironment : IDisposable
{
    public string RootDirectory { get; }

    public CompositionRootOptions Options { get; }

    public WiringTestEnvironment()
    {
        RootDirectory = Path.Combine(Path.GetTempPath(), $"volar-wiring-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(RootDirectory);
        Options = new CompositionRootOptions
        {
            DatabasePath = Path.Combine(RootDirectory, "volar.db"),
            SettingsFilePath = Path.Combine(RootDirectory, "settings.json"),
            DelegationMetaFilePath = Path.Combine(RootDirectory, "delegation-meta.json"),
            SkipRegistryRegistration = true,
            // See CompositionRootOptions.ToastGateway's own doc comment: the real
            // WinAppSdkNotificationGateway requires the Windows App SDK bootstrapper, which only a
            // real running app process initializes — a plain xunit test host never does, so every
            // wiring test needs this fake instead.
            ToastGateway = new NoOpNativeAppNotificationGateway(),
        };
    }

    public void Dispose()
    {
        // Release SQLite's file handle before deleting — mirrors State/SqliteFixture.cs's identical
        // rationale (a pooled connection can otherwise keep the file locked on Windows).
        try
        {
            SqliteConnection.ClearAllPools();
        }
        catch
        {
            // Best-effort cleanup only.
        }
        try
        {
            if (Directory.Exists(RootDirectory))
            {
                Directory.Delete(RootDirectory, recursive: true);
            }
        }
        catch
        {
            // A leaked temp directory is harmless; never let cleanup fail a test run.
        }
    }
}

/// <summary>Fully in-memory no-op <see cref="INativeAppNotificationGateway"/> — never calls into
/// Microsoft.Windows.AppNotifications, so it is safe to construct in a plain unit-test host process
/// (unlike the real <see cref="WinAppSdkNotificationGateway"/>, see
/// <see cref="CompositionRootOptions.ToastGateway"/>'s doc comment). Deliberately smaller than
/// Adapters/AdapterTestSupport.cs's FakeNativeGateway (which exists to exercise
/// AppNotificationToastChannel's own behavior in detail) — this one only needs to let
/// CompositionRoot.Build() finish constructing the graph without throwing.</summary>
internal sealed class NoOpNativeAppNotificationGateway : INativeAppNotificationGateway
{
    public bool Register() => true;

    public void Show(Guid recordId, string title, string body, IReadOnlyList<ToastButtonSpec> buttons)
    {
    }

    public IReadOnlyList<Guid> GetDeliveredIds() => Array.Empty<Guid>();

    public void RemoveByTag(Guid recordId)
    {
    }

    public event Action<string, Guid>? Invoked
    {
        add { }
        remove { }
    }

    public void Dispose()
    {
    }
}
