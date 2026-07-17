# Volar v2 — Mac Build & Verify Checklist (feature 002)

Nguồn: Opus final integration verify 2026-07-17 @ commit `f907570`. Toàn bộ code viết trên
Windows, CHƯA build/test lần nào. Đây là runbook verify thật sự trên Mac.

## ★ Phát hiện tích hợp #1 (BUG THẬT — cần xử) — menu bar bị "đơ" khi cửa sổ đóng

**Vấn đề (F1/F2, mức HIGH):** các observer refresh — `.onReceive(.volarTasksDidChange)`,
`.onOpenURL` (`volar://ai-done`), và `NSWorkspace.didWakeNotification` — đều gắn vào **scene
`Window("Volar")`**, KHÔNG gắn vào `MenuBarExtra` (luôn sống). Với app menu-bar (LSUIElement)
mà cửa sổ thường đóng, các observer này bị teardown → khi bấm "Done" trên notification, hoặc
nhận signal `volar://ai-done`, hoặc sleep/wake, **menu bar KHÔNG refresh** — vẫn hiện task đã
xong là "NOW" cho tới khi mở lại cửa sổ. Phá đúng cái fix WG-C của Phase 4/6, và vi phạm
constitution IV (reminder recovery) + V (glance-and-dismiss).

**Fix (nhỏ, gọn):** chuyển observer refresh ra chỗ sống độc lập với cửa sổ — gắn vào
`MenuBarExtra` label, hoặc một observer cấp `AppDelegate`/`NotificationCenter` tồn tại lâu hơn
cửa sổ. File: `Volar/Sources/App/VolarApp.swift:85–118`. **Cần verify trên Mac: `MenuBarExtra`
label có re-render theo `@Observable` khi cửa sổ đóng không** — đây là #1 điều cần xác nhận.

## Verdict tổng: LIKELY-COMPILES = at-risk

Lệch về "yes" trên trục rename/type-wiring (sạch). Rủi ro còn lại 100% là **API-shape đoán mò**
của framework (không build được trên Windows) + bug F1/F2 ở trên. Không có compile-break tích hợp.

## A. Runbook build & test (theo đúng thứ tự)

1. **Engine trước (phải xanh trước mọi thứ):**
   `cd VolarCore && swift build && swift test` — thư viện thuần, 0 dependency framework, nên
   SẼ compile được trên Mac; đây là mỏ neo tin cậy cho constitution III.
2. **Generate project app:** `cd Volar && xcodegen generate` — xác nhận ra `Volar.xcodeproj`
   với target/scheme test `VolarTests` chạy được (target này `// UNVERIFIED`, project.yml).
3. **Build app trong Xcode** (scheme `Volar`, Debug). Lỗi đầu tiên sẽ là các hotspot framework
   bên dưới, không phải logic app. Sửa API shape → build lại.
4. **Chạy test app-side:** `xcodebuild test -scheme Volar` — verify `@testable import Volar`
   (ReminderSchedulerTests) link được với Debug app target.
5. **Test migration store cũ:** mở app 1 lần với store on-disk **pre-002** (schema Voci/VolarTask
   cũ) → xác nhận SwiftData mở được CẢ HAI container (default + `VolarReminders`) không crash
   destructive-migration.
6. **Backend:** `supabase functions deploy parse` + set `GEMINI_API_KEY` (+ App Attest env cho
   free tier); smoke-test route `/parse`.
7. **Test seam F1/F2:** đóng cửa sổ chính → bắn reminder + bấm "Done" trên notification → mở
   `volar://ai-done?cwd=…` → sleep/wake → xác nhận badge NOW trên menu bar cập nhật. Nếu không →
   dời observer ra khỏi scene `Window` (fix ở trên).

## B. Hotspot `// UNVERIFIED` xếp theo rủi ro (check thứ tự này)

1. **`Volar/Sources/Parsing/FoundationModelParser.swift`** (8 markers) — RỦI RO COMPILE CAO NHẤT.
   Verify `@Generable` struct, `SystemLanguageModel.default.availability`, `LanguageModelSession(instructions:)`
   khớp API FoundationModels macOS 26 thật.
2. **`Volar/Sources/Parsing/DeviceCheckProvider.swift`** (7) — `DCAppAttestService`
   (`generateKey`/`attestKey`/`generateAssertion`) khớp server verifier `supabase/functions/_shared/auth.ts`.
3. **`Volar/Sources/Speech/HotkeyManager.swift`** — `import Carbon.HIToolbox`, `RegisterEventHotKey`/
   `InstallEventHandler`/`EventHotKeyRef`, `EventHandlerUPP`. Đặc biệt: **chạy dưới sandbox KHÔNG
   cần Accessibility** (lý do bật sandbox).
4. **SwiftData 2 container** (`TaskStore.swift:62`, `ReminderScheduler.swift:460`) — cả hai
   `ModelContainer` mở cùng lúc lúc launch, store `"VolarReminders"` không đụng; test path
   `try?`→in-memory fallback.
5. **`VolarApp.swift:85–118` scene-observer** — seam F1/F2 (runbook bước 7).
6. **`nonisolated(unsafe) static let` regex/detector** (`NLParser.swift:281,341,404,438,481,497,531`)
   — Swift 6 strict-concurrency (`SWIFT_STRICT_CONCURRENCY: complete`) chấp nhận, không data-race.
7. **`@Sendable` closure + `@MainActor`** — `UNUserNotificationCenter…{@Sendable}` (VolarApp),
   `Task { @MainActor [weak self] }` (AppState) — comment nói `@Sendable` load-bearing tránh
   EXC_BREAKPOINT isolation trap; confirm dưới strict concurrency.
8. **`volar://` onOpenURL** — `open volar://ai-done?cwd=…` thật tới được handler + mở lại cửa sổ.
9. **`ClaudeCodeConnector` merge settings.json** — logic append/marker-match `hooks.Stop` khớp
   schema hook Claude Code THẬT hiện tại; chỉ thêm/xóa entry marker `volar://`. Verify grant
   Connect (Settings dùng key `…settingsUI`, connector `detect()` dùng key khác — F3) resolve được.

## Constitution status (app tích hợp)

- I On-device/privacy: **PASS** · II Never silently guess: **PASS** · III Pure engine: **PASS**
  (VolarCore thuần + test target riêng) · **IV Reliable reminders: AT-RISK** (do F1/F2) ·
  **V Glance-and-dismiss: AT-RISK** (do F1/F2). → Fix F1/F2 đưa IV/V về PASS.

## Còn lại (không chặn ship-gate)

Restyle FocusOverlay/Settings/sheets; `TaskStore.setDelegation` (bỏ UserDefaults shadow);
`/attest/register` cho free-tier cloud parse; WhisperKit SPM có thể phải bump version trên Mac;
P3–P4 (calendar/accomplishment view/capture-at-scale/export).
