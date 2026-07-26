// Views/Controls/SidebarControl.xaml.cs — see SidebarControl.xaml header. Port of Sidebar.swift.
using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Volar.App.Services.State;
using Volar.App.Theme;
using Volar.App.ViewModels;
using Windows.UI;

namespace Volar.App.Views.Controls;

public sealed partial class SidebarControl : UserControl
{
    // VolarColor.surface.opacity(0.45) (Sidebar.swift:63-65, ambient-mode overlay) -> alpha =
    // round(0.45*255) = 114.75 -> 115 = 0x73, over VolarSurface's own RGB (#0A101C).
    private static readonly SolidColorBrush AmbientSurfaceOverlayBrush = new(Color.FromArgb(0x73, 0x0A, 0x10, 0x1C));

    // VolarColor.veil(0.03) (Sidebar.swift:121, footer background) -> alpha = round(0.03*255) =
    // 7.65 -> 8 = 0x08.
    private static readonly SolidColorBrush FooterBackgroundBrush = new(Color.FromArgb(0x08, 0x94, 0xB2, 0xE0));

    // VolarColor.veil(0.04) (Sidebar.swift:183, nav-item hover tint) -> alpha 0x0A.
    private static readonly SolidColorBrush NavHoverBrush = new(Color.FromArgb(0x0A, 0x94, 0xB2, 0xE0));

    private static readonly SolidColorBrush TransparentBrush = new(Colors.Transparent);

    public static readonly DependencyProperty ViewModelProperty = DependencyProperty.Register(
        nameof(ViewModel), typeof(TodayViewModel), typeof(SidebarControl), new PropertyMetadata(null, OnViewModelChanged));

    public SidebarControl()
    {
        InitializeComponent();
        UpdateVisual();
    }

    public TodayViewModel? ViewModel
    {
        get => (TodayViewModel?)GetValue(ViewModelProperty);
        set => SetValue(ViewModelProperty, value);
    }

    private static void OnViewModelChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var control = (SidebarControl)d;
        if (e.OldValue is TodayViewModel oldVm)
        {
            oldVm.PropertyChanged -= control.OnViewModelPropertyChanged;
        }
        if (e.NewValue is TodayViewModel newVm)
        {
            newVm.PropertyChanged += control.OnViewModelPropertyChanged;
        }
        control.UpdateVisual();
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e) => UpdateVisual();

    private async void OnCaptureButtonClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is TodayViewModel vm)
        {
            await vm.ToggleCaptureAsync().ConfigureAwait(true);
        }
    }

    // Mirrors Sidebar.swift's `SidebarItem`'s `.onHover` (Sidebar.swift:185-186) — Upcoming/Inbox get
    // the same hover tint even though their `action` is a no-op, matching the Swift original exactly.
    private void OnNavRowPointerEntered(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (sender is Border { Name: "TodayNavRow" })
        {
            return; // Today's background is accent-surface (active), never hover-tinted.
        }
        if (sender is Border border)
        {
            border.Background = NavHoverBrush;
        }
    }

    private void OnNavRowPointerExited(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (sender is Border { Name: "TodayNavRow" })
        {
            return;
        }
        if (sender is Border border)
        {
            border.Background = TransparentBrush;
        }
    }

    private void UpdateVisual()
    {
        var appResources = Application.Current.Resources;
        var vm = ViewModel;

        FooterBorder.Background = FooterBackgroundBrush;

        // sidebarBackground (Sidebar.swift:58-67): ambient active -> glass material + surface
        // overlay; else plain VolarSurface.
        var ambientActive = vm?.IsAmbientBackgroundActive ?? false;
        if (ambientActive)
        {
            var glassKey = vm!.Theme.Glass switch
            {
                GlassLevel.Subtle => "VolarGlassSubtleBrush",
                GlassLevel.Heavy => "VolarGlassHeavyBrush",
                _ => "VolarGlassStandardBrush",
            };
            RootBackground.Background = (Brush)appResources[glassKey];
            RootBackground.Child ??= new Microsoft.UI.Xaml.Shapes.Rectangle { Fill = AmbientSurfaceOverlayBrush };
        }
        else
        {
            RootBackground.Background = (Brush)appResources["VolarSurfaceBrush"];
            RootBackground.Child = null;
        }

        // Capture button (Sidebar.swift:69-84) — background/border are static XAML resources
        // (UserControl.Resources, above); only the icon/text foreground and the label text itself
        // are set here.
        CaptureButtonText.Text = vm?.CaptureButtonLabel ?? "Tap to speak";
        var accentSolid = (Brush)appResources["AccentSolidBrush"];
        CaptureIcon.IconBrush = accentSolid;
        CaptureButtonText.Foreground = accentSolid;

        // Today nav (Sidebar.swift:23-28) — always active.
        TodayNavIcon.IconBrush = accentSolid;
        TodayNavLabel.Foreground = accentSolid;
        TodayNavCountText.Foreground = accentSolid;
        TodayNavCountText.Text = (vm?.TodayNavCount ?? 0).ToString(System.Globalization.CultureInfo.InvariantCulture);
        TodayNavRow.Background = (Brush)appResources["AccentSurfaceBrush"];

        // Upcoming/Inbox nav (Sidebar.swift:29-40) — static placeholder counts, never active.
        UpcomingNavCountText.Text = TodayViewModel.UpcomingNavCountPlaceholder.ToString(System.Globalization.CultureInfo.InvariantCulture);
        InboxNavCountText.Text = TodayViewModel.InboxNavCountPlaceholder.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }
}
