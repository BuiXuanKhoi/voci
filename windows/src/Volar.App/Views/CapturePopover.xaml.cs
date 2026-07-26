// Views/CapturePopover.xaml.cs — see CapturePopover.xaml header. Port of PopoverView.swift
// (views-inventory.md §1.17), full fidelity per wave4-contract.md frozen decision 7. Every `Build*`
// method below is a direct, line-cited port of the correspondingly-named PopoverView.swift function;
// `Render()` (the bottom of this file) is the direct port of `PopoverView.body` (26-83)'s
// `if`-gated child list.
//
// RENDER STRATEGY: `Render()` clears and fully rebuilds `RootStack.Children` on every
// `CapturePopoverViewModel.PropertyChanged` notification, rather than diffing/patching the existing
// visual tree. This mirrors what SwiftUI itself does semantically (recompute `body` from state) but
// is a deliberate simplification on the WinUI side — a real diffing layer would need to match
// SwiftUI's `ForEach(id:)`-driven identity tracking practically feature-for-feature to be worth it,
// for a card this small (at most ~10 drafts x ~7 chips) that only re-renders on discrete user-driven
// state transitions (never per-frame, never per-keystroke). Flagged in this agent's final report as
// a documented design tradeoff, not an oversight.
using System.ComponentModel;
using System.Globalization;
using System.Numerics;
using Microsoft.UI; // `Colors` (Transparent/White) lives here in WinUI3, NOT Windows.UI.Colors (UWP).
using Microsoft.UI.Composition;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Volar.App.Services.State;
using Volar.App.ViewModels;
using Volar.App.Views.Controls;
using Volar.Core;
using Volar.Domain;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Volar.App.Views;

public sealed partial class CapturePopover : UserControl
{
    // Color.white.opacity(0.18) -> alpha = round(0.18*255) = 45.9 -> 46 = 0x2E (PopoverView.swift's
    // accent-button hairline stroke, e.g. actionsRow's Save button, 817-819).
    private static readonly SolidColorBrush WhiteOpacity18 = new(Color.FromArgb(0x2E, 255, 255, 255));

    private CapturePopoverViewModel? _viewModel;

    public CapturePopover()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Render();
            AnimateMount();
        };
    }

    /// <summary>Set by whichever composition-root/overlay-hosting code (Stage C) owns this popover's
    /// lifetime. Re-renders immediately on assignment; subscribes to
    /// <see cref="CapturePopoverViewModel.PropertyChanged"/> for the lifetime of the assignment.</summary>
    public CapturePopoverViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            if (ReferenceEquals(_viewModel, value))
            {
                return;
            }
            if (_viewModel is not null)
            {
                _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
            }
            _viewModel = value;
            if (_viewModel is not null)
            {
                _viewModel.PropertyChanged += OnViewModelPropertyChanged;
            }
            Render();
        }
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(Render);

    // No popover-local Escape/Enter KeyboardAccelerator handlers here: KeyboardAccelerators are
    // window-scope in WinUI, so registering them on this UserControl too would double-fire alongside
    // MainWindow.xaml.cs's root-level OnEscapeAccelerator/OnEnterAccelerator (~line 358), which
    // already dispatches to CapturePopoverViewModel.HandleEscape()/HandlePrimaryEnter() while the
    // capture scrim is visible, with args.Handled = true. Keyboard dispatch for this popover is owned
    // entirely by MainWindow's root accelerators.

    /// <summary>One-shot entrance animation — port of `PopoverView.body`'s `.onAppear` (76-82):
    /// `.spring(response: 0.2, dampingFraction: 0.86)` scale 0.96-&gt;1 + fade. NOT a repeat-forever
    /// loop (plays once per mount), so the gotcha's "gate loops on AnimationsEnabled" list doesn't
    /// technically apply, but this still skips itself when animations are system-disabled — same
    /// defensive convention every other animated control in this wave follows.</summary>
    private void AnimateMount()
    {
        if (!new UISettings().AnimationsEnabled)
        {
            return;
        }
        var visual = ElementCompositionPreview.GetElementVisual(RootGlass);
        var compositor = visual.Compositor;
        var width = (float)Math.Max(RootGlass.ActualWidth, RootGlass.Width);
        visual.CenterPoint = new Vector3(width / 2f, (float)Math.Max(RootGlass.ActualHeight, 1) / 2f, 0f);
        visual.Scale = new Vector3(0.96f, 0.96f, 1f);
        visual.Opacity = 0f;

        var scale = compositor.CreateSpringVector3Animation();
        scale.FinalValue = new Vector3(1f, 1f, 1f);
        scale.DampingRatio = 0.86f;
        scale.Period = TimeSpan.FromMilliseconds(200);

        var opacity = compositor.CreateScalarKeyFrameAnimation();
        opacity.InsertKeyFrame(1f, 1f);
        opacity.Duration = TimeSpan.FromMilliseconds(180);

        visual.StartAnimation("Scale", scale);
        visual.StartAnimation("Opacity", opacity);
    }

    // ============================================================================================
    // MARK: Render — port of PopoverView.body (26-83)
    // ============================================================================================

    private void Render()
    {
        if (_viewModel is null || RootStack is null)
        {
            return;
        }
        var vm = _viewModel;
        var resources = Application.Current.Resources;

        RootStack.Children.Clear();
        RootStack.Children.Add(BuildHintRow(vm));

        // The `.volarSpotlight(isActive: showTranscript)` inner group (32-60): the popover's "one
        // lit thing" while there's a NOW capture/confirm in progress.
        var spotlightContent = new StackPanel { Spacing = 0 };
        spotlightContent.Children.Add(BuildWaveformSection(vm));
        if (vm.ShowTranscript)
        {
            spotlightContent.Children.Add(BuildTranscriptSection(vm));
        }
        if (vm.ShowParsedCard)
        {
            spotlightContent.Children.Add(BuildParsedCard(vm));
        }
        if (vm.ShowVoiceDoneCard)
        {
            spotlightContent.Children.Add(BuildVoiceDoneCard(vm));
        }
        if (vm.ShowActions)
        {
            spotlightContent.Children.Add(BuildActionsRow(vm));
        }

        var spotlightHost = new Border { Child = spotlightContent };
        if (vm.ShowTranscript)
        {
            spotlightHost.Background = (Brush)resources["NowSpotlightVignetteBrush"];
        }
        RootStack.Children.Add(spotlightHost);

        if (vm.ShowError)
        {
            RootStack.Children.Add(BuildErrorActionsRow(vm));
        }
    }

    // ============================================================================================
    // MARK: Hint row — port of `hintRow`/`leftHint`/`Kbd`/`PulsingDot` (112-196, 986-1006, 1100-1125)
    // ============================================================================================

    private static FrameworkElement BuildHintRow(CapturePopoverViewModel vm)
    {
        var resources = Application.Current.Resources;
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var leftStack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (vm.ShowListeningDot)
        {
            leftStack.Children.Add(BuildPulsingDot());
        }
        leftStack.Children.Add(new TextBlock
        {
            Text = vm.HintText,
            FontSize = 11.5,
            TextWrapping = vm.State == CaptureState.Error ? TextWrapping.Wrap : TextWrapping.NoWrap,
            MaxLines = vm.State == CaptureState.Error ? 3 : 1,
            Foreground = BrushForHintTone(vm.HintToneValue),
            VerticalAlignment = VerticalAlignment.Center,
        });
        Grid.SetColumn(leftStack, 0);
        grid.Children.Add(leftStack);

        var rightStack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        rightStack.Children.Add(BuildKbd("Esc"));
        rightStack.Children.Add(new TextBlock
        {
            Text = "cancel",
            FontSize = 11.5,
            Opacity = 0.6,
            Foreground = (Brush)resources["VolarTextMutBrush"],
            VerticalAlignment = VerticalAlignment.Center,
        });
        Grid.SetColumn(rightStack, 1);
        grid.Children.Add(rightStack);

        return grid;
    }

    private static Brush BrushForHintTone(HintTone tone)
    {
        var resources = Application.Current.Resources;
        return tone switch
        {
            HintTone.Accent => (Brush)resources["AccentSolidBrush"],
            HintTone.Reschedule => (Brush)resources["VolarRescheduleBrush"],
            HintTone.Done => (Brush)resources["VolarDoneBrush"],
            _ => (Brush)resources["VolarTextMutBrush"],
        };
    }

    /// <summary>Port of the private `Kbd` struct (986-1006) — deliberately DISTINCT from
    /// Views/Controls/KeyBadge.xaml (per wave4-contract.md's explicit "do not merge" instruction):
    /// always the neutral mono style, never accent-aware.</summary>
    private static Border BuildKbd(string text)
    {
        var resources = Application.Current.Resources;
        return new Border
        {
            MinWidth = 16,
            MinHeight = 16,
            Padding = new Thickness(4, 0, 4, 0),
            CornerRadius = new CornerRadius(4), // Kbd's own one-off radius (PopoverView.swift:1001).
            BorderThickness = new Thickness(0.5),
            Background = (Brush)resources["VolarCardBrush"],
            BorderBrush = (Brush)resources["VolarBorderBrush"],
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = text,
                FontFamily = (FontFamily)resources["VolarMonoFontFamily"],
                FontSize = 10,
                FontWeight = FontWeights.Medium,
                Foreground = (Brush)resources["VolarTextSecBrush"],
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
    }

    /// <summary>Port of the private `PulsingDot` struct (1100-1125): expanding-ring pulse via a
    /// looping Composition scale+opacity animation (WinUI has no `.repeatForever` SwiftUI
    /// equivalent). One of the gotcha list's 3 explicitly-allowed repeat-forever Popover loops —
    /// gated on `UISettings.AnimationsEnabled` defensively (Swift's own `PulsingDot` does NOT check
    /// reduce-motion, a small inconsistency views-inventory.md §1.17 point 5 flags but doesn't
    /// mandate fixing; this port gates anyway for consistency with Spinner.cs's identical
    /// precedent).</summary>
    private static FrameworkElement BuildPulsingDot()
    {
        var accent = (Brush)Application.Current.Resources["AccentSolidBrush"];
        var host = new Grid { Width = 14, Height = 14, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

        var ring = new Ellipse
        {
            Width = 6,
            Height = 6,
            Stroke = accent,
            StrokeThickness = 2,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var core = new Ellipse
        {
            Width = 6,
            Height = 6,
            Fill = accent,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        host.Children.Add(ring);
        host.Children.Add(core);

        if (new UISettings().AnimationsEnabled)
        {
            var visual = ElementCompositionPreview.GetElementVisual(ring);
            var compositor = visual.Compositor;
            visual.CenterPoint = new Vector3(3f, 3f, 0f);

            var scale = compositor.CreateScalarKeyFrameAnimation();
            scale.InsertKeyFrame(0f, 1f);
            scale.InsertKeyFrame(1f, 2.4f);
            scale.Duration = TimeSpan.FromSeconds(1.2);
            scale.IterationBehavior = AnimationIterationBehavior.Forever;

            var opacity = compositor.CreateScalarKeyFrameAnimation();
            opacity.InsertKeyFrame(0f, 0.7f);
            opacity.InsertKeyFrame(1f, 0f);
            opacity.Duration = TimeSpan.FromSeconds(1.2);
            opacity.IterationBehavior = AnimationIterationBehavior.Forever;

            visual.StartAnimation("Scale.X", scale);
            visual.StartAnimation("Scale.Y", scale);
            visual.StartAnimation("Opacity", opacity);
        }

        return host;
    }

    // ============================================================================================
    // MARK: Waveform / done-check / try-again — port of `waveformSection`/`MicBreathingGlow`
    // (200-250, 1127-1157)
    // ============================================================================================

    private static FrameworkElement BuildWaveformSection(CapturePopoverViewModel vm)
    {
        var resources = Application.Current.Resources;
        var host = new Grid { Height = 42, Margin = new Thickness(0, 10, 0, 6) };

        if (vm.ShowWave)
        {
            // MicBreathingGlow (1133-1157) sits BEHIND the waveform (Swift: `.background(...)`),
            // active ONLY while `.recording` (never a resting loop) — added to the Grid first so
            // the Waveform (added second) paints on top of it.
            if (vm.WaveformActive)
            {
                host.Children.Add(BuildMicBreathingGlow());
            }
            host.Children.Add(new Waveform
            {
                Active = vm.WaveformActive,
                Bars = 32,
                BarHeight = 42,
                BarColor = (Brush)resources["AccentSolidBrush"],
                GlowColor = (Brush)resources["AccentGlowBrush"],
            });
        }
        else if (vm.ShowDoneCheck)
        {
            var badge = new Grid { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            badge.Children.Add(new Ellipse { Width = 32, Height = 32, Fill = (Brush)resources["VolarDoneBrush"] });
            badge.Children.Add(new VolarIcon
            {
                IconName = VolarIconName.Check,
                IconSize = 18,
                IconBrush = (Brush)resources["VolarBgBrush"],
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            });
            host.Children.Add(badge);
        }
        else if (vm.ShowTryAgainPlaceholder)
        {
            host.Children.Add(new TextBlock
            {
                Text = "Try again",
                FontSize = 13,
                Foreground = (Brush)resources["VolarRescheduleBrush"],
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }

        return host;
    }

    /// <summary>Port of the private `MicBreathingGlow` struct (1127-1157): a soft "breathing"
    /// opacity loop behind the waveform while `.recording` — one of the gotcha list's 3 explicitly-
    /// allowed repeat-forever Popover loops. Swift's `.blur(radius: 18)` has no WinUI equivalent
    /// without Win2D (frozen decision 2 forbids it) — same accepted structural gap Glass.xaml's own
    /// AcrylicBrush/NowSpotlightBrush already document; this renders as an unblurred, low-opacity
    /// rounded-rect fill instead, which is visually close enough for a soft glow behind a
    /// centered waveform. Gated on `UISettings.AnimationsEnabled`, matching Swift's own explicit
    /// `accessibilityReduceMotion` check (this is the ONE of the 3 loops where Swift itself already
    /// checks reduce-motion — see PulsingDot's doc comment for the contrast).</summary>
    private static FrameworkElement BuildMicBreathingGlow()
    {
        var glow = new Border
        {
            CornerRadius = new CornerRadius(12), // RoundedRectangle(cornerRadius: 12) — PopoverView.swift:1143.
            Background = (Brush)Application.Current.Resources["AccentGlowBrush"],
            IsHitTestVisible = false,
        };

        if (new UISettings().AnimationsEnabled)
        {
            glow.Opacity = 0.5;
            var keyFrames = new DoubleAnimationUsingKeyFrames { RepeatBehavior = RepeatBehavior.Forever, AutoReverse = true };
            keyFrames.KeyFrames.Add(new EasingDoubleKeyFrame { KeyTime = KeyTime.FromTimeSpan(TimeSpan.Zero), Value = 0.5 });
            keyFrames.KeyFrames.Add(new EasingDoubleKeyFrame { KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(1.6)), Value = 1.0, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } });
            Storyboard.SetTarget(keyFrames, glow);
            Storyboard.SetTargetProperty(keyFrames, "Opacity");
            var storyboard = new Storyboard();
            storyboard.Children.Add(keyFrames);
            glow.Loaded += (_, _) => storyboard.Begin();
            glow.Unloaded += (_, _) => storyboard.Stop();
        }
        else
        {
            // Port of Swift's `reduceMotion ? 0.6 : ...` static fallback (1145).
            glow.Opacity = 0.6;
        }

        return glow;
    }

    // ============================================================================================
    // MARK: Transcript — port of `transcriptSection`/`BlinkingCaret` (254-267, 1159-1176)
    // ============================================================================================

    private static FrameworkElement BuildTranscriptSection(CapturePopoverViewModel vm)
    {
        var resources = Application.Current.Resources;
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, MinHeight = 42, Margin = new Thickness(0, 8, 0, 4) };
        stack.Children.Add(new TextBlock
        {
            Text = vm.TranscriptText,
            FontSize = 14.5,
            TextWrapping = TextWrapping.Wrap,
            Foreground = vm.State == CaptureState.Recording ? (Brush)resources["VolarTextPriBrush"] : (Brush)resources["VolarTextSecBrush"],
            VerticalAlignment = VerticalAlignment.Top,
        });
        if (vm.ShowCaret)
        {
            stack.Children.Add(BuildBlinkingCaret());
        }
        return stack;
    }

    /// <summary>Port of the private `BlinkingCaret` struct (1159-1176): a HARD on/off cut (Swift's
    /// `steps(2, start)`, not eased) — expressed as a `DiscreteDoubleKeyFrame` Storyboard on
    /// `Opacity`, per wave4-contract.md's explicit "caret uses DISCRETE keyframes, hard cut"
    /// instruction (never a smooth `DoubleAnimation`).</summary>
    private static FrameworkElement BuildBlinkingCaret()
    {
        var caret = new Rectangle
        {
            Width = 2,
            Height = 16,
            Fill = (Brush)Application.Current.Resources["AccentSolidBrush"],
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 2, 0, 0),
        };

        if (new UISettings().AnimationsEnabled)
        {
            var keyFrames = new DoubleAnimationUsingKeyFrames { RepeatBehavior = RepeatBehavior.Forever };
            keyFrames.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = KeyTime.FromTimeSpan(TimeSpan.Zero), Value = 1 });
            keyFrames.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.45)), Value = 0 });
            keyFrames.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.9)), Value = 1 });
            Storyboard.SetTarget(keyFrames, caret);
            Storyboard.SetTargetProperty(keyFrames, "Opacity");
            var storyboard = new Storyboard();
            storyboard.Children.Add(keyFrames);
            caret.Loaded += (_, _) => storyboard.Begin();
            caret.Unloaded += (_, _) => storyboard.Stop();
        }

        return caret;
    }

    // ============================================================================================
    // MARK: Parsed card — port of `parsedCard`/`taskDraftCard`/`conflictAdvisoryRow` (285-372)
    // ============================================================================================

    private static FrameworkElement BuildParsedCard(CapturePopoverViewModel vm)
    {
        var resources = Application.Current.Resources;
        var inner = new StackPanel { Spacing = 10 };
        var drafts = vm.ConfirmDrafts;
        for (var i = 0; i < drafts.Count; i++)
        {
            if (i > 0)
            {
                inner.Children.Add(new Rectangle { Height = 0.5, Fill = (Brush)resources["VolarBorderBrush"], HorizontalAlignment = HorizontalAlignment.Stretch });
            }
            inner.Children.Add(BuildTaskDraftCard(vm, drafts[i], showRemove: drafts.Count > 1, isPrimary: i == 0));
        }

        return new Border
        {
            Padding = new Thickness(12),
            Background = (Brush)resources["VolarCardBrush"],
            BorderBrush = (Brush)resources["NowRingBrush"],
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(12), // Metrics.xaml VolarCornerRadiusGlass (PopoverView.swift:299, 12).
            Margin = new Thickness(0, 6, 0, 0),
            Child = inner,
        };
    }

    private static FrameworkElement BuildTaskDraftCard(CapturePopoverViewModel vm, ConfirmDraft draft, bool showRemove, bool isPrimary)
    {
        var resources = Application.Current.Resources;
        var root = new StackPanel { Spacing = 8 };

        var titleRow = new Grid();
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var titleText = new TextBlock
        {
            Text = draft.Task.Title,
            FontSize = 13.5,
            FontWeight = FontWeights.Medium,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 3,
            Foreground = isPrimary ? (Brush)resources["VolarNowAccentSoftBrush"] : (Brush)resources["VolarTextPriBrush"],
        };
        Grid.SetColumn(titleText, 0);
        titleRow.Children.Add(titleText);

        if (showRemove)
        {
            titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var removeButton = BuildIconButton(VolarIconName.X, 9, (Brush)resources["VolarTextMutBrush"]);
            removeButton.Click += (_, _) => vm.RemoveDraft(draft.Id);
            Grid.SetColumn(removeButton, 1);
            titleRow.Children.Add(removeButton);
        }
        root.Children.Add(titleRow);

        root.Children.Add(BuildAttributeChips(vm, draft));

        var conditionRows = BuildConditionRows(vm, draft);
        if (conditionRows is not null)
        {
            root.Children.Add(conditionRows);
        }

        var conflictRow = BuildConflictAdvisoryRow(vm, draft);
        if (conflictRow is not null)
        {
            root.Children.Add(conflictRow);
        }

        return root;
    }

    private static Button BuildIconButton(VolarIconName icon, double size, Brush color) => new()
    {
        Content = new VolarIcon { IconName = icon, IconSize = size, IconBrush = color },
        Background = new SolidColorBrush(Colors.Transparent),
        BorderThickness = new Thickness(0),
        Padding = new Thickness(4),
        VerticalAlignment = VerticalAlignment.Top,
    };

    private static FrameworkElement? BuildConflictAdvisoryRow(CapturePopoverViewModel vm, ConfirmDraft draft)
    {
        if (draft.Conflicts.Count == 0 || draft.ConflictDismissed)
        {
            return null;
        }
        var row = new Grid { Margin = new Thickness(0, 2, 0, 0) };
        row.Children.Add(new TextBlock
        {
            Text = CapturePopoverFormatting.ConflictAdvisoryText(draft.Conflicts[0]),
            FontSize = 11.5,
            Foreground = (Brush)Application.Current.Resources["VolarRescheduleBrush"],
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
        });
        row.Tapped += (_, _) => vm.DismissConflictAdvisory(draft.Id);
        return row;
    }

    // ============================================================================================
    // MARK: Attribute chips — port of `attributeChips`/`Chip` (374-453, 1008-1059)
    // ============================================================================================

    private static FrameworkElement BuildAttributeChips(CapturePopoverViewModel vm, ConfirmDraft draft)
    {
        var flow = new FlowPanel { ItemSpacing = 6, LineSpacing = 6 };
        var task = draft.Task;

        if (task.Deadline is ParsedValue<DateTimeOffset> deadline && !draft.Dismissed.Contains(ChipKind.Deadline))
        {
            flow.Children.Add(BuildChip(
                deadline.Value.ToString("MMM d, h:mm tt", CultureInfo.InvariantCulture),
                deadline.IsUncertain, draft.Accepted.Contains(ChipKind.Deadline), mono: true,
                onAccept: () => vm.AcceptUncertainAttribute(ChipKind.Deadline, draft.Id),
                onDismiss: () => vm.DismissAttribute(ChipKind.Deadline, draft.Id)));
        }
        if (task.EstimateMinutes is ParsedValue<int> estimate && !draft.Dismissed.Contains(ChipKind.Estimate))
        {
            flow.Children.Add(BuildChip(
                CapturePopoverFormatting.FormattedDuration(estimate.Value),
                estimate.IsUncertain, draft.Accepted.Contains(ChipKind.Estimate), mono: true,
                onAccept: () => vm.AcceptUncertainAttribute(ChipKind.Estimate, draft.Id),
                onDismiss: () => vm.DismissAttribute(ChipKind.Estimate, draft.Id)));
        }
        if (task.Priority is ParsedValue<int> priority && !draft.Dismissed.Contains(ChipKind.Priority))
        {
            flow.Children.Add(BuildChip(
                CapturePopoverFormatting.PriorityLabel(priority.Value),
                priority.IsUncertain, draft.Accepted.Contains(ChipKind.Priority), mono: false,
                onAccept: () => vm.AcceptUncertainAttribute(ChipKind.Priority, draft.Id),
                onDismiss: () => vm.DismissAttribute(ChipKind.Priority, draft.Id)));
        }
        if (task.ReminderOverride is ParsedValue<ReminderPolicy> reminder && !draft.Dismissed.Contains(ChipKind.Reminder))
        {
            flow.Children.Add(BuildChip(
                CapturePopoverFormatting.ReminderLabel(reminder.Value),
                reminder.IsUncertain, draft.Accepted.Contains(ChipKind.Reminder), mono: false,
                onAccept: () => vm.AcceptUncertainAttribute(ChipKind.Reminder, draft.Id),
                onDismiss: () => vm.DismissAttribute(ChipKind.Reminder, draft.Id)));
        }
        if (task.Recurrence is ParsedValue<Recurrence> recurrence && !draft.Dismissed.Contains(ChipKind.Recurrence))
        {
            flow.Children.Add(BuildChip(
                CapturePopoverFormatting.RecurrenceLabel(recurrence.Value),
                recurrence.IsUncertain, draft.Accepted.Contains(ChipKind.Recurrence), mono: false,
                onAccept: () => vm.AcceptUncertainAttribute(ChipKind.Recurrence, draft.Id),
                onDismiss: () => vm.DismissAttribute(ChipKind.Recurrence, draft.Id)));
        }
        if (task.Kind != TaskKind.Task && !draft.Dismissed.Contains(ChipKind.Kind))
        {
            flow.Children.Add(BuildChip(
                CapturePopoverFormatting.KindLabel(task.Kind),
                uncertain: false, accepted: true, mono: false,
                onAccept: null,
                onDismiss: () => vm.DismissAttribute(ChipKind.Kind, draft.Id)));
        }
        if (task.FollowUpReview && !draft.Dismissed.Contains(ChipKind.FollowUpReview))
        {
            flow.Children.Add(BuildChip(
                "+ Review after done",
                uncertain: false, accepted: true, mono: false,
                onAccept: null,
                onDismiss: () => vm.DismissAttribute(ChipKind.FollowUpReview, draft.Id)));
        }
        return flow;
    }

    /// <summary>Port of the private `Chip` struct (1008-1059). WinUI's `Border` has no dashed-stroke
    /// property, so the "uncertain" dashed-capsule outline (Swift: `Capsule().strokeBorder(...,
    /// style: StrokeStyle(..., dash: [3, 2]))`) is built from a `Rectangle` overlay
    /// (`StrokeDashArray`) instead of a `Border.BorderBrush` — a solid `Rectangle` (no dash) covers
    /// the confident/present case.</summary>
    private static Grid BuildChip(string label, bool uncertain, bool accepted, bool mono, Action? onAccept, Action onDismiss)
    {
        var resources = Application.Current.Resources;
        var showsDashed = uncertain && !accepted;

        Brush foreground = showsDashed
            ? (Brush)resources["VolarTextSecBrush"]
            : mono ? (Brush)resources["VolarInstrumentBrush"] : (Brush)resources["VolarTextPriBrush"];

        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 5,
            VerticalAlignment = VerticalAlignment.Center,
            Padding = new Thickness(9, 0, 9, 0),
        };
        if (showsDashed)
        {
            content.Children.Add(new TextBlock { Text = "?", FontSize = 10, FontWeight = FontWeights.Bold, Foreground = foreground, VerticalAlignment = VerticalAlignment.Center });
        }
        content.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 11.5,
            FontWeight = FontWeights.Medium,
            FontFamily = mono ? (FontFamily)resources["VolarMonoFontFamily"] : (FontFamily)resources["VolarUiFontFamily"],
            Foreground = foreground,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var dismissButton = BuildIconButton(VolarIconName.X, 8, (Brush)resources["VolarTextMutBrush"]);
        dismissButton.VerticalAlignment = VerticalAlignment.Center;
        dismissButton.Click += (_, _) => onDismiss();
        content.Children.Add(dismissButton);

        var background = new Rectangle
        {
            RadiusX = 11,
            RadiusY = 11,
            Fill = showsDashed
                ? new SolidColorBrush(Colors.Transparent)
                : mono
                    ? new SolidColorBrush((Color)resources["VolarInstrumentDim"]) { Opacity = 0.16 }
                    : (Brush)resources["VolarCardBrush"],
            Stroke = showsDashed
                ? (Brush)resources["VolarTextMutBrush"]
                : mono ? (Brush)resources["VolarInstrumentDimBrush"] : (Brush)resources["VolarBorderBrush"],
            StrokeThickness = 0.5,
            StrokeDashArray = showsDashed ? new DoubleCollection { 3, 2 } : null,
        };

        var root = new Grid { Height = 22 };
        root.Children.Add(background);
        root.Children.Add(content);
        if (showsDashed && onAccept is not null)
        {
            root.Tapped += (_, _) => onAccept();
        }
        return root;
    }

    // ============================================================================================
    // MARK: Condition rows / dependency picker — port of `conditionRows`/`conditionRow`/
    // `taskDoneRow`/`dependencyPicker` (455-570)
    // ============================================================================================

    private static FrameworkElement? BuildConditionRows(CapturePopoverViewModel vm, ConfirmDraft draft)
    {
        var conditions = draft.Task.Conditions;
        var visible = new List<int>();
        for (var i = 0; i < conditions.Count; i++)
        {
            if (!draft.DismissedConditions.Contains(i))
            {
                visible.Add(i);
            }
        }
        if (visible.Count == 0)
        {
            return null;
        }

        var stack = new StackPanel { Spacing = 6 };
        foreach (var index in visible)
        {
            stack.Children.Add(BuildConditionRow(vm, draft, index, conditions[index]));
        }
        return stack;
    }

    private static FrameworkElement BuildConditionRow(CapturePopoverViewModel vm, ConfirmDraft draft, int index, ParsedCondition condition)
    {
        var resources = Application.Current.Resources;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(new Ellipse { Width = 5, Height = 5, Fill = (Brush)resources["VolarInstrumentDimBrush"], VerticalAlignment = VerticalAlignment.Center });

        switch (condition)
        {
            case ParsedCondition.TaskDone taskDone:
                row.Children.Add(BuildTaskDoneRow(vm, draft, index, taskDone));
                break;
            case ParsedCondition.AfterDate afterDate:
                row.Children.Add(BuildChip(
                    $"After {afterDate.Date.ToString("MMM d", CultureInfo.InvariantCulture)}",
                    afterDate.Confidence < 0.7, draft.AcceptedConditions.Contains(index), mono: true,
                    onAccept: () => vm.AcceptUncertainCondition(index, draft.Id),
                    onDismiss: () => vm.DismissCondition(index, draft.Id)));
                break;
            case ParsedCondition.External external:
                row.Children.Add(BuildChip(
                    $"Waiting: {external.Description}",
                    external.Confidence < 0.7, draft.AcceptedConditions.Contains(index), mono: false,
                    onAccept: () => vm.AcceptUncertainCondition(index, draft.Id),
                    onDismiss: () => vm.DismissCondition(index, draft.Id)));
                break;
        }
        return row;
    }

    private static FrameworkElement BuildTaskDoneRow(CapturePopoverViewModel vm, ConfirmDraft draft, int index, ParsedCondition.TaskDone taskDone)
    {
        if (draft.ResolvedTaskDone.TryGetValue(index, out var resolvedId))
        {
            var resolvedTask = vm.OpenTasks.FirstOrDefault(t => t.Id == resolvedId);
            var title = resolvedTask.Title ?? taskDone.TitleQuery;
            return BuildChip(
                $"After: {title}",
                uncertain: false, accepted: true, mono: false,
                onAccept: null,
                onDismiss: () => vm.DismissCondition(index, draft.Id));
        }
        return BuildDependencyPicker(vm, draft, index, taskDone.TitleQuery);
    }

    /// <summary>Port of `dependencyPicker(titleQuery:index:draft:)` (531-570): a native `Menu` ->
    /// WinUI `MenuFlyout` populated from <see cref="CapturePopoverViewModel.OpenTasks"/>, capped at
    /// 100 (539) — plus the always-present "Skip — no dependency" entry (534-536).</summary>
    private static FrameworkElement BuildDependencyPicker(CapturePopoverViewModel vm, ConfirmDraft draft, int index, string titleQuery)
    {
        var resources = Application.Current.Resources;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };

        var flyout = new MenuFlyout();
        var skip = new MenuFlyoutItem { Text = "Skip — no dependency" };
        skip.Click += (_, _) => vm.ResolveTaskDone(index, null, draft.Id);
        flyout.Items.Add(skip);

        var candidates = vm.OpenTasks.Take(100).ToArray();
        if (candidates.Length > 0)
        {
            flyout.Items.Add(new MenuFlyoutSeparator());
            foreach (var candidate in candidates)
            {
                var item = new MenuFlyoutItem { Text = candidate.Title };
                var taskId = candidate.Id;
                item.Click += (_, _) => vm.ResolveTaskDone(index, taskId, draft.Id);
                flyout.Items.Add(item);
            }
        }

        var pickerContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        pickerContent.Children.Add(new TextBlock { Text = "?", FontSize = 10, FontWeight = FontWeights.Bold, Foreground = (Brush)resources["VolarInstrumentBrush"] });
        pickerContent.Children.Add(new TextBlock
        {
            Text = $"After: “{titleQuery}”",
            FontSize = 11.5,
            FontWeight = FontWeights.Medium,
            Foreground = (Brush)resources["VolarInstrumentBrush"],
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });

        var pickerButton = new Button
        {
            Flyout = flyout,
            Content = pickerContent,
            Padding = new Thickness(9, 0, 9, 0),
            Height = 22,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0.5),
            BorderBrush = (Brush)resources["VolarInstrumentDimBrush"],
            CornerRadius = new CornerRadius(11),
        };
        row.Children.Add(pickerButton);

        var dismissButton = BuildIconButton(VolarIconName.X, 9, (Brush)resources["VolarTextMutBrush"]);
        dismissButton.Click += (_, _) => vm.DismissCondition(index, draft.Id);
        row.Children.Add(dismissButton);

        return row;
    }

    // ============================================================================================
    // MARK: Voice-done card — port of `voiceDoneCard`/`voiceDoneConfirmContent`/
    // `voiceDoneNoMatchContent`/`voiceDoneConfirmButton`/`voiceDoneDismissButton` (572-732)
    // ============================================================================================

    private static FrameworkElement BuildVoiceDoneCard(CapturePopoverViewModel vm)
    {
        var resources = Application.Current.Resources;
        var inner = new StackPanel { Spacing = 10 };
        if (vm.VoiceDoneConfirmState is VoiceDoneConfirm confirm)
        {
            inner.Children.Add(BuildVoiceDoneConfirmContent(vm, confirm));
        }
        else if (vm.VoiceDoneNoMatchTranscript is not null)
        {
            inner.Children.Add(BuildVoiceDoneNoMatchContent(vm));
        }

        return new Border
        {
            Padding = new Thickness(12),
            Background = (Brush)resources["VolarCardBrush"],
            BorderBrush = (Brush)resources["NowRingBrush"],
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(12),
            Margin = new Thickness(0, 6, 0, 0),
            Child = inner,
        };
    }

    private static FrameworkElement BuildVoiceDoneConfirmContent(CapturePopoverViewModel vm, VoiceDoneConfirm confirm)
    {
        var resources = Application.Current.Resources;
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(new TextBlock
        {
            Text = CapturePopoverFormatting.VoiceDoneQuestion(confirm),
            FontSize = 13.5,
            FontWeight = FontWeights.Medium,
            Foreground = (Brush)resources["VolarNowAccentSoftBrush"],
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
        });

        if (confirm.Candidates.Count == 1)
        {
            var only = confirm.Candidates[0];
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            row.Children.Add(BuildVoiceDoneDismissButton(vm));
            row.Children.Add(BuildVoiceDoneConfirmButton(
                CapturePopoverFormatting.VoiceDoneOneTapLabel(confirm.Action, only.Title),
                () => _ = vm.ConfirmVoiceDoneAsync(only.TaskId)));
            stack.Children.Add(row);
        }
        else
        {
            var list = new StackPanel { Spacing = 6, Margin = new Thickness(0, 2, 0, 0) };
            foreach (var match in confirm.Candidates.Take(10))
            {
                var button = new Button
                {
                    Content = new TextBlock
                    {
                        Text = match.Title,
                        FontSize = 12.5,
                        FontWeight = FontWeights.Medium,
                        MaxLines = 1,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        Foreground = (Brush)resources["VolarTextPriBrush"],
                    },
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                    Padding = new Thickness(9, 0, 9, 0),
                    Height = 26,
                    Background = (Brush)resources["VolarCardBrush"],
                    BorderBrush = (Brush)resources["VolarBorderBrush"],
                    BorderThickness = new Thickness(0.5),
                    CornerRadius = new CornerRadius(7),
                };
                var taskId = match.TaskId;
                button.Click += (_, _) => _ = vm.ConfirmVoiceDoneAsync(taskId);
                list.Children.Add(button);
            }
            stack.Children.Add(list);
            stack.Children.Add(BuildVoiceDoneDismissButton(vm));
        }
        return stack;
    }

    private static FrameworkElement BuildVoiceDoneNoMatchContent(CapturePopoverViewModel vm)
    {
        var resources = Application.Current.Resources;
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(new TextBlock
        {
            Text = "Didn't find a matching task for that.",
            FontSize = 13,
            FontWeight = FontWeights.Medium,
            Foreground = (Brush)resources["VolarTextSecBrush"],
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
        });
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(BuildVoiceDoneDismissButton(vm));
        row.Children.Add(BuildVoiceDoneConfirmButton("Capture as new task instead", () => _ = vm.CaptureVoiceDoneAsNewTaskAsync()));
        stack.Children.Add(row);
        return stack;
    }

    private static Button BuildVoiceDoneDismissButton(CapturePopoverViewModel vm)
    {
        var resources = Application.Current.Resources;
        var button = new Button
        {
            Content = new TextBlock { Text = "Not this", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = (Brush)resources["VolarTextPriBrush"] },
            Padding = new Thickness(14, 0, 14, 0),
            Height = 34,
            Background = (Brush)resources["VolarCardBrush"],
            BorderBrush = (Brush)resources["VolarBorderBrush"],
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(9),
        };
        button.Click += (_, _) => _ = vm.DismissVoiceDoneConfirmAsync();
        return button;
    }

    private static Button BuildVoiceDoneConfirmButton(string title, Action action)
    {
        var accent = (Brush)Application.Current.Resources["AccentSolidBrush"];
        var button = new Button
        {
            Content = new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Colors.White), MaxLines = 1 },
            Padding = new Thickness(14, 0, 14, 0),
            Height = 34,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Background = accent,
            BorderBrush = WhiteOpacity18,
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(9),
        };
        button.Click += (_, _) => action();
        return button;
    }

    // ============================================================================================
    // MARK: Actions row (Cancel/Save) — port of `actionsRow`/`saveLabel` (775-834)
    // ============================================================================================

    private static FrameworkElement BuildActionsRow(CapturePopoverViewModel vm)
    {
        var resources = Application.Current.Resources;
        var grid = new Grid { Margin = new Thickness(0, 10, 0, 0), ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var cancelButton = new Button
        {
            Content = new TextBlock { Text = "Cancel", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = (Brush)resources["VolarTextPriBrush"] },
            Padding = new Thickness(14, 0, 14, 0),
            Height = 34,
            Background = (Brush)resources["VolarCardBrush"],
            BorderBrush = (Brush)resources["VolarBorderBrush"],
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(9),
        };
        cancelButton.Click += (_, _) => _ = vm.CancelAsync();
        Grid.SetColumn(cancelButton, 0);
        grid.Children.Add(cancelButton);

        var saving = vm.State == CaptureState.Saving;
        var accent = (Brush)resources["AccentSolidBrush"];
        var accentSurface = (Brush)resources["AccentSurfaceBrush"];

        FrameworkElement saveContent = saving
            ? new Spinner { SpinnerColor = accent, SpinnerSize = 14, HorizontalAlignment = HorizontalAlignment.Center }
            : new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                HorizontalAlignment = HorizontalAlignment.Center,
                Children =
                {
                    new TextBlock { Text = vm.SaveLabel, FontSize = 13, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Colors.White) },
                    new TextBlock { Text = "↵", FontSize = 12, Opacity = 0.85, Foreground = new SolidColorBrush(Colors.White) },
                },
            };

        var saveButton = new Button
        {
            Content = saveContent,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Height = 34,
            Background = saving ? accentSurface : accent,
            BorderBrush = saving ? accentSurface : WhiteOpacity18,
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(9),
            IsEnabled = !saving,
        };
        saveButton.Click += (_, _) => _ = vm.ConfirmSaveAsync();
        Grid.SetColumn(saveButton, 1);
        grid.Children.Add(saveButton);

        return grid;
    }

    // ============================================================================================
    // MARK: Error / consent rows — port of `errorActionsRow`/`cloudConsentActionsRow` (838-979);
    // `dictationConsentActionsRow` is N/A per wave4-contract.md frozen decision 7 and is NOT ported.
    // ============================================================================================

    private static FrameworkElement BuildErrorActionsRow(CapturePopoverViewModel vm) =>
        vm.PendingCloudConsent ? BuildCloudConsentActionsRow(vm) : BuildPlainErrorActionsRow(vm);

    private static FrameworkElement BuildPlainErrorActionsRow(CapturePopoverViewModel vm)
    {
        var resources = Application.Current.Resources;
        var grid = new Grid { Margin = new Thickness(0, 10, 0, 0), ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var dismissButton = new Button
        {
            Content = new TextBlock { Text = "Dismiss", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = (Brush)resources["VolarTextPriBrush"], HorizontalAlignment = HorizontalAlignment.Center },
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Height = 34,
            Background = (Brush)resources["VolarCardBrush"],
            BorderBrush = (Brush)resources["VolarBorderBrush"],
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(9),
        };
        dismissButton.Click += (_, _) => _ = vm.CancelAsync();
        Grid.SetColumn(dismissButton, 0);
        grid.Children.Add(dismissButton);

        var tryAgainButton = new Button
        {
            Content = new TextBlock { Text = "Try again", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Colors.White), HorizontalAlignment = HorizontalAlignment.Center },
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Height = 34,
            Background = (Brush)resources["AccentSolidBrush"],
            BorderBrush = WhiteOpacity18,
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(9),
        };
        tryAgainButton.Click += (_, _) => _ = vm.StartCaptureAsync();
        Grid.SetColumn(tryAgainButton, 1);
        grid.Children.Add(tryAgainButton);

        return grid;
    }

    private static FrameworkElement BuildCloudConsentActionsRow(CapturePopoverViewModel vm)
    {
        var resources = Application.Current.Resources;
        var stack = new StackPanel { Spacing = 8, Margin = new Thickness(0, 10, 0, 0) };

        var declineButton = new Button
        {
            Content = new TextBlock { Text = "Keep parsing on-device only", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Colors.White), MaxLines = 1 },
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Height = 34,
            Background = (Brush)resources["AccentSolidBrush"],
            BorderBrush = WhiteOpacity18,
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(9),
        };
        // Enter -> decline (the privacy-preserving default), per PopoverView.swift 957's
        // `.keyboardShortcut(.defaultAction)` on this exact button; centralized in
        // CapturePopoverViewModel.HandlePrimaryEnter() rather than a per-button accelerator.
        declineButton.Click += (_, _) => _ = vm.ResolveCloudConsentAsync(false);
        stack.Children.Add(declineButton);

        var allowButton = new Button
        {
            Content = new TextBlock
            {
                Text = "Allow cloud parsing (sends this text online)",
                FontSize = 12,
                FontWeight = FontWeights.Medium,
                Foreground = (Brush)resources["VolarTextSecBrush"],
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                MaxLines = 2,
            },
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Height = 34,
            Background = (Brush)resources["VolarCardBrush"],
            BorderBrush = (Brush)resources["VolarBorderBrush"],
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(9),
        };
        allowButton.Click += (_, _) => _ = vm.ResolveCloudConsentAsync(true);
        stack.Children.Add(allowButton);

        return stack;
    }
}
