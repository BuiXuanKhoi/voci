// FileDelegationMetaStoreTests.cs — every test uses a temp file path under Path.GetTempPath(),
// never the real %LocalAppData%\Volar\ folder, per this wave's hard constraint.
using Volar.App.Services.Adapters;
using Volar.Domain;
using Xunit;

namespace Volar.App.Tests.Adapters;

public sealed class FileDelegationMetaStoreTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"volar-app-tests-delegation-{Guid.NewGuid():N}.json");

    private static DelegationMeta SampleMeta(string label = "fix the bug", string? cwdHint = "/repo") => new(
        Label: label,
        CheckBackAt: new DateTimeOffset(2026, 7, 25, 10, 0, 0, TimeSpan.Zero),
        BackoffStage: 0,
        CwdHint: cwdHint,
        DelegatedAt: new DateTimeOffset(2026, 7, 25, 9, 50, 0, TimeSpan.Zero));

    [Fact]
    public void Get_ReturnsNull_ForUnknownTask()
    {
        var store = new FileDelegationMetaStore(_path);

        Assert.Null(store.Get(Guid.NewGuid()));
    }

    [Fact]
    public void SetThenGet_RoundTripsEveryField()
    {
        var store = new FileDelegationMetaStore(_path);
        var id = Guid.NewGuid();
        var meta = SampleMeta();

        store.Set(id, meta);
        var read = store.Get(id);

        Assert.Equal(meta, read);
    }

    [Fact]
    public void Remove_DropsTheEntry()
    {
        var store = new FileDelegationMetaStore(_path);
        var id = Guid.NewGuid();
        store.Set(id, SampleMeta());

        store.Remove(id);

        Assert.Null(store.Get(id));
    }

    [Fact]
    public void Remove_UnknownTask_IsANoOp()
    {
        var store = new FileDelegationMetaStore(_path);

        store.Remove(Guid.NewGuid()); // must not throw
    }

    [Fact]
    public void All_ReturnsEveryPersistedEntry()
    {
        var store = new FileDelegationMetaStore(_path);
        var id1 = Guid.NewGuid();
        var id2 = Guid.NewGuid();
        store.Set(id1, SampleMeta("a"));
        store.Set(id2, SampleMeta("b"));

        var all = store.All();

        Assert.Equal(2, all.Count);
        Assert.Equal("a", all[id1].Label);
        Assert.Equal("b", all[id2].Label);
    }

    [Fact]
    public void PruneKeys_DropsEntriesNotInLiveSet()
    {
        var store = new FileDelegationMetaStore(_path);
        var keep = Guid.NewGuid();
        var drop = Guid.NewGuid();
        store.Set(keep, SampleMeta());
        store.Set(drop, SampleMeta());

        store.PruneKeys(new HashSet<Guid> { keep });

        Assert.NotNull(store.Get(keep));
        Assert.Null(store.Get(drop));
    }

    [Fact]
    public void DataSurvives_ANewStoreInstanceOverTheSameFile()
    {
        var id = Guid.NewGuid();
        var meta = SampleMeta("survives restart", "/home/khoi/project");
        new FileDelegationMetaStore(_path).Set(id, meta);

        var reopened = new FileDelegationMetaStore(_path);

        Assert.Equal(meta, reopened.Get(id));
    }

    [Fact]
    public void MissingFile_StartsEmpty_NeverThrows()
    {
        var store = new FileDelegationMetaStore(_path); // file does not exist yet

        Assert.Empty(store.All());
    }

    [Fact]
    public void CorruptFile_StartsEmpty_NeverThrows()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, "{ this is not valid json");

        var store = new FileDelegationMetaStore(_path);

        Assert.Empty(store.All());
    }

    [Fact]
    public void CorruptFile_SetStillWorksAfterward_AndOverwritesTheCorruptContent()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, "not json at all");
        var store = new FileDelegationMetaStore(_path);
        var id = Guid.NewGuid();

        store.Set(id, SampleMeta());

        var reopened = new FileDelegationMetaStore(_path);
        Assert.Equal(SampleMeta(), reopened.Get(id));
    }

    [Fact]
    public void GetDefaultPath_PointsUnderLocalAppDataVolar()
    {
        var path = FileDelegationMetaStore.GetDefaultPath();

        Assert.Contains("Volar", path);
        Assert.EndsWith("delegation-meta.json", path);
    }

    public void Dispose()
    {
        if (File.Exists(_path))
        {
            File.Delete(_path);
        }
    }
}
