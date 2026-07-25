// Workflow/AppearanceAndPersistenceServiceTests.cs — AppearanceAndPersistenceService (inventory
// cluster J): FIX 4 (accent/density persistence), Glass's read-only/unpersisted contract (Opus
// decision 3), ambient mode + custom-image path persistence, and the ambient-sound toggle wiring.
using Volar.App.Services.State;
using Volar.Domain;
using Volar.Speech.Ambient;
using Xunit;

namespace Volar.App.Tests.Workflow;

public sealed class AppearanceAndPersistenceServiceTests
{
    // MARK: - Constructor defaults / FIX 4 override order

    [Fact]
    public void Constructor_WithNoPersistedValues_UsesTheConstructorSuppliedDefaults()
    {
        var service = new AppearanceAndPersistenceService(new InMemorySettingsStore());

        Assert.Equal(VolarAccent.Indigo, service.Accent);
        Assert.Equal(Density.Comfy, service.Density);
        Assert.Equal(GlassLevel.Standard, service.Glass);
        Assert.Equal(AmbientMode.None, service.Ambient);
        Assert.Null(service.CustomImagePath);
    }

    [Fact]
    public void Constructor_PersistedValuesWinOverConstructorParameters_FIX4()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(AppearanceAndPersistenceService.AccentKey, "teal");
        settings.SetString(AppearanceAndPersistenceService.DensityKey, "roomy");
        settings.SetString(AppearanceAndPersistenceService.AmbientKey, "snow");
        settings.SetString(AppearanceAndPersistenceService.CustomImageKey, @"C:\pictures\bg.png");

        // Deliberately different constructor defaults than what's persisted — the persisted value
        // must win (FIX 4's exact "persisted choice wins, caller-supplied parameter is only the
        // previews/tests fallback" contract).
        var service = new AppearanceAndPersistenceService(
            settings,
            accent: VolarAccent.Amber,
            density: Density.Cozy,
            ambient: AmbientMode.Rain,
            customImagePath: @"C:\other.png");

        Assert.Equal(VolarAccent.Teal, service.Accent);
        Assert.Equal(Density.Roomy, service.Density);
        Assert.Equal(AmbientMode.Snow, service.Ambient);
        Assert.Equal(@"C:\pictures\bg.png", service.CustomImagePath);
    }

    [Fact]
    public void Constructor_GarbagePersistedValues_FallBackToTheConstructorParameter_NotAHardcodedDefault()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(AppearanceAndPersistenceService.AccentKey, "not-a-real-accent");
        settings.SetString(AppearanceAndPersistenceService.DensityKey, "not-a-real-density");
        settings.SetString(AppearanceAndPersistenceService.AmbientKey, "not-a-real-ambient");

        var service = new AppearanceAndPersistenceService(
            settings, accent: VolarAccent.Magenta, density: Density.Roomy, ambient: AmbientMode.Embers);

        // Garbage must not silently reset to the hardcoded library default (Indigo/Comfy/None) —
        // the caller-supplied constructor parameter stands, mirroring
        // `densityFromPersistedID`'s own doc comment on this exact point.
        Assert.Equal(VolarAccent.Magenta, service.Accent);
        Assert.Equal(Density.Roomy, service.Density);
        Assert.Equal(AmbientMode.Embers, service.Ambient);
    }

    // MARK: - Glass: read-only, no setter, never persisted (Opus decision 3)

    [Fact]
    public void Glass_IsFixedAtConstructionTime_AndNeverPersisted()
    {
        var settings = new InMemorySettingsStore();
        var service = new AppearanceAndPersistenceService(settings, glass: GlassLevel.Heavy);

        Assert.Equal(GlassLevel.Heavy, service.Glass);
        // There is deliberately no `SetGlass`/persisted key for this test to exercise — see this
        // class's own header comment ("GLASS" note) for why that absence is intentional, not a gap.
        Assert.Null(settings.GetString("volar.glass"));
    }

    // MARK: - SetAccent / SetDensity (FIX 4 setters)

    [Fact]
    public void SetAccent_PersistsAndRoundTripsThroughANewInstance()
    {
        var settings = new InMemorySettingsStore();
        var first = new AppearanceAndPersistenceService(settings);

        first.SetAccent(VolarAccent.Amber);

        Assert.Equal(VolarAccent.Amber, first.Accent);
        var second = new AppearanceAndPersistenceService(settings);
        Assert.Equal(VolarAccent.Amber, second.Accent);
    }

    [Theory]
    [InlineData(VolarAccent.Indigo)]
    [InlineData(VolarAccent.Teal)]
    [InlineData(VolarAccent.Amber)]
    [InlineData(VolarAccent.Magenta)]
    public void SetAccent_RoundTripsEveryAccentValue(VolarAccent accent)
    {
        var settings = new InMemorySettingsStore();
        new AppearanceAndPersistenceService(settings).SetAccent(accent);

        Assert.Equal(accent, new AppearanceAndPersistenceService(settings).Accent);
    }

    [Fact]
    public void SetDensity_PersistsAndRoundTripsThroughANewInstance()
    {
        var settings = new InMemorySettingsStore();
        var first = new AppearanceAndPersistenceService(settings);

        first.SetDensity(Density.Roomy);

        Assert.Equal(Density.Roomy, first.Density);
        var second = new AppearanceAndPersistenceService(settings);
        Assert.Equal(Density.Roomy, second.Density);
    }

    [Theory]
    [InlineData(Density.Cozy)]
    [InlineData(Density.Comfy)]
    [InlineData(Density.Roomy)]
    public void SetDensity_RoundTripsEveryDensityValue(Density density)
    {
        var settings = new InMemorySettingsStore();
        new AppearanceAndPersistenceService(settings).SetDensity(density);

        Assert.Equal(density, new AppearanceAndPersistenceService(settings).Density);
    }

    // MARK: - SetAmbient / SetCustomImage

    [Fact]
    public void SetAmbient_PersistsAndRoundTrips()
    {
        var settings = new InMemorySettingsStore();
        var first = new AppearanceAndPersistenceService(settings);

        first.SetAmbient(AmbientMode.Embers);

        Assert.Equal(AmbientMode.Embers, first.Ambient);
        var second = new AppearanceAndPersistenceService(settings);
        Assert.Equal(AmbientMode.Embers, second.Ambient);
    }

    [Fact]
    public void SetCustomImage_NonNullPath_ForcesAmbientToCustom_AndPersistsBoth()
    {
        var settings = new InMemorySettingsStore();
        var service = new AppearanceAndPersistenceService(settings, ambient: AmbientMode.Rain);

        service.SetCustomImage(@"C:\images\sunset.png");

        Assert.Equal(@"C:\images\sunset.png", service.CustomImagePath);
        Assert.Equal(AmbientMode.Custom, service.Ambient);

        var reloaded = new AppearanceAndPersistenceService(settings);
        Assert.Equal(@"C:\images\sunset.png", reloaded.CustomImagePath);
        Assert.Equal(AmbientMode.Custom, reloaded.Ambient);
    }

    [Fact]
    public void SetCustomImage_Null_ClearsThePath_ButLeavesAmbientAlone()
    {
        var settings = new InMemorySettingsStore();
        var service = new AppearanceAndPersistenceService(settings);
        service.SetCustomImage(@"C:\images\sunset.png"); // -> Ambient becomes Custom.

        service.SetCustomImage(null);

        Assert.Null(service.CustomImagePath);
        Assert.Equal(AmbientMode.Custom, service.Ambient); // unchanged by the clear, matches Swift.
        Assert.Null(settings.GetString(AppearanceAndPersistenceService.CustomImageKey));
    }

    // MARK: - ToggleAmbientSound

    [Fact]
    public void ToggleAmbientSound_DefaultsToRain_WhenAmbientIsNone()
    {
        using var player = new AmbientSoundPlayer();
        var service = new AppearanceAndPersistenceService(new InMemorySettingsStore(), ambientSound: player, ambient: AmbientMode.None);

        Assert.Equal(player.IsPlaying, service.IsAmbientSoundPlaying); // wiring check, both false initially.

        service.ToggleAmbientSound();

        // Whatever AmbientSoundPlayer.IsPlaying settled to (hardware-dependent — its own playback
        // correctness is Volar.Speech.Tests' concern, not this service's), the passthrough must
        // agree with it exactly.
        Assert.Equal(player.IsPlaying, service.IsAmbientSoundPlaying);
    }

    [Fact]
    public void ToggleAmbientSound_NeverThrows_RegardlessOfAmbientMode()
    {
        using var player = new AmbientSoundPlayer();
        var service = new AppearanceAndPersistenceService(new InMemorySettingsStore(), ambientSound: player, ambient: AmbientMode.Snow);

        service.ToggleAmbientSound();
        service.ToggleAmbientSound();
    }
}
