// Services/State/AppearanceAndPersistenceService.cs — port of AppState.swift's appearance controls
// (§1.1 rows 2-6 + §1.16, lines 177-181 + 1644-1719) and ambient sound (§1.17 partial, line 1726).
// Inventory cluster J.
//
// FIX 4 (specs/003-windows-port/appstate-inventory.md §6, quoted verbatim there): `accent`/
// `density` used to have NO `UserDefaults` read-back in `init` and no persistence anywhere either,
// so a real launch silently reset both to their compiled-in defaults every time, discarding
// whatever Settings had set last session. The fix — quoted from the inventory's own header:
// "persisted choice wins, caller-supplied parameter is only the previews/tests fallback" — is
// implemented in this port's constructor exactly the way `ambient`/`customImageURL` already worked
// in Swift: assign the constructor parameter first, THEN override from the settings store if a
// value is present there. `SetAccent`/`SetDensity` persist on every call, mirroring
// `setAccent`/`setDensity` (`AppState.swift:1657-1668`).
//
// GLASS — Opus decision 3 (wave3c-services.md, binding, do not re-litigate): `Glass` gets NO
// setter and NO persistence. `AppState.glass` (§1.1 row 4) has neither in the Swift original either
// — "a real pre-existing gap, not something to silently 'fix' by inventing a `setGlass` the Mac app
// never had" (appstate-inventory.md §3, cluster J's own flag). Set once at construction, read-only
// forever after.
using Volar.Domain;
using Volar.Speech.Ambient;

namespace Volar.App.Services.State;

/// <summary>Port of `Theme.swift`'s `enum VolarAccent` (`.indigo/.teal/.amber/.magenta`) — the 4
/// selectable accent families. Raw persisted strings are the lowercase case names, matching Swift's
/// default `String`-backed `rawValue` exactly (`Theme.swift:125-126`).</summary>
public enum VolarAccent
{
    Indigo,
    Teal,
    Amber,
    Magenta,
}

/// <summary>Port of `Theme.swift`'s `enum Density` (`.cozy/.comfy/.roomy`) — row/section spacing.
/// Has no Swift `rawValue` of its own (plain enum); persistence uses the same three hand-picked
/// strings `AppState.densityPersistedID(_:)`/`densityFromPersistedID(_:)` already used
/// (`AppState.swift:1674-1698`).</summary>
public enum Density
{
    Cozy,
    Comfy,
    Roomy,
}

/// <summary>Port of `Theme.swift`'s `enum GlassLevel` (`.subtle/.standard/.heavy`) — per-control
/// glass/acrylic material intensity. See this file's header "GLASS" note: read-only, never
/// persisted, exactly like the Swift original.</summary>
public enum GlassLevel
{
    Subtle,
    Standard,
    Heavy,
}

public sealed class AppearanceAndPersistenceService
{
    /// <summary>`AppState.ambientKey` (`AppState.swift:358`).</summary>
    public const string AmbientKey = "volar.ambient";

    /// <summary>`AppState.customImageKey` (`AppState.swift:359`).</summary>
    public const string CustomImageKey = "volar.customImageURL";

    /// <summary>`AppState.accentKey` (`AppState.swift:387`) — FIX 4.</summary>
    public const string AccentKey = "volar.accent";

    /// <summary>`AppState.densityKey` (`AppState.swift:394`) — FIX 4.</summary>
    public const string DensityKey = "volar.density";

    private readonly ISettingsStore _settings;
    private readonly AmbientSoundPlayer _ambientSound;

    /// <param name="ambientSound">Defaults to a fresh <see cref="AmbientSoundPlayer"/> — cheap to
    /// construct (no audio graph is opened until <see cref="ToggleAmbientSound"/> actually starts
    /// playback), matching this codebase's established "construct real collaborators directly, no
    /// interface needed" convention for cheap leaf types (e.g. <c>VoicePlayback</c> in
    /// <c>AppNotificationToastChannelTests</c>).</param>
    /// <remarks>
    /// Constructor parameter defaults (<paramref name="accent"/>/<paramref name="density"/>/
    /// <paramref name="glass"/>/<paramref name="ambient"/>/<paramref name="customImagePath"/>) mirror
    /// Swift's `init(accent: VolarAccent = .indigo, density: Density = .comfy, glass: GlassLevel =
    /// .standard, ambient: AmbientMode = .none, customImageURL: URL? = nil, ...)`
    /// (`AppState.swift:399-403`) — the previews/tests fallback, overridden below by whatever the
    /// settings store already has (FIX 4's exact "assign parameter, then override" order).
    /// </remarks>
    public AppearanceAndPersistenceService(
        ISettingsStore settings,
        AmbientSoundPlayer? ambientSound = null,
        VolarAccent accent = VolarAccent.Indigo,
        Density density = Density.Comfy,
        GlassLevel glass = GlassLevel.Standard,
        AmbientMode ambient = AmbientMode.None,
        string? customImagePath = null)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _ambientSound = ambientSound ?? new AmbientSoundPlayer();

        Glass = glass; // no setter, no persistence — see file header "GLASS" note.

        Accent = accent;
        Density = density;
        Ambient = ambient;
        CustomImagePath = customImagePath;

        // Override from persisted user choice, if any — same order Swift's `init` applies
        // (ambient/customImageURL first, then accent/density immediately after — AppState.swift:
        // 420-434). Absent/garbage stored values leave the caller-supplied default standing rather
        // than falling back to a hardcoded default a second time, matching
        // `densityFromPersistedID`'s own doc comment on exactly this point.
        if (_settings.GetString(AmbientKey) is string ambientRaw && TryParseAmbient(ambientRaw, out var parsedAmbient))
        {
            Ambient = parsedAmbient;
        }
        if (_settings.GetString(CustomImageKey) is string storedPath)
        {
            CustomImagePath = storedPath;
        }
        if (_settings.GetString(AccentKey) is string accentRaw && TryParseAccent(accentRaw, out var parsedAccent))
        {
            Accent = parsedAccent;
        }
        if (_settings.GetString(DensityKey) is string densityRaw && TryParseDensity(densityRaw, out var parsedDensity))
        {
            Density = parsedDensity;
        }
    }

    public VolarAccent Accent { get; private set; }

    public Density Density { get; private set; }

    /// <summary>Read-only — see file header "GLASS" note (Opus decision 3).</summary>
    public GlassLevel Glass { get; }

    public AmbientMode Ambient { get; private set; }

    /// <summary>Plain file path string, matching the Swift original's own already-documented gap
    /// (`AppState.swift:1706-1709`: "not sandboxed today ... if sandboxing is ever enabled, this
    /// needs a security-scoped bookmark instead") — Windows has no equivalent sandbox restriction in
    /// this unpackaged deployment mode either, so the same plain-path persistence carries over
    /// unchanged (matches appstate-inventory.md §7's own framing of this exact gap).</summary>
    public string? CustomImagePath { get; private set; }

    /// <summary>Cross-cluster read (appstate-inventory.md §4): feeds
    /// <c>Volar.Reminders.ReminderContextGate.IsOtherAudioPlaying</c>. C5 is expected to wire
    /// <c>gate.IsOtherAudioPlaying = () =&gt; appearanceService.IsAmbientSoundPlaying;</c> once both
    /// are constructed — this service does not reach into <c>ReminderContextGate</c> itself (that
    /// collaborator's construction belongs to the composition root, same as
    /// <c>ReminderScheduler</c>'s own construction already does) — see this task's final report,
    /// "handoff."</summary>
    public bool IsAmbientSoundPlaying => _ambientSound.IsPlaying;

    /// <summary>Mirrors `setAccent(_:)` (`AppState.swift:1657-1660`) — FIX 4.</summary>
    public void SetAccent(VolarAccent accent)
    {
        Accent = accent;
        _settings.SetString(AccentKey, RawAccent(accent));
    }

    /// <summary>Mirrors `setDensity(_:)` (`AppState.swift:1665-1668`) — FIX 4.</summary>
    public void SetDensity(Density density)
    {
        Density = density;
        _settings.SetString(DensityKey, RawDensity(density));
    }

    /// <summary>Mirrors `setAmbient(_:)` (`AppState.swift:1701-1704`).</summary>
    public void SetAmbient(AmbientMode ambient)
    {
        Ambient = ambient;
        _settings.SetString(AmbientKey, RawAmbient(ambient));
    }

    /// <summary>Mirrors `setCustomImage(_:)` (`AppState.swift:1710-1719`): a non-null path forces
    /// <see cref="Ambient"/> to <see cref="AmbientMode.Custom"/> and persists both; a
    /// <see langword="null"/> path clears the property and removes the persisted key only (leaves
    /// <see cref="Ambient"/> alone), matching the Swift original's asymmetric branches exactly.</summary>
    public void SetCustomImage(string? path)
    {
        CustomImagePath = path;
        if (path is not null)
        {
            _settings.SetString(CustomImageKey, path);
            Ambient = AmbientMode.Custom;
            _settings.SetString(AmbientKey, RawAmbient(AmbientMode.Custom));
        }
        else
        {
            _settings.SetString(CustomImageKey, null); // removes the key — see ISettingsStore's contract.
        }
    }

    /// <summary>Mirrors `toggleAmbientSound()` (`AppState.swift:1726-1728`): toggles playback of
    /// whatever <see cref="Ambient"/> currently implies, defaulting to <see cref="AmbientMode.Rain"/>
    /// when <see cref="Ambient"/> is <see cref="AmbientMode.None"/> so the toolbar button always has
    /// something to toggle.</summary>
    public void ToggleAmbientSound() =>
        _ambientSound.Toggle(Ambient == AmbientMode.None ? AmbientMode.Rain : Ambient);

    // MARK: - Raw-value round trips
    //
    // `VolarAccent`'s raw strings match Swift's default `String`-backed rawValue (case name,
    // lowercased) exactly. `Density`/`AmbientMode` have no Swift `rawValue` in this port
    // (`Density`) or ARE reused from `Volar.Speech.Ambient.AmbientMode`, which likewise carries no
    // built-in raw-string form — both get the same hand-picked lowercase-case-name strings Swift's
    // own `AmbientMode: String` enum already uses (`none/rain/snow/embers/custom`,
    // `AppState.swift:24-25`) / `Density`'s existing `densityPersistedID` helper already used
    // (`cozy/comfy/roomy`).

    private static string RawAccent(VolarAccent accent) => accent switch
    {
        VolarAccent.Teal => "teal",
        VolarAccent.Amber => "amber",
        VolarAccent.Magenta => "magenta",
        _ => "indigo",
    };

    private static bool TryParseAccent(string raw, out VolarAccent accent)
    {
        switch (raw)
        {
            case "indigo": accent = VolarAccent.Indigo; return true;
            case "teal": accent = VolarAccent.Teal; return true;
            case "amber": accent = VolarAccent.Amber; return true;
            case "magenta": accent = VolarAccent.Magenta; return true;
            default: accent = default; return false;
        }
    }

    private static string RawDensity(Density density) => density switch
    {
        Density.Cozy => "cozy",
        Density.Roomy => "roomy",
        _ => "comfy",
    };

    private static bool TryParseDensity(string raw, out Density density)
    {
        switch (raw)
        {
            case "cozy": density = Density.Cozy; return true;
            case "comfy": density = Density.Comfy; return true;
            case "roomy": density = Density.Roomy; return true;
            default: density = default; return false;
        }
    }

    private static string RawAmbient(AmbientMode ambient) => ambient switch
    {
        AmbientMode.Rain => "rain",
        AmbientMode.Snow => "snow",
        AmbientMode.Embers => "embers",
        AmbientMode.Custom => "custom",
        _ => "none",
    };

    private static bool TryParseAmbient(string raw, out AmbientMode ambient)
    {
        switch (raw)
        {
            case "none": ambient = AmbientMode.None; return true;
            case "rain": ambient = AmbientMode.Rain; return true;
            case "snow": ambient = AmbientMode.Snow; return true;
            case "embers": ambient = AmbientMode.Embers; return true;
            case "custom": ambient = AmbientMode.Custom; return true;
            default: ambient = default; return false;
        }
    }
}
