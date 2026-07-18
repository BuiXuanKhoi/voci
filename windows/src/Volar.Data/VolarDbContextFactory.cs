// VolarDbContextFactory.cs — IDbContextFactory<VolarDbContext> implementation. The connection
// string is a required CONSTRUCTOR PARAMETER, never read from Environment/AppData inside this
// project (per this task's brief: "để đường dẫn là tham số inject, đừng đọc thẳng trong
// Volar.Data" — so tests can point at an in-memory/temp-file database without touching the real
// user profile). See VolarDbPaths for the (opt-in, App-layer-only) helper that computes the
// default on-disk path using Environment.SpecialFolder.LocalApplicationData.
using Microsoft.EntityFrameworkCore;

namespace Volar.Data;

/// <summary>
/// Creates a fresh, short-lived <see cref="VolarDbContext"/> per call — this is the ONLY supported
/// way to obtain a <see cref="VolarDbContext"/> in this project's own code (<see cref="TaskRepository"/>,
/// <see cref="CompletionEventRepository"/>); nothing holds a context across multiple operations or
/// shares one across threads.
/// </summary>
public sealed class VolarDbContextFactory(string connectionString) : IDbContextFactory<VolarDbContext>
{
    private readonly string _connectionString = connectionString;

    public VolarDbContext CreateDbContext()
    {
        var options = new DbContextOptionsBuilder<VolarDbContext>()
            .UseSqlite(_connectionString)
            .Options;
        return new VolarDbContext(options);
    }

    /// <summary>
    /// Convenience for callers (tests, App startup) that want a ready-to-use SQLite connection
    /// string from a plain file path, rather than hand-writing "Data Source=...".
    /// </summary>
    public static VolarDbContextFactory ForFile(string databaseFilePath) =>
        new($"Data Source={databaseFilePath}");

    /// <summary>
    /// Convenience for tests: a private, process-local in-memory SQLite database. NOTE: plain
    /// "Data Source=:memory:" drops all data the moment the owning connection closes, which is
    /// wrong for a factory that hands out a NEW connection per <see cref="CreateDbContext"/> call —
    /// callers needing a truly persistent in-memory database across multiple contexts (most tests)
    /// should keep a single open <see cref="Microsoft.Data.Sqlite.SqliteConnection"/> alive for the
    /// test's duration and pass it to <see cref="VolarDbContextFactory(string)"/> via its connection
    /// string, or use a temp file instead (see Volar.Data.Tests for the pattern actually used).
    /// </summary>
    public static VolarDbContextFactory InMemory() => new("Data Source=:memory:");
}
