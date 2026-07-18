// SqliteTestDatabase.cs — shared test fixture: a fresh, migrated, temp-file-backed SQLite database
// per instance. A TEMP FILE (not "Data Source=:memory:") is used deliberately: VolarDbContextFactory
// hands out a brand-new connection on every CreateDbContext() call (matching the "fresh short-lived
// DbContext per operation" lifecycle documented on VolarDbContextFactory/TaskRepository), and plain
// SQLite in-memory databases are private per-connection — a second connection would see an empty
// database. A temp file gives every test the same multi-connection behavior production actually has,
// without the added complexity of holding one shared SqliteConnection open for the test's duration.
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Volar.Data;

namespace Volar.Data.Tests;

public sealed class SqliteTestDatabase : IDisposable
{
    public string DbPath { get; }

    public VolarDbContextFactory Factory { get; }

    public SqliteTestDatabase()
    {
        DbPath = Path.Combine(Path.GetTempPath(), $"volar-data-tests-{Guid.NewGuid():N}.db");
        Factory = VolarDbContextFactory.ForFile(DbPath);

        using var context = Factory.CreateDbContext();
        context.Database.Migrate();
    }

    public TaskRepository CreateTaskRepository(IRecurrenceResetter? resetter = null) =>
        new(Factory, resetter);

    public CompletionEventRepository CreateCompletionEventRepository() =>
        new(Factory);

    public VolarDbContext CreateContext() => Factory.CreateDbContext();

    public void Dispose()
    {
        // Release SQLite's file handle before deleting — otherwise the delete can fail on Windows
        // while a pooled connection still has the file open.
        SqliteConnection.ClearAllPools();
        if (File.Exists(DbPath))
        {
            File.Delete(DbPath);
        }
    }
}
