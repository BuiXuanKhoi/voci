# AppState.swift / VolarApp.swift — mechanical inventory (Wave 3-C input)

Source: `Volar/Sources/App/AppState.swift` (2402 lines) and `Volar/Sources/App/VolarApp.swift`
(332 lines), read in full from this worktree (`voci-windows`, branch `window`) on 2026-07-25.
Line numbers below are exact citations into those two files as they stand right now (post the
2026-07-19 bug-fix pass — see the dedicated section near the end).

View-consumption columns were built by grepping `Volar/Sources/Views/**` for `appState\.<name>`
plus a few bare-name fallbacks (`glass`, `nowTasks`, `staleTasks`, `sweepItems`, `showSweep`,
`showTriage`, `voiceFeedback`, `allowServerRecognition`, `cloudParseConsent`,
`globalReminderPolicy`, `voiceDeliveryMode`). **Two view files never read `AppState` directly at
all**: `TriageView.swift` and `SweepView.swift` have no `@Environment(AppState.self)` — they are
pure presentation, driven entirely by `items:`/`onKeep:`/`onComplete:`/etc. closures that
`VolarApp.swift`'s `.sheet` blocks wire to `AppState` methods/computed properties
(`appState.staleTasks`, `appState.triageKeep`, `appState.sweepItems`, `appState.sweepComplete`,
...). `Waveform.swift` and `AmbientBackground.swift` also have no `@Environment(AppState.self)`
(pure rendering, parameters only). This matters for the C# port: those four views are the
"dumbest" components — they need no direct service reference, only bound data.

---

## 0. Module-level types (outside the `AppState` class body)

| Name | Lines | Kind | Notes |
|---|---|---|---|
| `Notification.Name.volarTasksDidChange` | 16-18 | notification name constant | Posted by `ReminderScheduler.handleAction` (`Sources/Reminders/ReminderScheduler.swift:308`), observed by `AppDelegate.registerWindowIndependentObservers()` in `VolarApp.swift:287-293`. See §6. |
| `enum AmbientMode` | 24-38 | String-backed enum, `CaseIterable`/`Identifiable` | `.none/.rain/.snow/.embers/.custom`. Drives `Settings → Appearance` picker and `AmbientBackground`/`AmbientSound`. |
| `enum SpeechEngineChoice` | 44-54 | String-backed enum | `.appleOnDevice/.whisperKit/.groq`. Freemium speech-tier picker. |
| `enum ParseEnginePreference` | 63-72 | String-backed enum | `.onDevice/.cloud`. Thin presentation bridge OVER `cloudParseConsent` — not a second source of truth. |
| `enum VoiceDeliveryMode` | 80-90 | String-backed enum | `.visualOnly/.visualPlusVoice/.voiceOnly`. Read directly (out-of-band) by `ReminderScheduler`/`VoiceReminderChannel` via its `UserDefaults` key, not injected. |
| `enum ChipKind` | 97-105 | Hashable enum | `.deadline/.estimate/.priority/.reminder/.recurrence/.kind/.followUpReview`. Confirm-card chip identity. |
| `struct ConfirmDraft` | 112-142 | Identifiable/Equatable struct | Per-draft UI overlay on a `ParsedTask`: `task`, `dismissed`, `accepted`, `dismissedConditions`, `acceptedConditions`, `resolvedTaskDone`, `conflicts`, `conflictDismissed`. Never persisted; lives only in `AppState.confirmDrafts`. |
| `enum VoiceDoneAction` | 149-158 | Sendable/Equatable enum | `.complete`, `.clearExternal`, `.delegate(checkBackMinutes:)`. |
| `struct VoiceDoneConfirm` | 165-169 | Identifiable/Equatable struct | `action` + bounded `candidates: [VoiceMatch]` (capped to 10 at construction, `AppState.swift:966`). |
| `final class DefaultCloudParseGate` (2370-2402, end of file) | — | standalone, NOT `@MainActor`, `@unchecked Sendable` | `IntentRouter`'s injected `CloudParseGate`. `isOptedIn()` reads `AppState.cloudParseConsentKey` directly from `UserDefaults` (2391); `isOnline()` is a lock-protected `NWPathMonitor` snapshot (2373-2401), default `true` until first callback. Windows: `NWPathMonitor` has no Windows equivalent — needs `NetworkInformation`/`NetworkStatusChanged` or a simple `HttpClient` reachability probe; the "default true, best-effort" contract should carry over unchanged. |

---

## 1. `AppState` stored properties, computed properties, methods — full table

Legend for **Kind**: `stored` / `derived` (computed) / `cmd` (mutating method/action) / `lifecycle`
(init/activate) / `key` (UserDefaults key constant) / `type` (nested type).
**Actor**: all of `AppState` is `@MainActor` (class-level annotation, line 172) — flagged only
where something *specifically* matters (fire-and-forget `Task{}`, async, or a callback that must
manually hop back onto MainActor because it is `@Sendable`-inferred off-actor).

### 1.1 Frozen §4 stored state (176-182)

| # | Name : line | Kind | Reads / Mutates | UI consumers | Actor/async | UserDefaults key |
|---|---|---|---|---|---|---|
| 1 | `tasks` : 176 | stored `[TaskItem]` | Mutated by nearly every CRUD/mutation method (`addTask`, `toggleDone`, `deleteTask`, `confirmSave`, `setFrog`, `triageDefer`, `delegateTask`, `clearExternalCondition`, `refreshFromStore`, `scheduleNextResurface`'s wake continuation). Read by every derived grouping (`nowTasks`/`laterTasks`/`doneTasks`/`openTasks`/`frogTask`/`activeTask`/`staleTasks`/`sweepItems`) and by `TaskStore.fetchAll()` round-trips. THE single source of truth the whole UI observes. | `TodayView` (`.animation(..., value: appState.tasks)` :139, counts :370/375), `MenuBarLabel` (:46, forces observation for the delegation badge), `TaskDetailView` (via `detailTask`), `TodayView` delegation-queue lookups (:816, :820) | `@MainActor` stored; every mutation is synchronous | — |
| 2 | `accent` : 177 | stored `VolarAccent` | Set by `setAccent`; overridden from `UserDefaults` in `init` (428-430) | `MenuBarLabel`, `MorningFrogView`, `FocusOverlay`, `Components`, `TodayView`, `TaskDetailView`, `Sidebar`, `OnboardingView`, `NotificationView`, `PopoverView`, `TaskRow`, `TaskBreakdownView`, `SettingsView` — nearly every view does `private var accentColors: Accent { appState.accent.accent }` | sync | `volar.accent` (`accentKey`, 387) — **FIX 4** |
| 3 | `density` : 178 | stored `Density` | Set by `setDensity`; overridden from `UserDefaults` in `init` (431-434) | `TodayView` (:103,120,129 — `sectionGap`/`rowGap`), `TaskRow` (:60 `rowPadY`), `SettingsView` (:439,443 picker) | sync | `volar.density` (`densityKey`, 394) — **FIX 4** |
| 4 | `glass` : 179 | stored `GlassLevel` | Set only via `init` parameter — **no setter method exists**; not persisted | `Sidebar` (:62 `.fill(appState.glass.material)`) | sync | none (not persisted at all — a real gap: unlike accent/density it has no `setGlass`/`UserDefaults` key) |
| 5 | `ambient` : 180 | stored `AmbientMode` | Set by `setAmbient`/`setCustomImage` (which force it to `.custom`); overridden from `UserDefaults` in `init` (420-422) | `TodayView` (:29-30, :152 background), `Sidebar` (:60), `SettingsView` (:373-374,379 picker) | sync | `volar.ambient` (`ambientKey`, 358) |
| 6 | `customImageURL` : 181 | stored `URL?` | Set by `setCustomImage`; overridden from `UserDefaults` in `init` (423-425) | `TodayView` (:30), `SettingsView` (:382,396,399 thumbnail/clear) | sync | `volar.customImageURL` (`customImageKey`, 359) — plain file path string, **not** a security-scoped bookmark (doc comment 1706-1709 flags this explicitly as a gap if sandboxing is ever turned on) |
| 7 | `voiceFeedback` : 182 | stored `Bool` | Set only via `init` parameter — **no setter method, no `UserDefaults` persistence**; read by `startFocus`/`completeFocusTask` to gate `voice.speak(...)` | none (no view reads it directly — it's an internal gate on spoken feedback, not a Settings-exposed toggle in the current file) | sync | none |

### 1.2 Capture / popover state (185-228)

| # | Name : line | Kind | Reads / Mutates | UI consumers | Actor/async | UserDefaults key |
|---|---|---|---|---|---|---|
| 8 | `enum CaptureState` : 185-187 | type | `.idle/.recording/.parsing/.parsed/.saving/.done/.error` — walked by `startCapture`→`stopCapture`→`finishRecording`→`runParse`→`confirmSave`/`finishSaveUI` | `TodayView` (:39,45), `PopoverView` (nearly every branch: :62,75,88,92,97,102,131-260 etc.), `Sidebar` (:75), `MorningFrogView` n/a | sync | — |
| 9 | `captureState` : 188 | stored | see above | see above | sync | — |
| 10 | `liveTranscript` : 189 | stored `String` | Set by `startCapture`'s `onPartial` callback (fire-and-forget closure, 729), `finishRecording` (888), cleared by `cancelCapture`/`dismissVoiceDoneConfirm`/`finishSaveUI`/`finishVoiceDoneUI` | `PopoverView` (:151,152,153,274,276) | mutated from inside a `_Concurrency.Task{}` closure (700-730) | — |
| 11 | `confirmDrafts` : 193 | stored `[ConfirmDraft]` | Populated by `runParse` (1179-1183); mutated by every chip method (`dismissAttribute`, `acceptUncertainAttribute`, `dismissCondition`, `acceptUncertainCondition`, `resolveTaskDone`, `removeDraft`, `dismissConflictAdvisory`); cleared by `confirmSave`/`finishSaveUI`, `startCapture`, `cancelCapture` | `PopoverView` (:98,134,142,152-194,276-291,833) | mutated inside `runParse`'s `_Concurrency.Task{}` (1164-1190) | — |
| 12 | `voiceDoneConfirm` : 199 | stored `VoiceDoneConfirm?` | Set by `presentVoiceDoneConfirm`/`presentDelegationConfirm`; cleared by `confirmVoiceDone`/`dismissVoiceDoneConfirm`/`startCapture`/`cancelCapture` | `PopoverView` (:109,136,139,149,181,582) | sync | — |
| 13 | `voiceDoneNoMatchTranscript` : 204 | stored `String?` | Set by `presentVoiceDoneConfirm` (zero-candidate branch, 960)/`presentDelegationConfirm` (no-active-task branch, 1027); consumed/cleared by `captureVoiceDoneAsNewTask` (1084) | `PopoverView` (:109,140,153,182,584) | sync | — |
| 14 | `captureErrorDetail` : 205 | stored `String?`, `private(set)` | Set by `handleCaptureError`, `proceedToCapture` (consent prompt copy, 924), `runParse` (error/"Didn't catch that.", 1185), `confirmSave`'s catch (1424) | `PopoverView` (:191) | sync | — |
| 15 | `allowServerRecognition` : 207 | stored `Bool`, `private(set)` | Set by `useServerRecognition`; loaded in `init` (435); read by `startCapture` to set `apple.allowServerFallback` (727) | none directly (drives `pendingServerConsent`'s flow, but the raw bool itself isn't rendered) | sync | `volar.allowServerRecognition` (`allowServerRecognitionKey`, 360) |
| 16 | `recognitionLocaleID` : 210 | stored `String`, `private(set)` | Set by `setRecognitionLocale`; loaded in `init` (436, default `"en-US"`); applied to `speech` in `init` (503) and `setRecognitionLocale` (847) | `SettingsView` (:204-205 picker binding) | sync | `volar.recognitionLocale` (`recognitionLocaleKey`, 361) |
| 17 | `speechEngineChoice` : 214 | stored `SpeechEngineChoice`, `private(set)` | Set by `setSpeechEngine`; loaded in `init` (437); read by `selectedEngine` (676-679) and `activateServices` (2191) | `SettingsView` (:153-154,165,172,218-219) | sync (but `setSpeechEngine` fires a fire-and-forget `Task { await whisper.prepare() }`, 856) | `volar.speechEngine` (`speechEngineKey`, 362) |
| 18 | `pendingServerConsent` : 217 | stored `Bool`, `private(set)`, default `false` | Set `true` by `handleCaptureError` (onDeviceUnavailable branch, 737); cleared by `useServerRecognition`/`startCapture` | `PopoverView` (:195,199 comment, consent row) | sync | — (not persisted — session-only prompt state) |
| 19 | `cloudParseConsent` : 223 | stored `Bool?`, `private(set)` | Set by `setParseEngine`/`resolveCloudConsent`; loaded in `init` (438, as `Bool?` — `nil` = never asked); read by `proceedToCapture` (917) and `DefaultCloudParseGate.isOptedIn()` (2391, reads the raw key directly, bypassing this property) | `parseEnginePreference` (derived from this, see below) | sync | `volar.cloudParseConsent` (`cloudParseConsentKey`, 369, **`fileprivate nonisolated static`** — the one key deliberately readable from a non-actor type) |
| 20 | `pendingCloudConsent` : 226 | stored `Bool`, `private(set)`, default `false` | Set `true` by `proceedToCapture` (923); cleared by `resolveCloudConsent`/`startCapture`/`cancelCapture` | `PopoverView` (:196,203 consent row) | sync | — |
| 21 | `pendingParseTranscript` : 228 | stored `String?`, `private` | Set by `proceedToCapture` (922); consumed by `resolveCloudConsent` (1147-1149) | none (fully internal handoff) | sync | — |

### 1.3 Phase-4 reminder / voice-delivery / triage settings (233-241)

| # | Name : line | Kind | Reads / Mutates | UI consumers | Actor/async | UserDefaults key |
|---|---|---|---|---|---|---|
| 22 | `voiceDeliveryMode` : 233 | stored `VoiceDeliveryMode`, `private(set)` | Set by `setVoiceDeliveryMode`; loaded in `init` (439-441, default `.visualPlusVoice`). **Read directly by `ReminderScheduler`/`VoiceReminderChannel` out-of-band via the key**, not injected. | `SettingsView` (:319-320) | sync | `volar.voiceDeliveryMode` (`voiceDeliveryModeKey`, 374, `static` not `private` — deliberate sibling-read seam) |
| 23 | `globalReminderPolicy` : 235 | stored `ReminderPolicy`, `private(set)` | Set by `setGlobalReminderPolicy`; loaded in `init` (442-447, JSON-decoded, default `.defaultPolicy`) | `SettingsView` (:307-308) | sync | `volar.globalReminderPolicy` (`globalReminderPolicyKey`, 377, `static`) — JSON-encoded `ReminderPolicy` |
| 24 | `triageKeptAt` : 241 | stored `[UUID: Date]`, `private` | Set by `triageKeep`; loaded in `init` (448-455); read by `staleTasks` (1948) | none directly (feeds the `staleTasks` computed property that `VolarApp.swift`/`TriageView` consume) | sync | `volar.triageKeptAt` (`triageKeptAtKey`, 380, `private`) — dictionary of `uuidString -> epoch-seconds Double` |

### 1.4 Focus session state (244-247)

| # | Name : line | Kind | Reads / Mutates | UI consumers | Actor/async | UserDefaults key |
|---|---|---|---|---|---|---|
| 25 | `focusActive` : 244 | stored `Bool` | Set by `startFocus`/`endFocus`/`completeFocusTask` (when the batch empties, 1631) | `MenuBarLabel` (:22, and a **debug-only direct write** at :152 `appState.focusActive = true`), `TodayView` (:47,73,85,386) | sync | — |
| 26 | `focusPaused` : 245 | stored `Bool` | Set by `startFocus`/`toggleFocusPause`/`endFocus` | `FocusOverlay` (:63,74,76,164-165), `TodayView` (:404,424,426) | sync | — |
| 27 | `focusSecondsLeft` : 246 | stored `Int` | Set by `startFocus`/`focusTick`/`endFocus` (default `25*60`) | `MenuBarLabel` (:136, and debug write :153), `FocusOverlay` (:70,74,102,111,213), `TodayView` (:417) | mutated once per second from `focusTimer`'s `@Sendable` `Timer` callback hopping to `@MainActor` via `_Concurrency.Task` (1579-1583) | — |
| 28 | `focusIndex` : 247 | stored `Int` | Set by `startFocus`/`completeFocusTask`/`FocusOverlay`'s prev/next (direct writes at FocusOverlay.swift:199,204) | `FocusOverlay` (:32,199,204) — **note: `FocusOverlay` mutates `appState.focusIndex` directly**, not through an `AppState` method | sync | — |

### 1.5 Modal / banner state (252-268)

| # | Name : line | Kind | Reads / Mutates | UI consumers | Actor/async | UserDefaults key |
|---|---|---|---|---|---|---|
| 29 | `struct ReminderBanner` : 252-256 | type | `id`, `title`, `timing` | `TodayView` (:48-70) | — | — |
| 30 | `showMorningFrog` : 258 | stored `Bool`, default `false` | Set by `VolarApp.swift`'s main-window `.task` (73, once/day gate) and `pickFrog`/`dismissMorningFrog` (both set `false`) | `VolarApp.swift`'s `.sheet` (:120-130) mounts `MorningFrogView`; view itself doesn't read this flag (gated at the sheet binding) | sync | — (day-gate itself is `@AppStorage("morningFrogLastShown")` **in `VolarApp.swift`, not `AppState`** — see §7 Windows deltas) |
| 31 | `showBreakdown` : 259 | stored `Bool`, default `false` | Set `true` by `TodayView` (:305,680) and `triageBreakdown` (1980); set `false` by `saveBreakdown`/`VolarApp.swift`'s sheet `onClose` | `VolarApp.swift`'s `.sheet` (:131-141); `TodayView`/`TaskRow` set it directly (not via a method — no `AppState.openBreakdown()` exists) | sync | — |
| 32 | `showTriage` : 264 | stored `Bool`, default `false` | Set `true` by `VolarApp.swift`'s `.task` (88, once/ISO-week, gated on `!staleTasks.isEmpty`); set `false` by `VolarApp.swift`'s sheet binding and `dismissBatchSheetsIfEmpty` | `VolarApp.swift`'s `.sheet` (:150-163) — **`TriageView` itself never reads `AppState`** | sync | week-gate is `@AppStorage("triageLastShownWeek")` in `VolarApp.swift` |
| 33 | `reminderBanner` : 265 | stored `ReminderBanner?`, default `nil` | Set by `showReminderPreview`; cleared by `dismissBanner` | `TodayView` (:48-70, plus a `.task(id:)` auto-dismiss after a delay) | sync | — |
| 34 | `detailTaskID` : 268 | stored `UUID?` | Set by `openDetail`; cleared by `closeDetail`/`VolarApp.swift`'s sheet binding (:143-144) | `VolarApp.swift`'s `.sheet` (:142-149) mounts `TaskDetailView`; `TaskDetailView` itself reads `detailTask` (derived), and a preview helper writes `detailTaskID` directly (TaskDetailView.swift:205) | sync | — |

### 1.6 Collaborators (implementation detail, not frozen §4) (283-354)

| # | Name : line | Kind | Reads / Mutates | UI consumers | Actor/async | Notes |
|---|---|---|---|---|---|---|
| 35 | `router: IntentRouter` : 283 | stored, `private let` | Used by `runParse` (1166) | none directly | `await self.router.parse(...)` inside `_Concurrency.Task{}` (1166) | Constructed with `CloudParser`+`DefaultCloudParseGate` defaults in `init`'s parameter list (405-408) |
| 36 | `store: TaskStore?` : 284 | stored, `private let` | Read/written by nearly every method with a `guard let store else { <no-store fallback> }` branch — this is THE central collaborator | none directly | sync (SwiftData-backed) | `nil` when the SwiftData container fails at launch (`VolarApp.init`, 20-21) — **every method must degrade gracefully**, a pattern the Windows port must replicate for its own store failure mode |
| 37 | `clock: () -> Date` : 287 | stored, `private let` | Injected pure clock, called everywhere `now`/`clock()` appears (used instead of `Date()` directly for testability) | none | sync | defaults to `Date.init` |
| 38 | `voice: VoicePlayback` : 292 | stored `let` | `speakDetails`, `startFocus`, `completeFocusTask`, `readDayAloud`, `finishSaveUI`, `finishVoiceDoneUI` all call `voice.speak(...)`/`voice.readDay(self)` | none directly (no view reads `appState.voice`) | `@MainActor` class, no-arg init | Windows: needs a `System.Speech.Synthesis.SpeechSynthesizer` (or SAPI) wrapper — TTS only, no ASR |
| 39 | `ambientSound: AmbientSound` : 293 | stored `let` | `toggleAmbientSound`; `reminderGate.isOtherAudioPlaying` closure reads `ambientSound.isPlaying` (502) | `TodayView` (:76, `.isPlaying`) | `@MainActor` | Windows: needs an `AudioGraph`/`MediaPlayer` loop equivalent |
| 40 | `hotkey: HotkeyManager` : 294 | stored `let` | `activateServices` calls `hotkey.start(appState: self)` (2156); `HotkeyManager` itself calls `appState.toggleCapture()` on key-down | none directly | `@MainActor` | Carbon `RegisterEventHotKey` — **Windows already ported this to `RegisterHotKey` per memory** (branch `window`, no WH_KEYBOARD_LL) |
| 41 | `speech: SpeechCapture` : 295 | stored `let`, conforms to `SpeechEngine` | Default capture engine; `startCapture`'s `selectedEngine` falls back to it; `setRecognitionLocale` calls `speech.setLocale(...)` | `OnboardingView` (:177, `await appState.speech.requestAuthorization()`) | async (`requestAuthorization`, `start`/`stop`/`cancel`) | Apple Speech framework — **Windows has no on-device equivalent; batch-only capture already accepted per task brief (no live caption)** |
| 42 | `whisper: WhisperKitEngine` : 298 | stored `let`, conforms to `SpeechEngine` | Free on-device tier; `selectedEngine` picks it when `.whisperKit` chosen AND `isModelReady`; `setSpeechEngine`/`activateServices` call `whisper.prepare()` (fire-and-forget `Task{}`, 856/2192) | `SettingsView` (:132 `switch appState.whisper.state`) | async prepare | WhisperKit is a Swift package wrapping a CoreML/GGML model — Windows equivalent would be a native `whisper.cpp`/ONNX runtime binding |
| 43 | `groq: GroqEngine` : 300 | stored `let`, conforms to `SpeechEngine` | Paid cloud tier; `selectedEngine` picks it when `.groq` chosen AND `GroqEngine.isConfigured` | `SettingsView` (:172, `GroqEngine.isConfigured` check) | async (network) | Pure HTTP client — ports as-is (no Apple-specific API), just needs the .NET `HttpClient` equivalent |
| 44 | `voiceDone: VoiceDone` : 304 | stored, `private let` | Pure/stateless matcher; used by `finishRecording` (901) via `voiceDoneOpenTasks` | none | sync | Sibling-owned, `Sources/Speech/VoiceDone.swift` — pure Swift logic, ports directly |
| 45 | `runningEngine: SpeechEngine?` : 308 | stored, `private var` | Set by `startCapture` (695); read/cancelled by `stopCapture`, `cancelCapture`, `dismissVoiceDoneConfirm`, `finishVoiceDoneUI`, `finishSaveUI` | none | sync | Tracks whichever engine `startCapture` actually routed to |
| 46 | `voiceChannel: VoiceReminderChannel` : 316 | stored `let` | Constructed in `init` (471) wrapping `voice`; read out-of-band by `ReminderScheduler`/itself via `voiceDeliveryModeKey` | none directly | — | Always constructed (doesn't need a store) |
| 47 | `reminderGate: ReminderContextGate` : 317 | stored `let` | Constructed in `init` (472); `isOtherAudioPlaying` closure wired at 502 | none directly | — | Always constructed |
| 48 | `scheduler: ReminderScheduler?` : 318 | stored `let` | `nil` when no store (476-478); else constructed with `store`/`voiceChannel`/`reminderGate` (474). Called from `addTask`, `toggleDone`, `deleteTask`, `clearExternalCondition`, `triageDefer`, `delegateTask`, `notifyEligibilityAndScheduleResurface`, `scheduleNextResurface`, `activateServices`, `offerRescheduleForOverdueTasks` | none directly | — | Posts `.volarTasksDidChange` from `handleAction` (sibling file) — see §6 |
| 49 | `delegation: DelegationTracker?` : 326 | stored `let` | `nil` when no store (486-487); else constructed with `store` (482-483). Called from `refreshDelegationQueue`, `delegateTask`, `resolveDelegationDone/StillWaiting/CheckLater`, `maybeShowEveningSweep` (`reconcileBatch`) | `MenuBarLabel` (:47), `TodayView` (:813), `SettingsView` (:512) — all via `appState.delegation?.wipCount()` | — | — |
| 50 | `appLinkHandler: AppLinkHandler?` : 327 | stored `let` | `nil` when no store (487); else constructed with `store`/`delegation` (484). `onCapture` closure wired at `init` (513-517). Called from `onAppLinkHandled`/`resolveAppLinkDisambiguation`/`dismissAppLinkDisambiguation`, and from `AppDelegate.application(_:open:)` in `VolarApp.swift` (328) | none directly | — | Handles inbound `volar://` app links — Windows needs a custom URL protocol registration (`Volar.exe` as a registered `volar://` handler) instead of macOS's `.onOpenURL`/`application(_:open:)` |
| 51 | `claudeConnector: ClaudeCodeConnector()` : 328 | stored `let`, always constructed | `detect()`, `previewHookEntry()`, `connect(bookmarkedClaudeDir:)`, `disconnect(...)`, `sendTestSignal()` — all called from `SettingsView` | `SettingsView` (:529,565,672,688,705) | `connect`/`disconnect` throw (security-scoped bookmark resolution) | File I/O only, no store dependency. `bookmarkedClaudeDir: url` — **uses an `NSOpenPanel` bookmark elsewhere (`SettingsView`)**, a macOS-only mechanism (see §7) |
| 52 | `dueDelegationRechecks: [UUID]` : 334 | stored `[UUID]` | Set by `refreshDelegationQueue` (2255); appended by `maybeShowEveningSweep` (2080) | `TodayView` (:816, ambient card list), `TodayView` action buttons (:923-925) | sync (but driven by a 60s repeating `Timer`, see `delegationTimer`) | — |
| 53 | `pendingDisambiguationTaskIDs: [UUID]` : 342 | stored `[UUID]` | Mirrors `AppLinkHandler.pendingDisambiguation`; set by `onAppLinkHandled`/`resolveAppLinkDisambiguation`; cleared by `dismissAppLinkDisambiguation` | `TodayView` (:820,874,895, ambient disambiguation card) | sync | — |
| 54 | `lastAppLinkAt: Date?` : 346 | stored `Date?`, `private(set)` | Set by `onAppLinkHandled` (2323) | `SettingsView` (:246,250,503 `.onChange` — Connect-Claude test-signal receipt) | sync | — (not persisted — session-only receipt signal) |
| 55 | `delegationTimer: Timer?` : 347 | stored, `private var` | Set/invalidated by `startDelegationTimer` | none directly | 60s repeating `Timer`, `@Sendable` block hops to `@MainActor` via `_Concurrency.Task` (2240-2244) | |
| 56 | `focusTimer: Timer?` : 354 | stored, `private var` | Set/invalidated by `startFocus`/`endFocus` | none directly | 1s repeating `Timer`, same `@Sendable`→`@MainActor` hop pattern (1579-1583) | **FIX B** (see §5) — moved here from `FocusOverlay` so the countdown survives the overlay window closing |

### 1.7 UserDefaults key constants (358-394)

| # | Name : line | Value | Scope |
|---|---|---|---|
| 57 | `ambientKey` : 358 | `"volar.ambient"` | `private static` |
| 58 | `customImageKey` : 359 | `"volar.customImageURL"` | `private static` |
| 59 | `allowServerRecognitionKey` : 360 | `"volar.allowServerRecognition"` | `private static` |
| 60 | `recognitionLocaleKey` : 361 | `"volar.recognitionLocale"` | `private static` |
| 61 | `speechEngineKey` : 362 | `"volar.speechEngine"` | `private static` |
| 62 | `cloudParseConsentKey` : 369 | `"volar.cloudParseConsent"` | `fileprivate nonisolated static` — the ONE key deliberately readable from `DefaultCloudParseGate`, a non-`@MainActor` type |
| 63 | `voiceDeliveryModeKey` : 374 | `"volar.voiceDeliveryMode"` | `static` (not `private`) — sibling-read seam for `ReminderScheduler`/`VoiceReminderChannel` |
| 64 | `globalReminderPolicyKey` : 377 | `"volar.globalReminderPolicy"` | `static` |
| 65 | `triageKeptAtKey` : 380 | `"volar.triageKeptAt"` | `private static` |
| 66 | `accentKey` : 387 | `"volar.accent"` | `private static` — **FIX 4** |
| 67 | `densityKey` : 394 | `"volar.density"` | `private static` — **FIX 4** |
| — | `staleThreshold` : 1933 | `TimeInterval = 7*24*60*60` | `private static` (not a UserDefaults key — a constant) |
| — | `triageDeferInterval` : 1934 | `TimeInterval = 3*24*60*60` | `private static` (constant) |
| — | `sweepLastShownDayKey` : 2025 | `"volar.sweepLastShownDay"` | `private static` |
| — | `delegationTriggerPhrases` : 978-983 | `[String]` phrase list | `private static` (not a key — Vietnamese/English delegation-handoff trigger phrases) |

### 1.8 `init` (396-518)

`init(store:tasks:accent:density:glass:ambient:customImageURL:voiceFeedback:router:clock:)` —
lifecycle. Order of operations that matters for a C# port:
1. Assign `store`, `tasks` (from param, or `store?.loadOrSeed()`, or `[]`).
2. Assign every simple stored property from parameters.
3. **Override `ambient`/`customImageURL`/`accent`/`density` from `UserDefaults`** if present (420-434) — this override-after-parameter-assignment order is FIX 4's shape; the Windows port must replicate "constructor param is the previews/tests fallback, persisted value always wins in production" for all four.
4. Load `allowServerRecognition`/`recognitionLocaleID`/`speechEngineChoice`/`cloudParseConsent`/`voiceDeliveryMode`/`globalReminderPolicy`/`triageKeptAt` from `UserDefaults` (435-455).
5. Assign remaining simple defaults (`voiceFeedback`, `captureState = .idle`, etc.) (456-465).
6. Construct `voiceChannel`/`reminderGate` (471-472), then conditionally `scheduler` (473-478), then conditionally `delegation`/`appLinkHandler` (481-488).
7. **Last**, after every stored property is set (comment 489-501 explains why — Swift forbids capturing `self` in a closure before `init` finishes): wire `reminderGate.isOtherAudioPlaying` closure (502) and `appLinkHandler?.onCapture` closure (513-517).
8. `speech.setLocale(...)` (503).

This ordering constraint ("closures that capture `self` must be assigned last") is a Swift-ism
that doesn't apply to C# constructors, but the *dependency order* (persisted-state load before
service construction, service construction before cross-wiring callbacks) should still be
preserved literally so behavior doesn't shift.

### 1.9 Derived task groupings (522-538)

| # | Name : line | Kind | Reads | UI consumers |
|---|---|---|---|---|
| 68 | `nowTasks` : 522 | derived `[TaskItem]` | `tasks.filter { !done && when == .now }` | not read directly by any view (only via `openTasks`/`FocusOverlay` comments) |
| 69 | `laterTasks` : 523 | derived | `tasks.filter { !done && when == .later }` | not read directly (only via `openTasks`) |
| 70 | `doneTasks` : 524 | derived | `tasks.filter(\.done)` | `TodayView` (:125,128,375) |
| 71 | `openTasks` : 525 | derived | `nowTasks + laterTasks` | `TodayView` (:60,69-70,99,175-176,365,370), `MorningFrogView` (:128,135), `FocusOverlay` (:25,203), `PopoverView` (:511,537,539), `Sidebar` (:26). Also read internally by `voiceDoneOpenTasks`, `startFocus`, `runParse`, `preResolveConditions`, `offerRescheduleForOverdueTasks`, `staleTasks` |
| 72 | `frogTask` : 526 | derived | `tasks.first { frog && !done }` | `TodayView` (:411,465), `startFocus`'s voice line (1570) |
| 73 | `detailTask` : 529 | derived | `detailTaskID.flatMap { id in tasks.first { $0.id == id } }` | `TaskDetailView` (:15) |
| 74 | `activeTask` : 534 | derived | `VolarCore.nextTask(from: tasks.map(snapshot), now: clock(), calendar: .current)`, re-mapped back to a `TaskItem` | `MenuBarLabel` (:115), `TodayView` (:69,72,175,199), `showReminderPreview` (1790), `presentDelegationConfirm` (1024) | **THE integration point with the VolarCore nextTask engine** — recomputed fresh on every access, no cache. This is the property whose staleness the whole `.volarTasksDidChange`/`refreshFromStore()` machinery in §6 exists to protect. |

### 1.10 Task CRUD (542-648)

| # | Name : line | Kind | Reads / Mutates | UI consumers | Notes |
|---|---|---|---|---|---|
| 75 | `addTask(_:)` : 542 | cmd | inserts into `tasks` at 0; `store?.add`; `scheduler?.scheduleReminders`; `notifyEligibilityAndScheduleResurface` | `saveBreakdown` (internal caller) | |
| 76 | `toggleDone(_:)` : 578 | cmd | store path: `store.toggle`, `tasks = store.fetchAll()`, cancel-or-reschedule reminders, `notifyEligibilityAndScheduleResurface`. No-store: in-place flip + force `.later` | `TodayView` (:239,306,689), `TaskRow` (:97,105), `TaskDetailView` (:187), `confirmVoiceDone` (.complete), `sweepComplete`, `resolveDelegationDone` | **THE consolidated completion+advance funnel** — every completion source routes through this (T037). Known gap documented in-file (570-577): `ReminderScheduler.handleAction`'s "Done" notification action bypasses this by design (FR-014/015/016), which is exactly why `.volarTasksDidChange` exists. |
| 77 | `deleteTask(_:)` : 612 | cmd | store path: `store.delete` (returns its own eligibility diff, reused directly — not recomputed), `tasks = store.fetchAll()`, `scheduler?.cancelReminders`, `scheduler?.notifyUnblocked`, `scheduleNextResurface` | `TodayView` (:311), `TaskRow` (:99), `TaskDetailView` (:167), `triageDrop` | |
| 78 | `refreshFromStore()` : 645 | cmd | `tasks = store.fetchAll()`, no-op without a store | called by `AppDelegate`'s `.volarTasksDidChange` observer (`VolarApp.swift:291`), `onAppLinkHandled`, `resolveAppLinkDisambiguation` | See §6 — the WG-C gap-fix hook |

### 1.11 Detail sheet (652-657)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 79 | `openDetail(_:)` : 652 | cmd | sets `detailTaskID` | `TodayView` (:303,678), `TaskRow` (:87) |
| 80 | `closeDetail()` : 653 | cmd | clears `detailTaskID` | `TaskDetailView` (:153,168) |
| 81 | `speakDetails(of:)` : 655 | cmd | `voice.speak(task.details.isEmpty ? task.title : task.details)` | `TaskDetailView` (:128) |

### 1.12 Capture / popover flow (662-929)

| # | Name : line | Kind | Reads / Mutates | UI consumers | Actor/async |
|---|---|---|---|---|---|
| 82 | `captureSession: Int` : 667 | stored, `private var` | Monotonic guard bumped by every start/stop/cancel; every deferred closure checks `self.captureSession == session` before acting | none directly | — |
| 83 | `selectedEngine` : 674 | derived, `private` | Switches on `speechEngineChoice` with fallback logic (WhisperKit only if supported+ready, Groq only if configured, else Apple) | none directly (internal to `startCapture`) | sync |
| 84 | `startCapture()` : 682 | cmd | resets capture-flow state, bumps `captureSession`, `_Concurrency.Task{ @MainActor [weak self] ... }` awaits `engine.requestAuthorization()`, wires `onFinal`/`onError`/`onPartial`, sets Apple's `allowServerFallback` | `TodayView` (:84), `Sidebar` (:71 via `toggleCapture`), `MenuBarMenuContent` (`VolarApp.swift:199`), `PopoverView` (:865), `MorningFrogView` (:77 via `toggleCapture`) | fire-and-forget `_Concurrency.Task` (700-730); explicit `@MainActor` hop documented at 698-699 |
| 85 | `handleCaptureError(_:)` : 735 | cmd, `private` | Special-cases `.onDeviceUnavailable` (sets `pendingServerConsent`); else sets `captureErrorDetail` from `describe(_:)` | called from `startCapture`'s `onError` closure | sync (but invoked from an async callback) |
| 86 | `describe(_:)` : 752 | static helper, `private static` | Maps `SpeechCaptureError` to user copy | — | sync |
| 87 | `cancelCapture()` : 763 | cmd | bumps `captureSession`, resets to `.idle`, `runningEngine?.cancel()` (FIX 2a: discards audio, no `onFinal`/`onError`) | `TodayView` (:42), `PopoverView` (:138,847) | sync |
| 88 | `stopCapture()` : 787 | cmd | **FIX 1** — see §5 | called from `toggleCapture()`'s "stop" branch | sync |
| 89 | `toggleCapture()` : 814 | cmd | `stopCapture()` if recording else `startCapture()` | `Sidebar` (:71), `MorningFrogView` (:77) | sync |
| 90 | `openDictationSettings()` : 825 | cmd | `NSWorkspace.shared.open(url)` with fallback candidates | `PopoverView` (:893) | sync — **macOS-only** (`NSWorkspace`, `x-apple.systempreferences:` URL scheme) |
| 91 | `useServerRecognition()` : 836 | cmd | sets `allowServerRecognition = true`, persists, clears `pendingServerConsent`, calls `startCapture()` | `PopoverView` (:912) | sync |
| 92 | `setRecognitionLocale(_:)` : 844 | cmd | sets + persists `recognitionLocaleID`, `speech.setLocale(...)` | `SettingsView` (:205) | sync |
| 93 | `setSpeechEngine(_:)` : 852 | cmd | sets + persists `speechEngineChoice`; fire-and-forget `Task { await whisper.prepare() }` when `.whisperKit` chosen | `SettingsView` (:154) | fire-and-forget `_Concurrency.Task` (856) |
| 94 | `parseEnginePreference` : 864 | derived | `cloudParseConsent == true ? .cloud : .onDevice` | `SettingsView` (:183,195) | sync |
| 95 | `setParseEngine(_:)` : 873 | cmd | sets + persists `cloudParseConsent` | `SettingsView` (:184) | sync |
| 96 | `finishRecording(transcript:)` : 887 | cmd | classifies delegation intent → voice-done → else `proceedToCapture` | called from `startCapture`'s `engine.onFinal` closure | sync (invoked from an async callback) |
| 97 | `proceedToCapture(transcript:)` : 916 | cmd, `private` | Gates on `cloudParseConsent == nil` (pause for consent) else `runParse` | internal (also re-entered by `captureVoiceDoneAsNewTask`) | sync |

### 1.13 Voice-done confirm / delegation intent (932-1137)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 98 | `voiceDoneOpenTasks` : 936 | derived, `private` | Maps `openTasks` to `VoiceDoneTask` (id/title/unsatisfied `.external` descriptions) | internal to `finishRecording` |
| 99 | `presentVoiceDoneConfirm(action:candidates:)` : 958 | cmd, `private` | Zero candidates → `voiceDoneNoMatchTranscript`; else caps to 10 and sets `voiceDoneConfirm` | internal |
| 100 | `delegationTriggerPhrases` : 978 | static list, `private static` | see §1.7 | internal to `classifyDelegationIntent` |
| 101 | `classifyDelegationIntent(_:)` : 989 | derived, `private` | Folds + matches trigger phrases, extracts minutes | internal to `finishRecording` |
| 102 | `foldForMatch(_:)` : 997 | static helper, `private static` | diacritic/case fold | internal |
| 103 | `extractCheckBackMinutes(from:)` : 1005 | static helper, `private static` | regex extraction, clamped 1...240 | internal |
| 104 | `presentDelegationConfirm(checkBackMinutes:)` : 1023 | cmd, `private` | No `activeTask` → no-match row; else builds a single-candidate `VoiceDoneConfirm(.delegate(...))` | internal |
| 105 | `confirmVoiceDone(taskId:)` : 1045 | cmd | Clears `voiceDoneConfirm` FIRST (idempotency), dispatches `.complete`→`toggleDone`, `.clearExternal`→`clearExternalCondition`, `.delegate`→`delegateTask`; then `finishVoiceDoneUI` | `PopoverView` (:613,620) |
| 106 | `dismissVoiceDoneConfirm()` : 1066 | cmd | bumps `captureSession`, clears confirm/no-match state, `runningEngine?.cancel()` | `PopoverView` (:716) |
| 107 | `captureVoiceDoneAsNewTask()` : 1082 | cmd | consumes `voiceDoneNoMatchTranscript`, calls `proceedToCapture` | `PopoverView` (:686) |
| 108 | `clearExternalCondition(taskId:now:)` : 1093 | cmd, `private` | store path: `store.clearFirstExternalCondition`, refresh, reschedule reminders, `notifyEligibilityAndScheduleResurface`. No-store: mutates first unsatisfied `.external` condition in place | internal to `confirmVoiceDone` |
| 109 | `finishVoiceDoneUI(action:)` : 1119 | cmd, `private` | sets `.done`, speaks result, 900ms auto-dismiss via session-guarded `_Concurrency.Task.sleep` | internal | fire-and-forget sleep (1131-1136) |
| 110 | `resolveCloudConsent(allow:)` : 1143 | cmd | sets + persists `cloudParseConsent`, resumes `pendingParseTranscript` via `runParse` | `PopoverView` (:941,960) |
| 111 | `runParse(transcript:)` : 1158 | cmd, `private` | `.parsing`, `await router.parse(...)`, builds capped `confirmDrafts` with pre-resolved conditions + conflicts | internal | fire-and-forget `_Concurrency.Task` (1164-1190) |
| 112 | `preResolveConditions(_:)` : 1196 | derived, `private` | auto-resolves confident `.taskDone` via fuzzy match | internal |
| 113 | `struct FuzzyMatch` : 1208 | type, `private` | `id`, `score` | internal |
| 114 | `bestFuzzyMatch(for:in:)` : 1217 | static helper, `private static` | Jaccard token-overlap over `openTasks` | internal |
| 115 | `tokenize(_:)` : 1235 | static helper, `private static` | lowercase+fold+split | internal |

### 1.14 Confirm-card chip interactions (1244-1559)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 116 | `dismissAttribute(_:forDraft:)` : 1255 | cmd | `confirmDrafts[i].dismissed.insert`, `logCorrection` | `PopoverView` (:159,161,163,165,167,168,169) |
| 117 | `acceptUncertainAttribute(_:forDraft:)` : 1263 | cmd | `.accepted.insert`, `logCorrection` | `PopoverView` (:158,160,162,164,166) |
| 118 | `dismissCondition(at:forDraft:)` : 1271 | cmd | `.dismissedConditions.insert`, clears `.resolvedTaskDone`, `logCorrection` | `PopoverView` (:171,173,175,180) |
| 119 | `acceptUncertainCondition(at:forDraft:)` : 1285 | cmd | `.acceptedConditions.insert`, `logCorrection` | `PopoverView` (:170,172) |
| 120 | `resolveTaskDone(at:to:forDraft:)` : 1297 | cmd | sets/clears `.resolvedTaskDone`, `logCorrection` | `PopoverView` (:176,179,535,541) |
| 121 | `removeDraft(_:)` : 1313 | cmd | `confirmDrafts.removeAll` | `PopoverView` (:319) |
| 122 | `dismissConflictAdvisory(forDraft:)` : 1320 | cmd | sets `.conflictDismissed = true` | `PopoverView` (:351) |
| 123 | `logCorrection(kind:attribute:task:correctedValue:)` : 1331 | cmd, `private` | `store?.recordCorrection(...)`, no-op without a store | internal to every chip method above |
| 124 | `parsedValueDescription(kind:task:)` : 1341 | derived, `private` | maps `ChipKind` → the parsed value's string form | internal to `logCorrection` |
| 125 | `confirmSave()` : 1359 | cmd | `.saving`, materializes every draft (+ follow-up review tasks), chunks by `TaskStore.maxBatchSize`, `store.addBatch` per chunk, refresh, `notifyEligibilityAndScheduleResurface`, `scheduleRemindersForSavedItems`, `finishSaveUI`. Catch branch still refreshes+reschedules before surfacing the error. | `PopoverView` (:796, `.keyboardShortcut(.defaultAction)`) | sync (no async inside — the parse already happened in `runParse`) |
| 126 | `scheduleRemindersForSavedItems(_:)` : 1433 | cmd, `private` | filters `items` against the just-refreshed `tasks` before scheduling, so a partial-chunk failure never schedules an orphan | internal |
| 127 | `materialize(_:now:)` : 1445 | derived, `private` | `ConfirmDraft` → `TaskItem` | internal |
| 128 | `resolvedValue(_:kind:draft:)` : 1478 | derived, `private` | generic: present + not-dismissed + (confident OR accepted) | internal |
| 129 | `resolvedConditions(_:)` : 1489 | derived, `private` | maps `task.conditions` per the drop/accept/resolve rules | internal (also used by `computeConflicts`) |
| 130 | `uiPriority(from:)` : 1513 | static helper, `private static` | clamps engine `1...4` into UI `Priority` `1...3` | internal |
| 131 | `materializeFollowUpReview(for:now:)` : 1526 | derived, `private` | builds the derived `.review` task with `.taskDone(parent.id)` | internal |
| 132 | `finishSaveUI(titles:)` : 1546 | cmd, `private` | `.done`, clears `confirmDrafts`, speaks result, 900ms session-guarded auto-dismiss | internal | fire-and-forget sleep (1553-1558) |

### 1.15 Focus session methods (1561-1642)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 133 | `startFocus()` : 1563 | cmd | resets `focusSecondsLeft`/`focusPaused`, sets `focusIndex` to the frog's index (or 0), `focusActive = true`, speaks (if `voiceFeedback`), (re)arms `focusTimer` | `TodayView` (:219,469) |
| 134 | `focusTick()` : 1591 | cmd, `private` | **FIX B target** — decrements `focusSecondsLeft`, calls `endFocus()` at zero | driven by `focusTimer` only |
| 135 | `endFocus()` : 1603 | cmd | invalidates `focusTimer`, resets `focusActive`/`focusSecondsLeft`/`focusPaused` | `FocusOverlay` (:170), `TodayView` (:434) |
| 136 | `toggleFocusPause()` : 1611 | cmd | `focusPaused.toggle()` | `FocusOverlay` (:167), `TodayView` (:424) |
| 137 | `completeFocusTask(_:)` : 1617 | cmd | **FIX 3** — see §5 | `FocusOverlay` (:143) |
| 138 | `readDayAloud()` : 1638 | cmd | `voice.readDay(self)` | `TodayView` (:80) |

### 1.16 Appearance controls (1644-1719)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 139 | `setAccent(_:)` : 1657 | cmd | **FIX 4** — see §5 | `SettingsView` (:428) |
| 140 | `setDensity(_:)` : 1665 | cmd | **FIX 4** — see §5 | `SettingsView` (:443) |
| 141 | `densityPersistedID(_:)` : 1674 | static helper, `private static` | `Density → "cozy"/"comfy"/"roomy"` | internal (mirrors `SettingsView.densityID(_:)`) |
| 142 | `densityFromPersistedID(_:)` : 1691 | static helper, `private static` | inverse, `nil` on garbage | internal to `init` |
| 143 | `setAmbient(_:)` : 1701 | cmd | sets + persists `ambient` | `SettingsView` (:374) |
| 144 | `setCustomImage(_:)` : 1710 | cmd | sets `customImageURL`; non-nil → also forces `ambient = .custom` + persists both; nil → removes the key only | `SettingsView` (:469) |

### 1.17 Ambient sound / frog-of-day / breakdown / banner (1721-1805)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 145 | `toggleAmbientSound()` : 1726 | cmd | `ambientSound.toggle(ambient == .none ? .rain : ambient)` | `TodayView` (:77) |
| 146 | `setFrog(_:)` : 1742 | cmd | store path: `store.setFrog`, refresh. No-store: loop-mutate `tasks[i].frog` | `pickFrog` (internal caller) — **FIX 6**, mentioned in-file but not one of the four 2026-07-19 fixes this task tracks (see note in §5) |
| 147 | `pickFrog(_:)` : 1756 | cmd | `setFrog`, `showMorningFrog = false` | `VolarApp.swift`'s sheet `onPick` (:125) |
| 148 | `dismissMorningFrog()` : 1762 | cmd | `showMorningFrog = false` | `VolarApp.swift`'s sheet `onSkip` (:126) |
| 149 | `saveBreakdown(_:)` : 1769 | cmd | `addTask` per title, `showBreakdown = false` | `VolarApp.swift`'s sheet `onSave` (:136) |
| 150 | `showReminderPreview()` : 1789 | cmd | sets `reminderBanner` from `activeTask` or a hardcoded sample | `VolarApp.swift`'s `MenuBarMenuContent` (:206) |
| 151 | `dismissBanner()` : 1803 | cmd | clears `reminderBanner` | `TodayView` (:55,56,57,66) |

### 1.18 Eligibility / resurface (1807-1929)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 152 | `resurfaceSession: Int` : 1812 | stored, `private var` | Monotonic guard, same pattern as `captureSession` | none directly |
| 153 | `notifyEligibilityAndScheduleResurface(before:now:)` : 1826 | cmd, `private` | `VolarCore.eligibilityDiff`, `scheduler?.notifyUnblocked`, `scheduleNextResurface` | called by `addTask`, `toggleDone`, `confirmSave`, `delegateTask` (NOT `deleteTask`, which reuses the store's own diff) |
| 154 | `scheduleNextResurface(from:now:)` : 1843 | cmd, `private` | **FIX 2** — see §5 | called by the above + `clearExternalCondition`, `triageDefer`, `deleteTask`, `activateServices` |
| 155 | `computeConflicts(for:now:)` : 1906 | derived, `private` | builds a throwaway `VolarCore.Task`, calls `VolarCore.conflicts(forAdding:...)` | internal to `runParse` |

### 1.19 Weekly triage (1931-2016)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 156 | `staleThreshold`/`triageDeferInterval` : 1933-1934 | constants, `private static` | 7 days / 3 days | internal |
| 157 | `staleTasks` : 1946 | derived | `openTasks.filter { (triageKeptAt[id] ?? createdAt) <= cutoff }` | `VolarApp.swift`'s `.task` gate (:87) and `.sheet` `items:` (:155) — **`TriageView` never reads this directly** |
| 158 | `dismissBatchSheetsIfEmpty()` : 1958 | cmd, `private` | **FIX A** — see §5 | called at the tail of `triageKeep/Breakdown/Defer/Drop`, `sweepComplete` |
| 159 | `triageKeep(_:)` : 1965 | cmd | `triageKeptAt[id] = clock()`, `persistTriageKeptAt`, `dismissBatchSheetsIfEmpty` | `VolarApp.swift`'s sheet `onKeep` (:156) |
| 160 | `triageBreakdown(_:)` : 1979 | cmd | `showBreakdown = true`, `dismissBatchSheetsIfEmpty` | `VolarApp.swift`'s sheet `onBreakdown` (:157) |
| 161 | `triageDefer(_:)` : 1987 | cmd | store path: `store.addCondition(.afterDate(...))`, refresh, reschedule, `notifyEligibilityAndScheduleResurface`. No-store: in-place append | `VolarApp.swift`'s sheet `onDefer` (:158) |
| 162 | `triageDrop(_:)` : 2007 | cmd | `deleteTask`, `dismissBatchSheetsIfEmpty` | `VolarApp.swift`'s sheet `onDrop` (:159) |
| 163 | `persistTriageKeptAt()` : 2012 | cmd, `private` | writes `triageKeptAt` dict to `UserDefaults` | internal to `triageKeep` |

### 1.20 Evening sweep (2017-2129)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 164 | `showSweep: Bool` : 2023 | stored, default `false` | set by `maybeShowEveningSweep`; cleared by `VolarApp.swift`'s sheet binding / `dismissSweep` | `VolarApp.swift`'s `.sheet` (:164-176) — **`SweepView` never reads this directly** |
| 165 | `sweepLastShownDayKey` : 2025 | key, `private static` | `"volar.sweepLastShownDay"` | internal |
| 166 | `sweepItems` : 2032 | derived | `openTasks` (fixed from a `nowTasks`-only bug per the in-file MINORS comment, 2027-2031) | `VolarApp.swift`'s sheet `items:` (:169) |
| 167 | `maybeShowEveningSweep()` : 2063 | cmd | `delegation?.reconcileBatch()` → merges into `dueDelegationRechecks`; day-gates `showSweep` | `VolarApp.swift`'s `.task` (:99, gated on hour>=18 at the call site) |
| 168 | `isoDayKey(from:)` : 2091 | static helper, `private static` | POSIX/Gregorian day-key formatter, duplicated from `VolarApp.swift`'s own `day` computation | internal |
| 169 | `sweepComplete(_:)` : 2103 | cmd | `toggleDone`, `dismissBatchSheetsIfEmpty` | `VolarApp.swift`'s sheet `onComplete` (:170) |
| 170 | `sweepSkip(_:)` : 2112 | cmd | intentionally empty (documented no-op) | `VolarApp.swift`'s sheet `onSkip` (:171) |
| 171 | `dismissSweep()` : 2117 | cmd | `showSweep = false` | `VolarApp.swift`'s sheet `onDismiss` (:172) |

### 1.21 Settings (2130-2145)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 172 | `setVoiceDeliveryMode(_:)` : 2134 | cmd | sets + persists `voiceDeliveryMode` at `voiceDeliveryModeKey` | `SettingsView` (:320) |
| 173 | `setGlobalReminderPolicy(_:)` : 2140 | cmd | sets + JSON-persists `globalReminderPolicy` | `SettingsView` (:308) |

### 1.22 Service activation / overdue scan (2147-2220)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 174 | `activateServices()` : 2155 | lifecycle | `hotkey.start(appState: self)`, `scheduler?.rebuildFromStorage()`, `offerRescheduleForOverdueTasks`, `scheduleNextResurface` (re-arm), `startDelegationTimer()`, conditional `whisper.prepare()` | called from BOTH `VolarApp.swift`'s main-window `.task` (:59) AND `AppDelegate.applicationDidFinishLaunching` (:247) — deliberate double-call, documented idempotent | fire-and-forget `Task{ await whisper.prepare() }` (2192) when applicable |
| 175 | `offerRescheduleForOverdueTasks(now:)` : 2210 | cmd, `private` | for every overdue open task without an already-outstanding "resurface" record, `scheduler.offerReschedule(taskId:)` | internal to `activateServices` |

### 1.23 Delegation orchestrator (2222-2350)

| # | Name : line | Kind | Reads / Mutates | UI consumers |
|---|---|---|---|---|
| 176 | `startDelegationTimer()` : 2230 | cmd, `private` | invalidates any prior timer, calls `refreshDelegationQueue()` once immediately, then arms a 60s repeating `Timer` | internal to `activateServices` |
| 177 | `refreshDelegationQueue(now:)` : 2254 | cmd | `dueDelegationRechecks = delegation?.dueForRecheck(now:) ?? []` | called by the timer, `activateServices` (via `startDelegationTimer`), `delegateTask`, `resolveDelegationDone/StillWaiting/CheckLater`, `onAppLinkHandled`, `resolveAppLinkDisambiguation` |
| 178 | `delegateTask(_:label:checkBackMinutes:)` : 2268 | cmd | `delegation.delegate(...)`, refresh `tasks`, reschedule reminders, `notifyEligibilityAndScheduleResurface`, `refreshDelegationQueue` | `TodayView` (:262,308), `confirmVoiceDone` (.delegate case) |
| 179 | `resolveDelegationDone(_:)` : 2284 | cmd | `toggleDone`, `refreshDelegationQueue` | `TodayView` (:923) |
| 180 | `resolveDelegationStillWaiting(_:)` : 2291 | cmd | `delegation?.bumpBackoff`, `refreshDelegationQueue` | `TodayView` (:924) |
| 181 | `resolveDelegationCheckLater(_:minutes:)` : 2301 | cmd | re-delegates same task with fresh check-back, `refreshDelegationQueue` | `TodayView` (:925) |
| 182 | `onAppLinkHandled()` : 2314 | cmd | `refreshFromStore()` FIRST, then `lastAppLinkAt = clock()`, mirrors `pendingDisambiguationTaskIDs`, `refreshDelegationQueue` | `AppDelegate.application(_:open:)` (`VolarApp.swift:329`) |
| 183 | `resolveAppLinkDisambiguation(taskId:)` : 2332 | cmd | `appLinkHandler?.resolveDisambiguation`, THEN `refreshFromStore()`, mirrors queue, `refreshDelegationQueue` | `TodayView` (:874) |
| 184 | `dismissAppLinkDisambiguation()` : 2346 | cmd | `appLinkHandler?.dismissDisambiguation()`, clears `pendingDisambiguationTaskIDs` | `TodayView` (:895) |

---

## 2. `VolarApp.swift` inventory (@main app + scenes + AppDelegate)

| Member : line | Kind | Detail |
|---|---|---|
| `@NSApplicationDelegateAdaptor(AppDelegate.self) appDelegate` : 8 | property wrapper | Constructed before `VolarApp.init()` body runs (its default-init expression is declared above `appState`) — this ordering is why `init()` can safely assign `appDelegate.appState = state` at line 32. |
| `@State appState: AppState` : 9 | state | THE single `AppState` instance for the whole app. |
| `@AppStorage("hasOnboardedV1") hasOnboarded` : 10 | persisted UI flag | Gates the onboarding sheet (:111-119). **Not** a key in `AppState` — this and the next two `@AppStorage` keys live in `VolarApp.swift` itself, a second persistence surface the Windows port must also account for (not just `AppState`'s `UserDefaults` keys). |
| `@AppStorage("morningFrogLastShown") frogLastShown` : 12 | persisted UI flag | Day-key gate ("yyyy-MM-dd"), read/set in the `.task` block (:72-75). |
| `@AppStorage("triageLastShownWeek") triageLastShownWeek` : 15 | persisted UI flag | ISO-week-key gate ("2026-W29"), read/set in the `.task` block (:81-90). |
| `init()` : 17-33 | lifecycle | `try? TaskStore()` (graceful degrade to `nil`), constructs the ONE `AppState(store:)`, assigns it to both `_appState` and `appDelegate.appState` — "exactly one `AppState` in the app" is stated explicitly in the doc comment (27). |
| `body: some Scene` : 35-183 | scene graph | `MenuBarExtra` (label=`MenuBarLabel`, content=`MenuBarMenuContent`, `.menuBarExtraStyle(.window)`) + `Window("Volar", id:"main")` (hosts `TodayView`, six `.sheet`s, one `.task`) + `Settings` (hosts `SettingsView`). |
| `Window("main")`'s `.task` : 49-101 | lifecycle hook | Calls `appState.activateServices()` (**also** called from `AppDelegate` — deliberate double-call, both idempotent); computes the day-key and conditionally sets `showMorningFrog`; computes the ISO-week-key and conditionally sets `showTriage` (gated on `!appState.staleTasks.isEmpty`); computes the hour and conditionally calls `appState.maybeShowEveningSweep()` (gated `hour >= 18`). **This `.task` runs only while the main window is open** — since Volar is `LSUIElement` (menu-bar-only), that's why the three window-independent concerns below were moved to `AppDelegate`. |
| Six `.sheet(...)` on the `Window` : 111-176 | scene modifiers | Onboarding (`!hasOnboarded`), MorningFrog (`showMorningFrog`), Breakdown (`showBreakdown`), TaskDetail (`detailTaskID != nil`), Triage (`showTriage`, `items: appState.staleTasks`), Sweep (`showSweep`, `items: appState.sweepItems`). Every sheet body gets `.environment(appState)`; only Triage/Sweep pass explicit `items:`/callback closures instead of letting the child view read `AppState` itself. |
| `private struct MenuBarMenuContent` : 189-215 | view | "Open Volar" (`openWindow(id:"main")`), "New task" (`appState.startCapture()` + open window), `SettingsLink`, "Preview reminder" (`appState.showReminderPreview()`), Quit. |
| `@MainActor final class AppDelegate: NSObject, NSApplicationDelegate` : 228-332 | lifecycle | See below — this is where the three window-independent observers live. |
| `AppDelegate.appState: AppState?` : 235 | stored, `var` (not `let`) | Set once from `VolarApp.init()` after `AppState` exists; every use-site is `?.`-guarded. |
| `applicationDidFinishLaunching(_:)` : 237-272 | lifecycle | Calls `appState?.activateServices()` (F1/F2 fix — the double-call with the `.task` above), `UNUserNotificationCenter.current().requestAuthorization(...)` (best-effort, `@Sendable` closure — required to avoid a Swift 6 MainActor-isolation trap, per the inline comment 251-254), `NotificationActions.registerCategories()`, then `registerWindowIndependentObservers()`. |
| `registerWindowIndependentObservers()` : 277-311 | lifecycle | Registers TWO app-lifetime `NotificationCenter` observers — see §6. |
| `application(_:open:)` : 326-331 | lifecycle | Handles inbound `volar://` links: `appState?.appLinkHandler?.handle(url)` then `appState?.onAppLinkHandled()`, per URL. This is the AppKit-level equivalent of `.onOpenURL` that fires regardless of window state — **Windows equivalent needed: custom URI scheme registration + a way to receive the activation args in a running single-instance process** (e.g. via a named pipe / second-instance redirect, since WinUI 3 doesn't have an automatic `.onOpenURL`). |

---

## 3. Cluster proposal (6-10 candidate C# services)

**A. `TaskListService`** (the store-facing CRUD + derived-groupings core)
- Owns: `tasks`, and every CRUD/mutation method: `addTask`, `toggleDone`, `deleteTask`, `refreshFromStore`, `setFrog`, and the derived groupings `nowTasks`/`laterTasks`/`doneTasks`/`openTasks`/`frogTask`/`activeTask`/`detailTask`/`detailTaskID`/`openDetail`/`closeDetail`.
- Needs injected: `TaskStore` (or its C# port), a clock, `ReminderScheduler`-equivalent (for the reminder side-effects inside `toggleDone`/`deleteTask`/`addTask`), and the eligibility/resurface tail (cluster D).
- This is the one cluster every other cluster depends on — `tasks` is the cross-cluster state (see §4).

**B. `CaptureFlowService`** (voice capture → parse → confirm → save)
- Owns: `captureState`, `liveTranscript`, `confirmDrafts`, `captureErrorDetail`, `pendingServerConsent`, `pendingCloudConsent`, `pendingParseTranscript`, `captureSession`, `runningEngine`, `selectedEngine`, plus every method from §1.12-1.14 (`startCapture` through `finishSaveUI`, `confirmSave` and all chip-interaction methods).
- Needs injected: the speech-engine trio (cluster F), `IntentRouter` (parsing), `TaskListService` (to materialize/save), `VoicePlayback` (spoken confirmations).
- **Flagged — dual-cluster**: `preResolveConditions`/`bestFuzzyMatch`/`resolvedConditions` read `openTasks` (cluster A's derived state) to resolve `.taskDone` dependencies. Lean: keep in B, inject `openTasks` as a read as opposed to giving B its own task cache — B should never own a second copy of task state.

**C. `VoiceDoneAndDelegationIntentService`** (finishRecording's classification branch + delegation handoff)
- Owns: `voiceDoneConfirm`, `voiceDoneNoMatchTranscript`, `voiceDoneOpenTasks`, `classifyDelegationIntent`/`delegationTriggerPhrases`/`foldForMatch`/`extractCheckBackMinutes`, `presentVoiceDoneConfirm`/`presentDelegationConfirm`, `confirmVoiceDone`/`dismissVoiceDoneConfirm`/`captureVoiceDoneAsNewTask`/`clearExternalCondition`/`finishVoiceDoneUI`.
- **Flagged — dual-cluster**: this is really a sub-mode of B's `finishRecording` (932-1137 sits physically inside the same MARK region as B). Lean: merge into B rather than a separate service — splitting it creates a two-way call cycle (`finishRecording` in B must call into C, and C's `.complete`/`.delegate` actions call back into A/E) for no isolation benefit, since both are driven by the exact same `captureSession`/`runningEngine` state B already owns. Listed separately here only because the task brief's granularity wants every MARK region examined on its own merits.

**D. `EligibilityAndResurfaceService`** (T031/T032 — the "shared tail" every mutation calls)
- Owns: `resurfaceSession`, `notifyEligibilityAndScheduleResurface`, `scheduleNextResurface`, `computeConflicts`.
- Needs injected: `TaskListService` (reads `tasks`, writes `tasks` back via the wake-continuation's `store.fetchAll()`), `ReminderScheduler`-equivalent, a clock.
- Small and mechanical but must NOT be inlined into A — it is called from six+ different mutation sites (`addTask`, `toggleDone`, `confirmSave`, `delegateTask`, `clearExternalCondition`, `triageDefer`) plus `activateServices`, and its own internal continuation-chaining (FIX 2) is exactly the kind of subtle timer logic that should be unit-testable in isolation.

**E. `FocusSessionService`**
- Owns: `focusActive`, `focusPaused`, `focusSecondsLeft`, `focusIndex`, `focusTimer`, `startFocus`/`focusTick`/`endFocus`/`toggleFocusPause`/`completeFocusTask`.
- Needs injected: `TaskListService` (for `openTasks`/`frogTask`, and `completeFocusTask`'s call into `toggleDone`), `VoicePlayback` (spoken feedback, gated by `voiceFeedback`).
- **Flagged**: `voiceFeedback` itself (a top-level stored bool, §1.1 row 7) has no owner cluster of its own — it's read only by E and by nothing else. Lean: give E ownership of `voiceFeedback` too, even though it's declared with the "frozen §4" properties at the top of the Swift file, since E is its only consumer.

**F. `SpeechEngineService`** (the freemium tier picker + the three engines)
- Owns: `speech`/`whisper`/`groq` instances, `speechEngineChoice`, `allowServerRecognition`, `recognitionLocaleID`, `setSpeechEngine`/`setRecognitionLocale`/`useServerRecognition`/`openDictationSettings`.
- Needs injected: nothing beyond `UserDefaults`-equivalent (Windows: a settings store) — this cluster is otherwise self-contained.
- **Windows delta is severe here** — see §7. `speech` (Apple on-device ASR with live partial results) has no Windows analog at all; `openDictationSettings` (`NSWorkspace` + `x-apple.systempreferences:` URL) is 100% macOS.

**G. `ReminderAndDeliverySettingsService`**
- Owns: `voiceDeliveryMode`, `globalReminderPolicy`, `setVoiceDeliveryMode`/`setGlobalReminderPolicy`, plus the `voiceChannel`/`reminderGate`/`scheduler` collaborator references (construction only — `ReminderScheduler` itself is sibling-owned and out of this inventory's scope, but AppState's *wiring* of it belongs here).
- **Cross-cluster note**: `scheduler` is called from clusters A, D, and the triage/sweep/delegation clusters below — it is a shared collaborator injected everywhere, not owned exclusively by G in the sense of "only G calls it." G owns its *construction and settings*, not its *call sites*.

**H. `TriageAndSweepService`** (weekly stale-task batch + evening sweep)
- Owns: `triageKeptAt`, `staleTasks`, `showTriage` (bool ownership contested — see below), `triageKeep`/`triageBreakdown`/`triageDefer`/`triageDrop`/`persistTriageKeptAt`, `showSweep`, `sweepItems`, `maybeShowEveningSweep`/`sweepComplete`/`sweepSkip`/`dismissSweep`, `dismissBatchSheetsIfEmpty`.
- **Flagged — dual ownership of `showTriage`/`showBreakdown`/`showSweep`/`showMorningFrog`**: these four booleans are set directly by `VolarApp.swift`'s `.task` block (not through an `AppState` method) as well as by methods inside `AppState`. In C#, whichever "shell"/window-orchestration layer replaces `VolarApp.swift`'s `.task` needs either write access to these flags or H needs to expose `maybeShowTriage()`/`maybeShowMorningFrog()` gate-methods so the shell never touches the flags directly. Lean: add those two missing gate-methods to H/E respectively during the port rather than replicating the "shell pokes AppState's bool directly" pattern — it's the one place in this file where the frozen boundary between "app shell" and "AppState" is already blurry, and a from-scratch C# port doesn't need to keep that wart.

**I. `DelegationOrchestratorService`** (Phase 6 / US4 — AI handoff to Claude Code)
- Owns: `dueDelegationRechecks`, `pendingDisambiguationTaskIDs`, `lastAppLinkAt`, `delegationTimer`, `delegation`/`appLinkHandler`/`claudeConnector` collaborator wiring, `startDelegationTimer`/`refreshDelegationQueue`/`delegateTask`/`resolveDelegationDone`/`resolveDelegationStillWaiting`/`resolveDelegationCheckLater`/`onAppLinkHandled`/`resolveAppLinkDisambiguation`/`dismissAppLinkDisambiguation`.
- **Flagged**: `delegateTask` is called both from I's own ambient-card flow AND from cluster C (`confirmVoiceDone`'s `.delegate` case) AND from `TodayView` directly. It must stay a public method on I that both B/C and the UI can call — not a candidate for splitting further.
- Windows delta: `appLinkHandler`'s `volar://` URL handling needs a completely different activation mechanism (see §2's `application(_:open:)` note and §7).

**J. `AppearanceAndPersistenceService`**
- Owns: `accent`, `density`, `glass`, `ambient`, `customImageURL`, `setAccent`/`setDensity`/`setAmbient`/`setCustomImage`, `densityPersistedID`/`densityFromPersistedID`, `toggleAmbientSound`, `ambientSound` collaborator.
- **Flagged**: `glass` has no setter/persistence at all (§1.1 row 4) — a pre-existing gap, not something to silently "fix" by inventing a `setGlass` the Mac app never had; note it and ask before adding one during the port, since the four 2026-07-19 fixes were scoped narrowly and this isn't one of them.
- Cross-cluster: `toggleAmbientSound`'s `ambientSound.isPlaying` feeds `reminderGate.isOtherAudioPlaying` (G's collaborator) — a genuine cross-cluster read, see §4.

**Where `router`/`store`/`clock`/`voice`/`hotkey`/`voiceDone`/`claudeConnector` land**: these are cross-cutting collaborators, not cluster-owned state. `store` and `clock` should be constructor-injected into every cluster that needs them (A, B, D, H, I); `voice` (TTS) into B, C, E; `hotkey` is a pure input-trigger that should live at the app-shell layer (it calls `toggleCapture()` on B, nothing else) — do not fold it into any of the ten clusters above, it's infrastructure, not app state.

---

## 4. Cross-cluster state (read by more than one candidate cluster)

| State | Owning cluster (lean) | Also read by | Implication |
|---|---|---|---|
| `tasks` | A (`TaskListService`) | B (materialize/save), C (`voiceDoneOpenTasks`), D (before/after diffing), E (`openTasks`/`frogTask`), H (`staleTasks`/`sweepItems`), I (`delegateTask` looks up titles), views everywhere | **The** shared observable task list. Every other cluster needs a *reference* to A, not its own copy — this is the strongest argument for A being constructed first and injected everywhere else, mirroring how `store` itself is threaded through today. |
| `openTasks` (derived from `tasks`) | A | B (`runParse`'s `openTaskTitles`, `preResolveConditions`, `resolveConditions`'s taskDone matching), C (`voiceDoneOpenTasks`), E (`startFocus`'s frog-index, `focusTick`'s bounds), H (`staleTasks`) | Same implication — must be a live read-through, not a snapshot copied at construction time. |
| `activeTask` (derived from `tasks`) | A | E (`presentDelegationConfirm`, `showReminderPreview`), views | Must recompute fresh every read (no caching) in the C# port too — this is the exact property `.volarTasksDidChange` exists to keep honest (§6). |
| `captureSession` | B | (not read outside B today, but any split-out C would need it) | If C is kept separate from B (against this doc's lean), `captureSession` becomes cross-cluster; merging them avoids that. |
| `scheduler` (`ReminderScheduler`) | G (construction) | A, D, H, I (all call `scheduleReminders`/`cancelReminders`/`notifyUnblocked`/`scheduleResurface`/`rebuildFromStorage`/`offerReschedule`) | A shared collaborator reference, not owned state — inject everywhere. |
| `store` (`TaskStore?`) | — (app-level, not cluster-owned) | A, B, D, H, I | The nullable-store "graceful degrade" pattern (§1.6 row 36) must be preserved identically wherever it's injected — every cluster needs its own `guard store else { <fallback> }` branch, exactly as today. |
| `clock` | — (app-level) | nearly everywhere | Inject as a single shared abstraction (e.g. `ITimeProvider`) for testability, matching the Swift `() -> Date` closure. |
| `ambientSound.isPlaying` | J | G (`reminderGate.isOtherAudioPlaying` closure, wired once in `init`) | A cross-cluster *read* set up once at construction — J must expose this as an observable/pollable property G's collaborator can query. |
| `dueDelegationRechecks` | I | views only (no other cluster reads it) | Not actually cross-cluster among the ten — listed for completeness since it's easy to mistake for shared state. |
| `voiceFeedback` | E (per §3's lean) | nowhere else | Listed to explicitly rule it OUT as cross-cluster, despite living among the top-level "frozen" properties. |

---

## 5. Refresh / notification topology (liveness — the Windows port must reproduce this or the UI goes stale)

### 5.1 `.volarTasksDidChange` — the one custom `NotificationCenter` name in the app

- **Declared**: `AppState.swift:16-18`.
- **Posted**: exactly one call site — `Sources/Reminders/ReminderScheduler.swift:308`, inside `ReminderScheduler.handleAction` (the notification "Done" action), **immediately after** that method mutates `TaskStore` directly via `store.toggle(...)`. This is deliberate: FR-014/015/016 forbid a notification action from touching `AppState`/the app window directly, so the scheduler mutates the store and then posts this notification as the ONLY hand-off back to the UI layer.
- **Observed**: exactly one call site — `VolarApp.swift`'s `AppDelegate.registerWindowIndependentObservers()` (287-293):
  ```swift
  NotificationCenter.default.addObserver(
      forName: .volarTasksDidChange, object: nil, queue: .main
  ) { @Sendable [weak self] _ in
      Task { @MainActor in
          self?.appState?.refreshFromStore()
      }
  }
  ```
  Registered on `AppDelegate` (app-lifetime, survives the main window being closed) rather than as a SwiftUI `.onReceive` on the `Window` scene — the F1/F2 integration fix's whole point (comment block `VolarApp.swift:102-110`) is that `.onReceive` attached to the `Window` scene stops firing the moment that window closes, which is the *normal* state for this `LSUIElement` menu-bar app.
- **Windows port requirement**: needs an equivalent pub/sub that (a) fires regardless of whether any window is currently visible, and (b) is observed exactly once, from an app-lifetime object (not a page/window-scoped one). A C# `event` on a singleton service, or a weak-referenced `WeakEventManager`, both work; the critical property to preserve is "the subscriber must be constructed once at app startup and never torn down with a window."

### 5.2 The second wake-recovery observer (same file, same pattern, different notification)

- `AppDelegate.registerWindowIndependentObservers()` also registers `NSWorkspace.didWakeNotification` on `NSWorkspace.shared.notificationCenter` (304-310), calling `scheduler?.rebuildFromStorage()` on wake. The in-file comment (295-303) explicitly flags that `ReminderScheduler.init`'s OWN internal wake observer registers on the *wrong* notification center (`NotificationCenter.default` instead of `NSWorkspace.shared.notificationCenter`, where this event actually posts) and so may never fire — this `AppDelegate` path is "the one guaranteed-correct path." Windows equivalent: `SystemEvents.PowerModeChanged` (`PowerModeChanged == Resume`) or WinRT `SystemNavigationManager`-adjacent sleep/resume APIs — whichever the Windows port already uses for sleep/wake, it must call the equivalent of `rebuildFromStorage()` on it.

### 5.3 `store.fetchAll()` re-reads — every place `tasks` gets reloaded wholesale from the backing store

All thirteen call sites (grepped, `AppState.swift`):
`578` (doc comment) → actual assignments at **591** (`toggleDone`), **623** (`deleteTask`), **647** (`refreshFromStore`), **1106** (`clearExternalCondition`), **1410**/**1421** (`confirmSave` success/catch), **1750** (`setFrog`), **1880** (`scheduleNextResurface`'s wake continuation), **1998** (`triageDefer`), **2273** (`delegateTask`).

Every one of these follows the exact same shape: mutate the store first, then `tasks = store.fetchAll()` as one atomic assignment — never a hand-patched in-memory edit on the store-backed path. This atomicity is what gives `activeTask`/`MenuBarLabel` (both re-derived from `tasks` on every read) their "no intermediate empty/list state" property. **Any C# port must preserve "mutate collaborator → reload full list → notify observers" as a single unit**, not split into "mutate" then "later, separately, someone refreshes" — that's precisely the WG-C gap the whole `.volarTasksDidChange` mechanism exists to patch for the ONE call site that can't follow this pattern (the notification-action path).

### 5.4 The local (non-durable) resurface wake continuation

Distinct from 5.1/5.2: `scheduleNextResurface` (1843-1896) arms a `_Concurrency.Task.sleep`-based one-shot continuation, guarded by `resurfaceSession`, that fires purely in-memory when the next `.afterDate` passes while the app is running. This is NOT a `NotificationCenter` posting — it directly re-reads `store.fetchAll()` (1880) and then recursively re-arms itself (1894, see FIX 2 in §6). Windows needs an equivalent cancellable delayed-continuation primitive (`CancellationTokenSource` + `Task.Delay`, re-armed the same way) — this is orthogonal to the two `NotificationCenter` names above and must be ported as its own mechanism, not folded into them.

---

## 6. The four 2026-07-19 bug fixes — exact quotes, so porting agents cannot reintroduce the pre-fix behavior

### FIX 1 — `stopCapture()` must always set `.parsing` before `engine.stop()`

Location: `AppState.swift:787-809`.

```swift
func stopCapture() {
    if let engine = runningEngine, engine.isRunning {
        // FIX 1: `SpeechCapture.stop()` sets `isRunning = false` SYNCHRONOUSLY
        // (SpeechCapture.swift:308) but the final transcript still arrives async via
        // `onFinal`. This used to only flip to `.parsing` for a batch engine
        // (`!supportsPartialResults`), so a partial-results engine (Apple) stayed stuck in
        // `.recording` for that whole gap. A second `stopCapture()` call landing in that
        // window then fell through to the `else if captureState == .recording` branch below,
        // which bumps `captureSession` — invalidating the very session `onFinal`'s guard
        // checks — and silently swallowed the transcript. `.parsing` is the correct state for
        // EVERY engine here: it means "mic is off, waiting on the final result," which is
        // just as true with partial results as without. It is also what disarms the second
        // call: with `isRunning` already false AND `captureState` no longer `.recording`,
        // neither branch matches, so `stopCapture()` becomes a clean no-op that leaves the
        // in-flight session intact instead of taking the destructive `else if`.
        captureState = .parsing
        engine.stop()
    } else if captureState == .recording {
        captureSession += 1
        captureState = .idle
        liveTranscript = ""
    }
}
```

**The invariant to preserve**: `captureState = .parsing` MUST be set unconditionally for every engine (not gated on `!supportsPartialResults`), and it must happen BEFORE `engine.stop()` is called (not after). A re-entrant/second call to `stopCapture()` while `.parsing` is in flight must be a no-op — never fall through to the `captureSession += 1` branch, which would orphan the in-flight `onFinal` callback.

### FIX 2 — resurface must be registered for EVERY task with a future `.afterDate`, chained on wake, re-armed in `activateServices()`

Three sub-locations, all load-bearing together:

**(a) Register every task's own earliest `.afterDate`, not just the single global-earliest one** — `AppState.swift:1843-1868`:
```swift
private func scheduleNextResurface(from snapshot: [VolarCore.Task], now: Date) {
    resurfaceSession += 1
    let session = resurfaceSession
    // FIX 2: `VolarCore.nextResurfaceDate` returns only the SINGLE earliest `.afterDate`
    // across the whole snapshot, so registering just that one task with the durable scheduler
    // left every OTHER task's `.afterDate` completely unregistered. ...
    var earliestOverall: Date?
    for task in snapshot {
        var earliestForTask: Date?
        for condition in task.conditions {
            guard case .afterDate(let date) = condition, date > now else { continue }
            if earliestForTask == nil || date < earliestForTask! { earliestForTask = date }
        }
        guard let taskDate = earliestForTask else { continue }
        scheduler?.scheduleResurface(at: taskDate, taskId: task.id)
        if earliestOverall == nil || taskDate < earliestOverall! { earliestOverall = taskDate }
    }
    guard let date = earliestOverall else { return }
    ...
```

**(b) Chain forward on wake** — `AppState.swift:1886-1895` (inside the same method's sleep continuation):
```swift
            // FIX 2 (chain): the refresh above only advances `tasks` past the resurface moment
            // that just fired — on its own it does NOT re-arm whichever `.afterDate` comes next.
            // Re-running this same method against a fresh snapshot/`now` is what chains forward.
            // This cannot loop forever: the moment that just fired is now <= `now` (this closure
            // only runs once the sleep above has elapsed), and the scan above requires strictly
            // `date > now` to even be a candidate, so that same moment can never be picked again —
            // each recursive call either lands on a strictly later date (and stops after that
            // one sleep) or finds none left at all (and returns immediately, ending the chain).
            self.scheduleNextResurface(from: self.tasks.map { $0.snapshot() }, now: self.clock())
```

**(c) Re-armed on launch, inside `activateServices()`** — `AppState.swift:2174-2182`:
```swift
        // FIX 2 (re-arm on launch): `scheduleNextResurface`'s local one-shot wake (the sleep
        // continuation inside it) lives only in memory, so it doesn't survive a quit/relaunch —
        // without this call, a task with a future `.afterDate` would sit unregistered (durably
        // AND locally) until some other mutation happened to touch `tasks` first. Idempotent if
        // `activateServices()` is ever called twice: ...
        scheduleNextResurface(from: tasks.map { $0.snapshot() }, now: clock())
```

**The invariant to preserve**: (1) scan ALL tasks for their own earliest future `.afterDate`, not just the global minimum; (2) the wake continuation must re-invoke the scheduling function again against a fresh snapshot, so it self-chains rather than firing once; (3) `activateServices()` must call it once at launch (and be safe to call twice, since it's already double-called from both `VolarApp.swift`'s `.task` and `AppDelegate`).

### FIX 3 — `completeFocusTask` must count `openTasks.count` AFTER the mutation

Location: `AppState.swift:1617-1636`.

```swift
func completeFocusTask(_ id: UUID) {
    // FIX 3: `remaining` used to be computed as `openTasks.count - 1` BEFORE calling
    // `toggleDone`, assuming completing one task always drops the open count by exactly one.
    // That's not true: `TaskStore.completeOne` (TaskStore.swift:394) resets a task with a
    // `recurrence` back to `.status == .todo` in place rather than closing it — it stays in
    // `openTasks`, a delta of 0, not -1 — and `TaskStore.toggle`'s parent auto-complete
    // cascade (TaskStore.swift:367-369) can additionally close the now-childless parent in
    // the same call, a delta of -2. Reading `openTasks.count` fresh AFTER `toggleDone` (which
    // itself refreshes `tasks` from the store) reports whichever of those actually happened
    // instead of guessing "-1".
    toggleDone(id)
    let remaining = openTasks.count
    focusIndex = remaining > 0 ? max(0, min(focusIndex, remaining - 1)) : 0
    if remaining == 0 {
        focusActive = false
    }
    if voiceFeedback {
        voice.speak(remaining > 0 ? "Done. \(remaining) left today." : "Done. All clear.")
    }
}
```

**The invariant to preserve**: never assume completing a task changes `openTasks.count` by exactly `-1`. Always call the completion mutation first (which refreshes the task list from the store), THEN read the count. A recurring task can produce a delta of `0`; a parent auto-complete cascade can produce `-2`.

### FIX 4 — `accent`/`density` must persist (keys + load in init)

Four locations, all load-bearing together — the key declarations, the init-time load-back, and the two setter methods:

**Keys** — `AppState.swift:387,394`:
```swift
    private static let accentKey = "volar.accent"
    ...
    private static let densityKey = "volar.density"
```

**Load-back in `init`, AFTER the parameter assignment** — `AppState.swift:426-434`:
```swift
        // FIX 4: same override convention as `ambient`/`customImageURL` immediately above —
        // persisted choice wins, caller-supplied parameter is only the previews/tests fallback.
        if let raw = UserDefaults.standard.string(forKey: Self.accentKey), let a = VolarAccent(rawValue: raw) {
            self.accent = a
        }
        if let raw = UserDefaults.standard.string(forKey: Self.densityKey),
           let d = Self.densityFromPersistedID(raw) {
            self.density = d
        }
```

**Setters** — `AppState.swift:1657-1668`:
```swift
    func setAccent(_ a: VolarAccent) {
        accent = a
        UserDefaults.standard.set(a.rawValue, forKey: Self.accentKey)
    }
    ...
    func setDensity(_ d: Density) {
        density = d
        UserDefaults.standard.set(Self.densityPersistedID(d), forKey: Self.densityKey)
    }
```

**Why this was a bug** (the in-file doc comment on `accentKey`, 381-386, quoted verbatim because it states the failure mode precisely): *"there was no read-back from `UserDefaults` here (unlike every other Settings → Appearance control ...) and no write anywhere either, so a real launch (`VolarApp.swift` calls `AppState(store:)` with neither parameter supplied) silently reset both to their compiled-in defaults (`.indigo`/`.comfy`) every time, discarding whatever `SettingsView` had set last session."*

**The invariant to preserve**: `SettingsView`'s accent/density controls must call `setAccent`/`setDensity` (never assign `appState.accent`/`appState.density` directly — the in-file comment at `SettingsView.swift:427` literally warns "`appState.accent = candidate` never survived relaunch"), and `init` must read the persisted value back AFTER assigning the constructor parameter default, exactly mirroring how `ambient`/`customImageURL` already did it.

---

## 7. Windows deltas — members that cannot port as-is

| macOS member / API | Why it can't port as-is | What the Windows port needs |
|---|---|---|
| `speech: SpeechCapture` (Apple Speech framework, on-device + server recognition, **live partial results** via `onPartial`) | No Apple Speech framework on Windows | Per the task brief, Windows already accepted **batch-only capture with no live caption** — so `liveTranscript`'s `onPartial`-driven updates (`AppState.swift:729`) simply have no Windows equivalent; the port's capture UI should show a "listening…" state instead of a live-updating transcript, and `SpeechCapture`'s role is filled by whatever local Windows ASR is chosen (e.g. `Windows.Media.SpeechRecognition` for on-device, wired the same way `speech` is here) |
| `whisper: WhisperKitEngine` (Swift package, CoreML/GGML-backed) | Swift-only package | A native `whisper.cpp`/ONNX-runtime binding invoked from C#, or drop this tier entirely for v1 and keep only Apple-equivalent-on-device + Groq (cloud) |
| `groq: GroqEngine` (pure HTTP client) | None — ports directly | `HttpClient`-based, no delta |
| `openDictationSettings()` (`NSWorkspace.shared.open`, `x-apple.systempreferences:` URL scheme) | macOS System Settings deep-link scheme | Windows equivalent: launch `ms-settings:speech` (Windows Speech settings) via `Process.Start` or `Launcher.LaunchUriAsync` |
| `claudeConnector.connect(bookmarkedClaudeDir:)` (uses a **security-scoped bookmark**, resolved from an `NSOpenPanel`-selected directory, per `SecureImageBookmark`/similar sibling helpers referenced in `SettingsView.swift`) | Security-scoped bookmarks are a macOS sandboxing mechanism with no Windows analog | Windows: a plain persisted folder path (via `FolderPicker`) is sufficient since Windows apps in this unpackaged/self-contained deployment mode don't need sandboxed re-authorization on every launch — but note this DOES mean losing the "survives even if the app is sandboxed later" guarantee; flag as a deliberate simplification, not silently dropped |
| `setCustomImage(_:)` persisting a **plain file path string** (not a bookmark) — the doc comment at 1706-1709 already flags this as "not sandboxed today ... if sandboxing is ever enabled, this needs a security-scoped bookmark instead" | N/A — already a plain path today | Windows: same plain-path persistence is fine (`FolderPicker`/`FileOpenPicker` result path), no bookmark equivalent needed |
| `MenuBarExtra` scene (`VolarApp.swift:36-43`, `.menuBarExtraStyle(.window)`) + `MenuBarLabel`/`MenuBarMenuContent` | SwiftUI-only API | Per memory (`Wave 3-A DONE`), the Windows port already has a tray icon via Win32 P/Invoke — `MenuBarMenuContent`'s four actions (Open Volar / New task / Settings / Preview reminder / Quit) need a tray context-menu equivalent, and `MenuBarLabel`'s dynamic label (recording pulse, focus countdown, delegation badge count) needs to be redrawn onto the tray icon or its tooltip |
| `Window("Volar", id:"main")` + `Settings { }` scenes, `@NSApplicationDelegateAdaptor`, `NSApplication.shared.terminate` | SwiftUI `App`/AppKit-specific | WinUI 3 `Window` + a settings window/page; app delegate concerns map to `App.xaml.cs`'s `OnLaunched`/activation handling |
| `UNUserNotificationCenter.current().requestAuthorization`/`NotificationActions.registerCategories()` (`AppDelegate.applicationDidFinishLaunching`) | macOS notification framework | Windows: `Microsoft.Windows.AppNotifications` (App SDK) or legacy `ToastNotificationManager`, with equivalent action-button categories (Done/Snooze/Tomorrow, etc.) |
| `AppDelegate.application(_:open:)` handling `volar://` links | AppKit's `application(_:open:)` Apple-event delivery | Windows needs custom URI-scheme registration (`ms-settings` style `Windows.ApplicationModel.Activation`/`AppInstance.GetActivatedEventArgs`) plus single-instance redirection (via `Microsoft.Windows.AppLifecycle`'s `AppInstance.FindOrRegisterForKey`) so a second `volar://` launch redirects into the already-running process instead of starting a new one — there is no `.onOpenURL`-equivalent for an already-running background app on Windows without this extra plumbing |
| `NSWorkspace.shared.notificationCenter` / `NSWorkspace.didWakeNotification` (sleep/wake) | AppKit-specific | `Microsoft.Win32.SystemEvents.PowerModeChanged` (`PowerModes.Resume`), or the WinRT equivalent already chosen elsewhere in the Windows port |
| `NWPathMonitor` inside `DefaultCloudParseGate.isOnline()` | Apple Network framework | `System.Net.NetworkInformation.NetworkChange.NetworkAvailabilityChanged`, or simply drop to "assume online, let the HTTP call itself fail gracefully" given the protocol's own doc comment already sanctions "true when unknown" as valid |
| `FoundationModels` (mentioned in the task brief as an Apple-only concern) | **Not actually referenced anywhere in `AppState.swift`/`VolarApp.swift`** — grepped, zero hits in either file. It may be used inside `IntentRouter`'s own implementation (`Sources/Parsing/IntentParsing.swift`, sibling-owned, out of this inventory's two target files) as the on-device "foundationModel" fallback the doc comment at line 275 mentions. Flag for whoever inventories `IntentRouter` directly — not a delta this file's inventory can resolve. | — |
| `HotkeyManager` (Carbon `RegisterEventHotKey`) | Already ported per memory — Windows uses `RegisterHotKey` (branch `window`) | No further action; noted here only for completeness since `AppState.hotkey` is one of the collaborators this inventory covers |
| `Timer` + `RunLoop.main.add(_:forMode:.common)` (used for `focusTimer`/`delegationTimer`) | Foundation `Timer` ports fine conceptually but the exact API differs | .NET `System.Threading.Timer` or a `DispatcherTimer` (if UI-thread affinity is wanted, mirroring the `@MainActor` hop every Swift timer callback here does explicitly) |

---

## 8. Miscellaneous cross-checks for the implementation agents

- **`FocusOverlay` mutates `AppState` state directly**, not through methods: `focusIndex` is written at `FocusOverlay.swift:199,204` (prev/next), and a debug/preview helper in `MenuBarLabel.swift:152-153` writes `focusActive`/`focusSecondsLeft` directly. If the C# port wants stricter encapsulation (all mutation through service methods), these two call sites need either a small `AppState`/`FocusSessionService` method added (`stepFocusIndex(by:)`) or an explicit decision to keep direct property writes for view-local navigation — flag for design review, not a silent behavior change.
- **`showBreakdown`/`showTriage`/`showSweep`/`showMorningFrog` are set directly by `VolarApp.swift`'s `.task` block**, not through `AppState` methods (see §3 cluster H's flag) — the shell "reaches into" `AppState`'s bools. A C# port that wants a clean shell/service boundary should add gate-methods; this doc flags it rather than resolving it, since it isn't one of this task's "own files."
- **`TriageView` and `SweepView` never read `AppState` at all** (§0 preamble) — they're the cleanest components in the whole view layer to port first, since they need only bound data + callbacks, no service reference.
- **Two persistence surfaces exist, not one**: `AppState`'s own ~15 `UserDefaults` keys (§1.7), AND `VolarApp.swift`'s three `@AppStorage` keys (`hasOnboardedV1`, `morningFrogLastShown`, `triageLastShownWeek`, §2). A Windows settings-store design needs to account for both, even though only the first set lives in the file this task calls "AppState.swift."
