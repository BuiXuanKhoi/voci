# 006 — Instruction cho agent execute (Sonnet)

> Đọc `design.md` cùng thư mục TRƯỚC. Design đã chốt, **không tự đổi quyết định kiến trúc**;
> thấy design sai thì DỪNG và báo lại, đừng tự sửa hướng.
> Môi trường: máy Windows, **không có Swift/Xcode** → code Swift viết mù, không build được.
> Deno 2.9 CÓ cài → mọi thay đổi TypeScript **bắt buộc** `deno check` + chạy test trước khi báo xong.

## Luật chung cho mọi task

1. **Chỉ sửa file trong danh sách "file sở hữu" của task mình.** Cần một thay đổi ở file
   ngoài danh sách → ghi vào báo cáo cuối, KHÔNG tự sửa.
2. Giữ đúng giọng comment của repo: giải thích **vì sao**, dẫn nguồn quyết định kèm ngày và
   tên người chốt, đánh dấu `// UNVERIFIED:` cho mọi thứ chỉ Mac mới kiểm được.
3. **Cấm đỏ, cấm badge, cấm đếm số việc chưa làm** — luật chống shame đã chốt của app.
4. Không thêm dependency mới. Không đổi public API của `VolarCore`.
5. **Self-review bắt buộc trước khi báo xong** (6 mục, viết thành 6 dòng trong báo cáo):
   (1) đã đọc lại toàn bộ diff của chính mình chưa; (2) có rò ra ngoài file sở hữu không;
   (3) chỗ nào có thể crash/mất dữ liệu (force unwrap, decode, migration); (4) test có thật sự
   kiểm hành vi hay chỉ kiểm chính nó; (5) chỗ nào mình đoán mà chưa verify được;
   (6) có vi phạm luật nào ở §5 của `design.md` không.

---

## T1 — Prompt + schema + probe (Deno/TypeScript)

**File sở hữu:** `supabase/functions/_shared/gemini.ts`, `supabase/functions/_shared/schema.ts`,
`supabase/tests/schema_test.ts`, `supabase/scripts/probe-breakdown.ts` (mới),
`supabase/scripts/probe-cues.ts` (mới).

### T1.1 — Implementation intention vào breakdown prompt

Sửa `buildBreakdownContents` (`gemini.ts:956`). Prompt hiện tại đã ép bước vật lý (giữ nguyên
toàn bộ phần đó, **không viết lại**), chỉ **THÊM** luật cue cho bước đầu:

- Bước ĐẦU TIÊN — và chỉ bước đầu tiên — nên mở đầu bằng một **cue sự kiện** rồi tới hành động
  vật lý, dạng `<cue> → <hành động>` (VN: "Sau khi ăn trưa → mở file báo cáo Q3").
- Cue phải là **sự kiện đã có sẵn trong ngày user**, lấy từ `sourceTranscript`/`notes`.
  **Cấm giờ đồng hồ** ("9h sáng", "lúc 14:00") — nêu rõ lý do trong prompt là vô ích, chỉ cần
  ra luật.
- **Không tìm thấy mốc thật trong `sourceTranscript`/`notes` ⇒ BỎ cue, để bước vật lý trần.**
  Cấm bịa thói quen user chưa từng nói. Đây là luật cứng, phải nói trong prompt bằng đúng
  giọng "never invent".
- Các bước 2..N **không** mang cue.
- Giữ nguyên: ngôn ngữ step = ngôn ngữ `taskTitle`; bước đầu ≤2 phút; cấm động từ trừu tượng trần.

Áp cùng luật đó cho `MIN/MAX_BREAKDOWN_STEPS` không đổi.

### T1.2 — Cap `task_cues_v1` + field `cue` trên `ParsedTaskOut`

Đúng 4 luật frozen của contract (chỉ THÊM, không sửa/xoá/đổi nghĩa field cũ):

- `schema.ts`: thêm `export interface CueOut { kind: "wake" | "dayEnd" | "unknown"; verbatim: string }`
  và field optional `cue?: CueOut` trên `ParsedTaskOut` (`schema.ts:631`).
- Validator `validateCue(v: unknown): CueOut | undefined` — **fail-closed**:
  `verbatim` phải là chuỗi không rỗng, cap độ dài dùng lại `MAX_TASK_TITLE_CHARS`; `kind` không
  nằm trong 3 giá trị ⇒ ép về `"unknown"` (KHÔNG vứt cả cue — `verbatim` mới là thứ có giá trị);
  `verbatim` rỗng/thiếu ⇒ trả `undefined` (vứt cue, giữ task).
- Gọi từ `validateParsedTask` (`schema.ts:908`) theo đúng khuôn các field optional khác:
  một field hỏng chỉ mất field đó, **không được làm hỏng cả task**.
- `cue` chỉ được sinh khi request khai `client_caps` chứa `"task_cues_v1"` — theo đúng khuôn
  `task_refs_v1` đang dùng (`schema.ts:399`, `ParseRequest.clientCaps`).
- Luật prompt cho cue (thêm vào preamble bản có cap, KHÔNG đụng `SYSTEM_PREAMBLE_CORE` dùng
  chung): khi câu nói neo việc vào một sự kiện thay vì một giờ ("ngủ dậy thì…", "tới văn phòng
  thì…", "sau khi ăn trưa…"), trả `cue.verbatim` = **nguyên văn mệnh đề neo của user**,
  `cue.kind` = `wake` cho ngủ dậy/thức dậy/sáng mai lúc dậy, `dayEnd` cho cuối ngày/trước khi
  ngủ, còn lại `unknown`. **Không được biến cue thành `deadline`** — đây là lỗi chính đang xảy ra
  hôm nay và là lý do tính năng này tồn tại.
- Câu ghép ("ngủ dậy thì test A, làm B"): cue gắn **đúng mệnh đề nó bổ nghĩa (chỉ A)**.
  Không phân phối sang B. Đây là ca probe bắt buộc.

### T1.3 — Hai probe (repo chưa có probe nào cho breakdown)

Chép khuôn từ `supabase/scripts/probe-time-parsing.ts` (có sẵn: cách nạp key, gọi API, in bảng).
Key thật đã có ở `supabase/.env` (đã gitignore).
Chạy: `deno run --env-file=supabase/.env --allow-net --allow-env supabase/scripts/<file>.ts`

- `probe-breakdown.ts` — tối thiểu 8 ca. Assertion máy chấm được:
  bước 1 mở đầu bằng động từ hành động vật lý (dùng danh sách động từ VN+EN như prompt liệt kê);
  bước 1 KHÔNG chứa động từ trừu tượng trần ("plan"/"prepare"/"lên kế hoạch"/"chuẩn bị" đứng một
  mình); mọi step cùng ngôn ngữ với title (≥1 ca VN + ≥1 ca EN);
  có `sourceTranscript` chứa mốc thật ⇒ bước 1 phải có cue; **KHÔNG có mốc nào ⇒ bước 1 KHÔNG
  được có cue** (ca chống bịa, quan trọng nhất);
  bước 1 không chứa số giờ đồng hồ.
- `probe-cues.ts` — tối thiểu 6 ca: "ngủ dậy thì test feature này" (→ `wake`, verbatim đúng,
  **`deadline` phải rỗng**); "tối trước khi ngủ thì đọc sách" (→ `dayEnd`); "tới văn phòng thì
  hỏi Nam" (→ `unknown`, vẫn có verbatim); câu có giờ thật ("3 giờ chiều họp") ⇒ **không cue,
  có deadline** (ca regression chống cue ăn tranh deadline); câu ghép "ngủ dậy thì test A, làm B"
  ⇒ chỉ A có cue; câu thường không mốc ⇒ không cue.

⚠️ **LUẬT NHIỄM ĐỀ (đã dính một lần 2026-08-07):** ví dụ trong prompt và case trong probe phải
**tách bạch tuyệt đối**. Không được lấy case probe làm few-shot.

### T1.4 — Test + kiểm tra

`deno check` sạch; `deno test supabase/tests/` toàn xanh; thêm test cho `validateCue` trong
`schema_test.ts` (ít nhất: kind lạ → `unknown`; verbatim rỗng → drop; verbatim quá dài → drop;
cue hỏng không làm hỏng task). **CHẠY CẢ HAI PROBE THẬT** và dán bảng kết quả vào báo cáo —
không chạy probe thì coi như chưa xong. **KHÔNG deploy** (anh Khôi tự quyết thời điểm).

---

## T2 — Cue model + persistence + firing (Swift)

**File sở hữu:** `Volar/Sources/Model/TaskCue.swift` (mới), `Volar/Sources/Model/TaskItem.swift`,
`Volar/Sources/Model/VolarTask.swift`, `Volar/Sources/Reminders/CueFiring.swift` (mới),
`Volar/Tests/CueFiringTests.swift` (mới).

1. `TaskCue.swift`: chép **verbatim** khối `CueKind`/`TaskCue` ở `design.md` §2, giữ nguyên cả
   doc comment. Thêm `static func defaultExpiry(from:)` = `createdAt + 48h`.
2. `TaskItem.swift`: thêm `var cue: TaskCue?` — đặt cạnh `resumeNote`, thêm vào memberwise init
   với default `nil` (giữ mọi call site cũ compile), và **nhớ cả `asTaskItem`/`apply` phía
   `VolarTask`**.
3. `VolarTask.swift`: `private var cueData: Data?` + computed accessor `var cue: TaskCue?` theo
   **đúng khuôn `recurrence`** (`VolarTask.swift:191`) — `try?` cả hai chiều, hỏng thì `nil`.
   Optional ⇒ lightweight migration; **cấm** đụng `VersionedSchema`. Thêm `cue` vào `asTaskItem`
   và `apply(_:)`.
4. `CueFiring.swift`: hàm thuần theo chữ ký ở `design.md` §2. Không đọc `Date()`, không
   `UserDefaults`, không SwiftData — mọi input qua tham số. Luật:
   - `lastActiveAt == nil` ⇒ trả `[]`.
   - cue đã quá `expiresAt` ⇒ không bao giờ trả về.
   - `wake` chỉ trả khi `now.timeIntervalSince(lastActiveAt) >= wakeGapHours * 3600`.
   - `dayEnd`/`unknown` **không** fire theo gap; chúng để tầng UI hiện ở điểm chạm tự nhiên —
     hàm này trả về chúng chỉ khi caller hỏi rõ, nên tách thành `firing(...)` (chỉ `wake`) và
     `pending(...)` (cue còn hạn, chưa hiện lần nào — dùng cho điểm chạm tự nhiên). Ghi rõ trong
     doc comment sự khác nhau, vì đây chính là chỗ dễ biến thành nagging.
5. `CueFiringTests.swift`: tối thiểu 8 ca — nil lastActive; gap 5h59 không fire; gap 6h01 fire;
   cue hết hạn không fire dù gap đủ; `.unknown` không bao giờ vào `firing`; nhiều cue cùng lúc
   giữ thứ tự đầu vào; cue rỗng trả `[]`; ranh giới đúng bằng 6h (fire, vì `>=`).

**KHÔNG đụng `AppState.swift`, không đụng view nào** — wire là T5.

---

## T3 — Parse plumbing + dọn code chết (Swift)

**File sở hữu:** `Volar/Sources/Parsing/CloudParser.swift`,
`Volar/Sources/Parsing/IntentParsing.swift`, `Volar/Sources/Parsing/FoundationModelParser.swift`,
`Volar/Sources/Model/NLParser.swift`, `Volar/Tests/CloudParserTests.swift`.

1. **Cap mới:** `CloudParser.cuesCapability = "task_cues_v1"`, gửi kèm trong mảng
   `"client_caps"` (`CloudParser.swift:329`) **cạnh** `task_refs_v1`, không thay thế.
2. **Decode `cue`:** thêm vào wire struct của `ParsedTask` theo đúng khuôn hardening đã chốt
   2026-08-01 — **không dùng `Int` non-optional cho số từ JSON**; ở đây là chuỗi nên chỉ cần
   `String?` + validate. `kind` lạ ⇒ `.unknown`, KHÔNG throw. Key thiếu ⇒ `cue = nil`.
   Server chưa deploy ⇒ không có key ⇒ đường cũ chạy y nguyên (bắt buộc có test back-compat).
3. `ParsedTask` thêm `var cue: TaskCue?` — dùng type từ T2 (chép verbatim, xem `design.md` §2;
   **không tự định nghĩa lại** type ở file khác).
4. **FM tier:** thêm cue vào `systemInstructions` của `runParseSession` với **đúng luật T1.2**
   (FM chạy TRƯỚC cloud trên máy macOS 26 — luật chỉ nằm ở `gemini.ts` sẽ không bao giờ chạy
   trên máy đó, đây là bài học đã ghi trong backlog 2026-08-02). Cũng thêm luật cue-bước-đầu
   của T1.1 vào `runBreakdownSession`.
5. **Dọn code chết (`NLParser.swift:695-705`):** `HeuristicNLParser.breakdown` trả 5 bước bịa
   hardcode tiếng Anh, **không còn call site production nào** (xem `design.md` §0.1). Đổi thành
   `return []` và viết doc comment giải thích: không có model thì không có cách trung thực nào
   sinh bước — cùng lý lẽ anh Khôi đã dùng khi bác `too_big` sinh 3-9 bước (2026-07-29).
   ⚠️ `CloudFirstDefaultsAndBreakdownTests.swift:243` có test dùng "nội dung trùng floor heuristic"
   — file đó **KHÔNG thuộc quyền sở hữu của task này**. Kiểm xem test đó có tự dựng mảng của
   riêng nó hay gọi `HeuristicNLParser`; nếu nó GỌI thì **dừng lại và báo**, đừng sửa file ngoài
   phạm vi.
6. `CloudParserTests.swift`: thêm ca — decode cue đủ 3 kind; kind lạ → `.unknown`; thiếu key →
   `nil` (back-compat, server cũ); verbatim rỗng → cue bị bỏ nhưng task vẫn còn; envelope có cả
   `task_refs_v1` lẫn `task_cues_v1` cùng lúc vẫn decode đúng.

---

## T4 — Waiting-mode holder (Swift)

**File sở hữu:** `Volar/Sources/Model/WaitingMode.swift` (mới),
`Volar/Tests/WaitingModeTests.swift` (mới).

Hàm thuần theo chữ ký `design.md` §2 việc C. Ràng buộc:

- Không đọc `Date()`, không `UserDefaults`, không calendar, không `AppState`. Mọi input qua
  tham số — kể cả duration mặc định (`defaultDurationMinutes: Int` tham số, mặc định 30).
- **Không sắp lại thứ tự** — `eligibleOrder` là thứ tự engine đã quyết, chỉ được LỌC.
- Anchor bỏ qua task `.done`/`.archived` và task chính nó không có `deadline`.
- Anchor phải **ở tương lai thật** (`deadline > now`); deadline đúng bằng `now` không tính.
- `fitMinutes = max(0, minutesUntil - bufferMinutes)`.
- Doc comment phải ghi rõ: `deadline` ở đây là **proxy cho "mốc cứng"** vì Volar chưa có kind
  cuộc hẹn (`TaskItem.startTime` là inert, chỉ set từ câu khẩn) — và calendar đọc-vào đã bị
  anh Khôi bác 2026-08-07 nên **không được** thêm đường EventKit.

Test tối thiểu 9 ca: không có deadline nào → nil; deadline ngoài horizon → nil; deadline quá khứ
→ nil; chọn đúng mốc SỚM NHẤT khi có nhiều; `fitMinutes` trừ đúng buffer; buffer lớn hơn khoảng
cách → `fitMinutes == 0`; chọn task khít đầu tiên theo `eligibleOrder` (không phải task ngắn
nhất); không task nào khít → `suggestedTaskId == nil` nhưng Decision vẫn trả về; anchor không
bao giờ tự đề xuất chính nó.

---

## T5 — Wire UI (LÀM SAU, một agent duy nhất, KHÔNG song song)

Chỉ chạy khi T2 + T4 đã xong và Opus review xong. `AppState.swift` + view — file to, một mình.
Nội dung sẽ chốt sau; nguyên tắc bất di: ambient, không push, không badge, không đếm
(`design.md` §3).
