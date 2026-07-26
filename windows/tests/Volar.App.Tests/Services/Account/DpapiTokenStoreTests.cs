// Services/Account/DpapiTokenStoreTests.cs — real file I/O + REAL DPAPI encrypt/decrypt (crypt32.dll
// via Dpapi.cs's P/Invoke), confined to a disposable temp file. No mocking here on purpose: this is
// exactly the security-critical path (task brief: "encrypt the refresh/access tokens at rest") this
// suite needs to prove actually round-trips on a real Windows machine, not just compiles.
using Volar.App.Services.Account;
using Xunit;

namespace Volar.App.Tests.Services.Account;

public sealed class DpapiTokenStoreTests : IDisposable
{
    private readonly string _tempFile = Path.Combine(Path.GetTempPath(), $"volar-dpapi-tests-{Guid.NewGuid():N}.dat");

    public void Dispose()
    {
        try
        {
            if (File.Exists(_tempFile))
            {
                File.Delete(_tempFile);
            }
        }
        catch
        {
            // best-effort cleanup
        }
    }

    [Fact]
    public void Load_NoFile_ReturnsNull()
    {
        var store = new DpapiTokenStore(_tempFile);

        Assert.Null(store.Load());
    }

    [Fact]
    public void SaveThenLoad_RoundTripsExactly()
    {
        var store = new DpapiTokenStore(_tempFile);
        var session = new StoredSession("access-token-123", "refresh-token-456", new DateTimeOffset(2026, 8, 1, 0, 0, 0, TimeSpan.Zero), "user-abc", "person@example.com");

        store.Save(session);
        var loaded = store.Load();

        Assert.Equal(session, loaded);
    }

    [Fact]
    public void Save_EncryptsAtRest_FileNeverContainsThePlaintextToken()
    {
        var store = new DpapiTokenStore(_tempFile);
        var session = new StoredSession("super-secret-access-token", "super-secret-refresh-token", DateTimeOffset.UtcNow, "user-abc", "person@example.com");

        store.Save(session);

        var rawBytes = File.ReadAllBytes(_tempFile);
        var rawText = System.Text.Encoding.UTF8.GetString(rawBytes);
        Assert.DoesNotContain("super-secret-access-token", rawText, StringComparison.Ordinal);
        Assert.DoesNotContain("super-secret-refresh-token", rawText, StringComparison.Ordinal);
        Assert.DoesNotContain("person@example.com", rawText, StringComparison.Ordinal);
    }

    [Fact]
    public void Clear_RemovesTheFile_SubsequentLoadReturnsNull()
    {
        var store = new DpapiTokenStore(_tempFile);
        store.Save(new StoredSession("t", "r", DateTimeOffset.UtcNow, "u", "e@x.com"));
        Assert.True(File.Exists(_tempFile));

        store.Clear();

        Assert.False(File.Exists(_tempFile));
        Assert.Null(store.Load());
    }

    [Fact]
    public void Load_CorruptCiphertext_ReturnsNull_NeverThrows()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_tempFile)!);
        File.WriteAllBytes(_tempFile, new byte[] { 1, 2, 3, 4, 5 }); // not a real DPAPI blob
        var store = new DpapiTokenStore(_tempFile);

        var loaded = store.Load();

        Assert.Null(loaded);
    }

    [Fact]
    public void Protect_ThenUnprotect_RoundTrips()
    {
        var plaintext = System.Text.Encoding.UTF8.GetBytes("hello dpapi");

        var ciphertext = Dpapi.Protect(plaintext);
        var roundTripped = Dpapi.Unprotect(ciphertext);

        Assert.NotNull(roundTripped);
        Assert.Equal(plaintext, roundTripped);
        Assert.NotEqual(plaintext, ciphertext); // sanity: it was actually transformed, not passed through.
    }

    [Fact]
    public void Unprotect_GarbageInput_ReturnsNull()
    {
        var result = Dpapi.Unprotect(new byte[] { 9, 9, 9, 9 });

        Assert.Null(result);
    }
}
