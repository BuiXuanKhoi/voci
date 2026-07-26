// ViewModels/CapturePopoverViewModel.cs — thin INPC bridge over CaptureFlowService for
// Views/CapturePopover.xaml(.cs). wave4-contract.md Stage B agent B2, frozen decision 7 (full
// PopoverView fidelity minus the N/A dictation-consent sub-flow) + decision 12 (VM pattern: commands
// call the service then Refresh(); subscribe to CaptureChanged via UiDispatch; no XAML types here).
//
// SOURCE OF TRUTH: this class deliberately does NOT reimplement any of CaptureFlowService's state
// machine, chip-resolution, or conflict logic — every property below either passes a
// CaptureFlowService/ITaskListService read straight through, or recomputes the SAME small
// visibility/label formulas PopoverView.swift itself computes from `appState.captureState` (the
// `showWave`/`showTranscript`/`showParsedCard`/`showActions`/`showVoiceDoneCard` computed
// properties, `leftHint`/`transcriptText`/`saveLabel`, and the chip-label formatters at the bottom
// of PopoverView.swift). Line citations throughout point at the exact Swift source this ports.
//
// WHY THE VIEW (not this VM) OWNS PER-DRAFT/PER-CHIP RENDERING: `ConfirmDraft` (Services/State/
// CaptureFlowService.cs) is already a plain, XAML-free C# class exposing everything a chip/condition
// row needs (Task, Dismissed, Accepted, DismissedConditions, AcceptedConditions, ResolvedTaskDone,
// Conflicts, ConflictDismissed) — wrapping every one of those in a second parallel view-model layer
// here would just be indirection with no behavioral value, so CapturePopover.xaml.cs reads
// `ConfirmDraft` directly (via this VM's `ConfirmDrafts` passthrough) and calls back into this VM's
// command methods (`DismissAttribute`/`AcceptUncertainAttribute`/etc.) by (kind, draftId) — mirroring
// PopoverView.swift's own closure-per-chip style almost 1:1, just expressed as method calls instead
// of SwiftUI closures. This VM's job is state + commands; the View's job is presentation.
using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Dispatching;
using Volar.App.Services;
using Volar.App.Services.State;
using Volar.Core;
using Volar.Domain;

namespace Volar.App.ViewModels;

/// <summary>Coarse color role for the hint-row text (PopoverView.swift's `leftHint`/
/// `leftHintByCaptureState`, 147-196) — brushes themselves live in the View/XAML per decision 12
/// ("brushes live in XAML/converters"), this enum only says WHICH one applies.</summary>
public enum HintTone
{
    Muted,
    Accent,
    Reschedule,
    Done,
}

/// <summary>Thin ViewModel over <see cref="CaptureFlowService"/> for the capture popover. Headless-
/// constructible: takes only the two frozen service interfaces plus an optional
/// <see cref="DispatcherQueue"/> (null in a plain unit-test host, matching
/// <see cref="ViewModels.UiDispatch"/>'s own documented test-host fallback).</summary>
public sealed class CapturePopoverViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly CaptureFlowService _captureFlow;
    private readonly ITaskListService _taskList;
    private readonly DispatcherQueue? _dispatcherQueue;

    public CapturePopoverViewModel(CaptureFlowService captureFlow, ITaskListService taskList, DispatcherQueue? dispatcherQueue = null)
    {
        _captureFlow = captureFlow ?? throw new ArgumentNullException(nameof(captureFlow));
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _dispatcherQueue = dispatcherQueue;
        _captureFlow.CaptureChanged += OnCaptureChanged;
    }

    /// <inheritdoc />
    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnCaptureChanged() => UiDispatch.Post(_dispatcherQueue, Refresh);

    /// <summary>Raises a single "everything may have changed" notification (empty/`null` property
    /// name, the standard INotifyPropertyChanged convention for "re-read everything") rather than a
    /// long list of individually-named properties. Deliberate, not a shortcut: like the SwiftUI
    /// source it ports, this popover's entire render tree is coupled to `captureState`/
    /// `confirmDrafts` as one unit (a state-machine card, not an independently-editable form) — the
    /// View re-renders its whole dynamic content on every call regardless, so granular property
    /// names would add bookkeeping with no behavioral benefit. Public so the View can force an
    /// initial render after wiring up its event handlers.</summary>
    public void Refresh() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));

    public void Dispose() => _captureFlow.CaptureChanged -= OnCaptureChanged;

    // --------------------------------------------------------------------------------------------
    // MARK: Passthrough state (CaptureFlowService's own public read surface)
    // --------------------------------------------------------------------------------------------

    public CaptureState State => _captureFlow.State;

    public string Transcript => _captureFlow.Transcript;

    public IReadOnlyList<ConfirmDraft> ConfirmDrafts => _captureFlow.ConfirmDrafts;

    public string? CaptureErrorDetail => _captureFlow.CaptureErrorDetail;

    public bool PendingCloudConsent => _captureFlow.PendingCloudConsent;

    public VoiceDoneConfirm? VoiceDoneConfirmState => _captureFlow.VoiceDoneConfirmState;

    public string? VoiceDoneNoMatchTranscript => _captureFlow.VoiceDoneNoMatchTranscript;

    /// <summary>Port of `appState.openTasks` (PopoverView.swift 511, 537-543) — deliberately
    /// UNCAPPED here, mirroring Swift exactly: the resolved-`.taskDone` title lookup (511, `first {
    /// $0.id == resolvedID }`) must search the FULL open-task list, while only the dependency
    /// picker's own rendered menu caps at 100 (539, `.prefix(100)`) — that cap is applied by the
    /// View at the point it builds the MenuFlyout, not here, so a resolved condition whose task
    /// happens to fall outside the first 100 still displays its real title instead of silently
    /// falling back to the fuzzy query text.</summary>
    public IReadOnlyList<TaskItem> OpenTasks => _taskList.OpenTasks;

    // --------------------------------------------------------------------------------------------
    // MARK: Visibility (PopoverView.swift 85-110: showWave/showTranscript/showParsedCard/
    // showActions/showVoiceDoneCard)
    // --------------------------------------------------------------------------------------------

    /// <summary>Port of `showVoiceDoneCard` (108-110).</summary>
    public bool ShowVoiceDoneCard => VoiceDoneConfirmState is not null || VoiceDoneNoMatchTranscript is not null;

    /// <summary>Port of `showWave` (87-89).</summary>
    public bool ShowWave => State == CaptureState.Recording || State == CaptureState.Parsing;

    /// <summary>Waveform's own `active` param (PopoverView.swift 205): recording only, not parsing —
    /// during `.Parsing` the bars are still shown (per `ShowWave`) but settled/flat.</summary>
    public bool WaveformActive => State == CaptureState.Recording;

    /// <summary>Port of `showTranscript` (91-93).</summary>
    public bool ShowTranscript => State != CaptureState.Idle && State != CaptureState.Error;

    /// <summary>Port of `showParsedCard` (95-99).</summary>
    public bool ShowParsedCard =>
        !ShowVoiceDoneCard
        && (State == CaptureState.Parsed || State == CaptureState.Saving || State == CaptureState.Done)
        && ConfirmDrafts.Count > 0;

    /// <summary>Port of `showActions` (101-103).</summary>
    public bool ShowActions => !ShowVoiceDoneCard && (State == CaptureState.Parsed || State == CaptureState.Saving);

    public bool ShowError => State == CaptureState.Error;

    /// <summary>Port of `waveformSection`'s `.done` branch (221-229): the checkmark glyph shown
    /// once `!showWave`.</summary>
    public bool ShowDoneCheck => !ShowWave && State == CaptureState.Done;

    /// <summary>Port of `waveformSection`'s `.error` branch (230-238): the generic "Try again"
    /// placeholder text (covers both plain errors and the two consent prompts, unchanged from
    /// pre-T024 behavior per the Swift comment).</summary>
    public bool ShowTryAgainPlaceholder => !ShowWave && State == CaptureState.Error;

    /// <summary>Port of `leftHintByCaptureState`'s `.recording` branch's `PulsingDot` (168-173) —
    /// only while recording AND no voice-done overlay is showing (mirrors `leftHint`'s if/else
    /// ordering: the voice-done branches take over the whole hint row first).</summary>
    public bool ShowListeningDot => State == CaptureState.Recording && !ShowVoiceDoneCard;

    /// <summary>Port of `transcriptSection`'s caret (255-263): only while recording.</summary>
    public bool ShowCaret => State == CaptureState.Recording;

    public bool IsSaveDisabled => State == CaptureState.Saving;

    // --------------------------------------------------------------------------------------------
    // MARK: Hint text / transcript text / save label (PopoverView.swift 147-196, 269-279, 830-834)
    // --------------------------------------------------------------------------------------------

    /// <summary>Port of `leftHint`/`leftHintByCaptureState` (147-196) — text only; see
    /// <see cref="HintToneValue"/> for the paired color role.</summary>
    public string HintText
    {
        get
        {
            if (VoiceDoneConfirmState is VoiceDoneConfirm confirm)
            {
                return confirm.Candidates.Count == 1 ? "Got it — confirm?" : "A few matches — pick one.";
            }
            if (VoiceDoneNoMatchTranscript is not null)
            {
                return "Didn't find a matching task.";
            }
            return State switch
            {
                CaptureState.Idle => string.Empty,
                CaptureState.Recording => "Listening…",
                CaptureState.Parsing => "Parsing with AI…",
                CaptureState.Parsed => ConfirmDrafts.Count > 1 ? "Looks right? Hit return to save all." : "Looks right? Hit return.",
                CaptureState.Saving => "Saving…",
                CaptureState.Done => "Saved",
                CaptureState.Error => CaptureErrorDetail ?? "Didn't catch that.",
                _ => string.Empty,
            };
        }
    }

    public HintTone HintToneValue
    {
        get
        {
            if (VoiceDoneConfirmState is not null)
            {
                return HintTone.Muted;
            }
            if (VoiceDoneNoMatchTranscript is not null)
            {
                return HintTone.Reschedule;
            }
            return State switch
            {
                CaptureState.Parsing or CaptureState.Saving => HintTone.Accent,
                CaptureState.Done => HintTone.Done,
                CaptureState.Error => HintTone.Reschedule,
                _ => HintTone.Muted,
            };
        }
    }

    /// <summary>Port of `transcriptText` (272-279).</summary>
    public string TranscriptText
    {
        get
        {
            if (State == CaptureState.Recording)
            {
                return Transcript;
            }
            if (ConfirmDrafts.Count == 0)
            {
                return Transcript;
            }
            var first = ConfirmDrafts[0];
            var extra = ConfirmDrafts.Count - 1;
            return extra > 0 ? $"{first.Task.Title}  +{extra} more" : first.Task.Title;
        }
    }

    /// <summary>Port of `saveLabel` (832-834).</summary>
    public string SaveLabel => ConfirmDrafts.Count > 1 ? $"Save {ConfirmDrafts.Count} tasks" : "Save task";

    // --------------------------------------------------------------------------------------------
    // MARK: Commands (call the service, await, Refresh() — decision 12). Every async method also
    // relies on CaptureChanged (subscribed above) as the eventually-consistent backstop for state
    // this SAME call may mutate later on a background thread (engine OnFinal/OnError, the 900ms
    // AutoDismissAsync flash-then-idle tail) — the explicit Refresh() below is the immediate-
    // feedback half, not the only one.
    // --------------------------------------------------------------------------------------------

    public async Task ToggleCaptureAsync()
    {
        await _captureFlow.ToggleCaptureAsync().ConfigureAwait(true);
        Refresh();
    }

    public async Task CancelAsync()
    {
        await _captureFlow.CancelCaptureAsync().ConfigureAwait(true);
        Refresh();
    }

    public async Task ConfirmSaveAsync()
    {
        await _captureFlow.ConfirmSaveAsync().ConfigureAwait(true);
        Refresh();
    }

    public void RemoveDraft(Guid draftId)
    {
        _captureFlow.RemoveDraft(draftId);
        Refresh();
    }

    public void DismissAttribute(ChipKind kind, Guid draftId)
    {
        _captureFlow.DismissAttribute(kind, draftId);
        Refresh();
    }

    public void AcceptUncertainAttribute(ChipKind kind, Guid draftId)
    {
        _captureFlow.AcceptUncertainAttribute(kind, draftId);
        Refresh();
    }

    public void DismissCondition(int conditionIndex, Guid draftId)
    {
        _captureFlow.DismissCondition(conditionIndex, draftId);
        Refresh();
    }

    public void AcceptUncertainCondition(int conditionIndex, Guid draftId)
    {
        _captureFlow.AcceptUncertainCondition(conditionIndex, draftId);
        Refresh();
    }

    public void ResolveTaskDone(int conditionIndex, Guid? taskId, Guid draftId)
    {
        _captureFlow.ResolveTaskDone(conditionIndex, taskId, draftId);
        Refresh();
    }

    public void DismissConflictAdvisory(Guid draftId)
    {
        _captureFlow.DismissConflictAdvisory(draftId);
        Refresh();
    }

    public async Task ConfirmVoiceDoneAsync(Guid taskId)
    {
        await _captureFlow.ConfirmVoiceDoneAsync(taskId).ConfigureAwait(true);
        Refresh();
    }

    public async Task DismissVoiceDoneConfirmAsync()
    {
        await _captureFlow.DismissVoiceDoneConfirmAsync().ConfigureAwait(true);
        Refresh();
    }

    public async Task CaptureVoiceDoneAsNewTaskAsync()
    {
        await _captureFlow.CaptureVoiceDoneAsNewTaskAsync().ConfigureAwait(true);
        Refresh();
    }

    public async Task ResolveCloudConsentAsync(bool allow)
    {
        await _captureFlow.ResolveCloudConsentAsync(allow).ConfigureAwait(true);
        Refresh();
    }

    public async Task StartCaptureAsync()
    {
        await _captureFlow.StartCaptureAsync().ConfigureAwait(true);
        Refresh();
    }

    // --------------------------------------------------------------------------------------------
    // MARK: Keyboard dispatch (wave4-contract.md Stage B/B2 brief: "Escape/Enter via
    // KeyboardAccelerators on the popover root dispatching to the VM's current-state commands (do
    // NOT port Swift's invisible-button FIX-D hack)"). Table below is the exhaustive port of every
    // `.keyboardShortcut(.cancelAction)`/`.keyboardShortcut(.defaultAction)` in PopoverView.swift
    // (875-878's inventory: ×4 cancelAction, ×4 defaultAction — minus the 2 dictation-consent
    // bindings, N/A per frozen decision 7).
    // --------------------------------------------------------------------------------------------

    /// <summary>Every `.cancelAction` in PopoverView.swift: the FIX-D invisible Esc button
    /// (recording/parsing, 138-145), `actionsRow`'s Cancel (793), `voiceDoneDismissButton` (731),
    /// `errorActionsRow`'s plain-error Dismiss (862). The two consent rows (dictation — dropped;
    /// cloud, 938-979) bind NEITHER button to `.cancelAction` in the Swift source, so Escape is a
    /// deliberate no-op while <see cref="PendingCloudConsent"/> is showing — not a gap.</summary>
    public void HandleEscape()
    {
        if (ShowVoiceDoneCard)
        {
            _ = DismissVoiceDoneConfirmAsync();
            return;
        }
        if (State == CaptureState.Error)
        {
            if (!PendingCloudConsent)
            {
                _ = CancelAsync();
            }
            return;
        }
        if (State is CaptureState.Recording or CaptureState.Parsing or CaptureState.Parsed or CaptureState.Saving)
        {
            _ = CancelAsync();
        }
    }

    /// <summary>Every `.defaultAction` in PopoverView.swift: `actionsRow`'s Save (825, disabled
    /// while <see cref="CaptureState.Saving"/> — Swift disables the same button its shortcut is
    /// attached to, so Enter is correctly a no-op mid-save), `voiceDoneConfirmButton` (710, used by
    /// BOTH the single-candidate one-tap confirm AND the no-match "Capture as new task instead" —
    /// the multi-candidate disambiguation list has no default-action button at all, so Enter is a
    /// no-op there), the cloud-consent row's decline/"Keep parsing on-device only" button (957 — the
    /// privacy-preserving default), and the plain-error "Try again" button (880). Dictation-consent's
    /// own `.defaultAction` (909) is N/A per frozen decision 7.</summary>
    public void HandlePrimaryEnter()
    {
        if (VoiceDoneConfirmState is VoiceDoneConfirm confirm)
        {
            if (confirm.Candidates.Count == 1)
            {
                _ = ConfirmVoiceDoneAsync(confirm.Candidates[0].TaskId);
            }
            return;
        }
        if (VoiceDoneNoMatchTranscript is not null)
        {
            _ = CaptureVoiceDoneAsNewTaskAsync();
            return;
        }
        if (State == CaptureState.Error)
        {
            if (PendingCloudConsent)
            {
                _ = ResolveCloudConsentAsync(allow: false);
            }
            else
            {
                _ = StartCaptureAsync();
            }
            return;
        }
        if (State == CaptureState.Parsed)
        {
            _ = ConfirmSaveAsync();
        }
    }
}

/// <summary>Pure chip/label/copy formatters, ported verbatim from PopoverView.swift's own private
/// helpers (736-771, 358-372, 645-673) — kept as static functions (no VM state needed) so
/// CapturePopover.xaml.cs can call them directly while rendering each draft's chip row, and so they
/// are trivially unit-testable in isolation from the rest of this VM's service wiring.</summary>
public static class CapturePopoverFormatting
{
    /// <summary>Port of `priorityLabel(_:)` (736-743).</summary>
    public static string PriorityLabel(int raw) => raw switch
    {
        1 => "High priority",
        2 => "Medium priority",
        3 => "Low priority",
        _ => $"Priority {raw.ToString(CultureInfo.InvariantCulture)}",
    };

    /// <summary>Port of `reminderLabel(_:)` (745-747).</summary>
    public static string ReminderLabel(ReminderPolicy policy) =>
        policy.RepeatEvery is not null
            ? "Custom reminders"
            : $"{policy.Offsets.Count} reminder{(policy.Offsets.Count == 1 ? string.Empty : "s")}";

    /// <summary>Port of `recurrenceLabel(_:)` (749-756).</summary>
    public static string RecurrenceLabel(Recurrence recurrence) => recurrence switch
    {
        Recurrence.Daily => "Daily",
        Recurrence.Weekly => "Weekly",
        Recurrence.Monthly => "Monthly",
        Recurrence.Every every => $"Every {every.Days.ToString(CultureInfo.InvariantCulture)}d",
        _ => string.Empty,
    };

    /// <summary>Port of `kindLabel(_:)` (758-760).</summary>
    public static string KindLabel(TaskKind kind) => kind == TaskKind.Review ? "Review" : kind.ToString();

    /// <summary>Port of `formattedDuration(_:)` (762-771) — mirrors `TaskItem.durationLabel`'s
    /// formatting, duplicated here for the same reason the Swift source duplicates it (a pre-save
    /// `ParsedTask` estimate, not a materialized `TaskItem`'s).</summary>
    public static string FormattedDuration(int minutes)
    {
        if (minutes < 60)
        {
            return $"{minutes.ToString(CultureInfo.InvariantCulture)} min";
        }
        var hours = minutes / 60;
        var mins = minutes % 60;
        if (mins == 0)
        {
            return hours == 1 ? "1 hr" : $"{hours.ToString(CultureInfo.InvariantCulture)} hrs";
        }
        return $"{hours.ToString(CultureInfo.InvariantCulture)}h {mins.ToString(CultureInfo.InvariantCulture)}m";
    }

    /// <summary>Port of `conflictAdvisoryText(_:)` (358-372) — one calm sentence per
    /// <see cref="TaskConflict"/> case, copy quoted verbatim from the Swift source (FR-036: no
    /// exclamation-mark alarm copy, never red/shame styling).</summary>
    public static string ConflictAdvisoryText(TaskConflict conflict) => conflict switch
    {
        TaskConflict.DeadlineCapacity capacity =>
            $"{capacity.ExistingCount.ToString(CultureInfo.InvariantCulture)} task{(capacity.ExistingCount == 1 ? string.Empty : "s")} " +
            $"already due {capacity.WindowEnd.ToString("dddd", CultureInfo.InvariantCulture)} — add anyway?",
        TaskConflict.DeadlineCollision collision => $"Clashes with “{collision.Title}” — add anyway?",
        TaskConflict.DependsOnBlocked blocked => $"Waiting on “{blocked.Title}”, which is overdue",
        TaskConflict.CompetesWithFrog frog => $"Competes with today's frog, “{frog.Title}”",
        TaskConflict.PossibleDuplicate duplicate => $"Looks similar to “{duplicate.Title}” — add anyway?",
        _ => string.Empty,
    };

    /// <summary>Port of `voiceDoneQuestion(_:)` (645-662).</summary>
    public static string VoiceDoneQuestion(VoiceDoneConfirm confirm)
    {
        var verb = confirm.Action switch
        {
            VoiceDoneAction.Complete => "Mark done",
            VoiceDoneAction.ClearExternal => "Clear",
            VoiceDoneAction.Delegate => "Hand off to Claude",
            _ => "Done",
        };
        if (confirm.Candidates.Count == 1)
        {
            return $"{verb}: “{confirm.Candidates[0].Title}”?";
        }
        return confirm.Action switch
        {
            VoiceDoneAction.Complete => "Which task is done?",
            VoiceDoneAction.ClearExternal => "Which one cleared?",
            VoiceDoneAction.Delegate => "Which task did you hand off?",
            _ => "Which task?",
        };
    }

    /// <summary>Port of `voiceDoneOneTapLabel(_:title:)` (664-673).</summary>
    public static string VoiceDoneOneTapLabel(VoiceDoneAction action, string title) => action switch
    {
        VoiceDoneAction.Complete or VoiceDoneAction.ClearExternal => $"Yes — {title}",
        VoiceDoneAction.Delegate => "Yes — hand off",
        _ => $"Yes — {title}",
    };
}
