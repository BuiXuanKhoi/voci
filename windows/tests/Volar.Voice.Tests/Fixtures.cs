using System.Globalization;

namespace Volar.Voice.Tests;

/// <summary>Deterministic id/task fixtures shared by every test in this project.</summary>
internal static class Fixtures
{
    /// <summary>
    /// Produces a stable, orderable <see cref="Guid"/> from a small integer so tests can reason
    /// about the id-ordinal tiebreak predictably: <c>FixedGuid(1)</c> sorts before
    /// <c>FixedGuid(2)</c>, etc. Mirrors <c>Volar.Core.Tests.Fixtures.FixedGuid</c>.
    /// </summary>
    public static Guid FixedGuid(int n)
    {
        var hex = n.ToString("x12", CultureInfo.InvariantCulture);
        return Guid.Parse($"00000000-0000-0000-0000-{hex}", CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Builds a <see cref="VoiceDoneTask"/> with sensible defaults so each test only needs to
    /// specify the fields it actually cares about.
    /// </summary>
    public static VoiceDoneTask MakeTask(
        Guid? id = null,
        string title = "Untitled task",
        IReadOnlyList<string>? externalDescriptions = null) =>
        new(id ?? Guid.NewGuid(), title, externalDescriptions ?? Array.Empty<string>());
}
