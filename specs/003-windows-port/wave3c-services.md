# Wave 3-C — App layer: services + adapters + wiring (5 agents, 3 stages)

Input: `specs/003-windows-port/appstate-inventory.md` (written 2026-07-25 — every `AppState`
member, what it reads/mutates, which view consumes it, every `UserDefaults` key literal, the
`.volarTasksDidChange` topology, and the four 2026-07-19 bug fixes quoted verbatim).
**Every agent in this wave must read that inventory before writing code**, plus the Swift file
it is porting from (`Volar/Sources/App/AppState.swift` in this worktree is current, post-review).

Wave 3-B closed the logic gaps (commit `afc436d`, 681 tests green). This wave replaces the
`Stubs/*.cs` placeholders and turns `AppState.swift` into services, so Wave 4's views have real
bindings to attach to.

## Decisions taken by Opus (do not re-litigate)

1. **9 services, not 10.** The inventory's cluster **C** (voice-done + delegation intent) is
   **merged into B (`CaptureFlowService`)**. Splitting them creates a two-way call cycle for no
   isolation benefit — both are driven by the same `captureSession`/`runningEngine` state B owns.
2. **`voiceFeedback` belongs to E (`FocusSessionService`)** — E is its only consumer, despite
   where it sits in the Swift file.
3. **`glass` gets no setter and no persistence.** The macOS app never had one; adding it here
   would be inventing product behaviour. Leave the property read-only and note it.
4. **The four sheet-gating bools are NOT poked by the shell.** macOS's `VolarApp.swift` sets
   `showTriage`/`showBreakdown`/`showSweep`/`showMorningFrog` directly from a `.task` block; the
   C# port does not reproduce that wart. Services expose gate methods
   (`MaybeShowEveningSweep()`, `MaybeShowTriage()`, `MaybeShowMorningFrog()`) and own their own
   flags. The shell calls gates; it never assigns flags.
5. **One task list, one copy.** `ITaskListService` is the single owner of task state. No other
   service may cache a `TaskItem` collection — they hold a reference to `ITaskListService` and
   read through it. This is the inventory's §4 conclusion and it is binding.
6. **The entity/domain mapper is finally written.** `windows/src/Volar.Data/Entities/TaskEntity.cs`
   lines 6-9 carry a Wave-1 note addressed to Opus: add `TaskEntity.ToTaskItem()` and the reverse.
   Do it now, in `Volar.Data`, with tests — services speak `Volar.Domain.TaskItem` (mirroring
   macOS `AppState.tasks: [TaskItem]`), never `TaskEntity`. Views therefore bind to `TaskItem`,
   which supersedes `wave4-slice.md`'s "bind/persist TaskEntity" line.
7. **Async is the boundary, not the core.** `TaskRepository` is async; macOS `TaskStore` is sync.
   Services expose async methods where they touch the repository, but every *decision* (ordering,
   eligibility, diffing, matching) stays synchronous and unit-testable with no I/O.
8. **Batch-only capture.** No live caption on Windows (anh Khôi, 2026-07-25). `CaptureFlowService`
   exposes a "listening" state and a single final transcript; do not invent a partial-results path.

## Wave-wide rules

- **Only `CompositionRoot.cs` may register services, and only agent C5 may edit it.** Every other
  agent declares its required registrations in its final report instead.
- **Only C5 deletes `Stubs/*.cs`.** Earlier agents add real types alongside the stubs so the tree
  keeps building at every point.
- Constructor-inject `ITimeProvider` (below) everywhere a clock is needed. No `DateTimeOffset.Now`
  inside any service method.
- Preserve the nullable-store degrade pattern: macOS guards `guard let store else { <in-memory
  fallback> }` in six places. Port that branch, do not assume the repository is always present.
- Reproduce the liveness topology from inventory §5 or the UI goes stale: the single
  `.volarTasksDidChange` post/observe pair becomes an event on `ITaskListService`; every
  `store.fetchAll()` re-read site becomes an explicit `await RefreshAsync()`.
- The four 2026-07-19 fixes are quoted in inventory §6. Porting the pre-fix behaviour is a
  regression, not a simplification. Each is a required test.
- xUnit tests live in a new `windows/tests/Volar.App.Tests/` project (C2 creates it; later agents
  extend it — file-disjoint per agent).
- Acceptance per agent: `dotnet build windows/Volar.Windows.sln -c Release` = 0 warning / 0 error,
  `dotnet test` green for every project (**681 tests before this wave** — no regressions).
- Self-review, stated explicitly in the final report: (1) parity — Swift member -> C# member table,
  and anything deliberately not ported; (2) behaviour drift; (3) security/privacy — no transcript,
  token, or path logged; (4) determinism — injected clock, culture-invariant strings;
  (5) tests — what is asserted and what could not be; (6) handoff — exact DI registrations,
  settings keys, and seams C5 must wire.

---

## Interfaces frozen by Opus (copy these signatures verbatim; do not redesign)

Put them in `windows/src/Volar.App/Services/Contracts.cs` (C2 creates the file; nobody else edits
it — if you need a change, report it).

```csharp
namespace Volar.App.Services;

/// Single clock seam for every service. Mirrors the Swift `clock: () -> Date` closure.
public interface ITimeProvider { DateTimeOffset Now { get; } }

/// The one owner of task state (Opus decision 5). Every other service holds a reference and
/// reads through it — nobody caches a second copy.
public interface ITaskListService
{
    IReadOnlyList<TaskItem> Tasks { get; }
    IReadOnlyList<TaskItem> NowTasks { get; }
    IReadOnlyList<TaskItem> LaterTasks { get; }
    IReadOnlyList<TaskItem> DoneTasks { get; }
    IReadOnlyList<TaskItem> OpenTasks { get; }
    TaskItem? FrogTask { get; }
    TaskItem? ActiveTask { get; }      // recompute per read, never cache (inventory §4)

    /// Replaces macOS's `.volarTasksDidChange` NotificationCenter pair. Raised after any
    /// mutation or refresh completes, on the UI thread.
    event Action? TasksChanged;

    Task RefreshAsync();
    Task AddAsync(TaskItem task);
    Task ToggleDoneAsync(Guid id);
    Task DeleteAsync(Guid id);
    Task SetFrogAsync(Guid id);
}

/// The shared mutation tail every writer calls (inventory cluster D). Kept separate from the
/// task list precisely because FIX 2's resurface chaining must be unit-testable alone.
public interface IEligibilityAndResurfaceService
{
    /// Diff eligibility across a mutation, notify newly-unblocked tasks, and (re)arm resurface
    /// for EVERY task with a future `.afterDate` — see FIX 2.
    Task NotifyEligibilityAndScheduleResurfaceAsync(
        IReadOnlyList<TaskItem> before, IReadOnlyList<TaskItem> after);

    /// Re-arm at launch/wake. Must be idempotent.
    Task RearmAsync();
}
```

---

## Stage 1 (parallel): C1 and C2

### C1 — infrastructure adapters (no `AppState` logic at all)

Replaces what `Stubs/*.cs` fakes today, with real Windows implementations. Files you own (all
new, under `windows/src/Volar.App/Services/Adapters/`):
- `AppNotificationToastChannel.cs` — implements `IToastChannel` via
  `Microsoft.Windows.AppNotifications` (WindowsAppSDK 1.8 is already referenced). Must support the
  reminder action buttons the macOS app registers (`NotificationActions` in `Volar.Reminders`:
  done / snooze 10' / tomorrow), report delivered ids for FIX B reconciliation, and degrade
  quietly when notifications are disabled by policy (Focus Assist) — never throw into the
  scheduler.
- `ReminderTaskStoreAdapter.cs` — `IReminderTaskStore` over `TaskRepository`.
- `OrchestratorTaskStoreAdapter.cs` — `IOrchestratorTaskStore` over `TaskRepository`.
- `FileDelegationMetaStore.cs` — durable `IDelegationMetaStore` (today's `InMemoryDelegationMetaStore`
  loses AI-handoff state on restart). JSON under `%LocalAppData%\Volar\`, atomic write, corrupt
  file = start empty.
- `UriSchemeRegistrar.cs` — register `volar://` under `HKCU\Software\Classes\volar` (unpackaged
  app; point at the running executable). Idempotent, and able to report whether registration is
  current. Without this the Claude Code hook and the "Chạy thử" button both fail silently.
- `SettingsThenEnvironmentReader.cs` — the ONE reader Wave 3-B's A3 asked for:
  `key => settings.GetString(key) ?? Environment.GetEnvironmentVariable(key)`. C5 must inject the
  same instance into both `GroqTranscriptionClient` and `GroqEngine` or they can disagree about
  whether cloud speech is configured.
- `SpeechEngineChoiceStore.cs` — persists `SpeechEngineChoice` under `volar.speechEngine`, shaped
  like `ParseEnginePreferenceStore`.
- Tests: `windows/tests/Volar.App.Tests/Adapters/**` (C2 creates the test project; if it does not
  exist yet when you get there, create it — you two are the only stage-1 agents and the csproj is
  a one-time add; coordinate by putting your tests in your own subfolder).

Do NOT touch `CompositionRoot.cs`, `Stubs/*.cs`, or anything under `Services/State/`.

### C2 — the linchpin: mapper + `TaskListService` + `EligibilityAndResurfaceService`

Files you own:
- `windows/src/Volar.Data/Entities/TaskEntityMapping.cs` (new) — `ToTaskItem()` / `ToEntity()`,
  resolving the Wave-1 note in `TaskEntity.cs:6-9`. Round-trip every field including conditions,
  recurrence, reminder override, parent, frog, resume note.
- `windows/src/Volar.App/Services/Contracts.cs` (new) — the frozen interfaces above, verbatim.
- `windows/src/Volar.App/Services/State/TaskListService.cs` (new) — inventory cluster A.
- `windows/src/Volar.App/Services/State/EligibilityAndResurfaceService.cs` (new) — cluster D,
  including **FIX 2** (per-task scan for every future `.afterDate`, wake chaining, launch re-arm).
- `windows/tests/Volar.App.Tests/**` (new project — xUnit, referenced from the sln) for your own
  tests under `windows/tests/Volar.App.Tests/State/`.

`TaskListService` must reproduce, from the inventory: the derived groupings, the reminder
side-effects inside `AddAsync`/`ToggleDoneAsync`/`DeleteAsync`, the post-mutation store re-read
(recurrence reset-in-place and parent cascade mean the in-memory list cannot be patched by hand —
this was macOS MAJOR bug #2 in the 2026-07-16 review), and `TasksChanged` firing after every one.

## Stage 2 (parallel, after stage 1 lands): C3 and C4

- **C3 — capture + speech:** `CaptureFlowService` (cluster B, with C merged in per decision 1:
  voice-done classification via `Volar.Voice`, delegation-intent phrases, confirm-card chip
  interactions, `ConfirmSaveAsync`) and `SpeechEngineService` (cluster F, 2 engines only).
  Includes **FIX 1** (always enter the parsing state before stopping the engine — the double-tap
  transcript-loss bug). Files under `Services/State/CaptureFlowService.cs`,
  `Services/State/SpeechEngineService.cs`, tests in `Volar.App.Tests/Capture/**`.
- **C4 — the rest:** `FocusSessionService` (cluster E, **FIX 3**: count open tasks AFTER the
  mutation), `ReminderAndDeliverySettingsService` (G), `TriageAndSweepService` (H, plus the gate
  methods from decision 4), `DelegationOrchestratorService` (I),
  `AppearanceAndPersistenceService` (J, **FIX 4**: accent/density persist; `glass` stays
  setter-less per decision 3). Files under `Services/State/` (distinct filenames from C3), tests
  in `Volar.App.Tests/Workflow/**`.

## Opus review notes from stage 1 (binding on later stages)

- **Two frozen-interface omissions are mine, not C2's.** `ITaskListService` has no slot for
  `detailTask`/`detailTaskID`/`openDetail`/`closeDetail`, and `IEligibilityAndResurfaceService` has
  none for `offerRescheduleForOverdueTasks`. C2 correctly flagged instead of widening the contract.
  **Decision: the detail-sheet trio belongs to the Wave 4 shell/ViewModel layer** (it is pure UI
  selection state — which task's sheet is open — not task data), and
  **`offerRescheduleForOverdueTasks` belongs to C4's `ReminderAndDeliverySettingsService`**, which
  already owns the scheduler's settings surface. Neither may be left unassigned.
- **`EligibilityAndResurfaceService.TaskList` is late-bound and null-tolerant** (it breaks a
  constructor cycle; a test pins "must not throw when unwired"). Opus added a one-shot
  `Debug.WriteLine` so an unwired graph is diagnosable. **C5 must additionally write a wiring test**
  that builds the real `CompositionRoot` service provider and asserts `TaskList` is non-null — an
  unwired graph means every `.afterDate` resurface silently never fires, which is precisely the FIX 2
  failure mode.
- **`AddAsync` reloads from the repository** where Swift hand-inserts, because
  `TaskRepository.AddAsync` can drop an invalid `taskDone` condition before persisting. Accepted:
  the stricter behaviour is correct, and the "never hand-patch the list" discipline is uniform.
- **Toast `Schedule()` does not survive app exit** (no OS future-delivery primitive in
  `AppNotificationManager`; C1 uses in-process chunked delays). Accepted, because
  `ReminderScheduler.RebuildFromStorage` + the now-durable `IReminderRecordStore` is the designed
  recovery path — **but C5 must call `RebuildFromStorage` at launch AND on session unlock/resume**,
  or a reminder due while the app was closed is simply lost. macOS gets this from its wake observer
  (inventory §5.2); Windows needs `SystemEvents.SessionSwitch`/`PowerModeChanged`.
- **`volar://` activation needs more than the registry.** C1's `UriSchemeRegistrar` writes the HKCU
  pointer; receiving the activation in the already-running unpackaged process additionally requires
  `Microsoft.Windows.AppLifecycle.AppInstance` single-instance redirection. C5 owns that.

## Opus review notes from stage 2 (binding on C5)

- **The C3/C4 delegation seam does NOT line up — C5 must write the adapter.** C3 declares
  `IDelegationHandoff.DelegateAsync(Guid taskId, string? label, int checkBackMinutes,
  CancellationToken)` inside `CaptureFlowService.cs`; C4 exposes
  `DelegationOrchestratorService.DelegateTaskAsync(Guid taskId, string? label = null,
  int checkBackMinutes = 10)`. Neither agent could edit the other's file, so both did the right
  thing and stopped at the boundary. C5 registers a two-line adapter implementing
  `IDelegationHandoff` over `DelegationOrchestratorService` and injects it into `CaptureFlowService`.
  **Until that adapter exists, a voice "giao cho Claude rồi" silently drops the hand-off** (C3 logs a
  warning and continues, deliberately, rather than throwing) — so C5 owes a test that the wired graph
  actually delegates.
- **Two real C# traps C3 found and fixed — do not reintroduce them elsewhere:**
  1. `T? Foo<T>(...)` on an *unconstrained* type parameter is a nullable-reference **annotation
     only**. Instantiated with a value type (`T = DateTimeOffset`), `return default;` yields
     `DateTimeOffset.MinValue`, not null — a dismissed deadline/estimate chip would have persisted
     garbage instead of omitting the field. Fixed with `bool IsResolved<T>(..., out ...)` plus
     concretely-typed wrappers. Any future generic "maybe value" helper in this codebase must not
     repeat the pattern.
  2. Swift's `onFinal` is a single-slot closure property; C#'s `ISpeechEngine.OnFinal` is an
     `event` (`+=` accumulates). Every capture start must unsubscribe the previous handler pair
     before subscribing — otherwise transcript N arrives N times.
- **C4 deferred `reminderBanner`/`showReminderPreview`/`dismissBanner` and the `showBreakdown` flag
  to Wave 4** (raising a `BreakdownRequested` event instead), following the precedent set for the
  detail-sheet trio. Accepted — but that makes **three** groups of UI-selection state Wave 4 must
  own; the Wave 4 contract has to name an owner for each or they fall through the cracks.
- **Apple-only members correctly dropped** by C3 (`allowServerRecognition`, `recognitionLocaleID`,
  `pendingServerConsent`, `useServerRecognition`, `setRecognitionLocale`, `openDictationSettings`):
  both Windows engines auto-detect language and there is no OS dictation toggle to send a user to.
  Wave 4's Settings view must therefore NOT render those rows — it is not a missing binding.
- **Gate-method call contract from C4** (the shell owns the cadence, not the services):
  `MaybeShowMorningFrog(now)` once/day, `MaybeShowTriage(now)` once/ISO-week,
  `MaybeShowEveningSweep(now)` **only when the local hour >= 18** (the method itself does not check
  the hour — that gate lived at Swift's call site), all three additionally requiring `hasOnboarded`,
  which no service owns. `RefreshDelegationQueue()` on a 60s cadence.
  `OfferRescheduleForOverdueTasks(now)` once at launch.

## Stage 3 (after stage 2): C5 — wiring and the shell

Owns `CompositionRoot.cs`, `App.xaml.cs`, `MainWindow.xaml(.cs)`, `Services/HotkeyService.cs`,
`Services/TrayIconService.cs`, and the deletion of `Stubs/*.cs`. Registers all 9 services and all
C1 adapters, passes `IReminderRecordStore` into the `ReminderScheduler` factory (Wave 3-B left it
on the in-memory default), injects the one settings-then-env reader into both Groq types, calls
`UriSchemeRegistrar` at startup, routes `volar://` activation into `AppLinkHandler`, wires the
hotkey to `CaptureFlowService.ToggleCaptureAsync()`, and calls the gate methods (never the flags).
Then Wave 4 attaches views.
