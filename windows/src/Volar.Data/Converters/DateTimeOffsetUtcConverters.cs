// Converters/DateTimeOffsetUtcConverters.cs
//
// DESIGN DECISION (flagged for Opus review per this task's brief): SQLite has no native date/time
// column type, and EF Core's built-in Sqlite provider default handling of DateTimeOffset (storing
// the "O"-ish round-trip text INCLUDING whatever offset the value happens to carry) has two known
// sharp edges relevant here:
//   1. Two instants with different original offsets sort incorrectly under a plain SQL ORDER BY on
//      the text column, because the offset suffix is part of the compared string.
//   2. Nothing in this project actually needs to remember the original offset — plan.md is explicit
//      that persisted timestamps are `DateTimeOffset` "(UTC)"; local-calendar-day reasoning (e.g.
//      "is this deadline today") is done by the caller via an explicitly injected `TimeZoneInfo`,
//      never by trusting whatever offset a stored value happens to carry (see
//      Volar.Core.NextTaskSelector.IsSameCalendarDay).
// Chosen: an explicit ValueConverter that normalizes every DateTimeOffset to UTC before storing (as
// an ISO-8601 string with a literal "+00:00"/"Z" offset) and parses it back on read. This makes (a)
// storage format fully explicit and independent of whatever the Sqlite provider's default happens
// to be in a future EF Core version, and (b) SQL ORDER BY / range comparisons on the stored TEXT
// column chronologically correct, since every stored value shares the same (zero) offset — ISO-8601
// UTC strings sort lexicographically in the same order as their instants.
//
// Round-trip semantics: `DateTimeOffset` equality (`==`) compares by absolute instant, not by
// offset — so a value constructed with a non-UTC offset (e.g. `+07:00`) still compares equal after
// round-tripping through this converter, even though the *offset itself* is not preserved (by
// design: only the instant matters downstream). See Volar.Data.Tests for a round-trip test proving
// this explicitly, including for a non-UTC input offset.
using System.Globalization;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;

namespace Volar.Data.Converters;

/// <summary>Converts a non-nullable <see cref="DateTimeOffset"/> to/from a UTC ISO-8601 string.</summary>
public sealed class DateTimeOffsetToUtcStringConverter()
    : ValueConverter<DateTimeOffset, string>(
        v => v.ToUniversalTime().ToString(Format, CultureInfo.InvariantCulture),
        v => DateTimeOffset.ParseExact(v, Format, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal))
{
    // "yyyy-MM-ddTHH:mm:ss.fffffffZ" — literal 'Z' (not the "K" custom specifier) so every stored
    // value is guaranteed byte-for-byte UTC, never "+00:00" for some rows and "Z" for others,
    // keeping ORDER BY / range-query lexicographic comparison well-defined.
    internal const string Format = "yyyy-MM-ddTHH:mm:ss.fffffff'Z'";
}

/// <summary>Nullable counterpart of <see cref="DateTimeOffsetToUtcStringConverter"/>.</summary>
public sealed class NullableDateTimeOffsetToUtcStringConverter()
    : ValueConverter<DateTimeOffset?, string?>(
        v => v == null ? null : v.Value.ToUniversalTime().ToString(DateTimeOffsetToUtcStringConverter.Format, CultureInfo.InvariantCulture),
        v => v == null ? null : DateTimeOffset.ParseExact(v, DateTimeOffsetToUtcStringConverter.Format, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal))
{
}
