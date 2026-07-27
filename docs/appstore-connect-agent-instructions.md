# Instruction cho Claude in Chrome — setup App Store Connect cho Volar

> Copy toàn bộ phần trong khung `---` bên dưới và đưa cho Claude in Chrome.
> Phần ngoài khung là ghi chú cho anh Khôi, đừng gửi đi.

## Ghi chú cho anh Khôi (KHÔNG gửi cho agent)

**Ba việc dưới đây agent KHÔNG được làm hộ, và instruction đã cấm tường minh:**

| Việc | Vì sao anh phải tự làm |
|---|---|
| Ký **Paid Applications Agreement** | Là hợp đồng pháp lý ràng buộc anh với Apple. Không giao cho automation bấm "Agree" thay mình. |
| Điền **Bank Account** | Số tài khoản nhận tiền. Agent không có, và không nên có. |
| Điền **Tax Forms** (W-8BEN / W-8BEN-E) | Khai thuế có chữ ký điện tử, khai sai là vấn đề của anh với IRS. |
| Bấm **Submit for Review** | Nộp bản build đi review là quyết định của anh, không phải của agent. |

Agent chỉ làm phần **cấu hình lặp đi lặp lại, nhiều field, dễ gõ sai**: app record, subscription
group, 2 product, sandbox tester. Đó đúng là chỗ automation có ích.

**Sau khi agent xong, anh gửi lại cho em 2 thứ:**
1. **App Apple ID** (dãy số ~10 chữ số) — em cần set `APPSTORE_APP_APPLE_ID` khi chuyển Production.
2. Trạng thái từng product (Ready to Submit / Missing Metadata).

---

Bạn đang thao tác trên **App Store Connect** (appstoreconnect.apple.com) cho một ứng dụng **macOS**
tên **Volar**. Chủ tài khoản đã có sẵn Apple Developer account.

## Nguyên tắc bắt buộc

1. **TUYỆT ĐỐI KHÔNG** ký bất kỳ hợp đồng nào (Paid Applications Agreement hay bất kỳ agreement
   nào khác), **KHÔNG** điền thông tin ngân hàng, **KHÔNG** điền/ký tax form (W-8BEN, W-8BEN-E…),
   **KHÔNG** bấm "Submit for Review" hay "Submit to App Review". Nếu một bước nào đó đòi những
   việc này, hãy **DỪNG LẠI và báo cáo** cho người dùng làm tay.
2. Không xoá, không đổi, không "dọn dẹp" bất cứ thứ gì đã tồn tại sẵn. Chỉ tạo cái được yêu cầu.
3. Nếu gặp màn hình xác nhận không chắc chắn, hoặc một field không có trong hướng dẫn này, **dừng
   và hỏi** thay vì đoán.
4. Sau mỗi bước lớn, chụp lại trạng thái và báo ngắn gọn đã làm gì.

## Bước 0 — Kiểm tra tiền đề (chỉ ĐỌC, không sửa)

Vào **App Store Connect ▸ Business** (tài khoản cũ có thể hiển thị là *Agreements, Tax, and
Banking*) ▸ tab **Agreements**.

Đọc trạng thái dòng **Paid Applications** và báo cáo chính xác nó đang là gì (ví dụ: *Active*,
*Pending*, *Request*, hoặc chưa tồn tại).

- Nếu **Active** → đi tiếp Bước 1.
- Nếu **KHÔNG** Active → **DỪNG TOÀN BỘ**, báo cáo trạng thái đó và nói rõ với người dùng rằng họ
  phải tự ký hợp đồng + điền banking + tax form, vì nếu chưa Active thì các product tạo ra sẽ
  không bao giờ load được trong app. Đừng tạo gì thêm.

## Bước 1 — App record

Vào **My Apps**. Kiểm tra đã có app nào tên **Volar** hoặc có bundle ID `tech.kioh.Volar` chưa.

- **Nếu đã có:** ghi lại **App Apple ID** (dãy số hiện ở mục App Information) rồi sang Bước 2.
- **Nếu chưa có:** bấm **+** ▸ **New App**, điền:
  - **Platforms:** chỉ tick **macOS** (KHÔNG tick iOS)
  - **Name:** `Volar`
  - **Primary Language:** English (U.S.)
  - **Bundle ID:** chọn `tech.kioh.Volar` trong danh sách.
    → Nếu bundle ID này **không có** trong danh sách, DỪNG và báo cáo: người dùng cần tạo App ID
    đó trong Developer portal (Certificates, Identifiers & Profiles ▸ Identifiers) và bật khả năng
    **In-App Purchase** cho nó trước.
  - **SKU:** `volar-macos-001`
  - **User Access:** Full Access

Sau khi tạo xong, vào **App Information** và **ghi lại App Apple ID** (dãy số ~10 chữ số). Đây là
thông tin quan trọng nhất cần báo lại.

## Bước 2 — Subscription group

Trong app Volar ▸ mục **Subscriptions** (sidebar bên trái, phần Monetization).

Tạo **Subscription Group** mới:
- **Reference Name:** `Volar Pro`

Nếu group `Volar Pro` đã tồn tại thì dùng lại, không tạo trùng.

## Bước 3 — Tạo 2 subscription

Trong group `Volar Pro`, tạo **hai** subscription. Cả hai đều **auto-renewable**.

### 3.1 — Gói tháng

| Field | Giá trị |
|---|---|
| Reference Name | `Volar Pro Monthly` |
| Product ID | `tech.kioh.Volar.pro.monthly` |
| Subscription Duration | 1 Month |
| Price | **6.99 USD** (chọn price point tương ứng ở storefront United States) |
| Family Sharing | **Tắt** |

**Localization (English (U.S.)):**
- Display Name: `Volar Pro (Monthly)`
- Description: `Cloud speech recognition and unlimited cloud parsing.`

**Introductory Offer:**
- Territory: tất cả các nước đang bán
- Type: **Free Trial**
- Duration: **2 weeks** (tức 14 ngày)

### 3.2 — Gói năm

| Field | Giá trị |
|---|---|
| Reference Name | `Volar Pro Yearly` |
| Product ID | `tech.kioh.Volar.pro.yearly` |
| Subscription Duration | 1 Year |
| Price | **49.99 USD** |
| Family Sharing | **Tắt** |

**Localization (English (U.S.)):**
- Display Name: `Volar Pro (Yearly)`
- Description: `Cloud speech recognition and unlimited cloud parsing. Best value.`

**Introductory Offer:** giống hệt gói tháng — Free Trial, **2 weeks**.

> **Product ID phải khớp CHÍNH XÁC từng ký tự**, kể cả chữ hoa/thường. Ứng dụng tìm product theo
> đúng hai chuỗi này; sai một ký tự là nút mua trong app trống trơn và không có thông báo lỗi nào.
> Product ID **không sửa được sau khi tạo** — kiểm lại trước khi lưu.

## Bước 4 — Review Screenshot cho từng subscription

Mỗi subscription bắt buộc phải có một **Review Screenshot** thì mới hết trạng thái *Missing
Metadata*.

Bạn **không tự tạo được ảnh này**. Hãy kiểm tra xem field đó đã có ảnh chưa:
- Nếu đã có → bỏ qua.
- Nếu chưa có → **báo cáo cho người dùng** rằng cần họ upload một ảnh chụp màn hình giao diện mua
  hàng của app, cho **cả hai** subscription. Đừng cố tải ảnh từ nguồn khác lên.

## Bước 5 — Sandbox Tester

Vào **Users and Access ▸ Sandbox ▸ Test Accounts** (một số tài khoản hiển thị là *Sandbox Testers*).

Kiểm tra đã có tester nào chưa. Nếu chưa, **hỏi người dùng một địa chỉ email chưa từng dùng cho
Apple ID nào** rồi mới tạo — bạn không được tự bịa email. Sau khi có email, tạo tester với:
- Region: Vietnam (hoặc United States nếu người dùng muốn test giá USD)
- Mật khẩu: để người dùng tự đặt và tự lưu

## Bước 6 — Báo cáo

Báo cáo lại đúng những mục sau, không thêm suy đoán:

1. **App Apple ID** (dãy số) — bắt buộc.
2. Trạng thái dòng **Paid Applications** ở Bước 0.
3. Với mỗi subscription: product ID, giá, trial, và **trạng thái hiện tại** (*Ready to Submit* /
   *Missing Metadata* / khác). Nếu *Missing Metadata*, ghi rõ đang thiếu field nào.
4. Sandbox tester đã tạo chưa, email gì (nếu có).
5. Bất kỳ bước nào bạn đã DỪNG lại và lý do.

**Nhắc lại lần cuối:** không ký hợp đồng, không nhập thông tin ngân hàng, không điền tax form,
không submit for review. Gặp mấy thứ đó thì dừng và báo.
