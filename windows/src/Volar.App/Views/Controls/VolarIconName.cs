// Views/Controls/VolarIconName.cs — port of `Volar/Sources/Design/VolarIcon.swift`'s
// `enum VolarIconName` (spec: specs/003-windows-port/wave4-contract.md, Stage A deliverable 1;
// glyph verification table: specs/003-windows-port/views-inventory.md §4).
//
// CASE-COUNT NOTE: the contract's own prose says "mirroring Swift's 30 cases 1:1", but the actual
// current `VolarIconName` (VolarIcon.swift:7-10, read in full for this port) declares exactly 28
// cases, not 30 — counted twice while writing this file. Per the contract's own top-line rule
// ("source of truth ... is the CURRENT Swift files"), this enum mirrors the CURRENT 28, not the
// stale "30" figure in the contract's prose. Flagged in this agent's final report as a documentation
// drift, not a porting decision.
namespace Volar.App.Views.Controls;

/// <summary>Every icon role used by the shared `VolarIcon` control, 1:1 with Swift's case list
/// (VolarIcon.swift:7-10). Views request icons by role, never by raw glyph string — see
/// <see cref="VolarIconGlyphs"/> for the Segoe MDL2 Assets codepoint each case resolves to.</summary>
public enum VolarIconName
{
    Mic,
    Focus,
    Inbox,
    Upcoming,
    Today,
    Plus,
    Search,
    Chevron,
    ChevronDown,
    Settings,
    Check,
    Clock,
    Bell,
    Sparkle,
    Flag,
    Bolt,
    Cmd,
    Project,
    Waveform,
    Home,
    Back,
    X,
    Eject,
    Pause,
    Play,
    Stop,
    Volume,
    VolumeOff,
}
