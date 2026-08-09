# App Store Connect — tờ khai điền metadata (Volar AI, macOS 1.0.0)

Gom mọi thứ **đã có sẵn trong repo** thành các ô đúng như App Store Connect hỏi, để copy-paste
thẳng. Ba loại đánh dấu:

- ✅ **CÓ SẴN** — lấy từ code/doc trong repo, dán được ngay.
- ✍️ **DỰ THẢO** — em soạn, anh Khôi đọc duyệt/sửa rồi dán.
- 🔴 **ANH KHÔI PHẢI CUNG CẤP** — repo không có và không suy ra được (số điện thoại, URL đã
  publish, ảnh chụp màn hình…). Danh sách gọn ở cuối file.

Không lặp lại: `docs/app-store-connect-checklist.md` (thao tác web), `docs/app-store-privacy.md`
(bảng privacy chi tiết), `docs/app-store-submission-guide.md` (thứ tự cổng, archive/upload).

---

## 1. App Information (khai một lần, dùng cho mọi version)

| Ô trong ASC | Giá trị | Nguồn |
|---|---|---|
| **Name** | `Volar AI` | ✅ `Info.plist` `CFBundleName`/`CFBundleDisplayName`, checklist §1 |
| **Subtitle** (≤30 ký tự) | `Say it. It becomes a task.` (26) | ✍️ |
| **Bundle ID** | `tech.kioh.Volar` | ✅ `Info.plist`, `project.yml` — **đóng băng, không đổi** |
| **SKU** | `volar-macos-001` | ✅ `appstore-connect-agent-instructions.md` §1 |
| **Primary Language** | English (U.S.) | ✅ cùng nguồn |
| **Primary Category** | Productivity | ✍️ |
| **Secondary Category** | Utilities | ✍️ — **đừng chọn Health & Fitness/Medical**, sẽ kéo app vào diện soi y tế (Guideline 1.4.1/5.1.3) chỉ vì có chữ ADHD |
| **Content Rights** | "Does not contain, show, or access third-party content" | ✍️ đúng thực tế: app không hiển thị nội dung bên thứ ba |
| **Age Rating** | Trả lời **None** hết mọi mục → **4+** | ✍️ không bạo lực/cờ bạc/nội dung người lớn/không UGC chia sẻ công khai/không web browser mở |
| **Privacy Policy URL** | `https://kioh.tech/volar/privacy` | ✅ hard-code trong `Volar/Sources/Views/PaywallView.swift:67` — 🔴 **phải kiểm URL này đã sống thật chưa**, ASC sẽ fetch |
| **License Agreement** | Apple's Standard EULA | ✍️ không có lý do dùng EULA riêng |

---

## 2. Version 1.0 — Metadata bán hàng

**Version number:** `1.0.0` — ✅ `Info.plist` `CFBundleShortVersionString` đã là `1.0.0`,
`CFBundleVersion = 1` (guide cũ nói còn `0.1.0`, đã lỗi thời).

**Copyright:** 🔴 cần tên pháp nhân — dạng `2026 <tên anh Khôi hoặc tên công ty>`.

### Promotional Text (≤170 ký tự, sửa được không cần review lại) — ✍️

```
Hold a hotkey, say what's on your mind, and Volar turns it into a task with a due date, a
reminder, and a clear answer to "what do I do next?"
```

### Description — ✍️ (bản dự thảo, đọc kỹ trước khi dán)

```
Volar AI turns a spoken sentence into a task — and then tells you which one to do next.

Most task apps stop at capture: you speak or type, and you get one more line in a list of
thirty. Volar goes one step further. It parses what you said into a real task — title, due
date, priority, estimated duration — and its engine picks the single next thing worth doing,
so you don't have to re-read your whole list to start working.

CAPTURE IN ONE BREATH
• Press Control-Option-M anywhere in macOS to start voice capture; press again to stop.
• Press Control-Option-T to type a task instead when you can't speak.
• Volar shows you what it understood before saving, so a mis-heard word never becomes a
  silent mistake.

ONE TASK AT A TIME
• The Today view answers "what now?" instead of showing a wall of rows.
• Focus mode puts the current task on screen and gets everything else out of the way.
• Break a task that feels too big into small steps you can actually start.

REMINDERS THAT SURVIVE A DISTRACTED MOMENT
• Set a reminder by voice, in the same sentence as the task.
• Tasks that are waiting on someone else stay out of your way until they're unblocked.
• Optional calendar mirroring: Volar creates its own calendar named "Volar" and mirrors your
  scheduled tasks into it. It never modifies events in calendars it did not create.

WORKS WITHOUT AN ACCOUNT
The core loop — capture, task, reminder, focus — needs no account and no network connection.
Signing in is optional and only unlocks the cloud features below.

FREE AND PRO
Free: every feature of the app, on-device speech recognition, and 12 cloud AI parses per day.
Pro: cloud speech recognition (faster and more accurate, and it handles mixed Vietnamese and
English), plus unlimited cloud parsing under fair use.
Pro is $6.99/month or $49.99/year, and starts with a 14-day free trial.

PRIVACY
No analytics SDK, no crash-reporting SDK, no advertising, no tracking. Nothing you record is
used to profile you. Cloud speech and cloud parsing are the only paths where content leaves
your Mac, and both are optional.
```

> ⚠️ **Lý do em không viết chữ "ADHD" vào description:** nói app dành cho ADHD trên App Store rất
> dễ bị đọc thành tuyên bố sức khoẻ và kéo theo yêu cầu chứng minh (Guideline 1.4.1). Định vị
> ADHD trong `docs/product-vision-v2.md` vẫn đúng cho marketing ngoài store; trong metadata App
> Store nên mô tả bằng hành vi ("một việc mỗi lần", "không phải đọc lại cả danh sách"). Nếu anh
> Khôi vẫn muốn có chữ ADHD, cách an toàn nhất là **keyword** (không phải câu tuyên bố trong
> description) và tuyệt đối không dùng từ "treat/therapy/symptom/diagnose".

### Keywords (≤100 ký tự, phân tách bằng dấu phẩy, KHÔNG có khoảng trắng) — ✍️

```
voice,todo,adhd,focus,reminder,dictation,productivity,speech,capture,menubar,planner,agenda
```
(89 ký tự. Không lặp từ đã có trong Name/Subtitle — Apple tự index chúng.)

### URLs

| Ô | Giá trị | Ghi chú |
|---|---|---|
| **Support URL** (bắt buộc) | 🔴 `https://kioh.tech/volar/support`? | phải là trang sống, có cách liên hệ. Thiếu/404 là reject |
| **Marketing URL** (tuỳ chọn) | `https://kioh.tech/products/volar` | ✅ nêu trong checklist §1 — 🔴 xác nhận đã publish |
| **Privacy Policy URL** | `https://kioh.tech/volar/privacy` | ✅ đã hard-code trong app; nếu URL này chết thì **nút trong Paywall cũng chết** |

### Screenshots — 🔴 anh Khôi phải chụp

macOS chấp nhận `1280×800` / `1440×900` / `2560×1600` / `2880×1800`, tối thiểu 1 ảnh.
Nên chụp 4–5 màn (đã có sẵn view trong code): `TodayView` (cửa sổ chính) · `CapturePanel`
(đang nghe + waveform) · `FocusOverlay` · `TaskBreakdownView` · `SettingsView`.
**Đừng** chụp mỗi icon nhỏ trên menu bar.

### What's New
Bỏ trống — version 1.0 không có ô này.

---

## 3. 🔴 App Review Information — phần anh Khôi hỏi tới

Đây đúng là mục "App Review Information" ở cuối trang version trong ASC.

| Ô | Giá trị |
|---|---|
| **Sign-in required** | ☑ **Yes** (app có tài khoản; không tick thì reviewer không có credential để test Pro) |
| **Demo — User Name** | 🔴 email test-OTP, dạng `review-8f3a2c@kioh.tech` (local-part khó đoán, theo guide §5.3) |
| **Demo — Password** | 🔴 mã 6 số cố định đã khai trong `[auth.email.test_otp]` của `supabase/config.toml` |
| **Contact — First / Last Name** | 🔴 |
| **Contact — Phone** | 🔴 (kèm mã quốc gia, `+84…`) |
| **Contact — Email** | 🔴 (hộp thư anh đọc thật — Apple gửi câu hỏi review vào đây) |
| **Attachment** | không bắt buộc |

### Notes — ✍️ bản dự thảo, dán nguyên

```
SIGNING IN (please read first)
The account field is an email one-time-code sign-in. The demo address above is configured as a
test account: no email is actually sent, and the fixed code below is accepted immediately.
Enter the demo email, then enter the code when prompted. This demo account already has a Pro
entitlement so you can review the paid features.

An account is NOT required to use the app. The core loop (capture, task, reminder, focus)
works fully signed-out and offline. Signing in only affects cloud speech and the cloud parsing
quota.

HOW TO CAPTURE A TASK
• Control-Option-M — global hotkey, press once to start voice capture, press again to stop.
  Speak a normal sentence, e.g. "call the dentist tomorrow at 3pm, ten minutes".
• Control-Option-T — global hotkey, opens a typed-capture box if you prefer not to speak.
• Both are also reachable from the mic button in the app window, so a review machine without a
  working microphone can still exercise the flow via typed capture.

MENU BAR
Volar is a normal app — it has a Dock icon, an app menu, and it opens its window at launch.
It ALSO lives in the menu bar: closing the window keeps it running there, and the menu bar
item reopens it. Quitting is Command-Q as usual.

FIRST-RUN DOWNLOAD (only if you switch engines)
The default speech engine is our cloud service. If you switch the engine to WhisperKit
(Settings › Speech), the app downloads a ~145 MB model from Hugging Face on first use. On a
slow connection this can take several minutes — the app is not frozen.

CALENDAR
Calendar access is requested for an optional feature that is OFF by default. When enabled,
Volar creates its own calendar named "Volar" and mirrors your scheduled tasks into it. The
code refuses to modify or delete any event it did not itself create (it verifies both the
calendar identifier and a marker URL it stamped on the event).

ACCOUNT DELETION (Guideline 5.1.1(v))
Settings › Account › "Delete account". It deletes the account server-side, not just locally.

IN-APP PURCHASE
Settings › Account (or the Pro screen) shows the Volar Pro subscription: $6.99/month or
$49.99/year, both with a 14-day free trial. Purchases use standard StoreKit; there are no
links out of the app to any alternative payment method.

PRIVACY
No analytics SDK, no crash reporter, no advertising, no tracking. Audio and text leave the
device only on the optional cloud speech and cloud parsing paths, and neither is retained.
```

> 🔴 **Hai câu trong Notes phải kiểm trước khi dán:**
> 1. *"This demo account already has a Pro entitlement"* — chỉ đúng sau khi đã insert tay
>    `tier='pro'` + `expires_at` xa vào bảng `entitlements` cho UUID của account demo
>    (backlog dòng 467, mục (3)). Chưa làm mà viết câu này là tự chuốc reject.
> 2. **"Connect Claude Code"** (`Sources/Orchestrator/ClaudeCodeConnector.swift`) — em **cố ý
>    không nhắc** trong Notes. Nếu tính năng này BẬT trong build submit thì phải thêm một đoạn
>    giải thích nó ghi vào `~/.claude/settings.json` qua NSOpenPanel do user tự chọn; guide
>    §5.2 khuyến nghị **tắt hẳn ở v1.0** cho nhẹ đầu. Anh Khôi chốt cái nào em sửa Notes theo.

---

## 4. App Privacy (nutrition label) — trả lời gọn

Chi tiết + lý do từng dòng nằm ở `docs/app-store-privacy.md`; dưới đây là bản rút để bấm nhanh.

| Data type | Collected? | Linked to identity | Tracking | Purpose |
|---|---|---|---|---|
| Contact Info › Email | Có (chỉ khi tạo account) | Có | Không | App Functionality |
| Identifiers › User ID | Có (Supabase UUID) | Có | Không | App Functionality |
| Identifiers › Device ID | **Không** (App Attest/DeviceCheck đã xoá hẳn) | — | — | — |
| Purchases | Có (tier, expiry, productId) | Có | Không | App Functionality |
| Audio Data | Có — **chỉ** trên đường cloud speech (Pro) | **Có** ⚠️ | Không | App Functionality |
| User Content (transcript) | Có — chỉ trên `/parse` cloud | Có | Không | App Functionality |
| Location, Contacts, Calendar, Health, Financial, Browsing/Search History, Analytics, Diagnostics, Advertising | **Không** | — | — | — |
| "Used to track you" (toàn app) | **Không** | | | |

⚠️ Dòng Audio Data "Linked: Yes" là **judgment call duy nhất** trong doc privacy — đó là lựa
chọn bảo thủ (request có bearer token nên quy được về account), anh Khôi xác nhận trước khi
finalize.

**Export compliance:** không phải trả lời thủ công — `ITSAppUsesNonExemptEncryption = false`
đã có sẵn trong `Info.plist`, mỗi lần upload ASC sẽ tự bỏ qua câu hỏi này.

---

## 5. Subscription metadata (khai trong Monetization ▸ Subscriptions)

Khớp 1:1 với `Volar/Volar.storekit` và `contracts/account-auth.md` §8 — sai một ký tự product ID
là nút mua trống trơn, không báo lỗi.

| | Monthly | Yearly |
|---|---|---|
| Reference Name | `Volar Pro Monthly` | `Volar Pro Yearly` |
| Product ID | `tech.kioh.Volar.pro.monthly` | `tech.kioh.Volar.pro.yearly` |
| Duration | 1 Month | 1 Year |
| Price | 6.99 USD (VN 149.000đ) | 49.99 USD (VN 449.000đ) |
| Family Sharing | Off | Off |
| Display Name (en-US) | `Volar Pro (Monthly)` | `Volar Pro (Yearly)` |
| Description (en-US) | `Cloud speech recognition and unlimited cloud parsing.` | `Cloud speech recognition and unlimited cloud parsing. Best value.` |
| Introductory Offer | Free Trial, 2 weeks, mọi territory | Free Trial, 2 weeks, mọi territory |
| **Review Screenshot** | 🔴 bắt buộc, mỗi product một ảnh — chụp `PaywallView` | 🔴 như trên |

Subscription group: `Volar Pro`. Auto-renewable **phải attach vào version 1.0** thì mới được
review cùng đợt.

---

## 6. 🔴 Danh sách anh Khôi phải cung cấp / xác nhận (gom một chỗ)

1. **Contact info** cho App Review: họ tên, số điện thoại có mã quốc gia, email đọc thật.
2. **Demo account**: email test-OTP + mã 6 số đã chốt (và đã `config push` chưa).
3. **Đã gán Pro cho account demo chưa** — quyết định câu Notes ở §3.
4. **Ba URL đã publish thật chưa**: privacy (app đang hard-code, chết là hỏng nút trong Paywall),
   support, marketing.
5. **Copyright** — tên pháp nhân/cá nhân ghi trên listing.
6. **Screenshots**: 4–5 ảnh app + 2 ảnh review screenshot cho 2 subscription.
7. **"Connect Claude Code" có ship ở v1.0 không** — quyết định thêm/bớt một đoạn trong Notes.
8. **Duyệt bản dự thảo** description / subtitle / keywords / notes ở trên, đặc biệt là quyết
   định có đưa chữ "ADHD" vào metadata App Store hay không.

---

## 7. Những thứ KHÔNG phải điền ở đây (kẻo tìm nhầm chỗ)

- **Export compliance questionnaire** — đã tắt bằng `ITSAppUsesNonExemptEncryption`.
- **Sáu entitlement sandbox** (`app-sandbox`, `network.client`, `device.audio-input`,
  `files.user-selected.read-write`, `files.bookmarks.app-scope`,
  `personal-information.calendars`) — khai trong `Volar.entitlements`, không có trong danh sách
  Capabilities của portal. Không thấy là ĐÚNG.
- **Paid Applications Agreement / bank account / tax form** — anh Khôi tự ký, và phải **Active**
  trước, nếu không `Product.products(for:)` trả mảng rỗng (guide Cổng 2.5).
