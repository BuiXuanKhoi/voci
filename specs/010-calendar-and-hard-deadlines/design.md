# 010 — Đọc lịch + hạn cứng/hạn mềm

**Anh Khôi chốt 2026-08-19.** Opus thiết kế, Sonnet execute.

Hai việc rời nhau về mặt tính năng nhưng chung một gốc: **app đang tự tin về những thứ nó không
biết.** Nó không biết Hạnh có họp lúc 14:00 nên vẫn bảo "làm việc 45 phút này" lúc 13:50; nó không
biết hạn nào là hạn có chế tài nên mời "đẩy sang mai" với thái độ y hệt nhau cho việc dọn bàn và
việc nộp tờ khai thuế.

## §0 — Bối cảnh: phần lớn đã có sẵn, đây là nối dây chứ không phải xây mới

| Đã có | Ở đâu | Hiện dùng làm gì |
|---|---|---|
| Quyền EventKit + xin quyền + mở System Settings | `Shared/Integrations/CalendarAccess.swift` | mirror task ra lịch |
| Ghi task ra lịch (một chiều) | `Shared/Integrations/CalendarSync.swift` | `reconcile(tasks:)` |
| **Đọc lịch — `nextEvent(within:now:excludingCalendarID:)`** | `CalendarAccess.swift:207` | **CHỈ `GlanceHUD` dùng**, trả về đúng 1 event trong 2h |
| Ba luật loại trừ đã đúng | cùng chỗ | all-day, calendar mirror của Volar, event đã bắt đầu |
| `WaitingMode.decide` — "mốc cứng của ngày" | `Shared/Model/WaitingMode.swift` | dùng `deadline` làm **proxy** |

`WaitingMode.swift` có comment đầu file dặn **đừng** thêm EventKit vào để cải thiện proxy. Đó là dấu
vết của chính quyết định bác-đọc-lịch ngày 2026-08-07. Anh Khôi lật lại quyết định đó (2026-08-19),
nên proxy hết lý do tồn tại — **nhưng comment vẫn đúng về mặt kỹ thuật**: `decide` phải ở lại là hàm
thuần, mốc cứng được TRUYỀN VÀO như dữ liệu (§2.3).

## §1 — Quyết định đã chốt (không bàn lại)

1. **"Event lớn" = dùng cờ busy/free của chính lịch, không tự bịa ngưỡng.** Chi tiết §2.1.
2. **Chỗ nhắc trùng lịch đắt nhất là LÚC TẠO TASK**, không phải lúc xem danh sách. §2.4.
3. **`WaitingMode.decide` giữ nguyên là hàm thuần**, không import EventKit. §2.3.
4. **Đọc lịch là toggle RIÊNG, mặc định TẮT**, dù quyền EventKit đã cấp cho mirror. §2.5.
5. **Tiêu đề event KHÔNG BAO GIỜ vào payload cloud parse.** Ranh giới cứng, không phải tuỳ chọn.
6. **Hạn cứng KHÔNG đổi thứ tự sắp xếp của engine.** §3.4.
7. **`deadlineKind` v1 chỉ có toggle tay, mặc định `.soft`.** Không đoán bằng AI. §3.5.

---

# PHẦN A — Đọc lịch

## §2.1 — Định nghĩa "event lớn"

**KHÔNG tự đặt ngưỡng thời lượng làm tiêu chí chính.** `EKEvent.availability` đã là câu trả lời của
hệ thống cho đúng câu hỏi "cái này có thật sự chiếm thời gian của tôi không", và người dùng đã tự
khai nó rồi. Bộ lọc, bốn điều kiện:

1. `availability != .free` — cờ busy/tentative/unavailable của chính lịch.
2. `!event.isAllDay` — đã có sẵn trong `nextEvent`, giữ.
3. **Không phải event mình đã BẤM TỪ CHỐI.** Kiểm `event.attendees` tìm `isCurrentUser == true`, nếu
   `participantStatus == .declined` thì loại. Đi họp cái mình đã từ chối không phải xung đột.
4. Thời lượng ≥ **15 phút** — chỉ để chặn nhiễu (mốc đánh dấu 5 phút), KHÔNG phải định nghĩa "lớn".

Cộng luật loại trừ sẵn có: bỏ calendar mirror của Volar (`CalendarSync.volarCalendarID`), nếu không
app sẽ đọc chính task của mình lên rồi báo là "cuộc họp".

## §2.2 — API mới trong `CalendarAccess.swift`

`nextEvent` GIỮ NGUYÊN (GlanceHUD đang dùng, không phá). Thêm:

```swift
/// Một khoảng thời gian đã bị chiếm bởi một event "lớn" (§2.1).
struct BusyBlock: Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
}

/// Mọi BusyBlock giao với [from, to). Trả `[]` khi chưa có quyền hoặc toggle đọc lịch đang tắt —
/// KHÔNG throw: thiếu quyền phải làm tính năng biến mất, không phải làm app báo lỗi.
func busyBlocks(from: Date, to: Date, excludingCalendarID: String?) -> [BusyBlock]
```

Bộ lọc §2.1 phải nằm ở **một chỗ duy nhất** (một `static func isBig(_:now:) -> Bool` private) và
`nextEvent` cũng gọi nó — nếu không, hai đường đọc lịch sẽ có hai định nghĩa "event đáng kể" và trôi
dạt khỏi nhau. Đây là đúng lớp lỗi đã xảy ra với `AppState.eligibleOrder`/`eligibleTasks`.

> ⚠️ `nextEvent` hiện KHÔNG lọc `availability` và KHÔNG lọc declined. Cho nó dùng chung `isBig` là
> một thay đổi hành vi có chủ ý của Glance (nó sẽ thôi báo những event `free`/đã từ chối). Đó là
> cải thiện, ghi vào comment, không lặng lẽ.

## §2.3 — `WaitingMode`: bỏ proxy, nhận mốc cứng như dữ liệu

`decide` hiện tự đi tìm "deadline gần nhất" làm mốc. Đổi thành **nhận danh sách mốc từ caller**:

```swift
struct HardAnchor: Equatable, Sendable {
    let title: String
    let at: Date
    let source: Source   // .deadline(taskID: UUID) | .calendar
}
```

`decide(...)` nhận `anchors: [HardAnchor]`, chọn mốc tương lai gần nhất. Hàm vẫn **thuần**: không
EventKit, không `Date()`, không `Calendar.current`. `AppState` là chỗ trộn hai nguồn (deadline của
task + `busyBlocks`) rồi truyền vào.

Sửa lại comment đầu file: cảnh báo "đừng thêm EventKit vào đây" **giữ nguyên và vẫn đúng**, nhưng
phải ghi rõ lý do mới (giữ tính thuần), chứ không phải lý do cũ (Volar không đọc lịch).

## §2.4 — Ba chỗ hiện cảnh báo trùng lịch, xếp theo giá trị giảm dần

**(a) Thẻ xác nhận lúc tạo task — QUAN TRỌNG NHẤT.** Hạnh nói *"gọi khách lúc 2 rưỡi"*, thẻ xác nhận
hiện thêm một dòng: `14:00–15:00 · Họp nội bộ`. Bắt ở đây rẻ hơn nhiều so với để Hạnh phát hiện lúc
14:25. Chỗ này là `ConfirmDraft` (`Shared/App/AppState.swift`) + view trong
`Volar/Sources/Views/PopoverView.swift`.

Tính **một lần lúc dựng draft** trong `buildConfirmDrafts`, y hệt cách `overdueSuggestion` sẵn có
làm — KHÔNG tính lại mỗi lần render.

**(b) Thẻ NOW.** Một dòng: `20 phút nữa có họp — việc này 45 phút`. Chỉ hiện khi việc thật sự không
lọt: `durationMinutes > phút còn lại tới mốc`. Không có duration thì không đoán, không hiện gì.

**(c) Chip trên row** cho task có `deadline` rơi vào giữa một `BusyBlock`. Dùng lại đúng hình dạng
chip blocked/waiting của đợt 009, chữ `textMut`, không màu.

**Không làm:** thông báo đẩy, đếm ngược, âm thanh. Cảnh báo trùng lịch là thông tin, không phải báo
động.

## §2.5 — Quyền riêng tư

- Toggle **riêng** trong Settings ▸ Calendar: "Read my calendar" — **mặc định TẮT**. Ghi vào lịch và
  đọc tiêu đề cuộc họp ra không cùng mức nhạy cảm; quyền EventKit đã cấp cho mirror KHÔNG mặc nhiên
  là sự đồng ý cho việc đọc.
- Tắt toggle ⇒ `busyBlocks` trả `[]`. Không cache, không lưu event xuống đĩa, không đưa vào store.
- **Tiêu đề event không bao giờ được đưa vào payload gửi lên cloud parse.** Khi thêm dòng cảnh báo
  vào `ConfirmDraft`, phải kiểm rằng field mới KHÔNG lọt vào bất kỳ struct request nào của
  `CloudParser`. Grep `CloudParser.appendContext` để chắc.

---

# PHẦN B — Hạn cứng / hạn mềm

## §3.0 — Vấn đề, phát biểu cho đúng

Lúc đầu tôi (Opus) tưởng đây là chuyện màu sắc — luật cấm-đỏ làm hạn quá hạn trông quá bình thản.
Đọc code xong thì màu là phần nhỏ. **Lời nói dối nằm ở hành động app cho phép.**
`Volar/Sources/Views/SweepView.swift:59`, nguyên văn:

> "Quick pass through what's still open. Anything left over just rolls to tomorrow — **no harm
> done**."

Đúng với "dọn bàn làm việc". Sai với "nộp tờ khai VAT quý III" — ở đó harm có thật và tính bằng
tiền. App **không đẩy được hạn nộp thuế sang mai**; nó chỉ đẩy được *kế hoạch* của người dùng. Gọi
hai thứ đó bằng một cái tên là chỗ hỏng.

## §3.1 — Model

`Shared/Model/TaskItem.swift`:

```swift
enum DeadlineKind: String, Sendable, Equatable, CaseIterable {
    case soft   // mốc tự đặt — đẩy được, không ai phạt
    case hard   // mốc bên ngoài áp, có chế tài — app không đẩy được
}
var deadlineKind: DeadlineKind = .soft
```

Mặc định `.soft` để mọi task đang tồn tại giữ nguyên hành vi. Vô nghĩa khi `deadline == nil` — coi
như `.soft`, không cần validate.

**KHÔNG thêm vào `VolarCore.Task`.** Engine không dùng tới nó (§3.4), thêm vào là mở rộng bề mặt
public không có người gọi.

**Persist — SỬA LẠI, spec bản đầu viết SAI chỗ này.** `TaskStore.swift` không giữ field nào cả; class
SwiftData `@Model` nằm ở **`Shared/Model/VolarTask.swift`**. Property lưu trữ bắt buộc phải khai trên
chính class đó, nên không có cách nào persist mà chỉ đụng `TaskStore.swift`. Đủ bốn điểm, thiếu một
điểm là field im lặng về `.soft` sau mỗi lần mở app mà không ai phát hiện:

1. `VolarTask`: stored property `deadlineKindRaw: String = "soft"` — raw-string backed theo đúng
   tiền lệ `statusRaw`/`whenRaw`/`kindRaw` trong cùng file, **literal default** (không phải tham
   chiếu static property) để `@Model` suy ra lightweight migration.
2. `VolarTask`: computed accessor `deadlineKind`, fail-closed về `.soft` nếu raw value lạ.
3. `VolarTask.asTaskItem` — đọc lên. `VolarTask.apply(_:)` — ghi xuống.
4. `TaskStore`: `updateEditableFields` và `insertSanitized`. (`mergeIntoExisting` đi qua `apply(_:)`
   nên tự có, không cần sửa.)

Migration của dữ liệu cũ: theo đúng pattern sẵn có, nhưng **ghi `UNVERIFIED` trong code** y hệt cách
file đó đã ghi cho các migration khác. Không khẳng định nó an toàn khi chưa build trên Mac.

**Đường ghi từ UI phải khép kín:** `TaskDetailView.commitIfChanged()` → `AppState.updateTask` →
`TaskStore.updateEditableFields` → `VolarTask.deadlineKind`. Tham số `deadlineKind` của `updateTask`
**cố ý KHÔNG có giá trị mặc định**: nó non-optional và ghi đè thẳng, nên một default sẽ biến mọi
call site quên truyền thành một đường **âm thầm hạ hạn cứng xuống hạn mềm** — không lỗi, không
cảnh báo. Đúng loại nói dối im lặng mà cả tính năng này sinh ra để diệt. Giá phải trả là mọi call
site phải nói rõ ý định; đó là điều mong muốn, không phải phiền toái.

## §3.2 — Bốn khác biệt của `.hard` (chỉ MỘT trong đó là màu)

| | `.soft` | `.hard` |
|---|---|---|
| Badge | chữ thường như hiện tại | **chip có nền** `veil(0.10)`, mono, kèm nhãn ngắn ("due") |
| Quá hạn | `VolarColor.reschedule` (xám), "needs rescheduling" | `VolarColor.high` (đất nung) — **vẫn KHÔNG phải `destruct` đỏ** |
| Trong drawer "Later" thu gọn | bị gộp vào phần ẩn | **không bao giờ bị giấu** — luôn nằm ở phần hiện sẵn |
| Sweep cuối ngày | "Skip" (rolls to tomorrow) | **không có nút đó** — thay bằng "Change due date" mở đúng ô ngày |

Điểm 4 là fix thật, ba điểm còn lại là để nhìn thấy nó.

## §3.3 — Câu chữ SweepView

Dòng 59 hiện tại chỉ đúng khi mọi task đang mở đều `.soft`. Sửa: khi tập đang quét **có** ít nhất
một `.hard`, câu mở đầu không được nói "no harm done". Viết lại thành hai nhánh, hoặc một câu trung
tính đúng cho cả hai. **Không** thêm giọng trách móc — luật anti-shame giữ nguyên, cái phải bỏ là
lời trấn an SAI, không phải sự điềm tĩnh.

Nút "Skip" của `.hard`: đổi nhãn thành "Change due date", hành động mở ô sửa deadline. KHÔNG tự động
cộng một ngày.

## §3.4 — Không đụng thứ tự engine

`orderedBefore` tier 2 đã đẩy mọi deadline gần lên trước. Hạn cứng còn xa **không có lý do gì** chen
lên trước hạn mềm hôm nay. Đổi tier 2 là thêm rủi ro cho engine đã có test mà không thêm giá trị.
`rankReason` (đợt 009) cũng KHÔNG cần case mới.

## §3.5 — Rủi ro đã biết, ghi ra để ba tuần nữa còn nhớ

**v1 chỉ có toggle tay.** Đoán "câu này có hậu quả pháp lý" từ lời nói là đúng loại phỏng đoán sai
âm thầm — sai kiểu không ai phát hiện. Nhưng người ADHD sẽ không đi bật toggle.

**Nếu sau ~3 tuần dùng thật mà gần như không task nào được đánh `.hard`, thiết kế này THẤT BẠI** và
phải nghĩ lại từ đầu, chứ không phải chỉnh thêm cho toggle dễ bấm hơn. Ghi mốc này vào backlog.

## §4 — Chia việc (file-disjoint)

**Wave 1 — song song:**

| Agent | File sở hữu | Nội dung |
|---|---|---|
| A | `Shared/Integrations/CalendarAccess.swift`, `Shared/Model/WaitingMode.swift` | §2.1, §2.2, §2.3 |
| B | `Shared/Model/TaskItem.swift`, `Shared/Model/TaskStore.swift` | §3.1 |

**Wave 2 — sau wave 1:**

| Agent | File sở hữu | Nội dung |
|---|---|---|
| C | `Shared/App/AppState.swift`, `Volar/Sources/Views/SettingsView.swift` | §2.4(a) phần dựng draft, §2.5 toggle, trộn anchors cho `WaitingMode` |
| D | `Volar/Sources/Views/SweepView.swift`, `Volar/Sources/Views/TaskDetailView.swift` | §3.2 hàng 4, §3.3, toggle `.hard` trong detail |

**Wave 3 — sau wave 2:**

| Agent | File sở hữu | Nội dung |
|---|---|---|
| E | `Shared/Views/TaskRow.swift`, `Volar/Sources/Views/TodayView.swift`, `Volar/Sources/Views/PopoverView.swift` | §2.4(a) phần view, §2.4(b), §2.4(c), §3.2 hàng 1–3 |

**Luật cho mọi agent:** không sửa file ngoài danh sách (thấy thì BÁO); không chạy
`supabase/scripts/probe-*.ts`; không có Swift toolchain ⇒ viết mù, **cấm báo "đã build xanh"**;
`.strokeBorder` thay `.stroke` khi kèm `.clipShape`; mọi `Button(.plain)` có `.background` phải kết
thúc label bằng `.contentShape(Rectangle())`; token màu lấy từ `Shared/Design/Theme.swift` (đợt 009
vừa đổi hết sang light+dark, **đọc lại trước khi dùng**).
