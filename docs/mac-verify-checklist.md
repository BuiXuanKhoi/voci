# Volar v2 — Mac Build & Verify Checklist (feature 002)

Nguồn: Opus final integration verify 2026-07-17 @ commit `f907570`. Toàn bộ code viết trên
Windows, CHƯA build/test lần nào. Đây là runbook verify thật sự trên Mac.

> **CẬP NHẬT 2026-07-26 — đọc trước mục #1 ngay dưới.** (a) Bug F1/F2 **ĐÃ ĐƯỢC FIX trong code**:
> ba observer đã dời sang `AppDelegate` (`VolarApp.swift` `init()` + `applicationDidFinishLaunching`),
> không còn treo vào scene `Window`. Mục #1 giữ nguyên làm lịch sử/bối cảnh — vẫn phải chạy bước 7
> của runbook để verify trên Mac thật, nhưng đừng đi "sửa" lại nữa. (b) **Volar không còn là app
> `LSUIElement`**: `Info.plist` đã bỏ key đó và scene `Window` đã được đảo lên trước `MenuBarExtra`,
> nên app giờ có Dock icon và tự mở cửa sổ lúc launch. Mọi câu dưới đây nói "app menu-bar, cửa sổ
> thường đóng" là mô tả trạng thái CŨ.

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

## C. Guided tour (coach-mark sau onboarding) — verify thủ công (thêm 2026-07-27)

Feature mới: `Volar/Sources/Views/Tour/*` + `AppState.swift`/`VolarApp.swift`/`Sidebar.swift`/
`TodayView.swift` sửa theo — xem mục ★★★ đầu `backlog.md` để biết đủ danh sách file. CHƯA build/
chạy trên Mac lần nào; toàn bộ bước dưới đây phải làm bằng tay trên máy Mac thật.

1. **Reset trạng thái "đã xem tour" + onboarding** (Terminal, trước khi mở app):
   ```
   defaults delete tech.kioh.Volar volar.hasSeenTourV1
   defaults delete tech.kioh.Volar hasOnboardedV1
   ```
   (Đổi `tech.kioh.Volar` nếu bundle id khác lúc build — xem `PRODUCT_BUNDLE_IDENTIFIER` trong
   `project.yml`.)
2. **Relaunch app** → hoàn tất 3 bước onboarding (bấm "Start using Volar" HOẶC "Skip for now" —
   cả 2 nút đều gọi `onComplete`) → xác nhận tour tự bật ngay sau đó, KHÔNG cần thao tác gì thêm.
3. **Test ở cửa sổ nhỏ nhất** (kéo về đúng `minWidth: 820, minHeight: 560`):
   - Stop 1 "capture": lỗ sáng phải khoanh đúng vùng nút "Tap to speak" + 3 badge ⌃⌥M trong
     Sidebar (không lệch, không cắt).
   - Stop 2 "list": lỗ sáng phải phủ đúng khối NOW/NEXT/Later/Completed bên phải.
   - Stop 3 "focus": lỗ sáng phải khoanh đúng nút "Start focus" (spotlight NOW) — nếu chưa có
     task nào eligible (test riêng ở bước 5), phải tự động khoanh nút "Focus" nhỏ ở frog pill
     thay vào đó (fallback anchor), KHÔNG được hiện card không-anchor giữa màn hình khi hai nút
     này tồn tại.
   - Stop 4 "calendar": card canh giữa màn hình (không anchor) — bấm "Enable Calendar" phải bật
     đúng hộp thoại xin quyền Calendar thật của macOS (không phải giả lập); Cho phép xong card
     phải tự chuyển sang dòng "Calendar connected · N calendars"; Từ chối xong quay lại tour (mở
     lại bằng Settings → Replay) phải hiện đúng dòng "Calendar access is off..." + nút "Open
     System Settings" mở đúng pane Privacy ▸ Calendars.
4. **Lặp lại y hệt bước 3 ở cửa sổ lớn** (kéo full màn hình hoặc ~1600×1000) — xác nhận card
   tooltip không tràn ra ngoài cửa sổ, hole/ring vẫn bám đúng vị trí nút thật sau khi resize.
5. **Test với 0 task** (dùng install sạch, chưa capture task nào) — xác nhận stop 2 vẫn khoanh
   được đúng `EmptyTodayCard` (không phải danh sách trống/crash), và stop 3 rơi vào fallback
   anchor (nút "Focus" ở frog pill) như mô tả ở bước 3.
6. **Test với vài task đã có** (capture 2-3 task, ít nhất 1 task có `frog = true` để có NOW) —
   xác nhận stop 3 khoanh đúng nút "Start focus" thật (primary anchor), không rơi vào fallback.
7. **Skip / Back / Next / Esc:**
   - "Next →" đi đúng thứ tự 4 stop, dot progress cập nhật đúng.
   - "Back" chỉ hiện từ stop 2 trở đi, quay lại đúng stop trước.
   - "Skip" (mọi stop, kể cả stop 4) đóng tour ngay lập tức.
   - Phím Esc đóng tour y hệt Skip; phím Return/Enter hoạt động như "Next →" (ở stop cuối, Return
     coi như kết thúc tour).
   - Trong lúc tour đang mở, click vào vùng lỗ sáng (nút thật đang được khoanh) KHÔNG được thực
     hiện hành động thật (không mở capture, không toggle task) — scrim phải nuốt click kể cả qua
     lỗ.
8. **Không lặp lại + Replay:** đóng app, mở lại → tour KHÔNG tự bật lần thứ hai. Vào Settings →
   hàng "Replay guided tour" (do Agent B thêm) → xác nhận tour bật lại từ stop 1 dù đã xem rồi.
9. **Không đè sheet khác:** nếu launch app đúng lúc app đang định hiện morning-frog/triage/evening
   -sweep (VD relaunch sau 18h với task tồn đọng), xác nhận sheet đó KHÔNG mở chồng lên tour —
   tour phải chạy xong (hoặc bị Skip/Esc) trước, sheet kia mới có cơ hội hiện ở lần mở tiếp theo.

## D. Calendar mirroring (task → Calendar) — verify thủ công (thêm 2026-07-27, fix-and-wire pass)

Feature: `Volar/Sources/Integrations/CalendarSync.swift` (+ `CalendarAccess.swift`), wired qua
`AppState.calendarSync`/`syncCalendarMirror()`/`setCalendarMirror(_:)`/`enableCalendarAccess()`.
CHƯA build/chạy trên Mac lần nào — mọi bước dưới đây phải làm bằng tay trên máy Mac thật. Đặc biệt
chú ý bước 3 — đó là regression của **FIX 1 (bug trùng event)** vừa sửa, đáng để verify kỹ nhất.

1. **Grant access:** Settings → Calendar access → "Enable Calendar" (hoặc bấm "Enable Calendar" ở
   stop cuối guided tour) → xác nhận đúng hộp thoại xin quyền Calendar thật của macOS bật lên; cho
   phép xong dòng trạng thái chuyển thành "Connected · N calendars" ngay lập tức (không cần đóng mở
   lại Settings).
2. **Bật mirroring:** Settings → "Mirror tasks to Calendar" → bật toggle → mở app Calendar.app →
   xác nhận có **calendar mới tên "Volar"** xuất hiện trong sidebar (không phải chèn vào calendar
   có sẵn nào).
3. **Test KHÔNG trùng event (FIX 1 — quan trọng nhất):** tạo 1 task có giờ cụ thể (VD "họp lúc 3h
   chiều mai") → xác nhận **đúng MỘT** event xuất hiện trong calendar "Volar". Sau đó làm liên tiếp
   vài thao tác edit khác (VD: toggle done rồi mở lại, sửa task khác, thêm task mới) mà KHÔNG đụng
   gì tới task vừa tạo → mở lại Calendar.app, xác nhận **vẫn chỉ có đúng 1 event** cho task đó, không
   nhân đôi/nhân ba. Đây chính xác là bug đã sửa: event mới tạo trước đây có thể không ghi được
   `eventIdentifier` vào `eventMap` (đọc trước khi commit), khiến lần `reconcile` kế tiếp tạo thêm
   event thứ 2 cho cùng 1 task.
4. **Sửa giờ task → event dời chỗ, không tạo thêm:** đổi giờ task ở bước 3 sang giờ khác → xác nhận
   event TRONG calendar "Volar" **dời theo giờ mới** (cùng 1 event, `eventIdentifier` không đổi),
   không phải một event mới cạnh event cũ.
5. **Tick done → event biến mất:** đánh dấu task đó "Done" → xác nhận event tương ứng **biến mất**
   khỏi calendar "Volar" (không phải chuyển màu/gạch ngang — biến mất hẳn, đúng
   `isDesired` = "chưa done + có deadline").
6. **Tắt mirroring → dọn sạch, không đụng calendar khác:** tạo lại vài task có giờ (để có vài event
   trong "Volar"), ghi chú số event hiện có trong MỘT calendar KHÁC (VD calendar mặc định của
   iCloud) trước khi tắt → Settings tắt "Mirror tasks to Calendar" → xác nhận: (a) mọi event Volar
   tạo trong calendar "Volar" biến mất ngay lập tức, không cần chờ; (b) calendar "Volar" bản thân
   nó vẫn còn (chỉ xoá event, không xoá calendar — đúng thiết kế, `deleteVolarCalendar()` là hành
   động khác, chưa có nút bấm trong Settings); (c) số event trong calendar KHÁC ở bước ghi chú
   **không đổi một event nào**.
7. **Thu hồi quyền → app im lặng, không crash:** System Settings → Privacy & Security → Calendars →
   tắt quyền của Volar → quay lại app, tạo/sửa 1 task có giờ → xác nhận app KHÔNG crash, không hiện
   lỗi đỏ (rule "no red for status") — `lastError`/Settings vẫn hiện trạng thái "Access is off" một
   cách bình thường, và **`eventMap`/event cũ trong "Volar" calendar không bị xoá** (vì access mất
   thì không xoá được gì cả — đây là FIX 2a, tránh mồ côi event vĩnh viễn). Bật lại quyền → xác nhận
   mirroring hoạt động lại bình thường (không phải cấu hình lại từ đầu).
8. **Bật lại mirroring qua guided tour:** reset trạng thái tour (xem mục C bước 1) → chạy lại tour
   tới stop cuối → xác nhận copy card đúng "Volar can read your calendar to see what's already
   booked..." (không còn nói "read-only" nữa) → bấm "Enable Calendar" tại đây cũng phải mirror ngay
   lập tức nếu mirroring đã bật sẵn từ trước (không cần đợi task edit kế tiếp).

## E. Launch at login (`LoginItem.swift`/`SMAppService`) + dual-identity auth hint — verify thủ công
## (thêm 2026-07-27, submission-prep pass)

Feature: `Volar/Sources/App/LoginItem.swift` (mới) + `SettingsView.swift`/`AppState.swift`/
`VolarApp.swift` sửa theo. CHƯA build/chạy trên Mac lần nào — mọi bước dưới đây phải làm bằng tay
trên máy Mac thật. Đặc biệt chú ý bước 4 — đó là `// UNVERIFIED` `launchIsDefaultUserInfoKey`, rủi
ro cao nhất trong pass này.

1. **Bật "Launch at login":** Settings → General → toggle "Launch at login" ON → xác nhận macOS
   hiện thông báo hệ thống kiểu "Volar" đã được thêm mục khởi động (login item) → mở System Settings
   ▸ General ▸ Login Items → xác nhận **Volar có trong danh sách**. Nếu trạng thái là "cần phê
   duyệt" (`.requiresApproval`), xác nhận Settings hiện đúng dòng giải thích + nút "Open Login
   Items…" mở đúng pane đó → bấm phê duyệt trong System Settings → quay lại Settings (đóng/mở lại
   cửa sổ Settings) → xác nhận toggle giờ đọc ON thật (không còn dòng "cần phê duyệt" nữa). Reboot
   máy (hoặc log out/log in) → xác nhận **Volar tự khởi động**.
2. **Tắt "Launch at login":** toggle OFF → xác nhận Volar **biến mất khỏi** System Settings ▸
   General ▸ Login Items ngay lập tức (không cần đóng/mở lại System Settings).
3. **Tắt từ System Settings sau lưng app (nguồn sự thật là `SMAppService.status`, không phải bản
   cache):** bật lại toggle ở bước 1 → tắt Accessibility... à không, tắt đúng mục "Volar" trực tiếp
   trong System Settings ▸ General ▸ Login Items (KHÔNG qua Settings của Volar) → quay lại app, mở
   lại cửa sổ Settings (đóng hẳn rồi mở lại để `.onAppear` chạy lại) → xác nhận toggle đọc **OFF** —
   đây chính là điều chứng minh `loginItemStatus` đọc `SMAppService.mainApp.status` sống mỗi lần mở
   Settings, không phải một bản cache đứng yên nói dối.
4. **Cửa sổ chính có tự mở lúc login hay không (`// UNVERIFIED`):** với "Launch at login" đang ON,
   log out rồi log in lại (hoặc reboot) → quan sát: Volar có tự mở cửa sổ chính lên màn hình không,
   hay chỉ có Dock icon + menu bar mà không có cửa sổ nào bật lên? **Ghi lại kết quả quan sát được
   dù là gì** — đây là hành vi `NSApplication.launchIsDefaultUserInfoKey` không thể verify từ
   Windows (xem comment trong `VolarApp.swift`'s `applicationDidFinishLaunching`). Nếu cửa sổ VẪN
   tự mở dù đã thêm guard này, đó là residual gap đã ghi chú sẵn trong code (scene `Window` đứng
   đầu `body` có thể tự mở bất kể `showMainWindow()` có gọi hay không) — cần một fix khác (không
   phải hack close()-sau-khi-mở mù quáng), ghi lại để xử lý tiếp chứ đừng tự sửa ngay tại bước verify
   này.
5. **Badge "Last time you signed in with…":** đăng xuất hết (nếu đang có tài khoản) → Sign in with
   Apple → sau khi đăng nhập thành công, Sign out → quay lại tab Account (trạng thái signed-out) →
   xác nhận dòng **"Last time you signed in with Sign in with Apple."** hiện phía trên nút "Sign in
   with Apple". Lặp lại với email OTP (Send code → Verify → Sign out) → xác nhận badge đổi thành
   **"Last time you signed in with Email code."**
6. **Gợi ý dual-identity ở tài khoản free đã đăng nhập:** đăng nhập bằng MỘT trong hai phương thức
   (account free, chưa mua Pro) → tab Account → xác nhận phía dưới khối "Upgrade to Pro" hiện đúng
   dòng nhắc tên phương thức CÒN LẠI (VD nếu vừa đăng nhập bằng Apple, dòng nhắc phải nói
   "...you subscribed using Email code, sign out and sign back in that way..." — tức PHƯƠNG THỨC
   KIA, không phải phương thức vừa dùng). Xác nhận không có nút tự động sign-out nào ở dòng này —
   chỉ là text hướng dẫn.

## F. ⌃⌥T typed capture ("type → Add task → done") — verify thủ công (thêm 2026-07-27)

Feature: hotkey thứ hai `Sources/Speech/HotkeyManager.swift` (⌃⌥T, `id: 2`, độc lập với ⌃⌥M) +
`Sources/Views/TextCapturePanel.swift` (mới) + `Sources/Views/CapturePanel.swift` (generalize để
host 2 nội dung khác nhau) + `AppState.swift` (`textCapture`/`openTextCapture`/`cancelTextCapture`/
`submitTextCapture` — tái dùng nguyên `router.parse` + `confirmSave()` của luồng voice, KHÔNG có
bước review confirm-card) + `VolarApp.swift` (`textCapturePanelController` thứ hai +
`observeTextCaptureState()` + guard mutual-exclusion trong `syncCapturePanel()`). CHƯA build/chạy
trên Mac lần nào — mọi bước dưới đây làm bằng tay trên máy Mac thật. Rủi ro cao nhất:
`GetEventParameter(..., typeEventHotKeyID, ...)` (shape suy đoán, `// UNVERIFIED` trong
`HotkeyManager.swift`) và `@FocusState` auto-focus trong `NSPanel` borderless/non-activating
(`// UNVERIFIED` trong `TextCapturePanel.swift`).

1. **⌃⌥T mở popup KHÔNG cướp focus của app khác:** mở một app bất kỳ (VD TextEdit), gõ dở vài chữ
   vào một document → bấm ⌃⌥T → xác nhận popup nhỏ "What needs doing?" hiện lên phía trên (upper
   third màn hình) VÀ ô text field đã tự có caret (không cần click) → xác nhận app TextEdit **vẫn
   còn đúng những gì vừa gõ dở**, không bị mất/không bị chèn ký tự lạ do hotkey.
2. **Gõ + Return tạo task:** với popup đang mở, gõ "mua sữa" → nhấn Return (hoặc bấm "Add task") →
   xác nhận: (a) popup hiện dòng xác nhận "Added "mua sữa"" trong chớp nhoáng rồi tự đóng (~900ms,
   giống hệt nhịp "Saved" của popover voice); (b) mở cửa sổ chính → task "mua sữa" đã xuất hiện
   thật trong danh sách (Today/Inbox tuỳ deadline) — tức đã đi qua đúng `confirmSave()`, không phải
   một đường lưu song song giả.
3. **Nhiều task trong 1 dòng:** bấm ⌃⌥T → gõ "mua sữa và gọi mẹ" (hoặc "buy milk and call mom") →
   Return → xác nhận dòng xác nhận đọc **"Added 2 tasks"** (số nhiều, không phải chỉ 1) → xác nhận
   cả 2 task đều xuất hiện trong danh sách.
4. **Esc đóng popup, không mất gì quan trọng:** bấm ⌃⌥T → gõ vài chữ → Esc → xác nhận popup đóng
   ngay, KHÔNG có task nào được tạo, và bấm lại ⌃⌥T lần nữa → ô field phải TRỐNG (không phải còn
   giữ chữ cũ từ lần Esc trước — `cancelTextCapture()` phải xoá `textCaptureInput`).
5. **Parse thất bại giữ nguyên chữ đã gõ:** khó ép được trường hợp này qua UI thật (parser hiện tại
   luôn trả về ít nhất 1 task cho input không rỗng — xem comment trong `AppState.submitTextCapture()`),
   nhưng NẾU quan sát được dòng lỗi "Didn't catch that" (hoặc lỗi `TaskStore` thật, VD dependency
   cycle) xuất hiện: xác nhận ô field **vẫn còn nguyên chữ đã gõ** (không bị xoá/không bị đóng popup)
   để sửa và bấm lại "Add task".
6. **⌃⌥T trong lúc đang ghi âm voice → huỷ ghi âm, mở popup gõ:** bấm ⌃⌥M bắt đầu ghi âm (hoặc để
   confirm-card voice đang chờ save) → trong lúc đó bấm ⌃⌥T → xác nhận: (a) waveform/popover voice
   **biến mất ngay** (ghi âm bị huỷ qua `cancelCapture()`, không phải chỉ ẩn UI trong khi mic vẫn
   chạy ngầm); (b) popup gõ chữ hiện ra thay thế, field trống, sẵn sàng gõ.
7. **⌃⌥M trong lúc popup gõ đang mở → đóng popup, bắt đầu ghi âm:** bấm ⌃⌥T mở popup, gõ dở vài chữ
   → bấm ⌃⌥M → xác nhận: (a) popup gõ chữ đóng ngay (chữ dở dang bị bỏ, đúng thiết kế
   `cancelTextCapture()`); (b) waveform/popover voice hiện ra và mic thật sự bắt đầu ghi (không phải
   chỉ đóng popup mà không làm gì tiếp).
8. **Popover voice KHÔNG được flash lên trong lúc lưu bằng chữ:** bấm ⌃⌥T → gõ 1 task → Return →
   quan sát THẬT KỸ khoảnh khắc lưu (nếu cần, thử vài lần liên tiếp với các task khác nhau) → xác
   nhận **popover voice (waveform/confirm-card kiểu voice) không hề xuất hiện dù chỉ 1 frame** trong
   suốt quá trình lưu — đây chính là guard `syncCapturePanel()` kiểm tra `textCapture != .closed`;
   nếu popover voice thoáng hiện lên, đây là bug cần sửa ngay (self-review point 4 của task này).
9. **Xung đột hotkey ⌃⌥T với app khác → log, không tắt ⌃⌥M:** dùng một app/tool nào đó chiếm sẵn
   combo ⌃⌥T (VD một global-hotkey app khác đăng ký ⌃⌥T trước) → khởi động lại Volar → xác nhận: (a)
   Console.app (hoặc log Xcode) có dòng `[Volar.HotkeyManager] RegisterEventHotKey(⌃⌥T) failed:
   status ...`; (b) ⌃⌥T không mở được popup gõ chữ (chấp nhận được — app kia đang giữ combo); (c)
   **⌃⌥M vẫn hoạt động bình thường** (mở/đóng ghi âm voice như chưa có gì xảy ra) — hai hotkey đăng
   ký độc lập, một cái fail không được kéo cái kia chết theo.
