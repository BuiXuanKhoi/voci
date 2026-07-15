# Voci — Vision v2: Voice-first Workflow Command Center (2026-07-15)

Định vị đã dịch chuyển (chốt trong thảo luận 2026-07-15): không còn là "voice to-do app"
mà là **trung tâm chỉ huy công việc bằng giọng nói cho kỷ nguyên AI** — người dùng điều
phối việc của mình VÀ việc đã giao cho AI agents, app đóng vai executive function bên ngoài.

## Moat hiện có (4 trụ)

1. **Voice là interface chính** — capture/done/switch/reply-to-agent đều bằng một hơi thở.
2. **Engine quyết định thay vì list** — `nextTask()` trả lời "giờ làm gì", không bắt user
   nhìn 30 dòng tự chọn.
3. **Orchestrator cho AI agents** — theo dõi vòng lặp giao-chờ-review, voice-reply vào terminal.
4. **ADHD-grade automation, skin chuyên nghiệp** — ritual, chống shame, reminder leo thang.

So sánh: Todoist/Things = list tĩnh không engine; Motion = auto-schedule nặng calendar,
không voice/ADHD; Raycast = command không phải workflow. Không ai đứng ở giao điểm 4 trụ này.

## Ứng viên tính năng mới (ĐỀ XUẤT — chưa duyệt, xếp theo tier)

### Tier 1 — đòn bẩy cao, khớp cả 4 trụ

1. **Calendar awareness (EventKit, read-only)** — đọc lịch để: biết khung giờ trống thật
   (nuôi quick-win mode), "deadline 5pm nhưng anh họp 2-5pm → deadline hiệu dụng là 2pm",
   **transition warning** 10' trước meeting (time blindness → trễ họp là bệnh ADHD kinh
   điển). On-device, một quyền EventKit. Dân chuyên nghiệp sống trong calendar — thiếu nó
   mọi lời khuyên thời gian của app đều ngây thơ.
2. **AI breakdown + parser thông minh qua Apple Foundation Models (macOS 26, on-device)**
   — dùng LLM on-device MIỄN PHÍ + private của Apple để: (a) breakdown thật (thay stub) —
   đề xuất các bước 5-15', user sửa bằng giọng; (b) nâng NLParser hiểu câu phức
   (đa task, conditions, "sau khi A xong thì..."). Khớp freemium: on-device free,
   cloud (Groq/Claude) chính xác hơn cho paid. Đây là mảnh AI-native còn thiếu giữa
   speech (đã có) và engine (đã có).
3. **Voice query — hỏi board bằng giọng**: "tuần này tôi có gì?", "cái nào đang chờ AI?",
   "task nào kẹt lâu nhất?" → app trả lời (đọc + hiện). Biến board thành hội thoại,
   không ai trong thị trường có. Cần intent parser (đi cùng #2).
4. **Context resume note — "save game" cho não** (ADHD tax killer, RẺ vì hạ tầng voice có
   sẵn): khi rời task / hết ngày, app hỏi một câu "đang dở gì, định làm gì tiếp?" → voice
   note gắn vào task → khi quay lại, hiện/đọc lại. Sáng hôm sau: "hôm qua anh dừng ở X,
   định làm Y tiếp". Chi phí re-entry → ~0, khớp cơ chế "đổi gió" đã chốt.
5. **Meeting/voice-memo ingestion → action items**: thu/nhận file audio cuộc họp →
   Whisper transcribe (stack có sẵn) → extract action items → confirm cards hàng loạt.
   Capture-at-scale cho dân chuyên nghiệp; on-device = không lo privacy nội dung họp.

### Tier 2 — đáng làm, sau Tier 1

6. **Overwhelm/panic mode**: nút (hoặc nói "quá tải") → ẩn TẤT CẢ, hiện đúng 1 việc ≤5',
   nhịp thở chậm lại. Phục hồi ADHD shutdown — rẻ, rất đúng đối tượng.
7. **Capture từ mọi nơi (Services/share extension)**: bôi đen text bất kỳ (email, Slack)
   → hotkey → thành task kèm nguồn.
8. **Export/backup (JSON/Markdown) + search toàn văn** (gồm cả sourceTranscript) —
   data ownership, điều kiện cần để dân chuyên nghiệp tin app.
9. **AI weekly narrative**: thuật lại tuần bằng văn ("tuần này 23 việc, chủ yếu dự án X,
   con ếch to nhất là Y") — nuôi Weekly review + động lực, positive-only.

### Tier 3 — lớn, để v3 (anh Khôi xác nhận để dành 2026-07-15)

10. **iPhone/Watch companion + CloudKit sync + nhắc đa thiết bị**: capture khi di chuyển
    (nơi ý tưởng nảy nhiều nhất), reminder theo tới mọi thiết bị, menu bar Mac là command
    center. Scope lớn (sync, app mới).
11. **Teamwork**: collect task từ team (giao việc cho nhau, nhận việc từ kênh chung) và
    **tự động resolve** khi bên kia xong — mở rộng orchestrator từ "điều phối AI" sang
    "điều phối người + AI". Ràng buộc cho v2: giữ task identity ổn định + completion log
    dạng event để sau này sync/team không phải đập model.

### Không làm (giữ kỷ luật)

- Kanban/board view phức tạp, project hierarchy sâu — quay lại thành Jira mini, phản
  engine-decides.
- Chat AI tổng quát trong app — Voci điều phối AI, không thay thế AI.
- Social/body-doubling, medication tracking — ngoài scope.

## Freemium v2 (chốt cấu trúc 2026-07-15 — giá bán quyết sau)

**Nguyên tắc: TÍNH NĂNG miễn phí hết — chỉ COMPUTE cao cấp (cloud) là trả tiền.**
Không paywall feature (tránh phân biệt); không account; gate paid = StoreKit JWS,
quota free = DeviceCheck (không cần đăng nhập).

| Năng lực | Free | Pro (trả phí) |
|---|---|---|
| Toàn bộ tính năng app: task model, reminder, orchestrator + Claude Code connect, focus/breakdown/đổi gió/panic, rituals, accomplishment, calendar, capture, voice query, export/search | ✅ đầy đủ | ✅ đầy đủ (không khác) |
| Speech-to-text | WhisperKit on-device **không giới hạn** (Apple Silicon; máy Intel fallback Apple Speech) | **Groq whisper-large-v3**: chính xác nhất, code-switch Việt-Anh, auto-detect, nhanh |
| AI parse câu nói → task + AI breakdown | FM on-device không giới hạn (macOS 26) · **cloud 50 lần/ngày/thiết bị** (opt-in, DeviceCheck) · heuristic không giới hạn | Cloud **không giới hạn** (fair-use) |
| Meeting ingestion (P3) | Whisper on-device (chậm hơn, vẫn unlimited) | Groq (nhanh, chính xác, file dài) |
| Weekly narrative | FM on-device / template | Cloud LLM khi máy không có FM |
| Trần 10 task/lần nói | áp dụng | áp dụng (sanity UX, không phải để bán) |

### Tái cấu trúc conversion (anh Khôi duyệt 2026-07-15)

1. **Trial 7–14 ngày full Pro cho mọi user mới** (StoreKit intro offer) rồi tự rơi về
   free — loss aversion là đòn bẩy chính, không phải cắt free.
2. **Quota AI cloud free hạ còn ~20–25/ngày + HIỆN đếm** ("còn 8 lượt AI hôm nay") —
   trần nhìn thấy được là quảng cáo Pro tự nhiên; giá trị chỉnh server-side.
3. **Chuyển sang Pro** (loại scale & polish, không đụng vòng lõi): meeting ingestion
   (Pro-only hẳn), AI weekly narrative, lịch sử accomplishment >30 ngày + view tháng
   (export vẫn FREE — không bắt cóc data), theme/soundscape pack làm sẵn.
4. **Giữ free tuyệt đối**: vòng lõi capture/remind/done, orchestrator + Claude Code
   connect, voice query, calendar, rituals, WhisperKit unlimited, export, và TOÀN BỘ
   juice/micro-reward (cơ chế thưởng free cho cả 2 tier — máy tạo thói quen; chỉ bán
   thêm content thẩm mỹ, milestone earned vẫn free).

### Mô hình chi phí & giá bán (phân tích 2026-07-15; giá nhà cung cấp verify 2026-07)

**Đơn giá nguồn**: Groq whisper-large-v3 $0.111/h, turbo $0.04/h (min 10s/request);
Gemini 3.1 Flash-Lite $0.25/$1.50 per 1M in/out (2.5 Flash-Lite $0.10/$0.40);
Supabase $0 → Pro $25/mo khi cần; Apple Small Business Program 15%; DeviceCheck $0.

**Chi phí biến đổi / user / tháng** (ước lượng, parse ~700 token in + 250 out):

| Hạng mục | Free (điển hình → trần) | Pro điển hình | Pro nặng (trần fair-use) |
|---|---|---|---|
| Speech capture (15–30 lượt/ngày, min 10s) | $0 (on-device) | ~$0.15–0.3 (large-v3) | ~$0.3 |
| Meeting ingestion (Pro-only; **dùng turbo** cho file dài) | — | 4h ≈ $0.16 | 20h ≈ $0.80 |
| Cloud parse (free ≤25/ngày; Pro ~30/ngày) | $0.05 → $0.4 max | ~$0.5 | ~$0.7 |
| **Tổng biến đổi** | **≈$0.05–0.4** | **≈$0.8–1.0** | **≈$1.8** |

Cố định: Apple dev $99/năm (~$8/mo) + Supabase $0→$25/mo. Trial ≈ $0.3–0.5/người dùng thử.
Đòn giảm chi phí có sẵn: turbo cho file dài (rẻ 2.8×), 2.5 Flash-Lite cho free tier,
FM on-device gánh miễn phí trên macOS 26, quota chỉnh server-side nếu free-cost phình.

**Giá CHỐT (anh Khôi duyệt 2026-07-15) + thang nâng giá theo mốc:**

- Launch (Release A): **$4.99/mo · $39.99/yr · VN 99.000đ/799.000đ · trial 14 ngày full Pro.**
- Release B ships (ingestion+calendar+accomplishment): cân nhắc nâng user MỚI lên $5.99/$49.99.
- v3 ships (iPhone/Watch + sync): cân nhắc $7.99/$59.99+ — mốc nâng mạnh nhất.
- Nguyên tắc: chỉ nâng khi giá trị thật tăng; user cũ grandfather giá cũ; mỗi đợt nâng
  là một chiến dịch "mua trước khi tăng". Đối chiếu thị trường: Tiimo ~$4.5/mo, Todoist $5,
  Motion $19 (suite đa nền tảng) → $4.99 đúng phân khúc menu-bar app một nền tảng.

Chi tiết margin của bộ số đã chốt:

- **Pro monthly $4.99** → net sau Apple 15% = $4.24 → margin điển hình ~$3.3/user (**~78%**),
  user nặng nhất vẫn lời ~$2.4 (~57%).
- **Pro yearly $39.99** (= $3.33/mo, giảm 33% — đẩy annual để khóa churn) → net $2.83/mo →
  margin điển hình ~$1.9/user/tháng (**~67%**).
- **Không bán lifetime lúc launch** (chi phí cloud là recurring; xét sau khi có số liệu,
  nếu bán thì ≥$79.99 + fair-use).
- **Storefront VN**: đặt giá riêng ~99.000đ/tháng, 799.000đ/năm (Apple cho custom theo
  storefront) — tương đương ~$3.9/$31 nhưng khớp sức mua; vẫn margin >60%.
- Break-even hạ tầng: ~8 monthly hoặc ~12 annual subscribers. Sanity ở 1.000 MAU free +
  5% conversion (50 Pro): doanh thu net ≈ $175/mo, chi phí ≈ $85–150/mo → lời từ mốc
  ~1k user và margin nở theo scale (chi phí free user là số nhỏ, kiểm soát bằng quota).

Fair-use Pro (chống lạm dụng, không phải để bán): meeting ingestion soft-cap 20h/tháng,
parse soft-cap ~100/ngày — vượt thì hàng đợi chậm lại, không chặn.

## Nguyên tắc soi mọi tính năng mới (checklist)

1. Có xóa bớt một quyết định khỏi đầu user không? (nếu THÊM quyết định → loại)
2. Có chạy được bằng giọng nói một hơi thở không?
3. Có giữ nguyên cam kết on-device privacy không?
4. Người ADHD lúc tệ nhất (quá tải, xấu hổ, quên) có dùng nổi không?
5. Có nuôi vòng lặp capture → decide → focus → done → review không, hay là feature mồ côi?
