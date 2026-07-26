// Views/Controls/ToolButton.xaml.cs — see ToolButton.xaml header. Port of Components.swift:131-184.
//
// `InnerButton.Background` (set directly below) flows into the template's `Grid` via that
// ControlTemplate's `Background="{TemplateBinding Background}"` — no `GetTemplateChild` lookup is
// needed since we only ever touch `Button.Background` itself, a property the UserControl's own
// compiled `InnerButton` field already exposes.
using System.Windows.Input;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Volar.App.Views.Controls;

public sealed partial class ToolButton : UserControl
{
    // VolarColor.veil(0.08) -> alpha 0x14 (Components.swift:160, plain-mode hover tint — same
    // math as KeyBadge's identical literal).
    private static readonly SolidColorBrush WhiteOpacity08 = new(Color.FromArgb(0x14, 0x94, 0xB2, 0xE0));

    private static readonly SolidColorBrush TransparentBrush = new(Colors.Transparent);
    private static readonly SolidColorBrush WhiteBrush = new(Color.FromArgb(0xFF, 255, 255, 255));

    public static readonly DependencyProperty IconNameProperty = DependencyProperty.Register(
        nameof(IconName), typeof(VolarIconName), typeof(ToolButton), new PropertyMetadata(VolarIconName.Plus, OnVisualChanged));

    /// <summary>Mirrors Swift's `accent: Bool = false` (Components.swift:135/144) — solid accent fill.</summary>
    public static readonly DependencyProperty AccentProperty = DependencyProperty.Register(
        nameof(Accent), typeof(bool), typeof(ToolButton), new PropertyMetadata(false, OnVisualChanged));

    /// <summary>Mirrors Swift's `tint: Bool = false` (Components.swift:136/145) — accent-tinted
    /// "activeTint" state.</summary>
    public static readonly DependencyProperty TintProperty = DependencyProperty.Register(
        nameof(Tint), typeof(bool), typeof(ToolButton), new PropertyMetadata(false, OnVisualChanged));

    public static readonly DependencyProperty CommandProperty = DependencyProperty.Register(
        nameof(Command), typeof(ICommand), typeof(ToolButton), new PropertyMetadata(null));

    public static readonly DependencyProperty CommandParameterProperty = DependencyProperty.Register(
        nameof(CommandParameter), typeof(object), typeof(ToolButton), new PropertyMetadata(null));

    private bool _isHovering;

    public ToolButton()
    {
        InitializeComponent();
        UpdateVisual();
    }

    public VolarIconName IconName
    {
        get => (VolarIconName)GetValue(IconNameProperty);
        set => SetValue(IconNameProperty, value);
    }

    public bool Accent
    {
        get => (bool)GetValue(AccentProperty);
        set => SetValue(AccentProperty, value);
    }

    public bool Tint
    {
        get => (bool)GetValue(TintProperty);
        set => SetValue(TintProperty, value);
    }

    public ICommand? Command
    {
        get => (ICommand?)GetValue(CommandProperty);
        set => SetValue(CommandProperty, value);
    }

    public object? CommandParameter
    {
        get => GetValue(CommandParameterProperty);
        set => SetValue(CommandParameterProperty, value);
    }

    /// <summary>Mirrors Swift's `action: () -> Void` init param (Components.swift:137/146) as a
    /// plain WinUI routed event, for callers that prefer a direct handler over
    /// <see cref="Command"/>.</summary>
    public event RoutedEventHandler? Click;

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((ToolButton)d).UpdateVisual();

    private void OnPointerEntered(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        _isHovering = true;
        UpdateVisual();
    }

    private void OnPointerExited(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        _isHovering = false;
        UpdateVisual();
    }

    private void OnInnerButtonClick(object sender, RoutedEventArgs e)
    {
        Click?.Invoke(this, e);
        if (Command?.CanExecute(CommandParameter) == true)
        {
            Command.Execute(CommandParameter);
        }
    }

    private void UpdateVisual()
    {
        var appResources = Application.Current.Resources;
        Icon.IconName = IconName;

        // Foreground never varies with hover in any mode (Components.swift:151-155).
        Brush foreground;
        if (Accent)
        {
            foreground = WhiteBrush;
        }
        else if (Tint)
        {
            foreground = (Brush)appResources["AccentSolidBrush"];
        }
        else
        {
            foreground = (Brush)appResources["VolarTextSecBrush"];
        }
        Icon.IconBrush = foreground;

        // Background: accent mode swaps solid<->hover on pointer-over; tint mode is hover-invariant
        // (always `accentColors.surface`); plain mode fades a white tint in on hover
        // (Components.swift:157-161).
        Brush background;
        if (Accent)
        {
            background = _isHovering ? (Brush)appResources["AccentHoverBrush"] : (Brush)appResources["AccentSolidBrush"];
        }
        else if (Tint)
        {
            background = (Brush)appResources["AccentSurfaceBrush"];
        }
        else
        {
            background = _isHovering ? WhiteOpacity08 : TransparentBrush;
        }
        InnerButton.Background = background;
    }
}
