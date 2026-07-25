// State/SqliteFixture.cs — a fresh, migrated, temp-file-backed SQLite database per instance, so
// TaskListService's tests exercise a real TaskRepository (not a hand-rolled fake) and therefore
// really do exercise FIX 3's sibling trap (recurrence reset-in-place / parent cascade land here for
// free because TaskRepository itself implements them). Deliberately duplicated from
// Volar.Data.Tests/SqliteTestDatabase.cs rather than shared across test assemblies — that class is
// `internal` to a project this one doesn't own, and Volar.Data.Tests is not in this task's list of
// owned files, so this project gets its own copy. A temp FILE (not "Data Source=:memory:") mirrors
// production's fresh-DbContext-per-call lifecycle exactly, same rationale as the original.
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Volar.Data;

namespace Volar.App.Tests.State;

public sealed class SqliteFixture : IDisposable
{
    public string DbPath { get; }

    public VolarDbContextFactory Factory { get; }

    public SqliteFixture()
    {
        DbPath = Path.Combine(Path.GetTempPath(), $"volar-app-tests-{Guid.NewGuid():N}.db");
        Factory = VolarDbContextFactory.ForFile(DbPath);

        using var context = Factory.CreateDbContext();
        context.Database.Migrate();
    }

    public TaskRepository CreateTaskRepository(IRecurrenceResetter? resetter = null) => new(Factory, resetter);

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
