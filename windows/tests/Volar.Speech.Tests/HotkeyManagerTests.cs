// HotkeyManagerTests.cs — exercises HotkeyManager/HotkeyOptions' decision logic (combo mapping,
// the "already registered by another app" error path, dispatch threading, Start/Stop idempotency)
// entirely through internal seams. NEVER calls the real Win32 RegisterHotKey/UnregisterHotKey —
// per anh Khôi's brief: "KHÔNG đăng ký hotkey thật trong test". Tests that need Start()/Stop() to
// run a real pump thread inject fake RegisterHotKeyFunc/UnregisterHotKeyFunc delegates so no actual
// system-wide hotkey registration ever happens, mirroring how the previous hook-based
// implementation let tests fake KeyStateProbe instead of touching real hardware.
using Volar.Speech.Hotkey;
using Xunit;

namespace Volar.Speech.Tests;

public class HotkeyManagerTests
{
    // ---- HotkeyOptions.ToRegisterHotKeyArgs -------------------------------------------------

    [Fact]
    public void ToRegisterHotKeyArgs_Default_MapsToCtrlAltM_WithNoRepeat()
    {
        var (fsModifiers, vk) = HotkeyOptions.Default.ToRegisterHotKeyArgs();

        Assert.Equal(NativeMethods.MOD_CONTROL | NativeMethods.MOD_ALT | NativeMethods.MOD_NOREPEAT, fsModifiers);
        Assert.Equal(0x4Du, vk);
    }

    [Fact]
    public void ToRegisterHotKeyArgs_AlwaysIncludesModNoRepeat_EvenWithNoModifiersRequired()
    {
        var options = new HotkeyOptions { RequireControl = false, RequireAlt = false };

        var (fsModifiers, _) = options.ToRegisterHotKeyArgs();

        Assert.Equal(NativeMethods.MOD_NOREPEAT, fsModifiers & NativeMethods.MOD_NOREPEAT);
    }

    [Fact]
    public void ToRegisterHotKeyArgs_RespectsEveryModifierFlag()
    {
        var options = new HotkeyOptions
        {
            RequireControl = true,
            RequireAlt = false,
            RequireShift = true,
            RequireWindows = true,
            VirtualKeyCode = 0x50, // 'P'
        };

        var (fsModifiers, vk) = options.ToRegisterHotKeyArgs();

        Assert.Equal(
            NativeMethods.MOD_CONTROL | NativeMethods.MOD_SHIFT | NativeMethods.MOD_WIN | NativeMethods.MOD_NOREPEAT,
            fsModifiers);
        Assert.Equal((uint)0x50, vk);
        Assert.Equal(0u, fsModifiers & NativeMethods.MOD_ALT); // explicitly NOT requested
    }

    // ---- HotkeyOptions.DescribeCombo ---------------------------------------------------------

    [Fact]
    public void DescribeCombo_Default_ReturnsCtrlAltM()
    {
        Assert.Equal("Ctrl+Alt+M", HotkeyOptions.Default.DescribeCombo());
    }

    [Fact]
    public void DescribeCombo_NonLetterDigitKey_FallsBackToVkLabel()
    {
        var options = new HotkeyOptions { RequireControl = true, RequireAlt = false, VirtualKeyCode = 0x70 }; // VK_F1

        Assert.Equal("Ctrl+VK 0x70", options.DescribeCombo());
    }

    // ---- HotkeyManager.CreateRegistrationFailureException (pure decision function) ------------

    [Fact]
    public void CreateRegistrationFailureException_AlreadyRegistered_ReturnsTypedException_NamingTheCombo()
    {
        var ex = HotkeyManager.CreateRegistrationFailureException(
            HotkeyOptions.Default, NativeMethods.ERROR_HOTKEY_ALREADY_REGISTERED);

        var typed = Assert.IsType<HotkeyAlreadyRegisteredException>(ex);
        Assert.Equal(NativeMethods.ERROR_HOTKEY_ALREADY_REGISTERED, typed.Win32ErrorCode);
        Assert.Contains("Ctrl+Alt+M", typed.Message);
    }

    [Fact]
    public void CreateRegistrationFailureException_OtherWin32Error_ReturnsPlainInvalidOperationException()
    {
        var ex = HotkeyManager.CreateRegistrationFailureException(HotkeyOptions.Default, win32Error: 5 /* ACCESS_DENIED */);

        Assert.IsType<InvalidOperationException>(ex);
        Assert.IsNotType<HotkeyAlreadyRegisteredException>(ex);
        Assert.Contains("5", ex.Message);
    }

    // ---- HotkeyManager.Dispatch (threading contract) -------------------------------------------

    [Fact]
    public async Task Dispatch_RunsOnToggleHandlerOffCallingThread()
    {
        var manager = new HotkeyManager();
        var callingThreadId = Environment.CurrentManagedThreadId;
        var handlerThreadId = -1;
        var signal = new ManualResetEventSlim(false);
        manager.OnToggle += () =>
        {
            handlerThreadId = Environment.CurrentManagedThreadId;
            signal.Set();
        };

        manager.Dispatch();

        Assert.True(await Task.Run(() => signal.Wait(TimeSpan.FromSeconds(2))));
        Assert.NotEqual(callingThreadId, handlerThreadId);
    }

    [Fact]
    public void Dispatch_NoSubscribers_DoesNotThrow()
    {
        var manager = new HotkeyManager();
        var exception = Record.Exception(() => manager.Dispatch());
        Assert.Null(exception);
    }

    // ---- HotkeyManager.Start/Stop, driven entirely through the RegisterHotKeyFunc/
    // UnregisterHotKeyFunc seams — never touches the real Win32 API. ---------------------------

    [Fact]
    public void Start_RegistrationAlreadyTaken_ThrowsHotkeyAlreadyRegisteredException_AndLeavesNotRunning()
    {
        var manager = new HotkeyManager
        {
            RegisterHotKeyFunc = (_, _) => (false, NativeMethods.ERROR_HOTKEY_ALREADY_REGISTERED),
        };

        var ex = Assert.Throws<HotkeyAlreadyRegisteredException>(manager.Start);

        Assert.Contains("Ctrl+Alt+M", ex.Message);
        Assert.False(manager.IsRunning);
    }

    [Fact]
    public void Start_Stop_AreIdempotent_WithFakeRegistrar()
    {
        var registerCalls = 0;
        var unregisterCalls = 0;
        var manager = new HotkeyManager
        {
            RegisterHotKeyFunc = (_, _) => { Interlocked.Increment(ref registerCalls); return (true, 0); },
            UnregisterHotKeyFunc = () => Interlocked.Increment(ref unregisterCalls),
        };

        manager.Start();
        manager.Start(); // second call while already running must be a no-op
        Assert.True(manager.IsRunning);
        Assert.Equal(1, registerCalls);

        manager.Stop();
        manager.Stop(); // second call while already stopped must be a no-op
        Assert.False(manager.IsRunning);
        Assert.Equal(1, unregisterCalls);

        manager.Dispose();
    }

    [Fact]
    public void Start_AfterStop_CanRegisterAgain_WithFakeRegistrar()
    {
        var registerCalls = 0;
        var manager = new HotkeyManager
        {
            RegisterHotKeyFunc = (_, _) => { Interlocked.Increment(ref registerCalls); return (true, 0); },
            UnregisterHotKeyFunc = () => { },
        };

        manager.Start();
        manager.Stop();
        manager.Start();

        Assert.True(manager.IsRunning);
        Assert.Equal(2, registerCalls);

        manager.Dispose();
    }

    [Fact]
    public void Dispose_WhenRunning_UnregistersAndStops_WithFakeRegistrar()
    {
        var unregisterCalls = 0;
        var manager = new HotkeyManager
        {
            RegisterHotKeyFunc = (_, _) => (true, 0),
            UnregisterHotKeyFunc = () => Interlocked.Increment(ref unregisterCalls),
        };

        manager.Start();
        manager.Dispose();

        Assert.False(manager.IsRunning);
        Assert.Equal(1, unregisterCalls);
    }

    [Fact]
    public void Start_AfterDispose_Throws()
    {
        var manager = new HotkeyManager
        {
            RegisterHotKeyFunc = (_, _) => (true, 0),
            UnregisterHotKeyFunc = () => { },
        };
        manager.Dispose();

        Assert.Throws<ObjectDisposedException>(manager.Start);
    }
}
