# Feature 004 — Volar for iOS

**Branch:** `ios` (worktree `C:\projects\voci-ios`, cắt từ `b2fc3d9` trên `macos`)
**Ngày:** 2026-07-27
**Tác giả plan:** Opus (bộ não). Execute: Sonnet 5 theo đúng contract dưới đây.
**Trạng thái build:** mọi dòng Swift ở đây viết trên Windows, **UNVERIFIED** — anh Khôi build/test
trên Mac + iPhone. Xem memory `build-env-windows-mac-split`.

---

## 0. Quyết định đã chốt (anh Khôi, 2026-07-27)

| # | Câu hỏi | Chốt |
|---|---|---|
| 1 | Base branch | Cắt từ `b2fc3d9`. Work chưa commit trên `macos` (CalendarSync, Tour, TaskSections) **không** có trong nhánh này. |
| 2 | Scope v1 | **Core-first**: capture giọng nói → parse → Today/NOW → Focus → reminders → settings. Bỏ ClaudeCodeConnector/delegation, global hotkey, menu bar, floating panel. |
| 3 | Sync Mac ↔ iPhone | **Để sau** — sẽ là tính năng của **paid tier**. v1 iOS đứng một mình. Nhưng schema + store phải để sẵn seam (§7.3) để bật sync sau mà không phải migrate destructive. |
| 4 | Tổ chức code | **Tách lớp shared**, chỉ làm trên nhánh `ios`; merge về `macos` **sau khi** bản Mac build xanh. |

### 0.1 Quyết định kỹ thuật Opus tự chốt (kèm lý do)

**A. Shared = THƯ MỤC NGUỒN CHUNG, không phải SPM package.**
Cách hiển nhiên là gói phần dùng chung vào `VolarShared` (SwiftPM). Em **không** chọn cách đó:
tạo ranh giới module đồng nghĩa mọi type/property/method mà view gọi qua phải đổi thành `public`
— hàng trăm chỗ trên **19k dòng code chưa từng compile lần nào**. Không ai (kể cả anh Khôi trên
Mac) đọc được lỗi access-control đó trước khi nó nổ hàng loạt.
→ Chốt: `Shared/` là thư mục nguồn, **cả hai** app target cùng compile nó (XcodeGen `sources:`).
Không có module boundary → giữ nguyên `internal`, zero churn. `VolarCore` vẫn là SPM package như
cũ (nó vốn đã `public` sẵn).

**B. Hai file `project.yml`, không gộp một Xcode project.**
`Volar/project.yml` (macOS) giữ nguyên cấu trúc, chỉ thêm 1 dòng trỏ `../Shared`. `VolarIOS/project.yml`
là file mới. Lý do: bản Mac đang chờ verify theo `docs/mac-verify-checklist.md` — đụng vào scaffold
của nó nhiều hơn mức tối thiểu là tự chuốc rủi ro cho một thứ chưa từng chạy. Lệnh cũ
`cd Volar && xcodegen generate` vẫn đúng.

**C. Deployment target iOS 17.0.**
`@Observable` + SwiftData yêu cầu iOS 17. Cùng thế hệ với macOS 14 của bản Mac. `FoundationModels`
(iOS 26, Apple Intelligence) bọc trong `#available(iOS 26, *)` y như bản Mac đang làm.

**D. Free-tier speech trên iOS = `SFSpeechRecognizer` on-device, WhisperKit là opt-in.**
Trên Mac, WhisperKit là engine free vì máy có RAM/nhiệt thoải mái. Trên iPhone thì model Whisper
tốn RAM, nóng máy, và tải model lần đầu ~100-500MB. Apple's on-device dictation đã miễn phí, có
sẵn, không tải gì. → mặc định iOS chọn `.appleOnDevice`; WhisperKit vẫn giữ trong `SpeechEngine`
picker nhưng off mặc định, và **chỉ tải model qua Wi-Fi + do người dùng bấm** (§8 rủi ro R3).

---

## 1. Bản đồ code hiện tại (đã khảo sát)

- `Volar/Sources` = 63 file, ~19k dòng. Coupling AppKit chỉ ở **8 file**.
- `VolarCore/` = SPM thuần logic (`nextTask`, `ConflictCheck`, `DependencyGraph`) — `platforms: [.macOS(.v13)]`.
- Design source of truth: `design/volar-mobile.jsx` (iOS companion, 498 dòng — trước giờ "parked",
  giờ là spec chính cho port này), `design/ios-frame.jsx`, tokens Volar Twilight trong
  `Volar/Sources/Design/Theme.swift`.

### 1.1 Phân loại từng file

**→ `Shared/` (dùng chung cả 2 platform, không sửa logic)**

```
Shared/Design/       Theme.swift  VolarIcon.swift  Glass.swift
Shared/Model/        TaskItem  VolarTask  TaskStore  NLParser  Recurrence
                     CompletionLog  ReminderRecord  ParseCorrection  SampleData
Shared/Parsing/      IntentParsing  FoundationModelParser  CloudParser
                     ConfigParseCredentialProvider  DeviceCheckProvider
Shared/Speech/       SpeechEngine  SpeechCapture  WhisperKitEngine  GroqEngine
                     GroqTranscriptionClient  VoicePlayback  VoiceDone
Shared/Account/      AccountModels  KeychainStore  AccountService*  Entitlements
Shared/Reminders/    ReminderScheduler*  NotificationActions  ReminderContextGate
                     VoiceReminderChannel
Shared/Views/        Components  TaskRow  Waveform  NotificationView
Shared/App/          AppState*
```
`*` = cần chèn `#if os(macOS)` / `#if os(iOS)`, chi tiết ở §3.

**→ Ở lại `Volar/Sources` (macOS-only, iOS không đụng tới)**

```
App/VolarApp.swift              MenuBarExtra + AppDelegate + NSWindow
Speech/HotkeyManager.swift      Carbon RegisterEventHotKey
Views/CapturePanel.swift        NSPanel + NSHostingView floating panel
Views/MenuBarLabel.swift        NSStatusItem label
Views/TodayView.swift           layout cửa sổ desktop (sidebar + 2 cột)
Views/Sidebar.swift             cột trái desktop
Views/PopoverView.swift         popover desktop (iOS port lại thành bottom sheet)
Views/SettingsView.swift        NSOpenPanel / NSWorkspace / Settings scene
Views/FocusOverlay.swift        overlay desktop (iOS port lại thành fullScreenCover)
Views/AmbientBackground.swift   Canvas particles OK, nhưng NSImage + security-scoped bookmark thì không
Orchestrator/*                  ClaudeCodeConnector, DelegationTracker, AppLinkHandler — desktop-only
Views/MorningFrogView, TriageView, SweepView, TaskBreakdownView, TaskDetailView, OnboardingView
                                → iOS port lại ở Phase 2/4
```

**→ Bỏ hẳn khỏi iOS v1**: toàn bộ `Orchestrator/` (delegation cho Claude Code là khái niệm
desktop), `HotkeyManager`, `CapturePanel`, `MenuBarLabel`.

---

## 2. Hình dáng app trên iOS

macOS Volar đứng trên 3 chân: **menu bar** (glance NOW), **global hotkey ⌃⌥M** (capture từ bất kỳ
đâu), **cửa sổ** (làm việc). iOS không có chân nào trong hai chân đầu. Thay thế:

| Chân macOS | Thay bằng trên iOS | Phase |
|---|---|---|
| Menu bar label (glance NOW) | **WidgetKit** widget Home/Lock Screen hiện đúng 1 task NOW | 5 |
| Global hotkey ⌃⌥M | **App Intents + Siri** ("Add a task to Volar") + **Control Center control** (iOS 18) + Action Button | 2 / 5 |
| Cửa sổ | `TabView` + mic FAB + bottom sheet | 1 |

**Constitution V (glance-and-dismiss) trên iOS = widget.** Nó không phải "nice to have" — nó là
cái thay thế duy nhất cho menu bar. Nhưng nó cần app group + widget extension target nên đẩy về
Phase 5, tách bạch, không chặn core.

### 2.1 Navigation (theo `design/volar-mobile.jsx`)

Prototype vẽ 4 tab: Today / Upcoming / Projects / Settings. **Bỏ "Projects"** — data model hiện tại
không có khái niệm project (`TaskItem` không có field project; prototype đang xài sample data).
Chốt **3 tab**:

```
TabView
├─ Today      (mặc định)  — hero NOW card + "Later today" + "Completed"
├─ Upcoming              — task ngày mai trở đi, nhóm theo ngày
└─ Settings              — Form kiểu iOS
+ Mic FAB nổi trên tab bar (chỉ hiện ở tab Today & Upcoming)
```

iOS 17 floor → dùng `TabView { ... .tabItem { Label(...) } }` (API `Tab {}` là iOS 18+).

### 2.2 Luồng capture (thay cho PopoverView)

Bottom sheet, `.presentationDetents([.medium, .large])`, `.presentationDragIndicator(.visible)`,
`.presentationBackground(.ultraThinMaterial)`. **5 state y hệt bản Mac**, đọc từ
`AppState.captureState` — không tự phát minh state machine mới:

```
recording  → waveform live + transcript chạy chữ + caret nhấp nháy + chấm đỏ "Listening…"
parsing    → waveform tĩnh + "Parsing with AI…"
parsed     → parsed card + chip (time / priority / duration / project) + [Cancel] [Save task]
saving     → spinner trong nút
done       → vòng tròn check mint, tự đóng sau ~800ms
```

Khác bản Mac: **hold-to-talk đổi thành tap-to-toggle**. Trên iPhone giữ ngón tay suốt câu nói là
khó chịu và chặn màn hình. Mic FAB tap → bắt đầu; tap lại (hoặc tap nút stop trong sheet) → dừng.
`AppState.toggleCapture()` đã có sẵn đúng semantics này.

### 2.3 Focus mode

`.fullScreenCover` thay vì overlay window. Nội dung port 1:1 từ `FocusOverlay.swift`: 1 task, timer
đếm ngược, ambient background, nút pause/skip/done. Thêm iOS-only: **giữ màn hình sáng** trong lúc
focus (`UIApplication.shared.isIdleTimerDisabled = true`, nhớ tắt khi thoát).

---

## 3. Các điểm phải chèn `#if` (danh sách đầy đủ, đừng phát sinh thêm)

| File | Vấn đề | Xử lý |
|---|---|---|
| `Shared/App/AppState.swift` | `hotkey`, `claudeConnector`, `delegation`, `appLinkHandler`, `dueDelegationRechecks`, `pendingDisambiguationTaskIDs`, `startDelegationTimer`, `activateServices` phần hotkey | bọc `#if os(macOS)`. Ước tính 10–15 site. **Không** tách file, **không** đổi tên API — mọi view macOS đang gọi. |
| `Shared/App/AppState.swift` | `customImageURL: URL?` (security-scoped bookmark macOS) | giữ nguyên property; iOS ghi vào đó URL từ `PhotosPicker` copy vào app container. |
| `Shared/Account/AccountService.swift` | `presentationAnchor` trả `NSApp.keyWindow` | `#if os(iOS)` trả về `UIApplication.shared.connectedScenes` → first `UIWindowScene` → `.keyWindow`; fallback `ASPresentationAnchor()`. |
| `Shared/Reminders/ReminderScheduler.swift` | observer `NSWorkspace.didWakeNotification` | `#if os(iOS)` dùng `UIApplication.didBecomeActiveNotification`. **Xem R2 §8 — quan trọng hơn là chuyện timer.** |
| `Shared/Speech/SpeechCapture.swift` | `AVAudioSession` không tồn tại trên macOS, **bắt buộc** trên iOS | `#if os(iOS)`: `setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])` + `setActive(true)` trước khi start, `setActive(false, options: .notifyOthersOnDeactivation)` sau khi stop. **Thiếu bước này micro trên iPhone câm hoàn toàn.** |
| `Shared/Speech/VoicePlayback.swift` | `AVSpeechSynthesizer` cần audio session active | dùng chung session ở trên; chỉ `setCategory(.playback)` khi chỉ đọc. |
| `Shared/Model/TaskStore.swift` | đường dẫn container SwiftData | đã dùng default container → không cần sửa; **nhưng** xem §7.3 seam sync. |
| `Shared/Design/Theme.swift` | không có gì macOS-only | **không sửa 1 chữ nào.** Token là hợp đồng chung. |

---

## 4. Design: đưa Volar Twilight lên iOS

Nguyên tắc bất di bất dịch, giữ nguyên từ bản Mac (`Theme.swift` header):

> **Bạc hà (mint `#8FEDCB`) = NOW duy nhất. Xanh băng (`#86B9FF`) = thông tin.**
> Nếu trên một màn hình có hai thứ màu mint, một trong hai là sai.
> Không bao giờ dùng đỏ cho overdue/badge (anti-shame).

Dark-only: đặt `.preferredColorScheme(.dark)` ở root scene. Không làm light mode.

### 4.1 Thang chữ & khoảng cách — macOS → iOS

Bản Mac dùng cỡ chữ desktop (11–13pt). Bê nguyên sang iPhone là chữ li ti không đọc được. Bảng quy
đổi **bắt buộc** dùng — đặt trong `VolarIOS/Sources/Design/IOSMetrics.swift`:

| Vai trò | macOS | iOS | Ghi chú |
|---|---|---|---|
| Greeting / màn hình title | 22 | **34** semibold, tracking −0.025em | `volar-mobile.jsx` "Good morning, Alex." |
| Ngày (eyebrow, uppercase) | 10.5 | **13** medium, tracking +0.05em, màu accent | |
| NOW card title | 15 | **17** semibold | |
| Task row title | 13 | **15** medium | |
| Meta / badge | 11 | **12.5** | |
| Section header (uppercase) | 10.5 | **11** medium, tracking +0.08em, `textMut` | |
| Footnote / caption | 11 | **13** | iOS tối thiểu 13 cho chữ đọc được |

- **Touch target ≥ 44×44pt** cho mọi thứ bấm được. Checkbox trong `TaskRow` hiện 20pt → giữ hình
  tròn 22pt nhưng bọc `.frame(width: 44, height: 44)` + `.contentShape(Rectangle())`.
- Bo góc: card 14, NOW card 18, sheet top 28 (khớp `volar-mobile.jsx`).
- Padding ngang màn hình: **18pt** cho card, **22pt** cho header/section label.
- `Density` preset: iOS mặc định `.comfy` nhưng `rowPadY` cộng thêm +4 (iOS cần thở hơn). Thêm
  `Density.iosRowPadY` trong `IOSMetrics.swift`, **không sửa `Theme.swift`**.

### 4.2 Chất liệu

- Tab bar & sheet: `.ultraThinMaterial` + overlay `VolarColor.bg.opacity(glass.bgOpacity)` — đúng
  công thức `GlassBackground` sẵn có, chỉ đổi chỗ dùng.
- Hairline: luôn `VolarColor.border` (xanh lạnh), **không bao giờ** `Color.white.opacity(...)` —
  đây đúng là lỗi mà commit `b2fc3d9` vừa quét sạch trên bản Mac, đừng tái phạm trên iOS.
- Mic FAB: nền `accent.solid` (ice blue, KHÔNG phải mint), 72pt, halo radial `accent.glow`,
  shadow `0 16 40 accent.glow`, scale 0.94 khi nhấn. Mint chỉ dành cho NOW card.

### 4.3 Logo & app icon

- Nguồn: `design/logo/app-icon.svg` + `design/logo/render-appicon.mjs`, mark mint
  (`assets/brand/volar-mark-mint-*.png`).
- **Icon iOS phải là bản riêng, không dùng lại bộ macOS.** Icon macOS đã bake sẵn squircle + padding
  ~10% quanh mark; iOS thì hệ thống tự mask, ảnh phải **full-bleed vuông**. Dùng lại bộ mac sẽ ra
  icon nhỏ tí nằm giữa ô trắng.
- Sinh `VolarIOS/Resources/Assets.xcassets/AppIcon.appiconset` — Xcode 14+ chỉ cần **1024×1024 duy
  nhất** (`"platform": "ios", "size": "1024x1024", "idiom": "universal"`). Nền = `VolarColor.bg`
  `#07090E`, mark mint ở giữa, chiếm ~62% cạnh.
- Task này cần chạy `render-appicon.mjs` (Node) — **anh Khôi chạy trên máy**, agent chỉ sửa script
  + viết `Contents.json`. Đánh dấu `// UNVERIFIED — cần render trên máy có Node`.

---

## 5. Cấu trúc thư mục đích

```
C:\projects\voci-ios\
├── VolarCore/                 SPM — thêm .iOS(.v17) vào platforms
├── Shared/                    ★ MỚI — nguồn dùng chung, KHÔNG phải package
│   ├── App/ Design/ Model/ Parsing/ Speech/ Account/ Reminders/ Views/
├── Volar/                     app macOS (giữ nguyên) — project.yml thêm `- path: ../Shared`
│   ├── project.yml  Sources/  Resources/  Tests/
├── VolarIOS/                  ★ MỚI — app iOS
│   ├── project.yml
│   ├── Sources/
│   │   ├── App/       VolarIOSApp.swift  RootTabView.swift
│   │   ├── Design/    IOSMetrics.swift
│   │   ├── Views/     TodayIOSView  UpcomingIOSView  SettingsIOSView
│   │   │              CaptureSheet  FocusIOSView  TaskDetailSheet
│   │   │              MobileTaskCard  MicFAB  VolarTabBar
│   │   └── Intents/   VolarAppIntents.swift        (Phase 2)
│   ├── Resources/     Info.plist  VolarIOS.entitlements  Assets.xcassets  PrivacyInfo.xcprivacy
│   └── Tests/
├── design/  docs/  specs/  supabase/  assets/
```

---

## 6. Phân pha & giao việc cho Sonnet (file-disjoint)

Quy trình theo yêu cầu của anh Khôi: Sonnet chạy **song song, file-disjoint**, mỗi agent tự
**self-review 6 mục** (compile-risk / API đoán mò / concurrency / token & design fidelity / dead
code / cái mình cố tình bỏ), Opus review diff cuối cùng.

### Phase 0 — Dựng Shared (COPY, KHÔNG MOVE)

> **★ ĐỔI CÁCH LÀM 2026-07-27 (anh Khôi chốt).** Kế hoạch ban đầu là `git mv`. **Huỷ.** Lúc này có
> **2 agent khác đang làm việc trên nhánh `ios`** → `git mv` sẽ gây race condition sửa trùng file.
>
> **Luật mới, áp dụng cho toàn bộ feature này cho tới khi anh Khôi nói khác:**
> 1. **COPY** file sang `Shared/`, **KHÔNG xoá / KHÔNG sửa** bản gốc trong `Volar/Sources/`.
> 2. **KHÔNG** thêm `- path: ../Shared` vào `Volar/project.yml`. Bản macOS tiếp tục compile
>    `Volar/Sources` y như cũ. (Thêm vào = duplicate symbol, build macOS đỏ ngay.)
> 3. Bản **macOS và Windows cứ chạy structure cũ**. Chỉ **iOS** dùng `Shared/`.
> 4. Khi `Shared/` chạy ổn định và anh Khôi xác nhận, anh sẽ **instruct riêng** việc xoá bản cũ.
>    **Chưa làm bây giờ.**
>
> **Đánh đổi đã chấp nhận:** trong giai đoạn này code bị **nhân đôi**. Sửa bug ở
> `Volar/Sources/Model/TaskItem.swift` sẽ **KHÔNG** tự vào `Shared/Model/TaskItem.swift` và ngược
> lại. Mỗi lần sửa file nằm trong cả hai nơi phải hỏi: sửa cả hai hay chỉ một? Ghi backlog.

**Bước 0.1 — copy (ĐÃ XONG 2026-07-27, Opus làm bằng shell).** 40 file trong `Shared/`:
`App/ Design/ Model/ Parsing/ Speech/ Account/ Reminders/ Audio/ Views/ Orchestrator/`.
19 file desktop ở lại `Volar/Sources`: `VolarApp, HotkeyManager, CapturePanel, MenuBarLabel,
ClaudeCodeConnector, TodayView, Sidebar, PopoverView, SettingsView, FocusOverlay,
AmbientBackground, MorningFrogView, TriageView, SweepView, TaskBreakdownView, TaskDetailView,
OnboardingView`.

**Sửa so với §1.1 — `DelegationTracker.swift` + `AppLinkHandler.swift` CÓ vào `Shared/`.** Khảo sát
cho thấy hai file này chỉ `import Foundation` + `VolarCore`, thuần logic, biên dịch được trên iOS.
Chỉ `ClaudeCodeConnector` là AppKit-only, và nó chỉ bị AppState gọi **đúng 1 dòng**. Nhờ vậy số
điểm `#if` trong `AppState.swift` rút từ ~30 xuống **5**. Giữ `AppLinkHandler` ở Shared còn có lợi
thật: seam `volar://capture` chính là thứ App Intents/Siri/widget iOS sẽ dùng ở Phase 2/5.

**Bước 0.2 — chèn `#if` (giao Sonnet).** Danh sách chính xác, đã xác minh bằng grep. **Không được
phát sinh site nào ngoài danh sách này:**

| File | Dòng | Sửa |
|---|---|---|
| `Shared/App/AppState.swift` | 2 | `import AppKit` → bọc `#if canImport(AppKit)` |
| | 296 | `let hotkey = HotkeyManager()` → `#if os(macOS)` |
| | 354 | `let claudeConnector = ClaudeCodeConnector()` → `#if os(macOS)` |
| | ~2447 | `hotkey.start(appState: self)` trong `activateServices()` → `#if os(macOS)` |
| | 1112–1120 | `openDictationSettings()` dùng `NSWorkspace.shared.open` → nhánh iOS mở `UIApplication.openSettingsURLString` |
| `Shared/Account/AccountService.swift` | 15 | `import AppKit` → `#if os(macOS)` / `import UIKit` cho iOS |
| | 340 | `presentationAnchor` → nhánh iOS lấy keyWindow từ `UIWindowScene` |
| `Shared/Speech/SpeechCapture.swift` | — | **AVAudioSession (R1, quan trọng nhất phase này)** |
| `Shared/Speech/VoicePlayback.swift` | — | audio session cho playback |
| `Shared/Reminders/ReminderScheduler.swift` | — | wake observer + **điều tra R2 (Timer vs UNNotification)** |
| `VolarCore/Package.swift` | 7 | thêm `.iOS(.v17)` |

**Đã kiểm, KHÔNG cần sửa:** `KeychainStore.swift` — dùng `kSecAttrAccessibleAfterFirstUnlock`,
không có `kSecAttrAccessGroup` → hợp lệ trên iOS nguyên trạng. Rủi ro R4 §8 đóng.

**Hoãn có chủ ý:** `Shared/Model/VolarTask.swift` có `@Attribute(.unique) var id: UUID` (+ vài
property non-optional không default) — CloudKit cấm cả hai. **Không sửa ở Phase 0.** Bỏ `.unique`
mà không có compiler/test có thể đẻ task trùng, tức đổi một bug nhìn thấy được lấy một lựa chọn
chưa chắc dùng (sync là paid tier, chưa làm). Cửa an toàn là "trước khi iOS có user thật" — ghi
backlog thành mốc chặn ship, không phải việc của phase này.

**Kiểm tra bắt buộc trước khi đóng phase:** grep lại `Shared/` cho `import AppKit`, `NSApp`,
`NSWindow`, `NSWorkspace`, `NSImage`, `NSEvent`, `MenuBarExtra`, `SettingsLink` — mọi hit phải nằm
trong `#if`. Còn sót một chỗ = build iOS đỏ ngay dòng đầu.

### Phase 1 — Core iOS (6 agent song song)

| Agent | File sở hữu (không ai khác được đụng) | Nội dung |
|---|---|---|
| **A1 Scaffold** | `VolarIOS/project.yml`, `VolarIOS/Resources/*` | project.yml (2 target: `VolarIOS` app + `VolarIOSTests`), Info.plist (§7.1), entitlements (§7.2), `PrivacyInfo.xcprivacy`, AppIcon Contents.json |
| **A2 App shell** | `VolarIOS/Sources/App/*`, `VolarIOS/Sources/Design/IOSMetrics.swift` | `@main VolarIOSApp` (WindowGroup + `.preferredColorScheme(.dark)` + `.onOpenURL` cho `volar://capture` + `scenePhase` observer thay `AppDelegate`), `RootTabView` (3 tab + FAB overlay), `IOSMetrics` (bảng §4.1) |
| **A3 Today** | `VolarIOS/Sources/Views/TodayIOSView.swift`, `MobileTaskCard.swift` | header (ngày + greeting + "N tasks today · M done"), hero NOW card có `.volarSpotlight()`, section "Later today"/"Completed", empty state "All clear.", swipe actions (done / delete) |
| **A4 Capture** | `VolarIOS/Sources/Views/CaptureSheet.swift`, `MicFAB.swift` | bottom sheet 5 state (§2.2), waveform, transcript chạy chữ, parsed card + chip, nút Cancel/Save. Đọc/ghi qua `AppState` sẵn có, **không** viết state machine mới |
| **A5 Focus** | `VolarIOS/Sources/Views/FocusIOSView.swift` | fullScreenCover port `FocusOverlay`, timer, ambient background (tái dùng phần `Canvas` của `AmbientBackground` — copy phần particle, **bỏ** phần `NSImage`/bookmark), idle timer off |
| **A6 Settings** | `VolarIOS/Sources/Views/SettingsIOSView.swift` | `Form`/`List` iOS: accent picker, density, glass, ambient, speech engine, parse engine, voice delivery, account (sign in / tier / restore purchase), consent toggles. `PhotosPicker` thay `NSOpenPanel`; `Link`/`openURL` thay `NSWorkspace.open` |

**Contract chung cho A2–A6** (Opus đóng băng, không agent nào được đổi):
- Chỉ đọc state qua `@Environment(AppState.self)`. Không thêm property mới vào `AppState`.
  Thiếu gì → ghi vào báo cáo cuối, Opus xử ở Phase 2.
- Màu/kiểu chữ/animation **chỉ** lấy từ `VolarColor` / `VolarAccent` / `VolarMotion` / `IOSMetrics`.
  Cấm hardcode hex, cấm `Color.white.opacity(...)` (dùng `VolarColor.veil(_:)`).
- Mint (`VolarColor.nowAccent*`) chỉ được xuất hiện trong hero NOW card và focus ring của nó.
- Mọi API framework đoán mò phải kèm `// UNVERIFIED: <lý do>` ngay dòng trên.

### Phase 2 — Hoàn thiện (sau khi Phase 1 review xong)

- `UpcomingIOSView`, `TaskDetailSheet`, `OnboardingIOSView`
- Reminders/notifications trên iOS: rà `ReminderScheduler` theo R2 §8
- `VolarAppIntents.swift`: `AppIntent` "Add task to Volar" + `AppShortcutsProvider` → Siri &
  Action Button "miễn phí"
- `VolarIOS/Tests/`

### Phase 3 — Kiểm & sửa (Opus)
Review toàn diff, đối chiếu token/design fidelity, viết `docs/ios-verify-checklist.md` kiểu
`mac-verify-checklist.md` để anh Khôi chạy trên máy.

### Phase 5 — Glance layer (tách hẳn, làm sau khi core xanh trên máy thật)
Widget extension (NOW task), Control Center control (iOS 18), Live Activity cho Focus session.
Cần app group + di chuyển SwiftData container vào group container → **phải làm trước khi có người
dùng thật**, nếu không sẽ là migration đau. Ghi backlog.

*(Phase 4 — MorningFrog / Triage / Sweep trên iOS: ngoài scope core-first, ghi backlog.)*

---

## 7. Cấu hình bắt buộc

### 7.1 `VolarIOS/Resources/Info.plist`

```
CFBundleIdentifier              tech.kioh.Volar.ios     ← KHÁC bundle ID bản Mac
CFBundleDisplayName             Volar
UILaunchScreen                  {}                       ← thiếu key này app bị letterbox
UISupportedInterfaceOrientations  Portrait (+ upside down thì thôi, bỏ landscape v1)
UIUserInterfaceStyle            Dark                     ← khoá dark, khớp Twilight
NSMicrophoneUsageDescription    "Volar listens while you speak so it can turn what you say into a task. Audio is transcribed on this iPhone and never leaves your device."
NSSpeechRecognitionUsageDescription  "…on-device speech recognition…"
CFBundleURLTypes                scheme `volar`           ← giống bản Mac, cho App Intents/widget mở capture
```
⚠️ Thiếu `NSMicrophoneUsageDescription` hoặc `NSSpeechRecognitionUsageDescription` → **app crash
ngay lúc xin quyền**, không phải chỉ là từ chối.

### 7.2 `VolarIOS.entitlements`

```
com.apple.developer.applesignin        [Default]
```
**Không** khai `com.apple.security.app-sandbox` (iOS luôn sandbox), **không** khai
`files.user-selected` / `bookmarks.app-scope` (không tồn tại trên iOS), **không** khai
network.client (iOS không cần). Khai thừa entitlement iOS không hiểu = lỗi ký/upload.
Keychain: `KeychainStore` **không được** đặt `kSecAttrAccessGroup` trừ khi thêm
`keychain-access-groups` — rà lại file này (R4 §8).

### 7.3 Seam cho sync paid tier (làm ngay, không tốn gì)

Anh Khôi chốt sync để sau. Nhưng SwiftData + CloudKit có ràng buộc schema **không thể sửa sau khi
đã có người dùng** mà không migrate: mọi property phải optional hoặc có default value, mọi
relationship phải optional, **không** được có `@Attribute(.unique)`.
→ Phase 0 rà `Shared/Model/VolarTask.swift`: nếu đang có `.unique` hoặc property non-optional
không default thì **sửa ngay bây giờ** (lúc chưa ai dùng), rồi ghi vào backlog rằng đây là chuẩn
bị cho CloudKit. Không bật CloudKit, không thêm entitlement iCloud ở v1.

---

## 8. Rủi ro & bẫy (đánh giá trước khi code — bắt buộc theo global rule)

| # | Rủi ro | Mức | Xử lý |
|---|---|---|---|
| **R1** | `AVAudioSession` chưa cấu hình → micro trên iPhone im lặng hoàn toàn, không báo lỗi | **CAO** | §3, bắt buộc trong `SpeechCapture` `#if os(iOS)`. Đây là lỗi #1 làm app voice chết trên iOS |
| ~~**R2**~~ | ~~iOS không chạy `Timer` khi app ở background~~ | **ĐÓNG 2026-07-27** | Đã kiểm: `ReminderScheduler` **không** dùng `Timer` để bắn reminder — tất cả là `UNNotificationRequest` + `UNTimeIntervalNotificationTrigger` (~dòng 545) hoặc `trigger: nil`. Hệ thống bắn ⇒ chạy được khi app đóng. Đã thêm observer `UIApplication.didBecomeActiveNotification` → `rebuildFromStorage()` làm đường phục hồi. **Còn lại (khác R2):** `systemRequestCap = 60` giới hạn 60 reminder đăng ký cùng lúc — xem backlog |
| **R3** | WhisperKit tải model vài trăm MB qua 4G → hoá đơn data của người dùng + App Review soi | Trung bình | Quyết định D §0.1: iOS mặc định Apple on-device. WhisperKit chỉ tải khi người dùng chủ động bấm, kèm cảnh báo dung lượng, chặn nếu không phải Wi-Fi |
| **R4** | `KeychainStore` có access group / `kSecAttrAccessible` không hợp lệ trên iOS → sign-in im lặng hỏng sau khi khoá máy | Trung bình | Rà ở Phase 0. Dùng `kSecAttrAccessibleAfterFirstUnlock` (token cần đọc được khi app chạy nền) |
| **R5** | Thiếu `PrivacyInfo.xcprivacy` → App Store **từ chối upload**. Volar dùng `UserDefaults` (required-reason API `CA92.1`) và file timestamp | Trung bình | A1 tạo file. **Bản Mac cũng thiếu** → ghi backlog cho nhánh `macos` |
| **R6** | Mic bị ngắt khi có cuộc gọi đến / app bị nền | Trung bình | Đăng ký `AVAudioSession.interruptionNotification`, coi interruption = stop capture + giữ transcript đã có. **Không** xin background audio mode (App Review sẽ hỏi tại sao) |
| **R7** | Merge `ios` → `macos` sau này sẽ đụng CalendarSync/Tour/TaskSections (đang chưa commit ở `macos`) với việc di chuyển file | Trung bình | Dùng `git mv` (Phase 0 bước 1) để git nhận diện rename. Merge sau khi bản Mac xanh, không sớm hơn |
| **R8** | App Attest (`DCAppAttestService`) chạy tốt hơn trên iOS so với macOS, nhưng server hiện **vẫn fail-closed 503** | Thấp | Đã biết, đã có fallback Heuristic. Không đụng ở feature này |
| **R9** | Bundle ID `tech.kioh.Volar` vs `.ios` — nếu sau này muốn universal purchase (mua 1 lần dùng cả 2) thì StoreKit product phải cùng App Store Connect app | Thấp | v1 để 2 app riêng. Ghi backlog: cân nhắc "Mac + iOS universal purchase" khi làm paid tier |

---

## 9. Định nghĩa "xong" cho v1

- [ ] `Shared/` tách xong, `grep` sạch AppKit ngoài `#if os(macOS)`
- [ ] `cd Volar && xcodegen generate` vẫn ra project macOS build được (không regress)
- [ ] `cd VolarIOS && xcodegen generate` ra project iOS
- [ ] App chạy trên iPhone simulator: mở ra thấy Today, tap mic → sheet → nói → parse → Save →
      task hiện trong list
- [ ] Focus mode chạy được, timer đếm, màn hình không tắt
- [ ] Settings đổi accent/density/ambient thấy đổi ngay
- [ ] Reminder đặt 2 phút sau, khoá máy, đúng giờ nổ notification (test R2)
- [ ] Icon iOS full-bleed, không có viền trắng
- [ ] `docs/ios-verify-checklist.md` viết xong cho anh Khôi chạy trên máy thật
