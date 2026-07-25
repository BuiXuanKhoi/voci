// Services/State/FocusSessionService.cs — port of AppState.swift's focus-session cluster (§1.4 +
// §1.15, lines 244-247 + 1561-1642): `focusActive`/`focusPaused`/`focusSecondsLeft`/`focusIndex`/
// `focusTimer`, `startFocus`/`focusTick`/`endFocus`/`toggleFocusPause`/`completeFocusTask`/
// `readDayAloud`. Inventory cluster E. Per Opus decision 2 (wave3c-services.md), this service ALSO
// owns `voiceFeedback` (§1.1 row 7) even though it sits among the "frozen §4" properties at the top
// of the Swift file — E is voiceFeedback's only consumer.
//
// FIX 3 (specs/003-windows-port/appstate-inventory.md §6, quoted verbatim there): a previous
// version of this logic computed "remaining open tasks" as `openTasks.count - 1` BEFORE calling the
// completion mutation, assuming completing one task always drops the open count by exactly one.
// That assumption is false: `TaskRepository.ToggleAsync` resets a RECURRING task back to Todo in
// place instead of closing it (delta 0, not -1), and a parent auto-complete cascade can additionally
// close the now-childless parent in the same call (delta -2). `CompleteFocusTaskAsync` below calls
// the completion mutation FIRST (which itself reloads the task list from the repository — see
// TaskListService.cs's own header comment on why a hand-patched count can never be trusted), THEN
// reads `ITaskListService.OpenTasks.Count` fresh — reporting whichever delta actually happened
// instead of guessing. Porting the pre-fix "-1 assumed" order back in would be a regression, not a
// simplification (wave-wide rule).
//
// TIMER PORT: Swift arms a 1s-repeating `Timer` on the RunLoop, `@Sendable`-hopping back onto
// `@MainActor` every tick (`AppState.swift:1579-1586`, itself FIX B — moved here from
// `FocusOverlay` so the countdown survives the overlay window closing). This port uses the same
// fire-and-forget `Task.Delay` + monotonic-session-guard shape `EligibilityAndResurfaceService`'s
// FIX 2(b) wake-continuation already established in this codebase, rather than a
// `System.Threading.Timer`: it's the pattern this project's tests already know how to drive
// deterministically (inject a fast/immediately-completing delay function, exactly like
// `AppNotificationToastChannel`'s `_delay` parameter), with no `SynchronizationContext`/dispatcher
// dependency for a plain, unit-testable C# class.
//
// DELIBERATE BEHAVIOR REFINEMENT (self-review "behaviour drift", flagged): Swift's `focusTick()`
// guards `focusActive` and just returns early forever once it's false, without invalidating
// `focusTimer` itself — `completeFocusTask` can set `focusActive = false` (last task done) WITHOUT
// calling `endFocus()`/invalidating the timer, so the RunLoop timer keeps firing harmlessly-idle
// forever after a focus session's last task closes. This port's tick loop instead exits the moment
// it observes `FocusActive == false`, ending the background `Task` outright. Externally
// indistinguishable (a false `FocusActive` makes every future tick a no-op on both platforms; this
// port simply stops paying for that no-op) — chosen because a managed `Task`-based loop has no
// RunLoop-level idle-timer coalescing to lean on the way Swift's `Timer` does, so leaking it forever
// is a real (if small) cost here that has no counterpart benefit.
using System.Globalization;
using Volar.Domain;
using Volar.Speech.Playback;

namespace Volar.App.Services.State;

public sealed class FocusSessionService
{
    /// <summary>25 minutes, matching `AppState.swift:1564`'s literal `25 * 60`.</summary>
    public const int DefaultFocusSeconds = 25 * 60;

    private readonly ITaskListService _taskList;
    private readonly VoicePlayback _voice;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private int _focusSession;

    /// <param name="voiceFeedback">Mirrors the Swift `init(..., voiceFeedback: Bool = false, ...)`
    /// parameter (`AppState.swift:404`) — no setter, no persistence, exactly like the Swift original
    /// (inventory §1.1 row 7): set once at construction, read forever after.</param>
    /// <param name="delay">Defaults to <see cref="Task.Delay(TimeSpan,CancellationToken)"/>; tests
    /// inject an immediately-completing fake so a full 25-minute countdown never actually elapses
    /// wall-clock time in the test suite — same seam shape as
    /// <see cref="Adapters.AppNotificationToastChannel"/>'s own `_delay` parameter.</param>
    public FocusSessionService(
        ITaskListService taskList,
        VoicePlayback voice,
        bool voiceFeedback = false,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _voice = voice ?? throw new ArgumentNullException(nameof(voice));
        VoiceFeedback = voiceFeedback;
        _delay = delay ?? Task.Delay;
    }

    public bool VoiceFeedback { get; }

    public bool FocusActive { get; private set; }

    public bool FocusPaused { get; private set; }

    public int FocusSecondsLeft { get; private set; } = DefaultFocusSeconds;

    /// <summary>Index into <see cref="ITaskListService.OpenTasks"/> the focus overlay is currently
    /// showing. Swift lets `FocusOverlay` write this directly for prev/next navigation
    /// (`FocusOverlay.swift:199,204`, flagged in appstate-inventory.md §8) — this port keeps that
    /// same "view-local navigation, not a service method" shape via <see cref="StepFocusIndex"/>
    /// rather than inventing stricter encapsulation the Swift original never had.</summary>
    public int FocusIndex { get; private set; }

    /// <summary>Mirrors `startFocus()` (`AppState.swift:1563-1586`): resets the countdown, jumps
    /// <see cref="FocusIndex"/> to today's frog (or 0), activates the session, speaks if
    /// <see cref="VoiceFeedback"/>, and (re)arms the 1s countdown — invalidating any still-running
    /// loop from a previous session first via the monotonic session guard, so two overlapping
    /// sessions can never double-decrement (mirrors the Swift `focusTimer?.invalidate()` call
    /// immediately before arming a new `Timer`).</summary>
    public void StartFocus()
    {
        FocusSecondsLeft = DefaultFocusSeconds;
        FocusPaused = false;

        var openNow = _taskList.OpenTasks;
        var frogIndex = -1;
        for (var i = 0; i < openNow.Count; i++)
        {
            if (openNow[i].Frog)
            {
                frogIndex = i;
                break;
            }
        }
        FocusIndex = frogIndex >= 0 ? frogIndex : 0;
        FocusActive = true;

        if (VoiceFeedback)
        {
            var frogTitle = _taskList.FrogTask is TaskItem frog ? frog.Title : "Twenty five minutes.";
            SafeSpeak($"Focus session started. {frogTitle}");
        }

        var session = Interlocked.Increment(ref _focusSession);
        _ = TickLoopAsync(session);
    }

    /// <summary>The 1s tick loop — see this file's header comment for why this is a guarded
    /// fire-and-forget <see cref="Task"/> loop rather than a <see cref="System.Threading.Timer"/>.
    /// Mirrors `focusTick()` (`AppState.swift:1591-1601`): while paused, a tick is a no-op (the loop
    /// keeps running, mirroring Swift's timer staying armed-but-idle); reaching zero ends the
    /// session.</summary>
    private async Task TickLoopAsync(int session)
    {
        while (true)
        {
            try
            {
                await _delay(TimeSpan.FromSeconds(1), CancellationToken.None).ConfigureAwait(false);
            }
            catch
            {
                return; // never let a cancelled/faulted delay crash this fire-and-forget loop.
            }

            if (Volatile.Read(ref _focusSession) != session)
            {
                return; // superseded by a newer StartFocus()/EndFocus() call — stale loop, no-op.
            }
            if (!FocusActive)
            {
                // See file header "DELIBERATE BEHAVIOR REFINEMENT" — Swift leaves its Timer armed
                // but permanently idle here; this port simply stops the loop instead.
                return;
            }
            if (FocusPaused)
            {
                continue;
            }
            if (FocusSecondsLeft <= 0)
            {
                EndFocus();
                return;
            }
            FocusSecondsLeft -= 1;
            if (FocusSecondsLeft <= 0)
            {
                EndFocus();
                return;
            }
        }
    }

    /// <summary>Mirrors `endFocus()` (`AppState.swift:1603-1609`).</summary>
    public void EndFocus()
    {
        Interlocked.Increment(ref _focusSession); // invalidate any still-running tick loop.
        FocusActive = false;
        FocusSecondsLeft = DefaultFocusSeconds;
        FocusPaused = false;
    }

    /// <summary>Mirrors `toggleFocusPause()` (`AppState.swift:1611-1613`).</summary>
    public void ToggleFocusPause() => FocusPaused = !FocusPaused;

    /// <summary>View-local navigation seam, mirroring `FocusOverlay.swift:199,204`'s direct writes
    /// to `appState.focusIndex` (see this property's doc comment) — clamps into
    /// <c>[0, openTasks.count - 1]</c> (or 0 when empty), never throws on an out-of-range request.</summary>
    public void StepFocusIndex(int delta)
    {
        var count = _taskList.OpenTasks.Count;
        if (count == 0)
        {
            FocusIndex = 0;
            return;
        }
        var next = FocusIndex + delta;
        FocusIndex = Math.Max(0, Math.Min(next, count - 1));
    }

    /// <summary>
    /// Mirrors `completeFocusTask(_:)` (`AppState.swift:1617-1636`) — see this file's header comment
    /// for FIX 3. Returns the post-mutation open-task count purely so tests can assert on FIX 3's
    /// exact invariant without a hook into <see cref="VoicePlayback"/>'s spoken text (which this
    /// project has no seam to intercept — see this task's final report, self-review point 5).
    /// </summary>
    public async Task<int> CompleteFocusTaskAsync(Guid id)
    {
        // FIX 3: mutate first (this itself reloads the task list from the repository — see
        // TaskListService.ToggleDoneAsync's own header comment)...
        await _taskList.ToggleDoneAsync(id).ConfigureAwait(false);
        // ...THEN count. Never guess a delta.
        var remaining = _taskList.OpenTasks.Count;

        FocusIndex = remaining > 0 ? Math.Max(0, Math.Min(FocusIndex, remaining - 1)) : 0;
        if (remaining == 0)
        {
            FocusActive = false;
        }
        if (VoiceFeedback)
        {
            SafeSpeak(remaining > 0
                ? string.Create(CultureInfo.InvariantCulture, $"Done. {remaining} left today.")
                : "Done. All clear.");
        }
        return remaining;
    }

    /// <summary>Mirrors `readDayAloud()` (`AppState.swift:1638-1642`): announces the open-task count
    /// + up to 3 titles, or "All clear" when empty.</summary>
    public void ReadDayAloud()
    {
        var titles = new List<string>();
        foreach (var task in _taskList.OpenTasks)
        {
            titles.Add(task.Title);
        }
        try
        {
            _voice.ReadDay(titles);
        }
        catch
        {
            // Degrade quietly — a TTS failure must never surface as a service error (matches this
            // codebase's established convention, e.g. AppNotificationToastChannel.SafeSpeak).
        }
    }

    private void SafeSpeak(string text)
    {
        try
        {
            _voice.Speak(text);
        }
        catch
        {
            // Degrade quietly — see ReadDayAloud's identical rationale above.
        }
    }
}
