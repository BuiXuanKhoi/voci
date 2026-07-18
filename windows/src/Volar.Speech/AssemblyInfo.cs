// AssemblyInfo.cs — grants Volar.Speech.Tests access to `internal` testable seams (currently
// HotkeyManager's Dispatch/RegisterHotKeyFunc/UnregisterHotKeyFunc/CreateRegistrationFailureException
// and HotkeyOptions' ToRegisterHotKeyArgs/DescribeCombo — see Hotkey/HotkeyManager.cs doc comments
// for why: the real system-wide hotkey must never be registered during automated tests, so its
// decision logic is exposed to tests via `internal`, not `public`, members.
using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("Volar.Speech.Tests")]
