// Theme/ThemeStateTests.cs — wave4-contract.md Stage A deliverable "unit tests for
// ThemeState/glyph map". Covers: AccentColorTable's accent -> 4-color mapping (cross-checked
// against Accents.xaml's own hex literals), DensityMetrics' density -> 3-metric mapping
// (cross-checked against Metrics.xaml), ThemeState's persistence pass-through
// (AppearanceAndPersistenceService underneath), the IAccentBrushWriter seam (a recording fake
// stands in for the Application.Resources-touching real implementation, which needs a live XAML
// runtime and is out of scope for a headless xunit host), and PropertyChanged/Changed notification.
using System.ComponentModel;
using Volar.App.Services.State;
using Volar.App.Theme;
using Volar.Domain;
using Volar.Speech.Ambient;
using Xunit;

namespace Volar.App.Tests.Theme;

public sealed class ThemeStateTests
{
    // ------------------------------------------------------------------------------------------
    // MARK: AccentColorTable — cross-checked against Accents.xaml's hex literals verbatim.
    // ------------------------------------------------------------------------------------------

    [Theory]
    [InlineData(VolarAccent.Indigo, 0x5B, 0x8D, 0xEF, 0x7F, 0xA5, 0xF5)]
    [InlineData(VolarAccent.Teal, 0x3D, 0xBF, 0xAF, 0x63, 0xD6, 0xC7)]
    [InlineData(VolarAccent.Amber, 0xD9, 0x85, 0x3D, 0xE9, 0xA1, 0x65)]
    [InlineData(VolarAccent.Magenta, 0xD1, 0x6B, 0xC0, 0xE3, 0x8B, 0xD4)]
    public void AccentColorTable_SolidAndHover_MatchAccentsXamlHexLiterals(
        VolarAccent accent, byte solidR, byte solidG, byte solidB, byte hoverR, byte hoverG, byte hoverB)
    {
        var colors = AccentColorTable.For(accent);

        Assert.Equal(255, colors.Solid.A);
        Assert.Equal(solidR, colors.Solid.R);
        Assert.Equal(solidG, colors.Solid.G);
        Assert.Equal(solidB, colors.Solid.B);

        Assert.Equal(255, colors.Hover.A);
        Assert.Equal(hoverR, colors.Hover.R);
        Assert.Equal(hoverG, colors.Hover.G);
        Assert.Equal(hoverB, colors.Hover.B);
    }

    [Theory]
    [InlineData(VolarAccent.Indigo)]
    [InlineData(VolarAccent.Teal)]
    [InlineData(VolarAccent.Amber)]
    [InlineData(VolarAccent.Magenta)]
    public void AccentColorTable_SurfaceAndGlow_ShareSolidsRgbAtTheDocumentedAlphas(VolarAccent accent)
    {
        var colors = AccentColorTable.For(accent);

        // surface = solid.opacity(0.15) -> alpha 0x26 (Accents.xaml comment, verbatim).
        Assert.Equal(0x26, colors.Surface.A);
        Assert.Equal(colors.Solid.R, colors.Surface.R);
        Assert.Equal(colors.Solid.G, colors.Surface.G);
        Assert.Equal(colors.Solid.B, colors.Surface.B);

        // glow = solid.opacity(0.45) -> alpha 0x73 (Accents.xaml comment, verbatim).
        Assert.Equal(0x73, colors.Glow.A);
        Assert.Equal(colors.Solid.R, colors.Glow.R);
        Assert.Equal(colors.Solid.G, colors.Glow.G);
        Assert.Equal(colors.Solid.B, colors.Glow.B);
    }

    // ------------------------------------------------------------------------------------------
    // MARK: DensityMetrics — cross-checked against Metrics.xaml's per-density x:Double resources.
    // ------------------------------------------------------------------------------------------

    [Theory]
    [InlineData(Density.Cozy, 7, 3, 18)]
    [InlineData(Density.Comfy, 10, 4, 22)]
    [InlineData(Density.Roomy, 14, 6, 30)]
    public void DensityMetrics_MatchMetricsXamlPerDensityValues(
        Density density, double rowPadY, double rowGap, double sectionGap)
    {
        var metrics = DensityMetrics.For(density);

        Assert.Equal(rowPadY, metrics.RowPadY);
        Assert.Equal(rowGap, metrics.RowGap);
        Assert.Equal(sectionGap, metrics.SectionGap);
    }

    // ------------------------------------------------------------------------------------------
    // MARK: ThemeState — persistence pass-through + notification.
    // ------------------------------------------------------------------------------------------

    [Fact]
    public void Constructor_WithNoBrushWriter_DoesNotThrow_AndPassesThroughInitialAccent()
    {
        var appearance = new AppearanceAndPersistenceService(new InMemorySettingsStore(), accent: VolarAccent.Teal);

        var state = new ThemeState(appearance); // brushWriter: null — headless-safe, per contract.

        Assert.Equal(VolarAccent.Teal, state.Accent);
    }

    [Fact]
    public void Constructor_WithBrushWriter_AppliesThePersistedAccentImmediately()
    {
        var appearance = new AppearanceAndPersistenceService(new InMemorySettingsStore(), accent: VolarAccent.Magenta);
        var writer = new RecordingAccentBrushWriter();

        _ = new ThemeState(appearance, writer);

        // A prior session's persisted accent must repaint the shared brushes on construction, not
        // just on the next explicit SetAccent call — see ThemeState's constructor doc comment.
        Assert.Equal(VolarAccent.Magenta, writer.LastAppliedAccent);
    }

    [Fact]
    public void SetAccent_PersistsThroughAppearanceService_AndInvokesBrushWriter()
    {
        var settings = new InMemorySettingsStore();
        var appearance = new AppearanceAndPersistenceService(settings);
        var writer = new RecordingAccentBrushWriter();
        var state = new ThemeState(appearance, writer);

        state.SetAccent(VolarAccent.Teal);

        Assert.Equal(VolarAccent.Teal, state.Accent);
        Assert.Equal(VolarAccent.Teal, appearance.Accent); // FIX 4 persistence still owned by the service.
        Assert.Equal(VolarAccent.Teal, writer.LastAppliedAccent);
        Assert.Equal(2, writer.ApplyCount); // constructor's initial sync (1) + this SetAccent call (1) = 2
    }

    [Fact]
    public void SetAccent_WithNoBrushWriter_StillPersists_AndDoesNotThrow()
    {
        var appearance = new AppearanceAndPersistenceService(new InMemorySettingsStore());
        var state = new ThemeState(appearance);

        state.SetAccent(VolarAccent.Amber);

        Assert.Equal(VolarAccent.Amber, state.Accent);
        Assert.Equal(VolarAccent.Amber, appearance.Accent);
    }

    [Fact]
    public void SetDensity_UpdatesTheThreeDerivedMetrics()
    {
        var appearance = new AppearanceAndPersistenceService(new InMemorySettingsStore());
        var state = new ThemeState(appearance);

        state.SetDensity(Density.Roomy);

        Assert.Equal(Density.Roomy, state.Density);
        Assert.Equal(14, state.RowPadY);
        Assert.Equal(6, state.RowGap);
        Assert.Equal(30, state.SectionGap);
    }

    [Fact]
    public void SetDensity_RaisesPropertyChanged_ForDensityAndAllThreeMetrics()
    {
        var appearance = new AppearanceAndPersistenceService(new InMemorySettingsStore());
        var state = new ThemeState(appearance);
        var raised = new List<string>();
        state.PropertyChanged += (_, e) => raised.Add(e.PropertyName!);

        state.SetDensity(Density.Cozy);

        Assert.Contains(nameof(ThemeState.Density), raised);
        Assert.Contains(nameof(ThemeState.RowPadY), raised);
        Assert.Contains(nameof(ThemeState.RowGap), raised);
        Assert.Contains(nameof(ThemeState.SectionGap), raised);
    }

    [Fact]
    public void SetAccent_RaisesChangedEvent()
    {
        var appearance = new AppearanceAndPersistenceService(new InMemorySettingsStore());
        var state = new ThemeState(appearance);
        var changedRaised = 0;
        state.Changed += (_, _) => changedRaised++;

        state.SetAccent(VolarAccent.Teal);

        Assert.Equal(1, changedRaised);
    }

    [Fact]
    public void Glass_PassesThroughReadOnly_FromAppearanceService()
    {
        var appearance = new AppearanceAndPersistenceService(new InMemorySettingsStore(), glass: GlassLevel.Heavy);
        var state = new ThemeState(appearance);

        Assert.Equal(GlassLevel.Heavy, state.Glass);
    }

    [Fact]
    public void Ambient_And_CustomImagePath_And_IsAmbientSoundPlaying_PassThrough()
    {
        var appearance = new AppearanceAndPersistenceService(new InMemorySettingsStore());
        var state = new ThemeState(appearance);

        Assert.Equal(AmbientMode.None, state.Ambient);
        Assert.Null(state.CustomImagePath);
        Assert.False(state.IsAmbientSoundPlaying);

        state.SetAmbient(AmbientMode.Rain);
        Assert.Equal(AmbientMode.Rain, state.Ambient);

        state.SetCustomImage(@"C:\pictures\bg.png");
        Assert.Equal(@"C:\pictures\bg.png", state.CustomImagePath);
        Assert.Equal(AmbientMode.Custom, state.Ambient); // SetCustomImage's own asymmetric contract.
    }

    /// <summary>Stands in for <see cref="ApplicationAccentBrushWriter"/> (which needs a live
    /// Application.Resources and cannot run in this headless test host) — records every accent it
    /// was asked to apply, including the constructor's initial sync call.</summary>
    private sealed class RecordingAccentBrushWriter : IAccentBrushWriter
    {
        public VolarAccent? LastAppliedAccent { get; private set; }

        public int ApplyCount { get; private set; }

        public void ApplyAccent(VolarAccent accent)
        {
            LastAppliedAccent = accent;
            ApplyCount++;
        }
    }
}
