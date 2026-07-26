// ViewModels/PriorityPresentationTests.cs — PriorityPresentation (Wave 4 Stage B3's shared
// High/Medium/Low label + color-resource-key helper — see PriorityPresentation.cs's header for why
// this is a deliberate, small, file-local duplicate of B1's own priority-color logic).
using Volar.App.ViewModels;
using Volar.Domain;
using Xunit;

namespace Volar.App.Tests.ViewModels;

public sealed class PriorityPresentationTests
{
    [Theory]
    [InlineData(Priority.High, "High")]
    [InlineData(Priority.Medium, "Medium")]
    [InlineData(Priority.Low, "Low")]
    public void Label_MatchesTaskDetailViewSwiftsPriorityLabelSwitch(Priority priority, string expected)
    {
        Assert.Equal(expected, PriorityPresentation.Label(priority));
    }

    [Theory]
    [InlineData(Priority.High, "VolarHighBrush")]
    [InlineData(Priority.Medium, "VolarMedBrush")]
    [InlineData(Priority.Low, "VolarLowBrush")]
    public void ColorResourceKey_MatchesTaskDetailViewSwiftsPriorityColorSwitch(Priority priority, string expectedKey)
    {
        Assert.Equal(expectedKey, PriorityPresentation.ColorResourceKey(priority));
    }
}
