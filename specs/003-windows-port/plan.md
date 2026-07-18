# Volar for Windows — Implementation Plan

**Branch:** `window` (worktree `C:\projects\voci-windows`, forked from `macos` @ 89e790a)
**Ngày:** 2026-07-18
**Mục tiêu:** Bản Windows đạt feature parity với bản macOS hiện tại (feature 002).

---

## 1. Quyết định kiến trúc đã chốt

| Hạng mục | macOS | Windows | Ghi chú |
|---|---|---|---|
| Ngôn ngữ | Swift 6 | **C# / .NET 10** | Một ngôn ngữ, không interop. .NET 9 EOL ~5/2026 (STS); đổi sang .NET 10 (LTS, hỗ trợ tới 11/2028) |
| UI | SwiftUI | **WinUI 3** (XAML, Windows App SDK) | Viết lại 100% |
| Shell | `MenuBarExtra` (LSUIElement) | **Tray icon + popup window** (H.NotifyIcon.WinUI) | Xem §5 khác biệt hành vi |
| Persistence | SwiftData | **EF Core 9 + SQLite** | Schema map 1:1 từ `@Model` |
| STT tier 1 | `SFSpeechRecognizer` / WhisperKit | **Whisper.net** (whisper.cpp, GGML) | On-device, free unlimited |
| STT tier 2 | Groq | **Groq** (port thẳng `GroqTranscriptionClient`) | HTTP thuần |
| Parse tier 1 | `NLParser` (rule-based) | **`NLParser` port sang C#** | Chạy offline |
| Parse tier 2 | `FoundationModels` (Apple LLM) | **Tuỳ chọn: Phi-4-mini qua ONNX Runtime GenAI** | Mặc định TẮT; bật trong Settings → tải model on-demand |
| Parse tier 3 | Supabase `/parse` | **Supabase `/parse`** (giữ nguyên hợp đồng) | Không đổi backend |
| Notification | `UserNotifications` | **`AppNotificationBuilder`** (Windows App SDK toast) | Xem §5 |
| Global hotkey | Carbon `RegisterEventHotKey` | **Win32 `RegisterHotKey`** + xem §5 vấn đề key-up | Rủi ro cao nhất |
| Audio | AVFoundation | **NAudio / WASAPI** | |
| Monetization | StoreKit (chưa land) | **Hoãn** — parity với mac | Backlog |
| Attestation | DeviceCheck / App Attest | **Stub** — không port phase này | Backlog |

---

## 2. Cấu trúc solution

```
Volar.Windows.sln
├─ src/
│  ├─ Volar.Core/           net10.0, ZERO dependency — port 1:1 VolarCore (755 dòng)
│  ├─ Volar.Domain/         net10.0, pure — TaskItem, Recurrence, NLParser, IntentParsing
│  ├─ Volar.Data/           EF Core 9 + SQLite — entities, DbContext, TaskRepository
│  ├─ Volar.Speech/         ISpeechEngine + WhisperNet/Groq, AudioCapture, HotkeyManager
│  ├─ Volar.Parsing/        IntentRouter (3 tier), CloudParser, OnnxSlmParser (optional)
│  ├─ Volar.Reminders/      ReminderScheduler (pure) + IToastChannel (adapter)
│  ├─ Volar.Orchestrator/   AppLinkHandler (volar://), DelegationTracker, EditorConnector
│  └─ Volar.App/            WinUI 3 — App.xaml, tray, Views/, ViewModels/, DI
└─ tests/
   ├─ Volar.Core.Tests/       xUnit — port toàn bộ VolarCore/Tests (1.251 dòng)
   ├─ Volar.Domain.Tests/     NLParser + Recurrence
   └─ Volar.Reminders.Tests/  port ReminderSchedulerTests
```

**Quy tắc phụ thuộc (bắt buộc):** `Core` ← `Domain` ← `Parsing`/`Reminders`/`Orchestrator` ← `App`.
`Core` và `Domain` **không được** tham chiếu WinUI, EF Core, hay bất kỳ thứ gì I/O.
Đây là điều kiện để test được và để sau này tái dùng cho nền tảng khác.

---

## 3. Ánh xạ domain model (Volar.Core)

Đây là lõi, phải port **đúng từng chi tiết** — mọi thứ khác phụ thuộc vào nó.

| Swift | C# | Lưu ý |
|---|---|---|
| `enum TaskStatus` | `enum TaskState { Todo, InProgress, Done, Archived }` | Đổi tên `TaskStatus` → `TaskState`: trùng `System.Threading.Tasks.TaskStatus` (BCL, implicit usings) → gây `CS0104` ambiguous reference ở mọi project phụ thuộc sau này. Property `TaskSnapshot.Status` giữ nguyên tên, chỉ đổi KIỂU. |
| `struct Task: Sendable, Equatable` | `record TaskSnapshot` | Đổi tên tránh đụng `System.Threading.Tasks.Task` — **quan trọng** |
| `enum Condition` (associated values) | `abstract record Condition` + 3 subrecord: `TaskDone(Guid)`, `AfterDate(DateTimeOffset)`, `External(string, bool)` | Discriminated union pattern; dùng `switch` expression |
| `Date` | `DateTimeOffset` (UTC) | **Không dùng `DateTime`** — tránh bug timezone |
| `Calendar` (injected) | `TimeZoneInfo` injected | Tier 2 ordering cần "cùng ngày lịch" |
| `UUID` | `Guid` | Tiebreak tier 5 so sánh `id.uuidString` → dùng `Guid.ToString()` **lowercase-invariant** để khớp thứ tự Swift |
| `nextTask(from:now:calendar:)` | `NextTaskSelector.NextTask(IReadOnlyList<TaskSnapshot>, DateTimeOffset, TimeZoneInfo)` | |
| `orderedBefore` | `IComparer<TaskSnapshot>` | 5 tier, first-difference-wins |
| `conflicts(...)` | `ConflictChecker.Conflicts(...)` | 340 dòng, phần lớn nhất của Core |
| `validateCondition` / `wouldCreateCycle` | `DependencyGraph` static class | |
| `eligibilityDiff` / `nextResurfaceDate` | `Snapshots` static class | |

**Bẫy đã biết:**
- Swift `Int.max` cho priority `nil` → C# dùng `int.MaxValue`, giữ nguyên semantics "unset sort sau cùng".
- Swift `min(by:)` với strict total order → C# `.MinBy()` hoặc sort có comparer; phải giữ tính total order (tier 5) nếu không kết quả sẽ không deterministic.
- Snapshot có id trùng: Swift để "last occurrence wins". C# dùng dictionary indexer (không `.Add()`) để giữ hành vi này.

---

## 4. Phân rã công việc theo wave (file-disjoint)

### Wave 1 — Nền móng (4 agent song song, không đụng file nhau)

| Agent | Phạm vi | Output | Nguồn đọc |
|---|---|---|---|
| **W1-A** | Solution skeleton + `Volar.Core` + `Volar.Core.Tests` | ~1.100 dòng C# | `VolarCore/**` |
| **W1-B** | `Volar.Domain`: TaskItem, Recurrence, NLParser + tests | ~1.100 dòng | `Model/{TaskItem,Recurrence,NLParser}.swift` |
| **W1-C** | `Volar.Data`: EF Core entities + DbContext + TaskRepository + migration | ~900 dòng | `Model/{TaskStore,VolarTask,ReminderRecord,CompletionLog,ParseCorrection}.swift` |
| **W1-D** | `Volar.Speech`: `ISpeechEngine`, WhisperNet, Groq, AudioCapture, HotkeyManager | ~1.000 dòng | `Speech/**`, `Audio/**` |

> W1-A phải xong **trước** khi W1-B/C/D commit vì chúng tham chiếu `Volar.Core`. Cách xử lý: W1-A tạo solution + project stub cho cả 4 project ngay bước đầu, rồi các agent khác điền vào project của mình.

### Wave 2 — Tầng dịch vụ (3 agent song song)

| Agent | Phạm vi | Nguồn đọc |
|---|---|---|
| **W2-A** | `Volar.Parsing`: IntentRouter 3 tier, CloudParser, OnnxSlmParser (optional, tải model) | `Parsing/**`, `supabase/functions/parse/**` |
| **W2-B** | `Volar.Reminders`: scheduler logic thuần + `IToastChannel` + Windows toast adapter | `Reminders/**` |
| **W2-C** | `Volar.Orchestrator`: AppLinkHandler (`volar://`), DelegationTracker, EditorConnector | `Orchestrator/**`, `specs/002-*/contracts/app-links.md` |

### Wave 3 — App shell + ViewModel (tuần tự, đây là chỗ dễ đụng nhau nhất)

| Agent | Phạm vi | Ghi chú |
|---|---|---|
| **W3-A** | WinUI 3 app shell: App.xaml, tray icon, popup window, DI container, MainWindow | Chặn Wave 4 |
| **W3-B** | Tách `AppState.swift` (2.165 dòng, 87 method, 28 nhóm MARK) thành **~8 service/ViewModel** | Xem §6 |

### Wave 4 — Views (4 agent song song, mỗi agent một màn hình)

| Agent | View | Dòng Swift gốc |
|---|---|---|
| **W4-A** | PopoverView (màn hình chính) | 1.187 |
| **W4-B** | TodayView + TaskRow + Sidebar + Components | 1.539 |
| **W4-C** | SettingsView + OnboardingView | 1.224 |
| **W4-D** | FocusOverlay, SweepView, TriageView, MorningFrogView, TaskBreakdownView, TaskDetailView, NotificationView, Waveform | 1.517 |

### Wave 5 — Design system + tích hợp
- Theme tokens (`Design/Theme.swift`, 319 dòng) → XAML ResourceDictionary
- `Glass.swift` (NSVisualEffectView) → Mica/Acrylic backdrop
- `AmbientBackground.swift` (417 dòng) → Composition API / Win2D
- Wiring end-to-end, smoke test

---

## 5. Khác biệt hành vi KHÔNG tránh được (phải chấp nhận)

1. **Push-to-talk key-up.** Win32 `RegisterHotKey` chỉ báo key-**down**, không báo key-up.
   → Phải dùng low-level keyboard hook `WH_KEYBOARD_LL` để bắt key-up. Đánh đổi: một số
   antivirus gắn cờ hook bàn phím toàn cục. Phương án B: đổi push-to-talk thành **toggle**
   (nhấn để bắt đầu, nhấn lại để dừng) — an toàn hơn nhưng đổi UX cốt lõi.
   **→ Cần anh Khôi quyết khi tới Wave 1-D.**
2. **Tray icon không hiển thị text động.** macOS `MenuBarExtra` hiện được tên task hiện tại
   trên thanh menu; Windows tray chỉ có icon 16x16 + tooltip. → Task hiện tại chỉ thấy khi
   hover (tooltip) hoặc mở popup.
3. **Toast notification** trên Windows vào Action Center và có thể bị Focus Assist chặn;
   số nút bấm giới hạn 5. Hành vi snooze khác macOS.
4. **Không có App Sandbox** tương đương → security-scoped bookmark không có; thay bằng
   lưu đường dẫn thường + kiểm tra quyền.

---

## 6. Kế hoạch tách `AppState.swift` (2.165 dòng → ~8 service)

| Service C# | Nhóm MARK gốc |
|---|---|
| `TaskListViewModel` | Derived task groupings, Task CRUD |
| `CaptureViewModel` | Capture/popover flow, confirm-card chips |
| `VoiceDoneService` | T036 voice-done confirm |
| `DelegationService` | T042 voice delegation, Phase 6 orchestrator |
| `FocusSessionService` | Focus session |
| `AmbienceService` | Ambient background + ambient sound |
| `EligibilityService` | Auto-unblock, afterDate resurface, overdue rescan |
| `RitualService` | Frog of the day, weekly triage, evening sweep |
| `SettingsService` | VoiceDeliveryMode, ReminderPolicy, UserDefaults → `ApplicationData.LocalSettings` |

---

## 7. Rủi ro

| Rủi ro | Mức | Giảm thiểu |
|---|---|---|
| Session limit khi chạy nhiều agent song song | **Cao** | Chạy tối đa 3-4 agent/wave, nghỉ giữa wave |
| Không có Mac để đối chiếu hành vi thực tế | Cao | Bản mac cũng **chưa build xanh** — port từ code, không từ app đang chạy |
| Hotkey key-up (§5.1) | Cao | Cần quyết định sớm |
| NLParser tiếng Việt port sai | TB | Port kèm test case, đối chiếu từng rule |
| Whisper.net chất lượng khác WhisperKit | TB | Cho phép chọn model size trong Settings |
| ONNX SLM parser tăng độ phức tạp installer | TB | Mặc định tắt, tải on-demand |

---

## 8. Trạng thái

- [x] Tạo worktree + branch `window`
- [x] Chốt tech stack
- [x] Viết plan này
- [ ] Wave 1 (4 agent)
- [ ] Wave 2 (3 agent)
- [ ] Wave 3 (2 agent, tuần tự)
- [ ] Wave 4 (4 agent)
- [ ] Wave 5
- [ ] Build xanh trên máy Windows của anh Khôi
