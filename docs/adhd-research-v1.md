# ADHD — nền tảng khoa học cho Volar (research 2026-08-06)

> Tài liệu tham chiếu. Nguồn thu thập qua deep-research 3 hướng (cơ chế/nguyên nhân,
> hệ quả đời thực, trải nghiệm sống + vì sao tool thất bại). **Mọi con số đều kèm nguồn;
> chỗ nào bằng chứng yếu hoặc chưa verify được đều ghi rõ** — không dùng số có cờ ⚠️ cho
> marketing hoặc App Store copy.

## 1. ADHD là gì (định nghĩa đúng)

Không phải "thiếu tập trung". Mô hình được chấp nhận rộng nhất (Russell Barkley) coi ADHD
là **rối loạn tự điều chỉnh (self-regulation) xuyên thời gian**, mà lõi là suy giảm
**behavioral inhibition** (khả năng ức chế phản ứng bộc phát). Bốn chức năng điều hành
đổ theo sau: working memory phi ngôn ngữ, nội ngôn (tự nói với mình để theo luật),
tự điều chỉnh cảm xúc/động lực, và reconstitution (phân tích–tổng hợp, lập kế hoạch).
Triệu chứng "mất tập trung" chỉ là hệ quả cuối chuỗi, không phải tổn thương gốc.
Nguồn: [Barkley factsheet](https://www.russellbarkley.org/factsheets/ADHD_EF_and_SR.pdf)

Hệ quả thiết kế: mọi công cụ giả định user **tự sinh được động lực từ "việc này quan trọng"**
đều đánh vào đúng chỗ hỏng. Ari Tuckman: *"người ADHD không giỏi tự tạo áp lực nội tại
nên phụ thuộc nhiều hơn vào áp lực bên ngoài — đó là lý do họ trì hoãn."*

## 2. Vì sao có ADHD

### Di truyền (áp đảo)

- **Heritability từ nghiên cứu song sinh: ~74%** (37 nghiên cứu, dải 71–90%) — ngang tự kỷ,
  tâm thần phân liệt, lưỡng cực; cao hơn hẳn trầm cảm/lo âu.
  [Frontiers](https://www.frontiersin.org/articles/10.3389/fpsyg.2022.751041/full) ·
  [PMC10789879](https://pmc.ncbi.nlm.nih.gov/articles/PMC10789879/)
- **Đa gen cực mạnh:** GWAS lớn nhất (Demontis 2023) tìm được **27 locus có ý nghĩa toàn hệ gen**;
  mô hình ước ~**7.300 biến thể phổ biến** mới giải thích 90% SNP-heritability. Không có
  "gene ADHD" đơn lẻ. [Nature Mol Psychiatry](https://www.nature.com/articles/s41380-018-0070-0)
- Khoảng trống heritability: twin 74% vs SNP-based chỉ 14–22% → còn phần rare variant +
  tương tác gene-môi trường. Rare variant 2025: MAP1A, ANO8, ANK2.
  [Nature 2025](https://www.nature.com/articles/s41586-025-09702-8)

### Môi trường (10–40% phương sai, và ít hơn người ta tưởng)

- **Có bằng chứng:** sinh non / nhẹ cân (~3× nguy cơ), phơi nhiễm chì, chấn thương sọ não
  (quan hệ hai chiều: ADHD làm tăng nguy cơ TBI, HR 4,57).
  [Pediatric Research](https://www.nature.com/articles/s41390-024-03233-0)
- ⚠️ **Mẹ hút thuốc khi mang thai — ĐANG TRANH CÃI:** thiết kế so sánh anh chị em ruột cho
  thấy liên hệ này phần lớn do **nhiễu bởi di truyền chung** (mẹ có gene ADHD → vừa dễ hút
  thuốc vừa truyền nguy cơ), không phải tác động trực tiếp.
  [PMC2756407](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC2756407/)
- **KHÔNG phải nguyên nhân (đã bác bỏ):** đường, nuôi dạy kém/thiếu kỷ luật, vaccine.
  Nghiên cứu song sinh/con nuôi cho thấy môi trường gia đình chung (nơi "cách dạy con"
  thể hiện) đóng góp rất ít.
- ⚠️ **Màn hình/screen time — chỉ TƯƠNG QUAN, chưa chứng minh nhân quả.** Cơ chế nếu có
  là gián tiếp (qua rối loạn giấc ngủ, giảm vận động), và nhân quả ngược rất khả dĩ
  (trẻ đã có triệu chứng thì bị hút vào nội dung kích thích cao). Không được nói như
  nguyên nhân đã xác lập.

### Não bộ

- **Dopamine + norepinephrine** ở vỏ não trước trán: điều chỉnh tỷ lệ tín hiệu/nhiễu.
  Đây là cơ sở dược lý của thuốc kích thích.
- **Default Mode Network không tắt đúng lúc:** bình thường DMN phải giảm hoạt động khi vào
  việc; ở ADHD ức chế này không trọn vẹn → suy nghĩ xâm nhập giữa lúc làm việc.
  [PMC5167011](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5167011/)
- **Chậm trưởng thành vỏ não, KHÔNG phải lệch lạc** (Shaw 2007, PNAS): đỉnh độ dày vỏ não
  đạt ~10 tuổi ở ADHD vs ~7,5 tuổi ở nhóm chứng — **trễ ~3 năm**, rõ nhất ở vỏ trước trán
  bên. [PNAS](https://www.pnas.org/doi/10.1073/pnas.0707741104)
- **ENIGMA-ADHD** (n=3.242 và n=4.180): thể tích/diện tích một số vùng nhỏ hơn thật, nhưng
  **effect size nhỏ** (d = −0,21 → −0,10) → không dùng chẩn đoán cá nhân bằng ảnh não được.
- **Mô hình hai đường (Sonuga-Barke):** (a) đường điều hành — thiếu hụt EF cổ điển;
  (b) đường động lực/phần thưởng — **delay aversion**: chờ đợi gây khó chịu thật sự,
  dẫn tới **delay discounting** dốc (thà nhận ít-ngay hơn nhiều-sau).
- **Nghịch lý hyperfocus** giải bằng mô hình cognitive-energetic: vấn đề là điều chỉnh
  mức kích hoạt, không phải "không thể chú ý". Việc nào tự nó đủ kích thích thì nó gánh
  phần điều chỉnh thay não → khoá cứng, khó dứt ra (bản chất là **không tự nguyện**).
  [PMC12437476](https://pmc.ncbi.nlm.nih.gov/articles/PMC12437476/)
- ⚠️ **"Interest-based nervous system" (Dodson) là khung lâm sàng/phổ thông, chưa được
  validate như construct khoa học** — nhưng khớp với literature dopamine/delay-aversion ở trên.
  Khung PINCH của Dodson (Passion, Interest, Novelty, Competition, Hurry) mô tả cái gì
  thật sự khởi động được người ADHD — **không phải "tầm quan trọng"**.

## 3. Các thiếu hụt chức năng điều hành (tên gọi chuẩn)

| Chức năng | Nghĩa | Ghi chú ADHD |
|---|---|---|
| Working memory | Giữ + thao tác thông tin trong đầu | Một trong các thiếu hụt effect size lớn nhất |
| Response inhibition | Ức chế phản ứng bộc phát | Barkley coi là thiếu hụt LÕI |
| Task initiation | Biến ý định thành hành động | Rào cản thần kinh, độc lập với mong muốn |
| Cognitive flexibility | Chuyển chiến lược khi bối cảnh đổi | Kém nhất quán hơn WM/inhibition |
| Emotional self-regulation | Điều tiết cường độ cảm xúc | Từng là tiêu chí lõi trước 1970s, bị bỏ khỏi DSM, nay đang được công nhận lại |
| Time perception (time blindness) | Cảm nhận thời gian trôi | Deadline "không có thật" cho tới lúc đột ngột sát nút |
| Prospective memory | Nhớ làm việc đã định ở tương lai | Suy giảm, chủ yếu do thiếu hụt khâu lập kế hoạch |

## 4. Dịch tễ

- Trẻ em Mỹ: **10,5% đang được chẩn đoán** (6,5 triệu); từng chẩn đoán 11,4%.
  [CDC databrief 499](https://www.cdc.gov/nchs/products/databriefs/db499.htm)
- Người lớn Mỹ: **6,0% (15,5 triệu)**. [CHADD](https://chadd.org/about-adhd/general-prevalence-adults/)
- Toàn cầu người lớn: ADHD dai dẳng **2,58%** (~140 triệu), có triệu chứng **6,76%** (~366 triệu).
  [JOGH](https://jogh.org/the-prevalence-of-adult-attention-deficit-hyperactivity-disorder-a-global-systematic-review-and-meta-analysis/)
- **Chẩn đoán ở phụ nữ 23–49 tuổi tại Mỹ TĂNG GẤP ĐÔI trong 2020–2022.** Bé gái được chẩn
  đoán chỉ bằng ~nửa bé trai (8% vs 15%) vì thể inattentive ít gây rối → ít bị để ý.
- ⚠️ **"50% khỏi khi trưởng thành" là đơn giản hoá sai.** Dải ước lượng qua 12 nghiên cứu:
  4%–77%, phụ thuộc hoàn toàn vào phương pháp. Theo best-practice: **40–50% còn đủ tiêu
  chuẩn chẩn đoán**, nhưng nghiên cứu MTA cho thấy **~90% vẫn còn triệu chứng tồn dư gây
  suy giảm chức năng**; chỉ 9,1% hồi phục bền vững.
  [AJP MTA](https://psychiatryonline.org/doi/full/10.1176/appi.ajp.2021.21010032)

## 5. Người lớn ADHD khác gì hình dung "trẻ hiếu động"

Tăng động **hướng vào trong** thành bồn chồn nội tâm, suy nghĩ đua nhau, không thư giãn nổi.
Cái nổi lên hàng đầu ở người lớn là **rối loạn điều tiết cảm xúc** và **suy giảm chức năng
điều hành** (quản lý thời gian, tổ chức, lập kế hoạch) — chứ không phải chạy nhảy.
**Masking** (nguỵ trang bằng chiến lược bù trừ) là lý do chính khiến chẩn đoán muộn,
đặc biệt ở phụ nữ và người IQ cao.

## 6. Hệ quả đời thực — cái giá thật

### Tuổi thọ và tử vong

- ⚠️ **O'Nions 2025 (BJPsych, UCL):** người lớn **được chẩn đoán** ADHD ở Anh có tuổi thọ
  ước tính ngắn hơn **4,5–9 năm (nam)** và **6,5–11 năm (nữ)**. n=30.029 vs 300.390 đối chứng.
  **Cảnh báo của chính tác giả:** dưới 1/9 người ADHD ở Anh được chẩn đoán → mẫu này thiên
  về ca nặng/nhiều bệnh kèm, có thể **thổi phồng** con số; không có dữ liệu nguyên nhân tử
  vong; chưa được lặp lại. [PubMed](https://pubmed.ncbi.nlm.nih.gov/39844532/)
- **Dalsgaard 2015 (Lancet)**, đăng bạ Đan Mạch 1,92 triệu người: **MRR = 2,07** (tử vong
  gấp đôi). Chẩn đoán khi trưởng thành nguy cơ cao nhất (MRR 4,25). Nguyên nhân chủ yếu là
  **tử vong do nguyên nhân không tự nhiên, đặc biệt tai nạn**.
- Tự sát: ý tưởng tự sát OR 2,22; toan tự sát OR 1,62; hành vi tự sát trọn đời 18,9% vs 9,3%.

### Bệnh kèm

**70–80% người lớn ADHD có ít nhất một rối loạn tâm thần kèm theo.** Lo âu 28–47%,
trầm cảm/rối loạn khí sắc 18,6–53,3%, rối loạn sử dụng chất 11–15% (tới 50% ở nhóm triệu
chứng dai dẳng), lệ thuộc nicotine ~40% (vs 20–26% dân số chung).
[PLOS One](https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0277175)

### Giấc ngủ — chênh lệch lớn nhất trong cả báo cáo

Mất ngủ **66,8%**; **hội chứng pha ngủ trễ 26–33%** so với dân số chung chỉ **0,1–3,1%**
(chênh cả chục lần). Sàng lọc bất kỳ rối loạn giấc ngủ nào: ~60% dương tính.
[ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0165178119324564)

### Kinh tế & công việc (Mỹ, ~8,7 triệu người lớn ADHD)

- Tổng chi phí xã hội vượt trội: **122,8 tỷ USD/năm** (~14.092 USD/người).
- Thất nghiệp cao hơn **13,6 điểm phần trăm**; thu nhập thấp hơn **10.791 USD/năm**;
  **gấp 3 lần khả năng mất việc**; **21,6 ngày công suy giảm/năm**.
  [JMCP](https://www.jmcp.org/doi/10.18553/jmcp.2021.21290)
- WHO World Mental Health (10 nước, n=7.075): **22,1 ngày/năm mất hiệu suất vượt trội**,
  trong đó 8,4 ngày vắng mặt. [PubMed 18505771](https://pubmed.ncbi.nlm.nih.gov/18505771/)

### Lái xe, pháp lý

- Nguy cơ tai nạn giao thông OR 1,49 (nam) / 1,44 (nữ). Dùng thuốc giảm **38%/42%**
  (thiết kế within-person trên 2,3 triệu bệnh nhân).
- Lichtenstein 2012 (NEJM), đăng bạ Thuỵ Điển n=25.656: giai đoạn dùng thuốc, kết án hình
  sự giảm **32% (nam) / 41% (nữ)**. [NEJM](https://www.nejm.org/doi/full/10.1056/NEJMoa1203241)

### Tiền bạc — "ADHD tax"

Nghiên cứu peer-reviewed (PMC5421775) sau khi hiệu chỉnh tuổi/thu nhập/học vấn/chất gây
nghiện vẫn thấy triệu chứng ADHD liên hệ độc lập với: delay discounting, **trả thẻ tín dụng
trễ**, dư nợ thẻ cao hơn, dùng dịch vụ cầm đồ, nợ cá nhân, đổi việc nhiều hơn.
⚠️ Con số tiền cụ thể (1.200–3.000 USD/năm; Monzo £1.600/năm) đến từ tổ chức vận động và dữ
liệu nội bộ một công ty, **không phải nghiên cứu bình duyệt** — dùng để kể chuyện được,
không dùng như dữ kiện khoa học.

### ⚠️ Ly hôn — cần cẩn thận

Con số "gấp đôi" / "cao hơn 30–50%" lan truyền rộng nhưng **truy nguồn về blog và trang vận
động, không tìm được nghiên cứu đăng bạ nào**. Ngược lại, **stress nuôi con** thì có bằng
chứng bình duyệt vững (Theule 2013 và nhiều nghiên cứu khác).

### RSD (Rejection Sensitive Dysphoria)

⚠️ **KHÔNG có trong DSM-5-TR hay ICD-11**, không có tiêu chuẩn chẩn đoán chuẩn hoá. Là
thuật ngữ lâm sàng do William Dodson phổ biến. Con số "77%" đến từ mẫu n=43. Rối loạn điều
tiết cảm xúc thì có bằng chứng vững — RSD là cách gọi một hiện tượng có thật bằng một nhãn
chưa được validate. **Tuyên bố "EU công nhận RSD trong tiêu chuẩn chẩn đoán ADHD" là SAI.**

## 7. Trải nghiệm sống hằng ngày (từ vựng cộng đồng + lâm sàng)

- **Task paralysis** — muốn làm, định làm, nhưng không bước qua được khe giữa ý định và
  chuyển động. Khác trì hoãn thường.
- **Wall of Awful (Brendan Mahan)** — mỗi lần thất bại/xấu hổ/bị chê là một "viên gạch";
  tường xây dần đến mức gửi một cái email cũng như trèo thành. **Đây là lý do app thứ N
  khó cam kết hơn app thứ nhất** — tường cao hơn mỗi lần.
- **"Object permanence"** ⚠️ (dùng sai thuật ngữ; đúng ra là thất bại working memory khi
  thiếu gợi ý) — khuất mắt là biến mất khỏi đầu.
- **Doom piles / doom boxes** — DOOM = "Didn't Organize, Only Moved". Đống đồ bị dồn chứ
  không được phân loại vì không đủ băng thông điều hành để quyết từng món.
- **Time blindness / "now vs not-now" (Barkley)** — thời gian chỉ có hai ngăn: BÂY GIỜ và
  KHÔNG-PHẢI-BÂY-GIỜ. Việc tương lai không "có thật" cho đến khi nó trở thành bây giờ.
- **Waiting mode** — một cuộc hẹn 13h30 phá hỏng cả buổi sáng, vì để không quên thì não
  phải ghim nó ở tiền cảnh ý thức liên tục, chiếm chỗ của mọi việc khác.
- **Task-switching cost** — mỗi lần chuyển việc là một khoản chi phí nhận thức + cảm xúc
  thật, không phải đổi ngữ cảnh trung tính.
- **Decision paralysis** — nghiên cứu tự báo cáo 2025 (n=50): 82% thường xuyên khó ra quyết
  định, 68% nói nó ảnh hưởng rõ tới hiệu suất công việc, 35% gặp hằng ngày.
  [PMC12438291](https://pmc.ncbi.nlm.nih.gov/articles/PMC12438291/) (mẫu nhỏ, tự báo cáo)
- **Revenge bedtime procrastination** — trì hoãn ngủ để đòi lại thời gian riêng; vòng xoáy:
  thiếu ngủ → triệu chứng nặng hơn hôm sau → tự điều chỉnh kém hơn → lại trì hoãn.

## 8. Vì sao app năng suất thông thường THẤT BẠI với người ADHD

Đây là phần quan trọng nhất cho Volar. Điểm chung mọi nguồn: **đây là lỗi thiết kế
(design mismatch), không phải lỗi user.**

1. **List dài → tê liệt.** Màn hình đầy task không phân biệt tự nó đã là rào cản.
2. **Badge đỏ quá hạn / guilt UI → né tránh.** Cái badge sinh ra để nhắc lại thành lý do
   không mở app nữa (khớp vòng xấu hổ ở §7).
3. **Đòi user nhớ mở app** — giải bài toán quên bằng chính năng lực đang hỏng.
4. **Ma sát lúc capture (gõ phím)** — "khó capture thì sẽ không capture". Gõ bắt vừa cấu
   trúc hoá suy nghĩ vừa thao tác vận động, đúng lúc EF yếu nhất. Khuyến nghị lặp lại
   khắp nguồn: **dưới 10 giây, ưu tiên giọng nói, capture trước — sắp xếp sau.**
5. **Bắt user quyết "làm việc nào tiếp"** — cộng thêm tải nhận thức thay vì gỡ bỏ.
6. **Streak/gamification kiểu mất-là-về-0** — ngày 3 thấy vui, ngày 14 thấy trừng phạt;
   đứt chuỗi → xoáy tội lỗi → bỏ app. ⚠️ (số liệu 40% bỏ trong 2 tuần sau khi đứt chuỗi 60+
   ngày là từ blog ngành gamification, không phải nghiên cứu.)
7. **Thiết kế theo lối "kỷ luật hoá" người ADHD cho giống người thường** — scoping review
   học thuật 2026 (arXiv 2601.21791) phê phán phần lớn công nghệ hỗ trợ ADHD theo đuổi
   "cách tiếp cận phi thực tế và ableist", vừa không hiệu quả vừa kỳ thị. Cũng review đó:
   trong nhóm "Assistive Tools" chỉ 4/10 bài dùng thiết kế lấy người dùng làm trung tâm,
   **2/10 đánh giá hiệu quả thật**.
8. **"Tool graveyard" / app-hopping** — bản thân việc tải app mới cho một cú dopamine
   (chữ N = Novelty trong PINCH). Nghĩa là: app mới luôn hiệu quả hơn app cũ trong thời
   gian ngắn, và hiệu ứng đó chắc chắn tàn — **ràng buộc cấu trúc với mọi app ADHD.**

## 9. Cái gì THẬT SỰ có tác dụng

- **Externalize trí nhớ và động lực ra ngoài đầu** (Barkley): "nguồn động lực bên ngoài,
  thường là nhân tạo, phải được bố trí ngay tại điểm thực thi (point of performance)".
  Sửa môi trường hiệu quả hơn dạy kỹ năng tổ chức.
- **Implementation intentions ("nếu X thì tôi làm Y", Gollwitzer)** — **bằng chứng mạnh
  nhất trong cả báo cáo.** Meta-analysis tổng quát: d = 0,65 (94 thí nghiệm, >8.000 người).
  Ở trẻ ADHD có các thử nghiệm có kiểm soát: giảm lỗi kiên trì sai, cải thiện ức chế trong
  Go/No-Go **lên ngang mức trẻ không ADHD**; kết hợp với thuốc cho kết quả cao nhất.
  ⚠️ Phần lớn thử nghiệm ở TRẺ EM; suy rộng sang người lớn hợp lý nhưng chưa được kiểm trực tiếp.
- **Chia việc thành hành động VẬT LÝ quan sát được** — không phải "ôn thi" mà là "đọc 1 trang".
- **Quy tắc 2 phút / on-ramp 5 phút** — hạ năng lượng kích hoạt, vì đây là bài toán chi phí
  khởi động chứ không phải bài toán thiếu hiểu biết.
- **Gợi ý thời gian bên ngoài** (đồng hồ đếm nhìn thấy được) — vì não không "xử lý nền" được
  một mốc tương lai.
- **Thưởng ngay khi hoàn thành** + trách nhiệm giải trình bên ngoài.
- **Body doubling** ⚠️ — bằng chứng thực nghiệm mỏng (một nghiên cứu không thấy hiệu quả ở
  mức nhóm; một pilot n=12 thấy có), NHƯNG trong khảo sát bạn đọc quốc tế 2025 của ADDitude,
  người lớn ADHD **xếp body doubling là chiến lược hiệu quả nhất ở nơi làm việc** — trên cả
  app năng suất, time blocking và Pomodoro.
- **Thuốc — bằng chứng mạnh nhất về outcome:** tử vong mọi nguyên nhân giảm 19%
  (JAMA 2024, đăng bạ Thuỵ Điển ~150.000 người), tử vong do nguyên nhân không tự nhiên
  giảm ~25%, tai nạn xe giảm 38–42%, kết án hình sự giảm 32–41%.
  [PubMed 38470385](https://pubmed.ncbi.nlm.nih.gov/38470385/)

## 10. Ý nghĩa trực tiếp cho Volar

| Phát hiện | Volar đã đúng | Volar cần chú ý |
|---|---|---|
| Capture phải <10s, ưu tiên giọng | Voice-first, hotkey, một hơi thở | Đường gõ tay phải ngon ngang, vì không phải lúc nào cũng nói được |
| Quyết định là chỗ tê liệt (82%) | engine-decides, menu bar 1 việc | Đừng để confirm card biến thành một màn quyết định mới |
| Badge đỏ/streak gây bỏ app | Đã chốt BỎ HẲN STREAK, không badge quá hạn | Giữ kỷ luật này kể cả khi làm stats |
| Wall of Awful — app thứ N khó cam kết hơn | Ngôn ngữ điềm tĩnh, không shame | Onboarding phải hạ kỳ vọng, không hứa "app này sẽ chữa đời bạn" |
| Novelty tàn → app-hopping là ràng buộc cấu trúc | Ritual sáng/tối tạo neo | Đây là rủi ro retention SỐ MỘT, phải đo ngày 3–14 |
| Time blindness, "now vs not-now" | Reminder leo thang | Calendar awareness (Tier 1) đánh đúng chỗ này |
| Waiting mode | (chưa có) | Ý tưởng: khi có mốc hẹn sắp tới, app giữ hộ mốc đó để não thôi phải ghim |
| Bước đầu phải là hành động vật lý | Đã chốt ở 7-đề-xuất-ADHD mục (3) | Phải sửa cả 3 tầng prompt (cloud/FM/heuristic) |
| Implementation intention d=0,65 | (chưa khai thác) | Cơ hội rõ nhất chưa dùng: breakdown nên sinh ra dạng "nếu…thì…" gắn với cue |
| Rối loạn giấc ngủ 60%, pha ngủ trễ gấp ~10× | (chưa có) | Cẩn thận với ritual buổi tối cố định giờ — nhiều user ADHD lệch pha thật |
| Body doubling xếp #1 theo chính user | (chưa có, đang ngoài scope) | Vision đã loại "social/body-doubling" — nên xem lại: chính user xếp nó trên app năng suất |

## 11. Quy tắc dùng tài liệu này cho marketing

- **KHÔNG dùng con số có ⚠️** trong copy công khai (tuổi thọ, ly hôn, ADHD tax bằng tiền,
  prevalence RSD). Chúng hoặc chưa lặp lại được, hoặc nguồn không bình duyệt.
- **Được dùng thoải mái:** heritability ~74%, chậm trưởng thành vỏ não ~3 năm, 70–80% có
  bệnh kèm, dữ liệu giấc ngủ, chi phí kinh tế Mỹ (JMCP), và toàn bộ §7 (từ vựng trải nghiệm
  — đây là thứ cộng đồng nhận ra mình trong đó).
- **Tuyệt đối không doạ bằng tuổi thọ.** Ngoài chuyện số liệu yếu, doạ chính là cơ chế
  kích hoạt shame/né tránh mô tả ở §7 — phản tác dụng với đúng nhóm mình phục vụ.
