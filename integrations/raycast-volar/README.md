# Volar for Raycast

Two commands, no window, no config: capture a task in Volar without leaving what you're doing.

| Command | What it does |
|---|---|
| **Add Task** | Type the sentence into Raycast's argument field. Volar reads the date, time and priority out of it. |
| **Capture Selection** | Turns the selected text in the frontmost app into a task. |

Both open `volar://capture`, the URL scheme the Mac app already registers — see
[`docs/url-scheme.md`](../../docs/url-scheme.md). There is no server, no file drop, no shared
database. If Volar isn't installed, macOS simply reports it can't open the link.

Volar shows its own confirm card for anything captured this way. You're at your Mac with your eyes
on the screen, so one glance is the cheapest place to catch a mis-parsed date. (Siri and Shortcuts
work differently — they read the parse back aloud, because nobody is looking at a screen. Same rule,
different channel.)

## Why this exists as a separate thing

This isn't really an integration; it's a distribution channel. Raycast is where the people Volar is
built for already spend their day, and a free extension in that store reaches them without Volar
shipping a single per-app integration.

It's TypeScript and touches no Swift, so it can be worked on and released completely independently
of the Mac app's build cycle.

## Development

```bash
cd integrations/raycast-volar
npm install
npm run dev
```

`npm run dev` registers the commands into your local Raycast immediately.

## Before publishing

- [ ] **`icon.png` (512×512) is missing.** Export it from `design/logo/mark.svg` — the repo already
      has `design/logo/render-appicon.mjs` for the app icon; the Raycast icon is a separate, smaller
      export. Raycast's store requires it; local development only warns.
- [ ] Fill in a real `author` — the Raycast store slug, not a display name.
- [ ] Run `npm run lint` and `npm run build` on a Mac. Neither has been run: this extension was
      written on Windows, so nothing here has been executed even once.
