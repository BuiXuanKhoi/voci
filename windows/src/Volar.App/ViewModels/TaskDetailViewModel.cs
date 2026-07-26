// ViewModels/TaskDetailViewModel.cs — port of TaskDetailView.swift + the `speakDetails`/
// `closeDetail`/`deleteTask`/`toggleDone` slice of AppState.swift's "Detail sheet" cluster
// (AppState.swift:650-657) the Swift view itself reads through `@Environment(AppState.self)`.
// views-inventory.md §1.7.
//
// OWNERSHIP OF "WHICH TASK IS OPEN": Swift's `AppState.detailTaskID`/`detailTask` (a derived,
// never-cached computed property — appstate-inventory.md row 73) has no single Wave 3-C service
// owner (TriageAndSweepService.cs's own header comment calls this out: "Wave 4's shell/ViewModel
// owns ... the detail-sheet trio per Opus's stage-1 review"). This VM is that owner: <see
// cref="Show"/> is called by Stage C's shell when a TaskRow (B1) is tapped; <see cref="HasTask"/>
// is the bound visibility the overlay hosting Grid (Stage C) uses to show/hide this card.
//
// THE NIL-TASK DEFENSIVE PATTERN (wave4-contract.md's own framing of this view's hardest point):
// Swift's `body` renders `EmptyView()` the instant `appState.detailTask` returns nil (task deleted
// elsewhere while the sheet is open) — WinUI has no equivalent "render nothing" escape hatch mid-
// overlay, so <see cref="Refresh"/> flips <see cref="HasTask"/> to <see langword="false"/> the
// moment the tracked id disappears from <see cref="ITaskListService.Tasks"/>, and the hosting view
// must close programmatically on that transition rather than leave a blank-looking card open.
using System.ComponentModel;
using System.Windows.Input;
using Microsoft.UI.Dispatching;
using Volar.App.Services;
using Volar.Domain;
using Volar.Speech.Playback;

namespace Volar.App.ViewModels;

public sealed class TaskDetailViewModel : INotifyPropertyChanged
{
    private readonly ITaskListService _taskList;
    private readonly VoicePlayback _voice;
    private readonly DispatcherQueue? _dispatcherQueue;
    private Guid? _taskId;

    public TaskDetailViewModel(ITaskListService taskList, VoicePlayback voice, DispatcherQueue? dispatcherQueue = null)
    {
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _voice = voice ?? throw new ArgumentNullException(nameof(voice));
        _dispatcherQueue = dispatcherQueue;
        _taskList.TasksChanged += OnTasksChanged;

        ReadAloudCommand = new RelayCommand(ReadAloud, () => HasTask);
        CloseCommand = new RelayCommand(Close);
        DeleteCommand = new RelayCommand(() => _ = DeleteAsync(), () => HasTask);
        ToggleDoneCommand = new RelayCommand(() => _ = ToggleDoneAsync(), () => HasTask);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    // MARK: - Bound state (mirrors TaskDetailView.swift's `content(for:)` fields 1:1)

    public bool HasTask { get; private set; }

    public string Title { get; private set; } = string.Empty;

    /// <summary>`task.frog && !task.done` (TaskDetailView.swift:39) — the small amber dot next to
    /// the title.</summary>
    public bool ShowFrogDot { get; private set; }

    public Priority Priority { get; private set; }

    public string PriorityLabel => PriorityPresentation.Label(Priority);

    public bool HasDeadline { get; private set; }

    public string DeadlineText { get; private set; } = string.Empty;

    public bool HasDuration { get; private set; }

    public string DurationText { get; private set; } = string.Empty;

    /// <summary>"Done"/"Open" (TaskDetailView.swift:86).</summary>
    public string StatusText { get; private set; } = string.Empty;

    /// <summary><see langword="true"/> when `task.details` is non-empty — gates the
    /// "No description" placeholder (TaskDetailView.swift:103-109).</summary>
    public bool HasDescription { get; private set; }

    /// <summary>Only meaningful when <see cref="HasDescription"/> — the raw `task.details` text.</summary>
    public string DescriptionText { get; private set; } = string.Empty;

    public bool IsDone { get; private set; }

    /// <summary>"Mark done"/"Mark not done" (TaskDetailView.swift:189).</summary>
    public string ToggleDoneLabel => IsDone ? "Mark not done" : "Mark done";

    // MARK: - Commands

    public ICommand ReadAloudCommand { get; }

    public ICommand CloseCommand { get; }

    public ICommand DeleteCommand { get; }

    public ICommand ToggleDoneCommand { get; }

    // MARK: - Open/close (Stage C's shell calls these; see file header "ownership" note)

    /// <summary>Mirrors `appState.openDetail(_:)` (AppState.swift:652) — called by Stage C when a
    /// TaskRow is tapped.</summary>
    public void Show(Guid taskId)
    {
        _taskId = taskId;
        Refresh();
    }

    /// <summary>Mirrors `closeDetail()` (AppState.swift:653) — also the Close button's handler
    /// (TaskDetailView.swift:153) and the tail of both Delete and (in Swift's actions closure only
    /// for Delete, not toggleDone) the destructive path.</summary>
    public void Close()
    {
        _taskId = null;
        HasTask = false;
        RaiseAll();
    }

    // MARK: - Actions

    /// <summary>Mirrors `speakDetails(of:)` (AppState.swift:655-657): reads the description, or the
    /// title when there is none.</summary>
    private void ReadAloud()
    {
        if (!HasTask)
        {
            return;
        }
        var text = string.IsNullOrEmpty(DescriptionText) ? Title : DescriptionText;
        try
        {
            _voice.Speak(text);
        }
        catch
        {
            // Degrade quietly — matches every other `VoicePlayback`/`ISpeechEngine` call site in
            // this codebase (e.g. FocusSessionService.SafeSpeak's identical try/catch).
        }
    }

    /// <summary>Mirrors the Delete button (TaskDetailView.swift:166-168): delete, then close —
    /// `appState.deleteTask(task.id)` followed unconditionally by `appState.closeDetail()`.</summary>
    private async Task DeleteAsync()
    {
        if (_taskId is not Guid id)
        {
            return;
        }
        await _taskList.DeleteAsync(id).ConfigureAwait(false);
        UiDispatch.Post(_dispatcherQueue, Close);
    }

    /// <summary>Mirrors the Mark done/not done button (TaskDetailView.swift:186-188) — toggles and
    /// stays open (unlike Delete, `toggleDone` has no matching `closeDetail()` call in Swift).</summary>
    private async Task ToggleDoneAsync()
    {
        if (_taskId is not Guid id)
        {
            return;
        }
        await _taskList.ToggleDoneAsync(id).ConfigureAwait(false);
        // TasksChanged (raised by ToggleDoneAsync itself) already triggers OnTasksChanged -> Refresh
        // on the UI thread; no direct call needed here.
    }

    // MARK: - Refresh

    private void OnTasksChanged() => UiDispatch.Post(_dispatcherQueue, Refresh);

    private void Refresh()
    {
        if (_taskId is not Guid id)
        {
            if (HasTask)
            {
                HasTask = false;
                RaiseAll();
            }
            return;
        }

        TaskItem? found = null;
        foreach (var task in _taskList.Tasks)
        {
            if (task.Id == id)
            {
                found = task;
                break;
            }
        }

        if (found is not TaskItem task2)
        {
            // The nil-task defensive pattern — see file header. The backing task vanished (deleted
            // elsewhere) while this sheet was open; close programmatically rather than show stale data.
            HasTask = false;
            RaiseAll();
            return;
        }

        HasTask = true;
        Title = task2.Title;
        ShowFrogDot = task2.Frog && !task2.Done;
        Priority = task2.Priority;
        if (task2.Deadline is DateTimeOffset deadline)
        {
            HasDeadline = true;
            DeadlineText = deadline.ToString("h:mm tt", System.Globalization.CultureInfo.InvariantCulture);
        }
        else
        {
            HasDeadline = false;
            DeadlineText = string.Empty;
        }
        if (task2.DurationLabel is string duration)
        {
            HasDuration = true;
            DurationText = duration;
        }
        else
        {
            HasDuration = false;
            DurationText = string.Empty;
        }
        StatusText = task2.Done ? "Done" : "Open";
        HasDescription = !string.IsNullOrEmpty(task2.Details);
        DescriptionText = task2.Details;
        IsDone = task2.Done;
        RaiseAll();
    }

    private void RaiseAll()
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
        (ReadAloudCommand as RelayCommand)?.RaiseCanExecuteChanged();
        (DeleteCommand as RelayCommand)?.RaiseCanExecuteChanged();
        (ToggleDoneCommand as RelayCommand)?.RaiseCanExecuteChanged();
    }
}
