// ViewModels/OnboardingViewModel.cs — B4 (Settings + Onboarding), Wave 4. Backs
// Views/OnboardingView.*, porting Volar/Sources/Views/OnboardingView.swift per
// specs/003-windows-port/views-inventory.md SS1.13 and wave4-contract.md decision 8.
//
// Headless-constructible, no XAML types (frozen decision 12) — the only collaborator is
// ISettingsStore (to persist the "has onboarded" flag on Complete()). Step-content
// (title/subtitle/buttons) and the mic-permission-settings launch (`ms-settings:privacy-microphone`
// via `Launcher.LaunchUriAsync`) live in the View's code-behind, per this wave's "FileOpenPicker/
// FolderPicker calls live in code-behind" rule extended to every WinRT API that needs a live UI
// thread/window context this VM must not depend on.
using Volar.Domain;

namespace Volar.App.ViewModels;

public sealed class OnboardingViewModel : System.ComponentModel.INotifyPropertyChanged
{
    /// <summary>MUST match App.xaml.cs's own `HasOnboardedKey` literal exactly — that file's own
    /// doc comment: `@AppStorage("hasOnboardedV1")` (appstate-inventory.md SS2/SS8), duplicated
    /// here rather than shared because App.xaml.cs is off-limits to every Stage A/B agent (wave4-
    /// contract.md frozen decision 13) and its constant is `private`. Cross-checked in
    /// OnboardingViewModelTests.cs against the same literal.</summary>
    public const string HasOnboardedSettingsKey = "hasOnboardedV1";

    public const int TotalSteps = 3;

    private readonly ISettingsStore _settings;

    public OnboardingViewModel(ISettingsStore settings, int initialStep = 1)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        Step = Clamp(initialStep);
    }

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Fired once <see cref="Complete"/> persists the onboarded flag — the View's Stage-C
    /// host subscribes to dismiss/replace this overlay. Port of Swift's `onComplete: () -> Void`
    /// init parameter (OnboardingView.swift:9).</summary>
    public event EventHandler? Completed;

    /// <summary>1-based, matching Swift's `@State private var step: Int` (OnboardingView.swift:8,
    /// default 1) and its "Step X of 3" footer text (OnboardingView.swift:55) 1:1.</summary>
    public int Step { get; private set; }

    public void GoToStep(int step)
    {
        var clamped = Clamp(step);
        if (clamped == Step)
        {
            return;
        }
        Step = clamped;
        PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(nameof(Step)));
    }

    /// <summary>Port of `withAnimation { step = N }` at each step's "next" call site
    /// (OnboardingView.swift:128,178,193) — the crossfade transition itself is a View-layer concern
    /// (Storyboard), this only advances the state driving it.</summary>
    public void Advance() => GoToStep(Step + 1);

    /// <summary>Port of step 3's "Start using Volar"/"Skip for now" buttons (OnboardingView.swift:
    /// 257-286), both of which call the same `onComplete()` — persists `hasOnboardedV1` (mirroring
    /// the `@AppStorage` write App.xaml.cs otherwise gates its Maybe-show sheets on) and raises
    /// <see cref="Completed"/> for the host to react to.</summary>
    public void Complete()
    {
        _settings.SetBool(HasOnboardedSettingsKey, true);
        Completed?.Invoke(this, EventArgs.Empty);
    }

    private static int Clamp(int step) => Math.Max(1, Math.Min(TotalSteps, step));
}
