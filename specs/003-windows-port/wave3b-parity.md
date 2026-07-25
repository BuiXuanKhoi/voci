# Wave 3-B — Parity gaps, logic layer (4 agents, file-disjoint, parallel)

Source of truth: parity audit 2026-07-25 (see `backlog.md` item ★★★★★ PARITY AUDIT).
Goal of this wave: close every **logic-layer** difference between the macOS app and the
Windows port, so that Wave 3-C (services + wiring) and Wave 4 (views) have nothing left to
invent. Views are NOT in this wave.

Branch `window` has just merged `macos` (merge commit `4fa783d`), so the Swift sources inside
this worktree (`Volar/Sources/**`, `VolarCore/**`) ARE the current, post-review macOS code.
**Port from the Swift in THIS worktree** — do not consult any other checkout.

## Rules for every agent in this wave

1. **Read the Swift reference first**, in full, before writing C#. Port behaviour, not syntax:
   same thresholds, same ordering, same edge cases, same fail-closed decisions. Where the Swift
   has a comment explaining WHY (`FIX A`, `// UNVERIFIED`, threat-model notes), carry the
   reasoning across into the C# doc comment.
2. **Touch only the files in your own list.** If you need a change in a file another agent owns,
   DO NOT make it — report it in your final message as "requires <file>: <change>".
3. **Nobody in this wave touches `windows/src/Volar.App/**`** — not `CompositionRoot.cs`, not
   `Stubs/*.cs`, not `MainWindow.*`. Wave 3-C swaps the stubs and does all DI wiring. Your new
   types must therefore be constructible without any App-layer change, and the solution must
   still build with the stubs in place.
4. **Layering** (do not add project references beyond these): `Volar.Domain` -> Core;
   `Volar.Parsing` / `Volar.Reminders` / `Volar.Orchestrator` -> Core + Domain; `Volar.Data` ->
   Core; `Volar.Speech` -> **nothing** (keep it dependency-free; inject readers/delegates
   instead of referencing other projects).
5. **Tests are part of the deliverable.** xUnit, mirroring the existing style
   (`windows/tests/Volar.*.Tests`, `Fixtures.cs` + `Fake*.cs` doubles, no mocking framework).
   Deterministic time only — inject `DateTimeOffset now` / a clock, never `DateTimeOffset.Now`
   inside logic.
6. **Acceptance:** `dotnet build windows/Volar.Windows.sln -c Release` = 0 warning / 0 error,
   and `dotnet test` green for your own test project **and** every pre-existing test project
   (567 tests were green before this wave — no regressions).

### Self-review before you return (state each explicitly in your final message)

1. **Parity** — list every Swift symbol you ported and its C# counterpart; name anything you
   deliberately did NOT port and why.
2. **Behaviour drift** — where .NET forced a different mechanism than Swift, say what could
   behave differently at runtime and how a Wave 3-C/4 caller would notice.
3. **Security / privacy** — no transcript, token, or file path logged; every credential path
   fail-closed; caps and limits preserved from the Swift.
4. **Determinism** — no `DateTimeOffset.Now` / `Random` / culture-dependent parsing inside
   logic; culture-invariant string handling where the Swift was locale-independent.
5. **Tests** — what you asserted, what you could NOT cover and why.
6. **Handoff** — exact list of DI registrations / settings keys / seams Wave 3-C must wire, and
   any "requires <file>" item from rule 2.

---

## A1 — `Volar.Voice`: voice-done, the whole US3 intent layer

**Gap:** macOS `Volar/Sources/Speech/VoiceDone.swift` has no Windows counterpart at all
(grep `jaccard|fuzzy` in `windows/src` = 0 hits). Without it the Windows app can never do
"xong cái báo cáo rồi" -> tick + auto-advance, nor clear an `.external` condition by voice.

**Files you own (all new):**
- `windows/src/Volar.Voice/Volar.Voice.csproj` (references Core + Domain; copy conventions from
  `windows/src/Volar.Reminders/Volar.Reminders.csproj`)
- `windows/src/Volar.Voice/VoiceDone.cs`
- `windows/tests/Volar.Voice.Tests/**` (csproj + tests + fixtures)
- `windows/Volar.Windows.sln` — add the two projects (**only** these two lines; leave every
  other sln entry untouched)

**Port target:** `Volar/Sources/Speech/VoiceDone.swift` in this worktree — read all of it,
including the long header comment about why the type is not `@MainActor`.

**Decisions already made (do not re-litigate):**
- `VoiceDoneIntent` -> a sealed record hierarchy in the style of `Volar.Core.Condition`
  (`windows/src/Volar.Core/Condition.cs`), not an enum with payload fields.
- Keep **every** constant identical: high-confidence threshold `0.8`, candidate floor `0.5`,
  max working length `4000`, max tokens `64`, max external descriptions per task `20`, max
  external description chars `500`. These are abuse caps as much as tuning knobs.
- Tokenisation must be **culture-invariant and diacritic-correct for Vietnamese**. Read what the
  Swift `normalizedTokens` actually does and match it: if it folds diacritics, use
  `string.Normalize(NormalizationForm.FormD)` + drop `NonSpacingMark`; if it does not, do not.
  State which one the Swift does in your self-review — this decides whether "bao cao" matches
  "báo cáo", i.e. whether voice-done works at all when Whisper drops tone marks.
- Cue phrases (completion cues, external cues, strip tokens) are **data, not logic**: port the
  tables verbatim, both the Vietnamese and English entries, and keep them in the same order.
- Pure and synchronous: no `async`, no I/O, no logging. `Classify(transcript, openTasks)` is the
  whole public surface plus the records it returns.

**Tests must cover:** exact-title completion; fuzzy title above/below the 0.5 floor; ambiguous
(two candidates within the confidence band) -> disambiguation intent, not a wrong auto-resolve;
external-condition clearing; cue phrase present but no candidate; transcript longer than the
4000 cap; a task carrying more than 20 external descriptions; empty `openTasks`; Vietnamese
input with and without diacritics.

---

## A2 — Reminders: make records durable (`ReminderScheduler` is in-memory today)

**Gap:** `windows/src/Volar.Reminders/ReminderScheduler.cs:63` keeps
`private readonly List<ReminderRecord> _records = new();` — every reminder is lost on restart,
while macOS persists `ReminderRecord` in SwiftData and rebuilds on launch/wake.
`windows/src/Volar.Data/Entities/ReminderRecordEntity.cs` already exists but nothing writes it.

**Files you own:**
- `windows/src/Volar.Reminders/IReminderRecordStore.cs` (new)
- `windows/src/Volar.Reminders/ReminderScheduler.cs` (edit)
- `windows/src/Volar.Data/ReminderRecordRepository.cs` (new)
- `windows/src/Volar.Data/Entities/ReminderRecordEntity.cs` (edit only if a column is genuinely
  missing; if you change the schema you MUST add an EF migration next to
  `windows/src/Volar.Data/Migrations/` and keep the existing one intact)
- `windows/tests/Volar.Reminders.Tests/**` (edit/extend — you own this whole folder this wave)
- `windows/tests/Volar.Data.Tests/ReminderRecordRepositoryTests.cs` (new file only)

**Design (fixed):**
- `IReminderRecordStore` lives in `Volar.Reminders` (so the project keeps zero infrastructure
  dependencies): `IReadOnlyList<ReminderRecord> LoadAll()`, `void Upsert(ReminderRecord)`,
  `void Delete(Guid id)`, `void UpsertRange(IEnumerable<ReminderRecord>)`.
- `ReminderScheduler` keeps `_records` as an in-memory **cache** but becomes **write-through**:
  every mutation that today only touches the list must also hit the store, and the constructor
  (or an explicit `Rehydrate()` called from `RebuildFromStorage`) loads existing records back.
  Mirror how the Swift reads through `fetchAllRecords()` / `save()` —
  `Volar/Sources/Reminders/ReminderScheduler.swift` is the reference, including its `save()`
  error handling (log, never throw into the caller).
- Existing constructor signature: add the store as a parameter with a **default of an in-memory
  implementation** so the current App wiring and all 30 existing Reminders tests keep compiling
  and passing untouched.
- `EfReminderRecordStore` (name it `ReminderRecordRepository` for consistency with
  `TaskRepository`/`CompletionEventRepository`) uses `IDbContextFactory<VolarDbContext>` exactly
  like `TaskRepository` does, and reuses `DateTimeOffsetUtcConverters` — **never** store local
  time. State/offsetKind stay strings, same values as the Swift (`"scheduled"`, `"delivered"`,
  `"satisfied"`, `"resurface"`).

**Tests must cover:** a scheduler built over a store that already has rows rehydrates them
(the restart case — this is the actual bug); write-through for schedule / cancel / fire /
resurface-dedupe (FIX A) / delivered-reconcile (FIX B); delivered and satisfied history
survives a rehydrate and is not re-fired; UTC round-trip through SQLite.

---

## A3 — Local <-> Cloud switch for parse and speech (macOS commit `f88d5e5`)

**Gap:** the newest macOS feature is missing entirely. macOS has `ParseEnginePreference`
(On-device / Cloud) persisted in defaults, a consent gate reusing `cloudParseConsent`, a
`ConfigParseCredentialProvider` reading `volar.parseProxyBaseURL` / `volar.parseProxyToken`, and
— critically — **silent fallback**: when cloud is chosen but unconfigured, parsing degrades to
on-device instead of erroring, and Groq speech falls back to the on-device engine instead of
throwing `.missingCredentials` at upload time. Windows has stubs only, and
`EnvironmentGroqCredentialProvider` has no `IsConfigured` at all.

**Files you own:**
- `windows/src/Volar.Domain/ISettingsStore.cs` (new — plain key/value: `string? GetString(key)`,
  `void SetString(key, value)`, `bool GetBool(key, bool @default)`, `void SetBool(key, value)`;
  plus an `InMemorySettingsStore` for tests)
- `windows/src/Volar.Data/JsonFileSettingsStore.cs` (new — the real one, `%LocalAppData%\Volar\
  settings.json`, path derived the same way `VolarDbPaths` derives the db path; atomic write via
  temp file + `File.Move(overwrite: true)`; corrupt/unreadable file = start empty, never throw)
- `windows/src/Volar.Parsing/ParseEnginePreference.cs` (new — enum + parse/format helpers)
- `windows/src/Volar.Parsing/ConfigParseCredentialProvider.cs` (new — replaces
  `StubParseCredentialProvider` semantically; **do not delete the stub**, Wave 3-C does that)
- `windows/src/Volar.Parsing/DefaultCloudParseGate.cs` (new — real `ICloudParseGate`)
- `windows/src/Volar.Speech/Groq/GroqCredentialProvider.cs` (edit — add `bool IsConfigured`)
- `windows/src/Volar.Speech/Groq/GroqEngine.cs` (edit — expose configured-ness so a router can
  gate on it before starting a capture)
- `windows/src/Volar.Speech/SpeechEngineChoice.cs` (new)
- `windows/tests/Volar.Parsing.Tests/**` and `windows/tests/Volar.Speech.Tests/**` (you own both
  folders this wave), plus `windows/tests/Volar.Data.Tests/JsonFileSettingsStoreTests.cs` (new
  file only), `windows/tests/Volar.Domain.Tests/InMemorySettingsStoreTests.cs` (new file only)

**Decisions (fixed):**
- Settings keys are the **same strings as macOS** so both platforms stay documentable as one
  product: `volar.parseProxyBaseURL`, `volar.parseProxyToken`, `volar.cloudParseConsent`,
  `volar.groqToken`, `volar.groqBaseURL`, `volar.speechEngine`. **CORRECTION (Opus, 2026-07-25,
  after A3 verified it):** an earlier draft of this line also listed `volar.parseEngine` — that key
  does **not** exist on macOS. `AppState.parseEnginePreference` is *derived* from
  `volar.cloudParseConsent` (`grep -rn parseEngine Volar/Sources` shows no defaults key), so the
  Windows side must bridge the same single source of truth, not invent a second key. Read
  `Volar/Sources/Parsing/ConfigParseCredentialProvider.swift` and the `f88d5e5` diff for exact
  semantics.
- **Silent fallback is the whole point.** `ParseEnginePreference.Cloud` with no base URL or no
  token = the router must behave exactly as `OnDevice` (heuristic path), with no exception, no
  dialog, no log of the token. Same for Groq: not configured -> the on-device Whisper engine
  runs. Assert this with tests; it is the acceptance criterion.
- `SpeechEngineChoice` has **two** cases on Windows — `WhisperOnDevice` (default) and
  `GroqCloud`. macOS's third case (`appleOnDevice`) has no Windows equivalent; per anh Khôi's
  decision 2026-07-25 Windows accepts batch-only capture (no live caption). Document that in the
  enum's doc comment.
- `Volar.Speech` must stay reference-free: `IGroqCredentialProvider` gains `bool IsConfigured`
  as an **instance** member, and the existing injected `Func<string, string?>` environment
  reader stays the only way settings reach it (Wave 3-C will pass a reader that checks the
  settings store first, then the environment).
- Never log or expose a token value, not even truncated, in any code path or test output.

**Tests must cover:** preference round-trip through the settings store; cloud chosen +
unconfigured -> heuristic result, no throw; cloud chosen + configured -> cloud path attempted;
consent absent -> gate closed; `IsConfigured` false/true from env vs settings; corrupt
settings.json -> empty store, no throw; atomic write leaves no partial file.

---

## A4 — Orchestrator: the Claude Code hook must be a Windows command

**Gap:** `windows/src/Volar.Orchestrator/EditorConnector.cs:65` still carries the macOS shell
line verbatim — `open "volar://ai-done?cwd=$(printf %s \"$PWD\" | base64)"`. Windows has neither
`open` nor `base64`, so "Kết nối Claude Code" installs a hook that can never fire. Everything
else in that file (backup, additive merge into `hooks.Stop`, marker-based removal, the
matcher-group JSON shape) is already at parity and must not regress.

**Files you own:**
- `windows/src/Volar.Orchestrator/EditorConnector.cs` (edit)
- `windows/src/Volar.Orchestrator/AppLinkHandler.cs` (edit — only if the decode side needs to
  accept the new encoding; keep backwards compatibility with the base64 form)
- `windows/tests/Volar.Orchestrator.Tests/**` (you own this folder this wave)

**Decisions (fixed):**
- Hook command: a single-line PowerShell invocation that (a) needs no external binary, (b) opens
  a URL without leaving a console window, (c) base64-encodes the cwd so spaces / `&` / `#` /
  non-ASCII paths survive the query string — the SAME wire format `AppLinkHandler.DecodedCwd`
  already accepts, so the receiving side keeps working unchanged:
  `powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "Start-Process ('volar://ai-done?cwd=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Location).Path)))"`
  Mind the JSON escaping — the existing `JsonEscape` path and the byte-for-byte preview string
  (`HookEntryJson`) must both stay correct, and the marker substring (`volar://`) must still
  match for dedupe and removal.
- Mark the command `// UNVERIFIED`: whether Claude Code on Windows runs `hooks.Stop` entries
  through `cmd.exe`, PowerShell, or `CreateProcess` directly is not verified — keep the command
  tolerant (no `cmd`-only syntax, no unescaped `%`), and note in your self-review that the
  "Chạy thử" / test-connection path is what will prove it on anh Khôi's machine.
- Settings path: macOS resolves `~/.claude/settings.json`; on Windows use
  `%USERPROFILE%\.claude\settings.json` and keep the same real-home guard intent as the Swift's
  `NSHomeDirectoryForUser` check (reject a path that escapes the user profile).
- Backup file naming, marker semantics, and the "Stop present but not an array -> throw, change
  nothing" rule stay exactly as they are.

**Tests must cover:** fresh install into a file with no `hooks` key; additive merge preserving
other Stop entries and other hook groups; idempotent connect (no second entry, no second
backup); disconnect removes only the marker entry; `hooks.Stop` present as a non-array -> throws
and the file is byte-identical afterwards; the emitted command contains no `open`/`base64`
binary dependency; round-trip cwd encode -> `AppLinkHandler` decode for a path with a space and
a non-ASCII character.

---

## What happens after this wave

Wave 3-C (single agent, after all four land): swap every `Stubs/*.cs`, rewire
`CompositionRoot.cs`, register the `volar://` URI scheme in HKCU, and decompose macOS
`AppState.swift` (2220 lines, ~60 members) into services — capture, task list, focus, theme +
settings, reminders settings, sweep/triage, delegation, voice-done — carrying the four
2026-07-19 AppState bug fixes across (see `backlog.md` ★★★★★ APPSTATE BUG-HUNT; do not port the
pre-fix behaviour). Then Wave 4: the 12 remaining views.
