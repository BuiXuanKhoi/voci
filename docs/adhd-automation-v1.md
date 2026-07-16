# Volar — tầng automation cho ADHD (phân tích 2026-07-15)

Trả lời câu hỏi: người ADHD cần gì, automate thế nào để **nhớ việc, tập trung,
không bỏ lỡ, và complete nhanh**. Bổ sung cho `docs/task-model-v1.md` (model là nền,
tài liệu này là các cơ chế chạy trên nền đó).

## Nguyên tắc thiết kế

1. **Mỗi automation phải XÓA một quyết định, không thêm một feature phải quản lý.**
   App task cho ADHD chết vì trở thành "một task nữa phải quản lý". Volar đóng vai
   executive function bên ngoài; user chỉ làm 2 động tác: **nói** (capture) và **tick** (done).
2. **Chống shame spiral bằng thiết kế.** Không tích badge đỏ/số quá hạn. Task quá hạn
   hoặc kẹt lâu → app chủ động hỏi MỘT lần với lối thoát tử tế (dời/chia nhỏ/bỏ),
   không tỏa tội lỗi thụ động. "Bỏ luôn" là câu trả lời hợp lệ.
3. **Đóng vòng đời task cùng một modality: giọng nói.** Nói để tạo → nói để xong →
   nói để clear điều kiện chờ. Đường từ ý nghĩ đến hành động < 2 giây.

## 5 điểm nghẽn executive function → cơ chế bù

| Điểm nghẽn | App bù bằng |
|---|---|
| Working memory kém (nghĩ ra → 30s sau quên) | Voice capture 1 hơi thở (đã có) + `sourceTranscript` giữ nguyên văn |
| Object permanence (không hiện = không tồn tại) | Menu bar 1 task + resurface đúng lúc (`afterDate`, auto-unblock) |
| Time blindness | `estimateMinutes` vs elapsed trong focus session; cảnh báo lệch |
| Initiation paralysis | Chỉ hiện 1 task (nextTask); breakdown với bước đầu "dễ ngớ ngẩn" |
| Dopamine deficit | Micro-reward khi done; auto-advance liền mạch; evening sweep thu hoạch done sót |

## Bốn mục tiêu → automation cụ thể

### 1. NHỚ làm việc gì
- **Reminder engine thật** (constitution IV — CHƯA build, gap lớn nhất): schedule
  `UNUserNotificationCenter` theo policy leo thang mặc định (−1d/−1h/0) + `reminderOverride`.
- **Auto-unblock notify**: khi một task done, diff eligibility trước/sau → task nào
  vừa hết bị chặn (`.taskDone` thỏa) thì notify "X vừa sẵn sàng vì Y đã xong".
- **Resurface `afterDate`**: task snooze tự hiện lại đúng mốc (schedule mốc gần nhất,
  không polling).
- **Morning frog** (UI đã có): ritual đầu ngày chọn con ếch — wire chặt với engine.

### 2. TẬP TRUNG làm việc gì
- **Single task menu bar + nextTask()** = automation của câu hỏi "giờ làm gì?" (core bet, đã có).
- **Estimate vs elapsed** trong FocusOverlay: "25/30 phút"; lệch nhiều (45/30) → hỏi nhẹ
  "chia nhỏ / dời deadline / nghỉ 5 phút?".
- **Breakdown thật** (hiện là stub sample cứng): task to → bước 5–15 phút, bước ĐẦU TIÊN
  phải không tốn ý chí ("mở file lên"). Các bước = task con chain `.taskDone` → engine
  tự dắt từng bước.
- **Quick-win mode** (backlog v2): `nextTask(availableMinutes:)` — "còn 15 phút → task 10 phút".

### 3. KHÔNG BỎ LỠ công việc nào
- **Stale task triage** (weekly, ~2 phút): task `.todo` quá N ngày không đụng → hỏi theo đợt
  từng task: "vẫn làm / chia nhỏ / dời / bỏ luôn". Không đỏ chói, không badge.
- **Overdue → auto-đề nghị reschedule**: qua deadline → notification hỏi "dời tối nay /
  mai / cuối tuần?" — một chạm task sống lại.
- **`.external` quá 3 ngày** → nhắc nhẹ "chờ X — đã có chưa? nhắc họ không?" (loại task
  dễ rơi hố đen nhất vì không có deadline riêng).

### 4. COMPLETE nhanh
- **Notification action buttons**: [Xong] [Snooze 10p] [Mai làm] ngay trên notification —
  done không cần mở app.
- **Voice done** (ưu tiên cao — cùng modality với capture): "xong cái báo cáo rồi" →
  fuzzy match title → tick + auto-advance. Câu ghép: "xong A, tiếp theo gì?".
  Cũng dùng clear `.external`: "anh Nam gửi file rồi".
- **Auto-advance liền mạch**: done → task kế hiện NGAY (khoảng trống quyết định là nơi
  ADHD lạc trôi). Engine đã hỗ trợ, cần wire app layer.
- **Evening sweep** (đối xứng morning frog): cuối ngày đọc task hôm nay, hỏi từng cái
  "xong chưa?" trả lời bằng giọng → tick hàng loạt. Thu hoạch các task đã làm ngoài đời
  nhưng chưa bao giờ được tick.
- **Micro-reward**: hiệu ứng done + đếm "ếch đã ăn tuần này". Streak KHÔNG trừng phạt
  (gãy không mất gì, chỉ đếm chiều dương).

## Breakdown & "đổi gió" — thiết kế cho cơn chán giữa task dài (bổ sung 2026-07-15)

Vấn đề thật (lời anh Khôi): task dài gây chán → muốn nhảy sang task mới. Phân tích:
task dài = sa mạc dopamine (không có sự kiện hoàn thành nào suốt nhiều giờ), và "chán"
thường thực chất là "kẹt" (bước kế tiếp mơ hồ). Cấm đổi task (ý chí) thất bại; đổi tự do
(mở board chọn) cũng thất bại. Giải pháp 2 nửa:

**Nửa 1 — Breakdown (CÓ, rất cần):** task dài → bước 5–15 phút chain `.taskDone`,
`parentId` trỏ về mẹ. Mỗi bước = 1 nhát dopamine + 1 "cái mới" hợp pháp; bước đủ ngắn
để xong trước khi cơn chán kịp tới; bước cụ thể xóa mơ hồ. Bước cuối done → auto-complete mẹ.

**Nửa 2 — Đổi task CÓ CẤU TRÚC (không dập cơn thèm đổi, đóng khung nó):**
- **"Đổi gió"**: lệnh giọng nói/nút → app đưa đúng MỘT lựa chọn thay thế (nextTask trên
  snapshot đã loại task hiện tại — không cần sửa engine). Task cũ giữ chỗ, không tội lỗi.
  KHÔNG bao giờ mở board cho tự chọn.
- **Timebox "10 phút thôi"**: cam kết 10 phút với task ngán (countdown đã có) → hết box
  được chọn tiếp/đổi miễn tội lỗi. Đa số đã vào guồng sẽ tự làm tiếp.
- **Re-entry rẻ**: quay lại task cũ → hiện ngay đang ở bước mấy + `sourceTranscript` +
  ghi chú dở. Chi phí quay lại ~0 thì switching hết nguy hiểm.
- **Trigger tự nhiên của breakdown**: task bị "đổi gió" bỏ đi ≥3 lần → app đề nghị
  "task này khó nhằn — chia nhỏ nhé?". Cơn chán lặp lại tự kích hoạt breakdown.

## "Đã làm được" — done-history theo phiên/ngày/tuần/tháng (bổ sung 2026-07-15)

Nên làm — với ADHD gần như bắt buộc: working memory kém khiến việc đã xong *bốc hơi khỏi
trí nhớ* → cuối ngày cảm giác "hôm nay tôi vô dụng" dù đã làm 8 việc → shame → bỏ app.
Accomplishment view biến tiến độ vô hình thành dopamine nhìn thấy được.

- **Khung thời gian**: phiên focus ("phiên này xong 3 bước") / hôm nay / tuần này / tháng
  (ritual nhìn lại). "This hour" gộp vào khung phiên — theo phiên tự nhiên hơn theo giờ đồng hồ.
- **Nguồn dữ liệu**: completion log (xem task-model doc) — KHÔNG đọc `completedAt` trên task
  vì recurrence reset-in-place xóa dấu vết.
- **Tie-in**: evening sweep kết thúc bằng "hôm nay anh xong 6 việc: …"; morning frog mở đầu
  bằng chiến tích hôm qua; streak/micro-reward đọc từ log.
- **Guardrail chống shame**: chỉ khung khẳng định (positive-only). KHÔNG biểu đồ so sánh
  ngày này/ngày kia, KHÔNG tô đỏ ngày trống, KHÔNG "bạn làm ít hơn tuần trước". Ngày 0 task
  đơn giản là không nhấn mạnh. Đây là bảng CHIẾN TÍCH, không phải dashboard năng suất.
- **Task mẹ vs subtask — hiển thị cuộn theo cấp (chốt 2026-07-15)**: không show phẳng cả
  hai (đếm trùng, thành tích giả), không chỉ show mẹ (ngày cày 5/7 bước mà màn hình trống
  → "vô dụng" — bẫy shame). Quy tắc:
  - *Phiên/hôm nay* (chi tiết): việc lẻ 1 dòng ✓; bước con gộp nhóm dưới tên mẹ
    "Báo cáo quý — ✓ 3/7 bước (…)". Mẹ chưa xong vẫn hiện — tiến độ dở dang PHẢI nhìn thấy.
    Xong bước cuối trong ngày → mẹ auto-done → gộp thành MỘT dòng "✓ (hoàn thành cả 7 bước)".
  - *Tuần/tháng* (cuộn lên): chỉ việc lẻ + mẹ đã hoàn thành, số bước là chú thích nhỏ;
    mẹ còn dở hiện dạng tiến độ "5/7", không tính vào số việc xong.
  - *Đếm 2 đơn vị, không cộng lẫn*: "việc" = task lẻ + mẹ hoàn thành; "bước" = subtask →
    "Hôm nay: 3 việc · 9 bước". Đếm ếch chỉ đếm VIỆC (giữ trọng lượng).
  - Completion log ghi kèm `parentId` (snapshot lúc done) để gộp nhóm không phụ thuộc
    mẹ còn tồn tại.

## Gamification — có, nhưng liều thấp: "juice, không phải game" (phân tích 2026-07-15)

Với ADHD gamification là dao hai lưỡi: hợp não nhất (thưởng tức thì bù dopamine deficit)
nhưng cũng giết app nhanh nhất nếu sai kiểu. 3 cách chết: (1) **nhờn thưởng** — não ADHD
habituate với điểm/badge/level trong ~2 tuần, hết phê là chán lây cả app; (2) **cơ chế
phạt** — gãy streak/mất máu kiểu Habitica = shame spiral, ngày gãy streak dài chính là
ngày xóa app; (3) **Goodhart** — có điểm là có farm điểm (thêm task vặt, né task to),
thước đo thành mục tiêu.

**ĐỊNH VỊ CHỐT (anh Khôi, 2026-07-15): app cho NGƯỜI CHUYÊN NGHIỆP — điềm tĩnh, không
trẻ con; vẫn motivate nhưng động lực đến từ cảm giác momentum, không phải hoạt hình.**
Cơ chế giữ nguyên, lớp trình bày theo chuẩn "premium, restrained":
- Thẩm mỹ chuẩn: Things 3 / Linear / Apple Fitness — hiệu ứng done đã tay nhưng tinh gọn
  (checkmark sắc, âm trầm ngắn, particle tinh tế); KHÔNG confetti lòe loẹt, KHÔNG mascot
  nhảy múa.
- Giọng chữ điềm tĩnh, tự tin ngầm: "6 việc hoàn thành. Ngày gọn gàng." — không
  "Bạn thật tuyệt vời! 🎉".
- Ếch giữ ở tầng KHÁI NIỆM (ritual "eat the frog" — phương pháp nghiêm túc), bỏ tầng
  hoạt hình (không táp mồi/ao sen) — biểu tượng tối giản.
- Reframe ngôn ngữ nghề nghiệp: streak → "chuỗi ngày đều đặn"; đếm ếch → "việc quan trọng
  đã xử tuần này"; accomplishment view → "Daily wins / Weekly review" (ritual GTD);
  unlock thẩm mỹ → "milestone mở theme/soundscape", trình bày kín đáo như premium tự mở.

Ba bậc thiết kế:
- **Bậc 1 — Juice** (= mục micro-reward, chắc chắn làm): hiệu ứng done thỏa mãn kiểu
  restrained, đếm việc quan trọng, streak chỉ đếm chiều dương.
- **Bậc 2 — Juice + bất ngờ + milestone (CHỐT LÀM, skin chuyên nghiệp)**:
  - *Variable reward*: thỉnh thoảng (ngẫu nhiên) một lần done có hiệu ứng tinh tế hơn
    hẳn — lịch thưởng biến thiên kháng nhờn tốt nhất; thể hiện bằng ĐỘ TINH TẾ,
    không phải pháo hoa to nhỏ.
  - *Milestone thẩm mỹ thay vì điểm*: tích lũy hoàn thành → mở ambient sound/theme mới.
    Phần thưởng là sự dễ chịu, thưởng phẳng không bóp méo chọn task (engine vẫn chọn).
  - Nguyên tắc sắt: thưởng khoảnh khắc hành động, không tích số so sánh được;
    KHÔNG BAO GIỜ phạt; không popup chen giữa flow capture/focus.
- **Bậc 3 — Full game (XP/level/avatar/quest/tiền tệ): KHÔNG làm** — thêm hệ thống phải
  quản lý (vi phạm "mỗi automation xóa một quyết định"), nhờn nhanh, mời farm điểm,
  phình UI ngược với glance-and-dismiss, và trẻ con so với định vị professional.

## Phương pháp làm việc phổ biến — tích hợp CƠ CHẾ, không tích hợp THƯƠNG HIỆU (2026-07-15)

Không làm menu "chọn phương pháp" (thêm hệ thống phải quản lý). Nướng lợi ích vào flow
mặc định. Volar đã ngầm chứa: eat-the-frog (morning ritual), GTD capture (voice),
GTD weekly review (stale triage + chiến tích tuần), Eisenhower (engine ordering =
deadline urgency × priority, máy kẻ ma trận hộ), timeboxing ("10 phút thôi").

**Pomodoro — ADHD-adapted: "Pomodoro để vào, Flowtime để ở lại" (chốt hướng):**
- Focus session mặc định 25 phút (chỉnh được) — liều khởi động chuẩn, phá initiation paralysis.
- Hết giờ → tín hiệu NHẸ không chặn ("nghỉ 5' hay tiếp?"), mặc định TIẾP TỤC, không trả lời
  thì tự nối dài — KHÔNG chặt đứt hyperfocus (flow của ADHD hiếm và quý, re-entry đắt;
  chuông nghỉ cứng của Pomodoro nguyên bản sinh cho não thường).
- Chống hyperfocus tự hại: session liên tục >~90 phút → nhắc nghỉ dứt khoát hơn một lần.

**Quy tắc 2 phút (GTD):** task `estimateMinutes` ≤ ~5 → lúc rảnh gợi ý "xử luôn cho gọn?"
(khớp quick-win mode).

**Không làm:** menu phương pháp, Eisenhower matrix UI, body doubling/social,
calendar time-blocking (v2 — đọc calendar biết khung trống sẽ nuôi quick-win mode).

## Chế độ orchestrator — làm việc song song với AI agents (2026-07-15)

Thực tế mới (lời anh Khôi): prompt task 1 cho AI → rảnh → prompt task 2, 3; con người là
người ĐIỀU PHỐI nhiều AI song song, không phải người thực thi tuần tự. "Một lúc một task"
kiểu cũ lỗi thời với pattern này — nhưng song song hóa không miễn phí với ADHD: nó đổi
vấn đề từ "không tập trung nổi" thành "N VÒNG LẶP MỞ trong working memory" → quên loop,
kết quả AI nằm mốc, agent treo ở câu clarify không ai trả lời. **Prompted ≠ done.**

Task tách 2 loại: **ủy thác** (chạm vào ở khoảnh khắc: prompt → chờ → review → done)
và **sâu** (cần não liên tục). Volar đổi vai: từ "gác cổng tập trung" → **đài kiểm soát
không lưu**: (1) không loop nào bị quên; (2) lấp khoảng chờ bằng "giờ làm gì?" (khoảng
2-5 phút chờ AI là nơi ADHD lạc trôi); (3) kỷ luật nghiệm thu — done = review xong,
không phải prompt xong; (4) capture ý tưởng giữa lúc chờ.

**Nguyên tắc KHÔNG BẮT TƯỜNG THUẬT switch**: app không quan tâm mắt user ở cửa sổ nào,
chỉ quan tâm trạng thái vòng lặp. 3 khoảnh khắc, mỗi cái 1 câu/1 phím:
- "Giao cho Claude rồi" → `.external("chờ AI làm X", satisfied: false)` (model có sẵn!)
  → task rời menu bar, task kế trồi lên. Switch là hệ quả ngầm của giao việc.
- "Kết quả về rồi" → satisfied → task trồi lại dạng CẦN REVIEW.
- "Xong" → done. Giữa các mốc: nhảy cửa sổ tùy thích, không khai báo.

Cơ chế đỡ lưng:
- **Hẹn nghiệm thu tự động**: giao là có timer, mặc định resurface sau N phút (nói được
  "check sau 10 phút"). Chờ-AI nhắc theo PHÚT (khác chờ-người nhắc theo ngày).
- **WIP guardrail**: menu bar "⏳ 3 đang chờ AI"; vượt ~3-4 loop mở → nhắc khẽ "nghiệm thu
  bớt trước khi giao thêm?" — cái đắt là review (nạp lại context), không phải prompt.
- Engine có thể ưu tiên review-sẵn-sàng lên trước (đóng loop = dopamine + mở round mới).

Model v1 gần như không sửa (`.external` + timer + eligibility gánh hết); việc phải làm là
flow giao/nhận 1 chạm + bộ đếm in-flight. **V2 exploration**: tự phát hiện AI xong việc
(lắng nghe notification Claude Code/terminal trên macOS → tự flip satisfied) → khỏi cần
nói cả "kết quả về rồi".

**Chống drift-nagging (2026-07-15)** — kịch bản: AI có kết quả, user đã review ngoài đời
nhưng không báo app → app đi nhắc chuyện đã xong = noise → user học cách lờ → chết app.
Nguyên tắc: app là MÔ HÌNH của thực tế, mô hình luôn trễ; mục tiêu là ĐỐI CHIẾU RẺ,
không phải sync hoàn hảo — không bao giờ phạt user vì app bị cũ. 4 tầng:
1. Recheck chờ-AI là **ambient**: lặng lẽ trồi lại trong next-up trên menu bar; KHÔNG
   push notification/popup/âm thanh (chỉ deadline thật được quyền làm phiền).
2. **Backoff, không leo thang**: resurface 10' → không phản hồi → 30' → gộp vào đợt.
   Im lặng = "đừng hỏi nữa", không phải "hỏi to hơn".
3. **Đối chiếu theo đợt tại điểm chạm tự nhiên** (mở popover / hỏi "giờ làm gì" /
   evening sweep): "3 task giao AI lâu rồi — cái nào xong tick luôn" — 1 tương tác dọn
   nhiều trạng thái cũ (insight GTD: tin hệ thống nhờ review định kỳ rẻ).
4. **Trả lời rẻ hơn lờ đi**: card resurface có 3 nút 1 chạm [Xong rồi][Vẫn chờ][Check sau
   30'] — "Vẫn chờ" tự lùi timer. Tầng cuối: auto-detect v2 xóa phần lớn drift.

**Auto-detect — thiết kế privacy (chốt 2026-07-15): CHỈ cooperative push, KHÔNG đọc lén.**
Các đường bị TỪ CHỐI vì app sẽ có năng lực đọc data phiên làm việc (vi phạm constitution
Principle I, phá positioning privacy-first, prompt quyền đáng sợ giết conversion):
đọc notification DB app khác (cần Full Disk Access — thấy cả tin nhắn/OTP), Accessibility
đọc nội dung cửa sổ app khác (Volar có quyền AX cho hotkey rồi — dùng nó đọc nội dung là
phản bội niềm tin + rủi ro App Store review), ScreenCaptureKit. Theo dõi process (`claude`
CLI exit) vô hại nhưng vô dụng (không biết task nào).
Đường CHỌN: Volar đăng ký **URL scheme `volar://`** (Info.plist, không quyền mới);
công cụ AI chủ động báo: `open "volar://ai-done?cwd=$PWD"`. Tính chất: một chiều
đi VÀO, payload tối thiểu (không nội dung phiên làm việc), opt-in hoàn toàn (không cài
hook → rơi về timer + batch reconcile). Threat: URL scheme app local nào cũng gọi được →
giả tín hiệu chỉ làm task trồi lên sớm để review (Volar KHÔNG auto-mark-done theo tín
hiệu, chỉ chuyển "cần review") — chấp nhận được. KHÔNG mở local HTTP server (web page
trong browser bắn request tới localhost được; URL scheme không có cổng lắng nghe).

**Setup 1 nút "Kết nối Claude Code" (chốt UX 2026-07-15)** — chuẩn cho MỌI tích hợp:
một nút, có preview, có chạy thử, có gỡ. Flow:
1. Tự phát hiện `~/.claude/` tồn tại → Settings mới hiện "[Kết nối]" (không có thì ẩn).
2. Bấm → PREVIEW entry JSON sẽ thêm (sửa config công cụ khác phải minh bạch, không lén).
3. Ghi an toàn: backup `settings.json` → parse → MERGE append vào `hooks.Stop`
   (tuyệt đối không ghi đè hook sẵn có — phá config dev của user là tội nặng nhất) →
   validate → ghi. Entry: `{"type":"command","command":"open \"volar://ai-done?cwd=$PWD\""}`.
4. Nút [Chạy thử] → bắn tín hiệu → "✓ Đã nhận" (tin ngay, không chờ lần dùng thật).
5. Nút [Gỡ kết nối] → xóa đúng entry có marker `volar://`, không đụng gì khác.
Mapping task (hook không mang tên task Volar): đúng 1 task đang chờ-AI (case phổ biến) →
map thẳng sang "cần review"; nhiều task → dùng `cwd` match project folder; không chắc →
ambient card "1 agent vừa xong — [A] [B]?" một chạm. Không bao giờ auto-done.
Ràng buộc App Sandbox (MAS): không tự ghi `~/.claude/` được → lần đầu hiện NSOpenPanel
trỏ sẵn `~/.claude`, user bấm Open 1 cái = security-scoped bookmark vĩnh viễn (tổng
2 click, 0 dòng lệnh; bản ngoài store = 1 click). Fallback: nút "Copy hook config" dán
tay — đường lùi, không phải đường chính.

**Voice-reply vào terminal — "gõ hộ" prompt tiếp theo (chốt hướng 2026-07-15, BIG WIN):**
đóng trọn vòng orchestrator bằng giọng nói: agent xong → Volar báo → hotkey → nói →
prompt chạy vào đúng terminal → agent chạy tiếp, không cần chạm terminal.
- **Đường chọn: AppleScript `write text` nhắm theo tty.** Stop-hook chạy trong session
  nên lấy được tty → gửi kèm `volar://ai-done?cwd=...&tty=...` → Volar hỏi iTerm2/Terminal
  session nào có tty đó → ghi chữ vào ĐÚNG session (kể cả đang bị che). Không race focus.
  Quyền: Apple Events automation — prompt MỘT LẦN THEO TỪNG APP ĐÍCH ("Volar muốn điều
  khiển iTerm2") — hẹp và dễ hiểu hơn Accessibility toàn cục. **CHỈ GHI, không bao giờ
  ĐỌC nội dung terminal** (một chiều đi ra, giữ nguyên cam kết privacy).
- **Preview BẮT BUỘC trước khi gửi** (constitution II): hiện transcript + đích đến
  ("→ iTerm2, dự án volar") → user gật mới gõ. Cũng là chốt an toàn nếu terminal đang
  đứng ở prompt y/n của lệnh khác.
- Fallback terminal không AppleScript (Warp/Ghostty/VS Code): kích hoạt đúng cửa sổ +
  clipboard + hiện "⌘V để gửi" (không bao giờ nhầm chỗ); CGEvent keystroke toàn cục chỉ
  là phương án cuối vì race focus (gõ nhầm app = thảm họa).
- **KHÔNG làm** đường `claude --resume <session> -p` ngầm: fork lịch sử hội thoại
  (terminal không thấy lượt mới), biến Volar thành agent client (phình scope), sandbox
  MAS giết process con. Terminal của user là single source of truth — Volar chỉ gõ hộ.
- Caveat phân phối: Apple Events entitlement + Accessibility đều khó qua MAS review →
  thêm lý do cân nhắc bản Developer ID ngoài store cho power users; bản MAS degrade
  về clipboard+⌘V.
- Flow: agent xong → task "cần review" → hotkey → nói ("viết thêm test rồi chạy lại")
  → preview → gửi → task quay lại "chờ AI" + timer mới.

## Chuỗi phụ thuộc / thứ tự ưu tiên đề xuất

1. Refactor task model v1 (`docs/task-model-v1.md`) — nền của tất cả.
2. NLParser resolve `Date` thật — hiện voice task có `deadline: nil` → trục
   deadline→urgency→reminder chết từ gốc; không sửa thì mọi thứ sau vô nghĩa.
3. Reminder engine + notification actions — trúng 3 đích (nhớ / không bỏ lỡ / complete nhanh).
4. Voice done + auto-advance wiring — đóng vòng đời task bằng giọng nói.
5. Ritual layer: evening sweep, stale triage, overdue reschedule, breakdown thật.
6. Polish: micro-reward, estimate-vs-elapsed.
