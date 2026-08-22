# Volar macOS — Runbook submit lên Mac App Store

Doc này là **thứ tự tổng** từ trạng thái hiện tại tới lúc bấm "Submit for Review", cộng phần
**archive/upload + bẫy review** mà 2 doc kia chưa phủ.

Không lặp lại nội dung của:
- `docs/app-store-connect-checklist.md` — mọi thao tác trên web (App ID, subscription group,
  Sign in with Apple, App Store Server API key). Doc đó vẫn đúng, dùng nguyên.
- `docs/app-store-privacy.md` — bảng trả lời App Privacy questionnaire.
- `docs/mac-verify-checklist.md` — runbook build & verify lần đầu trên Mac.

---

## Trạng thái xuất phát (2026-07-26) — đọc trước khi lập kế hoạch thời gian

| Thứ | Trạng thái |
|---|---|
| Code Swift | Viết 100% trên Windows, **chưa compile lần nào** |
| `Volar.xcodeproj` | Chưa tồn tại (phải `xcodegen generate`) |
| `VolarCore` test | Chưa từng chạy `swift test` |
| Backend Supabase | Migration `0002` **chưa apply**, function `subscription` **chưa deploy bao giờ** |
| StoreKit products | Chưa tạo trên ASC ⇒ nút mua không load được product |
| File `.storekit` local | Không có ⇒ chưa test được luồng mua |
| Info.plist / entitlements | **Đã đúng** (sandbox ON, mic, applesignin, LSUIElement, `volar://`) |
| App Store Connect | Chưa tạo app record |

Kết luận: khoảng cách tới submit **không đo bằng ngày**. Cổng 1 (build xanh) là ẩn số lớn nhất —
`FoundationModelParser.swift` có 8 marker `// UNVERIFIED` về API macOS 26.

---

## Cổng 1 — Build xanh + chạy được trên Mac

Theo `docs/mac-verify-checklist.md` mục A, đúng thứ tự. Tóm tắt:

```bash
cd VolarCore && swift build && swift test     # phải xanh trước tiên
cd ../Volar && xcodegen generate              # ra Volar.xcodeproj
open Volar.xcodeproj                          # build scheme Volar (Debug)
xcodebuild test -scheme Volar                 # test app-side
```

**Không đi tiếp khi chưa qua cổng này.** Mọi thứ dưới đây vô nghĩa nếu app chưa chạy.

Đặc biệt phải xử trước khi nghĩ tới submit:
- **Bug F1/F2 — ✅ đã fix trong code, CHƯA verify trên Mac.** Ba observer (`.volarTasksDidChange`,
  `.onOpenURL`, sleep/wake) đã dời từ scene `Window` sang `AppDelegate` (`VolarApp.swift` init +
  `applicationDidFinishLaunching`), nên không còn bị teardown khi user đóng cửa sổ.
  `docs/mac-verify-checklist.md` viết TRƯỚC lúc fix nên phần "Phát hiện tích hợp #1" của doc đó
  đã lỗi thời. Vẫn phải chạy bước 7 của runbook để xác nhận trên máy thật.
- **Cửa sổ có mở lúc launch thật không** — thứ tự scene mới (`Window` trước `MenuBarExtra`) chưa
  bao giờ được build. Đây là điều cần xác nhận đầu tiên khi mở Xcode.
- **`FoundationModels` trên macOS 14** — deployment target là 14.0 nhưng framework này là macOS 26.
  Xác nhận mọi call site có `@available`/`if #available` và app **không crash trên macOS 14/15**.
  Reviewer rất có thể chạy máy không phải macOS 26.

## Cổng 2 — Backend phải sống

Hiện tại backend còn ở thời device-auth, lệch hẳn với client (backlog mục 🔴🔴 đầu file).

```bash
supabase link --project-ref cjaamylayaylbuuhwlnz
supabase db push                                    # apply 0002 (hoặc 0003 nếu đã chốt schema MoR)
supabase functions deploy parse
supabase functions deploy groq
supabase functions deploy subscription              # CHƯA deploy bao giờ
supabase secrets unset PARSE_DEV_TOKEN              # 🔴 security, bắt buộc
```

⚠️ **Deploy từ nhánh `macos`**, không phải `window` — hai nhánh cùng có thư mục `supabase/` nhưng
chỉ có một project Supabase; deploy nhầm nhánh là ghi đè ngược.

### 🔴 SMTP — blocker submit mà chưa doc nào gọi tên

Supabase SMTP mặc định giới hạn **~2 mail/giờ**. Reviewer đăng nhập bằng email OTP, thử 2-3 lần là
bị chặn → họ kết luận "app không đăng nhập được" → **reject**. Phải cắm SMTP thật
(Resend/SendGrid/Postmark) vào Supabase Auth **trước khi submit**, không phải "sau khi có user".

## Cổng 2.5 — 🔴 HỢP ĐỒNG & NGÂN HÀNG (làm TRƯỚC mọi thứ liên quan tiền)

**Đây là thứ hay giết IAP nhất và không doc nào trong repo từng nhắc tới.** App Store Connect ▸
**Business** (trước gọi là *Agreements, Tax, and Banking*):

1. Ký **Paid Applications Agreement** (khác với Free Apps Agreement đã có sẵn khi mở tài khoản).
2. Điền **Bank Account** (tài khoản nhận tiền).
3. Điền **Tax Forms** — pháp nhân/cá nhân Việt Nam nộp **W-8BEN** (cá nhân) hoặc **W-8BEN-E**
   (công ty) cho phần thuế Mỹ.

**Chưa xong cả 3 thì `Product.products(for:)` trả về MẢNG RỖNG.** Không throw, không lỗi, không
log — nút mua chỉ đơn giản là trống trơn. Rất dễ mất mấy ngày đi soi code StoreKit trong khi code
hoàn toàn đúng. Nếu trên Mac thấy `appState.monthlyProduct == nil` mà mọi thứ khác đúng, kiểm mục
này TRƯỚC KHI nghi ngờ code.

Apple duyệt banking/tax không tức thì (thường vài giờ tới vài ngày). Làm sớm, đừng để tới lúc
sắp submit.

## Cổng 3 — Setup App Store Connect

Làm theo `docs/app-store-connect-checklist.md` §1–§8. Thứ tự phụ thuộc:
App ID (§2) → app record (§1) → subscription group (§4).

**⚠️ SỬA 2026-07-27 — bỏ bước "App Store Server API key":** `_shared/appstore.ts` **KHÔNG** gọi
App Store Server API; nó chỉ verify chữ ký JWS của giao dịch bằng root CA công khai của Apple. Ba
secret cần thiết (`APPSTORE_BUNDLE_ID`, `APPSTORE_ENVIRONMENT`, `APPSTORE_ROOT_CA_PEM`) **đã set
và verify xong 2026-07-27** — không phải tạo key `.p8` nào cả. Mục §5 của checklist cũ nói sai.

Nhắc lại 2 điều dễ quên trong đó:
- Subscription **auto-renewable phải được submit kèm build đầu tiên** thì mới được review cùng đợt.
  Tạo product xong mà không attach vào version là product sẽ ở trạng thái "Waiting for Review" mãi.
- `APPSTORE_ENVIRONMENT=Sandbox` khi test, đổi `Production` khi phát hành — sai giá trị này thì
  `/subscription/link` từ chối JWS thật.

## Cổng 4 — Archive & upload (phần chưa có doc nào)

### 4.1 Version number

`Info.plist` hiện là `CFBundleShortVersionString = 0.1.0`, `CFBundleVersion = 1`.

- Đổi `0.1.0` → **`1.0.0`** trước khi submit. `0.x` không sai luật nhưng đọc như bản chưa xong.
- `CFBundleVersion` **phải tăng nghiêm ngặt mỗi lần upload build**, kể cả khi bị reject và upload
  lại. Đây là lỗi vặt tốn thời gian nhất khi mới submit.

### 4.2 Thêm export-compliance vào Info.plist

Chưa có key này ⇒ mỗi lần upload ASC lại hỏi "app có dùng mã hoá không". Volar chỉ dùng HTTPS
tiêu chuẩn ⇒ được miễn. Thêm vào `Volar/Resources/Info.plist`:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

### 4.3 Signing

Xcode ▸ target Volar ▸ Signing & Capabilities:
- Team = tài khoản Developer Program của anh Khôi (**bắt buộc trả $99/năm**, chưa có thì đây là
  blocker cứng).
- Bật **Automatic manage signing** cho lần đầu — Xcode tự tạo cert "Apple Distribution" +
  provisioning profile, đỡ hẳn phần chứng chỉ thủ công.
- Xác nhận capability **Sign in with Apple** hiện diện thật (entitlement đã có sẵn trong
  `Resources/Volar.entitlements`, nhưng App ID trên portal cũng phải bật — checklist §2).
- Xác nhận **App Sandbox** hiện ON (đã có trong file entitlements — MAS bắt buộc, không được tắt).

### 4.4 Archive

```
Xcode ▸ Product ▸ Destination ▸ Any Mac
Xcode ▸ Product ▸ Archive
Organizer ▸ Distribute App ▸ App Store Connect ▸ Upload
```

**KHÔNG cần notarize.** Notarization chỉ dành cho bản phân phối ngoài store (Developer ID). Build
Mac App Store được Apple xử lý phía sau — đừng mất thời gian chạy `notarytool`.

Sau upload, build mất ~15–60 phút để hiện trong ASC ("Processing"). Nếu Apple gửi mail báo lỗi
entitlement/ICON thì sửa rồi tăng `CFBundleVersion`, archive lại.

### 4.5 App icon — ✅ đã làm 2026-07-26

`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` đã set, và `AppIcon.appiconset` đã có **đủ 10 size
macOS** (16 → 1024, cả @1x/@2x) — sinh từ bộ brand chính thức
`assets/Voci voice command app design.zip` ▸ `export-logo/volar-mark-app-1024.png` (squircle nền
tối + mark nón sáng bạc hà). Trước đó bộ icon còn là brand **dấu check vàng** cũ, lệch hẳn với
`Design/Theme.swift` đã migrate sang bảng màu bạc hà.

Tên file giữ nguyên nên `Contents.json` không phải sửa. Alpha được giữ (macOS cho phép trong suốt
ngoài squircle — khác iOS, iOS cấm alpha).

**Còn tinh chỉnh được (không chặn submit):** ở 16px/32px, icon là bản thu nhỏ nguyên xi nên đọc ra
"ô vuông tối + chấm xanh nhỏ", cái nón mờ gần như biến mất. README của bộ brand tự quy định
*"16px — dưới mức này bỏ halo, chỉ giữ nón + chấm"*, tức designer đã lường trước và muốn có bản
vẽ riêng cho size nhỏ. Muốn sắc nét ở menu bar/Finder list thì vẽ tay 2 file `icon_16x16.png` và
`icon_32x32.png` theo đúng quy tắc đó. Apple không reject vì việc này.

## Cổng 5 — Metadata & App Review Information

### 5.1 Screenshots

macOS yêu cầu ít nhất 1 bộ, chấp nhận `1280×800` / `1440×900` / `2560×1600` / `2880×1800`.
Volar là app menu bar nên đừng chụp mỗi cái icon nhỏ trên thanh — chụp cửa sổ chính, popover
capture, focus overlay, Settings.

### 5.2 🔴 Review notes — phần quyết định đậu/rớt

App này có **4 đặc điểm mà reviewer chắc chắn sẽ vấp** nếu không được báo trước. Viết hết vào ô
"Notes" của App Review Information:

1. ~~**`LSUIElement = true`**~~ — ✅ **ĐÃ XỬ 2026-07-26, không còn phải cảnh báo.** Anh Khôi chốt
   bỏ `LSUIElement` khỏi `Info.plist` và đảo thứ tự scene trong `VolarApp.swift` (`Window` lên
   trước `MenuBarExtra`) ⇒ Volar giờ là app bình thường: có Dock icon, có app menu, **tự mở cửa sổ
   lúc launch**, vẫn giữ nguyên menu bar item. Rủi ro reject "app does not launch" biến mất, và
   ⌘Q/⌘W/⌘, chạy đúng (trước đây không có app menu nên chúng không hoạt động).
   Vẫn nên ghi một dòng trong Notes: *"Volar also lives in the menu bar; closing the window keeps
   it running there."* — để reviewer không nghĩ đóng cửa sổ là thoát app.
2. **Hotkey** — ghi đúng tổ hợp phím mặc định để bắt đầu capture, kèm câu "hold to talk / press to
   toggle" cho đúng hành vi thật.
3. **WhisperKit tải model lần đầu (~145MB từ HuggingFace)** — trên máy sạch + mạng chậm, lần đầu
   dùng có thể lâu. Ghi trước để reviewer không tưởng app treo.
4. **"Connect Claude Code"** — nếu tính năng này bật trong bản submit: nó ghi vào
   `~/.claude/settings.json` **qua NSOpenPanel do user tự chọn** (entitlement
   `files.user-selected.read-write`, không phải truy cập tuỳ tiện). Nếu không giải thích, reviewer
   thấy app sửa file config của app khác là sẽ hỏi. **Cân nhắc tắt tính năng này ở bản v1.0** cho
   nhẹ đầu.

### 5.3 Demo account — dùng Supabase **test OTP** (anh Khôi chốt 2026-07-26)

Reviewer **phải đăng nhập được** để test Pro. Vấn đề: email OTP gửi mã về hộp thư mà reviewer
không có; còn Sign in with Apple thì họ tạo ra account `free` mới toanh, không thấy tính năng Pro.

**Giải pháp đã chốt:** dùng tính năng **test OTP** có sẵn của Supabase Auth — khai một cặp
(email, mã cố định); với đúng địa chỉ đó Supabase **không gửi mail** và chấp nhận luôn mã cố định.
Đây là feature Supabase dựng ra chính cho app-store review, không phải hack.

**KHÔNG cần sửa client.** Reviewer nhập email demo → app gọi `/auth/v1/otp` như thường (không có
mail nào được gửi) → nhập mã cố định → app gọi `/auth/v1/verify` → pass. Cả `AccountService` lẫn
edge function không biết và không cần biết có gì khác.

Cấu hình (`supabase/config.toml`):

```toml
[auth.email.test_otp]
"review@kioh.tech" = "000000"
```

rồi `supabase config push` (project đã link).

> ⚠️ **Bẫy của `config push`:** lệnh này đẩy **toàn bộ** khối config, không chỉ phần vừa thêm.
> Field nào không khai trong `config.toml` sẽ bị đặt về mặc định của CLI — có thể tắt provider
> hoặc đổi setting anh đã chỉnh tay trên dashboard. **Trước khi push: chụp lại màn hình
> Authentication ▸ Providers / Sign In hiện tại, push xong đối chiếu lại từng mục** (nhất là
> Apple provider ở checklist §3 và SMTP). Nếu dashboard của project có sẵn ô test OTP thì dùng
> đường dashboard, an toàn hơn.

**Chọn email và mã:** cặp này là một cửa hậu vĩnh viễn cho đúng địa chỉ đó — ai biết cặp
(email, mã) đều đăng nhập được vào account demo. Thiệt hại tối đa là một account Pro miễn phí
(account demo không chứa dữ liệu thật), nên rủi ro thấp, nhưng vẫn nên:
- dùng local part **không đoán được** (vd `review-8f3a2c@kioh.tech`) thay vì `review@`/`demo@`;
- cân nhắc mã 6 số ngẫu nhiên thay vì `000000` — cùng công sức, đỡ bị dò mù.

Giữ nguyên cặp này sau khi được duyệt: mỗi bản update Apple lại review lại, xoá đi là lần sau
phải dựng lại.

**Vẫn phải làm 2 việc kèm:**
1. **Gán tay Pro cho account demo** — sau khi account tồn tại, insert vào `entitlements`:
   `tier='pro'`, `expires_at` xa (vd 2030), `user_id` = UUID của account đó. Không có bước này
   reviewer đăng nhập được nhưng vẫn là `free`, không thấy cloud speech.
2. **Sandbox tester** cho luồng mua thật: ASC ▸ Users and Access ▸ Sandbox Testers.

Điền vào ô Demo Account của ASC: email demo + mã cố định, kèm một dòng
*"Sign in with this email; enter the code below when prompted (no email will be sent)."*

**Hệ quả tốt:** reviewer không đụng tới SMTP nữa ⇒ SMTP thật (§Cổng 2) **hạ từ blocker-submit
xuống blocker-launch**. Vẫn phải làm trước khi có user thật, nhưng không còn chặn ngày submit.

### 5.4 Guideline bắt buộc

- **5.1.1(v) — xoá tài khoản trong app**: phải có nút thật ở Settings ▸ Account, bấm được, và
  account biến mất khỏi `auth.users`. Thiếu là reject chắc chắn. Tự bấm thử trên Mac trước khi
  submit, đừng tin contract.
- **3.1.1 — không steer**: trong app Mac tuyệt đối không có link/chữ nào dẫn user ra web mua rẻ
  hơn. (Web checkout cho Windows vẫn hợp lệ nhờ 3.1.3(b) — xem backlog mục monetization.)
- **App Privacy**: điền theo `docs/app-store-privacy.md`, chú ý mục "Linked to identity" cho Audio
  Data (khuyến nghị: Yes).

---

## Thứ tự tối thiểu, gọn lại

1. Trả $99 Developer Program (nếu chưa).
2. Cổng 1: build xanh + fix F1/F2 + xác nhận không crash trên macOS 14/15.
3. Cổng 2: `db push` + deploy 3 function + unset `PARSE_DEV_TOKEN` + **cắm SMTP thật**.
4. Cổng 3: App ID → app record → subscription group → App Store Server API key.
5. Test mua bằng file `.storekit` local, rồi bằng Sandbox tester thật.
6. Cổng 4: version 1.0.0 + `ITSAppUsesNonExemptEncryption` + Archive → Upload.
7. Cổng 5: screenshots + review notes 4 điểm + demo account có webmail + privacy label.
8. Submit.
