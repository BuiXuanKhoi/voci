# Volar (macOS)

Voice-first, menu-bar task manager for Mac. Dark-only, "Liquid Glass" aesthetic. See
`../docs/app-architecture.md` for the full architecture and frozen contracts, and
`../specs/001-nexttask-engine/plan.md` for the `nextTask()` selection engine this app consumes
from the local `VolarCore` Swift package.

**Written on Windows, UNVERIFIED.** This entire app (Phase 1 foundation, Phase 2 views, Phase 3
integration) was written without access to Swift/Xcode and has never been compiled. Expect to fix
compile errors on the first Mac build — see `../backlog.md` for the specific risk areas to check
first (name clashes, Swift 6 concurrency annotations, API availability, etc.).

## Prerequisites

- macOS 26 + Xcode 26 (matches the Swift 6 strict-concurrency toolchain this code targets).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

## Build & run

```sh
cd Volar
xcodegen generate
open Volar.xcodeproj
```

Then build/run the **Volar** scheme in Xcode.

Volar is a menu-bar app (`LSUIElement = true`) — it has no Dock icon or default window. Look for
the mic icon in the menu bar; the main window opens from there ("Open Volar") or via the global
⌃⌥Space hotkey (hold to talk; also opens the window).

## Permissions (first run)

macOS will prompt for these the first time each feature is used:

- **Microphone** — for voice capture.
- **Speech Recognition** — on-device transcription (no audio/transcript ever leaves the machine).
- **Accessibility** — required for the global ⌃⌥Space hotkey to work while another app is
  frontmost. Grant it under **System Settings → Privacy & Security → Accessibility**. Without it,
  the hotkey still works while a Volar window/menu is key, but not system-wide.

## Speech engines (Settings → General → Speech engine)

Three interchangeable `SpeechEngine` implementations (`Sources/Speech/`), freemium-tiered:

- **Apple (on-device)** — `SpeechCapture`, `SFSpeechRecognizer`. Default; private, free, streams
  partial results. Only engine that needs the Speech Recognition permission above.
- **WhisperKit (on-device)** — `WhisperKitEngine`. Free tier alternative; private, batch (no
  partials), Apple Silicon only — downloads/caches a small Whisper model on first use.
- **Groq (cloud)** — `GroqEngine`. Paid tier; batch, sends audio to Groq for best multilingual/
  Vietnamese accuracy. The only engine whose audio leaves the machine.

## Engine tests

The pure `nextTask()` selection engine lives in the separate `../VolarCore` package and has its own
test suite, independent of this app target:

```sh
cd ../VolarCore
swift test
```
