// Capture/TestSupport.cs — small shared test doubles for this folder's CaptureFlowService and
// SpeechEngineService tests, mirroring the "TestSupport.cs" convention already established in this
// project's State/ subfolder (stage-1, C2). Deliberately self-contained: this folder is C3's alone
// (per wave3c-services.md, "Tests: Capture/** is yours, ... State/** ... are stage-1's"), but
// `FixedTimeProvider`/`RecordingEligibilityService`/`TestTasks`/`SqliteFixture` from
// Volar.App.Tests.State are `public`/`internal` types in the SAME test assembly — reused via a
// `using` below rather than duplicated, since they are pure, already-reviewed infrastructure with no
// Capture-specific behavior of their own.
using Volar.App.Services;
using Volar.App.Services.State;
using Volar.Core;
using Volar.Data;
using Volar.Domain;
using Volar.Parsing;
using Volar.Speech;
using Volar.Speech.Groq;

namespace Volar.App.Tests.Capture;

// MARK: - ITaskListService fake (full control, no repository needed)

/// <summary>Hand-rolled <see cref="ITaskListService"/> fake giving CaptureFlowService tests full
/// control over the task list without a real <see cref="TaskRepository"/>/SQLite fixture. Records
/// every mutation call so tests can assert exactly what CaptureFlowService asked for (mirrors
/// State/TestSupport.cs's `RecordingEligibilityService` convention for the sibling frozen
/// interface).</summary>
internal sealed class FakeTaskListService : ITaskListService
{
    public List<TaskItem> BackingTasks { get; } = new();

    public TaskItem? FrogOverride { get; set; }

    public TaskItem? ActiveOverride { get; set; }

    public int RefreshCallCount { get; private set; }

    public List<TaskItem> AddedTasks { get; } = new();

    public List<Guid> ToggledIds { get; } = new();

    public IReadOnlyList<TaskItem> Tasks => BackingTasks;

    public IReadOnlyList<TaskItem> NowTasks => BackingTasks.Where(t => !t.Done && t.When == When.Now).ToList();

    public IReadOnlyList<TaskItem> LaterTasks => BackingTasks.Where(t => !t.Done && t.When == When.Later).ToList();

    public IReadOnlyList<TaskItem> DoneTasks => BackingTasks.Where(t => t.Done).ToList();

    public IReadOnlyList<TaskItem> OpenTasks => NowTasks.Concat(LaterTasks).ToList();

    public TaskItem? FrogTask => FrogOverride;

    public TaskItem? ActiveTask => ActiveOverride;

    public event Action? TasksChanged;

    public Task RefreshAsync()
    {
        RefreshCallCount++;
        TasksChanged?.Invoke();
        return Task.CompletedTask;
    }

    public Task AddAsync(TaskItem task)
    {
        BackingTasks.Insert(0, task);
        AddedTasks.Add(task);
        TasksChanged?.Invoke();
        return Task.CompletedTask;
    }

    public Task ToggleDoneAsync(Guid id)
    {
        ToggledIds.Add(id);
        var index = BackingTasks.FindIndex(t => t.Id == id);
        if (index >= 0)
        {
            var item = BackingTasks[index];
            item.Status = item.Done ? TaskState.Todo : TaskState.Done;
            BackingTasks[index] = item;
        }
        TasksChanged?.Invoke();
        return Task.CompletedTask;
    }

    public Task DeleteAsync(Guid id)
    {
        BackingTasks.RemoveAll(t => t.Id == id);
        TasksChanged?.Invoke();
        return Task.CompletedTask;
    }

    public Task SetFrogAsync(Guid id) => Task.CompletedTask;
}

// MARK: - IIntentParser fake

/// <summary>Fully controllable <see cref="IIntentParser"/> fake — most CaptureFlowService tests
/// want a canned result, not real heuristic parsing (that is exercised separately in
/// Volar.Parsing.Tests). Every call is recorded so tests can assert what CaptureFlowService actually
/// asked for (transcript never logged elsewhere in this project — recording it here, in-memory, for
/// test assertions only, is not a violation of that rule).</summary>
internal sealed class FakeIntentParser : IIntentParser
{
    public List<string> ParseCalls { get; } = new();

    public IReadOnlyList<ParsedTask> Result { get; set; } = Array.Empty<ParsedTask>();

    public Task<IReadOnlyList<ParsedTask>> ParseAsync(
        string transcript, DateTimeOffset now, IReadOnlyList<string> openTaskTitles, CancellationToken cancellationToken = default)
    {
        ParseCalls.Add(transcript);
        return Task.FromResult(Result);
    }

    public Task<IReadOnlyList<string>> BreakdownAsync(string title, string? notes, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>());
}

// MARK: - ISpeechEngine / ISpeechEngineProvider fakes

/// <summary>Controllable batch <see cref="ISpeechEngine"/> fake. Deliberately does NOT raise
/// <see cref="OnFinal"/> automatically from <see cref="Stop"/> — tests call <see cref="RaiseFinal"/>
/// explicitly, reproducing the real async gap between "mic off" (`Stop()` returns) and "transcript
/// arrives" (`OnFinal` fires) that FIX 1 exists to protect against.</summary>
internal sealed class FakeSpeechEngine : ISpeechEngine
{
    public bool SupportsPartialResults => false;

    public bool IsRunning { get; private set; }

    public bool AuthorizationResult { get; set; } = true;

    public Exception? AuthorizationException { get; set; }

    public int StartCallCount { get; private set; }

    public int StopCallCount { get; private set; }

    public int CancelCallCount { get; private set; }

    public event Action<string>? OnFinal;

    public event Action<Exception>? OnError;

    public Task<bool> RequestAuthorizationAsync(CancellationToken cancellationToken = default)
    {
        if (AuthorizationException is { } ex)
        {
            return Task.FromException<bool>(ex);
        }
        return Task.FromResult(AuthorizationResult);
    }

    public void Start(Action<string>? onPartial = null)
    {
        StartCallCount++;
        IsRunning = true;
    }

    public void Stop()
    {
        StopCallCount++;
        IsRunning = false;
    }

    public void Cancel()
    {
        CancelCallCount++;
        IsRunning = false;
    }

    public void RaiseFinal(string transcript) => OnFinal?.Invoke(transcript);

    public void RaiseError(Exception error) => OnError?.Invoke(error);
}

internal sealed class FakeSpeechEngineProvider : ISpeechEngineProvider
{
    public ISpeechEngine SelectedEngine { get; set; } = new FakeSpeechEngine();
}

// MARK: - IDelegationHandoff recorder (the C3/C4 seam)

/// <summary>Records every hand-off <see cref="CaptureFlowService"/>'s voice-done `.Delegate` action
/// makes, standing in for whatever C4/C5 eventually wire <see cref="IDelegationHandoff"/> to
/// (C4's `DelegationOrchestratorService`). Proves the seam's shape without depending on C4's file.</summary>
internal sealed class RecordingDelegationHandoff : IDelegationHandoff
{
    public List<(Guid TaskId, string? Label, int CheckBackMinutes)> Calls { get; } = new();

    public Task DelegateAsync(Guid taskId, string? label, int checkBackMinutes, CancellationToken cancellationToken = default)
    {
        Calls.Add((taskId, label, checkBackMinutes));
        return Task.CompletedTask;
    }
}

// MARK: - Volar.Speech leaf fakes (for SpeechEngineServiceTests, which construct real
// WhisperNetEngine/GroqEngine wired to fakes at the hardware/network boundary only)

/// <summary>No-hardware <see cref="Audio.IAudioCaptureService"/> fake — exists purely so
/// <see cref="Speech.Whisper.WhisperNetEngine"/>/<see cref="GroqEngine"/> can be constructed in a
/// test process without touching NAudio/WASAPI, mirroring the seam those two engines' own file
/// headers document as designed for exactly this ("Phần chạm phần cứng ... hãy đặt sau interface và
/// test bằng fake/mock").</summary>
internal sealed class FakeAudioCaptureService : Volar.Speech.Audio.IAudioCaptureService
{
    public bool IsRunning { get; private set; }

    public TimeSpan? MaxDuration { get; set; }

    public event Action<Exception>? OnError { add { } remove { } }

    public Task<bool> RequestAuthorizationAsync(CancellationToken cancellationToken = default) => Task.FromResult(true);

    public void Start() => IsRunning = true;

    public Task<string> StopAsync(CancellationToken cancellationToken = default)
    {
        IsRunning = false;
        return Task.FromResult(string.Empty);
    }

    public void Cancel() => IsRunning = false;

    public void Dispose()
    {
    }
}

/// <summary>Controllable <see cref="IGroqCredentialProvider"/> — the ONLY thing
/// <see cref="SpeechEngineService.SelectedEngine"/>'s fallback logic actually reads off
/// <see cref="GroqEngine"/>.</summary>
internal sealed class FakeGroqCredentialProvider : IGroqCredentialProvider
{
    public bool IsConfigured { get; set; }

    public Task<Uri> GetBaseUrlAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(new Uri("https://example.invalid/"));

    public Task<string?> GetAuthorizationAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<string?>(null);
}

// MARK: - Shared task/parsed-task builders

internal static class CaptureTestData
{
    internal static readonly DateTimeOffset Now = new(2026, 7, 25, 9, 0, 0, TimeSpan.Zero);

    internal static TaskItem OpenTask(string title, Guid? id = null, When when = When.Now) => new(
        id: id ?? Guid.NewGuid(),
        title: title,
        priority: Priority.Medium,
        when: when,
        createdAt: Now,
        status: TaskState.Todo);

    internal static ParsedTask SimpleTask(string title, string transcript) => new(title, transcript);
}
