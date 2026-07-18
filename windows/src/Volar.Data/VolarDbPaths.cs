// VolarDbPaths.cs — opt-in helper for computing the default on-disk database path. Deliberately
// NOT called by anything else in this project (VolarDbContextFactory, TaskRepository) — per this
// task's brief, Volar.Data itself must never read Environment/AppData implicitly; only the App
// composition root should call this, then pass the resulting path into
// VolarDbContextFactory.ForFile(...) explicitly. Kept here (rather than in Volar.App) purely as a
// convenience so every consumer of this project agrees on the same folder/file naming convention
// without duplicating it.
namespace Volar.Data;

public static class VolarDbPaths
{
    /// <summary>
    /// The default database file path: <c>%LocalAppData%\Volar\volar.db</c>. Does not create the
    /// directory — callers (App startup) are responsible for
    /// <c>Directory.CreateDirectory(Path.GetDirectoryName(path)!)</c> before opening the database,
    /// exactly as they would for any other first-run file creation.
    /// </summary>
    public static string GetDefaultDatabasePath(string fileName = "volar.db")
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(root, "Volar", fileName);
    }
}
