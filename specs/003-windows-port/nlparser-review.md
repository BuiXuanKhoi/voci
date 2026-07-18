# NLParser.cs — Bảng đối chiếu để Opus / anh Khôi duyệt

Nguồn đối chiếu:
- C#: `C:\projects\voci-windows\windows\src\Volar.Domain\NLParser.cs` (807 dòng gốc trước khi sửa
  "khuya"; sau khi sửa còn 828 dòng — xem mục G.2)
- Swift: `C:\projects\voci\Volar\Sources\Model\NLParser.swift` (604 dòng, chỉ đọc)

Tài liệu này **trích xuất trung thực** hành vi hiện có trong code, không tự ý sửa (trừ bug "khuya"
đã được anh Khôi chốt sẵn — xem mục G.2). Mọi nghi vấn được đánh dấu ⚠️ trong bảng và gom lại đầy đủ
ở Mục H, không tự quyết định thay anh Khôi.

---

## Bảng A — Từ chỉ buổi trong ngày

Áp dụng trong hàm `ApplyVietnameseTimeOfDay(hour, marker)`, được gọi từ `TryMatchVietnameseClock`
— **chỉ có tác dụng khi marker đứng NGAY SAU một con số giờ dạng `<n>h` hoặc `<n> giờ`** (xem
`VietnameseHourMarkerRegex` / `VietnameseGioRegex` ở Bảng D). Một từ chỉ buổi đứng một mình, không
đi kèm con số giờ, KHÔNG được nhận diện ở bảng này (xem Bảng E / mục H.4).

| Từ | Quy tắc hiện tại trong code | Ví dụ input → output | ⚠️ |
|---|---|---|---|
| `sáng` | Giữ nguyên giờ literal (không +12) | "9 giờ sáng" → 09:00 | |
| `trưa` | Giữ nguyên giờ literal (không +12) | "12 giờ trưa" → 12:00 | |
| `chiều` | +12 nếu giờ literal < 12, giữ nguyên nếu ≥ 12 | "3h chiều" → 15:00 | |
| `tối` | +12 nếu giờ literal < 12, giữ nguyên nếu ≥ 12 | "9h tối" → 21:00 | |
| `khuya` | **[ĐÃ SỬA theo quyết định anh Khôi]** Giữ nguyên giờ literal (không +12). Nếu giờ đó đã trôi qua trong ngày hôm nay (so với `now`) VÀ không có từ chỉ ngày nào khác trong câu, tự động dời sang ngày hôm sau. | "2h khuya" lúc `now`=09:00 cùng ngày → ngày mai 02:00 (đã trôi qua). "2h khuya" lúc `now`=00:30 cùng ngày → hôm nay 02:00 (chưa trôi qua). | Đã chốt — không hỏi lại. |
| `đêm` | **KHÔNG được regex nhận diện** — không nằm trong alternation `(sáng\|trưa\|chiều\|tối\|khuya)`. "9h đêm" → marker không khớp → coi như không có marker → giữ nguyên giờ literal → 09:00 (không phải 21:00 như người dùng có thể mong đợi). | "9h đêm" → 09:00 | ⚠️ H.1 |
| `rạng sáng` | **KHÔNG được nhận diện** — cụm 2 từ, marker regex chỉ khớp 1 token ngay sau giờ; "rạng" không nằm trong alternation nên cả cụm bị bỏ qua, group marker rỗng. | "5h rạng sáng" → marker=null → giữ nguyên 05:00 (tình cờ đúng, nhưng không phải do regex hiểu "rạng sáng") | ⚠️ H.2 |
| `nửa đêm` | **KHÔNG được nhận diện** như marker giờ (không nằm trong alternation). Có tồn tại `"nửa đêm"` như phrase riêng ở đâu đó? Không — không xuất hiện trong `HalfHourPhrases`/`NinetyPhrases`/bất kỳ bảng nào khác. Hoàn toàn không được xử lý. | "nửa đêm mai" → không có deadline giờ nào được set, chỉ ngày "mai" (nếu match) | ⚠️ H.2 |
| *(không có marker)* | Giữ nguyên giờ literal | "15h" → 15:00 | |

---

## Bảng B — Từ chỉ ngày tương đối

Áp dụng trong `ResolveDateToken`, thử theo thứ tự: (1) từ khoá thứ-trong-tuần (Bảng C) → (2) cụm
"ngày mai" → (3) cụm "tuần sau/tới" → (4) cụm "hôm nay". **Chỉ 4 nhóm này tồn tại** trong code —
không có gì khác.

| Từ | Offset hiện tại | Ví dụ | ⚠️ |
|---|---|---|---|
| `hôm nay` / `today` | +0 ngày (dùng nguyên `now`) | "làm việc này hôm nay" → cùng ngày với `now` | |
| `mai` / `ngày mai` / `tomorrow` (xem `ContainsTomorrowCue`: chứa `"tomorrow"`, `"ngày mai"`, `" mai "` có khoảng trắng 2 bên, kết thúc bằng `" mai"`, hoặc bắt đầu bằng `"mai "`) | +1 ngày | "mai làm việc này" → `now`+1 ngày | Cụm `" mai "` yêu cầu có khoảng trắng CẢ HAI bên — chữ "mai" dính liền dấu câu (vd "mai," không có khoảng trắng sau) có thể trượt qua tất cả 4 điều kiện. ⚠️ H.9b |
| `tuần sau` / `tuần tới` / `next week` | +7 ngày | "làm việc này tuần sau" → `now`+7 ngày | |
| `mốt` / `ngày kia` (day-after-tomorrow) | **KHÔNG tồn tại trong code** | — | ⚠️ H.5 |
| `hôm qua` (yesterday) | **KHÔNG tồn tại trong code** | — | ⚠️ H.5 |
| `tháng sau` (next month) | **KHÔNG tồn tại trong code** | — | ⚠️ H.5 |
| `cuối tuần` (this/next weekend) | **KHÔNG tồn tại trong code** | — | ⚠️ H.5 |

---

## Bảng C — Thứ trong tuần

Bảng `WeekdayKeywords` (khớp bằng `string.Contains`, không dùng word-boundary/regex), sau đó
`NextOccurrenceOfWeekday` luôn trả về **lần xuất hiện KẾ TIẾP** — nếu thứ được nói trùng với thứ của
`now`, luôn hiểu là "thứ đó của TUẦN SAU" (+7 ngày), KHÔNG BAO GIỜ là "hôm nay".

| Từ (các biến thể được nhận diện) | Ánh xạ (Sun=1…Sat=7) | Quy tắc chọn tuần | ⚠️ |
|---|---|---|---|
| `chủ nhật`, `chúa nhật`, `sunday` | 1 | Kế tiếp; nếu hôm nay là CN → +7 | |
| `thứ hai`, `thứ 2`, `monday` | 2 | Kế tiếp; nếu hôm nay là T2 → +7 | |
| `thứ ba`, `thứ 3`, `tuesday` | 3 | Kế tiếp; nếu hôm nay là T3 → +7 | |
| `thứ tư`, `thứ 4`, `wednesday` | 4 | Kế tiếp; nếu hôm nay là T4 → +7 | |
| `thứ năm`, `thứ 5`, `thursday` | 5 | Kế tiếp; nếu hôm nay là T5 → +7 | |
| `thứ sáu`, `thứ 6`, `friday` | 6 | Kế tiếp; nếu hôm nay là T6 → +7 | |
| `thứ bảy`, `thứ 7`, `saturday` | 7 | Kế tiếp; nếu hôm nay là T7 → +7 | |
| `t2`…`t7`, `cn` (viết tắt không dấu cách) | **KHÔNG được nhận diện** | — | ⚠️ H.6 |
| `thu 2`, `chu nhat`… (không dấu) | **KHÔNG được nhận diện** — so khớp là so khớp chuỗi có dấu chính xác trên bản đã `ToLowerInvariant()`, KHÔNG bỏ dấu | — | ⚠️ H.6 |
| Thứ tự thử trong mảng | Mảng được duyệt tuần tự (chủ nhật → thứ hai → … → thứ bảy); `break` ngay khi khớp từ khoá ĐẦU TIÊN tìm thấy bằng `Contains`, không phải từ khoá xuất hiện SỚM NHẤT trong câu theo vị trí ký tự. Nếu câu chứa cả "thứ 2" lẫn "thứ 3" (hiếm nhưng có thể xảy ra do lỗi ASR), "chủ nhật" không có nhưng "thứ hai"/"thứ 2" được thử trước "thứ ba"/"thứ 3" trong mảng bất kể vị trí trong câu. | — | — | ⚠️ (nhánh hiếm, ghi nhận cho đủ) |

---

## Bảng D — Định dạng giờ

4 regex, thử theo thứ tự cố định trong `TryDetectExplicitTime` (khớp đầu tiên thắng — xem Mục F).

| Mẫu | Regex | Ví dụ khớp | Ví dụ KHÔNG khớp | ⚠️ |
|---|---|---|---|---|
| Anh, 12h + am/pm | `\b(?:at\s+)?(\d{1,2})(?::([0-5]\d))?\s*(am\|pm)\b` | "3pm", "3 pm", "at 3:30pm", "9:15am" | "13pm" (giờ ngoài 1-12 → khối `if` bị bỏ qua, KHÔNG return, rơi xuống thử pattern kế tiếp — không crash) | |
| Anh, 24h + "at" | `\bat\s+([01]?\d\|2[0-3]):([0-5]\d)\b` | "at 15:00", "at 9:05" | **"15:00" không có chữ "at" phía trước** — hoàn toàn không được nhận diện | ⚠️ H.10 (thiếu định dạng 24h trần) |
| VN, `<n>h<mm>? <buổi>?` | `(\d{1,2})\s*h\s*(\d{2})?\s*(sáng\|trưa\|chiều\|tối\|khuya)?` | "3h", "3h30", "15h", "3h chiều" | "3h5" — phút chỉ nhận đúng 2 chữ số (`\d{2}`), 1 chữ số bị bỏ qua → phút mặc định 0, "5" thừa không được dùng | ⚠️ H.8 (không nhất quán số chữ số phút so với mẫu "giờ" bên dưới) |
| VN, `<n> giờ <mm>? <buổi>?` | `(\d{1,2})\s*giờ\s*(\d{1,2})?\s*(sáng\|trưa\|chiều\|tối\|khuya)?` | "3 giờ", "3 giờ 5" (phút=5, vì `\d{1,2}` chấp nhận 1 chữ số), "9 giờ sáng" | "3pm" (không phải mẫu VN) | ⚠️ H.8 |
| *(không có mẫu nào cho)* | — | "3pm30" kiểu lai, "15h00 chiều" (giờ 24h + buổi cùng lúc — vô nghĩa nhưng không bị chặn: nếu khớp, `ApplyVietnameseTimeOfDay(15, "chiều")` trả về 15 vì `hour < 12` sai → giữ 15, tình cờ đúng), ngày/tháng dạng số ("20/3", "3/20/2026"), tên tháng ("March 20", "20 tháng 3") | — | ⚠️ H.10 |
| Giờ hợp lệ VN | Sau khi regex khớp, `TryMatchVietnameseClock` còn kiểm tra `hour` trong khoảng 0-23 và `minute` ≤ 59 mới chấp nhận; nếu giờ/phút vô lý (ASR lỗi, "25h"), **match đầu tiên bị huỷ toàn bộ và hàm KHÔNG thử tìm match thứ hai hợp lệ trong cùng câu** — nhảy thẳng sang bảng "giờ" tiếp theo (VietnameseGioRegex) trên TOÀN VĂN BẢN, không phải phần còn lại sau vị trí lỗi. | — | — | ⚠️ H.9 |

---

## Bảng E — Từ khoá khác

### E.1 — Ưu tiên (`DetectPriority`)

| Từ khoá | Ý nghĩa | ⚠️ |
|---|---|---|
| `high priority`, `ưu tiên cao`, `quan trọng nhất` | Priority=1, confidence 0.85 | |
| `low priority`, `ưu tiên thấp`, `không gấp` | Priority=3, confidence 0.85 | |
| `medium priority`, `normal priority`, `ưu tiên trung bình` | Priority=2, confidence 0.8 | |
| `urgent`, `asap`, `critical`, `khẩn cấp`, `gấp` | Priority=1, confidence 0.72 | |
| `whenever`, `no rush`, `not urgent`, `rảnh thì làm`, `khi nào rảnh` | Priority=3, confidence 0.7 | |
| *(không nhắc gì)* | `null` — không tự fabricate mặc định | |
| Thứ tự thử | Phrase cụm-2-3-từ luôn thử TRƯỚC single-word — "high priority" thắng trước khi kịp thử "urgent" dù cả hai có thể cùng xuất hiện | |

### E.2 — Ước lượng thời lượng (`DetectEstimate`)

| Từ khoá / mẫu | Ý nghĩa | ⚠️ |
|---|---|---|
| `nửa tiếng`, `nửa giờ`, `half an hour`, `half hour` | 30 phút | |
| `một tiếng rưỡi`, `1 tiếng rưỡi`, `hour and a half`, `an hour and a half`, `1.5 hours`, `1.5 hour` | 90 phút | |
| Regex `(\d+)\s*(minutes?\|mins?\|hours?\|hrs?\|phút\|tiếng\|giờ)` | Số phút/giờ tường minh; đơn vị bắt đầu bằng `h`/`t`/`g` → nhân 60 (giờ), còn lại giữ nguyên (phút); giá trị phải 1–1440, kết quả cắt tối đa 1440 | Đơn vị `giờ` cũng dùng cho ước lượng LẪN cho giờ hẹn (Bảng D) — cùng một chữ trong 2 ngữ cảnh khác nhau, không nhầm lẫn về logic nhưng cần lưu ý khi đọc code |
| Hedge words: `chắc`, `có lẽ`, `khoảng`, `tầm`, `cỡ`, `maybe`, `probably`, `about`, `around`, `~` | Nếu xuất hiện trong 20 ký tự NGAY TRƯỚC vị trí khớp số → hạ confidence xuống 0.6/0.62 (thay vì 0.75/0.85) | Cửa sổ 20 ký tự là hằng số cứng, không theo từ/token — câu dài có thể lọt ra ngoài cửa sổ dù ý hedge vẫn rõ ràng |

### E.3 — Nhắc lại / reminder override (`DetectReminderOverride`)

| Từ khoá | Ý nghĩa | ⚠️ |
|---|---|---|
| Gate: phải chứa `remind` HOẶC `nhắc` ở đâu đó trong câu (kiểm tra nhanh trước khi chạy regex nặng hơn) | | |
| Regex `(?:remind(?:\s+me)?(?:\s+every)?\|nhắc(?:\s+lại)?\s+mỗi)\s+(\d+)\s*(minutes?\|mins?\|hours?\|hrs?\|phút\|giờ)` | Sinh `ReminderPolicy(offsets=[0], repeatEvery=interval)`, confidence cố định 0.8, giá trị phải 1–1440 | |

### E.4 — Lặp lại / recurrence (`DetectRecurrence`)

| Từ khoá | Ý nghĩa | ⚠️ |
|---|---|---|
| `every day`, `daily`, `mỗi ngày`, `hằng ngày`, `hàng ngày` | `Recurrence.Daily`, confidence 0.82 | |
| `every week`, `weekly`, `mỗi tuần`, `hằng tuần`, `hàng tuần` | `Recurrence.Weekly`, confidence 0.82 | |
| `every month`, `monthly`, `mỗi tháng`, `hằng tháng`, `hàng tháng` | `Recurrence.Monthly`, confidence 0.8 | |
| `every morning`, `mỗi sáng`, `every evening`, `mỗi tối` | Ánh xạ GẦN ĐÚNG sang `Recurrence.Daily`, confidence hạ còn 0.62 — comment trong code tự thừa nhận đây là xấp xỉ vì `Recurrence` không có khái niệm buổi-trong-ngày | Đã được code tự đánh dấu "flagged uncertain" — giữ nguyên |
| Regex `(?:every\|mỗi\|cứ)\s+(\d+)\s+(?:days?\|ngày)` | `Recurrence.Every(N)`, confidence 0.78, N phải 1–365 | |
| *(không nhắc gì)* | `null` | |

### E.5 — Phụ thuộc tác vụ khác / dependency (`DetectDependencyCondition`)

Thử theo đúng thứ tự này, khớp ĐẦU TIÊN có group ≥ 2 ký tự thắng (xem Mục F chi tiết thứ tự):

| # | Mẫu | Ví dụ → titleQuery | ⚠️ |
|---|---|---|---|
| 1 | `(?:after\|once)\s+(.+?)\s+is\s+done` (EN) | "after the contract is done" → "the contract" | |
| 2 | `when\s+(.+?)\s+is\s+done` (EN) | "when the build is done" → "the build" | |
| 3 | `sau\s+khi\s+(.+?)\s+xong` (VN) | "sau khi hợp đồng xong" → "hợp đồng" | |
| 4 | `(.+?)\s+xong\s+thì` (VN) | "hợp đồng xong thì" → "hợp đồng" | |
| 5 | `after\s+(.+?)(?=,\|\.\|$)` (EN, fallback chung) | "after lunch" → "lunch" | Rất rộng — bất kỳ "after X" nào không khớp pattern 1/2 đều rơi vào đây, kể cả khi ý người nói không phải là phụ thuộc tác vụ (vd "after lunch" có thể chỉ là mốc thời gian, không phải điều kiện chờ việc khác xong) |
| 6 | `sau\s+khi\s+(.+?)(?=,\|thì\|\.\|$)` (VN, fallback chung) | "sau khi ăn trưa" → "ăn trưa" | Tương tự pattern 5 |
| Confidence | `titleQuery` khớp fuzzy (chứa lẫn nhau, so khớp thô bằng `Contains`) với 1 trong các `openTaskTitles` → 0.78; không khớp → 0.55; `titleQuery` rỗng sau `Trim()` → 0.5 (nhánh gần như không thể xảy ra vì đã lọc `length <= 1` trước đó) | | |

### E.6 — Điều kiện bên ngoài / external (`DetectExternalCondition`)

| # | Mẫu | Ví dụ → description | ⚠️ |
|---|---|---|---|
| 1 | `waiting\s+(?:for\|on)\s+(.+?)(?=,\|\.\|$)` (EN) | "waiting for legal approval" → "legal approval" | |
| 2 | `(?:chờ\|đợi)\s+(.+?)(?=,\|\.\|$)` (VN) | "chờ khách duyệt giá" → "khách duyệt giá" | |
| Confidence | Số từ trong `description` (`Split(' ')`) ≤ 4 → 0.72; > 4 → 0.62 | Đếm từ bằng `Split(' ')` đơn giản — không xử lý dấu câu dính liền từ, có thể đếm sai với văn bản có dấu phẩy/chấm dính sát chữ |

### E.7 — Loại tác vụ / review + follow-up review (`DetectKind`, `DetectFollowUpReview`)

| Từ khoá | Ý nghĩa | ⚠️ |
|---|---|---|
| Bắt đầu bằng `review ` (EN) | `TaskKind.Review` | |
| Bắt đầu bằng `review after` (EN) | `TaskKind.Review` | **Dead/thừa**: mọi chuỗi bắt đầu bằng "review after" chắc chắn đã bắt đầu bằng "review " (7 ký tự đầu giống hệt) — điều kiện này KHÔNG BAO GIỜ tự nó bắt được case nào mà điều kiện phía trên chưa bắt. Không phải bug gây sai, chỉ là code thừa. ⚠️ H.11 |
| Chứa `" review after "` (EN, không ở đầu câu) | `TaskKind.Review` | Đây mới là điều kiện thực sự hữu ích cho case "review" không ở đầu câu, vd "please review after the meeting" |
| Bắt đầu bằng `xem lại ` (VN) | `TaskKind.Review` | CHỈ nhận diện khi "xem lại" ở ĐẦU câu — không có điều kiện "chứa ở giữa câu" tương đương bản tiếng Anh (không có `" xem lại "` contains-check) | ⚠️ (bất đối xứng EN/VN, xem H) |
| *(không khớp gì)* | `TaskKind.Task` (mặc định) | |
| `when done, review`, `when it's done, review`, `once done, review`, `then review it` (EN) | `FollowUpReview = true` | Danh sách cố định, không phải regex — biến thể khác (vd "once it's done, review it") KHÔNG khớp | |
| `xong thì xem lại`, `làm xong thì xem lại`, `xong rồi xem lại` (VN) | `FollowUpReview = true` | Cùng hạn chế — cụm cố định, không linh hoạt | |

### E.8 — Cắt tiêu đề (`CleanTitle`) — không hẳn "từ khoá" nhưng cùng nhóm "khác"

| Cụm mở đầu bị cắt (EN) | Cụm mở đầu bị cắt (VN) | ⚠️ |
|---|---|---|
| `remind me to `, `remember to `, `i need to `, `please remember to `, `please ` | `nhắc tôi `, `nhắc mình `, `làm ơn nhắc tôi `, `tôi cần `, `mình cần `, `nhớ ` | Chỉ cắt được lead-in ĐẦU TIÊN khớp trong mảng (theo thứ tự khai báo), dùng `StartsWith` sau khi lowercase — chỉ 1 lần, không lặp (vd "please please call" chỉ cắt 1 "please ") |
| Cụm trailing bị cắt sau dấu phẩy đầu tiên nếu phần đuôi chứa `priority`/`urgent`/`ưu tiên` | | Chỉ xét dấu PHẨY ĐẦU TIÊN trong toàn câu — nếu tiêu đề tự nhiên có dấu phẩy không liên quan đến priority đứng trước cụm ưu tiên thật sự (vd "buy milk, eggs, high priority"), dấu phẩy đầu tiên ("milk, eggs") được xét trước, thấy đuôi "eggs, high priority" (toàn bộ phần sau dấu phẩy ĐẦU TIÊN, không phải dấu phẩy cuối) — vì `tail` lấy TOÀN BỘ phần sau dấu phẩy đầu tiên (bao gồm cả các dấu phẩy sau đó), cụm "high priority" vẫn nằm trong `tail` nên vẫn bị phát hiện đúng và title bị cắt còn "buy milk". Đã kiểm tra kỹ — hành vi ĐÚNG, không phải bug, nhưng dễ đọc nhầm nên ghi chú lại. | |

---

## Mục F — Thứ tự ưu tiên giữa các rule

**Cấp cao nhất (`ParseOne`)** — các attribute sau được tính **độc lập, không loại trừ nhau**, tất
cả đều có thể cùng khớp trong 1 câu: `title`, `priority`, `estimateMinutes`, `recurrence`,
`reminderOverride`, `kind`, `followUpReview`.

**Ngoại lệ duy nhất — deadline vs. defer (loại trừ lẫn nhau):**
1. `DetectDeferCondition` được thử TRƯỚC.
2. Nếu có defer cue (VN: `mới làm`/`để tuần sau`/`để thứ`; EN: `not until`/`wait until`/regex
   `start(ing) (on) <thứ>|next week`) **VÀ** `ResolveDateToken` tìm được ngày/giờ → tạo
   `ParsedCondition.AfterDate`, **`deadline` bị bỏ qua hoàn toàn** (không tính nữa).
3. Nếu KHÔNG có defer cue → `DetectDeadline` được tính bình thường (gọi lại `ResolveDateToken` với
   cùng `text`).
4. Nếu CÓ defer cue nhưng `ResolveDateToken` không tìm được gì → không có condition nào được thêm,
   và `deadline` CŨNG không được tính (vì nhánh `else` không chạy) → task hoàn toàn không có
   ngày/giờ nào, dù người dùng có ý định defer.

**`DetectDependencyCondition` và `DetectExternalCondition`** được tính SAU, hoàn toàn độc lập với
cặp deadline/defer ở trên — **CẢ HAI đều có thể cùng được thêm vào `Conditions`**, cộng thêm với
`AfterDate` (nếu có) ở bước trên → một câu có thể sinh ra tối đa 3 `ParsedCondition` cùng lúc
(`AfterDate` + `TaskDone` + `External`) nếu văn bản chứa đủ 3 loại cue.

**Bên trong `ResolveDateToken`** (dùng chung cho cả deadline lẫn defer):
1. Quét từ khoá THỨ-TRONG-TUẦN (Bảng C) trước — dừng ở từ khoá đầu tiên khớp theo THỨ TỰ MẢNG, không
   phải theo vị trí xuất hiện trong câu.
2. Nếu chưa có `day`: quét cụm "ngày mai".
3. Nếu chưa có `day`: quét cụm "tuần sau/tới".
4. Nếu chưa có `day`: quét cụm "hôm nay".
5. Độc lập với 4 bước trên: `TryDetectExplicitTime` quét GIỜ tường minh trên toàn văn bản gốc
   (Bảng D, khớp đầu tiên trong 4 regex thắng).
6. Kết hợp: `baseDay = day ?? now`; nếu có giờ tường minh → áp giờ đó lên `baseDay` (+ áp quy tắc
   dời-ngày riêng cho "khuya" — xem Bảng A); nếu không có giờ nhưng có `day` → dùng `day` nguyên giờ
   của `now`; nếu không có cả hai → trả `null` (không có deadline nào).

**Bên trong dependency/external pattern list**: dùng `firstMatch` của TỪNG regex theo thứ tự mảng
cố định, dừng ở regex ĐẦU TIÊN cho kết quả capture-group hợp lệ (`length > 1` sau `Trim()`) — các
pattern cụ thể hơn ("...is done", "...xong") luôn đứng trước pattern chung chung ("after X", "sau
khi X") để tránh bị pattern rộng nuốt mất trước.

---

## Mục G — Khác biệt so với bản Swift

**G.1 — Khác biệt lớn nhất: toàn bộ kiến trúc phát hiện ngày/giờ bị đảo thứ tự, không chỉ thay thế 1-1**

Swift dùng `NSDataDetector(types: .date)` làm **tín hiệu ĐẦU TIÊN, tốt nhất** trong
`resolveDateToken` — nếu nó khớp được BẤT KỲ cụm ngày/giờ nào (theo chính comment trong Swift: có
khả năng hiểu cả "next Friday at 3", tên tháng, ngày-tháng dạng số... dù "English-locale-tuned...
unverified for Vietnamese"), nó thắng NGAY, và chỉ khi `NSDataDetector` không khớp gì thì mới rơi
xuống bảng từ khoá thứ-trong-tuần → rồi mới tới "tomorrow/next week/today".

Bản C# đảo ngược hoàn toàn thứ tự này: từ khoá thứ-trong-tuần được thử TRƯỚC, "tomorrow/next
week/today" thử THỨ HAI, và regex giờ tường minh (thay thế NSDataDetector) chạy **hoàn toàn độc lập**
làm lớp phủ GIỜ lên trên bất kỳ NGÀY nào đã chọn — chứ không phải một khối ngày+giờ hợp nhất do một
detector duy nhất trả về.

**Hệ quả trực tiếp:** bản C# **hoàn toàn không parse được** các cụm mà `NSDataDetector` (dù chỉ
"unverified" cho tiếng Việt) ít nhất có khả năng bắt được cho tiếng Anh: tên tháng ("March 20th"),
ngày-tháng dạng số ("3/20", "20/3/2026"), cụm tương đối phức tạp ("in 2 weeks", "next Friday at 3").
Đây là khoảng trống chức năng lớn nhất của bản port này so với Swift — xem H.10.

**G.2 — "khuya" hoàn toàn không tồn tại trong Swift**

Vì Swift dựa vào `NSDataDetector` cho mọi việc phát hiện giờ, KHÔNG hề có bảng ánh xạ từ-chỉ-buổi
(`sáng/trưa/chiều/tối/khuya`) nào trong file Swift gốc. Toàn bộ `ApplyVietnameseTimeOfDay` +
4 regex ở Bảng D + quy tắc dời-ngày cho "khuya" là **code hoàn toàn mới do agent W1-B tự thiết kế**
để bù cho việc thiếu `NSDataDetector`, không phải bản dịch của bất kỳ dòng Swift nào. Bug "khuya
+12" ban đầu (đã sửa trong phiên này) cũng nằm hoàn toàn trong phần code mới này.

Quy tắc dời-ngày cho "khuya" (mục Việc 1) được cài đặt **bên trong `ResolveDateToken` dùng chung**,
nên áp dụng cho CẢ deadline lẫn defer condition (`AfterDate`) — xem câu hỏi H.3.

**G.3 — Cơ chế tính "có giờ tường minh hay không" (confidence gate) khác nhau**

Swift: `hasTimeSignal` được suy ra từ chính CHUỖI KÝ TỰ mà `NSDataDetector` đã khớp (`matchedText`)
— kiểm tra xem chuỗi đó có chứa `:`, `" at "`, `am`, `pm` hay không.

C#: `IsExplicitTime` chỉ đơn giản là "có tìm được match nào trong 1 trong 4 regex Bảng D hay
không" — không dựa trên nội dung 1 detector chung, vì không còn detector chung nào cả (do G.1).

Cùng mục tiêu (gate giữa confidence 0.85 "chắc chắn" và 0.65 "mơ hồ, cần chip uncertain"), nhưng cơ
chế xác định khác hẳn — hệ quả thực tế là các case mà Swift có thể coi "có tín hiệu giờ" (nhờ
detector hiểu rộng hơn) nhưng C# lại không có regex nào khớp thì sẽ RƠI XUỐNG nhánh không có deadline
nào cả, chứ không phải chỉ hạ confidence.

**G.4 — Các mục XÁC NHẬN GIỐNG Y HỆT giữa 2 bản** (đối chiếu từng dòng, không có sai khác)

- Toàn bộ danh sách từ khoá priority (`highPhrases`/`highWords`/`lowPhrases`/`lowWords`/`mediumPhrases`) và confidence số đi kèm.
- Toàn bộ danh sách lead-in tiêu đề (EN + VN) và logic cắt trailing priority clause.
- `hedgeWords`, cửa sổ 20 ký tự lookback, ngưỡng confidence 0.6/0.62/0.75/0.85 của estimate.
- `weekdayKeywords` (7 thứ × các biến thể) và logic "trùng thứ hôm nay → +7 ngày, không bao giờ hôm nay".
- 6 pattern dependency và thứ tự thử, 2 pattern external và thứ tự thử, ngưỡng confidence 0.78/0.55/0.72/0.62.
- Toàn bộ bảng recurrence (`dailyPhrases`/`weeklyPhrases`/`monthlyPhrases`/`looseDailyPhrases`/`everyNDays`) và confidence.
- Reminder override: regex, ngưỡng 1–1440, confidence 0.8 cố định.
- Kind/review + followUpReview: cùng danh sách cụm cố định.
- `maxWorkingLength` = 8000, `maxTitleLength` = 300, `fallbackTitle` = "Untitled task".

**G.5 — Khác biệt hạ tầng, không ảnh hưởng hành vi**

Swift dùng `NSRegularExpression`/`NSDataDetector` cache trong `nonisolated(unsafe) static let`, kèm
comment "UNVERIFIED" về Swift 6 strict concurrency (cần Xcode/Mac để xác nhận, không thể build trên
Windows). C# dùng `[GeneratedRegex]` (source-generated `partial` method, thread-safe by construction,
không có vấn đề tương đương). Không phải khác biệt hành vi, chỉ là khác biệt cách cache/threading.

**G.6 — Cắt bỏ có chủ đích, đã ghi rõ trong doc comment của chính file C#**

- Bỏ entry-point `Parse(_ transcript: String)` không tham số (đọc `Date()` ngầm) — vi phạm quy tắc
  domain-purity của project Windows; thay bằng `Parse(transcript, now, timeZone)` luôn yêu cầu tham
  số tường minh.
- Bỏ conformance `IntentParser.breakdown(title:notes:)` — thuộc phạm vi wave khác (Volar.Parsing /
  W2-A), không phải việc của `Volar.Domain`.

---

## Mục H — Câu hỏi cho anh Khôi

**H.1 — "đêm" (đêm khuya, ban đêm) không được nhận diện là marker giờ.**
Regex marker chỉ chấp nhận `sáng|trưa|chiều|tối|khuya` — "đêm" hoàn toàn vắng mặt. "9h đêm" hiện tại
bị coi như KHÔNG có marker → giữ nguyên giờ literal (09:00), trong khi có lẽ người dùng muốn nói
21:00 (giống "tối"). Anh có muốn thêm "đêm" vào bảng không, và nếu có thì nó nên hoạt động giống
"tối" (+12 nếu <12) hay giống "khuya" (giữ nguyên, có thể dời ngày)?

**H.2 — "rạng sáng" và "nửa đêm" là cụm 2 từ, regex hiện tại KHÔNG THỂ khớp được** (marker chỉ nhận
1 token liền sau số giờ). Anh có muốn thêm 2 cụm này không? Nếu có, "rạng sáng" nên xử lý giống
"khuya" (giữ giờ literal + có thể dời ngày nếu đã trôi qua) hay khác?

**H.3 — Quy tắc dời-ngày cho "khuya" (đã implement theo yêu cầu) nằm trong hàm `ResolveDateToken`
dùng chung cho CẢ deadline lẫn defer condition (`AfterDate`).** Nghĩa là câu như "để 2h khuya mới
làm việc này" (defer, không phải deadline) cũng sẽ được áp cùng quy tắc dời-ngày nếu giờ đó đã trôi
qua. Yêu cầu gốc chỉ nói "deadline" — anh xác nhận việc áp dụng luôn cho defer là đúng ý không, hay
cần tách riêng?

**H.4 — Từ chỉ buổi đứng MỘT MÌNH (không đi kèm số giờ) không tạo ra giờ mặc định nào cả.**
Ví dụ "chiều mai" (tomorrow afternoon) — hiện tại chỉ set ngày = mai, còn giờ vẫn giữ nguyên giờ của
`now` (vì không có regex số giờ nào khớp) — KHÔNG tự động hiểu "chiều" nghĩa là ~14:00-15:00 hay bất
kỳ giờ mặc định nào. Anh có muốn thêm giờ mặc định cho từng buổi khi không có số giờ tường minh
không (vd sáng=8h, trưa=12h, chiều=14h, tối=19h, khuya=1h)? Đây có thể là gap khá lớn trong thực tế
sử dụng vì "chiều mai làm" là cách nói rất phổ biến.

**H.5 — Thiếu hoàn toàn: `mốt`/`ngày kia` (ngày mốt), `hôm qua`, `tháng sau`, `cuối tuần`.**
Không có dòng code nào xử lý các từ này (đối chiếu cả Swift lẫn C#, cả hai đều thiếu). Đây là những
từ chỉ ngày tương đối rất thông dụng trong giao tiếp hằng ngày. Anh có muốn bổ sung không, và nếu
có — "mốt"/"ngày kia" là +2 ngày đúng không? "cuối tuần" nên hiểu là thứ 7 tuần này/tuần sau tuỳ vào
hôm nay là thứ mấy — anh muốn quy tắc cụ thể nào?

**H.6 — Thứ trong tuần viết tắt (`t2`…`t7`, `cn`) và dạng không dấu (`thu 2`, `chu nhat`) hoàn toàn
không được nhận diện.** Việc brief ban đầu có nhắc tới các biến thể này — code hiện tại chỉ có dạng
đầy đủ có dấu (`thứ 2`, `thứ hai`). Anh có muốn bổ sung không? (Lưu ý: thêm dạng không dấu cần cẩn
thận vì `t2` có thể trùng với các chuỗi khác trong câu, dễ false-positive hơn "thứ 2".)

**H.7 — Khi câu vừa có cue defer VỪA có ngày/giờ không liên quan nằm chỗ khác trong câu,
`ResolveDateToken` quét TOÀN VĂN BẢN chứ không giới hạn quanh cụm defer** — ví dụ "để tuần sau làm,
nhưng cuộc họp là lúc 3h chiều thứ 6" có thể khiến "3h chiều thứ 6" bị gán làm ngày defer thay vì
"tuần sau" (vì từ khoá thứ-trong-tuần được quét trước cụm "tuần sau" — xem Bảng B thứ tự). Đây có
phải hành vi chấp nhận được, hay cần thu hẹp phạm vi quét quanh cụm cue?

**H.8 — Bất nhất số chữ số phút giữa 2 regex Vietnamese:** mẫu `<n>h<mm>` yêu cầu ĐÚNG 2 chữ số
phút (`\d{2}`) — "3h5" không bắt được phút; mẫu `<n> giờ <mm>` cho phép 1-2 chữ số (`\d{1,2}`) —
"3 giờ 5" bắt được phút=5. Anh có muốn thống nhất lại (cả hai đều cho phép 1-2 chữ số) không?

**H.9 — Nếu match "h" đầu tiên trong câu có giờ vô lý (vd lỗi ASR ra "25h"), toàn bộ nhánh regex
`<n>h<mm>` bị huỷ và code KHÔNG thử tìm match hợp lệ thứ hai trong cùng câu** — nhảy thẳng sang regex
"giờ" (một mẫu khác hẳn, không phải "thử tiếp trong cùng mẫu"). Nếu câu chỉ có đúng 1 cụm giờ hợp lệ
dạng "Xh" và nó đứng SAU cụm lỗi, cụm hợp lệ đó sẽ bị bỏ lỡ hoàn toàn. Đây có phải rủi ro thực tế
đáng sửa (khi ASR tạo ra nhiễu số) hay tần suất quá thấp để bỏ qua?

**H.9b (phụ)** — cụm "ngày mai" dạng `" mai "` yêu cầu khoảng trắng CẢ HAI bên; "mai" dính liền dấu
câu ngay sau nó (vd "...mai," không có khoảng trắng) có thể trượt qua toàn bộ 4 điều kiện của
`ContainsTomorrowCue`. Có cần nới lỏng để chấp nhận dấu câu ngay sau "mai" không?

**H.10 — Khoảng trống chức năng lớn nhất (xem G.1): hoàn toàn không parse được ngày tháng dạng số
hay tên tháng** ("20/3", "3/20/2026", "March 20th", "20 tháng 3", "in 2 weeks"). Đây là khác biệt so
với Swift lớn nhất trong toàn bộ file. Anh có muốn mở ticket riêng cho việc bổ sung parser ngày-tháng
tường minh không (nằm ngoài phạm vi Việc 1/2 của phiên làm việc này)?

**H.11 (rất nhỏ, không phải ⚠️ về ngữ nghĩa, chỉ là code sạch)** — điều kiện
`lower.StartsWith("review after")` trong `DetectKind` là dead code: mọi chuỗi thoả điều kiện này
chắc chắn đã thoả `lower.StartsWith("review ")` đứng ngay trước nó trong cùng biểu thức `||`. Không
ảnh hưởng hành vi, có thể xoá cho gọn khi có dịp — không cấp bách, chỉ ghi nhận.
