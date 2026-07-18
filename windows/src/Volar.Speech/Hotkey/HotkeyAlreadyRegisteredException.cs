// Hotkey/HotkeyAlreadyRegisteredException.cs — distinct exception type for the one new failure
// mode RegisterHotKey has that the old WH_KEYBOARD_LL hook never did: another application can
// already own the exact same key combination.
namespace Volar.Speech.Hotkey;

/// <summary>Thrown by <see cref="HotkeyManager.Start"/> when the configured combo (default
/// Ctrl+Alt+M) is already registered by another application — Win32 <c>RegisterHotKey</c> failing
/// with <c>ERROR_HOTKEY_ALREADY_REGISTERED</c> (1409). Kept as its own type, distinct from a plain
/// <see cref="InvalidOperationException"/>, so a future Settings UI can catch this specific case
/// with a type check and prompt the user to pick a different key combination, instead of having to
/// pattern-match on exception message text.</summary>
public sealed class HotkeyAlreadyRegisteredException : InvalidOperationException
{
    /// <summary>The raw Win32 error code — always 1409 (<c>ERROR_HOTKEY_ALREADY_REGISTERED</c>) for
    /// this exception type. Exposed as data (not just baked into the message) for callers that want
    /// to branch on it programmatically.</summary>
    public int Win32ErrorCode { get; }

    public HotkeyAlreadyRegisteredException(string message, int win32ErrorCode)
        : base(message)
    {
        Win32ErrorCode = win32ErrorCode;
    }
}
