# Voci — design reference (pulled from claude.ai/design)

Source: claude.ai/design project **"Voci"** (id `c591756b-59dc-48b0-b065-3654657e55c1`), owner Khoi.
Pulled 2026-07-12 via DesignSync into this repo as **visual/UX reference only**.

These are React/JSX prototype components (Babel-in-browser via `index.html`) plus design tokens.
They are **NOT production code and NOT SwiftUI** — use them as the spec for building the native
macOS SwiftUI UI later. Open `index.html` in a browser to view the interactive prototype.

## Files

| File | What it is |
|---|---|
| `tokens.jsx` | Design tokens — palette, fonts, icon set (`VocIcon`), density/glass presets, sample data |
| `macos-window.jsx` | macOS "Liquid Glass" (Tahoe) window chrome primitives |
| `voci-mac.jsx` | **Main macOS app** — Today view, sidebar, hotkey ⌃⌥Space, popover overlay, Focus mode |
| `voci-popover.jsx` | Quick-capture popover (5 states: recording → parsing → parsed → saving → done/error) |
| `voci-focus.jsx` | Fullscreen one-task Focus mode overlay |
| `voci-ambient.jsx` | Ambient focus backgrounds (rain/snow/fireflies), Web-Audio sound, speech synthesis |
| `voci-extras.jsx` | Menu-bar icon states, onboarding, settings, notification, morning frog, task breakdown |
| `voci-app.jsx` | Canvas assembly — wires all artboards + Tweaks panel (the `App` entry) |
| `voci-mobile.jsx` | iOS companion (v1.0 is macOS-only; **parked** reference) |
| `ios-frame.jsx` | iOS 26 device frame primitives (reference only) |
| `design-canvas.jsx` | The Figma-ish canvas wrapper (design-tool scaffolding, not product UI) |
| `tweaks-panel.jsx` | Tweaks panel + form controls (design-tool scaffolding) |
| `index.html` | Entry point — loads React + Babel + all of the above |

## Not pulled
- `screenshots/*.png`, `.thumbnail` — binary; download directly from claude.ai/design if needed.
- `.design-canvas.state.json` — design-tool layout state, not useful as reference.

## Notes for the SwiftUI build
- Dark-only, "Liquid Glass" aesthetic; accent default = indigo `#6B6BFF`.
- Core screens to port first: `voci-mac.jsx` (Today + single active task), `voci-popover.jsx`
  (quick capture / confirm chips), `voci-focus.jsx` (one-task focus). These map to spec §7 and
  the single-task menu-bar model that feature 001's `nextTask()` engine powers.
