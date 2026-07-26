// Views/Controls/Segmented.xaml.cs — see Segmented.xaml header. Port of
// SettingsView.swift's private `Segmented<T>` (lines 817-849).
//
// GENERIC-NESS NOTE: WinUI/XAML cannot declare `x:Class="...Segmented`1"` for a generic
// UserControl (the XAML compiler requires a concrete, non-generic class), so unlike Swift's
// `Segmented<T: Hashable>`, this control's `Options`/`SelectedId` are typed `object` — every call
// site boxes its enum/int/string id, exactly mirroring the boxing SettingsView.swift's OWN call
// sites already do implicitly by binding through `.rawValue`/hand-picked string ids wherever the
// underlying Swift enum isn't `Hashable` (SpeechEngineChoice, ParseEnginePreference, Density — see
// that file's own comments at each Picker/Segmented call site). `object.Equals` is used for
// selection comparison, which is correct for boxed enums/ints/strings (value semantics preserved
// through boxing).
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Volar.App.Views.Controls;

/// <summary>One selectable option in a <see cref="Segmented"/> row. Port of SettingsView.swift's
/// private <c>SegmentOption&lt;T&gt;</c> (lines 810-814).</summary>
public sealed class SegmentOption
{
    public SegmentOption(object id, string label, bool disabled = false)
    {
        Id = id ?? throw new ArgumentNullException(nameof(id));
        Label = label ?? throw new ArgumentNullException(nameof(label));
        Disabled = disabled;
    }

    public object Id { get; }

    public string Label { get; }

    public bool Disabled { get; }
}

public sealed partial class Segmented : UserControl
{
    public static readonly DependencyProperty OptionsProperty = DependencyProperty.Register(
        nameof(Options), typeof(IReadOnlyList<SegmentOption>), typeof(Segmented),
        new PropertyMetadata(Array.Empty<SegmentOption>(), OnOptionsChanged));

    public static readonly DependencyProperty SelectedIdProperty = DependencyProperty.Register(
        nameof(SelectedId), typeof(object), typeof(Segmented), new PropertyMetadata(null, OnSelectedIdChanged));

    private readonly List<Button> _optionButtons = new();

    public Segmented()
    {
        InitializeComponent();
    }

    public IReadOnlyList<SegmentOption> Options
    {
        get => (IReadOnlyList<SegmentOption>)GetValue(OptionsProperty);
        set => SetValue(OptionsProperty, value);
    }

    public object? SelectedId
    {
        get => GetValue(SelectedIdProperty);
        set => SetValue(SelectedIdProperty, value);
    }

    /// <summary>Fired when the user picks a (non-disabled) option — carries the newly selected
    /// <see cref="SegmentOption.Id"/>. Mirrors Swift's plain `@Binding var value: T` write; this
    /// control does not update <see cref="SelectedId"/> itself on click beyond what the event
    /// handler's own follow-up assignment does, matching every other Stage-A control's "dumb
    /// control, code-behind/VM owns the source of truth" convention.</summary>
    public event EventHandler<object>? SelectionChanged;

    private static void OnOptionsChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((Segmented)d).RebuildButtons();

    private static void OnSelectedIdChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((Segmented)d).UpdateSelectionVisuals();

    private void RebuildButtons()
    {
        OptionsPanel.Children.Clear();
        _optionButtons.Clear();

        foreach (var option in Options)
        {
            var label = new TextBlock
            {
                Text = option.Label,
                FontFamily = (FontFamily)Application.Current.Resources["VolarUiFontFamily"],
                FontSize = 11.5,
                FontWeight = FontWeights.Medium,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };

            var button = new Button
            {
                Content = label,
                Padding = new Thickness(12, 0, 12, 0),
                Height = 24,
                CornerRadius = new CornerRadius(6), // VolarCornerRadiusSmall's value — literal, see file header.
                BorderThickness = new Thickness(0),
                Background = new SolidColorBrush(Colors.Transparent),
                Tag = option,
            };
            SuppressStockButtonChrome(button);
            button.Click += OnOptionButtonClick;

            _optionButtons.Add(button);
            OptionsPanel.Children.Add(button);
        }

        UpdateSelectionVisuals();
    }

    private void OnOptionButtonClick(object sender, RoutedEventArgs e)
    {
        var option = (SegmentOption)((Button)sender).Tag;
        if (option.Disabled)
        {
            return;
        }
        SelectedId = option.Id;
        SelectionChanged?.Invoke(this, option.Id);
    }

    private void UpdateSelectionVisuals()
    {
        var appResources = Application.Current.Resources;
        var accentSurface = (Brush)appResources["AccentSurfaceBrush"];
        var accentSolid = (Brush)appResources["AccentSolidBrush"];
        var textSec = (Brush)appResources["VolarTextSecBrush"];
        var textMut = (Brush)appResources["VolarTextMutBrush"];
        var transparent = new SolidColorBrush(Colors.Transparent);

        foreach (var button in _optionButtons)
        {
            var option = (SegmentOption)button.Tag;
            // Matches SettingsView.swift:827/834 exactly: `selected` is a bare id comparison,
            // NOT gated by `disabled` — Foreground below is what actually reflects the disabled
            // state (textMut wins over the selected-accent color when disabled).
            var selected = Equals(option.Id, SelectedId);
            var label = (TextBlock)button.Content;

            button.Background = selected ? accentSurface : transparent;
            label.Foreground = option.Disabled ? textMut : (selected ? accentSolid : textSec);
            label.Opacity = option.Disabled ? 0.5 : 1.0;
        }
    }

    /// <summary>A plain WinUI <see cref="Button"/>'s default template swaps in
    /// ButtonBackgroundPointerOver/Pressed theme brushes on hover/press, which would visually
    /// stomp the accent-surface/transparent backgrounds <see cref="UpdateSelectionVisuals"/> just
    /// set — overriding those 4 theme keys locally on each button (rather than a full custom
    /// ControlTemplate, unlike GlassPanel/ToolButton) keeps this control's background exactly what
    /// this class assigns, matching Swift's flat (no system hover tint) `.buttonStyle(.plain)`
    /// look with far less template code for a control this simple.</summary>
    private static void SuppressStockButtonChrome(Button button)
    {
        var transparent = new SolidColorBrush(Colors.Transparent);
        button.Resources["ButtonBackgroundPointerOver"] = transparent;
        button.Resources["ButtonBackgroundPressed"] = transparent;
        button.Resources["ButtonBorderBrushPointerOver"] = transparent;
        button.Resources["ButtonBorderBrushPressed"] = transparent;
    }
}
