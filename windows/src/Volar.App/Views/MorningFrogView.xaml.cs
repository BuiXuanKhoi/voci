// Views/MorningFrogView.xaml.cs — see MorningFrogView.xaml header. Port of MorningFrogView.swift.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Animation;
using Volar.App.ViewModels;
using Windows.UI.ViewManagement;

namespace Volar.App.Views;

public sealed partial class MorningFrogView : UserControl
{
    private MorningFrogViewModel? _viewModel;
    private Storyboard? _pulseStoryboard;

    public MorningFrogView()
    {
        InitializeComponent();
        Loaded += (_, _) => StartOrRestartPulse();
        Unloaded += (_, _) => StopPulse();
    }

    /// <summary>`.easeInOut(duration: 1.2).repeatForever(autoreverses: true)`
    /// (MorningFrogView.swift:101) — animates `PulseGlow`'s Opacity 0 -> 0.55 -> 0 forever. See
    /// MorningFrogView.xaml's "Voice CTA" comment for why this Border stands in for a real blurred
    /// glow. Gated on <see cref="UISettings.AnimationsEnabled"/> per this wave's gotcha list (a
    /// full-window modal is one of the surfaces explicitly allowed a repeat-forever loop, same as
    /// Spinner/Popover's own pulses).</summary>
    private void StartOrRestartPulse()
    {
        StopPulse();

        if (!new UISettings().AnimationsEnabled)
        {
            PulseGlow.Opacity = 0;
            return;
        }

        var animation = new DoubleAnimation
        {
            From = 0,
            To = 0.55,
            Duration = new Duration(TimeSpan.FromSeconds(1.2)),
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseInOut },
        };
        Storyboard.SetTarget(animation, PulseGlow);
        Storyboard.SetTargetProperty(animation, "Opacity");

        _pulseStoryboard = new Storyboard();
        _pulseStoryboard.Children.Add(animation);
        _pulseStoryboard.Begin();
    }

    private void StopPulse()
    {
        _pulseStoryboard?.Stop();
        _pulseStoryboard = null;
    }

    public MorningFrogViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            _viewModel = value;
            Bindings.Update();
        }
    }

    /// <summary>Mirrors the candidate row's `.onTapGesture` (MorningFrogView.swift:184-187) — the
    /// row template has no `Button`/`Command` (a `Border` + `Tapped`, matching Swift's own plain
    /// `.contentShape(Rectangle()).onTapGesture` rather than a button chrome), so this reads the
    /// tapped element's `DataContext` (a <see cref="FrogCandidateViewModel"/>, per the
    /// `CandidateTemplate` DataTemplate's `x:DataType`) directly instead of a bound
    /// `CommandParameter`.</summary>
    private void OnCandidateTapped(object sender, TappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: FrogCandidateViewModel candidate } && ViewModel is not null)
        {
            if (ViewModel.PickCommand.CanExecute(candidate.Id))
            {
                ViewModel.PickCommand.Execute(candidate.Id);
            }
        }
    }
}
