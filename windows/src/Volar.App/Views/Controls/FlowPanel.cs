// Views/Controls/FlowPanel.cs — hand-rolled wrap layout, port of PopoverView.swift's private
// `FlowLayout` (a SwiftUI `Layout` conformance wrapping chips left-to-right, PopoverView.swift per
// views-inventory.md §1.17). wave4-contract.md Stage A deliverable 4 + frozen decision 2: "No new
// NuGet packages... FlowLayout = hand-rolled Panel (MeasureOverride/ArrangeOverride)" — WinUI 3 has
// no built-in wrap panel in core (`ItemsWrapGrid` is grid-cell-uniform, not free-flow; a real
// variable-width wrap panel is normally a Community Toolkit `WrapPanel`, which this wave is
// forbidden from adding as a dependency).
//
// Left-to-right, top-to-bottom flow, no alignment/justification options — matches SwiftUI's
// `FlowLayout` default behavior (leading-aligned rows, no distribution). `ItemSpacing` is the gap
// between items on the same row; `LineSpacing` is the gap between rows.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace Volar.App.Views.Controls;

public sealed class FlowPanel : Panel
{
    public static readonly DependencyProperty ItemSpacingProperty = DependencyProperty.Register(
        nameof(ItemSpacing), typeof(double), typeof(FlowPanel), new PropertyMetadata(0.0, OnLayoutPropertyChanged));

    public static readonly DependencyProperty LineSpacingProperty = DependencyProperty.Register(
        nameof(LineSpacing), typeof(double), typeof(FlowPanel), new PropertyMetadata(0.0, OnLayoutPropertyChanged));

    public double ItemSpacing
    {
        get => (double)GetValue(ItemSpacingProperty);
        set => SetValue(ItemSpacingProperty, value);
    }

    public double LineSpacing
    {
        get => (double)GetValue(LineSpacingProperty);
        set => SetValue(LineSpacingProperty, value);
    }

    private static void OnLayoutPropertyChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((FlowPanel)d).InvalidateMeasure();

    protected override Size MeasureOverride(Size availableSize)
    {
        var maxWidth = double.IsInfinity(availableSize.Width) ? double.PositiveInfinity : availableSize.Width;
        double x = 0, lineHeight = 0, totalWidth = 0, totalHeight = 0;
        var lineHasItems = false;

        foreach (var child in Children)
        {
            child.Measure(new Size(maxWidth, double.PositiveInfinity));
            var size = child.DesiredSize;
            var prospectiveRight = (lineHasItems ? x + ItemSpacing : x) + size.Width;

            if (lineHasItems && prospectiveRight > maxWidth)
            {
                // Current item doesn't fit on this row — close the row out and start a new one.
                totalWidth = Math.Max(totalWidth, x);
                totalHeight += lineHeight + LineSpacing;
                x = 0;
                lineHeight = 0;
                lineHasItems = false;
            }

            x = (lineHasItems ? x + ItemSpacing : x) + size.Width;
            lineHeight = Math.Max(lineHeight, size.Height);
            lineHasItems = true;
        }

        totalWidth = Math.Max(totalWidth, x);
        totalHeight += lineHeight; // last row: no trailing LineSpacing.
        return new Size(totalWidth, totalHeight);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0, y = 0, lineHeight = 0;
        var lineHasItems = false;

        foreach (var child in Children)
        {
            var size = child.DesiredSize;
            var prospectiveRight = (lineHasItems ? x + ItemSpacing : x) + size.Width;

            if (lineHasItems && prospectiveRight > finalSize.Width + 0.5) // 0.5px sub-pixel tolerance
            {
                y += lineHeight + LineSpacing;
                x = 0;
                lineHeight = 0;
                lineHasItems = false;
            }

            var itemX = lineHasItems ? x + ItemSpacing : x;
            child.Arrange(new Rect(itemX, y, size.Width, size.Height));
            x = itemX + size.Width;
            lineHeight = Math.Max(lineHeight, size.Height);
            lineHasItems = true;
        }

        return finalSize;
    }
}
