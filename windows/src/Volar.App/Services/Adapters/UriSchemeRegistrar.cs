// Services/Adapters/UriSchemeRegistrar.cs — registers the `volar://` custom URI scheme under
// HKCU\Software\Classes\volar, per AppLinkHandler.cs's own header note ("OS-level protocol
// registration ... is DEFERRED to Wave 3 (App shell)") and appstate-inventory.md §7's Windows
// delta for `AppDelegate.application(_:open:)`.
//
// HKCU ONLY, NEVER HKLM, NEVER ELEVATE: this app is unpackaged and self-contained (no installer,
// no admin rights assumed) — HKCU\Software\Classes is the per-user registration root Windows
// consults for URI activation without any elevation, and is the only registry root this class ever
// touches (hard constraint from this wave's brief).
//
// IDEMPOTENT: EnsureRegistered() first checks IsRegistrationCurrent() and does nothing if the
// existing registration already points at the CURRENT running executable — re-running it on every
// launch (the expected call site, per this wave's C5 handoff) never rewrites the registry unless
// something actually changed (a previous build's stale exe path, or no registration at all yet).
//
// NOTE ON ACTIVATION: this class only WRITES the registration. Actually receiving a `volar://`
// activation into this already-running, unpackaged process (so a second launch redirects instead
// of starting a new instance) needs `Microsoft.Windows.AppLifecycle.AppInstance` single-instance
// redirection — that wiring is out of this file's scope (adapter, not shell) and belongs to
// whichever Wave 3-C/5 agent wires `AppLinkHandler` into the shell (see appstate-inventory.md §7's
// note on this exact gap); this class only makes sure the OS knows to launch/activate Volar.exe at
// all for that scheme.
using Microsoft.Win32;

namespace Volar.App.Services.Adapters;

public sealed class UriSchemeRegistrar
{
    public const string Scheme = "volar";

    /// <summary>Opens (creating if absent) the registry root this instance treats as "the Classes
    /// root" — production always resolves to the real per-user Classes hive
    /// (<c>HKCU\Software\Classes</c>); tests override this to point at a disposable temp subkey so
    /// no test run ever touches the real key (hard constraint from this wave's brief). Called fresh
    /// on every operation rather than held open, so nothing here leaks a registry handle.</summary>
    private readonly Func<RegistryKey> _openClassesRoot;

    /// <summary>Resolves the full path to the executable the registration should point at.
    /// Defaults to the running process's own module path — this app is unpackaged, so "the running
    /// executable" IS the install (no separate installer-known path to prefer).</summary>
    private readonly Func<string> _resolveExecutablePath;

    public UriSchemeRegistrar(Func<RegistryKey>? classesRootFactory = null, Func<string>? executablePathResolver = null)
    {
        _openClassesRoot = classesRootFactory ?? DefaultClassesRoot;
        _resolveExecutablePath = executablePathResolver ?? DefaultExecutablePath;
    }

    private static RegistryKey DefaultClassesRoot() =>
        Registry.CurrentUser.CreateSubKey(@"Software\Classes", writable: true)
            ?? throw new InvalidOperationException("Could not open/create HKCU\\Software\\Classes.");

    private static string DefaultExecutablePath() =>
        Environment.ProcessPath
            ?? System.Diagnostics.Process.GetCurrentProcess().MainModule?.FileName
            ?? throw new InvalidOperationException("Could not resolve the running executable's path.");

    /// <summary>The exact <c>shell\open\command</c> default value this registration should hold for
    /// <paramref name="exePath"/> — a quoted path followed by <c>"%1"</c> so the activated URL is
    /// passed as the process's first argument, the same convention every custom-URI-scheme sample
    /// uses (and the shape <see cref="Volar.Orchestrator.AppLinkHandler.Handle(string)"/> ultimately
    /// expects to receive from whatever hands it argv[1]).</summary>
    private static string CommandLineFor(string exePath) => $"\"{exePath}\" \"%1\"";

    /// <summary>
    /// <see langword="true"/> only when every key/value this registration writes already matches
    /// exactly what <see cref="EnsureRegistered"/> would write right now (in particular: the
    /// command line points at the CURRENT running executable's path) — a stale registration from a
    /// previous build/location reads as "not current", not "current".
    /// </summary>
    public bool IsRegistrationCurrent()
    {
        try
        {
            using var classes = _openClassesRoot();
            using var schemeKey = classes.OpenSubKey(Scheme);
            if (schemeKey is null)
            {
                return false;
            }
            if (schemeKey.GetValue("URL Protocol") is not string)
            {
                return false;
            }
            using var commandKey = schemeKey.OpenSubKey(@"shell\open\command");
            if (commandKey is null)
            {
                return false;
            }
            var expected = CommandLineFor(_resolveExecutablePath());
            var actual = commandKey.GetValue(null) as string;
            return string.Equals(actual, expected, StringComparison.Ordinal);
        }
        catch
        {
            // A registry read failure (permissions, corrupt hive, ...) means we cannot prove the
            // registration is current — treat exactly like "not current" so EnsureRegistered's
            // caller gets a chance to (re)write it.
            return false;
        }
    }

    /// <summary>
    /// Writes/repairs the <c>volar://</c> registration under <c>HKCU\Software\Classes\volar</c>.
    /// No-ops (besides the read-only check) if <see cref="IsRegistrationCurrent"/> already holds.
    /// Never throws: a failed write (e.g. a locked hive) leaves the app runnable with `volar://`
    /// links simply not activating it — the app still functions fully via direct capture/UI — so
    /// this is a best-effort integration, not a startup-blocking requirement.
    /// </summary>
    public void EnsureRegistered()
    {
        if (IsRegistrationCurrent())
        {
            return;
        }
        try
        {
            using var classes = _openClassesRoot();
            using var schemeKey = classes.CreateSubKey(Scheme, writable: true)
                ?? throw new InvalidOperationException($"Could not create Classes\\{Scheme}.");
            schemeKey.SetValue(null, "URL:Volar Protocol");
            schemeKey.SetValue("URL Protocol", "", RegistryValueKind.String);

            using var commandKey = schemeKey.CreateSubKey(@"shell\open\command", writable: true)
                ?? throw new InvalidOperationException($"Could not create Classes\\{Scheme}\\shell\\open\\command.");
            commandKey.SetValue(null, CommandLineFor(_resolveExecutablePath()));
        }
        catch
        {
            // Best-effort — see doc comment above. Never throw into a startup path over this.
        }
    }
}
