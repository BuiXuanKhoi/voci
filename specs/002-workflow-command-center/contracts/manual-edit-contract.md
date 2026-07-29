# Contract: Manual task editing (7 fields, at-create + after-create)

**Chốt bởi anh Khôi 2026-07-29.** User phải sửa được `title` / `description` / `priority` /
`startTime` / `deadline` / `duration` / `remind period` ở CẢ HAI thời điểm: trên confirm card lúc
tạo, và trên task đã tạo.

Quyết định UI anh Khôi đã chọn:
- **Sau khi tạo** → `TaskDetailView` trở thành sửa-tại-chỗ (không thêm sheet Edit riêng).
- **Lúc tạo** → bấm vào THÂN chip để đổi giá trị (giữ nguyên layout chip hiện tại, không thêm hàng form).

Ba agent làm song song, **file-disjoint**. File này là hợp đồng ĐÓNG BĂNG: mọi chữ ký dưới đây là
bắt buộc, không agent nào được đổi. Agent B/C code dựa vào chữ ký của A mà không cần chờ A xong.

| Agent | File sở hữu (chỉ được sửa đúng các file này) |
|---|---|
| A | `Volar/Sources/App/AppState.swift`, `Volar/Tests/ManualEditDraftTests.swift` (mới) |
| B | `Volar/Sources/Views/PopoverView.swift` |
| C | `Volar/Sources/Model/TaskStore.swift`, `Volar/Sources/Views/TaskDetailView.swift`, `Volar/Tests/TaskUpdateTests.swift` (mới) |

---

## §1 — API đóng băng (Agent A hiện thực, B/C tiêu thụ)

### 1.1 `ConfirmDraft` — 4 field overlay mới + 4 accessor

Đặt NGAY SAU `editedNotes`/`effectiveNotes` hiện có. Theo ĐÚNG khuôn `editedDeadline`/
`effectiveDeadline` đã có (đọc doc comment của chúng trước khi viết):

```swift
var editedPriority: Int?              // 1...3, nil = user chưa sửa
var editedStartTime: Date?
var editedEstimateMinutes: Int?       // > 0
var editedRemindPeriod: TimeInterval? // giây, > 0

var effectivePriority: ParsedValue<Int>?          // edited -> confidence 1.0, else task.priority
var effectiveStartTime: ParsedValue<Date>?        // edited -> confidence 1.0, else task.startTime
var effectiveEstimateMinutes: ParsedValue<Int>?   // edited -> confidence 1.0, else task.estimateMinutes
var effectiveReminderOverride: ParsedValue<ReminderPolicy>?
```

**`confidence: 1.0` là BẮT BUỘC, không phải làm đẹp.** `resolvedValue` (AppState.swift:3288) chặn
mọi giá trị `isUncertain` chưa được `accepted`. Nếu kế thừa confidence gốc, một chỉnh sửa tay của
user trên field mà parser đoán < 0.7 sẽ **không được lưu** trừ khi user bấm accept lần nữa — tức
edit thành lời nói dối. Đây đúng là lý do `effectiveDeadline` đã pin 1.0; đọc doc comment của nó.

`effectiveReminderOverride` khi có `editedRemindPeriod`: lấy base = `task.reminderOverride?.value
?? .defaultPolicy`, giữ nguyên `offsets`/`repeatEvery`/`fractionsRemaining` của base, chỉ thay
`remindPeriod`. (`ReminderRecord.derive` cho `remindPeriod` thắng `fractionsRemaining` — đúng ý
định: user nói rõ chu kỳ thì dùng chu kỳ đó.)

### 1.2 Setter trên `AppState`

Đặt cạnh `setDraftDeadline`. Sao y khuôn của nó — **bắt buộc mutate qua `confirmDrafts[index]`**,
KHÔNG được lấy bản copy local (`ConfirmDraft` là `struct`; sửa bản copy là mất trắng chỉnh sửa):

```swift
func setDraftPriority(_ raw: Int, forDraft draftID: ConfirmDraft.ID)
func setDraftStartTime(_ date: Date, forDraft draftID: ConfirmDraft.ID)
func setDraftEstimateMinutes(_ minutes: Int, forDraft draftID: ConfirmDraft.ID)
func setDraftRemindPeriod(_ seconds: TimeInterval, forDraft draftID: ConfirmDraft.ID)
```

Cả 4 **KHÔNG được đụng `dismissed`** — hiến pháp II: dismiss luôn thắng, giống hệt `setDraftDeadline`.

### 1.3 `TaskStore` — API update mới (Agent C)

```swift
/// Ghi ĐÚNG các field user sửa được bằng tay lên row có `item.id`. Trả `false` nếu không tìm thấy row.
@discardableResult
func updateEditableFields(from item: TaskItem) -> Bool
```

Chỉ ghi: `title`, `details`, `notes`, `priorityRaw`, `startTime`, `deadline`, `durationMinutes`,
`reminderOverride`. Rồi `save()`.

**TUYỆT ĐỐI KHÔNG dùng `VolarTask.apply(_:)`** dù doc comment của nó mời gọi. `apply` ghi đè cả
`conditions`/`parentId`/`createdAt`/`status`/`completedAt` — những thứ mang bất biến đã được
validate (cạnh DAG, quan hệ cha-con, lịch sử hoàn thành) mà hàm này không có snapshot để validate
lại. Sửa tay 7 field không có quyền đụng tới chúng.

### 1.4 `AppState.updateTask` — đường ghi DUY NHẤT cho sửa sau khi tạo (Agent A)

```swift
func updateTask(
    _ id: UUID,
    title: String,
    details: String,
    priority: Priority,
    startTime: Date?,
    deadline: Date?,
    durationMinutes: Int?,
    remindPeriod: TimeInterval?
)
```

Thân hàm, ĐÚNG thứ tự này (soi `addTask`/`toggleDone` để copy đúng khuôn side-effect):

1. `let before = tasks`, `let now = clock()`
2. Lấy `TaskItem` hiện có theo `id`; không có → return.
3. Dựng bản sửa: copy nguyên task cũ, thay 7 field.
   - **`details` VÀ `notes` phải cùng được ghi.** `TaskItem` có CẢ HAI: `details` (non-optional,
     là thứ `TaskDetailView` hiển thị và `speakDetails` đọc) lẫn `notes` (optional). `materialize`
     đã ghi cùng giá trị vào cả hai. Sửa một quên một = user gõ mô tả, lưu được, nhưng không hiện
     ra. Luật: `details = tham số details`; `notes = details.isEmpty ? nil : details`.
   - `reminderOverride`: `remindPeriod != nil` → base (`task.reminderOverride ?? globalReminderPolicy`)
     thay `remindPeriod`. `remindPeriod == nil` → giữ `task.reminderOverride` nhưng set
     `remindPeriod = nil` (override nil thì vẫn nil).
4. Có store: `store.updateEditableFields(from: edited)` rồi `tasks = store.fetchAll()`.
   Không store (preview/test): patch thẳng `tasks[index]`.
5. `scheduler?.scheduleReminders(taskId: id)` — **LUÔN gọi, không điều kiện.**
6. `notifyEligibilityAndScheduleResurface(before: before, now: now)`
7. `syncCalendarMirror()`

**Vì sao bước 5 bắt buộc:** `ReminderScheduler.scheduleReminders(taskId:)` đọc lại task tươi từ
store và **thay thế mọi row `.scheduled` chưa gửi** (doc comment của nó nói rõ "deadline edits land
here"), giữ nguyên lịch sử `delivered`/`satisfied`. Không gọi = user đổi hạn 15:00 → 20:00 mà thông
báo vẫn bắn lúc 15:00, và OS vẫn giữ pending request cũ. Gọi cả khi `deadline` bị xoá về `nil` —
lúc đó `derive` chuyển sang nhánh nudge backoff, vẫn cần dựng lại.

---

## §2 — Agent A: `AppState.swift`

Ngoài §1.1/§1.2/§1.4, phải **rà và chuyển mọi chỗ đọc giá trị gốc sang bản `effective*`**:

- `materialize(_:id:now:)` (~3242): 4 dòng `resolvedValue(task.priority, ...)` /
  `task.estimateMinutes` / `task.startTime` / `task.reminderOverride` → đổi sang
  `draft.effectivePriority` / `draft.effectiveEstimateMinutes` / `draft.effectiveStartTime` /
  `draft.effectiveReminderOverride`. **Đây là chỗ quyết định chỉnh sửa có thật sự được lưu hay
  không** — quên là chip đổi số trên màn hình mà task lưu ra vẫn số cũ.
- `mergeTransform(for:)` (~3123): rà y hệt, nhánh merge-vào-task-đã-có phải nhận cùng giá trị.
- `grep` toàn file cho `task.priority`, `task.estimateMinutes`, `task.startTime`,
  `task.reminderOverride`, `draft.task.priority`… và tự quyết từng chỗ: chỗ nào là "giá trị đã
  resolve để lưu/hiển thị" → đổi; chỗ nào là "parser đã đoán gì" (VD `parsedValueDescription`,
  `logCorrection`) → **GIỮ NGUYÊN**, đó chính là bản gốc để so sánh.

Test mới `Volar/Tests/ManualEditDraftTests.swift` (theo khuôn `ConfirmCardManualEditTests.swift`
đã có — `AppState()` không tham số rơi về nhánh no-store, đủ dùng):
1. Mỗi setter trong 4 setter → `effective*` trả giá trị mới với confidence 1.0.
2. Sửa một field mà parser trả về **uncertain (< 0.7)** và user KHÔNG bấm accept →
   `materialize`/`confirmSave` vẫn lưu giá trị user sửa (đây là bug bảo vệ chính, xem §1.1).
3. Field parser KHÔNG trả về (`task.priority == nil`) mà user set → vẫn lưu.
4. `dismissed.contains(kind)` → dù đã set `edited*`, vẫn KHÔNG lưu (dismiss thắng).
5. `updateTask` (no-store): đổi cả 7 field → `tasks[0]` phản ánh đủ, `details` và `notes` khớp nhau.

## §3 — Agent B: `PopoverView.swift`

Cho 4 chip `priority` / `estimate` / `startTime` / `reminder` trong `attributeChips(_:)` (~585):

1. **Đọc qua `draft.effective*`**, không phải `draft.task.*` — nếu không, chip vẫn hiện số cũ sau
   khi user sửa.
2. Thêm `onTap:` mở editor (Chip đã có sẵn tham số `onTap`, xem doc comment của nó: chỉ bắn khi
   chip không còn nét đứt, nên không giẫm lên `onAccept`).
3. Trạng thái **vắng giá trị** (`effective* == nil`, chưa dismiss) → pill nét đứt "Add …" y hệt
   `DeadlineControl`'s "Add time" (`PopoverView.swift:1433-1449`). Nếu không có, user không thể
   THÊM priority/estimate cho task parser không đoán ra.
4. Trạng thái **đã dismiss** → không render gì, y như `DeadlineControl` (dismiss thắng, không có
   cửa sau).

Editor cho từng loại — mỗi cái là một `View` struct riêng có `@State` của nó, đúng lý do
`DeadlineControl` là struct riêng (một `@ViewBuilder` method không sở hữu được `@State` riêng cho
từng draft):
- `priority` → `Menu` 3 dòng High/Medium/Low (dùng khuôn `dependencyPicker`'s `Menu`, ~801).
- `startTime` → `.popover` + `DatePicker([.date, .hourAndMinute])`, sao y `DeadlineControl`.
- `estimate` → `.popover` + danh sách preset phút `[5, 10, 15, 30, 45, 60, 90, 120, 180, 240]`.
- `reminder` → `.popover` + danh sách chu kỳ `[15m, 30m, 1h, 2h, 4h, 1 ngày]` (giây).

**KHÔNG dùng `Menu` để chứa `DatePicker`** — trên macOS `Menu` là `NSMenu`, render control sống
không đáng tin; đó chính là lý do `DeadlineControl` chọn `.popover` (đọc doc comment ~1398).

`reminderLabel` hiện tại (~1028) chỉ đếm `offsets` → phải hiện được chu kỳ khi có `remindPeriod`
(VD "Nhắc mỗi 2h" / "Every 2h"), nếu không user sửa xong nhìn nhãn không thấy gì đổi.

## §4 — Agent C: `TaskStore.swift` + `TaskDetailView.swift`

`TaskStore.updateEditableFields(from:)` theo §1.3 (dùng `fetchModel(_:)` private đã có).

`TaskDetailView` thành sửa-tại-chỗ, giữ nguyên layout tổng (header → meta row → description →
actions), đọc task sống từ `appState.detailTask` như hiện nay:
- Title → `TextField` (giữ cỡ chữ 24 hiện tại).
- Meta row → priority (`Menu`), deadline (`DatePicker`), duration, start time, remind period.
- Description → `TextField(axis: .vertical)` thay `Text` read-only. Giữ nguyên nút "Read description".
- Actions row giữ nguyên Close / Delete / Mark done.

**Cách commit (đóng băng — không tự đổi):** buffer `@State` cục bộ seed từ task; commit bằng
`appState.updateTask(...)` khi (a) control rời rạc đổi giá trị (menu/picker) — commit ngay, (b) ô
text mất focus, (c) bấm Close, (d) `.onDisappear`. `(d)` là lưới an toàn cho đường Esc/click ra
ngoài; commit phải **idempotent** — so với giá trị gốc, không đổi thì không gọi `updateTask` (mỗi
lần gọi là một `fetchAll` + dựng lại lịch nhắc, không được bắn vô cớ).

**Không tự thêm nút Save.** Anh Khôi chọn bản sửa-tại-chỗ; (a)-(d) đã phủ hết đường thoát.

Test mới `Volar/Tests/TaskUpdateTests.swift`: `updateEditableFields` ghi đúng 7 field; và **không**
đụng `conditions`/`parentId`/`status`/`createdAt` (dựng task có sẵn condition + parent, update,
assert chúng còn nguyên) — đây là bất biến §1.3 tồn tại để bảo vệ.

---

## §5 — Luật chung cho cả 3 agent

- Viết code trên Windows, **KHÔNG có Swift/Xcode để build**. Chỗ nào không chắc API macOS thì chọn
  phương án đã có tiền lệ trong chính repo này, và đánh dấu `// UNVERIFIED:` kèm lý do.
- Không sửa file ngoài danh sách sở hữu. Cần thứ gì từ file của agent khác → dùng đúng chữ ký ở §1.
- File test mới nằm dưới `Volar/Tests/` — `project.yml` gom theo thư mục nên không phải sửa nó.
- Tự review 6 mục trước khi báo xong: (1) đúng hợp đồng §1, (2) không rò ra ngoài file sở hữu,
  (3) đường lưu thật sự chạy (chỉnh sửa có tới `materialize`/store không), (4) side-effect nhắc
  nhở/calendar/eligibility, (5) trạng thái biên (vắng giá trị, đã dismiss, uncertain, no-store),
  (6) chỗ nào không verify được thì nói rõ chứ đừng đoán bừa.
