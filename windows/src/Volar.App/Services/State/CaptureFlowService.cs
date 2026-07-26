// Services/State/CaptureFlowService.cs — Wave 3-C stage 2, agent C3. Inventory cluster B
// ("capture -> parse -> confirm -> save") WITH cluster C merged in (Opus decision 1: voice-done
// classification + delegation-intent classification), ported from AppState.swift §1.12-1.14
// (662-1559) plus §1.18's `computeConflicts` (1900-1929, T074). Read alongside
// specs/003-windows-port/appstate-inventory.md before touching this file — every method below
// cites the exact Swift lines it ports.
//
// SCOPE CUT vs Swift (documented once here, not repeated per-member — see the wave's final report,
// self-review "parity" for the full table): Windows is batch-only (decision 8: no live caption) and
// has no Apple Speech framework, so every Apple-Speech-specific member is DROPPED, not stubbed:
// `allowServerRecognition`/`recognitionLocaleID`/`pendingServerConsent`/`useServerRecognition()`/
// `setRecognitionLocale(_:)`/`openDictationSettings()` (§1.12 rows 90-92, §1.1 rows 15-16). This
// file also does not replicate `liveTranscript`'s partial-result updates — `Transcript` (this file's
// rename of Swift's `liveTranscript`; there is nothing "live" about a batch engine's transcript, so
// the old name would mislead) is set exactly once per capture, when the final result lands.
//
// OWNERSHIP OF THE `store`/`scheduler` COLLABORATORS (read this before wondering why this class
// takes its own <see cref="TaskRepository"/>/<see cref="ReminderScheduler"/> instead of only
// <see cref="ITaskListService"/>): appstate-inventory.md §4 lists `store`/`scheduler` as CROSS-CUTTING
// collaborators injected into clusters A, B, D, H, I — NOT exclusively owned by A/TaskListService.
// Opus decision 5 ("one task list, one copy") forbids this class from CACHING a second `TaskItem`
// collection; it does not forbid holding a direct reference to the repository for mutations that are
// this cluster's OWN responsibility and have no slot in the frozen `ITaskListService` contract
// (`ConfirmSaveAsync`'s batch insert, `logCorrection`'s `RecordCorrectionAsync`, the voice-done
// `.clearExternal` action's `ClearFirstExternalConditionAsync` — none of these are cluster A's
// concern per the inventory's own cluster split, §3). Every mutation here still follows the SAME
// "mutate collaborator -> reload through the ONE owner -> read `_taskList.Tasks` back" discipline
// §5.3 mandates: this class calls `_taskList.RefreshAsync()` after touching the repository directly,
// never hand-patches anything, and never keeps its own `List<TaskItem>` field anywhere.
//
// FIX 1 (mandatory, appstate-inventory.md §6, quoted verbatim in that file): `StopCaptureAsync` must
// unconditionally enter `.Parsing` BEFORE calling `engine.Stop()`, for every engine, and a second
// `StopCaptureAsync` call while `.Parsing` is already in flight must be a clean no-op. See that
// method's own doc comment for the exact failure mode this prevents; see
// `Volar.App.Tests.Capture.CaptureFlowServiceTests.DoubleStop_...` for the required test.
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Volar.Core;
using Volar.Data;
using Volar.Data.Entities;
using Volar.Data.Exceptions;
using Volar.Domain;
using Volar.Parsing;
using Volar.Reminders;
using Volar.Speech;
using Volar.Speech.Playback;
using Volar.Voice;

namespace Volar.App.Services.State;

// ============================================================================================
// MARK: - UI-overlay types (this cluster's own state, never persisted — mirrors ConfirmDraft/
// ChipKind/VoiceDoneAction/VoiceDoneConfirm, AppState.swift 92-169)
// ============================================================================================

/// <summary>One attribute a confirm-card chip governs. Port of Swift's `enum ChipKind` (97-105).
/// `Title`/`Notes`/`Subtasks` have no chip (same reasoning as Swift); conditions are tracked
/// separately, keyed by index, on <see cref="ConfirmDraft"/> itself.</summary>
public enum ChipKind
{
    Deadline,
    Estimate,
    Priority,
    Reminder,
    Recurrence,
    Kind,

    /// <summary>Mi-1 (constitution II): makes `ParsedTask.FollowUpReview`'s derived second task
    /// visible/dismissible on the confirm card instead of materializing silently. Defaults ON —
    /// dismissing it is the exception.</summary>
    FollowUpReview,
}

/// <summary>
/// One confirmed task's editable confirm-card state, layered OVER a router-parsed
/// <see cref="ParsedTask"/> (never mutated in place) so every chip edit is reversible before Save.
/// Port of Swift's `struct ConfirmDraft` (112-142).
/// </summary>
/// <remarks>
/// Declared as a mutable <see langword="class"/> rather than mirroring Swift's value-type
/// <see langword="struct"/> — a C# <c>struct</c> stored inside a <c>List&lt;T&gt;</c> cannot be
/// mutated in place through a foreach/lookup the way Swift's copy-on-write struct-in-array can
/// (`confirmDrafts[index].dismissed.insert(...)` has no direct C# equivalent without re-indexing on
/// every single chip method); a reference type sidesteps that without changing behavior, since
/// nothing here relies on struct value-copy semantics (each draft is looked up once by
/// <see cref="Id"/> and mutated through that one reference, exactly like Swift's
/// `confirmDrafts[index]`).
/// </remarks>
public sealed class ConfirmDraft
{
    public Guid Id { get; } = Guid.NewGuid();

    public ParsedTask Task { get; }

    /// <summary>Scalar attribute chips explicitly removed — never saved regardless of confidence.</summary>
    public HashSet<ChipKind> Dismissed { get; } = new();

    /// <summary>Scalar attribute chips that were uncertain (&lt;0.7) and explicitly accepted.</summary>
    public HashSet<ChipKind> Accepted { get; } = new();

    /// <summary><see cref="ParsedTask.Conditions"/> indices removed (dismissed chip, or the taskDone
    /// picker's "Skip").</summary>
    public HashSet<int> DismissedConditions { get; } = new();

    /// <summary><see cref="ParsedTask.Conditions"/> indices (non-taskDone) that were uncertain and
    /// explicitly accepted.</summary>
    public HashSet<int> AcceptedConditions { get; } = new();

    /// <summary><see cref="ParsedTask.Conditions"/> indices of <c>TaskDone</c> cases resolved to a
    /// real existing task id — confident fuzzy match or explicit picker choice. Never populated by a
    /// guess below the confidence bar; an unresolved entry is simply absent, dropped at save.</summary>
    public Dictionary<int, Guid> ResolvedTaskDone { get; } = new();

    /// <summary>T074 conflict advisory — computed ONCE when this draft is created from a fresh parse,
    /// never recomputed per chip edit.</summary>
    public IReadOnlyList<TaskConflict> Conflicts { get; set; } = Array.Empty<TaskConflict>();

    /// <summary>User dismissed the (at most one rendered) conflict advisory line. One-way, never
    /// re-surfaces within this confirm session.</summary>
    public bool ConflictDismissed { get; set; }

    public ConfirmDraft(ParsedTask task)
    {
        Task = task;
    }
}

/// <summary>Which voice-done intent a <see cref="VoiceDoneConfirm"/> answers. Port of Swift's `enum
/// VoiceDoneAction` (149-158). Modeled as a closed union (matches this codebase's established
/// convention for <c>Condition</c>/<c>Recurrence</c>/<c>ParsedCondition</c>), matched exhaustively
/// via <see langword="switch"/>.</summary>
public abstract record VoiceDoneAction
{
    private protected VoiceDoneAction() { }

    public sealed record Complete : VoiceDoneAction;

    public sealed record ClearExternal : VoiceDoneAction;

    /// <summary>T042 (phase6-contract.md §C, US4): "giao cho Claude rồi" / "handed to Claude".
    /// <paramref name="CheckBackMinutes"/> is whatever <c>ClassifyDelegationIntent</c> parsed out of
    /// the utterance, defaulting to 10.</summary>
    public sealed record Delegate(int CheckBackMinutes) : VoiceDoneAction;
}

/// <summary>The pending glance-and-dismiss confirm for a <see cref="VoiceDoneAction"/>. Port of
/// Swift's `struct VoiceDoneConfirm` (165-169). One candidate -> a one-tap/one-word confirm UI;
/// several -> a bounded (&lt;=10, applied where this is constructed) disambiguation list.</summary>
public sealed record VoiceDoneConfirm(Guid Id, VoiceDoneAction Action, IReadOnlyList<VoiceMatch> Candidates);

/// <summary>
/// Narrow seam into whichever service owns delegation orchestration (inventory cluster I — agent
/// C4's <c>DelegationOrchestratorService</c>, running in parallel in this same wave stage). Defined
/// HERE, by C3, per this wave's hard constraint: the voice-done <c>.Delegate</c> action must hand off
/// to cluster I's full `delegateTask` (mark-delegated + refresh + reschedule + eligibility +
/// delegation-queue-refresh — see appstate-inventory.md row 178), but C3 may not reach into C4's
/// service or its files. C4/C5 must make <c>DelegationOrchestratorService</c> implement this
/// interface (directly, or via a two-line adapter) and C5 must register it into this class's
/// constructor. See this wave's final report for the exact wiring C5 needs.
/// </summary>
public interface IDelegationHandoff
{
    /// <summary>Mirrors Swift's <c>AppState.delegateTask(_:label:checkBackMinutes:)</c> in full —
    /// the refresh/reschedule/eligibility/queue-refresh tail is entirely cluster I's responsibility;
    /// this call only NEEDS to trigger it with the resolved task id, an optional caller-supplied
    /// label (<see langword="null"/> -&gt; cluster I resolves its own default, exactly like Swift's
    /// <c>label: String? = nil</c> falling back to the task's own title, else "Claude"), and the
    /// check-back minutes classified out of the utterance.</summary>
    Task DelegateAsync(Guid taskId, string? label, int checkBackMinutes, CancellationToken cancellationToken = default);
}

// ============================================================================================
// MARK: - CaptureFlowService
// ============================================================================================

/// <summary>Port of Swift's `enum CaptureState` (185-187). Batch-only capture (decision 8): unlike
/// Swift, no state here is ever reached via a partial-result callback — <see cref="Recording"/>
/// means "listening," full stop.</summary>
public enum CaptureState
{
    Idle,
    Recording,
    Parsing,
    Parsed,
    Saving,
    Done,
    Error,
}

/// <summary>
/// Inventory clusters B+C merged (Opus decision 1): the capture state machine, parse routing,
/// multi-draft confirm cards, attribute-chip interactions, conflict advisory, <see cref="ConfirmSaveAsync"/>,
/// the voice-done confirm branch, and delegation-intent classification. See this file's header for
/// the full scope-cut rationale and the collaborator-ownership note.
/// </summary>
public sealed partial class CaptureFlowService
{
    /// <summary>Extra settings key this class alone owns (NOT one of appstate-inventory.md §1.7's
    /// literal keys). Reproduces Swift's `cloudParseConsent: Bool?` tri-state — "never asked" (nil)
    /// vs. "asked and declined" (false) vs. "asked and allowed" (true) — which
    /// <see cref="ISettingsStore.GetBool"/> cannot express on its own: that accessor takes a
    /// caller-supplied default for the ABSENT case, so "absent" and "stored as false" are
    /// indistinguishable through it alone. Storing this second boolean is the one deliberate
    /// deviation from Swift's single-key (`volar.cloudParseConsent`) design in this file; the
    /// decision itself (`volar.cloudParseConsent`) is still read/written through the SAME key
    /// <see cref="Parsing.DefaultCloudParseGate"/> and <see cref="Parsing.ParseEnginePreferenceStore"/>
    /// already use — never a second source of truth for the decision, only for "have we asked."
    /// </summary>
    private const string CloudConsentAskedKey = "volar.cloudParseConsent.asked";

    private readonly ITaskListService _taskList;
    private readonly IEligibilityAndResurfaceService _eligibility;
    private readonly IIntentParser _parser;
    private readonly ISpeechEngineProvider _engineProvider;
    private readonly ITimeProvider _clock;
    private readonly ISettingsStore _settings;
    private readonly TaskRepository? _repository;
    private readonly ReminderScheduler? _scheduler;
    private readonly VoicePlayback? _voice;
    private readonly IDelegationHandoff? _delegationHandoff;
    private readonly TimeZoneInfo _timeZone;

    private readonly List<ConfirmDraft> _confirmDrafts = new();

    /// <summary>Monotonic guard, same role as Swift's `captureSession` (667). Bumped by every
    /// start/stop/cancel/dismiss/finish so a stale async continuation (permission grant, parse
    /// result, engine callback) can recognize it has been superseded and become a no-op instead of
    /// mutating state out from under a fresher capture.</summary>
    private int _captureSession;

    private ISpeechEngine? _runningEngine;
    private string? _pendingParseTranscript;

    /// <summary>Tracks which (engine, handler) pair is currently subscribed, so the next
    /// <see cref="StartCaptureAsync"/> call can unsubscribe it first. NEEDED because
    /// <see cref="ISpeechEngine.OnFinal"/>/<see cref="ISpeechEngine.OnError"/> are C# `event`s
    /// (+=/-= only) — unlike Swift's `SpeechCapture.onFinal`, a plain settable closure PROPERTY that
    /// each `startCapture()` call simply overwrites, a C# event accumulates subscribers across
    /// repeated captures of the SAME long-lived engine instance unless the previous handler is
    /// explicitly removed first. Without this, every capture after the first would leak one
    /// subscriber (harmless per-call, since the <c>_captureSession</c> guard inside each handler
    /// makes stale ones no-ops, but unbounded over an app session) — flagged and fixed here rather
    /// than silently ported, since this is a genuine platform-shape difference, not a stylistic one.</summary>
    private ISpeechEngine? _handlerEngine;
    private Action<string>? _handlerOnFinal;
    private Action<Exception>? _handlerOnError;

    public CaptureFlowService(
        ITaskListService taskList,
        IEligibilityAndResurfaceService eligibility,
        IIntentParser parser,
        ISpeechEngineProvider engineProvider,
        ITimeProvider clock,
        ISettingsStore settings,
        TaskRepository? repository = null,
        ReminderScheduler? scheduler = null,
        VoicePlayback? voice = null,
        IDelegationHandoff? delegationHandoff = null,
        TimeZoneInfo? timeZone = null)
    {
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _eligibility = eligibility ?? throw new ArgumentNullException(nameof(eligibility));
        _parser = parser ?? throw new ArgumentNullException(nameof(parser));
        _engineProvider = engineProvider ?? throw new ArgumentNullException(nameof(engineProvider));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _repository = repository;
        _scheduler = scheduler;
        _voice = voice;
        _delegationHandoff = delegationHandoff;
        _timeZone = timeZone ?? TimeZoneInfo.Utc;
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Public read surface (mirrors the interface WinUI binding will consume in Wave 4)
    // ------------------------------------------------------------------------------------------

    public CaptureState State { get; private set; } = CaptureState.Idle;

    /// <summary>Renamed from Swift's `liveTranscript` — see file header. Set exactly once per
    /// capture, when the batch engine's final result lands (or when a voice-done/delegation
    /// classification consumes it); never incrementally updated.</summary>
    public string Transcript { get; private set; } = string.Empty;

    public IReadOnlyList<ConfirmDraft> ConfirmDrafts => _confirmDrafts;

    public string? CaptureErrorDetail { get; private set; }

    public bool PendingCloudConsent { get; private set; }

    public VoiceDoneConfirm? VoiceDoneConfirmState { get; private set; }

    public string? VoiceDoneNoMatchTranscript { get; private set; }

    /// <summary>Replaces macOS's implicit `@Observable` auto-notify. Raised after every state change
    /// this service makes. NO thread marshaling of its own — mirrors
    /// <see cref="TaskListService.TasksChanged"/>'s documented deviation exactly: this event, and
    /// every public method here, may run on whichever thread an <see cref="ISpeechEngine.OnFinal"/>/
    /// <see cref="ISpeechEngine.OnError"/> callback happens to fire on (documented as a thread-pool
    /// thread, NOT the UI thread). C5 must marshal those callbacks (and therefore this event) onto
    /// the UI thread before any WinUI binding touches this service's state.</summary>
    public event Action? CaptureChanged;

    private void RaiseChanged() => CaptureChanged?.Invoke();

    /// <summary>Local↔cloud PARSE preference (distinct from <see cref="Services.State.SpeechEngineService"/>'s
    /// speech-engine choice). Port of `AppState.parseEnginePreference` (864-866): a thin presentation
    /// bridge over the SAME `volar.cloudParseConsent` bit <see cref="Parsing.DefaultCloudParseGate"/>
    /// gates <see cref="IIntentParser"/>'s Cloud tier on — never a second source of truth.</summary>
    public ParseEnginePreference ParseEnginePreference => ParseEnginePreferenceStore.Get(_settings);

    /// <summary>Port of `AppState.setParseEngine(_:)` (873-877). Also marks the tri-state consent as
    /// "asked" (see <see cref="CloudConsentAskedKey"/>'s remarks) — choosing a preference in Settings
    /// answers the same question the one-time voice-capture consent popover would have asked, exactly
    /// as it does in Swift (`cloudParseConsent` stops being `nil` either way).</summary>
    public void SetParseEngine(ParseEnginePreference preference)
    {
        ParseEnginePreferenceStore.Set(_settings, preference);
        _settings.SetBool(CloudConsentAskedKey, true);
        RaiseChanged();
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Capture state machine (662-820)
    // ------------------------------------------------------------------------------------------

    /// <summary>Toggle voice capture — the hotkey and any on-screen mic control call this. Port of
    /// `toggleCapture()` (814-820). NAMED exactly as wave3c-services.md's Stage-3 section specifies
    /// ("wires the hotkey to `CaptureFlowService.ToggleCaptureAsync()`") — C5 depends on this exact
    /// name.</summary>
    public Task ToggleCaptureAsync() => State == CaptureState.Recording ? StopCaptureAsync() : StartCaptureAsync();

    /// <summary>Port of `startCapture()` (682-731), minus every Apple-only branch (server-fallback
    /// wiring, per-engine locale). Sets `.Recording` and picks/records the engine SYNCHRONOUSLY
    /// (before the first <see langword="await"/>) so a subscriber of <see cref="CaptureChanged"/>
    /// observes "recording" immediately regardless of how long microphone authorization takes to
    /// resolve — the same property Swift's fire-and-forget `_Concurrency.Task{}` structure protects,
    /// achieved here with a plain <see langword="async"/> method instead (C# needs no actor-hop
    /// ceremony to get the same "UI updates before the await" guarantee).</summary>
    public async Task StartCaptureAsync()
    {
        State = CaptureState.Recording;
        Transcript = string.Empty;
        _confirmDrafts.Clear();
        VoiceDoneConfirmState = null;
        VoiceDoneNoMatchTranscript = null;
        CaptureErrorDetail = null;
        PendingCloudConsent = false;
        _pendingParseTranscript = null;
        _captureSession++;
        var session = _captureSession;
        var engine = _engineProvider.SelectedEngine;
        _runningEngine = engine;
        RaiseChanged();

        bool granted;
        try
        {
            granted = await engine.RequestAuthorizationAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            if (_captureSession == session && State == CaptureState.Recording)
            {
                CaptureErrorDetail = "Couldn't start the microphone.";
                State = CaptureState.Error;
                RaiseChanged();
            }
            Debug.WriteLine($"[Volar.App.Services.State.CaptureFlowService] RequestAuthorizationAsync threw {ex.GetType().Name}.");
            return;
        }

        // Stale? The hold ended (release/Esc/a fresh capture already started) while the permission
        // flow was in flight — mirrors Swift's `guard self.captureSession == session, self.captureState
        // == .recording else { return }` (704).
        if (_captureSession != session || State != CaptureState.Recording)
        {
            return;
        }
        if (!granted)
        {
            CaptureErrorDetail = "Microphone permission was denied.";
            State = CaptureState.Error;
            RaiseChanged();
            return;
        }

        RewireEngineHandlers(engine, session);
        engine.Start();
        RaiseChanged();
    }

    /// <summary>Unsubscribes the previous capture's handler pair (if any — see
    /// <see cref="_handlerEngine"/>'s remarks) before subscribing fresh ones bound to
    /// <paramref name="session"/>.</summary>
    private void RewireEngineHandlers(ISpeechEngine engine, int session)
    {
        if (_handlerEngine is not null)
        {
            if (_handlerOnFinal is not null)
            {
                _handlerEngine.OnFinal -= _handlerOnFinal;
            }
            if (_handlerOnError is not null)
            {
                _handlerEngine.OnError -= _handlerOnError;
            }
        }

        void OnFinal(string transcript)
        {
            if (_captureSession != session)
            {
                return;
            }
            _ = SafeFinishRecordingAsync(transcript);
        }

        void OnError(Exception error)
        {
            if (_captureSession != session)
            {
                return;
            }
            HandleCaptureError(error);
            RaiseChanged();
        }

        engine.OnFinal += OnFinal;
        engine.OnError += OnError;
        _handlerEngine = engine;
        _handlerOnFinal = OnFinal;
        _handlerOnError = OnError;
    }

    private async Task SafeFinishRecordingAsync(string transcript)
    {
        try
        {
            await FinishRecordingAsync(transcript).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // Never log the transcript itself — only the exception's type/shape.
            Debug.WriteLine($"[Volar.App.Services.State.CaptureFlowService] FinishRecordingAsync threw {ex.GetType().Name}.");
        }
    }

    /// <summary>Shared onError handling for whichever engine is running. Port of
    /// `handleCaptureError(_:)` (735-747), minus the Apple `.onDeviceUnavailable` special case (no
    /// Windows analog — see file header).</summary>
    private void HandleCaptureError(Exception error)
    {
        CaptureErrorDetail = error.Message;
        Debug.WriteLine($"[Volar.App.Services.State.CaptureFlowService] capture error: {error.GetType().Name}.");
        State = CaptureState.Error;
    }

    /// <summary>Port of `cancelCapture()` (763-779) — FIX 2a's contract preserved verbatim: `.Cancel()`
    /// immediately abandons capture and discards audio; neither `OnFinal` nor `OnError` fires for it.</summary>
    public Task CancelCaptureAsync()
    {
        _captureSession++;
        State = CaptureState.Idle;
        Transcript = string.Empty;
        _confirmDrafts.Clear();
        VoiceDoneConfirmState = null;
        VoiceDoneNoMatchTranscript = null;
        PendingCloudConsent = false;
        _pendingParseTranscript = null;
        _runningEngine?.Cancel();
        _runningEngine = null;
        RaiseChanged();
        return Task.CompletedTask;
    }

    /// <summary>
    /// FIX 1 (appstate-inventory.md §6, mandatory — do not "simplify" this back to the pre-fix
    /// shape). Port of `stopCapture()` (787-809), verbatim invariant:
    /// <list type="number">
    /// <item><see cref="CaptureState.Parsing"/> is entered UNCONDITIONALLY for every engine — never
    /// gated on whether the engine supports partial results (both Windows engines are batch-only per
    /// decision 8, which makes this MORE likely to matter than on macOS, not less: every single
    /// capture takes the async "mic off, waiting on the final transcript" gap this state exists to
    /// name).</item>
    /// <item>The state flip happens BEFORE <see cref="ISpeechEngine.Stop"/> is called, not after.</item>
    /// <item>A second call landing while <see cref="CaptureState.Parsing"/> is already in flight must
    /// be a clean no-op: at that point <c>engine.IsRunning</c> is already <see langword="false"/>
    /// (batch engines flip it synchronously inside <c>Stop()</c>) AND <see cref="State"/> is no
    /// longer <see cref="CaptureState.Recording"/>, so NEITHER branch below matches — it falls all
    /// the way through to the trailing `// else: no-op` and does nothing. The destructive pre-fix
    /// bug was exactly this second call instead bumping <see cref="_captureSession"/> (via a
    /// mis-scoped `else if`), which would invalidate the very session the in-flight `OnFinal`
    /// handler's guard checks against — silently discarding the user's speech. See
    /// <c>Volar.App.Tests.Capture.CaptureFlowServiceTests</c> for the required double-stop
    /// regression test.
    /// </item>
    /// </list>
    /// </summary>
    public Task StopCaptureAsync()
    {
        var engine = _runningEngine;
        if (engine is not null && engine.IsRunning)
        {
            State = CaptureState.Parsing;
            RaiseChanged();
            engine.Stop();
        }
        else if (State == CaptureState.Recording)
        {
            _captureSession++;
            State = CaptureState.Idle;
            Transcript = string.Empty;
            RaiseChanged();
        }
        // else: no-op — a stop landing while `.Parsing` (or anything else non-`.Recording`) is
        // already in flight must never fall through to the branch above and must never bump the
        // session out from under the in-flight `OnFinal`/`OnError` callback. This is FIX 1's whole
        // point; do not add an `else` branch here.
        return Task.CompletedTask;
    }

    // ------------------------------------------------------------------------------------------
    // MARK: External transcript entry (Wave 4, Stage C task 8) — volar://capture?text= app-link
    // ------------------------------------------------------------------------------------------

    /// <summary>
    /// Public entry point for a transcript that arrived from OUTSIDE this class's own mic pipeline —
    /// today, exactly one caller: <see cref="Volar.Orchestrator.AppLinkHandler.OnCapture"/>, wired by
    /// Stage C's App.xaml.cs to route <c>volar://capture?text=...&amp;source=...</c> here (see
    /// CompositionRoot.cs's own "NOTE (flagged, not silently skipped)" comment — this was the exact
    /// gap it named: "CaptureFlowService.cs (C3) exposes no PUBLIC entry point that accepts a bare
    /// transcript string outside its own mic-driven pipeline"). This method IS that entry point.
    ///
    /// STATE DISCIPLINE (mirrors FIX 1's invariant — see <see cref="StopCaptureAsync"/>'s own doc
    /// comment for the full rationale this echoes): only callable from <see cref="CaptureState.Idle"/>
    /// — a second/concurrent capture already in flight is left completely alone (no-op), the same
    /// "never steal a capture the user is mid-way through" discipline every other entry point in this
    /// class follows. There is no live microphone here (the text already arrived complete, e.g. from
    /// Claude Code's Stop hook via the app link), so this collapses the mic path's
    /// Recording-then-(FIX-1)-Parsing two-step into the ONE transition that actually matters to an
    /// observer: it goes straight to <see cref="CaptureState.Parsing"/> (never <see cref="CaptureState.Recording"/>
    /// — there is nothing to "listen" to) and then reuses the EXACT SAME finish pipeline a real
    /// engine's <see cref="ISpeechEngine.OnFinal"/> callback reaches
    /// (<see cref="FinishRecordingAsync"/> -&gt; delegation-intent / voice-done classification -&gt;
    /// <see cref="ProceedToCaptureAsync"/> -&gt; <see cref="RunParseAsync"/>), so an externally-supplied
    /// transcript gets the identical confirm-card/voice-done/delegation treatment a spoken one would —
    /// it never bypasses the confirm card, matching app-links.md's own "never bypasses the confirm
    /// card" contract for <c>volar://capture</c>.
    /// </summary>
    public async Task HandleExternalCaptureAsync(string transcript)
    {
        ArgumentNullException.ThrowIfNull(transcript);
        if (State != CaptureState.Idle)
        {
            return;
        }

        _captureSession++;
        var session = _captureSession;
        Transcript = string.Empty;
        _confirmDrafts.Clear();
        VoiceDoneConfirmState = null;
        VoiceDoneNoMatchTranscript = null;
        CaptureErrorDetail = null;
        PendingCloudConsent = false;
        _pendingParseTranscript = null;
        // FIX 1 parity: enter .Parsing unconditionally BEFORE the async finish tail runs — same
        // ordering StopCaptureAsync enforces for the mic path (state flip before the thing that can
        // take a while), just collapsed into one call since there is no engine.Stop() to await first.
        State = CaptureState.Parsing;
        RaiseChanged();

        try
        {
            await FinishRecordingAsync(transcript).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // Stale-session guard mirrors StartCaptureAsync's own catch block — only touch state if
            // nothing else (a cancel, a fresh capture) has already superseded this session.
            if (_captureSession == session && State == CaptureState.Parsing)
            {
                CaptureErrorDetail = "Couldn't process that.";
                State = CaptureState.Error;
                RaiseChanged();
            }
            Debug.WriteLine($"[Volar.App.Services.State.CaptureFlowService] HandleExternalCaptureAsync threw {ex.GetType().Name}.");
        }
    }

    // ------------------------------------------------------------------------------------------
    // MARK: finishRecording -> delegation-intent / voice-done classification (887-1136, 970-1136)
    // ------------------------------------------------------------------------------------------

    /// <summary>Port of `finishRecording(transcript:)` (887-910). Classification order is load-bearing
    /// (matches Swift's ordering comment at 889-895): delegation-intent FIRST, then voice-done, then
    /// fall through to ordinary new-task capture.</summary>
    private async Task FinishRecordingAsync(string transcript)
    {
        Transcript = transcript;

        var checkBackMinutes = ClassifyDelegationIntent(transcript);
        if (checkBackMinutes is int minutes)
        {
            PresentDelegationConfirm(minutes);
            return;
        }

        var openTasks = BuildVoiceDoneOpenTasks();
        switch (VoiceDone.Classify(transcript, openTasks))
        {
            case CompleteIntent complete:
                PresentVoiceDoneConfirm(new VoiceDoneAction.Complete(), complete.Candidates);
                break;
            case ClearExternalIntent clearExternal:
                PresentVoiceDoneConfirm(new VoiceDoneAction.ClearExternal(), clearExternal.Candidates);
                break;
            default:
                await ProceedToCaptureAsync(transcript).ConfigureAwait(false);
                break;
        }
    }

    /// <summary>Port of `voiceDoneOpenTasks` (936-947): id/title + each task's UNSATISFIED
    /// `.external` descriptions only. Rebuilt fresh from <see cref="ITaskListService.OpenTasks"/>
    /// every call — decision 5's read-through discipline, never cached.</summary>
    private IReadOnlyList<VoiceDoneTask> BuildVoiceDoneOpenTasks()
    {
        var result = new List<VoiceDoneTask>();
        foreach (var task in _taskList.OpenTasks)
        {
            var externalDescriptions = new List<string>();
            foreach (var condition in task.Conditions)
            {
                if (condition is ExternalCondition { Satisfied: false } external)
                {
                    externalDescriptions.Add(external.Description);
                }
            }
            result.Add(new VoiceDoneTask(task.Id, task.Title, externalDescriptions));
        }
        return result;
    }

    /// <summary>Port of `presentVoiceDoneConfirm(action:candidates:)` (958-968).</summary>
    private void PresentVoiceDoneConfirm(VoiceDoneAction action, IReadOnlyList<VoiceMatch> candidates)
    {
        if (candidates.Count == 0)
        {
            VoiceDoneNoMatchTranscript = Transcript;
            State = CaptureState.Parsed;
            RaiseChanged();
            return;
        }
        // Defensive cap, mirrors `runParse`'s own cap (self-review "client-exploit").
        VoiceDoneConfirmState = new VoiceDoneConfirm(Guid.NewGuid(), action, candidates.Take(10).ToArray());
        State = CaptureState.Parsed;
        RaiseChanged();
    }

    /// <summary>Trigger phrases for "I handed this off to Claude" (Vietnamese + English). Port of
    /// `delegationTriggerPhrases` (978-983), verbatim list, folded for matching via
    /// <see cref="FoldForMatch"/>.</summary>
    private static readonly string[] DelegationTriggerPhrases =
    {
        "giao cho claude", "giao viec cho claude", "da giao cho claude", "chuyen cho claude",
        "gui cho claude", "nho claude lam", "handed to claude", "handed off to claude",
        "gave it to claude", "gave this to claude", "delegated to claude", "delegated this to claude",
        "assigned to claude", "assigned this to claude",
    };

    /// <summary>Port of `classifyDelegationIntent(_:)` (989-995): <see langword="null"/> = not a
    /// delegation utterance at all (falls through to ordinary <see cref="VoiceDone"/>/new-task
    /// classification).</summary>
    private static int? ClassifyDelegationIntent(string transcript)
    {
        var folded = FoldForMatch(transcript);
        var matched = false;
        foreach (var phrase in DelegationTriggerPhrases)
        {
            if (folded.Contains(FoldForMatch(phrase), StringComparison.Ordinal))
            {
                matched = true;
                break;
            }
        }
        return matched ? ExtractCheckBackMinutes(folded) ?? 10 : null;
    }

    /// <summary>Diacritic/case fold — same NFD-decompose + strip-NonSpacingMark + explicit đ→d
    /// convention <see cref="Volar.Voice.VoiceDone"/> and <see cref="Volar.Core.ConflictChecker"/>
    /// already use elsewhere in this codebase (kept consistent rather than reaching for Swift's
    /// `.folding(options: .diacriticInsensitive)` idiom, which has no exact .NET equivalent).</summary>
    private static string FoldForMatch(string text)
    {
        var decomposed = text.ToLowerInvariant().Normalize(NormalizationForm.FormD);
        var stripped = new StringBuilder(decomposed.Length);
        foreach (var ch in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) == UnicodeCategory.NonSpacingMark)
            {
                continue;
            }
            stripped.Append(ch);
        }
        return stripped.ToString().Replace('đ', 'd');
    }

    [GeneratedRegex(@"(\d{1,4})\s*(phut|minutes?|mins?|min)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex CheckBackMinutesRegex();

    /// <summary>Port of `extractCheckBackMinutes(from:)` (1005-1014). Defensive clamp to 1...240
    /// minutes — a garbled/adversarial ASR result must never schedule a wildly-out-of-range
    /// check-back.</summary>
    private static int? ExtractCheckBackMinutes(string folded)
    {
        var match = CheckBackMinutesRegex().Match(folded);
        if (!match.Success || !int.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var value))
        {
            return null;
        }
        return Math.Min(Math.Max(value, 1), 240);
    }

    /// <summary>Port of `presentDelegationConfirm(checkBackMinutes:)` (1023-1036): always targets the
    /// current <see cref="ITaskListService.ActiveTask"/> — a bare "giao cho Claude rồi" names no
    /// task, and the single NOW slot IS the thing the user is working on.</summary>
    private void PresentDelegationConfirm(int checkBackMinutes)
    {
        if (_taskList.ActiveTask is not TaskItem active)
        {
            VoiceDoneNoMatchTranscript = Transcript;
            State = CaptureState.Parsed;
            RaiseChanged();
            return;
        }
        VoiceDoneConfirmState = new VoiceDoneConfirm(
            Guid.NewGuid(),
            new VoiceDoneAction.Delegate(checkBackMinutes),
            new[] { new VoiceMatch(active.Id, active.Title, 1.0) });
        State = CaptureState.Parsed;
        RaiseChanged();
    }

    /// <summary>User tapped the one-tap confirm, or picked one candidate from the disambiguation
    /// list. Port of `confirmVoiceDone(taskId:)` (1045-1062). Cleared FIRST — idempotency, mirrors
    /// `FinishSaveUI`'s "empty the source of truth before the async tail" convention so a stray
    /// double-tap on the about-to-vanish confirm button can't re-fire this.</summary>
    public async Task ConfirmVoiceDoneAsync(Guid taskId)
    {
        if (VoiceDoneConfirmState is not VoiceDoneConfirm confirm)
        {
            return;
        }
        var action = confirm.Action;
        VoiceDoneConfirmState = null;
        switch (action)
        {
            case VoiceDoneAction.Complete:
                await _taskList.ToggleDoneAsync(taskId).ConfigureAwait(false);
                break;
            case VoiceDoneAction.ClearExternal:
                await ClearExternalConditionAsync(taskId, _clock.Now).ConfigureAwait(false);
                break;
            case VoiceDoneAction.Delegate delegate_:
                await RouteDelegateActionAsync(taskId, delegate_.CheckBackMinutes).ConfigureAwait(false);
                break;
        }
        FinishVoiceDoneUI(action);
    }

    private async Task RouteDelegateActionAsync(Guid taskId, int checkBackMinutes)
    {
        if (_delegationHandoff is null)
        {
            Debug.WriteLine(
                "[Volar.App.Services.State.CaptureFlowService] voice-done .Delegate fired with no " +
                "IDelegationHandoff wired -- hand-off dropped. C5 must register one at startup " +
                "(see this wave's final report for the exact seam).");
            return;
        }
        await _delegationHandoff.DelegateAsync(taskId, label: null, checkBackMinutes).ConfigureAwait(false);
    }

    /// <summary>T036 `.ClearExternal`: clears the FIRST unsatisfied `.external` condition on
    /// <paramref name="taskId"/>. Port of `clearExternalCondition(taskId:now:)` (1093-1114) — the
    /// no-store branch is intentionally a no-op here (not a hand-patch): the frozen
    /// <see cref="ITaskListService"/> contract has no "clear condition" slot (that mutation belongs to
    /// this cluster, not cluster A — appstate-inventory.md row 108), and decision 5 forbids reaching
    /// into A's private list to fake one. This mirrors the existing "no-store means best-effort
    /// degrade, not a crash" convention rather than inventing new UI-visible behavior for an
    /// unsupported (store-less) graph.</summary>
    private async Task ClearExternalConditionAsync(Guid taskId, DateTimeOffset now)
    {
        if (_repository is null)
        {
            return;
        }
        var newlyEligible = await _repository.ClearFirstExternalConditionAsync(taskId, now).ConfigureAwait(false);
        await _taskList.RefreshAsync().ConfigureAwait(false);
        // WG-1: this task's own condition state just changed — re-derive its reminders, same as
        // every other condition-adding path in this codebase.
        _scheduler?.ScheduleReminders(taskId);
        if (newlyEligible.Count > 0)
        {
            _scheduler?.NotifyUnblocked(newlyEligible, now);
        }
        // Port of Swift's direct `scheduleNextResurface(from: tasks..., now:)` call (1113) — NOT the
        // combined `notifyEligibilityAndScheduleResurface`, since the eligibility half of that is
        // already handled above via `NotifyUnblocked` (self-review "performance", mirrors
        // TaskListService.DeleteAsync's own documented "reuse the diff already computed" tradeoff).
        // `RearmAsync` is exactly "scan the current task list fresh, arm resurface" — the frozen
        // contract's closest match to Swift's resurface-only call.
        await _eligibility.RearmAsync().ConfigureAwait(false);
    }

    /// <summary>Glance-and-dismiss "not this" / cancel — leaves every task untouched. Port of
    /// `dismissVoiceDoneConfirm()` (1066-1077). Also used as the no-match row's "Dismiss".</summary>
    public Task DismissVoiceDoneConfirmAsync()
    {
        _captureSession++;
        VoiceDoneConfirmState = null;
        VoiceDoneNoMatchTranscript = null;
        State = CaptureState.Idle;
        Transcript = string.Empty;
        _runningEngine?.Cancel();
        _runningEngine = null;
        RaiseChanged();
        return Task.CompletedTask;
    }

    /// <summary>The "no matching task" escape hatch. Port of `captureVoiceDoneAsNewTask()` (1082-1086).</summary>
    public Task CaptureVoiceDoneAsNewTaskAsync()
    {
        if (VoiceDoneNoMatchTranscript is not string transcript)
        {
            return Task.CompletedTask;
        }
        VoiceDoneNoMatchTranscript = null;
        return ProceedToCaptureAsync(transcript);
    }

    /// <summary>Shared "flash a result + auto-dismiss" tail for <see cref="ConfirmVoiceDoneAsync"/>.
    /// Port of `finishVoiceDoneUI(action:)` (1119-1137).</summary>
    private void FinishVoiceDoneUI(VoiceDoneAction action)
    {
        State = CaptureState.Done;
        _runningEngine?.Stop();
        var spoken = action switch
        {
            VoiceDoneAction.Complete => "Done.",
            VoiceDoneAction.ClearExternal => "Cleared.",
            VoiceDoneAction.Delegate => "Handed off.",
            _ => "Done.",
        };
        _voice?.Speak(spoken);
        _captureSession++;
        var session = _captureSession;
        RaiseChanged();
        _ = AutoDismissAsync(session);
    }

    /// <summary>900ms flash timing, session-guarded so a superseded flash never clobbers a fresh
    /// capture already in flight. Shared by <see cref="FinishVoiceDoneUI"/> and
    /// <see cref="FinishSaveUI"/> — Swift duplicates this timing block in both call sites (1131-1136,
    /// 1553-1558); this port factors it out since nothing differs between the two beyond which state
    /// they auto-dismiss FROM (always <see cref="CaptureState.Done"/> in both callers).</summary>
    private async Task AutoDismissAsync(int session)
    {
        try
        {
            await Task.Delay(TimeSpan.FromMilliseconds(900)).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Volar.App.Services.State.CaptureFlowService] AutoDismissAsync delay threw {ex.GetType().Name}.");
            return;
        }
        if (_captureSession != session || State != CaptureState.Done)
        {
            return;
        }
        State = CaptureState.Idle;
        Transcript = string.Empty;
        RaiseChanged();
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Cloud-parse consent + runParse (916-929, 1139-1242)
    // ------------------------------------------------------------------------------------------

    /// <summary>The ordinary Phase-3 new-task confirm flow, gated by the one-time cloud-parse
    /// consent. Port of `proceedToCapture(transcript:)` (916-929).</summary>
    private Task ProceedToCaptureAsync(string transcript)
    {
        if (!_settings.GetBool(CloudConsentAskedKey, false))
        {
            _pendingParseTranscript = transcript;
            PendingCloudConsent = true;
            CaptureErrorDetail =
                "Volar can parse on-device for free, or use a cloud AI for trickier phrasing. Cloud " +
                "parsing sends only the TEXT of what you said (never audio) to our server.";
            State = CaptureState.Error;
            RaiseChanged();
            return Task.CompletedTask;
        }
        return RunParseAsync(transcript);
    }

    /// <summary>User answered the one-time cloud-parse consent sheet. Port of
    /// `resolveCloudConsent(allow:)` (1143-1150).</summary>
    public Task ResolveCloudConsentAsync(bool allow)
    {
        ParseEnginePreferenceStore.Set(_settings, allow ? ParseEnginePreference.Cloud : ParseEnginePreference.OnDevice);
        _settings.SetBool(CloudConsentAskedKey, true);
        PendingCloudConsent = false;
        if (_pendingParseTranscript is not string transcript)
        {
            RaiseChanged();
            return Task.CompletedTask;
        }
        _pendingParseTranscript = null;
        return RunParseAsync(transcript);
    }

    /// <summary>The actual <see cref="IIntentParser.ParseAsync"/> call (T025). Port of
    /// `runParse(transcript:)` (1158-1191): builds up to <see cref="TaskRepository.MaxBatchSize"/>
    /// <see cref="ConfirmDraft"/>s, pre-resolves confident `.taskDone` conditions, and computes the
    /// T074 conflict advisory ONCE per parse against a single shared "now" instant.</summary>
    private async Task RunParseAsync(string transcript)
    {
        State = CaptureState.Parsing;
        _captureSession++;
        var session = _captureSession;
        var now = _clock.Now;
        var openTaskTitles = _taskList.OpenTasks.Select(t => t.Title).ToArray();
        RaiseChanged();

        var results = await _parser.ParseAsync(transcript, now, openTaskTitles).ConfigureAwait(false);

        // Stale? The hold ended (Esc/cancel/a second capture) while the parse was in flight —
        // mirrors `startCapture`'s authorization-pending guard.
        if (_captureSession != session || State != CaptureState.Parsing)
        {
            return;
        }

        // Defense-in-depth cap (self-review "client-exploit"): the router already enforces a
        // 10-task cap; this survives a malformed/hostile result regardless.
        var capped = results.Count <= TaskRepository.MaxBatchSize ? results : results.Take(TaskRepository.MaxBatchSize).ToArray();

        var conflictNow = _clock.Now;
        var allTasks = _taskList.Tasks;
        var frogId = _taskList.FrogTask?.Id;

        _confirmDrafts.Clear();
        foreach (var parsed in capped)
        {
            var draft = new ConfirmDraft(parsed);
            PreResolveConditions(draft);
            draft.Conflicts = ComputeConflicts(draft, conflictNow, allTasks, frogId, _timeZone);
            _confirmDrafts.Add(draft);
        }

        if (_confirmDrafts.Count == 0)
        {
            CaptureErrorDetail = "Didn't catch that.";
            State = CaptureState.Error;
        }
        else
        {
            State = CaptureState.Parsed;
        }
        RaiseChanged();
    }

    /// <summary>Auto-resolves `.taskDone` conditions the parser was itself confident about (&gt;=0.7)
    /// against a confident fuzzy title match in <see cref="ITaskListService.OpenTasks"/>. Port of
    /// `preResolveConditions(_:)` (1196-1206).</summary>
    private void PreResolveConditions(ConfirmDraft draft)
    {
        var candidates = _taskList.OpenTasks;
        for (var index = 0; index < draft.Task.Conditions.Count; index++)
        {
            if (draft.Task.Conditions[index] is not ParsedCondition.TaskDone taskDone || taskDone.Confidence < 0.7)
            {
                continue;
            }
            if (BestFuzzyMatch(taskDone.TitleQuery, candidates) is { Score: >= 0.7 } match)
            {
                draft.ResolvedTaskDone[index] = match.Id;
            }
        }
    }

    private readonly record struct FuzzyMatch(Guid Id, double Score);

    /// <summary>Token-overlap (Jaccard) similarity over whitespace-split, diacritic/case-folded
    /// tokens. Port of `bestFuzzyMatch(for:in:)`/`tokenize(_:)` (1217-1242) — deliberately the SAME
    /// simple placeholder heuristic Swift uses (not <see cref="Volar.Core.ConflictChecker"/>'s
    /// punctuation-stripping tokenizer), since this ports a specific Swift method, not a shared
    /// utility.</summary>
    private static FuzzyMatch? BestFuzzyMatch(string query, IReadOnlyList<TaskItem> openTasks)
    {
        var queryTokens = TokenizeForFuzzyMatch(query);
        if (queryTokens.Count == 0)
        {
            return null;
        }
        FuzzyMatch? best = null;
        foreach (var task in openTasks)
        {
            var titleTokens = TokenizeForFuzzyMatch(task.Title);
            if (titleTokens.Count == 0)
            {
                continue;
            }
            var shared = queryTokens.Intersect(titleTokens).Count();
            var union = queryTokens.Union(titleTokens).Count();
            if (union == 0)
            {
                continue;
            }
            var score = (double)shared / union;
            if (best is null || score > best.Value.Score)
            {
                best = new FuzzyMatch(task.Id, score);
            }
        }
        return best;
    }

    private static HashSet<string> TokenizeForFuzzyMatch(string text) =>
        new(
            FoldForMatch(text).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries),
            StringComparer.Ordinal);

    // ------------------------------------------------------------------------------------------
    // MARK: Confirm-card chip interactions (1244-1339)
    // ------------------------------------------------------------------------------------------

    private ConfirmDraft? FindDraft(Guid draftId) => _confirmDrafts.FirstOrDefault(d => d.Id == draftId);

    /// <summary>Port of `dismissAttribute(_:forDraft:)` (1255-1259).</summary>
    public void DismissAttribute(ChipKind kind, Guid draftId)
    {
        if (FindDraft(draftId) is not ConfirmDraft draft)
        {
            return;
        }
        draft.Dismissed.Add(kind);
        LogCorrection(kind, null, draft.Task, "dismissed");
        RaiseChanged();
    }

    /// <summary>Port of `acceptUncertainAttribute(_:forDraft:)` (1263-1267).</summary>
    public void AcceptUncertainAttribute(ChipKind kind, Guid draftId)
    {
        if (FindDraft(draftId) is not ConfirmDraft draft)
        {
            return;
        }
        draft.Accepted.Add(kind);
        LogCorrection(kind, null, draft.Task, "accepted");
        RaiseChanged();
    }

    /// <summary>Port of `dismissCondition(at:forDraft:)` (1271-1279).</summary>
    public void DismissCondition(int conditionIndex, Guid draftId)
    {
        if (FindDraft(draftId) is not ConfirmDraft draft)
        {
            return;
        }
        draft.DismissedConditions.Add(conditionIndex);
        draft.ResolvedTaskDone.Remove(conditionIndex);
        LogCorrection(null, $"condition[{conditionIndex}]", draft.Task, "dropped");
        RaiseChanged();
    }

    /// <summary>Port of `acceptUncertainCondition(at:forDraft:)` (1285-1292).</summary>
    public void AcceptUncertainCondition(int conditionIndex, Guid draftId)
    {
        if (FindDraft(draftId) is not ConfirmDraft draft)
        {
            return;
        }
        draft.AcceptedConditions.Add(conditionIndex);
        LogCorrection(null, $"condition[{conditionIndex}]", draft.Task, "accepted");
        RaiseChanged();
    }

    /// <summary>The dependency picker's resolution. Port of `resolveTaskDone(at:to:forDraft:)`
    /// (1297-1309). <paramref name="taskId"/> <see langword="null"/> drops the condition (picker's
    /// "Skip — no dependency").</summary>
    public void ResolveTaskDone(int conditionIndex, Guid? taskId, Guid draftId)
    {
        if (FindDraft(draftId) is not ConfirmDraft draft)
        {
            return;
        }
        if (taskId is Guid id)
        {
            draft.ResolvedTaskDone[conditionIndex] = id;
            draft.DismissedConditions.Remove(conditionIndex);
        }
        else
        {
            draft.DismissedConditions.Add(conditionIndex);
        }
        LogCorrection(null, $"condition[{conditionIndex}].taskDone", draft.Task, taskId?.ToString() ?? "dropped");
        RaiseChanged();
    }

    /// <summary>Multi-task confirm: removes one task from the batch entirely. Port of
    /// `removeDraft(_:)` (1313-1315).</summary>
    public void RemoveDraft(Guid draftId)
    {
        _confirmDrafts.RemoveAll(d => d.Id == draftId);
        RaiseChanged();
    }

    /// <summary>T074: dismisses the conflict advisory line for one draft — never re-derives or
    /// re-runs conflict detection. Port of `dismissConflictAdvisory(forDraft:)` (1320-1323).</summary>
    public void DismissConflictAdvisory(Guid draftId)
    {
        if (FindDraft(draftId) is not ConfirmDraft draft)
        {
            return;
        }
        draft.ConflictDismissed = true;
        RaiseChanged();
    }

    private static string ChipKindRawValue(ChipKind kind) => kind switch
    {
        ChipKind.Deadline => "deadline",
        ChipKind.Estimate => "estimate",
        ChipKind.Priority => "priority",
        ChipKind.Reminder => "reminder",
        ChipKind.Recurrence => "recurrence",
        ChipKind.Kind => "kind",
        ChipKind.FollowUpReview => "followUpReview",
        _ => "unknown",
    };

    /// <summary>Constitution V / FR-044: every chip edit is logged locally (never egressed) as the
    /// signal for improving parsing over time. Port of `logCorrection(kind:attribute:task:correctedValue:)`
    /// (1331-1339) — fire-and-forget (this class's own chip methods stay synchronous for callers,
    /// matching Swift's non-`async` chip methods) since logging is best-effort, never load-bearing
    /// for save. No-op without a repository, matching every other `store?.` call site in this
    /// codebase.</summary>
    private void LogCorrection(ChipKind? kind, string? attribute, ParsedTask task, string correctedValue)
    {
        if (_repository is null)
        {
            return;
        }
        var attributeName = attribute ?? (kind is ChipKind k ? ChipKindRawValue(k) : "unknown");
        var parsedDescription = ParsedValueDescription(kind, task);
        _ = FireAndForgetLogCorrectionAsync(attributeName, parsedDescription, correctedValue, task.SourceTranscript);
    }

    private async Task FireAndForgetLogCorrectionAsync(string attribute, string parsed, string corrected, string transcript)
    {
        try
        {
            await _repository!.RecordCorrectionAsync(attribute, parsed, corrected, transcript).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // Never log the transcript itself — only that the write failed and why (by type).
            Debug.WriteLine($"[Volar.App.Services.State.CaptureFlowService] RecordCorrectionAsync threw {ex.GetType().Name}.");
        }
    }

    /// <summary>Port of `parsedValueDescription(kind:task:)` (1341-1352). Purely a local diagnostic
    /// string (never egressed, never logged to Debug/Console) — culture-invariant formatting only,
    /// no locale-dependent output.</summary>
    private static string ParsedValueDescription(ChipKind? kind, ParsedTask task) => kind switch
    {
        ChipKind.Deadline => task.Deadline?.Value.ToString("O", CultureInfo.InvariantCulture) ?? "",
        ChipKind.Estimate => task.EstimateMinutes?.Value.ToString(CultureInfo.InvariantCulture) ?? "",
        ChipKind.Priority => task.Priority?.Value.ToString(CultureInfo.InvariantCulture) ?? "",
        ChipKind.Reminder => task.ReminderOverride?.Value.Offsets.Count.ToString(CultureInfo.InvariantCulture) ?? "",
        ChipKind.Recurrence => task.Recurrence?.Value.ToString() ?? "",
        ChipKind.Kind => task.Kind.ToString(),
        ChipKind.FollowUpReview => task.FollowUpReview.ToString(CultureInfo.InvariantCulture),
        null => "",
        _ => "",
    };

    // ------------------------------------------------------------------------------------------
    // MARK: ConfirmSaveAsync + materialization (1359-1541) + conflicts (1900-1929)
    // ------------------------------------------------------------------------------------------

    /// <summary>T025/T031: materializes every confirmed draft, persists it, and runs the shared
    /// eligibility/resurface tail + reminder scheduling exactly once for the whole batch. Port of
    /// `confirmSave()` (1359-1427).</summary>
    /// <remarks>
    /// BEHAVIOUR NOTE (self-review "performance"/"parity"): the WITH-repository path chunks by
    /// <see cref="TaskRepository.MaxBatchSize"/> and calls <see cref="TaskRepository.AddBatchAsync"/>
    /// per chunk — a direct, minimal-deviation port of Swift's own `stride(...).map(...)` chunking +
    /// per-chunk `store.addBatch` loop (1401-1408), preserved rather than "simplified" to N individual
    /// single-item inserts, so the one exception `AddBatchAsync` can throw
    /// (<see cref="BatchTooLargeException"/>) stays reachable exactly where Swift's `catch` block
    /// expects it, and so a follow-up-review child's `.taskDone(parent.id)` condition still validates
    /// against a snapshot that grows WITHIN a chunk the same way Swift's intra-batch validation does.
    /// </remarks>
    public async Task ConfirmSaveAsync()
    {
        if (_confirmDrafts.Count == 0)
        {
            return;
        }
        State = CaptureState.Saving;
        RaiseChanged();
        var now = _clock.Now;
        var before = _taskList.Tasks;

        var itemsToSave = new List<TaskItem>();
        foreach (var draft in _confirmDrafts)
        {
            var item = Materialize(draft, now);
            itemsToSave.Add(item);
            // Mi-1: the "+ review after done" chip is dismissible (defaults on) — only materialize
            // the derived `.review` task when the user hasn't dismissed it.
            if (draft.Task.FollowUpReview && !draft.Dismissed.Contains(ChipKind.FollowUpReview))
            {
                itemsToSave.Add(MaterializeFollowUpReview(item, now));
            }
        }

        if (_repository is null)
        {
            // No-store fallback (previews/tests without a repository): route each item through the
            // ONE owner of task state instead of hand-patching a second list (decision 5).
            // `ITaskListService.AddAsync`'s own no-repository branch inserts at index 0 per call, so
            // looping in `itemsToSave` order reproduces Swift's `insert(contentsOf: itemsToSave
            // .reversed(), at: 0)` final ordering one call at a time (each subsequent insert-at-0
            // pushes the previous item down by one, landing on the identical final order).
            foreach (var item in itemsToSave)
            {
                await _taskList.AddAsync(item).ConfigureAwait(false);
            }
            FinishSaveUI(itemsToSave.Select(i => i.Title).ToArray());
            return;
        }

        try
        {
            foreach (var chunk in ChunkBy(itemsToSave, TaskRepository.MaxBatchSize))
            {
                await _repository.AddBatchAsync(chunk.Select(i => i.ToEntity()).ToArray()).ConfigureAwait(false);
            }
            await _taskList.RefreshAsync().ConfigureAwait(false);
            var after = _taskList.Tasks;
            await _eligibility.NotifyEligibilityAndScheduleResurfaceAsync(before, after).ConfigureAwait(false);
            ScheduleRemindersForSavedItems(itemsToSave, after);
            FinishSaveUI(itemsToSave.Select(i => i.Title).ToArray());
        }
        catch (Exception ex)
        {
            // A failure on a LATER chunk (after earlier chunks already committed) is refreshed from
            // the repository here too, so the UI never shows stale/duplicate state for the part that
            // did save — the user only re-confirms what's genuinely still outstanding. `confirmDrafts`
            // is left intact so the user can adjust and retry rather than losing the capture.
            await _taskList.RefreshAsync().ConfigureAwait(false);
            var after = _taskList.Tasks;
            await _eligibility.NotifyEligibilityAndScheduleResurfaceAsync(before, after).ConfigureAwait(false);
            ScheduleRemindersForSavedItems(itemsToSave, after);
            CaptureErrorDetail = ex is TaskRepositoryException repositoryException ? repositoryException.Message : ex.Message;
            State = CaptureState.Error;
            RaiseChanged();
        }
    }

    private static IEnumerable<List<TaskItem>> ChunkBy(List<TaskItem> items, int size)
    {
        for (var i = 0; i < items.Count; i += size)
        {
            yield return items.GetRange(i, Math.Min(size, items.Count - i));
        }
    }

    /// <summary>WG-1: schedules reminders for exactly the drafts that actually made it into the task
    /// list — filtering against the just-refreshed snapshot rather than assuming every item in
    /// <paramref name="items"/> saved, so a partial-chunk failure never schedules a reminder for a
    /// task that was never actually persisted. Port of `scheduleRemindersForSavedItems(_:)`
    /// (1433-1439).</summary>
    private void ScheduleRemindersForSavedItems(IReadOnlyList<TaskItem> items, IReadOnlyList<TaskItem> after)
    {
        if (_scheduler is null)
        {
            return;
        }
        var savedIds = new HashSet<Guid>(after.Select(t => t.Id));
        foreach (var item in items)
        {
            if (savedIds.Contains(item.Id))
            {
                _scheduler.ScheduleReminders(item.Id);
            }
        }
    }

    /// <summary>One draft -&gt; one <see cref="TaskItem"/>. Port of `materialize(_:now:)`
    /// (1445-1474). <see cref="ParsedTask.SourceTranscript"/> is ALWAYS persisted.</summary>
    private static TaskItem Materialize(ConfirmDraft draft, DateTimeOffset now)
    {
        var task = draft.Task;
        var deadline = ResolvedDeadline(task.Deadline, ChipKind.Deadline, draft);
        var estimate = ResolvedInt(task.EstimateMinutes, ChipKind.Estimate, draft);
        var priorityInt = ResolvedInt(task.Priority, ChipKind.Priority, draft);
        var reminder = ResolvedReminderPolicy(task.ReminderOverride, ChipKind.Reminder, draft);
        var recurrence = ResolvedRecurrence(task.Recurrence, ChipKind.Recurrence, draft);
        var kind = draft.Dismissed.Contains(ChipKind.Kind) ? TaskKind.Task : task.Kind;

        return new TaskItem(
            id: Guid.NewGuid(),
            title: task.Title,
            priority: UiPriority(priorityInt),
            when: When.Now,
            createdAt: now,
            // `details` is the voice read-back copy — prefer explicit notes, else fall back to the
            // verbatim transcript so read-back is never empty.
            details: task.Notes ?? task.SourceTranscript,
            status: TaskState.Todo,
            deadline: deadline,
            conditions: ResolvedConditions(draft),
            durationMinutes: estimate,
            frog: false,
            notes: task.Notes,
            sourceTranscript: task.SourceTranscript,
            kind: kind,
            recurrence: recurrence,
            reminderOverride: reminder);
    }

    /// <summary>A <see cref="ParsedValue{T}"/> only materializes if present, not dismissed, and
    /// either confident (&gt;=0.7) or explicitly accepted. Port of `resolvedValue&lt;T&gt;(_:kind:draft:)`
    /// (1478-1482) — split into a shared bool predicate plus one thin, CONCRETELY-typed wrapper per
    /// value kind, rather than a single generic `T? ResolvedValue&lt;T&gt;(...)`.
    /// </summary>
    /// <remarks>
    /// BUG AVOIDED, documented so it is never reintroduced: C# 9's "unconstrained type parameter
    /// annotation" feature makes <c>T?</c> compile for an UNCONSTRAINED <c>T</c>, but for a value-type
    /// instantiation (e.g. <c>T = DateTimeOffset</c>) the <c>?</c> is a nullable-reference-tracking
    /// ANNOTATION ONLY — it does NOT erase to <see cref="Nullable{T}"/>. A first draft of this method
    /// declared <c>private static T? ResolvedValue&lt;T&gt;(...)</c> and `return default;` for the
    /// dismissed/uncertain-and-not-accepted cases; for `T = DateTimeOffset` that `default` silently
    /// erased to `DateTimeOffset.MinValue` (a REAL, non-null instant), not `null` — which then
    /// up-converted to a `HasValue: true` `DateTimeOffset?` the moment it was assigned into
    /// <see cref="TaskItem.Deadline"/>/<see cref="TaskSnapshot.Deadline"/>, and in one integration
    /// test caused <see cref="ConflictChecker.Conflicts"/> to run real date-math against
    /// <see cref="DateTimeOffset.MinValue"/>. Caught by this wave's own required tests (a dismissed
    /// deadline chip asserting the saved task's `Deadline` is <see langword="null"/>) — exactly the
    /// class of bug those tests exist to catch. The fix: never let a value-type `T?` cross a generic
    /// boundary unconstrained; each concrete nullable type below is spelled out explicitly instead.
    /// </remarks>
    private static bool IsResolved<T>(ParsedValue<T>? value, ChipKind kind, ConfirmDraft draft, out ParsedValue<T> resolved)
    {
        if (value is not ParsedValue<T> v || draft.Dismissed.Contains(kind) || (v.IsUncertain && !draft.Accepted.Contains(kind)))
        {
            resolved = default;
            return false;
        }
        resolved = v;
        return true;
    }

    private static DateTimeOffset? ResolvedDeadline(ParsedValue<DateTimeOffset>? value, ChipKind kind, ConfirmDraft draft) =>
        IsResolved(value, kind, draft, out var resolved) ? resolved.Value : null;

    private static int? ResolvedInt(ParsedValue<int>? value, ChipKind kind, ConfirmDraft draft) =>
        IsResolved(value, kind, draft, out var resolved) ? resolved.Value : null;

    private static ReminderPolicy? ResolvedReminderPolicy(ParsedValue<ReminderPolicy>? value, ChipKind kind, ConfirmDraft draft) =>
        IsResolved(value, kind, draft, out var resolved) ? resolved.Value : null;

    private static Recurrence? ResolvedRecurrence(ParsedValue<Recurrence>? value, ChipKind kind, ConfirmDraft draft) =>
        IsResolved(value, kind, draft, out var resolved) ? resolved.Value : null;

    /// <summary>Resolves `task.conditions` into <see cref="Condition"/>s. `.taskDone` only ever comes
    /// from <see cref="ConfirmDraft.ResolvedTaskDone"/> — an unresolved one is DROPPED, never guessed.
    /// Port of `resolvedConditions(_:)` (1489-1507).</summary>
    private static IReadOnlyList<Condition> ResolvedConditions(ConfirmDraft draft)
    {
        var result = new List<Condition>();
        for (var index = 0; index < draft.Task.Conditions.Count; index++)
        {
            if (draft.DismissedConditions.Contains(index))
            {
                continue;
            }
            switch (draft.Task.Conditions[index])
            {
                case ParsedCondition.AfterDate afterDate:
                    if (afterDate.Confidence >= 0.7 || draft.AcceptedConditions.Contains(index))
                    {
                        result.Add(new AfterDateCondition(afterDate.Date));
                    }
                    break;
                case ParsedCondition.External external:
                    if (external.Confidence >= 0.7 || draft.AcceptedConditions.Contains(index))
                    {
                        result.Add(new ExternalCondition(external.Description, false));
                    }
                    break;
                case ParsedCondition.TaskDone:
                    if (draft.ResolvedTaskDone.TryGetValue(index, out var resolvedId))
                    {
                        result.Add(new TaskDoneCondition(resolvedId));
                    }
                    break;
            }
        }
        return result;
    }

    /// <summary>Engine priority is 1...4; the UI <see cref="Priority"/> enum only spans 1...3. Clamp
    /// 4 into <see cref="Priority.Low"/> rather than throw. Port of `uiPriority(from:)` (1513-1520).</summary>
    private static Priority UiPriority(int? raw) => raw switch
    {
        1 => Priority.High,
        2 => Priority.Medium,
        3 or 4 => Priority.Low,
        _ => Priority.Medium,
    };

    /// <summary>`FollowUpReview`: a second `.review`-kind task depending on the just-created one via
    /// `.taskDone`. Port of `materializeFollowUpReview(for:now:)` (1526-1541).</summary>
    private static TaskItem MaterializeFollowUpReview(TaskItem parent, DateTimeOffset now) => new(
        id: Guid.NewGuid(),
        title: $"Review: {parent.Title}",
        priority: Priority.Medium,
        when: When.Later,
        createdAt: now,
        details: "",
        status: TaskState.Todo,
        deadline: null,
        conditions: new Condition[] { new TaskDoneCondition(parent.Id) },
        durationMinutes: null,
        frog: false,
        sourceTranscript: parent.SourceTranscript,
        kind: TaskKind.Review);

    /// <summary>Shared "Saved" flash + auto-dismiss tail. Port of `finishSaveUI(titles:)`
    /// (1546-1559).</summary>
    private void FinishSaveUI(IReadOnlyList<string> titles)
    {
        State = CaptureState.Done;
        _confirmDrafts.Clear();
        _runningEngine?.Stop();
        _voice?.Speak(titles.Count == 1 ? (titles.Count > 0 ? titles[0] : "Saved") : $"{titles.Count} tasks saved.");
        _captureSession++;
        var session = _captureSession;
        RaiseChanged();
        _ = AutoDismissAsync(session);
    }

    /// <summary>Builds the throwaway <see cref="TaskSnapshot"/> <see cref="ConflictChecker.Conflicts"/>
    /// needs, from exactly the same resolved/dismissed/accepted state <see cref="Materialize"/>/
    /// <see cref="ResolvedConditions"/> would use, so the advisory reflects what would ACTUALLY be
    /// saved — not the raw unconfirmed parse. Port of `computeConflicts(for:now:)` (1900-1929).
    /// `busyIntervals: []` until a future calendar integration lands (contract C, out of this wave's
    /// scope) — matches Swift's own `busyIntervals: []` placeholder exactly.</summary>
    private static IReadOnlyList<TaskConflict> ComputeConflicts(
        ConfirmDraft draft, DateTimeOffset now, IReadOnlyList<TaskItem> tasks, Guid? frogId, TimeZoneInfo timeZone)
    {
        var deadline = ResolvedDeadline(draft.Task.Deadline, ChipKind.Deadline, draft);
        var estimate = ResolvedInt(draft.Task.EstimateMinutes, ChipKind.Estimate, draft);
        var priorityInt = ResolvedInt(draft.Task.Priority, ChipKind.Priority, draft);
        var candidate = new TaskSnapshot(
            draft.Id,
            draft.Task.Title,
            TaskState.Todo,
            priorityInt,
            deadline,
            ResolvedConditions(draft),
            estimate,
            null,
            now);
        var snapshot = tasks.Select(t => t.Snapshot()).ToArray();
        return ConflictChecker.Conflicts(candidate, snapshot, now, timeZone, Array.Empty<DateInterval>(), frogId);
    }
}
