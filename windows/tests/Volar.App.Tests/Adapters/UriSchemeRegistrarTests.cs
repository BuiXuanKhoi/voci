// UriSchemeRegistrarTests.cs — every test here points classesRootFactory at a disposable temp
// subkey under HKCU\Software\VolarTests\<guid> instead of the real HKCU\Software\Classes, per this
// wave's hard constraint ("do NOT write to the real HKCU\Software\Classes\volar ... during
// tests"). The temp key is deleted in Dispose() regardless of test outcome.
using Microsoft.Win32;
using Volar.App.Services.Adapters;
using Xunit;

namespace Volar.App.Tests.Adapters;

public sealed class UriSchemeRegistrarTests : IDisposable
{
    private readonly string _tempRootPath = $@"Software\VolarTests\{Guid.NewGuid():N}";

    private RegistryKey OpenTempRoot() =>
        Registry.CurrentUser.CreateSubKey(_tempRootPath, writable: true)
            ?? throw new InvalidOperationException("Could not create test registry key.");

    private UriSchemeRegistrar CreateRegistrar(string exePath = @"C:\fake\Volar.exe") =>
        new(classesRootFactory: OpenTempRoot, executablePathResolver: () => exePath);

    [Fact]
    public void IsRegistrationCurrent_False_WhenNothingRegisteredYet()
    {
        var registrar = CreateRegistrar();

        Assert.False(registrar.IsRegistrationCurrent());
    }

    [Fact]
    public void EnsureRegistered_ThenIsRegistrationCurrent_True()
    {
        var registrar = CreateRegistrar(@"C:\Program Files\Volar\Volar.exe");

        registrar.EnsureRegistered();

        Assert.True(registrar.IsRegistrationCurrent());
    }

    [Fact]
    public void EnsureRegistered_WritesTheExpectedKeysAndValues()
    {
        var exePath = @"C:\Program Files\Volar\Volar.exe";
        var registrar = CreateRegistrar(exePath);

        registrar.EnsureRegistered();

        using var root = OpenTempRoot();
        using var schemeKey = root.OpenSubKey(UriSchemeRegistrar.Scheme);
        Assert.NotNull(schemeKey);
        Assert.Equal("", schemeKey!.GetValue("URL Protocol"));

        using var commandKey = schemeKey.OpenSubKey(@"shell\open\command");
        Assert.NotNull(commandKey);
        Assert.Equal($"\"{exePath}\" \"%1\"", commandKey!.GetValue(null));
    }

    [Fact]
    public void IsRegistrationCurrent_False_WhenExecutablePathChanged()
    {
        var registrar = CreateRegistrar(@"C:\old\Volar.exe");
        registrar.EnsureRegistered();
        Assert.True(registrar.IsRegistrationCurrent());

        var movedRegistrar = CreateRegistrar(@"C:\new\Volar.exe");

        Assert.False(movedRegistrar.IsRegistrationCurrent());
    }

    [Fact]
    public void EnsureRegistered_RepairsAStaleRegistration_AfterAnExecutableMove()
    {
        var oldRegistrar = CreateRegistrar(@"C:\old\Volar.exe");
        oldRegistrar.EnsureRegistered();

        var newRegistrar = CreateRegistrar(@"C:\new\Volar.exe");
        newRegistrar.EnsureRegistered();

        Assert.True(newRegistrar.IsRegistrationCurrent());
        using var root = OpenTempRoot();
        using var commandKey = root.OpenSubKey(UriSchemeRegistrar.Scheme + @"\shell\open\command");
        Assert.Equal("\"C:\\new\\Volar.exe\" \"%1\"", commandKey!.GetValue(null));
    }

    [Fact]
    public void EnsureRegistered_IsIdempotent_CallingTwiceDoesNotThrowAndStaysCurrent()
    {
        var registrar = CreateRegistrar();

        registrar.EnsureRegistered();
        registrar.EnsureRegistered();

        Assert.True(registrar.IsRegistrationCurrent());
    }

    [Fact]
    public void IsRegistrationCurrent_NeverThrows_WhenClassesRootFactoryThrows()
    {
        var registrar = new UriSchemeRegistrar(
            classesRootFactory: () => throw new InvalidOperationException("no registry access"),
            executablePathResolver: () => @"C:\fake\Volar.exe");

        Assert.False(registrar.IsRegistrationCurrent());
    }

    [Fact]
    public void EnsureRegistered_NeverThrows_WhenClassesRootFactoryThrows()
    {
        var registrar = new UriSchemeRegistrar(
            classesRootFactory: () => throw new InvalidOperationException("no registry access"),
            executablePathResolver: () => @"C:\fake\Volar.exe");

        registrar.EnsureRegistered(); // must not throw
    }

    public void Dispose()
    {
        try
        {
            Registry.CurrentUser.DeleteSubKeyTree(_tempRootPath, throwOnMissingSubKey: false);
        }
        catch
        {
            // Best-effort cleanup — never fail the test run over leftover test registry state.
        }
    }
}
