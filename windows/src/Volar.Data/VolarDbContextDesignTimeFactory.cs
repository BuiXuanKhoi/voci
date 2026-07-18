// VolarDbContextDesignTimeFactory.cs — used ONLY by `dotnet ef migrations add`/`dotnet ef database
// update` at design time, when there is no running App composition root to supply a real connection
// string via DI. NOT used at runtime — VolarDbContextFactory (the IDbContextFactory<VolarDbContext>
// implementation) is what the app and tests actually use, with an explicitly-injected path/
// connection string (see that file's header comment for why Volar.Data never reads
// Environment/AppData implicitly). The connection string here is a schema-generation placeholder
// only; no file is ever created/opened by running `migrations add`.
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace Volar.Data;

public sealed class VolarDbContextDesignTimeFactory : IDesignTimeDbContextFactory<VolarDbContext>
{
    public VolarDbContext CreateDbContext(string[] args)
    {
        var options = new DbContextOptionsBuilder<VolarDbContext>()
            .UseSqlite("Data Source=design-time-placeholder.db")
            .Options;
        return new VolarDbContext(options);
    }
}
