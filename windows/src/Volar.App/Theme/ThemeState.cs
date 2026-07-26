// Theme/ThemeState.cs — bridges AppearanceAndPersistenceService (Services/State, the persisted
// source of truth) to the XAML resource layer. wave4-contract.md Stage A deliverable 6 + frozen
// decisions 9/10/11:
//   - decision 9 (accent): the 4 `AccentSolidBrush/HoverBrush/SurfaceBrush/GlowBrush` entries in
//     Application.Resources stay SINGLE SolidColorBrush instances; SetAccent mutates their `.Color`
//     IN PLACE so every XAML consumer using `{StaticResource AccentSolidBrush}` updates instantly,
//     with no rebind needed.
//   - decision 10 (density): density can't propagate through x:Double resources, so density-
//     dependent metrics are exposed here as plain INotifyPropertyChanged doubles
//     (RowPadY/RowGap/SectionGap) for views to `{x:Bind}` against.
//   - decision 11 (glass): read-only, no setter — passed through from
//     AppearanceAndPersistenceService.Glass unchanged (that service itself already enforces "no
//     SetGlass", Opus decision 3, wave3c-services.md).
//
// THREAD SAFETY: every mutating method here (SetAccent/SetDensity/SetAmbient/SetCustomImage/
// ToggleAmbientSound) is UI-thread-only. SetAccent's brush mutation specifically touches
// Application.Resources' shared SolidColorBrush instances, which are DispatcherQueue-affine WinUI
// objects — per this wave's wave-wide rule ("never touch a DependencyObject without
// DispatcherQueue.TryEnqueue"), callers driven by a service event (which may fire off the UI
// thread) must marshal to the UI thread themselves before calling ThemeState's setters; ThemeState
// does not do this marshaling internally, matching e.g. TaskListService's own contract of raising
// its change event "on the UI thread" rather than hopping threads itself.
//
// TESTABILITY SEAM: <see cref="IAccentBrushWriter"/> is the seam the contract's brief asked for —
// <see cref="ApplicationAccentBrushWriter"/> is the real, Application.Resources-touching
// implementation (requires a live XAML runtime); passing `null` (the default) or a test double
// lets <see cref="ThemeState"/> itself, and its accent/density MAPPING logic
// (<see cref="AccentColorTable"/>/<see cref="DensityMetrics"/>), be unit-tested headlessly — see
// windows/tests/Volar.App.Tests/Theme/ThemeStateTests.cs.
using System.ComponentModel;
using Volar.App.Services.State;
using Volar.Speech.Ambient;

namespace Volar.App.Theme;

/// <summary>The seam between <see cref="ThemeState.SetAccent"/> and the actual
/// Application.Resources brush mutation — see this file's header "TESTABILITY SEAM" note.</summary>
public interface IAccentBrushWriter
{
    /// <summary>Mutate the 4 shared accent brushes' `.Color` in place for <paramref name="accent"/>.
    /// UI-thread-only (see this file's header "THREAD SAFETY" note).</summary>
    void ApplyAccent(VolarAccent accent);
}

/// <summary>The one owner of the 4 shared accent-brush KEYS (frozen decision 9) — must be
/// constructed and invoked on the UI thread; touches
/// <see cref="Microsoft.UI.Xaml.Application.Current"/>.Resources directly, so it cannot be
/// exercised from a headless unit-test host (no XAML runtime there). Wired up by Stage C's
/// composition root (this Stage-A agent does not touch CompositionRoot.cs/App.xaml.cs, per the
/// contract's hard rules) — construct as
/// <c>new ThemeState(appearanceService, new ApplicationAccentBrushWriter())</c>.</summary>
public sealed class ApplicationAccentBrushWriter : IAccentBrushWriter
{
    public void ApplyAccent(VolarAccent accent)
    {
        var resources = Microsoft.UI.Xaml.Application.Current.Resources;
        var colors = AccentColorTable.For(accent);
        ((Microsoft.UI.Xaml.Media.SolidColorBrush)resources["AccentSolidBrush"]).Color = colors.Solid;
        ((Microsoft.UI.Xaml.Media.SolidColorBrush)resources["AccentHoverBrush"]).Color = colors.Hover;
        ((Microsoft.UI.Xaml.Media.SolidColorBrush)resources["AccentSurfaceBrush"]).Color = colors.Surface;
        ((Microsoft.UI.Xaml.Media.SolidColorBrush)resources["AccentGlowBrush"]).Color = colors.Glow;
    }
}

/// <summary>`VolarAccent` -> the 4 derived roles (`Accent` struct, Theme.swift:112-149), duplicated
/// numerically from Accents.xaml's hex literals so <see cref="ApplicationAccentBrushWriter"/> can
/// mutate the shared brushes' `.Color` without a resource-dictionary round trip for every value
/// (only the brush KEYS — "AccentSolidBrush" etc. — are looked up from Application.Resources; the
/// per-family color VALUES live here, matching Accents.xaml's own values 1:1 — see
/// ThemeStateTests.cs for the cross-check that keeps the two in sync). PUBLIC (not internal) so
/// that cross-check can run from Volar.App.Tests without needing an InternalsVisibleTo entry added
/// to Volar.App.csproj — a file this wave's agents are barred from editing.</summary>
public static class AccentColorTable
{
    public static (Windows.UI.Color Solid, Windows.UI.Color Hover, Windows.UI.Color Surface, Windows.UI.Color Glow) For(VolarAccent accent)
    {
        var (solidRgb, hoverRgb) = accent switch
        {
            VolarAccent.Teal => (0x3DBFAFu, 0x63D6C7u), // Accents.xaml VolarTealSolid/Hover
            VolarAccent.Amber => (0xD9853Du, 0xE9A165u), // Accents.xaml VolarAccentAmberSolid/Hover
            VolarAccent.Magenta => (0xD16BC0u, 0xE38BD4u), // Accents.xaml VolarMagentaSolid/Hover
            _ => (0x86B9FFu, 0xB3D2FFu), // Indigo (default) — Accents.xaml VolarIndigoSolid/Hover
        };
        var solid = FromRgb(solidRgb, 0xFF);
        var hover = FromRgb(hoverRgb, 0xFF);
        // surface = solid.opacity(0.15) -> alpha round(0.15*255) = 38.25 -> 38 = 0x26 (Theme.swift's
        // Accent computed property; matches Accents.xaml's *Surface colors exactly).
        var surface = FromRgb(solidRgb, 0x26);
        // glow = solid.opacity(0.45) -> alpha round(0.45*255) = 114.75 -> 115 = 0x73 (matches
        // Accents.xaml's *Glow colors exactly).
        var glow = FromRgb(solidRgb, 0x73);
        return (solid, hover, surface, glow);
    }

    private static Windows.UI.Color FromRgb(uint rgb, byte alpha) =>
        Windows.UI.Color.FromArgb(alpha, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
}

/// <summary>`Density` -> `rowPadY`/`rowGap`/`sectionGap` (Theme.swift:153-179), duplicated
/// numerically from Metrics.xaml's per-density `x:Double` resources — <see cref="ThemeState"/>
/// exposes these as plain doubles (not resource lookups) precisely because density needs runtime
/// re-evaluation that `{StaticResource}` can't provide (frozen decision 10). PUBLIC for the same
/// test-access reason as <see cref="AccentColorTable"/> above.</summary>
public static class DensityMetrics
{
    public static (double RowPadY, double RowGap, double SectionGap) For(Density density) => density switch
    {
        Density.Cozy => (7, 3, 18), // Metrics.xaml VolarRowPadYCozy/RowGapCozy/SectionGapCozy
        Density.Roomy => (14, 6, 30), // Metrics.xaml VolarRowPadYRoomy/RowGapRoomy/SectionGapRoomy
        _ => (10, 4, 22), // Comfy (default) — Metrics.xaml VolarRowPadYComfy/RowGapComfy/SectionGapComfy
    };
}

/// <summary>The Views-layer front door onto <see cref="AppearanceAndPersistenceService"/> — see
/// this file's header for the full design rationale.</summary>
public sealed class ThemeState : INotifyPropertyChanged
{
    private readonly AppearanceAndPersistenceService _appearance;
    private readonly IAccentBrushWriter? _brushWriter;

    /// <param name="brushWriter">Pass <see langword="null"/> (the default) in a headless test host;
    /// pass <see cref="ApplicationAccentBrushWriter"/> from the real composition root so
    /// <see cref="SetAccent"/> actually repaints the shared brushes.</param>
    public ThemeState(AppearanceAndPersistenceService appearance, IAccentBrushWriter? brushWriter = null)
    {
        _appearance = appearance ?? throw new ArgumentNullException(nameof(appearance));
        _brushWriter = brushWriter;

        // Sync the shared brushes to whatever accent was persisted/constructed BEFORE this
        // ThemeState existed (e.g. a prior session's SetAccent(Teal)) — without this, the brushes
        // would sit at Accents.xaml's compiled-in Indigo default until the user picks a DIFFERENT
        // accent in the current session, silently ignoring their persisted choice on first paint.
        _brushWriter?.ApplyAccent(_appearance.Accent);
    }

    /// <inheritdoc />
    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Coarse-grained companion to <see cref="PropertyChanged"/> for consumers that just
    /// want "something in the theme changed, re-check everything" (this task's brief: "a `Changed`
    /// event") — e.g. a view re-reading every density metric at once rather than subscribing to 3
    /// separate property names.</summary>
    public event EventHandler? Changed;

    public VolarAccent Accent => _appearance.Accent;

    public Density Density => _appearance.Density;

    /// <summary>Read-only — see this file's header "frozen decision 11" note.</summary>
    public GlassLevel Glass => _appearance.Glass;

    public AmbientMode Ambient => _appearance.Ambient;

    public string? CustomImagePath => _appearance.CustomImagePath;

    public bool IsAmbientSoundPlaying => _appearance.IsAmbientSoundPlaying;

    public double RowPadY => DensityMetrics.For(Density).RowPadY;

    public double RowGap => DensityMetrics.For(Density).RowGap;

    public double SectionGap => DensityMetrics.For(Density).SectionGap;

    /// <summary>Persists the choice (via <see cref="AppearanceAndPersistenceService.SetAccent"/>)
    /// AND — when a real <see cref="IAccentBrushWriter"/> was supplied — mutates the 4 shared
    /// brushes in place. UI-thread-only when a real writer is present; see file header.</summary>
    public void SetAccent(VolarAccent accent)
    {
        _appearance.SetAccent(accent);
        _brushWriter?.ApplyAccent(accent);
        RaiseChanged(nameof(Accent));
    }

    public void SetDensity(Density density)
    {
        _appearance.SetDensity(density);
        RaiseChanged(nameof(Density), nameof(RowPadY), nameof(RowGap), nameof(SectionGap));
    }

    public void SetAmbient(AmbientMode ambient)
    {
        _appearance.SetAmbient(ambient);
        RaiseChanged(nameof(Ambient));
    }

    public void SetCustomImage(string? path)
    {
        _appearance.SetCustomImage(path);
        // Mirrors AppearanceAndPersistenceService.SetCustomImage's own asymmetric contract: a
        // non-null path also flips Ambient to Custom; a null path only clears CustomImagePath. This
        // notifies both properties unconditionally — cheap, and correct either way since a no-op
        // PropertyChanged for an unchanged value is harmless.
        RaiseChanged(nameof(CustomImagePath), nameof(Ambient));
    }

    public void ToggleAmbientSound()
    {
        _appearance.ToggleAmbientSound();
        RaiseChanged(nameof(IsAmbientSoundPlaying));
    }

    private void RaiseChanged(params string[] propertyNames)
    {
        foreach (var name in propertyNames)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
