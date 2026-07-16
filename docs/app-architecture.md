# Volar macOS app — architecture & frozen contracts

**Status:** implementation spec authored by Opus (brain). Sonnet agents implement against the
**frozen contracts** below so parallel work stays coherent. All Swift here is written on Windows
and delivered **UNVERIFIED** (no Swift/Xcode on the dev machine — see memory
`build-env-windows-mac-split`). anh Khôi builds & tests on Mac.

Design source of truth: `design/*.jsx` (React prototype). Fidelity choice = **native macOS first**
(keep the design's look/feel and tokens, but prefer standard macOS controls/materials over
pixel-copying CSS). Dark-only, "Liquid Glass" aesthetic, default accent indigo `#6B6BFF`.

Engine: `VolarCore` package already exists (pure `nextTask(from:now:calendar:)` + `Task` value type).
The app **must not** duplicate selection logic — it maps its UI model into `VolarCore.Task` and calls
`nextTask` to compute the single "active" task.

---

## 1. App shape & tech decisions

| Concern | Decision |
|---|---|
| App type | Menu-bar app. `LSUIElement = true`. SwiftUI `MenuBarExtra` (window style) + `Window`/`WindowGroup` scenes. |
| Min OS | macOS 26 (Xcode 26 toolchain), Swift 6 strict concurrency. Matches VolarCore. |
| Scaffold | **XcodeGen** `project.yml` at repo `Volar/`. anh Khôi runs `xcodegen generate` on Mac. Do NOT hand-write `.xcodeproj`. |
| Package dep | App target depends on the local `VolarCore` SwiftPM package (`../VolarCore`). |
| Persistence | **SwiftData** `@Model VolarTask`, mapped to the UI struct `TaskItem` and to `VolarCore.Task`. |
| State | One `@Observable final class AppState` (Observation framework) injected via `.environment`. |
| Speech-in | `SFSpeechRecognizer` (on-device: `requiresOnDeviceRecognition = true`) + `AVAudioEngine` tap → live transcript. |
| NL parse | On-device heuristic `NLParser` (protocol + `HeuristicNLParser`): `NSDataDetector` for dates/times, keyword scan for priority/duration. NO network. The design's "Parsing with AI" is satisfied on-device; a smarter parser is a later swap behind the protocol. |
| Speech-out | `AVSpeechSynthesizer` (read-my-day, voice feedback). |
| Global hotkey | `HotkeyManager` using `NSEvent` global+local monitors for ⌃⌥Space **keyDown → start, keyUp → stop** (hold-to-talk). Needs Accessibility permission — document it, don't block launch. |
| Ambient visuals | SwiftUI `TimelineView(.animation)` + `Canvas` particle systems (rain/snow/fireflies). No Metal. |
| Ambient sound | `AVAudioEngine` with a synthesized noise buffer + low-pass (mirror `useAmbientSound` in `volar-ambient.jsx`). |
| Notifications | `UNUserNotificationCenter` for real reminders; the in-app `NotificationView` is a design artboard (optional preview). |
| Glass | `.ultraThinMaterial` / `.regularMaterial` in a `ZStack` with token tint overlays. Helper `GlassBackground`. |

**Privacy (constitution I):** mic audio + transcript stay on device; no network calls anywhere.

---

## 2. File / target layout (new — under repo `Volar/`)

```
Volar/
  project.yml                     # XcodeGen — app target "Volar" + VolarCore package ref
  Sources/
    App/
      VolarApp.swift               # @main; MenuBarExtra + main Window + Settings scene; AppDelegate
      AppState.swift              # @Observable store (frozen API §4)
    Design/
      Theme.swift                 # palette, accents, density, glass (frozen §3)
      VolarIcon.swift               # icon set (SF Symbols map + custom Shapes for non-SF ones)
      Glass.swift                 # GlassBackground modifier + material helpers
    Model/
      TaskItem.swift              # UI/domain struct (frozen §4) + mapping to VolarCore.Task
      VolarTask.swift              # SwiftData @Model + <-> TaskItem
      TaskStore.swift             # SwiftData container + CRUD; exposes activeTask via VolarCore.nextTask
      NLParser.swift              # protocol + HeuristicNLParser + ParsedTask
      SampleData.swift            # ports SAMPLE_TASKS / SAMPLE_TRANSCRIPT_PARSED for previews & first run
    Speech/
      SpeechCapture.swift         # SFSpeechRecognizer + AVAudioEngine -> transcript stream
      VoicePlayback.swift         # AVSpeechSynthesizer wrapper (readDay, feedback)
      HotkeyManager.swift         # global ⌃⌥Space hold monitor
    Audio/
      AmbientSound.swift          # synthesized rain/snow/embers loop
    Views/
      TodayView.swift             # main window: sidebar + Today list + greeting + frog/focus pill
      Sidebar.swift               # capture button + Focus nav + on-device footer
      TaskRow.swift               # single row (checkbox, title, priority, dur, frog dot, time badge)
      Components.swift            # KeyBadge, PriorityBadge, TimeBadge, Spinner, ToolButton, SectionHeader
      PopoverView.swift           # 5-state quick capture
      Waveform.swift              # animated bars (TimelineView) + settled state
      FocusOverlay.swift          # fullscreen one-task focus
      AmbientBackground.swift     # Canvas particle background + vignette
      MenuBarLabel.swift          # menu-bar icon: idle | listening(REC) | focuslock(title·timer)
      OnboardingView.swift        # 3 steps
      SettingsView.swift          # 5 tabs (General/Hotkeys/Notifications/Appearance/About) + Toggle/Segmented/KeyRecorder
      MorningFrogView.swift       # good-morning modal
      TaskBreakdownView.swift     # AI breakdown artboard
      NotificationView.swift      # in-app notification artboard (optional)
  Resources/
    Info.plist                    # LSUIElement, NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription
    Volar.entitlements             # app sandbox (if used): mic; else non-sandboxed for global hotkey
    Assets.xcassets/              # AppIcon placeholder, AccentColor
```

---

## 3. FROZEN — Design tokens (`Theme.swift`)

Port `design/tokens.jsx`. All colors are **dark-only** literals. Use `Color(red:green:blue:opacity:)`
(sRGB, 0–1). rgba(255,255,255,a) → white at opacity a.

```
enum VolarColor {   // static let … : Color
  bg=#1C1C1E  surface=#2C2C2E  surfaceHi=#3A3A3C
  card=white@0.05  cardHover=white@0.08  border=white@0.08  borderHi=white@0.14
  textPri=white@0.88  textSec=white@0.45  textMut=white@0.25
  high=#FF6B6B  med=#FFB347  low=white@0.30  destruct=#FF453A  done=#5BD17A
}

struct Accent { let solid, hover, surface, glow: Color }
enum VolarAccent: String, CaseIterable, Identifiable { case indigo, teal, amber, magenta
  // indigo solid#6B6BFF hover#8B8BFF surface=solid@0.15 glow=solid@0.45
  // teal   solid#3DD5C7 hover#6FE3D8 …
  // amber  solid#FFB547 hover#FFC76B …
  // magenta solid#FF6BD0 hover#FF8BD9 …
  var accent: Accent { … }
}

enum Density { case cozy, comfy, roomy   // rowPadY/rowGap/sectionGap = (7,3,18)/(10,4,22)/(14,6,30) }
enum GlassLevel { case subtle, standard, heavy   // blur/bgOpacity = 14/0.92, 24/0.78, 36/0.55 }
```

Fonts: system (`Font.system(size:weight:)`), monospaced via `.monospaced` design (tabular numbers →
`.monospacedDigit()`). Default: accent = `.indigo`, density = `.comfy`, glass = `.standard`.

`VolarIcon`: expose `VolarIcon(_ name: VolarIconName, size:, color:, weight:)` → `View`. Map to SF Symbols
where a clean equivalent exists (mic→"mic", focus→"scope", inbox→"tray", today/upcoming→"calendar",
plus→"plus", search→"magnifyingglass", check→"checkmark", clock→"clock", bell→"bell",
sparkle→"sparkles", flag→"flag", bolt→"bolt.fill", play→"play.fill", pause→"pause.fill",
stop→"stop.fill", volume→"speaker.wave.2.fill", volumeOff→"speaker.slash.fill", x→"xmark",
back→"chevron.left", chevron→"chevron.right", waveform→"waveform", settings→"gearshape",
cmd→"command", home→"house", project→"folder"). Keep the name enum stable so views can request icons
by role.

---

## 4. FROZEN — Domain model & AppState API

Views depend ONLY on these signatures. Do not change names/shapes in phase-2 agents.

```swift
enum Priority: Int, Sendable { case high = 1, medium = 2, low = 3 }   // maps to VolarCore priority Int
enum When: Sendable { case now, later }

struct TaskItem: Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    var priority: Priority
    var status: TaskStatus        // typealias to VolarCore.TaskStatus (.todo/.inProgress/.done/.archived)
    var deadline: Date?
    var dependsOn: [UUID]
    var createdAt: Date
    var when: When                // UI bucket (Now / Later today), as in the prototype
    var durationMinutes: Int?     // -> "dur" label ("45 min", "1 hr")
    var frog: Bool                // "frog of the day"
    // Derived: var done: Bool { status == .done }
    // Derived: var timeBadge: String?  (formatted deadline time, nil when none/done)
    // Derived: var durationLabel: String?
    func toEngineTask() -> VolarCore.Task   // maps into the engine value type
}

@Observable @MainActor final class AppState {
    var tasks: [TaskItem]
    var accent: VolarAccent
    var density: Density
    var glass: GlassLevel
    var ambient: AmbientMode            // .none/.rain/.snow/.embers/.custom
    var customImageURL: URL?
    var voiceFeedback: Bool

    // Capture / popover
    enum CaptureState { case idle, recording, parsing, parsed, saving, done, error }
    var captureState: CaptureState
    var liveTranscript: String
    var parsed: ParsedTask?
    func startCapture(); func cancelCapture(); func confirmSave()

    // Focus session
    var focusActive: Bool
    var focusPaused: Bool
    var focusSecondsLeft: Int           // default 25*60
    var focusIndex: Int
    func startFocus(); func endFocus(); func toggleFocusPause(); func completeFocusTask(_ id: UUID)

    // Derived task groupings (computed)
    var nowTasks: [TaskItem]            // !done && when == .now
    var laterTasks: [TaskItem]          // !done && when == .later
    var doneTasks: [TaskItem]
    var openTasks: [TaskItem]           // now + later
    var frogTask: TaskItem?

    // THE integration point with feature 001:
    var activeTask: TaskItem?           // == nextTask(from: tasks.map{$0.toEngineTask()}, now: .now)

    func addTask(_ t: TaskItem); func toggleDone(_ id: UUID); func deleteTask(_ id: UUID)
    func readDayAloud()
}

struct ParsedTask: Sendable {   // NLParser output; mirrors SAMPLE_TRANSCRIPT_PARSED.parsed
    var title: String; var when: String; var priority: Priority
    var durationMinutes: Int?; var context: String?
}
protocol NLParser { func parse(_ transcript: String) -> ParsedTask }
struct HeuristicNLParser: NLParser { … }   // NSDataDetector + keyword rules, on-device
```

`activeTask` is highlighted as the first "Now" row, is the Focus target, and is what the menu-bar
single-task label shows. This is the only place the app consumes `VolarCore.nextTask`.

---

## 5. FROZEN — shared Components signatures (`Components.swift`)

```
KeyBadge(_ text: String, accent: Bool = false)                 // ⌃ ⌥ Space chips
PriorityBadge(_ priority: Priority)                            // dot + High/Medium/Low pill
TimeBadge(_ text: String, filled: Bool = false)               // accent time pill
Spinner(color: Color)                                         // rotating ring
ToolButton(icon: VolarIconName, accent: Bool=false, tint: Bool=false, action: ()->Void)
SectionHeader(_ title: String, count: Int?, accent: Bool=false) // "NOW", "LATER TODAY", "COMPLETED"
GlassBackground(level: GlassLevel = .standard)                 // ViewModifier / background view
```

Animations: use `.animation`/`withAnimation`; pulse via `TimelineView` or repeating `withAnimation`.
Keep motion subtle (design uses ~0.12–0.18s ease).

---

## 6. Fidelity mapping (CSS → SwiftUI), native-first

| Prototype (CSS) | SwiftUI |
|---|---|
| `backdrop-filter: blur()` glass panels | `.background(.ultraThinMaterial)` + token tint overlay; `GlassBackground` |
| `border: 0.5px solid …` | `.overlay(RoundedRectangle().stroke(color, lineWidth: 0.5))` |
| `border-radius` | `.clipShape(RoundedRectangle(cornerRadius:))` / `RoundedRectangle` |
| `box-shadow` glow | `.shadow(color: accent.glow, radius:, y:)` |
| `fontVariantNumeric: tabular-nums` | `.monospacedDigit()` |
| Waveform `requestAnimationFrame` sines | `TimelineView(.animation) { Canvas … }` layered sines |
| Rain/snow/embers canvas | `TimelineView(.animation) { Canvas … }` particle arrays (port constants from `volar-ambient.jsx`) |
| `position:absolute; inset:0` overlays | `ZStack` full-bleed layers |
| Traffic lights | Real macOS window chrome (don't draw them); artboard-only views may draw them |
| Hover states | `.onHover` |

---

## 7. Phase plan (how Sonnet executes)

- **Phase 1 — Foundation (1 Sonnet agent, run first, blocking):** `project.yml`, `Info.plist`,
  `Theme.swift`, `VolarIcon.swift`, `Glass.swift`, `TaskItem.swift`, `VolarTask.swift`, `TaskStore.swift`,
  `NLParser.swift`, `SampleData.swift`, `AppState.swift`, `VolarApp.swift` (scenes wired; view bodies may
  be temporary stubs), `Components.swift`. Must compile-shape against §3–§5 exactly. Opus reviews &
  freezes before Phase 2.
- **Phase 2 — Views (parallel Sonnet agents, each given the frozen §3–§6):**
  - A: `TodayView` + `Sidebar` + `TaskRow`.
  - B: `PopoverView` + `Waveform` + `SpeechCapture` wiring.
  - C: `FocusOverlay` + `AmbientBackground` + `AmbientSound` + `VoicePlayback` + `HotkeyManager`.
  - D: `SettingsView` (+Toggle/Segmented/KeyRecorder) + `OnboardingView` + `MorningFrogView` +
       `TaskBreakdownView` + `MenuBarLabel` + `NotificationView`.
- **Phase 3 — Integration & handoff (Opus):** wire all views into `VolarApp`, reconcile any contract
  drift, write `Volar/README.md` build steps (`xcodegen generate && open Volar.xcodeproj`), add backlog
  entries (Mac build unverified; Accessibility permission for hotkey; smarter NL parser; real ambient
  sound polish).

Everything ships UNVERIFIED pending the Mac build, consistent with the repo's established pattern.
