# Implementation Plan: One Source Tree, Three Apple Platforms

**Branch**: `macos` → becomes trunk (project convention — no feature branches) | **Date**: 2026-08-09

**Scope**: macOS + iOS + watchOS share one Swift source tree, build as three binaries, ship as
**one** App Store Connect record. The Windows port (`window` branch, C#/.NET 10/WinUI 3) stays on
its own branch by explicit decision and is **out of scope** for this plan except for one shared-
ownership rule (§8).

**Prior art**: the `ios` branch already performed this split once on 2026-07-27
(`specs/004-ios-port/plan.md`). That split is the basis of the classification below, but it has
drifted 40 commits behind trunk and never classified the 16 files added since. This plan
reconciles it rather than starting over.

---

## Summary

`Volar/Sources` holds 79 Swift files ≈ 32,000 lines. The survey in §2 classifies every one of them:

| | Files | Lines | Share |
|---|---|---|---|
| **Shared** — compiled by all three targets | 55 | ≈ 18,990 | 59% |
| **macOS-only** — windowing, menu bar, chrome | 24 | ≈ 12,970 | 41% |

The entire platform-neutrality cost is **18 `#if os()` guards across 6 files** — a number measured,
not estimated: those guards already exist and compile on the `ios` branch. Nothing needs
rearchitecting. `VolarCore` needs a one-line change.

The work is therefore not "make the code portable" — it is largely portable already. The work is
**reconciling two drifted copies of it and classifying 16 unclassified files**, then adding a
watchOS target.

---

## 1. Technical Context

**Language**: Swift 6.x strict concurrency, SwiftUI. **Floors**: macOS 14, iOS 17, watchOS 10.

**Build**: XcodeGen (`project.yml` per app) → Xcode. Swift builds only on Mac; every phase below is
tagged **[Win]** (doable on Windows today) or **[Mac]** (needs the Mac).

**Target layout after migration**:

```
VolarCore/            SPM package, dependency-free   → all 3 platforms
Shared/               55 platform-neutral files      → compiled by all 3 app targets
Volar/Sources/        24 macOS-only files            → macOS target
VolarIOS/Sources/     8 iOS-only files (exists)      → iOS target
VolarWatch/Sources/   new                            → watchOS target, embedded in iOS .ipa
```

**Classification rule**: a file is macOS-only if it manages a *window, panel, menu bar, global
hotkey, or host filesystem*. Everything else — models, parsing, scheduling, networking, speech,
account, and any view that renders inside a container it does not own — is shared.

---

## 2. Source survey — the shared/platform split

Legend: **S** = `Shared/` · **M** = macOS-only · **⚠** = new since the 2026-07-27 split, never
classified before · **#n** = number of `#if os()` guards needed

### Account/ — 3 files, 524 lines

| File | Lines | | Note |
|---|---|---|---|
| `AccountModels.swift` | 142 | **S** | clean |
| `AccountService.swift` | 304 | **S** #2 | guards exist on `ios` branch |
| `KeychainStore.swift` | 78 | **S** | clean |

### App/ — 4 files, 7,137 lines

| File | Lines | | Note |
|---|---|---|---|
| `AppState.swift` | 6,359 | **S** #4 | The central store. Imports AppKit but only **6 call sites** (`NSApplication.didBecomeActiveNotification`, `NSWorkspace.shared.open`, 4 in comments). Guards already proven on `ios` branch. |
| `VolarApp.swift` | 660 | **M** | `MenuBarExtra`, `NSPanel`, `NSWindow`, `NSApplication` |
| `LoginItem.swift` | 56 | **M** ⚠ | launch-at-login is a macOS-only concept |
| `WindowChrome.swift` | 62 | **M** ⚠ | `NSViewRepresentable`, `NSPanel` |

### Audio/ — 1 file, 143 lines — all **S** (`AmbientSound.swift`, clean)

### Design/ — 3 files, 484 lines — all **S**

`Glass.swift` 63 · `Theme.swift` 354 · `VolarIcon.swift` 67. `Theme.swift` mentions
`NSStatusItem`/`MenuBarExtra` **in comments only** — verified by the `ios` branch compiling it
unguarded. Do not add guards on the strength of a grep hit.

### Integrations/ — 2 files, 592 lines

| File | Lines | | Note |
|---|---|---|---|
| `CalendarAccess.swift` | 160 | **S** #2 | EventKit permission flow differs per platform |
| `CalendarSync.swift` | 432 | **S** | clean |

### Model/ — 13 files, 3,278 lines — **all S, all clean, zero guards**

`CompletionLog` 101 · `Entitlements` 321 · `NLParser` 729 · `ParseCorrection` 70 · `Recurrence`
244 · `ReminderRecord` 335 · `SampleData` 70 · `TaskCue` 48 ⚠ · `TaskItem` 178 · `TaskSections` 81
· `TaskStore` 585 · `VolarTask` 342 · `WaitingMode` 174 ⚠

This folder plus `Parsing/` is 6,672 lines that move with zero edits.

### Orchestrator/ — 3 files, 934 lines

| File | Lines | | Note |
|---|---|---|---|
| `AppLinkHandler.swift` | 235 | **S** | `volar://` handling is platform-neutral |
| `DelegationTracker.swift` | 280 | **S** | clean |
| `ClaudeCodeConnector.swift` | 419 | **M** | `NSOpenPanel` + security-scoped bookmark to `~/.claude`; no host filesystem on iOS/watchOS |

### Parsing/ — 6 files, 3,394 lines — **all S, all clean, zero guards**

`CloudParser` 833 · `ConfigParseCredentialProvider` 72 · `DeviceCheckProvider` 218 ·
`FoundationModelParser` 701 · `IntentParsing` 1,462 · `ParsedCapture` 108 ⚠

### Reminders/ — 8 files, 1,615 lines

| File | Lines | | Note |
|---|---|---|---|
| `ReminderScheduler.swift` | 927 | **S** #3 | guards exist on `ios` branch |
| `FullScreenEscalationDecision.swift` | 98 | **S** ⚠ | pure decision logic, already has its own test file |
| `CueFiring.swift` | 93 | **S** ⚠ | pure logic, has tests |
| `NotificationActions.swift` | 84 | **S** | clean |
| `ReminderContextGate.swift` | 59 | **S** | clean |
| `VoiceReminderChannel.swift` | 32 | **S** | clean |
| `FullScreenTakeoverWindow.swift` | 249 | **M** ⚠ | `NSPanel`, `NSScreen`, `NSHostingView` |
| `MicrophoneActivityMonitor.swift` | 73 | **M** ⚠ | **VERIFY on Mac** — if it is pure CoreAudio device polling it may be shareable; classified M until read |

Note the shape here: the *decision* whether to escalate is shared; only the *window that escalates*
is macOS-only. Keep that seam — iOS and watchOS reuse the decision and present it as a
notification instead.

### Speech/ — 9 files, 1,793 lines

| File | Lines | | Note |
|---|---|---|---|
| `SpeechCapture.swift` | 396 | **S** #5 | most-guarded file; guards exist on `ios` branch |
| `WhisperKitEngine.swift` | 246 | **S** + `#if canImport(WhisperKit)` | **watchOS cannot link WhisperKit** — see §6 trap 1 |
| `VoiceDone.swift` | 278 | **S** | clean |
| `GroqTranscriptionClient.swift` | 220 | **S** | clean |
| `GroqEngine.swift` | 197 | **S** | clean |
| `SpeechEngine.swift` | 56 | **S** | protocol |
| `VoicePlayback.swift` | 47 | **S** #2 | `AVAudioSession` is iOS/watchOS-only |
| `MicrophonePermission.swift` | 42 | **S** ⚠ #1? | `AVCaptureDevice` path differs; verify |
| `HotkeyManager.swift` | 311 | **M** | Carbon `RegisterEventHotKey` / `NSEvent` — no global hotkey on iOS/watchOS |

### Views/ — 27 files, 11,142 lines

**Shared (7 files, 925 lines)** — components that render inside a container they do not own:

`Components.swift` 223 · `TaskRow.swift` 175 · `Waveform.swift` 89 · `NotificationView.swift` 86 ·
`DiffRow.swift` 118 ⚠ · `EmailSignInForm.swift` 130 ⚠ · `SignInSheet.swift` 104 ⚠

The first four are already in `Shared/Views` on the `ios` branch. The three ⚠ are new, grep-clean,
and are exactly the kind of leaf component iOS needs verbatim — classify them S.

**macOS-only (20 files, 10,217 lines)**:

`PopoverView` 2,558 · `SettingsView` 1,727 · `TodayView` 1,525 · `FocusOverlay` 742 ·
`TaskDetailView` 709 · `PaywallView` 454 ⚠ · `OnboardingView` 450 · `AmbientBackground` 417 ·
`TourOverlay` 389 · `Sidebar` 358 · `TaskBreakdownView` 314 · `TextCapturePanel` 243 ⚠ ·
`SweepView` 224 · `TriageView` 221 · `MorningFrogView` 196 · `CapturePanel` 183 · `MenuBarLabel`
158 · `CommandBar` 143 ⚠ · `TourModel` 87 · `TourAnchor` 44

Two deliberate calls here:

- **`PaywallView` (454) stays M, but its logic does not.** iOS needs a paywall too. Do **not** try
  to share the view — share `Model/Entitlements.swift` (already S) and let each platform draw its
  own. A paywall rendered for a 1,200pt Mac window is wrong on a 390pt phone and absurd on a watch.
- **`TourModel` (87) + `TourAnchor` (44) are shareable in principle** — they are state machines, not
  chrome. Left M in this plan to keep Phase 0 mechanical. Revisit when iOS wants onboarding.

### VolarCore/ — 6 files, separate package

`Condition` · `ConflictCheck` · `DependencyGraph` · `NextTask` · `Snapshots` · `Task`. Zero
dependencies, zero platform API use, 8 test files. Already portable — see Phase 1.

---

## 3. Current state of each platform

| | Source | Target | Buildable | Submittable |
|---|---|---|---|---|
| **macOS** | `Volar/Sources`, 79 files | `Volar/project.yml` ✅ | ✅ builds & tests on Mac | ✅ bundle `tech.kioh.Volar`, SKU `volar-macos-001`, metadata drafted |
| **iOS** | `Shared/` (43 files, **40 commits stale**) + `VolarIOS/Sources` (8 files) | `VolarIOS/project.yml` ✅ | ❓ never built | ❌ **bundle ID wrong** — see Phase 2 |
| **watchOS** | — | — | ❌ | ❌ |

The iOS app's 8 existing files (`VolarIOSApp`, `RootTabView`, `TodayIOSView`, `CaptureSheet`,
`MicFAB`, `MobileTaskCard`, `SettingsIOSView`, `IOSMetrics`) are the iOS equivalent of `App/` +
`Views/` — the split was done correctly, it just needs re-basing onto current trunk.

### The 16 files added since the split — the real gap

These exist on trunk and were never classified. Phase 0 must place each one:

**→ Shared (10)**: `TaskCue` · `WaitingMode` · `ParsedCapture` · `CueFiring` ·
`FullScreenEscalationDecision` · `MicrophonePermission` · `DiffRow` · `EmailSignInForm` ·
`SignInSheet` · *(pending verify)* `MicrophoneActivityMonitor`

**→ macOS-only (6)**: `LoginItem` · `WindowChrome` · `FullScreenTakeoverWindow` · `CommandBar` ·
`PaywallView` · `TextCapturePanel`

---

## 4. Phase 0 — reconcile into one tree **[Mac]**

The hard phase. Two copies of the same code exist; they must become one without a moment where
both are compiled (duplicate symbols).

**Order matters. Do not reorder.**

1. Merge `ios` into trunk. On every conflicted Swift file take **trunk's content** (newer by 40
   commits) and **`Shared/`'s path** (the target layout). `Shared/` is a directory move, not a
   content merge.
2. Move the 55 shared files from `Volar/Sources` → `Shared/`, preserving folder names. Use
   `git mv` so history follows.
3. Apply the 18 `#if os()` guards to the 6 files in §2. Copy them from the `ios` branch verbatim —
   they already compile there. Re-derive nothing.
4. Place the 16 unclassified files per §3.
5. `Volar/project.yml`: change `sources:` to `- path: ../Shared` **and** `- path: Sources`.
6. **Delete** the moved copies from `Volar/Sources`. Steps 5 and 6 are one commit — a tree where
   both `Shared/` and `Volar/Sources` hold the same type is a duplicate-symbol build failure. The
   warning is already written at the top of `VolarIOS/project.yml`; heed it.
7. Move app-layer tests that cover shared code from `Volar/Tests` to a target both apps can run.
   26 test files exist; `CueFiringTests`, `WaitingModeTests`, `FullScreenEscalationDecisionTests`,
   `ReminderSchedulerTests`, `CloudParserTests`, `TaskSectionsTests` and peers all test **S** code.

**Acceptance gate — non-negotiable**: `xcodebuild test` green for the macOS scheme, and
`xcodegen generate` + build green for `VolarIOS`. Do not commit on a red build. If the merge is
half-done at end of session, leave it uncommitted rather than commit a tree that compiles neither.

---

## 5. Phase 1 — VolarCore goes multi-platform **[Win]**

`VolarCore/Package.swift:6` currently reads `platforms: [.macOS(.v13)]`. The package has **zero
dependencies** and touches no platform API. Change to:

```swift
platforms: [.macOS(.v13), .iOS(.v17), .watchOS(.v10)]
```

That is the whole phase. Verify by reading the 6 sources for any Foundation-only assumption; there
should be none.

---

## 6. Phase 2 — identity, before any submission **[Win]**

| What | From | To |
|---|---|---|
| `VolarIOS/project.yml:65` `PRODUCT_BUNDLE_IDENTIFIER` | `tech.kioh.Volar.ios` | **`tech.kioh.Volar`** |
| watchOS target bundle ID | — | `tech.kioh.Volar.watchkitapp` (Apple requires the iOS ID as prefix) |
| Developer portal | — | reuse existing App ID `tech.kioh.Volar`; add iOS capabilities to it. **Do not create a new App ID.** |

**Why this cannot slip**: identical bundle IDs on iOS and macOS are the sole precondition for
Universal Purchase — one App Store record, one subscription group, one purchase unlocking all three
platforms. Ship `tech.kioh.Volar.ios` once and the ID is locked forever; merging later means
abandoning the record and every review on it.

The existing SKU `volar-macos-001` is fine as-is — SKUs are internal, immutable, and do not
constrain which platforms a record carries. Do not try to "fix" it.

---

## 7. Phase 3 — the watchOS target **[Mac]**

The watch app is a **target inside `VolarIOS/project.yml`**, not its own XcodeGen project, because
the iOS app must embed it at archive time:

```yaml
VolarWatch:
  type: application
  platform: watchOS
  deploymentTarget: "10.0"
  sources: [{path: ../Shared}, {path: Sources}]

VolarIOS:
  dependencies:
    - target: VolarWatch
      embed: true
```

**Three traps, all load-bearing:**

1. **WhisperKit will not link on watchOS.** `Shared/Speech/WhisperKitEngine.swift` must be wrapped
   in `#if canImport(WhisperKit)` *and* the package dependency omitted from the watch target.
   Without this the watch target fails at link, not compile — a confusing failure late in the build.
2. **Speech input on watch is not an engine.** Use the system `presentTextInputController`
   (dictation/scribble), which returns finished text. Feed that straight into the existing
   `CloudParser`. No STT engine on the watch at all.
3. **Data reaches the watch over `WCSession`, not the cloud.** WatchConnectivity is a direct
   phone↔watch link — it needs no server and no paid-tier sync. `Shared/Model/TaskStore.swift`
   gains one more load path. *(This corrects an earlier assumption that watchOS was blocked on
   cloud sync — it is not. Only "use the watch with no iPhone nearby" needs cloud sync.)*

Also absent on watch by definition: `App/` (no windows), global hotkey, full-screen takeover. Cue
escalation becomes a local notification plus haptic — arguably the strongest ADHD surface in the
product, and the reason this phase is worth doing.

---

## 8. Windows — the one rule that still applies

`window` stays a separate branch (anh Khôi, 2026-08-09). The cost is already visible: **9 files
under `supabase/` have been edited on both branches**, including `functions/parse/index.ts`,
`_shared/quota.ts`, `_shared/auth.ts`, `_shared/appstore.ts`, `_shared/http.ts`,
`functions/subscription/index.ts`, `functions/groq/index.ts`, `config.toml`, and migration
`0002_accounts_entitlements.sql`. There is one production Supabase project; whichever branch
deploys last silently overwrites the other.

**Rule**: `supabase/` has exactly one owner — **trunk**. The `window` branch reads it and never
edits it; backend changes Windows needs are made on trunk and cherry-picked over.

Separately, `0002_accounts_entitlements.sql` must stop being edited on either branch — it is already
applied, so edits change nothing in the real database and only make two branches believe in two
imaginary schemas. Any correction goes in a new `0005_` migration.

---

## 9. Submission — 3 builds, 2 uploads, 1 app

```
BUILD (3 binaries)          UPLOAD (2)        APP STORE CONNECT (1 record)
Volar.app      (macOS) ──→  .pkg  ─────────┐
VolarIOS.app   (iOS)   ─┐                  ├──→  "Volar AI" / tech.kioh.Volar
VolarWatch.app (watch) ─┴─→ .ipa  ─────────┘      ├── iOS App    (screenshots: iPhone + Watch)
   ↑ embedded inside the .ipa                     └── macOS App  (screenshots: Mac)
```

- watchOS is **not** a third upload and **not** a third platform section — it ships inside the iOS
  `.ipa` and appears only as an extra screenshot slot under the iOS section.
- Each platform has its own version string and its own build list; they may differ and release on
  different days.
- Apple reviews the iOS submission (watch included) and the macOS submission **independently** — a
  rejection on one does not block the other.
- Build numbers increment per platform; they need not match across platforms.

---

## 10. Execution order & ownership

| Phase | Where | Needs Mac | Depends on |
|---|---|---|---|
| **1** VolarCore platforms | `VolarCore/Package.swift` | no | — |
| **2** Bundle ID + App ID | `VolarIOS/project.yml`, portal | no | — |
| **0** Reconcile `Shared/` | whole Swift tree | **yes** | — |
| **3** watchOS target | `VolarIOS/project.yml`, `VolarWatch/` | **yes** | Phase 0 |
| **4** Submit | App Store Connect | **yes** | 0–3 |

Phases 1 and 2 are config-only and can be done today on Windows; they are independent of Phase 0
and of each other. Phase 0 is the only phase with real risk and must not be rushed to a commit.

Per project convention: design and classification decisions in this document are settled; execution
(file moves, guard insertion, YAML edits) goes to Sonnet with this plan as the instruction.

---

## 11. Open questions

1. `Reminders/MicrophoneActivityMonitor.swift` (73 lines) — read on Mac; if it is CoreAudio device
   enumeration with no AppKit, reclassify **S** (watchOS has no equivalent API, so it would need a
   `#if os(macOS)` body regardless).
2. Onboarding on iOS — reuse `TourModel`/`TourAnchor` as shared state machines with a new iOS view,
   or write a separate flow? Deferred; does not block any phase.
3. Does the watch app need to run without a paired iPhone at launch? If yes, it blocks on cloud sync
   (paid tier). If no — the recommendation — `WCSession` suffices and Phase 3 can proceed now.
