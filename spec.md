# Volar — Cross-Platform Feature Spec

**Đây là nguồn sự thật chung** để dựng Volar trên nhiều platform: macOS, Windows, mobile (iOS
trước), watch. File này mô tả **sản phẩm**, không mô tả code của một platform nào.

**Ai đọc file này:** agent/dev được giao implement một bản Volar mới. Đọc xong phải trả lời được
"app này phải cư xử thế nào", rồi tự quyết "trên platform của tôi thì dựng bằng gì".

---

## 0. Cách đọc file này — ba tầng

| Tầng | Nghĩa | Quyền tự do của người implement |
|---|---|---|
| **L1 — LÕI** | Luật sản phẩm. **Mọi platform phải giống hệt nhau**, tới từng con số. Hai bản Volar cho ra kết quả khác nhau trên cùng dữ liệu = lỗi. | **Không có.** Sai lệch phải sửa spec trước, không sửa lẻ một bản. |
| **L2 — THÍCH ỨNG** | Behavior bắt buộc phải có, nhưng **hình hài do platform quyết**. Ví dụ "user gọi được capture từ bất cứ đâu" — macOS là global hotkey, iOS là Siri/Share sheet, watch là complication. | Chọn cơ chế tốt nhất của platform, miễn thoả **mục tiêu** đã ghi. |
| **L3 — TUỲ CHỌN** | Có thì tốt, thiếu không sao. Không port cũng không phải nợ kỹ thuật. | Toàn quyền bỏ. |

**Luật vàng:** nghi ngờ một thứ thuộc tầng nào → mặc định coi là **L1**, rồi hỏi anh Khôi. Sản
phẩm này chết vì hai bản cùng tên mà cư xử khác nhau, không chết vì thiếu một hiệu ứng đẹp.

**Trạng thái các bản hiện có** (tham chiếu, không phải cam kết chất lượng):

| Bản | Nhánh | Trạng thái |
|---|---|---|
| macOS (SwiftUI) | `macos` | Bản tham chiếu đầy đủ nhất. Code-complete, **chưa build/verify hết trên Mac** |
| Windows (.NET + WinUI 3) | `window` | Full-parity theo bản Mac, build/test chạy được |
| iOS | `ios` | Core-first, **chưa có sync** |
| watch | — | Chưa có |

---

## 1. Sản phẩm này là gì (đọc trước khi implement bất cứ gì)

Volar giải đúng **một** vấn đề: khoảng cách giữa *"tôi vừa nghĩ ra một việc"* và *"việc đó nằm
đúng chỗ, đúng thời điểm, và tôi biết phải làm gì tiếp theo"*.

Bốn mệnh đề định hình mọi quyết định thiết kế:

1. **Bắt việc phải nhanh hơn quên.** Nghĩ ra việc → nói/gõ một câu → xong. Không form, không chọn
   project, không chọn ngày trong picker.
2. **Trả lời "làm gì bây giờ", không trả bảng danh sách.** Danh sách 30 dòng là thứ khiến người ta
   đứng hình. App phải chỉ ra **một** việc.
3. **Không bao giờ làm user xấu hổ.** Không streak, không màu đỏ, không "bạn đã trễ 3 ngày". Việc
   chưa làm chỉ là việc chưa làm.
4. **AI đề xuất, người quyết.** Không có đường nào để model tự sửa/tự đánh dấu xong dữ liệu của
   user mà không qua một cú xác nhận.

Nền khoa học: `docs/adhd-research-v1.md`. Định vị sản phẩm: `docs/product-vision-v2.md`.

> **Luật marketing (L1):** không dùng ngôn ngữ y tế (treat / therapy / symptom / diagnose), không
> nêu con số hiệu quả không có nguồn. Trên App Store mô tả bằng **hành vi** ("một việc mỗi lần"),
> không bằng chẩn đoán.

---

## 2. Data contract

### 2.0 "Giống nhau" nghĩa là giống ở đâu — đọc kỹ mục này trước

Câu hỏi hay bị hỏi sai: *"các bản có phải dùng chung một model object không?"* Câu trả lời:
**không, và đừng cố.** Giống nhau ở **hợp đồng**, tự do ở **cách hiện thực**. Năm tầng, mỗi tầng
một câu trả lời khác nhau:

| Tầng | Phải giống? | Ghi chú |
|---|---|---|
| **Ngữ nghĩa** — khái niệm và luật (§2.1, §2.2) | ✅ **BẮT BUỘC** | "Task cha bị loại khi còn con đang mở" mà một bản hiểu khác đi là hai sản phẩm khác nhau đội chung một tên |
| **Hình dạng trong bộ nhớ** — tên field, kiểu dữ liệu | ❌ **Không** | Swift `struct`, C# `record`, Kotlin `data class` — ép ba thứ này giống nhau là tốn công đổi lấy số không. Đặt tên theo quy ước ngôn ngữ của mình |
| **Wire format** — JSON đi/về server | ✅ **BẮT BUỘC** | Mọi bản gọi cùng một Edge Function. Contract nằm ở `supabase/functions/_shared/schema.ts`, đó là nguồn sự thật, không phải client nào |
| **Lưu trên máy** — SwiftData / SQLite / Room / Core Data | ❌ **Không** | …cho tới khi có sync |
| **Canonical form để sync** | ✅ **BẮT BUỘC nếu làm sync** | Xem §2.3. Hiện **chưa bản nào có** |

Hệ quả thực tế: engine dùng chung được giữa macOS và iOS (cùng Swift package), nhưng Windows
(.NET) **không có cách nào** — nó phải viết lại bằng C#. Đó là bình thường và chấp nhận được.
Cái **không** chấp nhận được là viết lại rồi lệch luật.

> ⚠️ **Chỗ nguy hiểm nhất của toàn bộ dự án này không nằm ở model object, nằm ở hai hàm:** engine
> chọn việc (§4.1) và sinh mốc nhắc (§6.1). Mỗi bản viết lại chúng bằng ngôn ngữ của mình; lệch một
> tầng so sánh hoặc một con số thì **không compiler nào kêu, không test riêng của bản nào fail** —
> chỉ có user thấy hai máy chỉ hai việc khác nhau. Ai implement hai hàm này: đọc §4.1/§6.1 từng
> dòng, đừng đọc lướt rồi viết theo trí nhớ.

### 2.1 Task

| Khái niệm | Ngữ nghĩa | Bắt buộc |
|---|---|---|
| `id` | Định danh ổn định, so sánh được theo thứ tự từ điển (UUID string) | L1 — tầng chốt hoà của engine dựa vào nó |
| `title` | Câu việc | L1 |
| `status` | `todo` / `inProgress` / `done` / `archived` | L1 |
| `deadline` | Mốc thời gian, có thể rỗng | L1 |
| `priority` | 1…4, 1 cao nhất; rỗng = chưa đặt | L1 |
| `createdAt` | Lúc tạo | L1 |
| `updatedAt` | Lần sửa gần nhất — **xem §2.3** | L1 |
| `deletedAt` | Bia mộ khi xoá — **xem §2.3** | L1 |
| `parentId` | Task cha (dùng cho việc đã chia nhỏ) | L1 |
| `conditions` | Danh sách điều kiện chặn (§2.2) | L1 |
| `estimateMinutes` | Ước lượng thời lượng | L1 — waiting mode cần |
| `sourceTranscript` | **Nguyên văn câu user đã nói** lúc tạo | L1 — hiện lại khi quay lại task |
| `resumeNote` | Ghi chú "đang làm dở tới đâu" | L2 |
| `cue` | Cue nếu-thì (§7) | L1 |
| `frog` | Việc quan trọng nhất của ngày hôm nay | L2 |
| `isSensitive` | Không đọc nội dung thành tiếng ở nơi công cộng | L2 |
| `reminderOverride` | Chính sách nhắc riêng cho task này | L1 |
| `recurrence` | Lặp lại | L2 |

### 2.2 Condition — bốn loại

| Loại | Nghĩa | Thoả khi |
|---|---|---|
| `taskDone` | Chờ task khác xong | task được trỏ tới có `status == done` |
| `taskStart` | Chờ task khác bắt đầu | task được trỏ tới đã `inProgress` |
| `afterDate` | Chờ tới mốc thời gian | `now >= date` |
| `external` | Chờ người/hệ thống bên ngoài ("chờ sếp duyệt") | **chỉ user tự gỡ** — máy không bao giờ tự đoán là xong |

Ngữ nghĩa **AND**: còn một điều kiện chưa thoả thì task chưa đủ tư cách.

### 2.3 Ba thứ phải có sẵn cho sync — L1, **bắt buộc trong spec, chưa bản nào implement**

Volar chưa có sync. Nhưng sync **nằm trong lộ trình** (bản mobile để dành tier trả phí, focus sync
§5.3), và ba thứ dưới đây thuộc loại **rẻ khi thêm lúc chưa có dữ liệu thật, đắt khi thêm sau** —
thêm sau nghĩa là viết migration cho từng platform, mỗi bản một kiểu.

**Luật (anh Khôi chốt 2026-08-09): mọi bản MỚI dựng theo spec này phải có sẵn từ đầu.** Bản macOS
và Windows đang thiếu; bổ sung khi thực sự làm sync, không phải bây giờ.

**1. `id` sinh ở client, dạng UUID** — ✅ *đã đúng sẵn, ghi ra đây để không ai đổi*

Không dùng số tự tăng của server. Task phải tạo được khi **offline, chưa đăng nhập**, và id đó phải
sống sót nguyên vẹn khi sau này đồng bộ lên. Đây là quyết định khó đảo nhất trong cả mục này.
Engine cũng dựa vào `id` để chốt hoà ở tầng 5 (§4.1) — id đổi nghĩa là thứ tự đổi.

**2. `updatedAt`** — mốc sửa gần nhất, cập nhật ở **mọi** đường ghi

Thiếu nó thì hai máy cùng sửa một task xong không có cách nào biết bản nào mới hơn. Không có nó,
"last write wins" cũng không thực hiện được — không biết ai là "last".

**3. `deletedAt` — bia mộ, KHÔNG xoá thẳng hàng**

Xoá thật khỏi bộ nhớ thì máy kia sync xong sẽ **hồi sinh** task đã xoá: máy A xoá, máy B chưa biết
nên vẫn còn bản của nó, tới lượt B đẩy lên thì task sống lại. User xoá một việc ba lần mà nó cứ
quay về là kiểu lỗi làm người ta gỡ app. Xoá = đánh dấu `deletedAt` + ẩn khỏi mọi truy vấn; dọn
thật sau một khoảng an toàn.

Ba thứ **chưa** cần chốt bây giờ (chốt khi thực sự dựng sync, đừng đoán trước): luật giải xung đột
ở mức field hay mức bản ghi, transport (polling / realtime), và mã hoá đầu-cuối.

### 2.4 Thời gian — L1

- **Lưu mọi mốc thời gian dạng tuyệt đối** (instant/UTC). Không lưu chuỗi giờ địa phương, không lưu
  kèm tên múi giờ như một phần của giá trị.
- **Múi giờ/`Calendar` là tham số truyền vào hàm**, không đọc từ biến toàn cục — cùng luật với
  `now` (§4.1).
- ⚠️ **Cái bẫy cụ thể:** tầng 2 xếp hạng của engine hỏi *"deadline này có cùng ngày với `now`
  không"*. Đây là câu hỏi **theo lịch**, nên hai máy khác múi giờ **trả lời khác nhau trên cùng một
  dữ liệu** — 23h ở Hà Nội và 9h sáng hôm sau ở đâu đó là cùng một khoảnh khắc nhưng khác "hôm
  nay". Mỗi bản phải chốt rõ và ghi lại: "hôm nay" tính theo lịch của **thiết bị**, hay theo một
  múi giờ chuẩn của **tài khoản**. Hai bản chọn khác nhau = hai bản chỉ hai việc khác nhau, và
  không test nào của riêng bản nào bắt được.

---

## 3. FEATURE 1 — Bắt việc linh hoạt (giọng nói / chữ)

### 3.1 Mục tiêu

Từ lúc nảy ra ý tới lúc việc nằm trong hệ thống: **một thao tác, không rời khỏi việc đang làm**.

### 3.2 Đường vào — L2 (bắt buộc có, hình hài tuỳ platform)

Yêu cầu chung: phải gọi được capture **mà không cần mở app trước**, và phải có **cả đường nói lẫn
đường gõ** (mic hỏng, đang ở nơi không nói được, hoặc chỉ muốn gõ).

| Platform | Đường nói | Đường gõ |
|---|---|---|
| macOS | Global hotkey (hiện tại ⌃⌥M), menu bar, URL scheme `volar://capture` | Global hotkey (⌃⌥T) mở ô nhập nổi |
| Windows | Global hotkey dạng **toggle** (`RegisterHotKey`), tray | Hotkey riêng + ô nhập nổi |
| Mobile | Share sheet, Siri Shortcut / trợ lý hệ thống, widget màn hình khoá, Control Center | Widget + ô nhập trong app |
| Watch | Complication, nút bấm nhanh, "raise to speak" | **Miễn** — bàn phím watch không phải đường gõ thật; thay bằng dictation + gợi ý |

### 3.3 Đường xử lý — L1

Chuỗi ba tầng, **luôn trả về kết quả dùng được**, không bao giờ ném lỗi vào mặt user:

1. **On-device model** (nếu platform có)
2. **Cloud** (Gemini qua Edge Function) — cần: đã đăng nhập **+ đã đồng ý privacy một lần** **+**
   có mạng
3. **Sàn title-only** — không tầng nào chạy được thì tạo task với **nguyên văn câu nói làm tiêu
   đề**. **Cấm đoán** deadline/priority bằng quét từ khoá: thà không có dữ liệu còn hơn dữ liệu sai
   mà user tưởng là đúng.

Luật cứng:

- Một câu nói → **1 đến 10 task**. Cap 10 áp ở tầng router, không tin producer tự cap.
- **Luôn hiện thẻ xác nhận trước khi lưu.** Không có đường ghi thẳng.
- Câu rỗng/toàn khoảng trắng → không tạo gì, không báo lỗi.

### 3.4 Đa ngôn ngữ — L1 về câu chữ, L2 về engine

**Cách nói ra ngoài (anh Khôi chốt 2026-08-09): "hỗ trợ đa ngôn ngữ". KHÔNG nêu con số.**

Lý do: số ngôn ngữ không do app quyết mà do engine đang chạy, và mỗi platform có bộ engine khác
nhau.

| Đường | Phạm vi |
|---|---|
| **Cloud (Whisper qua Groq)** — mặc định | Đa ngôn ngữ, tự nhận ngôn ngữ đang nói |
| On-device của hệ điều hành | Đúng bằng danh sách OS hỗ trợ trên máy đó — **hẹp hơn**, khác nhau giữa các máy |
| On-device Whisper (nếu phần cứng cho phép) | Tự nhận ngôn ngữ |

Hai luật:

- Phải có lựa chọn **"Automatic (multilingual)"** và nó phải **không gửi hint ngôn ngữ** cho
  server, để model tự nhận — đây là thứ làm câu trộn vi↔en hoạt động.
- Đường cloud cần **đã đăng nhập**. Chưa đăng nhập thì rơi về on-device, và lúc đó **phạm vi ngôn
  ngữ hẹp lại** — không được quảng cáo "đa ngôn ngữ hoàn toàn offline".

### 3.5 Sửa / đánh dấu xong bằng giọng — L1

Ba ý định phải nhận ra được từ lời nói:

| Ý định | Ví dụ | Kết quả |
|---|---|---|
| Đánh dấu xong | "xong cái báo cáo rồi" | Thẻ xác nhận một chạm |
| Gỡ trạng thái chờ | "sếp duyệt rồi" | Thẻ xác nhận một chạm |
| Sửa task đang có | "cái vụ gửi mail dời sang thứ sáu" | Thẻ xác nhận, **user phải tự chọn đúng task** |

Ba luật **cấm phá** (L1):

1. Server **không bao giờ trả về task id** — chỉ trả cụm từ để client tự tìm trong kho của mình.
   Đây là ranh giới privacy: server không cần biết danh sách việc của user.
2. **Không bao giờ tự gán**, dù độ tin cậy 0.99. Fuzzy match chỉ để **sắp xếp gợi ý**.
3. Ghi chú là **nối thêm**, không ghi đè.

---

## 4. FEATURE 2 — Mỗi lần một việc

### 4.1 Engine chọn việc — L1, **phải là hàm thuần**

Đây là trái tim sản phẩm. Yêu cầu kỹ thuật cứng, mọi platform:

- **Không I/O, không đọc đồng hồ toàn cục.** `now` và `calendar` là **tham số truyền vào**. Cùng
  input → cùng output, luôn luôn.
- Nằm ở **tầng lõi dùng chung**, không nằm trong UI layer.
- Có **test đơn vị với đồng hồ cố định** trước khi nối vào giao diện.

**Đủ tư cách** — loại khỏi danh sách nếu:

- không phải `todo`/`inProgress`;
- còn condition chưa thoả;
- **là cha của một task con đang mở** → user luôn nhìn thấy bước nhỏ, không nhìn thấy tảng đá.

**Thứ tự** — 5 tầng, hơn nhau ở tầng nào dừng ở tầng đó:

1. `inProgress` trước `todo`
2. Deadline **hôm nay hoặc đã quá hạn** trước; trong nhóm đó, deadline sớm hơn trước. Deadline
   tương lai xa **không** tham gia tầng này.
3. Priority tăng dần; chưa đặt thì xếp sau mọi giá trị đã đặt
4. `createdAt` sớm hơn trước
5. So sánh `id` dạng chuỗi

Tầng 5 tồn tại để quan hệ này là **total order**: không hoà, không nhấp nháy đổi thứ tự giữa hai
lần vẽ lại màn hình.

**API tối thiểu:** `nextTask()` phải **là** `eligibleTasksOrdered().first` — cùng một đường code,
không phải hai đường "được ghi chú là đồng ý với nhau". Cần cả danh sách xếp hạng đầy đủ vì waiting
mode (§8) dùng nó.

### 4.2 Hiển thị "một việc" — L2

Bắt buộc: phải có **ít nhất một bề mặt luôn nhìn thấy** chỉ hiện đúng một việc, đọc thẳng từ engine.

| Platform | Bề mặt "một việc" |
|---|---|
| macOS | Menu bar |
| Windows | Tray / taskbar |
| Mobile | Widget màn hình khoá + Live Activity / Dynamic Island |
| Watch | Complication trên mặt đồng hồ — **đây là bề mặt chính của bản watch** |

Màn hình chính **được phép** có danh sách bên dưới thẻ chính (macOS đang vậy), nhưng **thẻ chính
phải chiếm ưu thế thị giác rõ rệt**. Bản watch thì ngược lại: **chỉ một việc**, danh sách là màn
hình phụ phải cuộn tới.

**Switch (đổi gió):** user đổi việc đang hiện. Luật: Switch chỉ ảnh hưởng **màn hình chính**; bề
mặt "một việc" ở trên vẫn đọc lựa chọn **thô** của engine. Và Switch **không** phải hành động xấu —
không cảnh báo, không đếm, không nhắc lại.

### 4.3 Chia nhỏ việc — L1 về luật, L2 về UI

- Kết quả: **3–9 bước**.
- **Luôn do user chủ động** — cấm tự chia. Ít nhất một đường vào từ menu của task.
- Không lấy được kết quả → **nói thật** ("cần cloud" / "không kết nối được"). **Cấm bịa** bước mẫu.

### 4.4 "Stuck?" — L1

Nút đứng **ngang hàng** với "Done", cùng kiểu dáng, không màu cảnh báo, không icon. Bấm vào hỏi
**loại bế tắc**, ba lựa chọn viết bằng câu người thường (không bao giờ lộ tên mã `too_big`/`dread`/
`cant_start` ra giao diện):

| User chọn | App làm |
|---|---|
| "Việc này giống nhiều việc gộp lại." | Trả về **đúng một hành động vật lý kế tiếp** — không phải cả kế hoạch. Kèm đường phụ mở bản chia nhỏ đầy đủ. Không tìm được thì nói thẳng, **cấm bịa**. |
| "Nhìn vào là thấy nặng." | Một câu ngắn gọi tên chi tiết đang gây ngán + nút "Bắt đầu (2 phút)". Không có model thì dùng câu tĩnh trung thực. |
| "Không nhúc nhích được." | Đồng hồ **2 phút** trần trụi, thông điệp "hai phút thôi, làm gì cũng được" — **không gắn với task nào**. |

Ba nhánh này khác nhau có chủ đích. Gộp lại thành một "trợ lý AI" chung là **hỏng feature**: ba
loại bế tắc cần ba loại can thiệp khác nhau.

**Watch:** nhánh 3 (đồng hồ 2 phút) là nhánh giá trị nhất và dễ làm nhất — làm nhánh này trước.

---

## 5. FEATURE 3 — Focus mode

### 5.1 Lõi — L1

- Phiên **25 phút**.
- Đồng hồ đếm ngược **thuộc về tầng state của app, không thuộc view**. Đóng/ẩn màn hình focus thì
  phiên **vẫn chạy**. Đây từng là bug thật: timer chết theo view, phiên đứng im.
- Trong phiên: **một việc trên màn hình**, mọi thứ khác lùi ra sau.
- Bốn hành động: **Xong · Đổi việc · Stuck? · Tạm dừng/Kết thúc**.
- **Ngữ cảnh quay lại** hiện cùng task: "N/M bước xong", ghi chú đang làm dở, và **nguyên văn câu
  user đã nói lúc tạo**. Đây là thứ khiến quay lại một việc bỏ dở không phải bắt đầu lại từ đầu.

### 5.2 Khung cảnh (nền + âm) — L3

Có thì tốt, thiếu không sao. Nếu làm thì đúng những gì đang có, **đừng hứa hơn**:

- Nền động: mưa / tuyết / than hồng / ảnh user tự chọn.
- Âm thanh: **noise tổng hợp trong bộ nhớ** (white noise cho mưa, brown-ish noise cho tuyết/than),
  **không ship file audio**, không nhạc, không playlist, không preset "quán cà phê".
- Watch: **bỏ hẳn** — vẽ particle trên watch là đốt pin đổi lấy thứ không ai nhìn.
- Mobile: cân nhắc kỹ, cùng lý do pin.

> ⚠️ Bẫy đã gặp trên macOS: nền động gắn ở màn hình chính chứ không gắn trong lớp phủ focus, mà lớp
> phủ lại tô tối đè lên → **vào focus là gần như mất nền**. Bản nào làm khung cảnh thì phải kiểm
> bằng mắt đúng lúc đang ở trong focus.

### 5.3 Đồng bộ focus giữa các thiết bị — ❌ **CHƯA CÓ Ở BẤT KỲ BẢN NÀO**

Ý tưởng: bật focus ở máy tính → điện thoại/watch cũng vào chế độ tối giản, im lặng.

**Hiện trạng: không tồn tại.** Không bản nào có sync, Handoff, hay kênh đẩy trạng thái. Nhánh `ios`
cố tình chưa có sync (để dành tier trả phí).

Cần gì để làm được (đây là **feature mới, cần spec riêng**, không phải chỉnh sửa nhỏ):

1. Backend đồng bộ trạng thái phiên focus (ai đang focus, việc gì, còn bao lâu) — hiện chưa có
   bảng nào cho việc này.
2. Ít nhất hai bản client cùng chạy được và cùng đăng nhập một tài khoản.
3. Quyết định luật xung đột: hai thiết bị cùng bật focus hai việc khác nhau thì ai thắng.
4. Quyết định luật privacy: trạng thái focus là dữ liệu hành vi — đồng bộ nghĩa là nó rời khỏi máy.

**Cho tới khi làm xong: cấm nhắc tính năng này trong bất kỳ mô tả sản phẩm nào.**

Lưu ý phân biệt: "im lặng khi chế độ Focus của **hệ điều hành** đang bật" là chuyện **khác** và
thuộc §6 — dễ hơn nhiều, và nên có ở mọi platform.

---

## 6. FEATURE 4 — Nhắc việc

### 6.1 Sinh mốc nhắc — L1, tới từng con số

**Mặc định:** nhắc **đúng lúc deadline**, cộng mốc khi **còn 1/2** và **còn 1/3** thời gian.

Mốc tính theo **phần thời gian còn lại**, nên khoảng cách giữa các lần nhắc **tự co lại khi tới
gần deadline** — đó chính là "càng gần càng nhắc dày", và nó tự đúng cho cả task 10 ngày lẫn task 2
tiếng mà không cần luật riêng.

| Luật | Giá trị | Vì sao |
|---|---|---|
| Sàn sớm nhất | không nhắc sớm hơn deadline − **24h** | mốc "một nửa" của task 30 ngày bị **kéo về** mốc 1 ngày trước, không bắn 15 ngày sớm |
| Khoảng cách tối thiểu | **10 phút** | không bắn hai thông báo dính nhau |
| Trần số mốc trước deadline | **8 mốc/task** | ngân sách thông báo của OS là hữu hạn và dùng chung cho cả app |
| User nói rõ cadence ("nhắc mỗi 15 phút") | **thắng** mốc theo tỉ lệ | user nói rõ thì nghe user |

**Task không có deadline vẫn phải được nhắc** — backoff dịu, **neo vào `createdAt`**:

- priority cao nhất: **1h, 3h, 7h, 14h, 24h, 72h**
- mọi priority còn lại (kể cả chưa đặt): **7h, 14h, 24h, 72h**
- hết danh sách: **lặp mãi mỗi 3 ngày**

> ⚠️ **Neo vào `createdAt`, tuyệt đối không neo vào `now`.** Sinh mốc chạy lại mỗi lần khởi động/máy
> thức dậy/sửa task. Neo `now` thì mỗi lần chạy lại reset về "1h nữa" → biến thành cằn nhằn hàng
> giờ, không bao giờ tới được các mốc thưa. Đây là bug đã từng xảy ra.

Sinh mốc phải là **hàm thuần** (`now` là tham số) và có test riêng, giống engine chọn việc.

### 6.2 Leo thang — L1 về nấc thang, L2 về hình hài

| Nấc | Khi nào |
|---|---|
| 1. Thông báo bình thường | mọi reminder |
| 2. **Đọc thành tiếng** | reminder ở/quá deadline, **hoặc** một reminder trước đó của cùng task đã bị lờ |
| 3. **Chiếm toàn màn hình** | reminder đã hiện mà **nằm im ≥5 phút** |

Điều kiện chặn nấc 3 (mỗi cái đủ để huỷ):

- user đã tắt setting;
- **mic đang được dùng** (đang họp — chiếm màn hình lúc này là phá hoại);
- app đang ghi âm;
- task đã xong;
- thông báo đã được tương tác.

Ba luật cứng:

1. **Một record chỉ được chiếm màn hình đúng một lần** mỗi lần chạy app — kể cả khi user để nó tự
   đóng. Không có vòng lặp nag.
2. Mỗi lượt quét chỉ nổi **một** cửa sổ, không xếp chồng.
3. Mốc "bị lờ" tính theo **giờ giao thật của thông báo**, không phải giờ dự kiến. Bug đã gặp: máy
   ngủ qua đêm, mở lên là bị chiếm màn hình ngay lập tức trước khi user kịp nhìn.

**Thích ứng nấc 3 theo platform:** macOS/Windows = cửa sổ toàn màn hình. Mobile = notification
critical/full-screen intent theo luật của OS. **Watch = haptic mạnh + màn hình đơn** — không có
khái niệm "chiếm màn hình" trên watch, thay bằng chạm cổ tay.

### 6.3 Tính bền — L1

- Reminder nằm trong **bộ nhớ bền**, **dựng lại từ ổ đĩa mỗi lần khởi động và mỗi lần máy thức
  dậy**. Không có gì "chỉ sống trong RAM".
- Reminder quá hạn khi app không chạy: bắn bù **đúng một lần** — phải đối chiếu với thứ OS đã giao
  để không bắn lại.
- Task xong/xoá → huỷ sạch reminder. Task lặp lại → sinh lại theo deadline mới.
- Nút trên thông báo (**Xong / Hoãn 10' / Tối nay / Ngày mai / Cuối tuần**) **không được mở app**.
- Chữ trong thông báo **dịu**: "due tomorrow", "due now", "worth a look". **Cấm** "OVERDUE",
  "MISSED", cấm chữ in hoa hét vào mặt.

---

## 7. Cue nếu-thì (implementation intention) — L1

Giữ **nguyên văn** câu điều kiện của user ("ngủ dậy thì test cái này") và đọc lại đúng lúc.

| Loại cue | Fire khi nào |
|---|---|
| `wake` | Phiên tương tác đầu tiên sau khoảng nghỉ **≥6 giờ** |
| `dayEnd` | Nghi thức cuối ngày |
| `unknown` | **Không fire** — chỉ hiện ở điểm chạm tự nhiên |

Bốn luật:

1. **Không neo vào giờ đồng hồ.** "Buổi sáng" của user này không phải 7h — lệch pha ngủ là đặc
   điểm của chính nhóm user này. Dùng **khoảng nghỉ giữa hai phiên**, không dùng giờ.
2. `unknown` là **hợp lệ và phổ biến**, không phải lỗi. Giá trị nằm ở **nguyên văn**, không nằm ở
   việc máy hiểu được — liên kết nếu-thì đã hình thành trong đầu user rồi, app chỉ cần đọc lại đúng
   lời họ.
3. **Hết hạn sau 48 giờ**: quá mốc thì cue thành trơ — vẫn hiện được chữ, nhưng không đẩy thứ tự
   lên nữa. Đây là hàng rào chống nuốt việc.
4. **Cue không bao giờ ẩn task.** Nó là lớp **làm nổi**, tuyệt đối không phải điều kiện chặn.

---

## 8. Waiting mode — L1

**Vấn đề:** một cuộc hẹn cứng lúc 1h30 có thể phá nát cả buổi sáng, vì cách duy nhất để không quên
nó là giữ nó trong đầu suốt — chiếm hết chỗ của mọi việc khác.

**App làm:** giữ hộ cái mốc đó, và trả lời "từ giờ tới đó làm được gì".

- Tìm **mốc cứng gần nhất sắp tới**.
- Tính thời gian còn lại, **trừ đi một khoảng đệm** — "vừa đủ lọt" không được có nghĩa "tới nơi
  đúng lúc hết giờ".
- Trong **thứ tự mà engine đã xếp** (§4.1), lấy task đầu tiên **lọt vào** khoảng đó.
- **Chỉ lọc, không xếp lại.** Cấm tự chấm điểm hay đoán lại thứ tự.
- Việc được gợi ý **không bao giờ là chính cái mốc đó**.

Ghi chú thiết kế: bản macOS đang dùng "deadline gần nhất" làm **đại diện** cho "mốc cứng", vì chưa
có khái niệm cuộc hẹn riêng. Platform nào có nguồn lịch tin cậy hơn thì **vẫn phải theo luật §11
về quyền lịch**.

---

## 9. Feature phụ (L3) — port khi có chỗ

| Feature | Mô tả |
|---|---|
| Con ếch buổi sáng | Lần mở đầu tiên trong ngày: chọn **một** việc quan trọng nhất hôm nay |
| Sweep buổi tối | **Một thẻ gộp** cuối ngày để tick nhanh. "Bỏ qua" = "hôm nay không tới lượt", mang sang mai lặng lẽ. **Không đỏ, không streak, không "bạn chưa xong"** |
| Triage việc cũ | Mỗi chu kỳ gom **một** thẻ cho cả loạt việc nguội — **không nag từng cái** |
| Đọc ngày thành tiếng | Đọc số việc đang mở + tối đa 3 tiêu đề; rỗng thì "xong hết rồi" |
| Mirror lịch | **Một chiều** app → lịch riêng do app tự tạo. Xem §11 |
| Giao việc cho AI | Task mang điều kiện "đang chờ AI" + backoff hỏi lại; deep link để agent báo xong |
| Tour hướng dẫn | Overlay chỉ chỗ lần đầu |

---

## 10. Tài khoản, tier, quota — L1

- **Vòng lõi phải chạy được khi chưa đăng nhập và không có mạng**: bắt việc → tạo task → nhắc →
  focus. Đăng nhập chỉ mở thêm đường cloud.
- Đăng nhập: mã một lần qua email.
- **Cloud speech và cloud parse mở cho cả free lẫn Pro** — khác nhau ở **hạn mức mỗi ngày**, không
  khác nhau ở tính năng.
- Khoá bí mật (Groq, Gemini) **không bao giờ nằm trong client**. Mọi lời gọi đi qua proxy của mình.
- Hết quota → **một dòng nhẹ nhàng**, tự rơi về on-device. Không modal chặn đường, không bán hàng
  giữa lúc user đang bắt việc.
- Phải có **xoá tài khoản** thật sự xoá phía server.

---

## 11. Ranh giới privacy — L1, không thương lượng

1. **Không analytics SDK, không crash-reporter SDK, không quảng cáo, không tracking.** Ở mọi bản.
2. Chữ/audio chỉ rời máy trên đúng hai đường **cloud speech** và **cloud parse**, và cả hai đều cần
   **đồng ý một lần rõ ràng**. Từ chối là từ chối vĩnh viễn cho tới khi user tự đổi trong Settings.
3. **Server không bao giờ nhận task id.** Tham chiếu tới task đang có luôn đi bằng **cụm từ**, client
   tự tìm.
4. **Quyền lịch:** chỉ **ghi** vào lịch riêng do app tự tạo. **Cấm đọc nội dung event** của user
   (anh Khôi bác quyền đọc lịch ngày 2026-08-07). Trước mỗi lần ghi phải qua **hai lớp kiểm chứng
   độc lập**: đúng lịch của mình **và** đúng dấu do chính app đóng lên event. Cấm tin OS scope hộ —
   quyền lịch của hệ điều hành là quyền cho **mọi** lịch.
5. Nội dung nhạy cảm: không đọc thành tiếng.

---

## 12. Tông giọng — L1

Áp cho mọi chữ user nhìn thấy, mọi platform, mọi ngôn ngữ:

| Cấm | Thay bằng |
|---|---|
| Streak, chuỗi ngày, "đừng làm đứt chuỗi" | Không có gì cả |
| Màu đỏ, badge "quá hạn", chữ in hoa | Chữ dịu, cùng màu với mọi thứ khác |
| "Bạn chưa hoàn thành…", "bạn đã trễ…" | "Việc này chưa tới lượt" |
| Tên mã lộ ra giao diện (`too_big`, `dread`) | Câu người thường, ngôi thứ nhất |
| Nút "nguy hiểm" cho hành động bình thường ("Bỏ", "Stuck?") | Cùng kiểu dáng với mọi nút khác |

Nguyên tắc gốc: bấm **"Stuck?"** phải cảm thấy bình thường **y hệt** bấm "Xong".

---

## 13. Checklist cho agent bắt đầu một bản mới

0. Đọc **§2.0** trước khi gõ dòng model đầu tiên — biết rõ chỗ nào bắt buộc giống, chỗ nào tự do.
   Dựng model với **`id` UUID sinh ở client, `updatedAt`, `deletedAt`** ngay từ đầu (§2.3): thêm
   bây giờ là một dòng, thêm sau là một migration.
1. Dựng **engine chọn việc** (§4.1) làm module thuần trước tiên. Test với đồng hồ cố định. **Chưa
   xanh thì chưa động vào UI.**
2. Dựng **sinh mốc nhắc** (§6.1) cũng thuần, cũng test trước. Hai module này là nơi hai bản Volar
   dễ lệch nhau nhất, và lệch thì không compiler nào bắt được.
3. Dựng lưu trữ bền + **dựng lại lúc khởi động/thức dậy** (§6.3).
4. Dựng đường bắt việc (§3) với sàn title-only **trước**, cloud sau — để app dùng được ngay cả khi
   backend chưa sẵn sàng.
5. Dựng bề mặt "một việc" (§4.2) của platform mình.
6. Focus mode (§5.1), khung cảnh để sau cùng hoặc bỏ.
7. Đối chiếu ngược §11 (privacy) và §12 (tông giọng) **trước khi** viết bất kỳ chữ nào ra ngoài.

**Khi phát hiện spec này mâu thuẫn với code của một bản đang chạy:** dừng, hỏi anh Khôi, sửa spec
trước. Đừng lặng lẽ làm theo code — bản đang chạy có thể mới là bản sai.
