# Wave 4 — Vertical Slice: Today + Quick-Capture Popover (REAL data)

> ## ⛔ SUPERSEDED IN PART — read this before using any of it (Opus, 2026-07-25)
>
> Three things in this document are now stale. `specs/003-windows-port/views-inventory.md` wins on
> all three, and `specs/003-windows-port/wave3c-services.md` wins on the fourth:
>
> 1. **The design layout spec below (§"Design layout spec", lines ~100-126) is stale.** It describes
>    a flat "Now / Later today / Completed" row-list ported from `design/volar-mac.jsx`. The actual
>    `Volar/Sources/Views/TodayView.swift` was restructured by the Studio Dark retheme into a
>    different visual grammar: ONE spotlit "NOW" hero card, ONE dimmed "NEXT" peek row, and
>    Later/Completed collapsed into default-collapsed disclosure drawers. `PopoverView.swift`
>    likewise grew multi-draft confirm cards, attribute chips, conflict advisories and the
>    voice-done branch. **DECISION: Wave 4 ports the CURRENT SWIFT, not this document's layout** —
>    the whole point of this effort is parity with the macOS app as it exists (anh Khôi, 2026-07-25:
>    "2 bản phải đồng nhất"). Where this doc and the Swift disagree, the Swift is the spec.
> 2. **The theme crib (§"Theme resources") quotes the pre-retheme palette** (e.g. `#1C1C1E`). The
>    XAML already in `windows/src/Volar.App/Theme/*.xaml` matches the current Swift. Use the XAML
>    keys and `Volar/Sources/Design/Theme.swift`, never this doc's hex values.
> 3. **The 3-agent task breakdown (§"Task breakdown") is superseded** by the 14-slice, file-disjoint
>    proposal in `views-inventory.md` §3, which covers all 18 views rather than just two.
> 4. **"bind/persist TaskEntity" is superseded**: services and views speak `Volar.Domain.TaskItem`
>    (`wave3c-services.md` decision 6). `TaskEntity` stays inside `Volar.Data`.
>
> Still valid and worth reading: the "Scope boundary", the "HARD GOTCHAS (violating these = native
> crash)" list, and the 6-point self-review checklist.

Author: Opus (brain). Executors: Sonnet (hands). Branch: `window`, worktree `C:\projects\voci-windows`.
Goal decided with anh Khôi 2026-07-21: build the **Today** screen + **quick-capture Popover**
matching `design/volar-mac.jsx` + `design/volar-popover.jsx`, wired to **real data** (SQLite via
`TaskRepository`, real `HeuristicIntentParser`), replacing the placeholder in `MainWindow.xaml`.

## Scope boundary (READ FIRST)
- IN: Today view (title bar, sidebar, greeting, Now/Later/Completed sections, task rows, empty
  state), Popover overlay (5 states), real load/group/sort/toggle/create against SQLite, engine-driven
  "NOW", hotkey/tray → open capture.
- OUT (do NOT build now): Focus overlay, ambient backgrounds, Settings, Onboarding, voice-done card,
  delegation UI, reminders/toast, real microphone transcription.
- **Speech is stubbed** (`StubSpeechEngine`, no transcription). So the Popover's transcript source for
  this slice is a **TextBox the user types into** (labelled naturally, e.g. placeholder "Type or speak
  a task…"). Recording/waveform state is visual only; the real pipeline runs on the typed text:
  typed text → `IIntentParser.ParseAsync` (real heuristic) → confirm card → save → Today refresh.
  This is a genuine end-to-end real-data loop minus the mic. Keep the visual states so voice can drop
  in later.

## Architecture decisions (fixed — do not re-litigate)
1. **MVVM primitives**: add NuGet `CommunityToolkit.Mvvm` (latest 8.x) to `Volar.App.csproj`. Use
   `ObservableObject`, `[ObservableProperty]`, `[RelayCommand]`, and `ObservableCollection<T>`.
2. **Binding**: use compiled `x:Bind` (with `Mode=OneWay`/`TwoWay` as needed) against a typed VM set
   as the page/root `DataContext`. Rows bind to a `TaskRowViewModel` wrapper (below) — do NOT try to
   build the full `TaskEntity`↔`TaskItem` adapter (it doesn't exist and isn't needed here).
3. **Engine ordering**: sort/select via the real ported engine `Volar.Core.NextTaskSelector` /
   `TaskOrderComparer` over `TaskEntity.ToSnapshot()`. The "NOW" (active) task = engine winner.
4. **Popover host**: overlay Grid INSIDE `MainWindow` (like the Mac app — no separate window),
   visible when `CaptureViewModel.CaptureState != Idle`, over a dim scrim. Esc / scrim tap = cancel.
5. **Entry points**: `HotkeyService.OnToggle`, tray "New task", and the title-bar `+` button all call
   `CaptureViewModel.ToggleCapture()`. Wire these in `App`/`MainWindow`.

## Data & parsing contracts (verified from source)
### TaskEntity (`Volar.Data.Entities.TaskEntity`) — the row you bind/persist
Fields you use: `Id (Guid)`, `Title (string)`, `PriorityRaw (int 1..4)`, `StatusRaw (string
"todo"/"inProgress"/"done"/"archived")`, `Deadline (DateTimeOffset?)`, `CreatedAt (DateTimeOffset)`,
`WhenRaw (string "now"/"later")`, `DurationMinutes (int?)`, `Frog (bool)`, `ParentId (Guid?)`.
Typed accessors (NOT EF-mapped): `TaskState Status {get;set;}` (fail-closed over StatusRaw),
`TaskSnapshot ToSnapshot()`.
`TaskState` enum (`Volar.Core`): `Todo, InProgress, Done, Archived`. "Done" == `Status==Done` (no bool).

### TaskRepository (singleton, already DI-registered) — real persistence
- `Task<IReadOnlyList<TaskEntity>> GetAllAsync(ct)` — everything, ordered by CreatedAt, incl Conditions.
- `Task<TaskEntity?> GetActiveAsync(DateTimeOffset now, TimeZoneInfo tz, ct)` — engine winner (single).
- `Task AddAsync(TaskEntity task, ct)` — create; assigns Id if empty.
- `Task ToggleAsync(Guid id, DateTimeOffset? now, TimeZoneInfo? tz, bool anchorRecurrence=false, ct)`
  — complete/uncomplete (records CompletionEvent; auto-advances via recompute). ⚠ tasks WITH
  RecurrenceJson throw (no IRecurrenceResetter injected) — this slice only creates non-recurring tasks,
  so fine; still guard ToggleAsync in try/catch and surface a calm message on failure.
- DbContextFactory + EnsureCreated already wired in `CompositionRoot`. VMs take `TaskRepository` via ctor.

### Engine (`Volar.Core.NextTaskSelector`, pure, synchronous)
- `TaskSnapshot? NextTask(IReadOnlyList<TaskSnapshot> snap, DateTimeOffset now, TimeZoneInfo tz)`.
- `sealed class TaskOrderComparer(DateTimeOffset now, TimeZoneInfo tz) : IComparer<TaskSnapshot>` —
  use to sort a list. Feed it `entities.Select(e => e.ToSnapshot())` and map back by Id.
- Inject clock/timezone: use `DateTimeOffset.Now` + `TimeZoneInfo.Local` at the VM boundary (app layer
  is allowed to read the clock; domain/core is not).

### ParsedTask (`Volar.Domain.ParsedTask`) — confirm card + save source
Fields you render/save: `Title (string)`, `Priority (ParsedValue<int>? 1..4)`, `Deadline
(ParsedValue<DateTimeOffset>?)`, `EstimateMinutes (ParsedValue<int>?)`, `SourceTranscript`, `Notes`.
`ParsedValue<T>` = value + confidence; render the value, ignore confidence for this slice.
Parser: `IIntentParser.ParseAsync(string transcript, DateTimeOffset now, IReadOnlyList<string>
openTaskTitles, ct)` → `IReadOnlyList<ParsedTask>` (never throws for content; empty ⇒ show error state).
Get `IIntentParser` from DI (registered). Pass open task titles from TodayViewModel's current open list.

### Save mapping ParsedTask → TaskEntity
`new TaskEntity { Title = p.Title, PriorityRaw = p.Priority?.Value ?? 3, StatusRaw = "todo",
Deadline = p.Deadline?.Value, DurationMinutes = p.EstimateMinutes?.Value, WhenRaw = "now",
CreatedAt = DateTimeOffset.Now, SourceTranscript = p.SourceTranscript, Frog = false }` then
`await repo.AddAsync(entity)`. After save, tell TodayViewModel to `RefreshAsync()`.

## Theme resources (use these keys; do NOT invent colors)
Brushes: `VolarBgBrush VolarSurfaceBrush VolarSurfaceHiBrush VolarCardBrush VolarCardHoverBrush
VolarBorderBrush VolarBorderHiBrush VolarTextPriBrush VolarTextSecBrush VolarTextMutBrush
VolarHighBrush VolarMedBrush VolarLowBrush VolarDestructBrush VolarDoneBrush` +
NOW: `VolarNowAccent*Brush NowSpotlightBrush NowRingBrush` + accent aliases
`AccentSolidBrush AccentHoverBrush AccentSurfaceBrush AccentGlowBrush` (indigo default) and raw color
keys `VolarIndigoSolid/Hover/Surface/Glow`, `VolarTealSolid`… etc.
Text styles: `VolarTitleTextStyle VolarHeadlineTextStyle VolarBodyTextStyle VolarCaptionTextStyle
VolarInstrumentMonoTextStyle`. Fonts: `VolarUiFontFamily`, `VolarMonoFontFamily`.
Metrics (x:Double): `VolarRowPadY(10) VolarRowGap(4) VolarSectionGap(22)
VolarCornerRadiusGlass(12) VolarCornerRadiusSmall(6) VolarHairlineThickness(0.5)`.
Glass acrylic panels: `VolarGlassStandardBrush` (popover card / sidebar / title bar).
Design token → theme key crib (from design/tokens.jsx): bg `#1C1C1E`=VolarBg, surface `#2C2C2E`=VolarSurface,
card=VolarCard, textPri/Sec/Mut, high `#FF6B6B`=VolarHigh, med `#FFB347`=VolarMed, done `#5BD17A`=VolarDone,
accent indigo `#6B6BFF`=AccentSolid. Match the layout/spacing numbers quoted in the design spec below.

## HARD GOTCHAS (violating these = native crash)
- **CornerRadius must be a literal number** in XAML (`CornerRadius="12"`), NEVER
  `{StaticResource VolarCornerRadiusGlass}` — a StaticResource x:Double → CornerRadius conversion
  crashes the native XAML parser at load (0xC000027B), uncatchable. Same for `Thickness`. Mirror the
  Metrics doubles by hand: 12 (glass), 9 (hairline), 6 (small).
- New XAML pages/ResourceDictionaries become new `.xbf` files. The existing
  `CopyProjectPriToPublishDir` target in `Volar.App.csproj` already copies `**/*.xbf` + `Volar.pri`
  recursively — do NOT remove/narrow it. If you add a `Views/` folder, its `.xbf` are covered.
- Hairlines are `0.5px` in design → use `BorderThickness="1"` with a thin brush (WinUI logical px).

## Design layout spec (authoritative — full detail in design/volar-mac.jsx & volar-popover.jsx)
### Today (frame ~920×580, root radius 12)
Title bar h=38 (VolarSurface, bottom hairline): traffic-light dots left (informational, static;
window uses real WinUI titlebar — you may render a simple custom top row or reuse AppWindow titlebar,
keep it minimal), centered "Volar", right tool buttons (28×28 r=7): volume, waveform, search, `+`(accent).
Body = horizontal: **Sidebar w=160** (VolarSurface, right hairline): "Hold to speak" button (accent
surface, mic + text) + KeyBadges ⌃ ⌥ Space; "Focus" section label; nav items Today/Upcoming/Inbox
(icon + label + count pill), active=accent surface; spacer; on-device privacy card. **Main column**:
greeting header (pad 20/28/8): "Today" (26/SemiBold) + subtitle "Wed, May 21 · {open} open · {done}
done"; right Frog pill (red surface, dot + "Frog · {title}" + Focus button — Focus button may be
disabled/no-op this slice). Scrollable list: **Now** section (accent label + hairline rule + count),
rows; first Now row = active style (accent surface + inset ring); **Later today** (muted label);
**Completed** (muted, done rows strikethrough). Empty state = centered mic tile + "All clear." + hint.
TaskRow: checkbox (17×17 circle; checked=accent+check) | body (title 13 + meta: priority dot+label,
· duration, · Frog) | right slot (time badge pill; done→muted time text). r=9, pad rowPadY/12.

### Popover (card w=380, r=18, VolarGlassStandard, scrim rgba(0,0,0,.32))
Rows: hint row (status text left, "Esc cancel" right) → 42px glyph slot (waveform when recording/
parsing; green check circle when done; "Try again" when error) → transcript (the TextBox in this
slice; show typed text) → parsed card (r=12, VolarCard) with 4 ParseRows label|value:
"Task"=title, "When"=TimeBadge pill, "Priority"=PriorityBadge (dot+label, high/med/low colors),
"Context"=dot + "{context} · {duration}" → actions row (Cancel + "Save task ↵", Save shows spinner
while saving). States: idle/recording/parsing/parsed/saving/done/error. Visibility:
showWave=recording||parsing; showTranscript=≠idle&&≠error; showParsedCard=parsed||saving||done;
showActions=parsed||saving. Slice flow: user types → presses Enter/Parse → parsing → parsed (chips)
→ Save → saving → done (green check) → auto-close ~900ms → Today shows new task. Empty parse ⇒ error.

## Task breakdown (3 Sonnet agents; W-A first, then W-B ∥ W-C)
### W-A — ViewModels + data wiring  (files: windows/src/Volar.App/ViewModels/*, edits to
CompositionRoot.cs, Volar.App.csproj)
- Add CommunityToolkit.Mvvm package ref.
- `TaskRowViewModel(TaskEntity e, Func<Guid,Task> onToggle)`: exposes `Title`, `Done`, `PriorityLabel`
  ("High"/"Medium"/"Low"), `PriorityBrushKey` (or expose an enum the view maps), `TimeBadge` (deadline
  → "h:mm tt" or null), `DurationLabel` ("45 min"/"1 hr"/null), `Frog`, `WhenRaw`; `[RelayCommand]
  ToggleAsync` calling onToggle(e.Id). Keep it a thin display wrapper.
- `TodayViewModel(TaskRepository repo)`: `ObservableCollection<TaskRowViewModel> NowTasks, LaterTasks,
  CompletedTasks`; props `ActiveTaskId (Guid?)`, `OpenCount`, `DoneCount`, `GreetingDate`,
  `FrogTitle`, `IsEmpty`, `CaptureViewModel Capture` (compose it). `RefreshAsync()`: GetAllAsync →
  split done/open → sort open with TaskOrderComparer(now,tz) over snapshots → Now = open WhenRaw=="now",
  Later = open WhenRaw=="later", Completed = done; ActiveTaskId = engine winner among open (first of
  sorted Now, or GetActiveAsync). Toggle funnels through `repo.ToggleAsync` then RefreshAsync (auto-
  advance). Expose `OpenTaskTitles` for the parser. Load on construction/first show.
- `CaptureViewModel(IIntentParser parser, TaskRepository repo, Func<Task> refreshToday)`: enum
  `CaptureState {Idle,Recording,Parsing,Parsed,Saving,Done,Error}`; props `State`, `TranscriptText`
  (TwoWay from the TextBox), `ParsedResult` (a small `ConfirmDraftViewModel` exposing
  Title/TimeBadge/PriorityLabel/PriorityKind/DurationLabel/Context), `StatusText`, `ErrorText`, plus
  computed visibility bools. Commands: `ToggleCapture` (Idle↔Recording), `Parse` (Recording→Parsing→
  Parsed via parser; empty→Error), `Save` (Parsed→Saving→map→AddAsync→Done→auto Idle + refreshToday),
  `Cancel` (→Idle, clear). Guard async tails with a monotonic `_captureSession` int (increment on
  start/cancel; ignore results whose captured session != current) — port the Swift captureSession
  staleness guard.
- Register `TodayViewModel` (singleton) + `CaptureViewModel` in CompositionRoot. Build the class
  library (`dotnet build windows/src/Volar.App/Volar.App.csproj` may need the app; at minimum
  `dotnet build windows/Volar.Windows.sln`) and fix compile errors.

### W-B — Today view XAML + reusable controls  (files: windows/src/Volar.App/Views/*,
MainWindow.xaml + .xaml.cs edits; depends on W-A types)
- Replace the placeholder StackPanel in `MainWindow.xaml` with the Today layout (title bar row +
  sidebar + main column + sections), bound via x:Bind to `TodayViewModel` (set DataContext in
  MainWindow ctor from `App.Services.GetRequiredService<TodayViewModel>()`; call RefreshAsync on show).
- Reusable UserControls under `Views/Controls/`: `TaskRowControl`, `SidebarItem`, `ToolButton`,
  `KeyBadge`, `SectionHeader`, `EmptyTodayView`. Use theme keys + literal CornerRadius. Match the
  spacing/sizes in the design spec above.
- Add the Popover overlay Grid host (visible bound to Capture.State != Idle) but the popover CONTENT
  control is W-C's — expose a named ContentControl/placeholder so W-C fills it (coordinate: W-B owns
  MainWindow overlay + scrim; W-C owns the `CapturePopoverControl`). To stay file-disjoint, W-B adds
  `<local:CapturePopoverControl .../>` referencing the type W-C creates — so W-C must land first OR
  W-B stubs the element and W-C replaces. Simplest: **W-C creates CapturePopoverControl; W-B references
  it.** Build after both.
- Wire `+` tool button, tray "New task", and HotkeyService.OnToggle → `TodayViewModel.Capture.ToggleCaptureCommand`.

### W-C — Popover view XAML  (files: windows/src/Volar.App/Views/Controls/CapturePopoverControl.xaml
+ .cs; depends on W-A CaptureViewModel)
- `CapturePopoverControl` (UserControl) bound to `CaptureViewModel`: card r=18 VolarGlassStandard,
  hint row, 42px glyph slot (simplify waveform to a settled bar row or a subtle pulse — full animation
  optional), the transcript TextBox (TwoWay to TranscriptText, Enter → ParseCommand), parsed card with
  4 ParseRows + TimeBadge + PriorityBadge, actions (Cancel + Save with spinner), error row. Visibility
  via x:Bind bools. Reusable badges (`TimeBadge`, `PriorityBadge`) may live here.
- Build the full solution and confirm it compiles.

## Self-review (each Sonnet agent must self-check these 6 before returning)
1. **Compiles** — ran `dotnet build windows/Volar.Windows.sln`, zero errors (report warnings).
2. **Real data, no stubs where real exists** — uses TaskRepository + IIntentParser (not StubOrchestrator/
   StubReminder); create/toggle actually hits SQLite; NOW uses NextTaskSelector.
3. **Design fidelity** — layout regions, sizes, radii, and theme keys match the design spec (no
   invented colors; correct token→key mapping).
4. **XAML safety** — every CornerRadius/Thickness is a literal number (no StaticResource struct crash);
   no removed .pri/.xbf target; app boots without 0xC000027B.
5. **Async/null safety** — captureSession staleness guard present; ToggleAsync/AddAsync wrapped so a
   repo exception surfaces a calm state, never crashes; no force-unwrap of ActiveTask when list empty.
6. **State machine correctness** — Popover honors all 7 states + visibility rules; empty parse → error;
   Today empty state renders when no open tasks; done rows strikethrough; toggle auto-advances NOW.
