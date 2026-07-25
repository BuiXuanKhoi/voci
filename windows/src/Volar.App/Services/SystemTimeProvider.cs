// Services/SystemTimeProvider.cs — the ONE real-clock ITimeProvider implementation for this app.
// Every Wave 3-C service takes ITimeProvider by constructor injection instead of reading
// DateTimeOffset.Now/UtcNow directly (wave-wide rule, specs/003-windows-port/wave3c-services.md) —
// this is the sole place that rule is allowed to be satisfied with a real clock read. Tests inject
// their own fixed/fake ITimeProvider instead of this type.
namespace Volar.App.Services;

public sealed class SystemTimeProvider : ITimeProvider
{
    /// <summary>UTC, not local — every consumer that needs local-calendar semantics (day/week keys,
    /// the evening-sweep "hour &gt;= 18" gate, ...) converts this instant itself via an explicitly
    /// injected <see cref="TimeZoneInfo"/>, exactly as <c>TriageAndSweepService</c>/
    /// <c>TaskListService</c>/etc. already do — keeping the raw instant itself timezone-neutral
    /// avoids ever silently double-converting.</summary>
    public DateTimeOffset Now => DateTimeOffset.UtcNow;
}
