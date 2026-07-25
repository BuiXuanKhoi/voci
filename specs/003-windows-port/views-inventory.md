# Views Inventory — Wave 4 slicing input (macOS SwiftUI -> WinUI 3)

Source: `Volar/Sources/Views/**` (18 files, 6537 lines) + `Volar/Sources/Design/**` (Theme.swift
319, Glass.swift 60, VolarIcon.swift 67), read in full from this worktree (`voci-windows`, branch
`window`) on 2026-07-25. Cross-checked against `specs/003-windows-port/appstate-inventory.md`
(AppState member -> view consumer table, written same day) and
`specs/003-windows-port/wave4-slice.md` (the only Wave-4 scope already locked: Today + Popover).

This document is the contract for slicing the REMAINING 16 views (Today + Popover already
speced in wave4-slice.md) into agent-sized, file-disjoint assignments.

**IMPORTANT theme-doc discrepancy found while reading**: `wave4-slice.md`'s "Theme resources" crib
(its lines 74-88) quotes `design/tokens.jsx`'s OLDER palette (bg `#1C1C1E`, high `#FF6B6B`, accent
indigo `#6B6BFF`). The actual, current `Volar/Sources/Design/Theme.swift` (read in full above) and
the actual, current `windows/src/Volar.App/Theme/*.xaml` (also read in full) both already implement
a NEWER "Studio Dark / One Lit Thing" retheme (bg `#0B0D11`, high `#B9705A`, accent indigo
`#5B8DEF`, plus a new warm-amber "NOW spotlight" family reserved for the single active task). The
two are in sync with EACH OTHER (Swift <-> XAML), just not with wave4-slice.md's crib, which
predates the retheme. **All per-view theme-token mappings below cite the current
Theme.swift/XAML names, not wave4-slice.md's stale crib.** Any Wave-4 agent should use this
document's token names, not wave4-slice.md lines 74-88.

---

## 0. Design layer (read first — every view depends on these)

### Theme.swift (319 lines) -> Windows equivalent

| Swift token | Windows XAML key | Status |
|---|---|---|
| `VolarColor.bg` #0B0D11 | `VolarBgBrush` (Colors.xaml:103) | done |
| `VolarColor.surface` #15181E | `VolarSurfaceBrush` | done |
| `VolarColor.surfaceHi` #1B1F26 | `VolarSurfaceHiBrush` | done |
| `VolarColor.card` white@0.04 | `VolarCardBrush` | done |
| `VolarColor.cardHover` white@0.07 | `VolarCardHoverBrush` | done |
| `VolarColor.border` white@0.07 | `VolarBorderBrush` | done |
| `VolarColor.borderHi` white@0.11 | `VolarBorderHiBrush` | done |
| `VolarColor.textPri/Sec/Mut` | `VolarTextPriBrush/SecBrush/MutBrush` | done |
| `VolarColor.high/med/low/destruct/done` | `VolarHighBrush/MedBrush/LowBrush/DestructBrush/DoneBrush` | done |
| `VolarColor.nowAccent*` (6 tokens) | `VolarNowAccent*Brush`, `VolarNowGlow*Brush`, `VolarNowRingBrush` (Colors.xaml + Glass.xaml `NowSpotlightBrush`/`NowRingBrush`) | done |
| `VolarColor.instrument/instrumentDim/reschedule` | `VolarInstrumentBrush/InstrumentDimBrush/RescheduleBrush` | done |
| `VolarAccent` enum (indigo/teal/amber/magenta, 4 roles each) | `Accents.xaml`: `VolarIndigoSolid/Hover/Surface/Glow`, `VolarTealSolid...`, `VolarAccentAmberSolid...`, `VolarMagentaSolid...`, + default aliases `AccentSolidBrush/AccentHoverBrush/AccentSurfaceBrush/AccentGlowBrush` | done — **NOTE: user-selectable accent-family SWITCHING (`AppState.setAccent`) has NO XAML-side implementation yet** — the 4 families exist as static resources but nothing repoints `AccentSolidBrush` etc. at runtime. This is an app-layer gap, see §Gaps. |
| `Density` enum (cozy/comfy/roomy: rowPadY/rowGap/sectionGap) | `Metrics.xaml`: `VolarRowPadYCozy/Comfy/Roomy` etc. + default aliases `VolarRowPadY/RowGap/SectionGap` | done — **same runtime-switch gap**: `AppState.setDensity` has no XAML consumer wiring yet. |
| `GlassLevel` enum (subtle/standard/heavy, blur+bgOpacity+material) | `Glass.xaml`: `VolarGlassSubtleBrush/StandardBrush/HeavyBrush` (AcrylicBrush) | done |
| corner radii (12 glass / 9 hairline / 6 small) + hairline 0.5 | `Metrics.xaml`: `VolarCornerRadiusGlass(12)/Hairline(9)/Small(6)`, `VolarHairlineThickness(0.5)` | done — **but per wave4-slice.md's HARD GOTCHA, these x:Double resources CANNOT be used as `{StaticResource ...}` for a `CornerRadius`/`Thickness` property — must hand-copy the literal number in every XAML file.** Every per-view slice below must repeat this warning. |
| `Font.volar`/`Font.volarMono`, `.volarTabularNumbers()` | `Typography.xaml`: `VolarUiFontFamily`, `VolarMonoFontFamily`, `VolarTitleTextStyle/HeadlineTextStyle/BodyTextStyle/CaptionTextStyle/InstrumentMonoTextStyle` (last has `Typography.NumeralAlignment=Tabular`) | done |
| `VolarMotion` enum (hover/press/list/state spring/easing curves) | **no XAML equivalent exists yet** | GAP — WinUI needs `Storyboard`/`ThemeTransition`/`ImplicitAnimation` equivalents (`ConnectedAnimation` for cross-view, `Vector3TransitionType`/`OpacityTransitionType` for lists, or a Composition `SpringVector3NaturalMotionAnimation`). No 1:1 spring-animation resource dictionary primitive in WinUI 3 the way SwiftUI's `Animation.spring` is a value type — each view will need per-control `Storyboard`s or explicit Composition API calls in code-behind. Flag per-view below whenever a view uses `VolarMotion.*`. |
| `SpotlightBackground`/`.volarSpotlight()` (RadialGradient pool + vignette overlay, only for the active/NOW task) | `Glass.xaml`: `NowSpotlightBrush` (3-stop `RadialGradientBrush`) + `NowRingBrush` | partial — the pool gradient exists as a static brush; the SECOND layer (`.overlay` vignette-into-shadow, a second RadialGradient centered off-axis at `UnitPoint(0.5,0.32)`) has NO XAML resource yet. A view that renders the NOW spotlight (TodayView, MenuBarLabel) needs to add that second overlay brush or inline it. |

### Glass.swift (60 lines) -> Windows

- `GlassBackground` (system Material + tint-opacity overlay + 0.5px hairline stroke, parametrized
  by `level`/`tint`/`cornerRadius`/`borderColor`) has no single reusable WinUI **control**
  equivalent yet — `VolarGlassStandardBrush` (AcrylicBrush) covers the material+tint half, but the
  hairline stroke overlay is NOT bundled; every consuming view must add its own
  `Border BorderBrush="{StaticResource VolarGlassBorderBrush}" BorderThickness="1"` (literal, per
  the CornerRadius/Thickness gotcha) around a `Border Background="{StaticResource
  VolarGlassStandardBrush}"`. **Recommend a shared `GlassPanel` UserControl** be added to the
  shared-control manifest (below) so 6+ views don't hand-roll this composition differently.
- `volarHairline(...)` (bare 0.5px stroke, no fill) — same gap; every task-row-like control needs
  a literal `BorderThickness="1"` + `VolarBorderBrush`/`VolarGlassBorderBrush`.

### VolarIcon.swift (67 lines) -> Windows

`VolarIconName` enum (30 cases) wraps SF Symbols via `Image(systemName:)`. WinUI 3 has no
SF-Symbols-equivalent single API — glyphs must come from **Segoe Fluent Icons** (a font, referenced
by `Glyph="&#xE...;"` on a `FontIcon`, or `Symbol="..."` on a `SymbolIcon` for the subset that maps
to the older Segoe MDL2 enum). See the full SF Symbols inventory table near the end of this
document for the name-by-name mapping — every one of the 30 `VolarIconName` cases plus every
inline `Image(systemName:)` literal found directly in view files (there are several not routed
through `VolarIcon`) is catalogued there in one place so a view agent never has to guess a glyph.

**Recommend a shared `VolarIcon` UserControl or a lookup dictionary** (`VolarIconName -> glyph
string`) mirroring the Swift enum 1:1, so C# call sites read `<controls:VolarIcon Name="Mic"/>`
instead of hand-typing Segoe glyph codepoints per view (glyph typos are silent — wrong glyph
renders as an unrelated icon, no compile error).

---

## 1. Per-view inventory

### 1.1 `NotificationView.swift` (85 lines)

1. **Surface**: in-app notification banner overlay (manually triggered via menu "Preview
   reminder" -> `AppState.showReminderPreview()`; production reminders via
   `UNUserNotificationCenter` are NOT this view — this is only the in-app-visible banner). Not in
   wave4-slice scope — **unassigned**.
2. **AppState**: `appState.accent` (read-only, for `accentColors`). Reads `AppState.reminderBanner`
   indirectly at the mount site (`VolarApp.swift` / future MainWindow overlay host), not inside
   this view itself — this view takes `title`/`timing`/`onDone`/`onSnooze`/`onReschedule` as plain
   params, only touches `AppState` for accent color.
3. **Sub-components**: defines a private `actionButton(_:solid:action:)` helper (not exported).
   Consumes `VolarIcon(.mic)`.
4. **Theme tokens**: `VolarColor.textPri/textSec`, custom inline `Color(volar: 0x282828)` tint
   (NOT a named token — a one-off passed to `.volarGlass(tint:)`, flag for the C# port: either add
   a named resource or hardcode this literal), `.volarGlass(level: .heavy, cornerRadius: 14)` ->
   `VolarGlassHeavyBrush` (exists) but cornerRadius 14 is NOT one of the 3 Metrics.xaml radii
   (12/9/6) — needs a literal `14` in XAML, no matching resource exists (not a gap worth adding a
   4th Metrics key for, just note it's a one-off literal same as the tint).
5. **Interaction**: no keyboard/drag/focus/context-menu; 3 plain buttons with hover-free static
   styling (no `.onHover` in this file). No animation.
6. **macOS-only APIs**: none beyond `.volarGlass` (already covered by Glass.xaml). Pure
   presentation.
7. **Complexity**: **S**. Hardest thing: the one-off `Color(volar: 0x282828)` tint + 14pt corner
   radius aren't in the shared Metrics/Colors resources — trivial to hardcode, just don't let the
   agent invent a resource key that doesn't exist elsewhere.

### 1.2 `Waveform.swift` (88 lines)

1. **Surface**: reusable rendering control (animated capture waveform bars), consumed by
   PopoverView (already in wave4-slice scope, simplified there per the slice doc: "simplify
   waveform to a settled bar row or a subtle pulse — full animation optional") and potentially
   Sidebar/MorningFrogView ("Hold to speak" affordance). **Covered by wave4-slice.md indirectly**
   (Popover needs SOME visual here) but the slice doc explicitly downgrades full animation to
   optional — so a faithful `Waveform` port is still **unassigned** as its own deliverable.
2. **AppState**: none — pure parameters (`active: Bool`, `color: Color`, `glow: Color`, `bars:
   Int = 32`, `height: CGFloat = 42`). Confirmed by appstate-inventory.md's intro: this file "has
   no `@Environment(AppState.self)`... pure rendering, parameters only."
3. **Sub-components**: none defined/consumed — self-contained leaf.
4. **Theme tokens**: none referenced directly inside the file (colors passed in by caller); the
   `#Preview` block uses inline `Color(volar: 0x6B6BFF)` (stale pre-retheme accent hex — dead
   preview code only, not load-bearing).
5. **Interaction**: continuous per-frame animation via `TimelineView(.animation)` + `Canvas`,
   driven by a layered-sine formula (exact formula quoted in the source, lines 52-61) — 32 bars,
   3px wide, 3px spacing, Gaussian envelope taper at edges, min height 2px, redrawn every frame
   while `active`; settles to a flat 3px line (no animation) when `active == false`. **WinUI has
   no direct `Canvas`+per-frame-procedural-draw equivalent as a lightweight SwiftUI-style API** —
   closest ports: (a) `Microsoft.UI.Xaml.Media.CompositionTarget.Rendering` event driving a
   `Win2D`/`CanvasControl` per-frame redraw (needs the Win2D NuGet, heavier dependency), or (b) a
   `Grid`/`ItemsRepeater` of 32 `Rectangle`s each animated via a Composition
   `ScalarKeyFrameAnimation` (no per-frame CPU math, GPU-driven, closer to "native" WinUI idiom but
   the sine formula would need re-expressing as keyframes/expression animations, not a literal
   port of the tick function). Recommend (b) for fidelity-without-a-new-dependency, but it's a
   genuinely different implementation strategy, not a mechanical port — this is the single hardest
   piece of visual porting work in the whole view layer.
6. **macOS-only API**: `TimelineView`, `Canvas`, `GraphicsContext`/`.addFilter(.shadow(...))` — no
   WinUI 1:1; see above.
7. **Complexity**: **M** (self-contained, no AppState coupling, but the animation strategy is a
   genuine redesign, not a transliteration). Hardest thing: replacing per-frame procedural Canvas
   drawing with a WinUI-idiomatic animated-bars mechanism that doesn't require pulling in Win2D
   just for this one control (unless the team decides Win2D is acceptable — worth flagging to the
   orchestrator as a design decision, not something a view agent should decide unilaterally).

### 1.3 `MenuBarLabel.swift` (158 lines)

1. **Surface**: menu-bar-extra label content (the actual `NSStatusItem`/`MenuBarExtra` label shown
   in the macOS menu bar — 3 states: idle/listening/focus-lock). Windows has no menu-bar; the
   direct analog is the **system tray icon tooltip/overlay** (`NotifyIcon` in WinUI/Win32 terms —
   memory confirms the Windows port already has a tray via Win32 P/Invoke, per Wave 3-A). **Not in
   wave4-slice.md scope** (that slice only wires tray "New task" -> capture toggle, not a live
   tray label/badge) — **unassigned**, and arguably app-shell work more than "a view", see Gaps.
2. **AppState**: `appState.focusActive`, `appState.captureState` (`== .recording`),
   `appState.accent` (`accentColors`), `appState.delegation?.wipCount()` (via `appState.tasks` as
   an Observation trigger — see the FIX F comment, lines 16-19, 38-48: `wipCount` is deliberately
   read through `appState.tasks` to get a live Observation dependency since `TaskStore` itself
   isn't `@Observable`), `appState.activeTask?.title`, `appState.focusSecondsLeft`.
3. **Sub-components**: defines `wipBadge(count:)`, `idleContent`, `listeningContent`,
   `focusLockContent`, `timerLabel` (all private, view-internal). Consumes `VolarIcon(.mic)`.
4. **Theme tokens**: `VolarColor.textSec` (idle), `appState.accent.accent.{glow,solid}`
   (listening), `VolarColor.nowAccent`/`VolarColor.nowGlow`/`VolarColor.textPri`/
   `VolarColor.textMut`/`VolarColor.instrument` (focus-lock — this is one of the few views that
   deliberately uses the reserved warm `nowAccent` family, since focus-lock IS the NOW task
   badge), `Font.volarMono` (REC label, WIP badge, countdown timer — all 3 map to
   `VolarInstrumentMonoTextStyle`/`VolarMonoFontFamily`).
5. **Interaction**: no hover/drag/keyboard (menu-bar labels don't take direct interaction beyond
   the OS-level click-to-open); no animation (explicit code comment: "No looping/breathing
   animation added — static only, per the historical AppKit layout-thrash removal"; also "NEVER
   use `.repeatForever` on a MenuBarExtra/NSStatusItem-hosted view" per Theme.swift's
   `VolarMotion` doc comment). This constraint should carry over: the tray icon/tooltip must not
   animate continuously either (battery/CPU + Windows tray norms agree).
6. **macOS-only API**: this ENTIRE view is a `MenuBarExtra` label, which doesn't exist on Windows.
   Windows equivalent: draw the 3 states into a small bitmap/icon set for `NotifyIcon`, or (more
   likely, given how much text this label renders — task title, REC, mono countdown, WIP badge)
   render into a lightweight always-on-top flyout/tooltip window rather than trying to cram this
   into a 16x16 tray icon. This is a genuine architecture question, not a mechanical port — flag
   to the orchestrator.
7. **Complexity**: **L**. Hardest thing: there is no WinUI "menu bar label" surface at all: the
   whole view needs to be re-hosted as either (a) a custom tray icon bitmap generator (loses all
   the rich text/layout), or (b) a small popup/flyout anchored to the tray icon (closer fidelity,
   but a new window/flyout to build, own show/hide lifecycle, and multi-monitor tray-position
   logic). Needs an explicit product decision before any agent should build it.

### 1.4 `TaskRow.swift` (172 lines)

1. **Surface**: reusable control — the single task row used throughout Today's Now/Later/
   Completed lists. **Explicitly in wave4-slice.md scope**: W-B's `TaskRowControl` +
   `TaskRowViewModel` (W-A) are this view's direct Windows counterpart, already assigned.
2. **AppState**: `appState.accent` (`accentColors`), `appState.density.rowPadY`,
   `appState.openDetail(task.id)` (row tap), `appState.toggleDone(task.id)` (checkbox tap AND
   context-menu "Mark done/not done"), `appState.showBreakdown = true` (context-menu "Break down
   into steps…" — **direct bool write, not a method call**, matches appstate-inventory.md's note
   that no `AppState.openBreakdown()` method exists), `appState.deleteTask(task.id)`
   (context-menu "Delete").
3. **Sub-components**: defines `checkbox`, `titleAndSubrow`, `trailing` (private). Consumes
   `VolarIcon(.check)` and **`TimeBadge`** (referenced at line 164 but NOT defined in this file —
   defined in `Components.swift`, see §1.13 below; this is a real cross-file dependency: TaskRow's
   Windows port cannot compile/render without `TimeBadge` existing first).
4. **Theme tokens**: `VolarColor.high/med/low` (priority dot), `VolarColor.textMut/textPri/
   textSec`, `accentColors.{solid,surface}`, `VolarColor.cardHover`/`VolarColor.card`,
   `VolarColor.border`, corner radius 9 (`VolarCornerRadiusHairline` — literal in XAML per the
   gotcha), hairline 0.5 (`VolarHairlineThickness` — literal).
5. **Interaction**: `.onHover` (hover background swap card->cardHover — WinUI: `PointerEntered`/
   `PointerExited` or a `VisualState` `PointerOver` trigger), `.onTapGesture` on the row (opens
   detail sheet) layered with a `.simultaneousGesture(DragGesture(minimumDistance:0))` purely to
   get press-down scale feedback (`isPressed` -> `scaleEffect(0.985)`) without competing with the
   checkbox's own nested `Button` tap — WinUI: use `Button` `Click` for checkbox (already isolates
   tap) + a `PointerPressed`/`PointerReleased` on the row `Grid` for the press-scale, or a
   `PointerDownThemeAnimation`. `.contextMenu` with 4 items (2 actions + divider + destructive) ->
   WinUI `MenuFlyout` with `MenuFlyoutItem`s + `MenuFlyoutSeparator`, destructive item can use
   `Foreground="{StaticResource VolarDestructBrush}"`. `.animation(VolarMotion.hover/press, ...)`
   on 3 separate value-triggers (isHovering, isActive, isPressed) — needs 3 small
   Storyboards/Composition animations or `AnimatedVisualPlayer`-less manual `DoubleAnimation`s on
   opacity/scale (see the `VolarMotion` gap noted in §0). Checkbox check-mark uses
   `.transition(.scale.combined(with:.opacity))` on appear — WinUI: `Popup`/`ContentTransitions` or
   a manual fade+scale on the `FontIcon`.
6. **macOS-only API**: `.contextMenu` (-> `MenuFlyout` via right-click/`ContextFlyout`),
   `.onHover` (-> `PointerEntered`/`Exited`), `GestureState`/`DragGesture` for press feedback (->
   `PointerPressed`/`PointerReleased` bool + `VisualStateManager` or manual scale transform), SF
   Symbol `checkmark` (-> Segoe Fluent `Accept`/`` or `CheckMark`/``, see SF Symbols
   table).
7. **Complexity**: **M** (already scoped in wave4-slice W-B, so most design decisions are
   pre-made). Hardest thing: reproducing the 3 independent `.animation(value:)` triggers
   (hover/active/press) as WinUI visual-state transitions without a 1:1 SwiftUI `Animation`
   primitive — wave4-slice.md's own self-review checklist doesn't mention animation fidelity at
   all, so this may intentionally ship simplified (static states, no spring) in the current W-B
   slice; confirm with the orchestrator whether animation parity is in-scope now or backlog.

### 1.5 `Sidebar.swift` (188 lines)

1. Surface: reusable panel — the Today window's left nav column (capture button, key badges,
   Focus section label, 3 nav items, on-device privacy footer). Explicitly in wave4-slice.md
   scope (Today's "Sidebar w=160" region) though the slice doc describes it by layout, not by
   naming this Swift file — orchestrator should confirm W-B's `Views/Controls/` folder includes a
   Sidebar-equivalent control (it already lists `SidebarItem` as a sub-control, consistent with
   this file's private `SidebarItem`).
2. AppState: `appState.accent`, `appState.openTasks.count` (Today nav-item count; Upcoming/Inbox
   counts are hardcoded 12/3, static placeholder data), `appState.toggleCapture()`,
   `appState.captureState` (`== .recording`, swaps button label), `appState.ambient` (`!= .none`
   gates whether the background uses `appState.glass.material` + surface overlay vs plain
   `VolarColor.surface`), `appState.glass.material` (confirms appstate-inventory.md row 4: `glass`
   has no setter but IS read here).
3. Sub-components: defines private `CaptureButtonStyle` (ButtonStyle) and private `SidebarItem`
   (icon+label+count nav row). Consumes `KeyBadge(_:accent:)` — defined in `Components.swift`
   (§1.13), a cross-file dependency like TaskRow's `TimeBadge`.
4. Theme tokens: `VolarColor.border/surface/textMut/textPri/textSec`, `accentColors.solid`,
   `Color.white.opacity(0.03/0.04)` (inline one-off tints, no named resource), width 160 (matches
   wave4-slice.md's "Sidebar w=160" spec exactly), corner radii 9/7 (literal in XAML).
5. Interaction: `.onHover` on `SidebarItem` (hover tint), `ButtonStyle`-driven press feedback on
   the capture button via `configuration.isPressed` — maps directly to a WinUI `Button`
   `VisualState` `Pressed` trigger, no custom gesture layering needed (simpler than TaskRow's
   `GestureState` approach). `.animation(VolarMotion.press/hover, ...)` — 2 more instances of the
   VolarMotion gap noted in §0.
6. macOS-only API: `.onHover`, `ButtonStyle` protocol (-> WinUI `Style`/`ControlTemplate`
   `VisualState`s), SF Symbols via `VolarIcon` (`.mic`, `.today`, `.upcoming`, `.inbox`).
7. Complexity: S-M. Hardest thing: the conditional background (`appState.ambient != .none` swaps
   in the glass material) is a cross-cutting concern this view reads but doesn't own — the C# VM
   needs an `IsAmbientActive`-style bool from whichever service owns `AmbientMode`, and the XAML
   needs a `VisualStateManager`/`x:Bind`-driven brush swap, not a static background.

### 1.6 `MorningFrogView.swift` (194 lines)

1. Surface: daily first-launch sheet/modal ("Good morning" pick-a-frog prompt), mounted from
   `VolarApp.swift`'s `.sheet(isPresented: appState.showMorningFrog)`. NOT in wave4-slice.md's IN
   list — unassigned.
2. AppState: `appState.accent`, `appState.openTasks` (candidate list — every open task is
   pickable, not a curated subset), `appState.toggleCapture()` (voice CTA). Two `@State` locals
   (`picked: UUID?`, `pulse: Bool`) are view-local, not AppState. Two injected closures `onPick:
   (UUID) -> Void` / `onSkip: () -> Void` are wired by `VolarApp.swift` to `appState.pickFrog(_:)`
   / `appState.dismissMorningFrog()` — this view never calls those two methods directly itself
   (hybrid pattern: reads AppState directly for data, receives its 2 primary actions as closures).
3. Sub-components: defines private `voiceCTA`, `divider`, `candidateList`, `candidateRow(_:)`.
   Consumes `KeyBadge("M", accent: true)` and `VolarIcon(.mic, .check)`.
4. Theme tokens: `VolarColor.bg/surface` (background gradient), `VolarColor.textPri/textMut/
   textSec/border/high`, `accentColors.{solid,surface,glow}`, `.volarGlass(level: .heavy,
   cornerRadius: 16)` — a 16pt modal radius not in the 12/9/6 Metrics set (recurs in
   TaskDetailView and TaskBreakdownView below too — worth the orchestrator deciding whether a 4th
   named Metrics key, e.g. `VolarCornerRadiusModal`, is warranted since 3 views want the same
   one-off value).
5. Interaction: `.onTapGesture` per candidate row (select), plain buttons. A genuine looping pulse
   animation on the voice CTA: `withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses:
   true))` driving a glow-shadow pulse (unlike MenuBarLabel's explicit AVOIDANCE of
   `.repeatForever` — fine here since this is a full-window modal, not menu-bar-hosted). WinUI: a
   looping `Storyboard` with `RepeatBehavior="Forever"` + `AutoReverse="True"` animating a
   `DropShadow`/glow opacity — well-supported, straightforward to build (unlike Waveform's
   per-frame-Canvas problem).
6. macOS-only API: none beyond the already-covered `.volarGlass`/`VolarIcon` patterns; the
   `.repeatForever` call has a direct Storyboard equivalent.
7. Complexity: M. Hardest thing: nothing structurally hard, but it's a full sheet/modal needing
   its own WinUI `ContentDialog`-or-overlay-Grid hosting decision — should follow the same overlay-
   Grid-inside-MainWindow pattern wave4-slice.md item 4 specifies for the Popover, for consistency
   (see slice proposal below).

### 1.7 `TaskDetailView.swift` (208 lines)

1. Surface: sheet/modal — full task detail (title, meta row, description, read-aloud,
   close/delete/mark-done actions). Mounted from `VolarApp.swift`'s
   `.sheet(isPresented: appState.detailTaskID != nil)`, opened by `TaskRow`'s tap gesture. NOT in
   wave4-slice.md's IN list — unassigned, though the most natural "next" slice since TaskRow (its
   trigger) is already being built.
2. AppState: `appState.accent`, `appState.detailTask` (derived — the live task, recomputed every
   render, no cache, per appstate-inventory.md row 73), `appState.speakDetails(of: task)`
   (read-aloud button), `appState.closeDetail()` (Close button AND the fallback path when
   `detailTask` is nil — this view has NO parameter-based fallback: if `detailTaskID` points at a
   missing/deleted task it renders `EmptyView()` rather than crashing; the C# VM must replicate
   this via a nullable `DetailTask` + `HasTask` bound bool, not assume the task always exists),
   `appState.deleteTask(task.id)` (Delete, then also calls `closeDetail()`),
   `appState.toggleDone(task.id)` (Mark done/not done).
3. Sub-components: defines private `header(_:)`, `metaRow(_:)`, `descriptionSection(_:)`,
   `readButton(_:)`, `actions(_:)`. Consumes `VolarIcon(.volume)`. Its priority color/label switch
   DUPLICATES TaskRow's identical logic (both files independently switch on `task.priority` with
   the same 3 cases/colors/labels) — flag for the C# port: this belongs once on
   `TaskRowViewModel`/a shared priority helper, not duplicated again in a `TaskDetailViewModel`.
4. Theme tokens: `VolarColor.high/med/low`, `VolarColor.textPri/textSec/textMut`, `VolarColor.
   card`, `accentColors.{solid,surface,glow}`, `.volarGlass(level: .heavy, cornerRadius: 16)` (4th
   occurrence of the 16pt one-off), `.volarHairline(cornerRadius: 12)` (description box), corner
   radii 8/9/12/16 all literal.
5. Interaction: a `ScrollView` wrapping the description `Text` (-> WinUI `ScrollViewer` wrapping a
   `TextBlock`, direct 1:1). No hover/drag/context-menu/keyboard/animation in this file.
6. macOS-only API: none beyond `.volarGlass`/`VolarIcon`/`Button(role: .destructive)` (-> style
   the Delete button's foreground/background manually with `VolarHighBrush`; no built-in
   "destructive role" on a plain WinUI `Button`, but the Swift code already styles it explicitly
   with `VolarColor.high` anyway, so no fidelity loss).
7. Complexity: S-M. Hardest thing: the `detailTask == nil -> EmptyView()` defensive pattern — a
   WinUI dialog/overlay can't as gracefully "render nothing" mid-transition; the VM needs an
   explicit visibility bool so the dialog closes programmatically the instant its backing task
   disappears (e.g. deleted elsewhere while the sheet is open), not just bind a null title into a
   blank-looking dialog.

### 1.8 `TaskBreakdownView.swift` (220 lines)

1. Surface: sheet/modal — AI task-breakdown preview (5 hardcoded sample steps + "Save all as
   tasks", currently `.disabled(true)` per the in-file "FIX G" comment: the breakdown generator
   isn't real yet, so persisting sample junk was deliberately disabled). Mounted from `TaskRow`'s
   context-menu "Break down into steps…" via `VolarApp.swift`'s
   `.sheet(isPresented: appState.showBreakdown)`. NOT in wave4-slice.md's IN list — unassigned.
2. AppState: `appState.accent` only. Two injected closures `onSave: ([String]) -> Void` (wired to
   `appState.saveBreakdown(_:)`, currently reachable only via the disabled button) and `onClose:
   () -> Void` (wired to `appState.showBreakdown = false`). All step content (`steps`,
   `totalLabel`) is hardcoded inside the view, not AppState-backed — a real AI-breakdown feature
   needs a new service that doesn't exist yet (see Gaps section).
3. Sub-components: defines private `Step` struct, `stepRow(_:)`, `header`, `stepsCard`,
   `summary`, `actions`. Consumes `VolarIcon(.sparkle)`.
4. Theme tokens: `VolarColor.textMut/textPri/textSec/card/border`, `accentColors.{solid,surface,
   glow}`, `Color.white.opacity(0.04/0.06)`, `.volarGlass(level: .heavy, cornerRadius: 16)` (5th
   occurrence of the 16pt modal radius), `.volarHairline(cornerRadius: 12/9)`, fixed frame
   480x540 (hardcoded modal size, unlike TaskDetailView's min-size).
5. Interaction: no hover/drag/keyboard; plain buttons; `Text` concatenation via `+` for the
   mixed-styled summary line (-> WinUI: one `TextBlock` with multiple `Run` inlines, each its own
   `Foreground`, direct equivalent). "Save all as tasks" is `.disabled(true)` (-> WinUI
   `Button.IsEnabled="False"` bound to a VM bool so it can flip once a real generator exists, per
   the in-file comment's stated intent).
6. macOS-only API: none beyond already-covered patterns.
7. Complexity: S. Hardest thing: nothing technically hard — the only subtlety is making sure the
   "disabled + explanatory caption" state ships identically disabled (an agent must NOT
   "helpfully" re-enable it just because wiring the save-callback looks easy — preserve the
   deliberate FIX G intent).

### 1.9 `TriageView.swift` (221 lines)

1. Surface: sheet/modal — weekly stale-task batch card (4 equally-weighted actions per row:
   Keep/Break down/Defer/Drop). Mounted from `VolarApp.swift`'s `.sheet(items:
   appState.staleTasks, ...)`. NOT in wave4-slice.md's IN list — unassigned.
2. AppState: **NONE — confirmed by appstate-inventory.md's intro**: this file has no
   `@Environment(AppState.self)` at all. Pure presentation: takes `items: [TaskItem]` + 4 action
   closures (`onKeep`/`onBreakdown`/`onDefer`/`onDrop`) as init params, wired by `VolarApp.swift`
   to `appState.triageKeep`/`triageBreakdown`/`triageDefer`/`triageDrop`. Also uses
   `@Environment(\.dismiss)` (SwiftUI's built-in sheet-dismiss, not AppState) and
   `@Environment(\.accessibilityReduceMotion)` (system accessibility setting -> WinUI:
   `UISettings.AnimationsEnabled` or `AccessibilitySettings`, should gate the hover animation the
   same way).
3. Sub-components: defines private `TriageRow`, `actionButton(_:action:)`. No cross-file
   component consumption (self-contained, per the file's own header comment: "touches no app
   state, no persistence, no other files").
4. Theme tokens: `VolarColor.textMut/textPri/textSec/cardHover/card/high/med/low`,
   `.volarGlass(level: .heavy, cornerRadius: 16)` (6th occurrence of the 16pt modal radius — now a
   clear pattern across every full-batch/detail modal in the app), `.volarHairline(cornerRadius:
   12/8)`, fixed width 520 (matches SweepView exactly — the two are explicitly sibling designs per
   both files' header comments).
5. Interaction: `ScrollView` + `LazyVStack` (perf note in comment: bounded per-frame work for
   large batches -> WinUI `ScrollViewer` + `ItemsRepeater`/virtualizing `ListView`, NOT a plain
   `StackPanel`, to preserve that same UI-virtualization property), per-row `.onHover` gated by
   `accessibilityReduceMotion` (skips the `withAnimation` wrapper when reduce-motion is on — WinUI
   should check the equivalent system setting the same way, not just always animate),
   `.accessibilityLabel` on every action button (`"\(label) — \(item.title)"` — WinUI:
   `AutomationProperties.Name` on each `Button`, same semantic).
6. macOS-only API: `@Environment(\.dismiss)` (-> WinUI: a `ContentDialog`'s own
   `Hide()`/`PrimaryButtonClick` or an overlay-Grid's own visibility toggle, depending on hosting
   choice), `@Environment(\.accessibilityReduceMotion)` (-> `UISettings.AnimationsEnabled`),
   `.help(title)` tooltip is FocusOverlay's, not this file's — N/A here.
7. Complexity: S-M. Hardest thing: nothing structurally — the interesting constraint is
   NON-technical: FR-036/constitution V mandate all 4 actions render IDENTICALLY (no red, no
   destructive styling on "Drop") — an agent must resist "improving" this by making Drop look like
   a delete action, since that's explicitly the anti-shame design intent this file's own header
   comment calls out twice.

### 1.10 `SweepView.swift` (222 lines)

1. Surface: sheet/modal — evening sweep batch card (2 actions per row: Complete/Skip). Mounted
   from `VolarApp.swift`'s `.sheet(items: appState.sweepItems, ...)`. Explicitly a sibling design
   of TriageView (shares card shell/header/list/footer/glass level/row hairline/hover per this
   file's own header comment). NOT in wave4-slice.md's IN list — unassigned; **should be
   slotted alongside TriageView in the same agent assignment given the deliberate code-shape
   mirroring** (see slice proposal).
2. AppState: **NONE** — same pure-presentation pattern as TriageView (confirmed by
   appstate-inventory.md intro). Takes `items: [TaskItem]` + `onComplete`/`onSkip`/`onDismiss`
   closures, wired by `VolarApp.swift` to `appState.sweepComplete`/`sweepSkip`/`dismissSweep`.
   Also uses `@Environment(\.accessibilityReduceMotion)` (no `\.dismiss` here — SweepView's
   footer button calls the injected `onDismiss` closure directly instead, a small divergence from
   TriageView's `@Environment(\.dismiss)` pattern — flag this asymmetry for the C# port so the
   ViewModel doesn't need to guess which dismiss mechanism a given batch card uses).
3. Sub-components: defines private `SweepRow`, inline `actions` (Complete/Skip button pair, not
   factored into a shared `actionButton` helper the way TriageView's 4-action row is — another
   small code-shape divergence). Consumes `VolarIcon(.check)`.
4. Theme tokens: `VolarColor.textMut/textPri/textSec/cardHover/card/high/med/low/done` (this file
   additionally uses `VolarColor.done` on the Complete button's check icon — TriageView has no
   equivalent "success" tint since none of its 4 actions map to completion),
   `.volarGlass(level: .heavy, cornerRadius: 16)` (7th occurrence), `.volarHairline(cornerRadius:
   12/8)`, fixed width 520, `Font.volarMono` used directly (footer count + row duration label) ->
   `VolarInstrumentMonoTextStyle`/`VolarMonoFontFamily` (TriageView's footer count uses a plain
   `.monospacedDigit()` system font instead of `Font.volarMono` — 3rd small asymmetry between the
   two "sibling" files worth flagging so an agent building both doesn't assume perfect symmetry).
5. Interaction: same `ScrollView`+`LazyVStack` virtualization note as TriageView, same
   reduce-motion-gated hover, same `.accessibilityLabel` pattern on action buttons.
6. macOS-only API: `@Environment(\.accessibilityReduceMotion)` only (no `\.dismiss` usage here,
   per point 2).
7. Complexity: S-M. Hardest thing: same as TriageView — preserving the neutral/non-shaming visual
   treatment (Skip must NOT look like a failure state) is the one design constraint an agent must
   protect, not any particular technical porting difficulty.

### 1.11 `Components.swift` (223 lines) — shared component file, not a "view" per se

1. Surface: reusable-control library — defines 6 components: `KeyBadge`, `PriorityBadge`,
   `TimeBadge`, `Spinner`, `ToolButton`, `SectionHeader`. This is infrastructure every other view
   slice depends on, not a screen of its own. **`TimeBadge` and (implicitly, for the title-bar
   `+`/search/etc buttons) `ToolButton` are directly required by wave4-slice.md's Today+Popover
   scope** (Today's title-bar tool buttons at 28x28 r=7 = `ToolButton`; TaskRow's trailing time
   pill = `TimeBadge`; the Popover's "Priority"=PriorityBadge / "When"=TimeBadge parse-rows =
   `PriorityBadge`+`TimeBadge` directly). **This file must be ported BEFORE TaskRow/Today/Popover
   can compile** — it is the highest-priority shared-control dependency in the whole inventory (see
   Shared-control manifest below).
2. AppState: `KeyBadge`/`TimeBadge`/`ToolButton`/`SectionHeader` each independently read
   `appState.accent` (`accentColors`) — 4 separate `@Environment(AppState.self)` declarations, one
   per component (not a single shared base). `PriorityBadge` and `Spinner` take NO AppState at all
   (pure parameter-driven, per their init signatures) — confirmed consistent with the file's own
   header comment ("KeyBadge/TimeBadge/ToolButton/SectionHeader read the active accent... ").
3. Sub-components: `ToolButton` defines a private `ToolButtonStyle` (ButtonStyle). None of the 6
   consume each other or any other file's components — this is the leaf/foundation layer.
4. Theme tokens: `VolarColor.textSec/textMut/border`, `accentColors.{solid,surface,hover}`,
   `Color.white.opacity(0.05/0.08/0.10)` (3 more inline one-offs). `PriorityBadge` is notable: it does **NOT**
   use the current `VolarColor.high/med` for its background/foreground roles — it uses raw
   `Color(volar: 0xFF6B6B, opacity: 0.14)` / `Color(volar: 0xFFB347, opacity: 0.14)` /
   `Color(volar: 0xFF8B8B)` / `Color(volar: 0xFFC279)` literals, which are the **STALE
   pre-retheme** hex values (`#FF6B6B` red, `#FFB347` amber) that Theme.swift's own header comment
   says were explicitly superseded by the Studio Dark retheme. **This is a real bug/staleness in
   the CURRENT Swift source, not just a doc-crib mismatch like wave4-slice.md's** — `PriorityBadge`
   visually contradicts `TaskRow`'s/`TaskDetailView`'s priority dot colors (`VolarColor.high`
   `#B9705A`) because it only updates the DOT color (`s.dot = VolarColor.high`, retheme-correct)
   but the pill's background/foreground stayed on the old red/amber literals. **Flag prominently:
   a Windows agent porting `PriorityBadge` should use the CURRENT `VolarHighBrush`/`VolarMedBrush`-
   derived tones consistently (dot AND pill), not reproduce this inconsistency — recommend fixing
   it as part of the port** (this belongs in backlog.md per user's global process if not fixed
   immediately, since it's an unrequested behavior change beyond "port the existing code").
5. Interaction: `Spinner` has a genuine `.repeatForever` linear rotation (0.7s, no autoreverse) —
   like MorningFrogView's pulse, a full "spinner" use case has a direct WinUI `Storyboard`
   `RepeatBehavior="Forever"` equivalent (`RotateTransform` + `DoubleAnimation`), well-trodden
   pattern (WinUI even has a built-in `ProgressRing` control that may be usable directly instead
   of hand-rolling — worth the agent checking if `ProgressRing`'s stock look is close enough
   before reimplementing this custom trimmed-circle spinner). `KeyBadge`/`ToolButton`/
   `SectionHeader` all use `.onHover`/`.animation(VolarMotion.hover/press)` (ToolButton) — same
   gaps as prior views.
6. macOS-only API: `.onHover`, `ButtonStyle` protocol, ANSI-ish monospaced `design: .monospaced`
   font modifier on `KeyBadge` (-> `VolarMonoFontFamily`).
7. Complexity: **S per component, but M in aggregate + HIGH priority** since everything else
   depends on it. Hardest thing: the `PriorityBadge` stale-color bug above — an agent must not
   silently "faithfully port the bug," it should be called out and a decision made explicitly.

### 1.12 `FocusOverlay.swift` (268 lines)

1. Surface: fullscreen single-task Focus-mode overlay (heavy dark glass, giant countdown, one
   task's info, mark-done, pause/end, prev/next task nav). Mounted presumably full-window (not a
   sheet — the file's own comment says it "ports `volar-focus.jsx`'s `VolarFocusOverlay`", a
   full-screen takeover). **Explicitly OUT of wave4-slice.md scope** (listed by name in the OUT
   list: "Focus overlay") — **unassigned, but already explicitly deferred by the locked slice, not
   just unscoped.**
2. AppState: `appState.accent`, `appState.openTasks` (the full candidate list this overlay steps
   through), `appState.focusIndex` (read AND **written directly by this view** —
   `goToPrevious()`/`goToNext()` mutate `appState.focusIndex` in place, confirmed by
   appstate-inventory.md row 28's explicit callout: "note: `FocusOverlay` mutates
   `appState.focusIndex` directly, not through an `AppState` method" — the ONE view in the whole
   app that bypasses the command-method convention), `appState.focusPaused`,
   `appState.focusSecondsLeft`, `appState.completeFocusTask(task.id)` (Mark done),
   `appState.toggleFocusPause()`, `appState.endFocus()`.
3. Sub-components: defines private `FocusRoundBtn` (small round glass icon button, reused 4x
   internally: pause/end, prev/next). No cross-file component consumption. Consumes
   `VolarIcon(.check/.play/.pause/.x/.back/.chevron)`.
4. Theme tokens: `VolarColor.textMut/textPri/textSec/high/med`, `accentColors.{solid,glow}`,
   inline `Color(red: 9/255, green: 10/255, blue: 15/255)` (a hand-computed near-duplicate of
   `VolarColor.bg` #0B0D11 ≈ rgb(11,13,17) — close but NOT byte-identical to the named token;
   flag as a literal-vs-token drift worth reconciling to `VolarBgBrush` during the port rather
   than reproducing a slightly-off custom color), `Color.white.opacity(0.06/0.10/0.12)`.
5. Interaction: **the richest keyboard surface in the whole view layer** — `.focusable()` +
   `.focusEffectDisabled()` + `.focused($isFocused)` + `.onAppear { isFocused = true }` (grabs
   keyboard focus on mount) + `.onKeyPress(.leftArrow)`/`.onKeyPress(.rightArrow)` (prev/next task
   navigation) -> WinUI: `Control.Focus(FocusState.Programmatic)` on load + `KeyDown` event
   handler (or `KeyboardAccelerator` with `Windows.System.VirtualKey.Left/Right`) on the root
   `Grid`/`UserControl`. Also `.help(title)` tooltips on `FocusRoundBtn` (-> WinUI `ToolTipService.
   ToolTip`). Multiple `.animation(VolarMotion.hover, value:)` + one `.animation(.linear(duration:
   1), value: appState.focusSecondsLeft)` (progress-hairline fill, a genuine per-second linear
   animation tied to a changing bound value — WinUI: a `DoubleAnimation` retriggered each time
   `FocusSecondsLeft` changes, or bind the width via a converter and skip animating it at all for a
   simpler v1). `.disabled(index <= 0 / index >= count-1)` on prev/next (-> `IsEnabled` binding).
6. macOS-only API: `.focusable()`/`.focusEffectDisabled()`/`.focused()`/`.onKeyPress` (-> WinUI
   focus + `KeyDown`/`KeyboardAccelerator`), `.help()` (-> `ToolTipService`), `design: .monospaced`
   giant countdown font (76pt semibold monospaced digits -> `VolarMonoFontFamily` at a literal
   size, no matching Typography.xaml style at 76pt so this is a one-off `FontSize` in the view's
   own XAML, not a shared resource).
7. Complexity: **L**. Hardest thing: this is a full input-focus-driven fullscreen surface with
   real keyboard navigation, arrow-key handling, and a view that mutates `AppState` directly
   (breaking the command-method convention every other view follows) — the C# port has 2 choices:
   (a) faithfully keep `FocusIndex` as a publicly mutable bound property on whatever VM owns Focus
   (matching Swift 1:1), or (b) "fix" it into `GoToPrevious()`/`GoToNext()` commands during the
   port (cleaner C#/MVVM idiom, deviates from the literal port). Needs an explicit decision before
   an agent builds it, not something a single view-agent should decide alone given it's a
   documented pre-existing wart, not a bug.

### 1.13 `OnboardingView.swift` (302 lines)

1. Surface: full-window first-run onboarding, 3 steps (hotkey intro / mic permission / try-it),
   gated by `@AppStorage("hasOnboarded V1")` in `VolarApp.swift` (NOT an `AppState` key — a second
   persistence surface per appstate-inventory.md §2). NOT in wave4-slice.md's IN list —
   unassigned.
2. AppState: `appState.accent` only for color, PLUS a real side-effecting call:
   `appState.speech.requestAuthorization()` (step 2's "Allow microphone" button) — this is the
   ONE place any view in the whole app directly calls a method on the `speech` collaborator
   rather than going through an `AppState`-owned command; per appstate-inventory.md row 41,
   `speech` (Apple's on-device ASR) has **no Windows equivalent at all**, and this view is its
   only direct caller outside AppState itself. **This means OnboardingView's Windows port cannot
   have a faithful "Allow microphone" step wired to the same collaborator** — it needs to call
   whatever the Windows speech-permission-request mechanism ends up being (likely Windows'
   `Windows.Media.SpeechRecognition` capability prompt, or simply a no-op if the port's speech
   strategy is "batch-only, no live ASR" per memory's freemium-speech decision) — flag as an
   app-layer dependency, not something this view agent can resolve alone.
3. Sub-components: defines private `stepDots`, `footer`, `stepContent`/`title`/`subtitle` helpers,
   `stepOne`/`stepTwo`/`stepThree`. Consumes `KeyBadge(_:accent:)` (4th consumer file) and
   `VolarIcon(.mic)`.
4. Theme tokens: `VolarColor.bg/textPri/textSec/textMut/border/done`, `accentColors.{solid,hover,
   surface,glow}`, `Color.white.opacity(0.04/0.15)`, corner radii 11/12/14/22 (a 4th distinct
   one-off radius family beyond the 12/9/6 Metrics set and the 14/16 modal one-offs already
   flagged — this view alone introduces 22pt icon-tile radius and 11pt button radius, neither
   matching any existing Metrics key).
5. Interaction: `withAnimation { step = N }` step transitions (plain SwiftUI implicit animation on
   a state var -> WinUI: a `Frame`/`Grid` content transition, e.g. `NavigationThemeTransition` or
   a manual crossfade `Storyboard` between 3 pre-built panels), animated step-dot width change
   (`.animation(VolarMotion.hover, value: step)` on the active dot's width 6->18 — another
   VolarMotion-gap instance), an `async Task { }` around the mic-permission call (-> `async`/
   `await` in the C# command, direct 1:1 with `IAsyncRelayCommand`).
6. macOS-only API: `appState.speech.requestAuthorization()` (Apple Speech framework permission
   prompt — no Windows equivalent, see point 2), otherwise standard already-covered patterns
   (`.volarHairline`, `KeyBadge`, `VolarIcon`).
7. Complexity: M. Hardest thing: the mic-permission step has no faithful Windows target to call —
   this is a product decision (what does "Allow microphone" even mean on Windows given the
   speech-engine strategy?) before an agent can port step 2 meaningfully; steps 1 and 3 are
   otherwise straightforward layout/button work.

### 1.14 `AmbientBackground.swift` (417 lines) — longest non-Today/Popover/Settings file

1. Surface: background layer — full-window ambient particle system (rain/snow/embers via
   `TimelineView`+`Canvas` procedural drawing) OR a custom user-chosen image layer, rendered
   behind `TodayView`'s content (per `TodayView`'s own `.background` reference, confirmed in
   appstate-inventory.md row 5: consumed at `TodayView.swift:29-30,152`) and `Sidebar`'s
   conditional glass background (row 5 again: `Sidebar:60`). NOT in wave4-slice.md's IN list
   (explicitly OUT: "ambient backgrounds") — unassigned, and per wave4-slice.md's scope note,
   Today's Wave-4 slice should render WITHOUT this layer for now (plain background instead).
2. AppState: **NONE directly in this file** — confirmed by appstate-inventory.md's intro note
   ("`AmbientBackground.swift` also has no `@Environment(AppState.self)`... pure rendering,
   parameters only"). Takes `mode: AmbientMode`, `imageURL: URL?`, `intensity: Double = 0.7` as
   plain init params — the CALLERS (`TodayView`, `Sidebar`) read `appState.ambient`/
   `appState.customImageURL` and pass them in. So the Windows XAML control itself needs no direct
   AppState/VM reference either — just bound properties from whatever hosts it.
3. Sub-components: defines private `CustomImageLayer`, `HatchPattern`, `Particle` struct,
   `SplitMix64` (seeded RNG). No cross-file consumption — fully self-contained leaf, like
   `Waveform`.
4. Theme tokens: mostly inline literal colors NOT drawn from `VolarColor` at all — per-mode
   backdrop gradients (`Color(volar: 0x0C1220)` etc, 9 distinct hex literals across
   rain/snow/embers), particle colors (`rgba(172,194,235,·)` rain, `rgba(230,238,252,·)` snow,
   `rgba(255,190,110,·)`/`rgba(255,198,122,·)` embers glow/fill), `Color(volar: 0x101014)`/
   `Color(volar: 0x14141A)`/`Color(volar: 0x17171E)` (custom-mode bg / placeholder bg / hatch
   stripe). **None of these have a named Colors.xaml resource** — they are a deliberately separate
   "ambient" palette, distinct from the Studio Dark UI palette; the Windows port should introduce
   its OWN small `AmbientColors.xaml`-style set of literals (or just inline them, matching the
   Swift file's own approach) rather than trying to force-fit them into the existing
   `VolarColor`/Colors.xaml naming scheme.
5. Interaction: pure rendering, `allowsHitTesting(false)` throughout (never intercepts input) —
   simplifies the port (no gesture/focus concerns at all). The animation itself is the entire
   challenge: `TimelineView(.animation)` + `Canvas` procedural draw, redrawn every frame, animating
   30-130 particles (rain streak lines / snow ellipses / glowing ember ellipses with a shadow
   filter) via closed-form per-particle-per-frame math seeded by a custom `SplitMix64` PRNG for
   deterministic (non-`Date`-seeded) initial placement. This is the SAME structural gap as
   `Waveform.swift` (§1.2) — no WinUI 1:1 for "per-frame procedural Canvas draw of N animated
   primitives" — except LARGER in scope (3 distinct particle systems, up to 130 particles, a
   custom seeded RNG, wrap-around cycling, a shadow/glow filter on embers) and layered UNDER other
   UI content rather than being a standalone control. Recommended approach: Win2D `CanvasControl`
   with a `CompositionTarget.Rendering`-driven redraw (closest 1:1 to `Canvas`+`TimelineView`,
   reuses the exact per-particle math almost verbatim including the `SplitMix64` seed function and
   the trig formulas) — OR accept a lower-fidelity static/CSS-gradient-only ambient mode for a
   first pass and defer full particle parity. This is a genuine scope/fidelity decision for the
   orchestrator, not a mechanical-port judgment call for a single agent.
6. macOS-only API: `TimelineView`/`Canvas`/`GraphicsContext.addFilter(.shadow(...))` (same gap as
   Waveform), **`NSImage`, `NSOpenPanel`-granted security-scoped bookmarks
   (`url.bookmarkData(options: .withSecurityScope, ...)`, `startAccessingSecurityScopedResource`)**
   — the entire `SecureImageBookmark` enum (lines 320-397) is App-Sandbox-specific plumbing with
   **no Windows equivalent need at all**: Windows has no App Sandbox security-scoped-URL concept —
   a chosen file path from a Windows file picker (`FileOpenPicker`) can simply be stored and
   re-read directly (subject to normal ACLs), no bookmark/re-resolution dance required. **This
   entire subsystem (77 lines) should be DELETED, not ported** — replace with a plain stored file
   path + `BitmapImage`/`StorageFile` load, which is strictly simpler than the Mac version. Flag
   this explicitly so an agent doesn't waste time porting sandboxing machinery Windows doesn't
   need.
7. Complexity: **L**. Hardest thing: same category of problem as Waveform but bigger — 3 particle
   systems' worth of per-frame procedural math needs a WinUI-appropriate rendering strategy
   decision before any agent should start, PLUS a scope decision on whether v1 even needs full
   particle fidelity vs. a static gradient placeholder (explicitly OUT of wave4-slice.md already,
   so this can stay deferred pending that decision).

### 1.15 `SettingsView.swift` (958 lines) -- 2nd-largest file, most AppState surface area

1. Surface: Settings window, 6 tabs (General/Hotkeys/Notifications/Appearance/Integrations/About).
   Mounted from `VolarApp.swift`'s `Settings` scene (a native macOS Settings window, not a sheet).
   Explicitly OUT of wave4-slice.md scope ("OUT: ... Settings") -- unassigned, and the largest
   remaining single slice by AppState surface area.
2. AppState -- by far the widest single-view binding surface in the app (partial list; full
   per-member detail already lives in appstate-inventory.md, cross-referenced here):
   `appState.speechEngineChoice`/`setSpeechEngine`, `appState.whisper.state` (WhisperKit
   download/ready status -- Windows: no WhisperKit equivalent per appstate-inventory.md row 42),
   `GroqEngine.isConfigured` (static check, not AppState but adjacent), `appState.
   parseEnginePreference`/`setParseEngine`, `ConfigParseCredentialProvider.isConfigured`,
   `appState.recognitionLocaleID`/`setRecognitionLocale` (bound to `SFSpeechRecognizer.
   supportedLocales()` -- macOS-only API, no direct Windows equivalent; Windows would need
   `Windows.Globalization.Language`/`SpeechRecognizer.SupportedTopicLanguages` or a hardcoded
   locale list depending on the chosen speech strategy), `appState.globalReminderPolicy`/
   `setGlobalReminderPolicy`, `appState.voiceDeliveryMode`/`setVoiceDeliveryMode`,
   `appState.ambient`/`setAmbient`, `appState.customImageURL`/`setCustomImage` (+ the
   `SecureImageBookmark`/`NSOpenPanel` machinery, same sandbox-only concern flagged in
   AmbientBackground SS1.14 -- delete, don't port, use `FileOpenPicker` + plain path storage on
   Windows), `appState.accent`/`setAccent` (this is the ONLY view in the entire app that
   actually exercises the accent-family SWITCHING UI -- the accent-swatch row, lines 408-432 --
   confirming the SS0 flag that Windows has the 4 accent-family resource sets but no UI/logic yet
   to repoint `AccentSolidBrush` etc. at runtime; this view's port is what will surface that gap
   concretely), `appState.density`/`setDensity` (same "only exerciser" story as accent -- the
   Density segmented control here is the sole call site), `appState.claudeConnector` (`.detect()`,
   `.previewHookEntry()`, `.connect(bookmarkedClaudeDir:)`, `.disconnect(...)`,
   `.sendTestSignal()` -- all 5 methods used only from this file), `appState.lastAppLinkAt`
   (`.onChange` drives the test-signal "received" receipt UI), `appState.delegation?.
   wipCount()` (gates whether "Send test signal" is offered -- same value MenuBarLabel's WIP badge
   reads).
3. Sub-components: defines 6 private shared controls used ONLY within this file:
   `SettingsRow<Content>`, `VolarToggle`, `Segmented<T>`+`SegmentOption<T>`,
   `CustomImageThumbnail`, `KeyRecorder`. None of these are reused by any other view in the
   inventory (unlike `KeyBadge`/`TimeBadge`/`ToolButton` from Components.swift, which ARE reused
   elsewhere) -- so these 6 can be built as Settings-page-local controls in the Windows port
   without needing to land in the shared-control manifest first. Also defines a private
   `ReminderPolicyPreset` enum (Settings-local named presets over `ReminderPolicy`) and a private
   `ClaudeDirBookmark` enum (a byte-for-byte duplicate of `AmbientBackground.swift`'s
   `SecureImageBookmark` pattern, per its own doc comment -- same delete-don't-port verdict:
   Windows has no App Sandbox, so persisting a plain folder path is sufficient, no bookmark
   re-resolution dance needed).
4. Theme tokens: touches nearly every token in Colors.xaml at least once (`VolarColor.bg/card/
   textPri/textSec/textMut/border/borderHi/surface/surfaceHi/done/reschedule/instrument`,
   `accentColors.{solid,hover,surface,glow}`), several one-off radii (16 for the About icon tile,
   11 for `SettingsRow`/`claudeCodeCard`, matching neither the 12/9/6 Metrics set nor the modal-16
   pattern from other views -- a 5th distinct radius value, `11`, recurring 3x in THIS file alone),
   `Color.black.opacity(0.25)` (recurs 3x: hyperfocus segmented bg, long-press chip bg, KeyRecorder
   bg -- worth a named resource if any of these controls gets reused later, though currently
   Settings-local only).
5. Interaction: `Picker(...).pickerStyle(.menu)` x3 (speech engine, parse engine, recognition
   locale -- WinUI: `ComboBox` bound via `SelectedItem`/`SelectedValue`, direct 1:1 for a menu-style
   picker), custom `Segmented<T>` control (already covered as a Settings-local sub-component --
   WinUI: a `RadioButtons`/`SegmentedControl`-style `ItemsRepeater` of toggle buttons, or WinUI 3's
   community-toolkit `SegmentedControl` if that dependency is already in use elsewhere), custom
   `VolarToggle` (a hand-rolled pill switch, NOT the SwiftUI `Toggle` -- WinUI has a stock
   `ToggleSwitch` control that could substitute directly, OR restyle it to match the pill look; an
   agent should check whether visual fidelity or native-control-reuse wins here), `.task` (runs
   once when the Integrations tab is first shown -- detects Claude Code -- WinUI: `Loaded` event or
   a VM `InitializeAsync` called from the tab-selection command), `.onChange(of: appState.
   lastAppLinkAt)` (test-signal receipt -- needs a live-updating binding/event in the C# VM),
   `NSOpenPanel` x2 (`chooseImage`, `connectClaudeCode` -- both macOS-only, replace with
   `Windows.Storage.Pickers.FileOpenPicker`/`FolderPicker`), `.textSelection(.enabled)` on the
   hook-preview code block (-> WinUI `TextBlock.IsTextSelectionEnabled="True"`, direct 1:1).
6. macOS-only API: `NSOpenPanel` (x2, see above), `SFSpeechRecognizer.supportedLocales()`,
   `NSHomeDirectoryForUser`/`FileManager.default.homeDirectoryForCurrentUser` (sandbox-vs-real-home
   distinction -- N/A on Windows, no sandbox container concept, just use the real path directly),
   `NSWorkspace` (indirectly, via `ClaudeCodeConnector.sendTestSignal()`'s `volar://` URL open --
   Windows needs a registered custom URI scheme handler, same gap noted in appstate-inventory.md
   SS2 for `application(_:open:)`), the entire security-scoped-bookmark pattern (x2 in this file:
   `ClaudeDirBookmark` + reused `SecureImageBookmark`) -- delete, don't port, per SS1.14's verdict.
7. Complexity: L. Hardest thing: this is less a UI-porting problem and more an
   integration-surface problem -- the Claude Code "Connect" card (lines 490-953, roughly half the
   file) depends on `ClaudeCodeConnector`, `AppLinkHandler`, and a `volar://` custom-URI-scheme
   receive path, none of which exist on Windows yet (per appstate-inventory.md row 50's explicit
   callout: "Windows needs a custom URL protocol registration... instead of macOS's `.onOpenURL`").
   A view agent cannot build a faithful Integrations tab until that app-layer plumbing exists --
   recommend splitting this file's tabs across 2 slices: General/Hotkeys/Notifications/Appearance/
   About (straightforward settings UI, buildable now) vs. Integrations (blocked on the
   `volar://`-equivalent infra) -- see slice proposal.

### 1.16 `TodayView.swift` (953 lines) -- CRITICAL SCOPE FLAG, read this before building Today

**The actual current `TodayView.swift` no longer matches wave4-slice.md's locked design layout
spec.** wave4-slice.md (lines 100-114) describes a flat "Now section / Later today section /
Completed section" row-list layout ported from `design/volar-mac.jsx` -- rows stacked under
plain section headers, no spotlight hero. The file actually on disk (per its own header comment,
"STUDIO DARK RETHEME (2026-07, visual layer only)") has been restructured into a completely
different visual grammar: ONE spotlit "NOW" hero card (`nowSpotlight`, a bespoke ~300pt-tall
centered card with a 28pt title, chip row, and 3 action buttons -- Start Focus / Done / Delegate
to Claude), ONE dimmed "NEXT" peek row (`NextPeekRow`), and everything else collapsed by default
into two disclosure drawers ("Later"/"Completed", `CollapsibleTaskSection`, default-collapsed,
height-capped at 6 visible rows). This is NOT a cosmetic tweak -- it changes which controls exist,
how many rows render by default, and what wave4-slice.md's W-B task ("replace the placeholder...
title bar row + sidebar + main column + sections") actually needs to build. **The orchestrator
must decide explicitly whether Wave 4 targets the OLD flat design wave4-slice.md specifies or the
NEW spotlight design actually in the Swift source** before assigning a Today-view agent --
building either one is a reasonable, self-consistent scope, but an agent left to infer from
"read the design spec" (wave4-slice.md) vs. "port the Swift" (TodayView.swift) will get two
different UIs. This inventory describes the ACTUAL current Swift source below, since that's what
this task was asked to inventory; wave4-slice.md's older spec is flagged, not corrected.

1. Surface: main window content -- title-bar toolbar + Sidebar + greeting header + NOW spotlight +
   NEXT peek + Later/Completed drawers + hotkey footer, PLUS the overlay stack this view owns:
   capture-state scrim + `PopoverView`, `FocusOverlay` (when `focusActive`), a reminder-banner
   overlay (`NotificationView`), and an ambient background layer. Partially in wave4-slice.md
   scope (Today's IN-list items: title bar, sidebar, greeting, task list, empty state, real
   load/toggle/create) but the ACTUAL layout structure diverges as described above; the overlay
   stack (Popover host, Focus overlay, ambient bg, reminder banner) mixes IN-scope (Popover host)
   with explicitly OUT-scope (Focus overlay, ambient bg per wave4-slice.md's OUT list) elements
   all living in this ONE file -- an agent building "Today" per wave4-slice.md must carefully
   include the Popover overlay wiring but skip/stub FocusOverlay, AmbientBackground, and
   NotificationView mounting, none of which exist yet in the Windows port.
2. AppState -- the widest read/mutate surface of the whole view layer (superset even of
   SettingsView's list, though narrower per-member): `appState.ambient`/`customImageURL`
   (ambient bg gating), `appState.captureState` (popover-scrim gating + `cancelCapture()` on scrim
   tap), `appState.focusActive` (FocusOverlay gating + greeting-header pill swap),
   `appState.reminderBanner`/`dismissBanner()` (notification overlay + auto-dismiss `.task`),
   `appState.ambientSound.isPlaying`/`toggleAmbientSound()`, `appState.readDayAloud()`,
   `appState.startCapture()` (toolbar `+`), `appState.density.{sectionGap,rowGap}`,
   `appState.openTasks`/`activeTask` (NOW/NEXT/LATER derivation -- `remainingOpenTasks`/
   `peekTask`/`laterListTasks` are view-local computed properties built FROM these, not new
   AppState members), `appState.doneTasks`, `appState.tasks` (list-change `.animation` trigger),
   `appState.startFocus()`/`toggleDone()`/`delegateTask()`/`openDetail()`/`showBreakdown`/
   `deleteTask()` (NOW spotlight's actions + context menu), `appState.frogTask` (running-focus
   pill / frog pill title), `appState.focusPaused`/`focusSecondsLeft`/`toggleFocusPause()`/
   `endFocus()` (running-focus pill controls), `appState.dueDelegationRechecks`/
   `pendingDisambiguationTaskIDs`/`resolveAppLinkDisambiguation()`/`dismissAppLinkDisambiguation()`/
   `resolveDelegationDone/StillWaiting/CheckLater()` (the `DelegationAmbientSection` sub-view, T043
   phase6-contract.md SSC -- a THIRD distinct feature area embedded in this one file, on top of
   the main Today list and the overlay stack).
3. Sub-components: defines FOUR private sub-structs beyond the main view --
   `EmptyTodayCard`, `SpotlightChip`, `NextPeekRow`, `CollapsibleTaskSection`,
   `DelegationAmbientSection` (5, actually). Consumes `Sidebar()`, `PopoverView()`,
   `FocusOverlay()`, `NotificationView(...)`, `AmbientBackground(...)`, `ToolButton` (Components),
   `TaskRow` (inside `CollapsibleTaskSection` -- confirms wave4-slice.md's assumption that
   `TaskRow` is the row primitive reused inside the drawers, NOT inside the NOW/NEXT slots which
   use bespoke layouts), `KeyBadge`, `VolarIcon`.
4. Theme tokens: touches essentially the full palette (`VolarColor.bg/surface/surfaceHi/border/
   borderHi/textPri/textSec/textMut/high/done/instrument/instrumentDim/nowAccent/nowAccentSoft/
   nowGlow/nowRing`), `.volarSpotlight(isActive:)` (the ONE other consumer of Theme.swift's
   `SpotlightBackground` modifier besides MenuBarLabel's focus-lock badge -- confirms the SS0 flag
   that the vignette-overlay half of the spotlight primitive has no XAML resource yet and this view
   needs it built), corner radius 22 (the NOW spotlight card + "nothing ready" placeholder -- a
   6th distinct one-off radius value beyond 12/9/6/11/14/16), radius 15 (NextPeekRow +
   CollapsibleTaskSection -- a 7th).
5. Interaction: `.toolbar { ToolbarItemGroup(placement: .primaryAction) }` (4 title-bar tool
   buttons -- WinUI: a custom title-bar row of `ToolButton`s, matching wave4-slice.md's own plan
   already, since WinUI has no native `.toolbar` modifier equivalent for in-content placement the
   way SwiftUI does), `.contextMenu` on the NOW spotlight card (4 items, same MenuFlyout pattern as
   TaskRow SS1.4), `.onTapGesture` (NOW card, NextPeekRow -- open detail), 2 independent
   `.repeatForever` pulse animations (running-focus pill's dot, distinct from MorningFrogView's and
   Spinner's own instances -- same Storyboard-`RepeatBehavior="Forever"` pattern, 3rd occurrence in
   the inventory), `.animation(VolarMotion.state, value: appState.reminderBanner)` +
   `.animation(VolarMotion.list, value: appState.tasks)` (2 more VolarMotion-gap instances, this
   time on LIST content changes -- WinUI: `ItemsRepeater`/`ListView` add/remove animations via
   `ItemContainer` transitions or explicit `ContentTransitions`), `.transition(.asymmetric(...))`
   ×2 (banner slide-in, row insert/remove in `CollapsibleTaskSection` -- WinUI: `Transitions`
   collection on the hosting panel, e.g. `AddDeleteThemeTransition`/`RepositionThemeTransition`),
   `.task(id: appState.reminderBanner?.id)` (auto-dismiss-after-5s -- WinUI: a `CancellationTokenSource`
   +`Task.Delay` re-armed whenever the bound banner id changes, direct 1:1), disclosure toggle
   buttons on `CollapsibleTaskSection` ("Show"/"Hide" -- plain `Button` + bound `bool`, trivial).
6. macOS-only API: nothing new beyond what's already covered by its 6 consumed sub-views'
   individual macOS-API lists (Sidebar/PopoverView/FocusOverlay/NotificationView/AmbientBackground
   each already catalogued above) -- TodayView itself is composition + its own bespoke
   NOW/NEXT/drawer layout, no additional native-API surface of its own beyond `.toolbar`/
   `.contextMenu`/`.transition`/`.animation`, all already covered elsewhere in this document.
7. Complexity: **L**. Hardest thing: this is the single highest-fan-in file in the view layer --
   it composes 5 other views/overlays PLUS defines 5 of its own sub-structs PLUS owns a whole
   separate delegation-ambient feature area, and (per the CRITICAL SCOPE FLAG above) the visual
   design it currently implements diverges from the one wave4-slice.md's Today spec describes.
   Recommend the orchestrator resolve the design-version question FIRST, then split Today into at
   minimum 2 slices: (a) the NOW/NEXT/drawer list + greeting + toolbar (core, matches most of
   wave4-slice.md's W-B), and (b) `DelegationAmbientSection` (a self-contained, independently
   toggleable feature area that depends on `DelegationOrchestratorService`/cluster I per
   appstate-inventory.md SS3, not yet ported at all) -- (b) should NOT block (a) from shipping.

### 1.17 `PopoverView.swift` (1214 lines) -- CRITICAL SCOPE FLAG, largest file in the inventory

**Like TodayView, the actual current `PopoverView.swift` is dramatically richer than
wave4-slice.md's locked Popover spec.** wave4-slice.md (lines 116-125) describes a simple 7-state
card: hint row, 42px glyph slot, transcript, ONE parsed card with 4 fixed label/value rows
("Task"/"When"/"Priority"/"Context"), actions row. The actual Swift source implements a
substantially larger feature set the slice doc's spec doesn't mention at all:
- **Multi-task confirm** -- `appState.confirmDrafts` is an ARRAY; the card renders N draft
  sub-cards separated by hairlines (not fixed at 1), each individually removable (`removeDraft`),
  and Enter saves the whole batch ("Save 3 tasks").
- **Per-attribute dismissible/acceptable chips** -- deadline/estimate/priority/reminder/
  recurrence/kind/followUpReview each render as an independent `Chip` with its own
  accept/dismiss affordance and an "uncertain" (<0.7 confidence) dashed-border state requiring an
  explicit tap before it counts as confirmed (constitution II in the file's own comments) -- this
  is a full micro-interaction model per attribute, not 4 static label/value rows.
- **Condition rows incl. a dependency-picker `Menu`** -- `.taskDone` conditions below confidence
  render a native `Menu` populated from `appState.openTasks` (capped at 100) letting the user pick
  which other task this one depends on, or "Skip -- no dependency"; `.afterDate`/`.external`
  conditions render as ordinary chips.
- **Conflict advisory row** -- `TaskConflict` (from `VolarCore`, contract C) renders one calm
  dismissible sentence per draft (5 conflict cases with distinct copy) -- **this is the only view
  file in the whole inventory that imports `VolarCore` directly** (`import VolarCore` at the top),
  meaning its Windows port has a REAL dependency on however much of `VolarCore`'s conflict-check
  API has been ported already (need to confirm `TaskConflict`'s C# port exists before this row can
  compile).
- **A whole second card type, `voiceDoneCard`** -- for voice-driven "mark done"/"clear
  condition"/"delegate" intents (`AppState.voiceDoneConfirm`/`voiceDoneNoMatchTranscript`), with
  its own one-tap-vs-disambiguation-list branching, mutually exclusive with the normal parsed
  card.
- **Two consent-gated error sub-flows** -- `dictationConsentActionsRow` (on-device dictation is
  off, offers "Open Dictation Settings" -- **macOS-only, `NSWorkspace`+`x-apple.systempreferences:`
  URL, no Windows equivalent at all**, appstate-inventory.md row 90 confirms this same gap for
  `AppState.openDictationSettings()`) and `cloudConsentActionsRow` (one-time cloud-parse privacy
  opt-in).
- **A custom `FlowLayout`** (a hand-rolled SwiftUI `Layout` conformance, wrapping chips
  left-to-right) -- WinUI has a native equivalent: `Microsoft.UI.Xaml.Controls.WrapPanel` isn't
  built-in to WinUI 3 core (it's `ItemsWrapGrid` or a Community Toolkit `WrapPanel`), so this
  needs either the toolkit's `WrapPanel` or a hand-rolled attached-layout equivalent -- not a
  trivial 1:1 but a well-known WinUI pattern.
This means wave4-slice.md's "5 states, 4 ParseRows" framing significantly UNDER-scopes what a
faithful PopoverView port actually requires. **The orchestrator should treat wave4-slice.md's
W-C (CapturePopoverControl) as covering ONLY the single-draft, no-conflict, no-voice-done, no-
consent happy path** (consistent with the slice doc's own stated speech-stub constraint: typed
text -> heuristic parse -> single confirm -> save) and explicitly decide whether chips/multi-draft/
conflict-advisory/voice-done/consent-rows are a Wave-4-B follow-up or deferred to a later wave --
this is a scope decision, not a porting-difficulty question, and belongs with the orchestrator
before an agent starts "the popover."

1. Surface: menu-bar/hotkey-triggered quick-capture overlay, hosted (per wave4-slice.md's own
   architecture decision, item 4) as an overlay Grid inside MainWindow, not a separate window.
   Partially in wave4-slice.md scope (the happy-path subset only, per the flag above).
2. AppState: `appState.accent`, `appState.captureState` (all 7 states, drives nearly every
   visibility computed property), `appState.confirmDrafts` (array), `appState.voiceDoneConfirm`/
   `voiceDoneNoMatchTranscript`, `appState.captureErrorDetail`, `appState.liveTranscript`,
   `appState.cancelCapture()`, `appState.removeDraft()`, `appState.dismissConflictAdvisory()`,
   `appState.acceptUncertainAttribute()`/`dismissAttribute()` (×7 attribute kinds),
   `appState.acceptUncertainCondition()`/`dismissCondition()`, `appState.resolveTaskDone()`,
   `appState.openTasks` (dependency picker's candidate list), `appState.confirmVoiceDone()`/
   `dismissVoiceDoneConfirm()`/`captureVoiceDoneAsNewTask()`, `appState.confirmSave()`,
   `appState.pendingServerConsent`/`pendingCloudConsent`, `appState.openDictationSettings()`/
   `useServerRecognition()`/`resolveCloudConsent()`/`startCapture()`. This is the single
   densest AppState-binding file in the entire view layer (more distinct AppState members touched
   than even SettingsView, though SettingsView's are individually more varied in TYPE).
3. Sub-components: defines 6 private sub-structs -- `Kbd` (note: a SECOND, visually-distinct key
   chip from Components.swift's `KeyBadge` -- deliberately not reused, per its own doc comment --
   an agent must not "simplify" by merging these two), `Chip`, `FlowLayout`, `PulsingDot`,
   `MicBreathingGlow`, `BlinkingCaret`. Consumes `Waveform` (SS1.2), `Spinner` (Components.swift).
4. Theme tokens: touches most of Colors.xaml (`VolarColor.textMut/textPri/textSec/border/card/
   done/reschedule/instrument/instrumentDim/nowRing/nowAccentSoft/bg`), `accentColors.{solid,
   glow,surface}`, `.volarGlass(level: .heavy, cornerRadius: 18)` (an 8th distinct one-off radius --
   18, only used here), `.volarSpotlight(isActive: showTranscript)` (2nd consumer of the
   spotlight primitive alongside TodayView, confirming SS0's vignette-overlay gap matters for THIS
   view too, not just Today).
5. Interaction: **the richest keyboard-shortcut surface after FocusOverlay** --
   `.keyboardShortcut(.cancelAction)` (×4: hint-row invisible Esc button [FIX D], actionsRow
   Cancel, voiceDoneDismissButton, errorActionsRow Dismiss) and `.keyboardShortcut(.defaultAction)`
   (×4: actionsRow Save, voiceDoneConfirmButton, dictation/cloud-consent primary buttons) -- WinUI:
   `KeyboardAccelerator` (`Escape`/`Enter`) attached per-button or centrally on the popover root,
   dispatching to the currently-relevant command; the FIX-D "invisible button carries the
   shortcut" trick (lines 136-145) is a SwiftUI-specific workaround that has no reason to carry
   over literally -- WinUI can just bind `Escape` centrally to whatever "cancel" command is active
   for the current state. Multiple `.transition` combinations (opacity, opacity+move) on card
   appear/disappear -- same `ContentTransitions`/Storyboard gap as elsewhere. THREE independent
   `.repeatForever` loops (`PulsingDot`'s ring expand, `MicBreathingGlow`'s breathing opacity,
   `BlinkingCaret`'s hard on/off via `TimelineView(.periodic)` rather than an interpolated
   animation -- note this ONE is a hard cut, not eased, so a WinUI port should use a 2-keyframe
   `DiscreteDoubleKeyFrame` Storyboard, not a smooth `DoubleAnimation`, to preserve the intentional
   non-eased blink). `MicBreathingGlow` and `PulsingDot` both respect
   `@Environment(\.accessibilityReduceMotion)` (only `MicBreathingGlow` explicitly checks it in
   code though -- `PulsingDot` does NOT check reduce-motion despite being a similar looping
   animation, a small inconsistency worth flagging, not necessarily fixing, during the port). A
   native `Menu` (dependency picker, SS above) -> WinUI `MenuFlyout` triggered from a button, or a
   `ComboBox` styled to look like the custom chip (visual fidelity vs. control-reuse tradeoff,
   same category of decision as SettingsView's `VolarToggle`).
6. macOS-only API: `appState.openDictationSettings()`'s underlying `NSWorkspace`+
   `x-apple.systempreferences:` (no Windows target at all -- if the Windows port has no live-ASR
   engine per memory's freemium-speech decision, the entire dictation-consent sub-flow may be
   N/A and should simply not be built, rather than porting dead UI for a state that can never
   occur on Windows -- flag for the orchestrator), `Menu`/`.menuStyle(.borderlessButton)` (->
   `MenuFlyout`), custom `Layout` protocol (`FlowLayout` -> WrapPanel/Community Toolkit, see above),
   `TimelineView(.periodic(from:by:))` (caret blink -> `DispatchTimer`/`DispatcherTimer` toggling a
   bool bound to opacity, straightforward 1:1 despite the different API shape).
7. Complexity: **L**. Hardest thing: same category as TodayView -- the scope gap between what
   wave4-slice.md locked in and what the actual Swift source implements is large enough that "port
   PopoverView" is really "decide how much of PopoverView, then port that." The happy-path subset
   (single draft, no conflicts, no voice-done, no consent rows) is a reasonably-scoped M/L agent
   task consistent with W-C; the full file is realistically 2-3 additional agent-sized follow-up
   slices (chips+conditions+picker; conflict-advisory+voice-done; consent rows) that should NOT be
   bundled into the Wave-4 happy path.

---

## 2. Shared-control manifest (must exist BEFORE per-view agents start)

Ordered by how many views depend on them. Building these out of order stalls whichever view
agent hits the missing type first.

1. **`Components.swift` port (`KeyBadge`, `PriorityBadge`, `TimeBadge`, `Spinner`, `ToolButton`,
   `SectionHeader`)** -- HIGHEST PRIORITY. Consumers: `TaskRow` (`TimeBadge`), `Sidebar`
   (`KeyBadge`), `MorningFrogView` (`KeyBadge`), `OnboardingView` (`KeyBadge`), `TodayView`
   (`KeyBadge`, `ToolButton`, indirectly via toolbar), `SettingsView` (`KeyBadge` inside
   `KeyRecorder`), `PopoverView` (`Spinner`). Required bindings: each of the 4 accent-aware
   components (`KeyBadge`/`TimeBadge`/`ToolButton`/`SectionHeader`) needs the current
   `AccentSolidBrush`/`AccentHoverBrush`/`AccentSurfaceBrush`/`AccentGlowBrush` (or an
   accent-family-aware equivalent once that gap, see SS3 below, is closed). **Fix the
   `PriorityBadge` stale-color bug (SS1.11 point 4) as part of this port**, don't propagate it.
2. **`GlassPanel`/`Glass.xaml` composition helper** (a UserControl or attached-property bundling
   `VolarGlassStandardBrush`/`HeavyBrush`/`SubtleBrush` + the hairline-border overlay Glass.swift's
   `GlassBackground` always pairs with it). Consumers: nearly every modal/sheet view (Notification,
   MorningFrog, TaskDetail, TaskBreakdown, Triage, Sweep, Popover) plus Sidebar's conditional
   background. Without this, 7+ views each hand-roll a slightly different Border+Border
   composition. Required: parametrized level (subtle/standard/heavy) + cornerRadius (literal, per
   the CornerRadius/Thickness XAML gotcha -- this control's XAML template needs the SAME
   literal-not-StaticResource discipline every consuming view already needs).
3. **`VolarIcon` lookup control/dictionary** (VolarIconName -> Segoe Fluent glyph, see SS4 SF
   Symbols table below). Consumers: every single view file in the inventory except
   `AmbientBackground`/`Waveform` (the two purely-parametric leaves). Blocks literally everything
   visual. Should land as either a `VolarIcon` UserControl (`Name` DependencyProperty) or a static
   `Dictionary<VolarIconName,string>` + a thin `FontIcon` wrapper -- agent's choice, but must exist
   before any other control renders an icon.
4. **`TaskRowViewModel`/`TaskRowControl`** -- already scoped by wave4-slice.md W-A/W-B. Additional
   consumers beyond Today's own lists: `TaskBreakdownView` does NOT reuse it (has its own bespoke
   `stepRow`), but `CollapsibleTaskSection` (inside TodayView, SS1.16) explicitly reuses `TaskRow`
   for its Later/Completed drawers, and `Sidebar`'s nav-item counts read the same open-task data
   this VM's source list is drawn from. Confirm this lands before `CollapsibleTaskSection`.
5. **`Segmented<T>`/`VolarToggle`** (SettingsView-local per SS1.15, but worth listing here since a
   later Settings-window slice will need them and they're reusable-in-spirit even if currently
   file-local) -- LOWER priority since Settings itself is deferred; list here only so whoever
   eventually builds Settings doesn't rediscover the WinUI equivalents (`RadioButtons`/community
   `SegmentedControl`, stock `ToggleSwitch`) from scratch.
6. **Spotlight vignette-overlay brush** (SS0's flagged gap: `NowSpotlightBrush` covers the pool,
   but the SECOND radial-gradient overlay layer -- `Theme.swift`'s `SpotlightBackground`
   `.overlay` half, off-axis at `UnitPoint(0.5,0.32)`, darkening into shadow -- has no XAML
   resource). Consumers: `TodayView`'s NOW spotlight card, `MenuBarLabel`'s focus-lock badge (if
   that ever gets a real tray-flyout host), `PopoverView`'s transcript-region spotlight. Needed
   before any of those 3 views can be visually faithful (functionally they can ship without it --
   this is a fidelity gap, not a compile-blocker, unlike items 1-4 above).
7. **A looping-animation Storyboard pattern/helper** (the `VolarMotion` gap, SS0) -- not a single
   control but a recommended shared approach (e.g. a small `AttachedProperty`/`Behavior` that
   takes a spring-like duration/damping pair and produces a reusable `Storyboard`) so the 3+
   `.repeatForever` consumers (MorningFrogView's pulse, Components.swift's `Spinner`, PopoverView's
   `PulsingDot`/`MicBreathingGlow`) and the 10+ `.animation(VolarMotion.hover/press/list/state,
   ...)` consumers don't each invent their own ad hoc Storyboard boilerplate.

---

## 3. Slice proposal

Grouped so no two slices touch the same file; dependency order top-to-bottom; "||" marks slices
that can run in parallel once their listed dependencies are met.

- **Slice 0 (sequential, blocks everything else): Shared controls.** Files:
  `Views/Controls/KeyBadge.xaml(+.cs)`, `PriorityBadge`, `TimeBadge`, `Spinner`, `ToolButton`,
  `SectionHeader` (Components.swift port), `VolarIcon` lookup, `GlassPanel`. Must land before
  Slice 1+. This is wave4-slice.md's implicit prerequisite too (it never names Components.swift
  explicitly, but W-B/W-C cannot compile without `TimeBadge`/`ToolButton`/`Spinner`).

- **Slice 1 (wave4-slice.md's locked scope -- already assigned, not re-proposed here): Today core
  + Popover happy path.** W-A (ViewModels) -> W-B (Today XAML, `TaskRowControl`,
  `SidebarControl`) || W-C (`CapturePopoverControl`, happy-path only per SS1.17's flag). Depends
  on Slice 0. NOTE per SS1.16/1.17's critical flags: confirm with the orchestrator whether "Today"
  here means the flat wave4-slice.md layout or the actual spotlight/NOW-NEXT/drawer layout before
  starting -- this materially changes W-B's scope.

- **Slice 2 || (independent of 3-7, depends only on Slice 0): TaskDetailView.** Single file,
  self-contained sheet, natural follow-on to TaskRow (its trigger). Complexity S-M.

- **Slice 3 || (independent, depends only on Slice 0): Triage + Sweep (paired -- deliberately
  sibling designs, same agent should build both so the intentional symmetry, and the 3 small
  asymmetries flagged in SS1.9/1.10, are handled consistently).** Files: `TriageView`,
  `SweepView` (+ their private row/action sub-structs, contained within each file). Zero AppState
  coupling -- purely closures + `items:` -- the easiest non-trivial slice in the whole inventory
  besides Slice 0's leaf controls. Complexity S-M.

- **Slice 4 || (independent, depends only on Slice 0): TaskBreakdownView.** Single file, hardcoded
  sample content, disabled save button. Complexity S. Lowest-risk slice to hand to a first-time
  agent on this codebase.

- **Slice 5 || (independent, depends on Slice 0's VolarIcon + GlassPanel): OnboardingView.**
  Single file, 3 static steps. Complexity M -- flag the "Allow microphone" step 2 as blocked on a
  product decision (SS1.13 point 2) before the agent reaches it; the agent can still build steps 1
  and 3 and stub step 2's button as a no-op pending that decision.

- **Slice 6 (blocked on a rendering-strategy decision, NOT file-conflicting with anything):
  Waveform.** Single file, zero AppState. Needs the orchestrator to pick a rendering approach
  (Win2D CanvasControl vs. Composition-driven bar animations, SS1.2) before an agent starts, or the
  agent will burn its first pass just exploring options. Once decided, S-M to build.

- **Slice 7 (blocked on a rendering-strategy AND fidelity-scope decision): AmbientBackground.**
  Single file (plus the DELETE-don't-port `SecureImageBookmark` subsystem noted in SS1.14 point 6
  -- confirm that deletion decision explicitly too). Larger version of Slice 6's problem. L.

- **Slice 8 (blocked on a product/hosting decision): MorningFrogView.** Depends on Slice 0. Needs
  a decision on modal-hosting mechanism (ContentDialog vs. overlay-Grid, matching whichever pattern
  the Popover ends up using) before starting. Once decided, M.

- **Slice 9 (blocked on architecture decision, do NOT start without explicit sign-off):
  MenuBarLabel.** Needs a decision on how/whether to represent 3 rich text-bearing states in a
  Windows tray icon (bitmap-generation vs. flyout-window) -- SS1.3's flag. L, and possibly a
  different shape of deliverable than "a XAML view" once decided (could become a small always-
  on-top flyout Window instead of a UserControl).

- **Slice 10 (blocked on architecture decision): FocusOverlay.** Needs a decision on whether
  `FocusIndex` stays a directly-mutable bound property (literal port) or becomes
  `GoToPrevious`/`GoToNext` commands (idiomatic C#/MVVM) -- SS1.12's flag. Also needs the
  looping/keyboard-accelerator infra from Slice 0-adjacent work. L. Explicitly OUT of
  wave4-slice.md, lowest urgency of the "OUT" list since Focus mode is a whole-session feature,
  not a first-open experience.

- **Slice 11 (large, split internally, mostly blocked on app-layer work): SettingsView.**
  Recommend 2 sub-slices once Slice 0 lands: **11a** General/Hotkeys/Notifications/Appearance/
  About tabs (buildable now, M-L) and **11b** Integrations tab (blocked on
  `ClaudeCodeConnector`/`AppLinkHandler`/`volar://`-URI-scheme infra existing on Windows first --
  do not assign until that app-layer plumbing lands, per SS1.15 point 7). 11a can start once Slice
  0 + a `VolarToggle`/`Segmented<T>` decision are made; 11b should be its own later slice, not
  bundled with 11a.

- **Slice 12 (deferred, depends on Slice 1's PopoverView happy path landing first): PopoverView
  full-fidelity follow-up.** Per SS1.17's flag, split further into 12a (chips + conditions +
  dependency picker), 12b (conflict advisory + voice-done card -- also needs `TaskConflict` ported
  from `VolarCore` first), 12c (dictation/cloud consent rows -- 12c's dictation half may be
  entirely N/A depending on the Windows speech-engine strategy, confirm before assigning).

- **Slice 13 (deferred, depends on Slice 1's Today core landing first): TodayView follow-ups.**
  Per SS1.16's flag: 13a `DelegationAmbientSection` (needs `DelegationOrchestratorService`/cluster
  I ported first -- app-layer, not view-layer, blocker) and 13b full NOW-spotlight/NEXT-peek/
  drawer visual fidelity if Slice 1 ships the simpler flat layout first and the spotlight design
  is confirmed as the real target.

---

## 4. SF Symbols inventory (30 `VolarIconName` cases -- no inline `Image(systemName:)` literals
found outside `VolarIcon.swift` itself; every icon reference in every view goes through this one
enum)

**Confidence caveat**: the Segoe Fluent Icons glyph codepoints below are recalled from general
familiarity with the font, NOT verified against the live Character Map / Microsoft's published
glyph list on this pass (no live lookup performed). Treat every "Medium"/"Low" confidence row as
"verify in Character Map (`segoeicons.com` or Microsoft's `Segoe Fluent Icons font` reference
page) before wiring it into XAML" -- a wrong codepoint silently renders an unrelated glyph, not a
build error. High-confidence rows are the handful that are extremely commonly used/documented.

| VolarIconName | SF Symbol | Segoe Fluent glyph (name / codepoint) | Confidence |
|---|---|---|---|
| `.mic` | `mic` | Microphone / E720 | High |
| `.focus` | `scope` | no direct equivalent -- nearest is "Target"/"ScopeTemplate"; consider a custom glyph or repurpose `GpsFixed`-style icon | Low -- verify or use custom |
| `.inbox` | `tray` | Mail / E715, or a dedicated "Inbox" glyph if present in the font | Low |
| `.upcoming` | `calendar` | Calendar / E787 | Medium |
| `.today` | `calendar` | CalendarDay / E184 (distinguish visually from `.upcoming` if both appear together, e.g. Sidebar) | Medium |
| `.plus` | `plus` | Add / E710 | High |
| `.search` | `magnifyingglass` | Zoom / E721 (or "Find", E11A, if present) | Medium |
| `.chevron` | `chevron.right` | ChevronRight / E76C | High |
| `.chevronDown` | `chevron.down` | ChevronDown / E70D | High |
| `.settings` | `gearshape` | Setting / E713 | High |
| `.check` | `checkmark` | Accept / E8FB (or E73E on older MDL2 mapping) | Medium |
| `.clock` | `clock` | Clock / E823 | Medium |
| `.bell` | `bell` | Ringer / E7E7 | Medium |
| `.sparkle` | `sparkles` | "Sparkle"-family glyph is a NEWER Fluent-only addition (not in classic MDL2) -- verify it exists in whichever Segoe Fluent Icons font version ships on the target Windows build | Low |
| `.flag` | `flag` | Flag / E7C1 | Medium |
| `.bolt` | `bolt.fill` | Flash / E945 | Medium |
| `.cmd` | `command` | NO direct Windows equivalent (Mac command-key glyph) -- render as literal text "Ctrl" or a generic key-cap glyph instead of hunting for a symbol | N/A -- needs a design decision, not a glyph |
| `.project` | `folder` | Folder / E8B7 | Medium |
| `.waveform` | `waveform` | NO standard static glyph fits (the app already renders real waveforms via the `Waveform` control, SS1.2) -- this icon case is likely only used as a small static toolbar glyph (TodayView's toolbar); consider `Equalizer`/`BarcodeScanner`-style substitute or a custom vector | Low |
| `.home` | `house` | Home / E80F | High |
| `.back` | `chevron.left` | ChevronLeft / E76B | High |
| `.x` | `xmark` | Cancel / E711 | High |
| `.eject` | `eject.fill` | Eject / E92A | Medium |
| `.pause` | `pause.fill` | Pause / E769 | Medium |
| `.play` | `play.fill` | Play / E768 | Medium |
| `.stop` | `stop.fill` | Stop / E71A | Medium |
| `.volume` | `speaker.wave.2.fill` | Volume / E767 (or a specific "Volume2"/"Volume3" tier glyph if the font distinguishes levels) | Medium |
| `.volumeOff` | `speaker.slash.fill` | Mute / E74F | Medium |

Recommend whoever builds the `VolarIcon` lookup (shared-control manifest item 3) spend 15-20
minutes with Windows' Character Map app filtered to "Segoe Fluent Icons" to confirm every
Medium/Low row above BEFORE other view agents start consuming it -- this is exactly the kind of
"missing glyph mapping stalls a view agent mid-flight" risk the task brief called out, and it is
cheaper to resolve once, centrally, than to have 6 different view agents each independently guess
and diverge.

---

## 5. Gaps that are NOT views -- app-layer/service work needed before certain views can be fully real

1. **Accent-family runtime switching.** `Accents.xaml` has all 4 families (indigo/teal/amber/
   magenta) as static resources, and `AccentSolidBrush`/`HoverBrush`/`SurfaceBrush`/`GlowBrush`
   alias to indigo, but nothing repoints those aliases at runtime when the user picks a different
   family in Settings (`AppState.setAccent`'s only real exerciser, per SS1.15). Needs either a
   `ThemeResource`-swap mechanism, a converter-driven brush selection in every consuming control,
   or a runtime `ResourceDictionary` merge/replace on selection change.
2. **Density runtime switching.** Same story as accent -- `Metrics.xaml` has cozy/comfy/roomy
   values, `AppState.setDensity`'s only real exerciser is also Settings, and nothing currently
   swaps `VolarRowPadY`/`RowGap`/`SectionGap` at runtime.
3. **`volar://` custom URI scheme handling.** Needed by: SettingsView's Integrations tab (Claude
   Code "Send test signal" round-trip), the whole `AppLinkHandler`/`DelegationOrchestratorService`
   feature area (`TodayView`'s `DelegationAmbientSection`), and `AppState.onAppLinkHandled()`'s
   equivalent. Windows needs a registered custom protocol handler + a way to route inbound
   activation args into the already-running single-instance process (named pipe / redirect-to-
   existing-instance pattern) -- no automatic `.onOpenURL` equivalent exists in WinUI 3.
4. **Tray-hosted rich content surface.** `MenuBarLabel`'s 3 states (idle/listening/focus-lock with
   title+countdown) need SOME Windows host -- either a generated tray-icon bitmap set (loses most
   fidelity) or a small anchored flyout/always-on-top window (keeps fidelity, needs its own
   show/hide lifecycle + multi-monitor tray-position logic). This is app-shell work, not a view.
5. **Speech-permission/engine strategy for OnboardingView step 2 and PopoverView's
   dictation-consent row.** Both assume Apple's on-device ASR with a permission-prompt flow that
   has no Windows analog. Needs a product decision (does Windows even have a "mic permission"
   step given the batch-only/stubbed-speech strategy per memory's freemium-speech-backend
   decision?) before either view's speech-adjacent UI can be finished.
6. **`DelegationOrchestratorService`/cluster I (per appstate-inventory.md SS3) itself.** Blocks
   `TodayView`'s `DelegationAmbientSection` and `SettingsView`'s Integrations tab equally -- both
   are UI on top of a service that (per this inventory's read of the codebase) has not been ported
   to C# yet.
7. **`TaskConflict`/VolarCore conflict-check API.** Blocks `PopoverView`'s conflict-advisory row
   (the only view file importing `VolarCore` directly). Confirm this type's C# port status before
   assigning Slice 12b.
8. **Win2D (or an equivalent GPU-composited procedural-drawing path).** Blocks full-fidelity
   `Waveform` and `AmbientBackground`. A scope decision (accept lower fidelity now vs. add the
   Win2D dependency) unblocks both Slices 6 and 7 at once.
9. **A file-path-based (non-bookmark) custom-image storage convention for the ambient background
   and the Claude-Code-directory grant.** Both Mac-side `SecureImageBookmark`/`ClaudeDirBookmark`
   subsystems (AmbientBackground.swift + SettingsView.swift) are App-Sandbox-specific and should
   be DELETED, not ported -- Windows just needs a plain stored path + `FileOpenPicker`/
   `FolderPicker`. Not really a "gap" so much as a simplification opportunity to flag so no agent
   wastes time porting sandbox machinery Windows doesn't need.

---

*End of inventory. 18/18 view files + 3/3 Design files read in full. Two CRITICAL scope
discrepancies flagged (SS1.16 TodayView, SS1.17 PopoverView) between wave4-slice.md's locked
design spec and the actual current Swift source -- resolve those with the orchestrator before
assigning Slice 1's continuation or Slices 12-13.*

