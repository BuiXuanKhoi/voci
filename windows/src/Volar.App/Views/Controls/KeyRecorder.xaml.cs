// Views/Controls/KeyRecorder.xaml.cs — see KeyRecorder.xaml header. Port of SettingsView.swift's
// private KeyRecorder (lines 881-901).
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Volar.App.Views.Controls;

public sealed partial class KeyRecorder : UserControl
{
    public static readonly DependencyProperty KeysProperty = DependencyProperty.Register(
        nameof(Keys), typeof(IReadOnlyList<string>), typeof(KeyRecorder),
        new PropertyMetadata(Array.Empty<string>(), OnKeysChanged));

    public KeyRecorder()
    {
        InitializeComponent();
    }

    public IReadOnlyList<string> Keys
    {
        get => (IReadOnlyList<string>)GetValue(KeysProperty);
        set => SetValue(KeysProperty, value);
    }

    private static void OnKeysChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((KeyRecorder)d).Rebuild();

    private void Rebuild()
    {
        KeysPanel.Children.Clear();
        foreach (var key in Keys)
        {
            KeysPanel.Children.Add(new KeyBadge { Text = key });
        }
        KeysPanel.Children.Add(new TextBlock
        {
            Text = "Change",
            FontFamily = (Microsoft.UI.Xaml.Media.FontFamily)Application.Current.Resources["VolarUiFontFamily"],
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["AccentSolidBrush"],
            Margin = new Thickness(4, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
        });
    }
}
