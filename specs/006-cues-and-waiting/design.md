# 006 — Cue (implementation intentions) + Waiting-mode holder + bước đầu vật lý

> Opus chốt design 2026-08-08 theo yêu cầu anh Khôi. Nền khoa học: `docs/adhd-research-v1.md`
> §9 (implementation intentions d=0,65 — bằng chứng phi-thuốc mạnh nhất cả report), §7
> (waiting mode, time blindness), §6 (pha ngủ trễ 26–33%). Thay thế/gộp hai mục backlog:
> "★ CUE / NEO THEO SỰ KIỆN — task_cues_v1" và "MAI LÀM (B) bước đầu vật lý".

## 0. Ba phát hiện khi đọc code — đọc trước khi làm bất cứ gì

**(1) Tầng heuristic breakdown là CODE CHẾT, không phải tầng chưa sửa.**
Backlog mục (B) viết "tầng thứ 3 bị bỏ sót, chưa bao giờ được sửa" và đặt ra một quyết định
khó (bịa 1 bước hay trả rỗng). Kiểm code: `IntentRouter.breakdown` đã **gỡ hẳn** heuristic floor
từ 2026-07-28 (`IntentParsing.swift:307`), `AppState.fetchBreakdown` truyền `heuristicFloor: []`
(`AppState.swift:5398`), và `HeuristicNLParser` không còn call site production nào
(grep: chỉ còn trong comment). 5 bước bịa tiếng Anh ở `NLParser.swift:698-704` **không bao giờ
tới mắt user**. ⇒ Không có quyết định sản phẩm nào cần chốt ở đây; đây là việc dọn code chết.
Việc THẬT còn lại của mục (B) là: **chứng minh 2 tầng model còn sống thật sự sinh bước vật lý** —
tức viết `probe-breakdown.ts`, thứ repo chưa có.

**(2) Calendar đọc-vào đã bị anh Khôi bác 2026-08-07** ⇒ mọi thiết kế cue/waiting-mode trong
đợt này **không được phụ thuộc EventKit**. Hệ quả cụ thể: bỏ `cueKind = calendarEventEnd` khỏi
thiết kế cue cũ trong backlog; waiting-mode holder phải chạy trên dữ liệu Volar tự sở hữu.

**(3) Volar không có khái niệm "cuộc hẹn".** `startTime` là inert và chỉ set từ câu khẩn
("làm ngay") — KHÔNG phải giờ hẹn (`TaskItem.swift:36-44`). Mốc cứng duy nhất Volar có là
`deadline`. Waiting-mode v1 dùng `deadline` làm proxy cho mốc, và ghi rõ đó là proxy.

## 1. Quyết định kiến trúc lớn nhất: cue là lớp SURFACING, không phải lớp ELIGIBILITY

**Chốt: KHÔNG thêm case vào `VolarCore.Condition`. Không đụng VolarCore một dòng nào.**

Lý do (theo thứ tự quan trọng):

1. **Cue là điều kiện gate thì task bị GIẤU cho tới khi cue fire.** Với cue tầng B (máy không
   bắt được: "tới văn phòng", "sau khi ăn trưa") thì task bị giấu **vĩnh viễn** — đúng cái bẫy
   "task biến mất im lặng" mà chính backlog cảnh báo, và đúng nỗi sợ "app nuốt mất việc của tôi"
   ở mục re-entry.
2. Cue chỉ cần làm đúng hai việc: **(a) nổi lên đúng lúc, (b) đọc lại nguyên văn lời user**.
   Cả hai đều là surfacing. Không việc nào cần eligibility.
3. `Condition` là public enum trong contract đóng băng của VolarCore — thêm case làm vỡ mọi
   `switch` exhaustive, kéo theo `ConditionDTO` (`VolarTask.swift:27`), wire schema, và 4 luật
   frozen của envelope. Chi phí lớn, đổi lại một ngữ nghĩa mình không muốn.

Hệ quả tốt: task có cue **vẫn eligible bình thường** ở mọi thời điểm. Cue chỉ **nâng thứ tự nổi
lên** và **thêm một câu trích nguyên văn**. Không có đường nào để cue nuốt mất việc — đây là lý
do thiết kế này an toàn hơn hẳn bản trong backlog.

## 2. Ba việc, và ranh giới giữa chúng

### Việc A — implementation intention trong breakdown (đòn d=0,65, rẻ nhất)

Đổi output breakdown từ *"bước vật lý"* sang *"khi &lt;cue có thật&gt; thì &lt;bước vật lý&gt;"*.

**Chốt: KHÔNG đổi shape `[String]`.** Cue nằm ngay trong chuỗi step:
`"Sau khi pha cà phê sáng → mở file báo cáo Q3"`. Lý do: đổi shape đụng `IntentParser` frozen
protocol + `BreakdownStepOut` + `TaskBreakdownView` + 3 tier; trong khi toàn bộ giá trị khoa học
của implementation intention nằm ở **việc user đọc và nhận lấy liên kết nếu-thì**, không nằm ở
việc máy phân giải được cue. Đây là chủ ý, không phải nợ kỹ thuật.

**Luật cue trong step (áp cho cả 2 tầng model):**
- Cue phải là **SỰ KIỆN đã có sẵn trong ngày của user**, không phải giờ đồng hồ. "9h sáng" bị
  cấm; "sau khi ăn trưa", "khi mở laptop", "sau khi họp xong" được.
  Lý do khoa học: time blindness làm mốc đồng hồ vô nghĩa; và pha ngủ trễ ở ADHD phổ biến gấp
  ~10 lần dân số chung nên mọi giả định giờ cố định đều sai với đúng nhóm user này.
- Chỉ **bước ĐẦU TIÊN** mang cue. Các bước sau đã có cue tự nhiên là "xong bước trước".
  Gắn cue cho cả 9 bước là biến breakdown thành một lịch trình cứng — thứ vision cấm (không
  làm Motion).
- Cue phải rút từ `sourceTranscript`/`notes` nếu ở đó có mốc thật; **không có thì bỏ trống
  cue, giữ nguyên bước vật lý trần** — cấm bịa một thói quen mà user chưa từng nói (cùng luật
  "không đoán thứ user không nói" đã áp cho task_refs).

### Việc B — `TaskCue`: giữ nguyên văn lời user và trả lại đúng lúc

Ca lõi anh Khôi nêu: *"ngủ dậy thì test feature này"*. Hôm nay câu này chỉ có 2 đường xuống,
cả hai đều sai (ép thành `afterDate` với giờ bịa, hoặc `external` bắt user tự tay clear).

**Model (PINNED — cả agent T3 và T4 chép verbatim, T3 sở hữu file):**

```swift
// Volar/Sources/Model/TaskCue.swift
enum CueKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// Phiên tương tác đầu tiên sau một khoảng nghỉ dài (xem `CueFiring.wakeGapHours`).
    /// CỐ Ý không neo vào giờ đồng hồ — pha ngủ trễ ở ADHD phổ biến gấp ~10 lần dân số chung
    /// (`docs/adhd-research-v1.md` §6), nên "buổi sáng" của user này không phải 7h.
    case wake
    /// Ritual cuối ngày (neo theo hành vi đóng máy, không neo giờ cứng).
    case dayEnd
    /// Máy KHÔNG phân giải được ("tới văn phòng", "sau khi ăn trưa", "khi gặp sếp").
    /// Vẫn giữ nguyên `verbatim` và vẫn có giá trị: sức mạnh của implementation intention nằm
    /// ở liên kết nếu-thì user ĐÃ hình thành trong đầu; app chỉ cần đọc lại đúng lời họ.
    case unknown
}

struct TaskCue: Sendable, Equatable, Codable {
    /// Loại cue máy hiểu được. `.unknown` là hợp lệ và phổ biến — không bao giờ vứt cue chỉ vì
    /// không fire được.
    var kind: CueKind
    /// NGUYÊN VĂN lời user ("ngủ dậy thì test feature này"). LUÔN có, kể cả `.unknown`.
    /// Đây là thứ được đọc lại cho user, không phải `kind`.
    var verbatim: String
    var createdAt: Date
    /// SÀN CHỐNG NUỐT VIỆC (bắt buộc): quá mốc này cue thành inert — `verbatim` vẫn hiển thị
    /// được nhưng không còn nâng thứ tự nổi lên nữa. Mặc định `createdAt + 48h`.
    /// Task KHÔNG BAO GIỜ bị ẩn vì cue (xem §1), nên đây là hàng rào thứ hai, không phải thứ nhất.
    var expiresAt: Date
}
```

Persistence: `VolarTask.cueData: Data?` — JSON blob sau computed accessor, **đúng convention
`recurrence`/`reminderOverride`/`delegation` đã có** (`VolarTask.swift:191-204`), fail-closed về
`nil` khi blob hỏng. Optional ⇒ SwiftData lightweight migration, **không cần `VersionedSchema`**.

**Fire — hàm thuần, không I/O** (tiền lệ `FullScreenEscalationDecision.swift`):

```swift
// Volar/Sources/Reminders/CueFiring.swift
enum CueFiring {
    static let wakeGapHours: Double = 6
    /// Quyết định cue nào đáng nổi lên NGAY BÂY GIỜ. Pure: không đọc đồng hồ, không đụng store.
    /// `lastActiveAt == nil` (lần chạy đầu) ⇒ KHÔNG coi là wake — thà im còn hơn chào sai.
    static func firing(now: Date, lastActiveAt: Date?, cues: [(taskId: UUID, cue: TaskCue)])
        -> [UUID]
}
```

- `wake` fire khi `now - lastActiveAt >= 6h`. **Không** dùng `com.apple.screenIsUnlocked`
  (`DistributedNotificationCenter` có thể bị sandbox chặn — chưa verify được trên Mac, và không
  cần thiết cho v1). **Không** dùng "sang ngày lịch mới" (user ngủ 4h sáng sẽ bị chào lúc 1h).
- Hạn chế đã biết, ghi lại để khỏi tưởng là bug: user để máy chạy liên tục thì gap 6h không bao
  giờ tới ⇒ cue `wake` không fire. Cue vẫn hiện ở lần chạm tự nhiên kế tiếp qua đường
  `.unknown`, không mất.
- `volar.lastActiveAt` **dùng chung với mục re-entry** trong backlog (khoá UserDefaults cấp app,
  không phải `lastTouchedAt` cấp task). Việc này chỉ ĐỌC khoá đó; ai làm re-entry trước thì
  người đó tạo.

**Cách trả lại:** mở máy KHÔNG dump list — hiện **đúng một việc**, trích nguyên văn:
> Tối qua anh nói: *"ngủ dậy thì test feature này"*

### Việc C — Waiting-mode holder

Hiện tượng (`docs/adhd-research-v1.md` §7): một mốc 13h30 phá hỏng cả buổi sáng, vì để không
quên thì não phải ghim nó ở tiền cảnh ý thức liên tục, chiếm chỗ mọi việc khác. App giữ hộ mốc
⇒ giải phóng working memory. Đây là externalization đúng nghĩa Barkley.

**Hàm thuần, không calendar, không I/O:**

```swift
// Volar/Sources/Model/WaitingMode.swift
enum WaitingMode {
    struct Decision: Sendable, Equatable {
        let anchorTaskId: UUID
        let anchorTitle: String
        let anchorAt: Date
        let minutesUntil: Int
        /// Quỹ thời gian thật = minutesUntil - bufferMinutes, sàn 0.
        let fitMinutes: Int
        /// Việc khít nhất trong quỹ đó, hoặc `nil` nếu không có việc nào vừa.
        let suggestedTaskId: UUID?
    }
    static let horizonMinutes = 240
    static let bufferMinutes = 10
    static func decide(now: Date, tasks: [TaskItem], eligibleOrder: [UUID]) -> Decision?
}
```

Luật:
- Anchor = task `.todo`/`.inProgress` có `deadline` sớm nhất trong `(now, now + 240']`.
  **Đây là proxy**: Volar chưa có kind "cuộc hẹn" (xem §0.3). Ghi rõ trong doc comment để sau
  này có `.appointment` thì siết lại.
- `suggestedTaskId` = task đầu tiên theo `eligibleOrder` (thứ tự engine đã quyết, **không tự sắp
  lại**) có `durationMinutes ?? defaultTaskDurationMinutes` ≤ `fitMinutes`, và không phải chính
  anchor.
- Không có anchor trong horizon ⇒ trả `nil`, UI không hiện gì. **Không thêm nhiễu khi không có
  mốc nào** — im lặng là mặc định.
- Không có việc nào khít ⇒ `suggestedTaskId = nil`. UI nói thật ("còn 12 phút — chưa có việc nào
  khít") và **không ép** làm gì. Cấm biến khoảng trống thành áp lực.

## 3. Chống nhiễu — luật chung cho cả cue lẫn waiting mode

Kế thừa nguyên tắc chống drift-nagging đã chốt 2026-07-15, không được nới:

- Cue và waiting-mode là **ambient**: hiện trong popover/menu bar/next-up. **KHÔNG push
  notification, KHÔNG âm thanh, KHÔNG full-screen.** Chỉ deadline thật mới được quyền làm phiền.
- Cue chỉ nhắc **một lần mỗi lần fire**. Im lặng = "đừng hỏi nữa", không phải "hỏi to hơn".
- Không đếm, không badge, không "anh đã bỏ lỡ N cue".

## 4. Chia việc cho Sonnet (file-disjoint) — chi tiết ở `tasks.md`

| Task | Ngôn ngữ | File sở hữu | Song song được? |
|---|---|---|---|
| T1 — prompt + schema + probe | Deno/TS | `_shared/gemini.ts`, `_shared/schema.ts`, `tests/schema_test.ts`, `scripts/probe-breakdown.ts` (mới), `scripts/probe-cues.ts` (mới) | ✅ |
| T2 — cue model + firing | Swift | `Model/TaskCue.swift` (mới), `Model/TaskItem.swift`, `Model/VolarTask.swift`, `Reminders/CueFiring.swift` (mới), `Tests/CueFiringTests.swift` (mới) | ✅ |
| T3 — parse plumbing + dọn code chết | Swift | `Parsing/CloudParser.swift`, `Parsing/IntentParsing.swift`, `Parsing/FoundationModelParser.swift`, `Model/NLParser.swift`, `Tests/CloudParserTests.swift` | ✅ |
| T4 — waiting mode | Swift | `Model/WaitingMode.swift` (mới), `Tests/WaitingModeTests.swift` (mới) | ✅ |
| T5 — wire UI (SAU, một mình) | Swift | `App/AppState.swift`, `Views/*` | ❌ chạy sau T2/T4 |

T3 cần type `TaskCue` do T2 sở hữu ⇒ chép **verbatim** khối code ở §2 (tiền lệ "PINNED PUBLIC
SURFACE" của `ParsedCapture.swift`). Không agent nào được sửa định nghĩa đó giữa chừng.

T5 tách riêng vì `AppState.swift` là file 5.000+ dòng — hai agent cùng đụng là công thức xung đột
đã có tiền lệ đau trong repo này.

## 5. Cái gì đợt này KHÔNG làm (ghi để khỏi trôi)

- **Không** đọc calendar (anh Khôi bác 2026-08-07). Không `EKEvent`, không `busyIntervals`.
- **Không** đổi shape `[String]` của breakdown.
- **Không** đụng `VolarCore` (kể cả `Condition`, kể cả engine ordering).
- **Không** làm cue trở thành eligibility gate ở bất kỳ tầng nào.
- **Không** đổi `nextTask()` — waiting mode chỉ LỌC trên thứ tự engine đã trả, không sắp lại.
