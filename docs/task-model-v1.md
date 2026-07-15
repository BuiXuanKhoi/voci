# Voci Task Model v1 — thiết kế đã chốt (2026-07-15)

Kết quả buổi thảo luận "voice → task, người ADHD cần gì trên mỗi task".
Tài liệu này **supersede** phần model của `specs/001-nexttask-engine/data-model.md`
(cụ thể: `dependsOn` bị thay bằng `conditions[]`). Engine 001 đã implement sẽ được
refactor theo tài liệu này (xem backlog).

## Nguyên tắc gốc

1. **Capture zero-friction (ADHD-first).** Mọi field đều optional với default hợp lý.
   Các "câu hỏi khi thêm task" là checklist cho **parser tự tìm trong lời nói**,
   KHÔNG phải form bắt user điền. Không nói → để trống, task vẫn lên board.
2. **Never Silently Guess (constitution II).** Parser chỉ điền field khi lời nói
   thể hiện rõ; mơ hồ → để `nil` và surface lên confirm card, không đoán bừa.
3. **Engine thuần giữ nguyên tính chất (constitution III).** `nextTask()` vẫn pure,
   deterministic; `conditions` được đánh giá từ snapshot + `now`, không I/O.

## Model thống nhất (persisted superset)

```swift
struct Task {
    let id: UUID
    var title: String
    var notes: String?               // mô tả thêm
    var sourceTranscript: String?    // NGUYÊN VĂN lời nói — luôn giữ (phao nhớ ADHD)
    var kind: TaskKind               // .task | .review — UI hiển thị khác, engine không đổi
    var status: TaskStatus           // .todo | .inProgress | .done | .archived (như cũ)
    var priority: Int?               // 1…4, nil = unset (như cũ)
    var deadline: Date?              // vẫn là field riêng — drive ORDERING (tier 2) + reminders
    var estimateMinutes: Int?        // ước lượng thời gian — chống time blindness
    var conditions: [Condition]      // gate ELIGIBILITY: TẤT CẢ phải thỏa (AND)
    var recurrence: Recurrence?      // lặp lại; engine KHÔNG đọc — app layer xử lý khi done
    var reminderOverride: ReminderPolicy?  // nil = dùng policy leo thang mặc định toàn cục
    var parentId: UUID?              // task con của breakdown trỏ về task mẹ (bổ sung 2026-07-15)
    let createdAt: Date
}

enum TaskKind { case task, review }

enum Condition: Sendable, Equatable {
    case taskDone(UUID)                            // thay dependsOn cũ
    case afterDate(Date)                           // thay notBefore (defer/snooze)
    case external(description: String, satisfied: Bool)  // "chờ client ký NDA" — user confirm tay/giọng nói
}

enum Recurrence: Sendable, Equatable {
    case daily
    case weekly          // cùng thứ trong tuần
    case monthly         // cùng ngày trong tháng
    case every(days: Int)
}

struct ReminderPolicy: Sendable, Equatable {
    var offsets: [TimeInterval]      // mốc nhắc tương đối so với deadline, vd [-86400, -3600, 0]
    var repeatEvery: TimeInterval?   // "nhắc mỗi 30 phút" — nil = không lặp
}
```

**Phân vai rõ ràng:** `conditions` quyết định *task có được phép hiện/chọn không*
(eligibility); `deadline` quyết định *task khẩn cấp tới đâu* (ordering) và *khi nào nhắc*
(reminder). Không trộn hai vai.

## Engine subset (VociCore.Task — chỉ field selection-relevant)

`id, title, status, priority, deadline, conditions, createdAt`.
(`notes/sourceTranscript/kind/estimateMinutes/recurrence/reminderOverride` thuộc persisted
model, engine không đọc. `estimateMinutes` sẽ vào engine ở v2 nếu làm chế độ
"quick win theo thời gian trống" — xem backlog.)

## Eligibility (thay §FR-003 cũ)

Task eligible ⇔ `status ∈ {todo, inProgress}` **và** mọi `Condition` đã thỏa:

- `.taskDone(id)`: task tham chiếu là `.done`, `.archived`, hoặc **vắng mặt khỏi snapshot**
  (đã xóa) — giữ nguyên mapping resolution của spec 001. `.todo`/`.inProgress` = còn chặn.
- `.afterDate(d)`: `now >= d`.
- `.external(_, satisfied)`: `satisfied == true`. Máy không tự đánh giá — user clear bằng
  tay hoặc giọng nói ("client ký rồi"). Khi tương lai có tích hợp (Mail/Calendar) thì loại
  này mới auto được.

Ordering 5 tier (status class → deadline urgency → priority → createdAt → id) **giữ nguyên**.

## Graph invariant (thay DependencyGraph cũ)

Đồ thị các cạnh `.taskDone` trích từ `conditions` của mọi task **phải là DAG**.
Validation lúc thêm condition: từ chối self-reference và mọi cạnh tạo cycle (DFS như cũ),
message thân thiện như spec 001. Cycle detection CHỈ chạy trên `.taskDone`
(`afterDate`/`external` không tạo cạnh).

## Recurrence — xử lý ngoài engine

`nextTask()` không biết recurrence tồn tại. Khi user done một task có `recurrence`,
**app layer** reset task in-place: `status → .todo`, dời `deadline` (và mọi
`.afterDate` condition) sang chu kỳ kế tiếp, reset `.external` về unsatisfied nếu có.
(Chọn reset-in-place thay vì spawn task mới cho v1 — đơn giản, giữ id; lịch sử hoàn thành
là việc của persistence/analytics sau này.)

## Reminder — hybrid đã chốt

Mặc định toàn cục kiểu **leo thang**: nhắc lúc deadline −1 ngày, −1 giờ, đúng giờ
(config được trong Settings). Task chỉ mang `reminderOverride` khi user **nói rõ**
("nhắc anh mỗi 30 phút"). Reminder engine là feature riêng (constitution IV) — model
chỉ định nghĩa field.

## Checklist cho parser (7 câu hỏi → field)

| User nói gì | Parser điền |
|---|---|
| "…5 giờ chiều mai" / "trước thứ 6" | `deadline` |
| "nhắc anh mỗi tiếng" | `reminderOverride` |
| nội dung việc | `title` (+ `notes`); `sourceTranscript` LUÔN giữ nguyên văn |
| "làm B sau khi xong A" / "xong A thì làm B" | `conditions += .taskDone(A)` trên B (2 chiều diễn đạt, 1 cạnh) |
| "thứ 2 mới làm" / "để tuần sau" | `conditions += .afterDate(...)` |
| "phải chờ client ký NDA đã" | `conditions += .external("client ký NDA", satisfied: false)` |
| "xong X thì review lại" | tạo task THỨ HAI `kind: .review`, `conditions: [.taskDone(X)]` |
| "chắc mất nửa tiếng" | `estimateMinutes` |
| "mỗi sáng" / "hằng tuần" | `recurrence` |

Không match gì → chỉ `title` + `sourceTranscript` + `createdAt`. Task vẫn hợp lệ.

## Bổ sung 2026-07-15 (thảo luận breakdown + done-history)

- **`parentId: UUID?`** — task con của breakdown trỏ về task mẹ. Các bước con vẫn chain
  nhau bằng `.taskDone` (engine không đổi); `parentId` chỉ phục vụ UI gộp nhóm/tiến độ
  ("3/7 bước") và app layer **auto-complete task mẹ khi bước cuối done**. Task mẹ còn con
  chưa xong thì không được chọn trực tiếp (engine chọn bước con).
- **`completedAt: Date?`** trên persisted task + **completion log** (bảng event riêng:
  `taskId, title snapshot, completedAt, estimateMinutes?`) ghi MỖI lần done. Cần log riêng
  vì task recurrence reset-in-place sẽ xóa dấu vết done trên chính task — log là nguồn
  dữ liệu cho "Đã làm được" (accomplishment view) và streak. Engine không đọc log.

## Quyết định đã loại

- **Energy/context tag** ("việc não/tay chân") — bỏ, thêm friction không đáng.
- **Điều kiện máy-tự-đánh-giá cho external** — chờ có tích hợp nguồn sự kiện thật.
- **`waitingOn` free-text** — bị thay bằng `.external` (option 3 thắng option 1).
