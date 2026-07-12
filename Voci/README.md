# Voci (macOS)

Voice-first, menu-bar task manager for Mac. Dark-only, "Liquid Glass" aesthetic. See
`../docs/app-architecture.md` for the full architecture and frozen contracts, and
`../specs/001-nexttask-engine/plan.md` for the `nextTask()` selection engine this app consumes
from the local `VociCore` Swift package.

**Written on Windows, UNVERIFIED.** This entire app (Phase 1 foundation, Phase 2 views, Phase 3
integration) was written without access to Swift/Xcode and has never been compiled. Expect to fix
compile errors on the first Mac build — see `../backlog.md` for the specific risk areas to check
first (name clashes, Swift 6 concurrency annotations, API availability, etc.).

## Prerequisites

- macOS 26 + Xcode 26 (matches the Swift 6 strict-concurrency toolchain this code targets).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

## Build & run

```sh
cd Voci
xcodegen generate
open Voci.xcodeproj
```

Then build/run the **Voci** scheme in Xcode.

Voci is a menu-bar app (`LSUIElement = true`) — it has no Dock icon or default window. Look for
the mic icon in the menu bar; the main window opens from there ("Open Voci") or via the global
⌃⌥Space hotkey (hold to talk; also opens the window).

## Permissions (first run)

macOS will prompt for these the first time each feature is used:

- **Microphone** — for voice capture.
- **Speech Recognition** — on-device transcription (no audio/transcript ever leaves the machine).
- **Accessibility** — required for the global ⌃⌥Space hotkey to work while another app is
  frontmost. Grant it under **System Settings → Privacy & Security → Accessibility**. Without it,
  the hotkey still works while a Voci window/menu is key, but not system-wide.

## Engine tests

The pure `nextTask()` selection engine lives in the separate `../VociCore` package and has its own
test suite, independent of this app target:

```sh
cd ../VociCore
swift test
```
