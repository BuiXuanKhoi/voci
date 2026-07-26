// Views/Controls/VolarIconGlyphsTests.cs — wave4-contract.md Stage A: "unit tests for ... glyph
// map" — completeness (every VolarIconName case maps to something), and the one text-mode case
// (Cmd -> "Ctrl") per the frozen contract's explicit instruction. Pure C# (VolarIconGlyphs has no
// XAML/Application.Current dependency), so this runs headlessly like every other test in this
// project — no live-rendering assertion is possible here (a wrong codepoint is a silent visual
// failure, not a test failure; see VolarIconGlyphs.cs's own header for the Character-Map
// spot-check recommendation this can't replace).
using Volar.App.Views.Controls;
using Xunit;

namespace Volar.App.Tests.Views.Controls;

public sealed class VolarIconGlyphsTests
{
    /// <summary>The contract's prose says "mirroring Swift's 30 cases 1:1", but the actual current
    /// `VolarIconName` (VolarIcon.swift:7-10) declares exactly 28 — see VolarIconName.cs's own
    /// header comment. This test pins the count so a future drift (someone silently adding/removing
    /// a case without updating the glyph map) fails loudly instead of via a missing-glyph
    /// exception somewhere else.</summary>
    [Fact]
    public void VolarIconName_HasExactly28Cases()
    {
        var cases = Enum.GetValues<VolarIconName>();
        Assert.Equal(28, cases.Length);
    }

    [Fact]
    public void Glyph_ReturnsANonEmptyStringForEveryCase()
    {
        foreach (var name in Enum.GetValues<VolarIconName>())
        {
            var glyph = VolarIconGlyphs.Glyph(name);
            Assert.False(string.IsNullOrEmpty(glyph), $"{name} has no glyph mapping.");
        }
    }

    [Theory]
    [InlineData(VolarIconName.Cmd, true)]
    [InlineData(VolarIconName.Mic, false)]
    [InlineData(VolarIconName.Plus, false)]
    [InlineData(VolarIconName.Search, false)]
    [InlineData(VolarIconName.Sparkle, false)]
    public void IsTextMode_IsTrueOnlyForCmd(VolarIconName name, bool expected)
    {
        Assert.Equal(expected, VolarIconGlyphs.IsTextMode(name));
    }

    [Fact]
    public void IsTextMode_IsTrueForExactlyOneCase()
    {
        var textModeCases = Enum.GetValues<VolarIconName>().Where(VolarIconGlyphs.IsTextMode).ToList();

        var only = Assert.Single(textModeCases);
        Assert.Equal(VolarIconName.Cmd, only);
    }

    [Fact]
    public void TextFallback_Cmd_RendersLiteralCtrl()
    {
        // Per the frozen contract: macOS's `command` glyph has no Windows analog — render "Ctrl"
        // text instead of hunting for a symbol.
        Assert.Equal("Ctrl", VolarIconGlyphs.TextFallback(VolarIconName.Cmd));
    }

    [Fact]
    public void TextFallback_IsEmptyForEveryGlyphModeCase()
    {
        foreach (var name in Enum.GetValues<VolarIconName>().Where(n => !VolarIconGlyphs.IsTextMode(n)))
        {
            Assert.Equal(string.Empty, VolarIconGlyphs.TextFallback(name));
        }
    }

    /// <summary>Distinct-glyph sanity check: every case OTHER than the two documented deliberate
    /// reuses (Today reuses Upcoming's Calendar; Waveform reuses Mic's Microphone — both flagged
    /// with `SUBSTITUTION:` comments in VolarIconGlyphs.cs) should resolve to a distinct codepoint,
    /// catching an accidental copy-paste collision between otherwise-unrelated icons.</summary>
    [Fact]
    public void Glyph_HasNoUnexpectedCollisions_BeyondTheTwoDocumentedReuses()
    {
        var byGlyph = Enum.GetValues<VolarIconName>()
            .Where(n => !VolarIconGlyphs.IsTextMode(n))
            .GroupBy(VolarIconGlyphs.Glyph)
            .Where(group => group.Count() > 1)
            .ToList();

        foreach (var group in byGlyph)
        {
            var names = group.OrderBy(n => n).ToList();
            var isDocumentedTodayUpcomingReuse =
                names.SequenceEqual(new[] { VolarIconName.Today, VolarIconName.Upcoming }.OrderBy(n => n));
            var isDocumentedWaveformMicReuse =
                names.SequenceEqual(new[] { VolarIconName.Mic, VolarIconName.Waveform }.OrderBy(n => n));

            Assert.True(
                isDocumentedTodayUpcomingReuse || isDocumentedWaveformMicReuse,
                $"Unexpected glyph collision between: {string.Join(", ", names)}");
        }
    }
}
