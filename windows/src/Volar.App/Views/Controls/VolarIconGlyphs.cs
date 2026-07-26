// Views/Controls/VolarIconGlyphs.cs — VolarIconName -> Segoe MDL2 Assets glyph map (Stage A
// deliverable 1). Kept as a plain, headless-testable static class separate from the visual
// `VolarIcon` control so the mapping's completeness (28/28 cases, `Cmd` text-mode) can be unit
// tested without a XAML runtime — see windows/tests/Volar.App.Tests/Views/Controls/
// VolarIconGlyphsTests.cs.
//
// FONT: every codepoint below targets Segoe MDL2 Assets, the ONLY icon font guaranteed present on
// the dev/test machine (Win10 19045 per the frozen contract, decision 1) — `VolarIcon`'s
// FontFamily is the composite "Segoe Fluent Icons,Segoe MDL2 Assets" so a Win11 machine with the
// newer Fluent font still renders identically (Fluent is a superset for every codepoint used here).
//
// VERIFICATION STATUS: codepoints below fall into two groups —
//   (a) codepoints the frozen contract itself specifies verbatim (wave4-contract.md deliverable 1)
//       — used as given, not re-litigated;
//   (b) 9 cases the contract explicitly flags as having "no reliable MDL2 glyph" (sparkle,
//       focus/scope, waveform, cmd, inbox, today-vs-upcoming, eject, home, clock) — each has a
//       `SUBSTITUTION:`/`VERIFY:` comment on its switch arm explaining the choice and confidence.
// No live Character-Map verification was performed on this pass (no interactive Windows GUI access
// from this agent) — every (b)-group codepoint should be spot-checked in Character Map (filter:
// "Segoe MDL2 Assets") before a visual QA pass; a wrong codepoint is a SILENT failure (renders an
// unrelated glyph, no build error), per the contract's own gotcha list.
namespace Volar.App.Views.Controls;

public static class VolarIconGlyphs
{
    /// <summary>The one case with no glyph at all — `VolarIcon` renders literal text instead (see
    /// <see cref="TextFallback"/>). Per the frozen contract: macOS's `command` glyph has no Windows
    /// analog; render "Ctrl" instead of hunting for a symbol.</summary>
    public static bool IsTextMode(VolarIconName name) => name == VolarIconName.Cmd;

    /// <summary>Only meaningful when <see cref="IsTextMode"/> is <see langword="true"/>.</summary>
    public static string TextFallback(VolarIconName name) => name switch
    {
        VolarIconName.Cmd => "Ctrl",
        _ => string.Empty,
    };

    /// <summary>Segoe MDL2 Assets glyph string for every icon EXCEPT <see cref="VolarIconName.Cmd"/>
    /// (text-mode — see <see cref="IsTextMode"/>), which still returns a (unused) non-empty
    /// placeholder here so the "every case maps to something" completeness test doesn't need a
    /// special case.</summary>
    public static string Glyph(VolarIconName name) => name switch
    {
        // --- Contract-specified codepoints (wave4-contract.md deliverable 1), used verbatim. ---
        VolarIconName.Mic => "", // Microphone
        VolarIconName.Plus => "", // Add
        VolarIconName.Search => "", // Search (per contract; frozen, not relitigated)
        VolarIconName.Chevron => "", // ChevronRight
        VolarIconName.ChevronDown => "", // ChevronDown
        VolarIconName.Back => "", // ChevronLeft
        VolarIconName.X => "", // Cancel
        VolarIconName.Settings => "", // Setting
        VolarIconName.Check => "", // CheckMark
        VolarIconName.Play => "", // Play
        VolarIconName.Pause => "", // Pause
        VolarIconName.Stop => "", // Stop
        VolarIconName.Volume => "", // Volume
        VolarIconName.VolumeOff => "", // Mute
        VolarIconName.Upcoming => "", // Calendar
        VolarIconName.Project => "", // Folder
        VolarIconName.Flag => "", // Flag
        VolarIconName.Bolt => "", // LightningBolt

        // Bell: contract offers a choice of E7E7/EA8F, "VERIFY". Picked Ringer (E7E7) — the more
        // widely documented of the two in Microsoft's published Segoe MDL2 Assets icon list.
        VolarIconName.Bell => "", // Ringer — VERIFY against Character Map before shipping.

        // --- The 9 cases the contract flags as having no reliable MDL2 glyph. ---

        // SUBSTITUTION: Fluent's "sparkle"/"sparkles" glyph postdates classic MDL2 (Fluent-only
        // addition, per contract + inventory §4). Closest documented MDL2 stand-in for an
        // "AI/generated content" affordance pre-dating Sparkle: FavoriteStar.
        VolarIconName.Sparkle => "", // SUBSTITUTION: FavoriteStar (no MDL2 sparkle glyph exists)

        // SUBSTITUTION: no MDL2 "scope"/target/crosshair glyph exists. FullScreen's viewfinder-corner
        // brackets are the closest documented visual metaphor for a "Focus mode" affordance.
        VolarIconName.Focus => "", // SUBSTITUTION: FullScreen (no MDL2 scope/target glyph)

        // SUBSTITUTION: no dedicated MDL2 "Inbox"/"tray" glyph. Mail is the closest documented
        // stand-in (both read as "things waiting for you").
        VolarIconName.Inbox => "", // SUBSTITUTION: Mail (no dedicated MDL2 inbox/tray glyph)

        // SUBSTITUTION: no distinct MDL2 glyph reliably documented for "today" vs. a generic
        // calendar (inventory §4's "GoToToday"-style candidates were judged too speculative to cite
        // as a real codepoint here). Reuses Calendar (same as `.Upcoming`) — Sidebar/nav-item
        // labels, not icon shape, are what actually distinguish Today vs. Upcoming (inventory §1.5).
        VolarIconName.Today => "", // SUBSTITUTION: reuses Calendar (no distinct MDL2 "today" glyph)

        // SUBSTITUTION: no per-frame procedural waveform glyph exists in MDL2, and this enum case is
        // only ever a small static toolbar glyph (inventory §1.4: the real animated waveform renders
        // via a dedicated Waveform control, not this icon). Reuses Microphone as the nearest
        // "audio-capture affordance" stand-in.
        VolarIconName.Waveform => "", // SUBSTITUTION: reuses Microphone (no MDL2 waveform glyph)

        // Home, Eject, Clock: contract lists these among the "no reliable glyph" group, but each has
        // a widely-documented, high-confidence MDL2 codepoint — flagged here for a Character Map
        // spot-check per the contract's instruction, not because a real substitution was made.
        VolarIconName.Home => "", // VERIFY: Home (widely documented; contract flags for a Character Map check anyway)
        VolarIconName.Eject => "", // VERIFY: Eject (widely documented; contract flags for a Character Map check anyway)
        VolarIconName.Clock => "", // VERIFY: Clock (widely documented; contract flags for a Character Map check anyway)

        // Cmd never reaches here in practice (IsTextMode short-circuits VolarIcon's render path)
        // but must still return a non-empty string so the "28/28 non-empty" completeness test
        // (VolarIconGlyphsTests) can assert every case without special-casing Cmd.
        VolarIconName.Cmd => "", // unused placeholder — Cmd renders "Ctrl" text instead, see IsTextMode.

        _ => throw new ArgumentOutOfRangeException(nameof(name), name, "Unmapped VolarIconName — every case must have a glyph or text-mode entry."),
    };
}
