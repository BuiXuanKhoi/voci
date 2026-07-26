# Wave 4+5 Contract — Views port (macOS SwiftUI → WinUI 3)

**Status: ACTIVE — this supersedes `wave4-slice.md` entirely** (that doc's layout specs, palette
crib, and agent split are stale; it already carries a ⛔ banner). Source of truth for WHAT to
build: the CURRENT Swift files under `Volar/Sources/Views/` + `Volar/Sources/Design/` in THIS
worktree (post-merge `9df8910`, includes the `eb627de` hex-literal fix). Per-view analysis,
theme-token maps, gotchas: `specs/003-windows-port/views-inventory.md` (read your view's §1.x
section IN FULL before writing code). Anh Khôi's locked direction (2026-07-25): **full parity
with the Swift source as it exists today** — the NOW-spotlight TodayView, the full-fidelity
PopoverView. Wave 5 (design-system runtime wiring + motion) is folded into Stage A + Stage C of
this contract; there is no separate Wave 5 doc.

## Frozen decisions (Opus, 2026-07-26 — do NOT relitigate inside an agent)

1. **Icons**: `FontFamily="Segoe Fluent Icons,Segoe MDL2 Assets"` (composite fallback — dev/test
   machine is Win10 19045 which has ONLY MDL2). Every codepoint used MUST exist in Segoe MDL2
   Assets (verify against Microsoft's published MDL2 glyph list; the Fluent-only `sparkle` case
   needs a documented MDL2 substitute). One shared `VolarIcon` control; no per-view glyph
   literals.
2. **No new NuGet packages.** No Win2D, no CommunityToolkit. Waveform = Composition/keyframe
   animations on 32 `Rectangle`s. FlowLayout = hand-rolled `Panel` (`MeasureOverride`/
   `ArrangeOverride`). Spinner may use stock `ProgressRing` only if restyled to match; otherwise
   hand-rolled rotate Storyboard.
3. **AmbientBackground v1 = static per-mode gradient backdrop + custom-image layer.** No
   particle systems (deferred to backlog — full-fidelity particles need a rendering-strategy
   revisit). Delete-don't-port the `SecureImageBookmark`/`ClaudeDirBookmark` sandbox machinery:
   store plain file paths, use `FileOpenPicker`/`FolderPicker` (inventory §1.14/§1.15).
4. **MenuBarLabel analog = tray icon state swap (idle/listening/focus-lock icons) + dynamic
   tooltip** (`Shell_NotifyIcon` szTip: task title + countdown, ≤127 chars). No rich tray
   flyout in this wave (backlog). Constraint carried over from Swift: NOTHING tray-related may
   animate continuously.
5. **All sheets/modals = overlay Grid layers inside MainWindow** (matching the Popover's
   hosting), never `ContentDialog`. Scrim + centered card, per-overlay visibility bound to VM.
6. **FocusOverlay ports the `focusIndex` direct-mutation wart as commands**
   (`GoToPreviousCommand`/`GoToNextCommand` → `FocusSessionService.StepFocusIndex(±1)`).
   Behavior identical; idiom fixed. Documented deviation, not silent.
7. **PopoverView: dictation-consent sub-flow is N/A on Windows — do not build it.** The whole
   `pendingServerConsent`/`openDictationSettings`/`useServerRecognition` surface was
   deliberately dropped in Wave 3-C (no OS streaming STT on Windows; batch-only decision
   2026-07-25). Cloud-parse consent row IS in scope (`DefaultCloudParseGate`). Everything else
   in PopoverView is in scope: multi-draft array, per-attribute chips with uncertain-state,
   condition rows + dependency-picker MenuFlyout, conflict advisory (`Volar.Core.ConflictCheck`
   is ported), voice-done card, error card.
8. **Onboarding step 2 ("Allow microphone")**: informational panel + button opening
   `ms-settings:privacy-microphone` via `Launcher.LaunchUriAsync` + "Continue". No permission
   API call (unpackaged desktop apps get mic access unless the global privacy toggle blocks it;
   first real capture is the actual test).
9. **Accent runtime switching**: the four `AccentSolidBrush/HoverBrush/SurfaceBrush/GlowBrush`
   entries in `Application.Resources` stay SINGLE `SolidColorBrush` instances; `ThemeState`
   mutates their `.Color` in place on `SetAccent` (DP change propagates to every consumer
   instantly). Views keep using `{StaticResource AccentSolidBrush}`.
10. **Density runtime switching**: densities can't propagate through x:Double resources —
    density-dependent paddings/gaps are `x:Bind` to `ThemeState` (INPC: `RowPadY`, `RowGap`,
    `SectionGap` as double/Thickness). Fixed (non-density) metrics stay literals per the
    CornerRadius/Thickness gotcha below.
11. **Glass level is static** (Swift has no `setGlass` — Wave 3-C decision 3). `GlassLevel`
    read-only from `AppearanceAndPersistenceService.Glass`.
12. **ViewModel pattern** (the observability bridge over the deliberately-sync Wave 3-C
    services): one VM class per surface in `ViewModels/`, implementing `INotifyPropertyChanged`.
    Commands call the service, then `Refresh()` re-reads service state and raises the changed
    properties. Subscribe to the three service events (`TaskListService.TasksChanged`,
    `CaptureFlowService.CaptureChanged`, `TriageAndSweepService.BreakdownRequested`) and to any
    timer-driven state via a `DispatcherQueueTimer` owned by the VM's host; ALWAYS marshal
    event callbacks through `DispatcherQueue.TryEnqueue` before touching VM state. VMs must be
    constructible in a plain unit-test host: no XAML control types inside VMs (enums, strings,
    `Windows.UI.Color` structs, and collections only — brushes live in XAML/converters).
13. **No `.csproj` edits by any Stage A/B agent** (XAML pages auto-glob). Only Stage C may
    touch `Volar.App.csproj`, `MainWindow.xaml(.cs)`, `App.xaml(.cs)`, `CompositionRoot.cs`,
    `TrayIconService.cs` — EXCEPT `TrayIconService.cs` which is owned by B5.
14. **Priority colors**: port the CURRENT (post-`eb627de`) `Components.swift` — `PriorityBadge`
    uses `VolarColor.high/.med` tokens throughout. Do not resurrect the pre-retheme literals.

## Hard gotchas (every agent re-reads before writing XAML)

- **`CornerRadius`/`Thickness` cannot consume `x:Double` StaticResources** — hand-copy literal
  numbers (12 glass / 9 hairline / 6 small / one-offs 11·14·15·16·18·22 as per view). Cite the
  Metrics.xaml name in a comment when you inline one.
- Glyph typos are silent (wrong icon, no error) — only use codepoints verified in the MDL2 list.
- `Volar.Core.TaskStatus` vs `System.Threading.Tasks.TaskStatus` ambiguity in sibling projects —
  alias it (`using TaskStatus = Volar.Core.TaskStatus;`) on first collision.
- Service events may fire off the UI thread — never touch a DependencyObject without
  `DispatcherQueue.TryEnqueue`.
- Build must stay green after EVERY agent: `dotnet build windows/Volar.Windows.sln -c Release`
  then `dotnet test` — 0 warn / 0 err / all tests green is the bar (TreatWarningsAsErrors on).
- Repeat-forever animations allowed ONLY in full-window surfaces (MorningFrog pulse, Spinner,
  Popover PulsingDot/MicBreathingGlow/BlinkingCaret §1.17 — caret uses DISCRETE keyframes, hard
  cut). Gate loops on `UISettings.AnimationsEnabled` where the Swift checks reduce-motion.

## Stage/slice ownership (file-disjoint; nobody touches another agent's files)

**Stage A (sequential, blocks everything):** `Views/Controls/` — VolarIcon (+verified MDL2
glyph map), KeyBadge, PriorityBadge, TimeBadge, Spinner, ToolButton, SectionHeader, GlassPanel,
FlowPanel, spotlight-vignette brush (Glass.xaml addition), `Theme/ThemeState.cs` (accent
in-place brush mutation + density INPC + persistence via `AppearanceAndPersistenceService`),
`ViewModels/UiDispatch` helper. + unit tests for ThemeState/glyph map.

**Stage B (5 parallel agents, each depends only on Stage A):**
- **B1 Today**: `Views/TodayView.xaml(+.cs)`, `Views/Controls/TaskRowControl.*`,
  `Views/Controls/SidebarControl.*`, `ViewModels/TodayViewModel.cs`, `ViewModels/TaskRowViewModel.cs`.
  Scope: toolbar, greeting, NOW spotlight hero (+context menu, 3 actions), NEXT peek, 2
  collapsed drawers, empty state, running-focus pill, DelegationAmbientSection (service exists:
  `DelegationOrchestratorService`), hotkey footer. Does NOT mount Popover/Focus/Notification/
  Ambient overlays (Stage C).
- **B2 Popover + Waveform**: `Views/CapturePopover.xaml(+.cs)`, `Views/Controls/Waveform.*`,
  `ViewModels/CapturePopoverViewModel.cs`. Full fidelity per frozen decision 7.
- **B3 Modals**: `Views/TaskDetailView.*`, `Views/TaskBreakdownView.*`, `Views/TriageView.*`,
  `Views/SweepView.*`, `Views/MorningFrogView.*` + their VMs. Triage/Sweep are deliberate
  siblings — keep the symmetry AND the 3 flagged asymmetries (§1.9/1.10). TaskBreakdown's
  "Save all" stays disabled (FIX G). Triage's 4 actions stay visually identical (anti-shame,
  FR-036).
- **B4 Settings + Onboarding**: `Views/SettingsView.*` (all 6 tabs — Integrations infra EXISTS:
  `EditorConnector`/`AppLinkHandler`/`volar://` all wired in Wave 3-C), `Views/OnboardingView.*`,
  their VMs, Settings-local controls (`Segmented`, `VolarToggle` restyled `ToggleSwitch`,
  `KeyRecorder`). Locale picker: omit (no OS ASR on Windows — engine picker only).
- **B5 Focus + Notification + Ambient + Tray**: `Views/FocusOverlay.*`, `Views/Controls/
  NotificationBanner.*`, `Views/Controls/AmbientBackground.*` (static-gradient v1),
  `ViewModels/FocusViewModel.cs`, and `Services/TrayIconService.cs` (state icons + tooltip; B5
  is the ONLY agent allowed in that existing file).

**Stage C (sequential, after all B):** MainWindow becomes the real shell — hosts TodayView +
overlay stack (popover scrim, focus overlay, 5 modal overlays, notification banner, ambient
layer behind), wires VMs↔services↔DispatcherQueue, adds `CaptureFlowService` public transcript
entry (`HandleExternalCaptureAsync`) and wires `AppLinkHandler.OnCapture` (the flagged Wave 3-C
leftover), focus 1s tick timer, full build + test + smoke-run `dotnet run`, fix everything.

## Per-agent self-review (anh Khôi's standing 6 points — run before reporting done)

1. Đúng nguồn: đối chiếu từng section với file Swift hiện tại (không phải doc cũ).
2. Build xanh 0 warn/0 err + test xanh toàn sln.
3. Binding/thread-safety: mọi event → DispatcherQueue; không XAML type trong VM.
4. Token đúng: không hex literal ngoài danh sách bespoke đã ghi trong inventory.
5. Gotcha list ở trên: từng mục một, xác nhận đã tuân thủ.
6. Ghi lại residual/deviation vào report cuối (để Opus review + backlog).
