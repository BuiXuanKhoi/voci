# Volar — Vision v2: Trợ lý Executive Function cho não ADHD (2026-07-15 · định vị siết lại 2026-07-16)

Định vị đã dịch chuyển (chốt 2026-07-15, siết lại sau deep-research validate thị trường
2026-07-16): không còn là "voice to-do app", và KHÔNG dẫn đầu bằng "voice AI app" — mà là
**trợ lý điều hành (executive function) cho não ADHD trong kỷ nguyên AI**. Voice command
là INTERFACE (cách thao tác); engine-decides — "nói một câu → app quyết giùm bạn làm gì
tiếp" — mới là VALUE cốt lõi, thứ thật sự giữ chân user.

**Vì sao không dẫn đầu bằng "voice AI app"**: gọi tên như vậy, thị trường sẽ đọc Volar
thành một app voice-dictation (giọng → chữ) và so trực tiếp với Wispr Flow (định giá
~$2 tỷ) cùng 17+ app dictation khác trên macOS — Volar thua ngay từ khung so sánh, vì
phần speech-to-text chỉ là hạ tầng, không phải sản phẩm. Phải dẫn đầu bằng outcome cho
người ADHD, voice chỉ là cách làm.

**Khác biệt then chốt (đây mới là moat thật)**: Volar KHÁC hẳn nhóm voice-dictation
(Wispr Flow, Superwhisper, và 17+ app macOS khác: giọng → chữ, dừng ở đó) và KHÁC nhóm
list tĩnh visual-first (Tiimo — visual schedule, Todoist — checklist). Volar là
**giọng → hành động + engine quyết định**: không bắt user gõ, không bắt user nhìn 30
dòng rồi tự chọn việc tiếp theo. Cả hai nhóm đối thủ trên đều thiếu vế "engine quyết"
này — đó là khoảng trống Volar đứng vào, và là moat cần bảo vệ.

## Moat hiện có (4 trụ, tái framing sau deep-research 2026-07-16)

1. **Voice là interface chính** — capture/done/switch/reply-to-agent đều bằng một hơi thở.
2. **Engine quyết định thay vì list** — `nextTask()` trả lời "giờ làm gì", không bắt user
   nhìn 30 dòng tự chọn.
3. **Orchestrator cho AI agents — feature bổ trợ, KHÔNG phải trụ định vị.** Đã bị
   Sherlock một phần: Claude Code nay có voice dictation built-in miễn phí (dictate
   reply cho background session) + Agent View — dashboard theo dõi đa-agent, miễn phí
   trong Pro/Max; Conductor (macOS) miễn phí; Spokenly nối voice vào Claude Code qua
   MCP. "Voice reply cho AI agent" không còn là novel tính đến 2026. Kẽ hở còn lại
   (mỏng): chưa tool nào kết hợp voice + task-engine + executive-function framing
   trong một app; Agent View vẫn text-only. Nhưng audience dev trả tiền rất ít cho một
   GUI bọc quanh CLI miễn phí → giữ orchestration như feature cho power-user, KHÔNG
   dùng làm go-to-market chính.
4. **ADHD-grade automation, skin chuyên nghiệp** — ritual, chống shame, reminder leo thang.

So sánh & bằng chứng wedge: Todoist/Things = list tĩnh không engine; Motion = auto-schedule
nặng calendar, không voice/ADHD; Raycast = command không phải workflow. Wedge có bằng
chứng thị trường mạnh nhất là **ADHD-professional**: adults 18+ chiếm 55.9% doanh thu
app ADHD; user iOS đóng 68-69% doanh thu app toàn cầu → nhắm Apple-only là nhắm đúng
nhóm WTP (willingness-to-pay) cao. Đối thủ trực tiếp cần theo dõi sát: **Tiimo** (1M+
user, iPhone App of the Year 2025, có AI Co-Planner — nhưng KHÔNG voice-first, KHÔNG
engine-decides) và **Blabby AI** (2026, core sản phẩm = voice-to-task cho ADHD — nhưng
KHÔNG có engine-decides). Không ai đứng ở giao điểm đủ 4 trụ này, nhưng khoảng cách với
Tiimo/Blabby đang hẹp dần.

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
- Chat AI tổng quát trong app — Volar điều phối AI, không thay thế AI.
- Social/body-doubling, medication tracking — ngoài scope.

## Freemium v2 (chốt cấu trúc 2026-07-15 — giá bán quyết sau)

**Nguyên tắc: TÍNH NĂNG miễn phí hết — chỉ COMPUTE cao cấp (cloud) là trả tiền.**
Không paywall feature (tránh phân biệt); không account; gate paid = StoreKit JWS,
quota free = DeviceCheck (không cần đăng nhập).

| Năng lực | Free | Pro (trả phí) |
|---|---|---|
| Toàn bộ tính năng app: task model, reminder, orchestrator + Claude Code connect, focus/breakdown/đổi gió/panic, rituals, accomplishment, calendar, capture, voice query, export/search | ✅ đầy đủ | ✅ đầy đủ (không khác) |
| Speech-to-text | WhisperKit on-device **không giới hạn** (Apple Silicon; máy Intel fallback Apple Speech) | **Groq whisper-large-v3**: chính xác nhất, code-switch Việt-Anh, auto-detect, nhanh |
| AI parse câu nói → task + AI breakdown | FM on-device không giới hạn (macOS 26) · **cloud 12 lần/ngày/thiết bị** (chốt 2026-08-09, hạ từ 50 → 20 → 12 sau khi đo chi phí thật; opt-in, DeviceCheck) · heuristic không giới hạn | Cloud **không giới hạn** (fair-use) |
| Meeting ingestion (P3) | Whisper on-device (chậm hơn, vẫn unlimited) | Groq (nhanh, chính xác, file dài) |
| Weekly narrative | FM on-device / template | Cloud LLM khi máy không có FM |
| Trần 10 task/lần nói | áp dụng | áp dụng (sanity UX, không phải để bán) |

### Tái cấu trúc conversion (anh Khôi duyệt 2026-07-15)

1. **Trial 7–14 ngày full Pro cho mọi user mới** (StoreKit intro offer) rồi tự rơi về
   free — loss aversion là đòn bẩy chính, không phải cắt free.
2. **Quota AI cloud free — CHỐT 12/ngày** (2026-08-09, thay đề xuất ~20–25 ở đây và con số
   50 trong bảng trên; code default `DEFAULT_PARSE_LIMIT_FREE` đã hạ 20 → 12) **+ HIỆN đếm**
   ("còn 8 lượt AI hôm nay") — trần nhìn thấy được là quảng cáo Pro tự nhiên; giá trị chỉnh
   server-side qua `PARSE_LIMIT_FREE` không cần redeploy.
3. **Chuyển sang Pro** (loại scale & polish, không đụng vòng lõi): meeting ingestion
   (Pro-only hẳn), AI weekly narrative, lịch sử accomplishment >30 ngày + view tháng
   (export vẫn FREE — không bắt cóc data), theme/soundscape pack làm sẵn.
4. **Giữ free tuyệt đối**: vòng lõi capture/remind/done, orchestrator + Claude Code
   connect, voice query, calendar, rituals, WhisperKit unlimited, export, và TOÀN BỘ
   juice/micro-reward (cơ chế thưởng free cho cả 2 tier — máy tạo thói quen; chỉ bán
   thêm content thẩm mỹ, milestone earned vẫn free).
5. **Onboarding soft-paywall** (mới, chốt sau deep-research 2026-07-16): một màn giới
   thiệu Pro hiện TRƯỚC khi vào app lần đầu (không chặn cứng — chỉ show trial 14 ngày,
   user luôn bấm qua được để dùng free). Data 2025/26 (RevenueCat): freemium thuần
   convert median chỉ 2.1% (RPI $0.38) trong khi hard-paywall lên tới 10.7% (RPI $3.09)
   — nhóm thấy paywall ngay từ onboarding convert cao hơn hẳn nhóm không thấy. Volar vẫn
   giữ freemium (không khoá tính năng) nhưng học chiến thuật "cho thấy Pro sớm" của
   hard-paywall để nâng conversion mà không phá nguyên tắc free-feature.

### Mô hình chi phí & giá bán (phân tích 2026-07-15; giá nhà cung cấp verify 2026-07;
bộ giá & mục tiêu MRR cập nhật 2026-07-16 sau deep-research)

**Đơn giá nguồn**: Groq whisper-large-v3 $0.111/h, turbo $0.04/h (min 10s/request);
Gemini 3.1 Flash-Lite $0.25/$1.50 per 1M in/out (2.5 Flash-Lite $0.10/$0.40);
Supabase $0 → Pro $25/mo khi cần; Apple Small Business Program 15%; DeviceCheck $0.

**Chi phí biến đổi / user / tháng** (bảng ĐÃ SỬA 2026-08-09 — xem cảnh báo ngay dưới):

| Hạng mục | Free (điển hình → trần 12/ngày) | Pro điển hình | Pro nặng (fair-use) |
|---|---|---|---|
| Speech capture (15–30 lượt/ngày, min 10s) | $0 (on-device) | ~$0.15–0.3 (large-v3) | ~$0.3 |
| Meeting ingestion (Pro-only; **dùng turbo** cho file dài) | — | 4h ≈ $0.16 | 20h ≈ $0.80 |
| Cloud parse @ **$0.0016/call đo thật** (free ≤12/ngày; Pro ~30/ngày; nặng ~50/ngày) | $0.07 → **$0.58** | **~$1.44** | **~$2.40** |
| **Tổng biến đổi** | **≈$0.07–0.58** | **≈$1.75–1.9** | **≈$3.5** |

> ⚠️ **Bảng cũ sai 8,5× ở input token.** Nó giả định "parse ~700 token in + 250 out". Đo thật
> ngày 2026-08-09 bằng `usageMetadata` của Gemini trên `gemini-3.1-flash-lite`: **5.967 token
> in** + ~220 out = **$0.0016/call**, không phải $0.00055. Prompt đã phình qua ba đợt tính năng
> (`task_refs_v1`, `task_cues_v1`, khối date rules 8.2k ký tự) mà bảng này chưa cập nhật theo.
> Phân rã: systemInstruction 3.230 tok + date rules 2.400 + example theo `now` 235 + dữ liệu
> user chỉ 90 → **98,8% input token là chi phí cố định, lời user chỉ chiếm 1,2%**.
> (`responseSchema` 1.367 tok KHÔNG tính vào `promptTokenCount` nên không bill.)

Margin thật sau khi sửa (thay bộ số ở mục "Chi tiết margin" bên dưới):

- **Pro monthly $6.99** → net $5.94 − $1.75–1.9 = lời ~**$4.05–4.2 (~68–71%)**, không phải 80%+.
- **Pro yearly $49.99** → net $3.54/mo − $1.75–1.9 = lời ~**$1.65–1.8 (~47–51%)**, không phải
  ~70%. Đây là chỗ tụt mạnh nhất — annual đang được đẩy mạnh để khoá churn, cần biết margin
  thật của nó chỉ bằng ~2/3 kỳ vọng cũ.
- **Pro nặng** → lời ~**$2.44 (~41%)**, không phải ~70%. Vẫn dương.

Cố định: Apple dev $99/năm (~$8/mo) + Supabase $0→$25/mo. Trial ≈ $0.3–0.5/người dùng thử.
Đòn giảm chi phí có sẵn: turbo cho file dài (rẻ 2.8×), **2.5 Flash-Lite cho free tier**
($0.10/$0.40 → ~$0.00068/call, rẻ 2,4× — đây là đòn mạnh nhất còn chưa dùng, mạnh hơn hẳn việc
rút gọn prompt), FM on-device gánh miễn phí trên macOS 26, quota chỉnh server-side
(`PARSE_LIMIT_FREE`) nếu free-cost phình.

**Ngưỡng phải theo dõi sau launch**: ở conversion 2,5%, mỗi Pro gánh ~39 free user → ngân sách
hoà vốn ~$0.15/free/tháng ≈ **3,2 parse/ngày trung bình trên toàn free base**. Trần 12/ngày an
toàn miễn là trung bình thực tế nằm dưới mức đó; nếu vượt, xử lý bằng cách route free sang
2.5 Flash-Lite trước, hạ trần sau.

**Giá CHỐT (anh Khôi duyệt 2026-07-16, thay bộ giá 2026-07-15 sau deep-research) + thang
nâng giá theo mốc:**

- Launch (Release A): **$6.99/mo · $49.99/yr · VN 149.000đ/449.000đ · trial 14 ngày full Pro.**
- Release B ships (ingestion+calendar+accomplishment): cân nhắc nâng user MỚI lên $7.99/$59.99.
- v3 ships (iPhone/Watch + sync): cân nhắc $9.99+ — mốc nâng mạnh nhất.
- Nguyên tắc: chỉ nâng khi giá trị thật tăng; user cũ grandfather giá cũ; mỗi đợt nâng
  là một chiến dịch "mua trước khi tăng".
- **Lý do đổi giá** (data 2025/26): productivity app median $9.99/mo & $34.99/yr; voice
  tool median $8-15/mo; ADHD comparable — Tiimo ~$3-4.5/mo hiệu dụng, Llama Life $4/mo
  hoặc $30/năm. $4.99 cũ định giá thấp hơn hẳn dải này; data conversion cho thấy **giá
  cao hơn convert trial tốt hơn**, không tệ hơn. Annual $49.99 (~$4.17/mo, giảm ~40% so
  với 12× giá tháng) đẩy mạnh để khóa doanh thu trước khi churn ăn mòn: monthly
  retention sau 1 năm chỉ ~17%, annual Year-1 churn ~72% — thu tiền cả năm ngay từ đầu
  quan trọng hơn giá thấp. VN 449.000đ (~$18) khớp SEA yearly median ~$18, vẫn margin
  >60%.

Chi tiết margin của bộ số mới:

> ⚠️ **HAI GẠCH ĐẦU DÒNG NGAY DƯỚI ĐÃ LỖI THỜI** (2026-08-09) — chúng dựa trên chi phí biến đổi
> $0.8–1.0/tháng, tính từ giả định parse 700 token in đã được đo lại là sai 8,5×. Số margin
> ĐÚNG nằm ở mục "Margin thật sau khi sửa" phía trên. Giữ lại nguyên văn ở đây để thấy bộ số
> nào đã dùng cho quyết định giá 2026-07-16; **đừng trích dẫn hai dòng này nữa**.

- ~~**Pro monthly $6.99** → net sau Apple 15% ≈ $5.94 → chi phí biến đổi Pro điển hình
  ~$0.8-1.0/user/tháng (không đổi) → margin điển hình ~80%+ (~$5/user), user nặng nhất
  (trần fair-use, chi phí ~$1.8) vẫn lời ~$4.1 (~70%).~~ → thật: ~68–71% / ~41%.
- ~~**Pro yearly $49.99** (= $4.17/mo, giảm ~40% — đẩy annual để khóa churn) → net sau
  Apple 15% ≈ $42.49/năm ≈ $3.54/mo → margin điển hình ~70% (~$2.6/user/tháng).~~
  → thật: ~47–51% (~$1.65–1.8/user/tháng).
- **Không bán lifetime lúc launch** (chi phí cloud là recurring; xét sau khi có số liệu,
  nếu bán thì ≥$99.99 + fair-use).
- **Storefront VN**: đặt giá riêng 149.000đ/tháng, 449.000đ/năm (Apple cho custom theo
  storefront) — tương đương ~$6/$18, khớp SEA yearly median ~$18; vẫn margin >60%.
- Break-even hạ tầng: vẫn ~8-12 subscriber.

**Mục tiêu doanh thu & sanity check (điều chỉnh về mức thực tế 2026-07-16)**:

- Mục tiêu thực tế: **$300–800 MRR trong 12 tháng** (KHÔNG phải $500-2.000 — đó là
  top-decile, chỉ 17.3% app mới chạm $1K MRR trong 2 năm đầu).
- Giả định conversion nên plan cận thực **2-3%** (không phải 5% — 5% là 2.4× benchmark
  freemium median).
- Comparable: **Llama Life** (solo ADHD app) mất 4 năm mới đạt ~$4.25K MRR — bench nhắc
  kỳ vọng phải kiên nhẫn.
- Sanity: 1.000 MAU free × 2.5% conversion ≈ 25 Pro → doanh thu net khiêm tốn (dưới mục
  tiêu $300-800); cần vài nghìn MAU mới tới $500+ MRR.
- Đòn bẩy thắng/thua là **distribution cộng đồng ADHD + build-in-public + founder-as-user**,
  KHÔNG phải feature — feature chỉ giữ chân user đã vào, không tự kéo user tới.

Fair-use Pro (chống lạm dụng, không phải để bán): meeting ingestion soft-cap 20h/tháng,
parse soft-cap ~100/ngày — vượt thì hàng đợi chậm lại, không chặn.

## Nguyên tắc soi mọi tính năng mới (checklist)

1. Có xóa bớt một quyết định khỏi đầu user không? (nếu THÊM quyết định → loại)
2. Có chạy được bằng giọng nói một hơi thở không?
3. Có giữ nguyên cam kết on-device privacy không?
4. Người ADHD lúc tệ nhất (quá tải, xấu hổ, quên) có dùng nổi không?
5. Có nuôi vòng lặp capture → decide → focus → done → review không, hay là feature mồ côi?

## Rủi ro cạnh tranh & Sherlocking (validate 2026-07-16)

- **Dev wedge bị Sherlock nhanh nhất**: Claude Code đã có voice dictation built-in miễn
  phí (dictate reply cho background session) + Agent View — dashboard theo dõi đa-agent,
  miễn phí trong Pro/Max; OpenAI có Codex macOS app riêng; Conductor (macOS) miễn phí.
- **Voice-dictation wedge đã đóng**: Wispr Flow định giá ~$2 tỷ, 17+ app dictation khác
  trên macOS, on-device STT miễn phí đã bị commoditize hàng loạt → free WhisperKit tier
  của Volar là table-stakes, KHÔNG phải hook để thu hút user.
- **Rủi ro chí mạng cần theo dõi sát**:
  1. Anthropic/OpenAI mở rộng Agent View + voice sang workflow phi-dev (non-dev).
  2. Blabby AI hoặc Tiimo thêm voice + engine-decides vào sản phẩm của họ.
  3. Apple Sherlock voice-to-task ngay ở tầng hệ điều hành (macOS 27).
- Chi tiết đầy đủ (nguồn, số liệu, phân tích từng đối thủ) đã lưu ở deep-research memory
  `market-2026-competitive-threats.md`.
