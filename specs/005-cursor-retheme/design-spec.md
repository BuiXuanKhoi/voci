# Volar × Cursor — macOS redesign spec ("Volar Graphite")

Ngày: 2026-08-07 · Phạm vi: **chỉ macOS** (`Volar/Sources/**`) · Nhánh: `macos`
Người chốt hướng: anh Khôi (chọn cả 4 tầng: pattern tương tác + shell + da/bảng màu + density/typography)

Supersedes: RETHEME 2 "Volar Twilight" (2026-07-26) về **giá trị màu ink/hairline/text**.
KHÔNG supersede: luật NOW-spotlight, luật cấm đỏ, họ mint của logo.

---

## 0. Luận điểm — mượn gì, và vì sao

Cursor là IDE: **graphite trung tính, phẳng tuyệt đối (không blur), viền gần như vô hình,
bo góc nhỏ, mật độ chặt, một accent duy nhất.** Volar là app capture voice-first cho ADHD,
lõi thị giác là *một thứ được rọi sáng, phần còn lại chìm*.

Hai thứ này hợp nhau hơn là chống nhau, vì một lý do: **nền xám trung tính là nền tốt nhất
cho một điểm sáng có màu.** Nền xanh đêm hiện tại cùng họ lạnh với mint nên đang "kéo" mất
một phần spotlight. Đổi ink sang graphite làm mint nổi hơn, không phải yếu đi.

**BỐN LUẬT KHÔNG ĐƯỢC PHÁ** (giữ nguyên từ Twilight):
1. Mint (`nowAccent`) chỉ dành cho **một** task NOW. Hai thứ mint trên một màn hình = sai một cái.
2. **Không bao giờ dùng đỏ** cho trạng thái task (overdue, trễ hạn, diff removed). Chỉ `destruct`
   cho hành động phá huỷ không hoàn tác được (nút Delete).
3. Xanh băng (`instrument`) = thông tin. Không bao giờ là spotlight.
4. Không có animation `.repeatForever` trong view host bởi MenuBarExtra/NSStatusItem.

**Luật mới của pass này:**
5. **Phẳng là mặc định.** Blur chỉ được phép ở bề mặt *thật sự nổi trên desktop*: popover
   menubar và `FocusOverlay`. Mọi panel nằm trong cửa sổ chính đều phẳng, đục.

---

## 1. Token — `Volar/Sources/Design/Theme.swift`

Tên token **không đổi một chữ nào** (mọi call site vẫn compile). Chỉ đổi giá trị.

### 1.1 Ink / depth

| Token | Cũ (Twilight) | Mới (Graphite) | Vai trò |
|---|---|---|---|
| `bg` | `0x07090E` | `0x0F0F11` | Nền cửa sổ chính, sâu nhất |
| `surface` | `0x0A101C` | `0x16161A` | Sidebar + panel nổi 1 bậc |
| `surfaceHi` | `0x101827` | `0x1E1E23` | Card / input / hover panel |

Quan hệ độ sáng giữ nguyên chiều cũ (`bg` < `surface` < `surfaceHi`) — sidebar vẫn sáng hơn
main column, không lật ngược app.

Ba giá trị này gần như trung tính (R≈G, B nhỉnh hơn 2 đơn vị) — đủ để mắt không đọc ra
"xám chết" mà vẫn không có cast xanh.

### 1.2 Hairline / veil — **đổi base về trắng**

Twilight đổi base veil sang xanh lạnh `0x94B2E0` vì phủ trắng lên nền xanh đêm làm xám bệt.
Nền giờ *đã là* xám trung tính, nên lý do đó biến mất — quay về trắng, đúng cách Cursor làm.

```swift
static let card      = Color.white.opacity(0.035)
static let cardHover = Color.white.opacity(0.06)
static let border    = Color.white.opacity(0.07)   // cũ 0.10 xanh
static let borderHi   = Color.white.opacity(0.12)  // cũ 0.18 xanh
static func veil(_ opacity: Double) -> Color { Color.white.opacity(opacity) }
```

`veil` về đúng công thức nguyên bản trước Twilight → **~40 call site không cần sửa gì**.
Alpha border hạ xuống (0.10→0.07, 0.18→0.12) là điểm Cursor nhất trong toàn bộ pass: phân
tách bằng chênh lệch fill, không bằng đường kẻ.

### 1.3 Text

| Token | Cũ | Mới | Contrast vs `bg` |
|---|---|---|---|
| `textPri` | `0xEDF2F9` | `0xE8E8EA` | 15.7:1 — AAA |
| `textSec` | `0x9AA7BC` | `0xA1A1A8` | 7.5:1 — AAA |
| `textMut` | `0x57637C` | `0x6B6B74` | 3.6:1 — tertiary only, cố ý dưới AA body |

(Đã tính tay theo WCAG relative luminance; ghi lại số vào doc comment như file cũ đang làm.)

### 1.4 GIỮ NGUYÊN — không đụng vào

- Toàn bộ họ mint: `nowAccent`, `nowAccentSoft`, `nowAccentDeep`, `nowGlow`, `nowGlowSoft`, `nowRing`.
  Đây là logo, và là lý do tồn tại của spotlight.
- `instrument` `0x86B9FF`, `instrumentDim` — **cố ý giữ**. Nó đã được tinh chỉnh để đứng cạnh
  mint mà không cạnh tranh; đổi lúc này là thêm một tín hiệu sáng thứ hai, rủi ro không đáng.
- Ramp priority `high`/`med`/`low`, `done`, `destruct`, `reschedule`. Trên nền graphite, ramp
  ấm này thành thứ **duy nhất** ấm trên màn hình → phân tầng còn rõ hơn trước (ấm = ưu tiên,
  lạnh = thông tin, mint = NOW).
- `VolarAccent` cả 4 family — giá trị hex không đổi (persisted by rawValue).

### 1.5 Glass — phẳng hoá

`GlassLevel.bgOpacity` là chỗ duy nhất cần đổi; không thêm case mới (tránh vỡ switch).

```swift
case .subtle:   return 1.00   // cũ 0.92 — phẳng hoàn toàn
case .standard: return 0.97   // cũ 0.78 — material còn nhưng gần như vô hình
case .heavy:    return 0.80   // cũ 0.55 — vẫn kính, dành cho bề mặt nổi trên desktop
```

Mapping này đã đúng sẵn theo ngữ nghĩa cũ (blur nặng = tint nhạt = kính hơn).

> **Sonnet phải verify trước khi sửa:** grep mọi call site `volarGlass(` / `GlassBackground(`
> và liệt kê `level` từng chỗ. Panel trong cửa sổ chính phải là `.subtle`/`.standard`;
> popover menubar + `FocusOverlay` phải là `.heavy`. **Chỗ nào lệch thì báo lại, đừng tự đổi**
> — đổi level là đổi ngữ nghĩa, không phải đổi màu.

### 1.6 Bo góc — bảng quy đổi toàn app

| Nơi | Cũ | Mới |
|---|---|---|
| `GlassBackground` default `cornerRadius` | 12 | **8** |
| `volarHairline` default | 9 | **6** |
| `TaskRow` | 9 | **6** |
| `ToolButton`, `SidebarItem`, `ProSidebarRow`, `CaptureButtonStyle`, footer sidebar | 7 / 9 | **5** |
| `KeyBadge` | 5 | **4** |
| Capsule (`PriorityBadge`, `TimeBadge`) | Capsule | **RoundedRectangle 5** — Cursor không có pill |

### 1.7 Density — chặt lại

```swift
rowPadY:     cozy 5  · comfy 8  (cũ 10) · roomy 12 (cũ 14)
rowGap:      cozy 2  · comfy 3  (cũ 4)  · roomy 5  (cũ 6)
sectionGap:  cozy 14 · comfy 18 (cũ 22) · roomy 26 (cũ 30)
```

Mặc định vẫn `.comfy`.

---

## 2. Typography

Giữ SF Pro / SF Mono, giữ mọi size hiện có **trừ** một luật mới:

**Luật mono:** mọi con số người dùng *so sánh hoặc đọc như số đo* phải là `Font.volarMono` +
`.monospacedDigit()`. Cụ thể: count ở `SidebarItem` và `SectionHeader`, `durationLabel` và
`timeBadge` ở `TaskRow`, timer/estimate ở `FocusOverlay` và `TaskDetailView`, WIP counter.
Chữ UI thường (title task, label nav, body copy) **không** đổi sang mono.

`SectionHeader` giữ uppercase + tracking — VS Code/Cursor cũng làm y hệt ở explorer.

---

## 3. Shell (vỏ layout)

### 3.1 Sidebar — `Sidebar.swift`
- Width `160` → **172** (Cursor thoáng hơn ở cột trái dù dày ở list).
- Đường kẻ phải: giữ, nhưng nó tự động mảnh đi vì `border` đã hạ alpha. Không sửa code.
- `sidebarBackground`: nhánh `ambient != .none` giữ nguyên; nhánh thường giữ `VolarColor.surface`.
- `SidebarItem`: radius 7→5, `padding(.vertical, 6)` → **5**. Count sang `volarMono`.

### 3.2 Toolbar — `TodayView.swift` + `Components.swift`
`ToolButton` phẳng hoá: radius 7→5, bỏ nền khi idle (đã đúng: `.clear`), hover `veil(0.06)`.
Biến thể `accent: true` (nút `+`) giữ fill accent — đây là primary action duy nhất trên toolbar.

### 3.3 Cột phải — **quyết định cần anh Khôi duyệt riêng, CHƯA làm ở pass này**
`TaskDetailView` hiện là `.sheet` (modal). Kiểu Cursor là **inspector panel bên phải, thu gọn được**.
Đây là cải thiện thật cho ADHD (sheet = mất ngữ cảnh), nhưng nó là thay đổi kiến trúc điều hướng
chứ không phải retheme. **Ghi backlog, không implement trong pass này.**

---

## 4. Pattern tương tác mượn từ Cursor

### 4.1 Accept / Reject diff — ưu tiên cao nhất
`PopoverView.swift` §`task_refs_v1` (dòng ~850) đã có luồng "một câu nói sửa task có sẵn"
nhưng **chưa hiện diff before/after**. Đây là chỗ Cursor có bài học rõ nhất.

Thêm component `DiffRow` (file mới `Volar/Sources/Views/DiffRow.swift`):

```
┌─────────────────────────────────────────┐
│ Deadline                                 │
│   hôm nay 15:00        ← struck, textMut │
│   thứ Sáu 09:00        ← done (sage)     │
└─────────────────────────────────────────┘
```

- Giá trị **cũ**: `VolarColor.textMut` + `.strikethrough(color: VolarColor.veil(0.25))`.
- Giá trị **mới**: `VolarColor.done` (sage `0x7FA88C`) trên nền `done.opacity(0.10)`.
- **Không dùng đỏ cho vế bị bỏ** — luật 2. Diff vẫn đọc được vì gạch ngang + tương phản sáng/tối
  đã đủ mã hoá "cũ vs mới"; màu chỉ là lớp thứ hai.
- Hàng nút: `Accept ⏎` (primary, accent fill) / `Reject ⎋` (ghost). Dùng `Kbd` đã có sẵn
  trong `PopoverView.swift` (dòng ~1642) cho phím tắt, đừng viết badge mới.

### 4.2 Command bar ⌘K — file mới `Volar/Sources/Views/CommandBar.swift`
Ô nhập giữa màn hình, kiểu Cursor ⌘K: `RoundedRectangle(6)`, nền `surfaceHi`, viền `borderHi`,
placeholder "Type a task, or press ⌃⌥M to speak", không icon, không nút — chỉ text + gợi ý phím.
Đây là đường dự phòng khi không nói được. **Không thay thế** `TextCapturePanel` — command bar
gọi thẳng vào cùng entry point parse mà `TextCapturePanel` đang dùng; Sonnet phải đọc
`TextCapturePanel.swift` và tái sử dụng, không nhân bản logic.

---

## 5. Thứ tự thi công (giao Sonnet, file-disjoint)

| Việc | File | Phụ thuộc |
|---|---|---|
| **A. Token** | `Design/Theme.swift`, `Design/Glass.swift` | không — làm trước |
| **B. Component** | `Views/Components.swift`, `Views/TaskRow.swift`, `Views/Sidebar.swift` | sau A |
| **C. Sweep radius/mono** | 19 view còn lại | sau B |
| **D. DiffRow** | `Views/DiffRow.swift` (mới) + `Views/PopoverView.swift` | sau A |
| **E. CommandBar** | `Views/CommandBar.swift` (mới) + wiring hotkey | sau A |

A → B → C phải tuần tự (C phụ thuộc quy ước B đặt ra). D và E chạy song song được với B/C
vì file rời nhau — trừ `PopoverView.swift`, chỉ một agent được đụng vào file đó.

**Ràng buộc môi trường:** máy Windows, không có Swift/Xcode → code viết mù, build và verify
bằng mắt phải làm trên Mac. Không agent nào được báo "đã verify" khi chưa build trên Mac.

## 6. Việc chưa làm / rủi ro đã biết

- Cột phải inspector thay `.sheet` — §3.3, cần anh Khôi duyệt riêng.
- Windows (WinUI) và iOS sẽ **lệch design** sau pass này. Windows vừa đạt parity 1106 test;
  đồng bộ lại là một pass riêng, phải chờ macOS chốt bằng mắt trước.
- `VolarAccent.teal` (`0x3DBFAF`) vẫn đứng gần mint — vấn đề cũ từ Twilight, chưa xử lý ở pass này.
- Chưa build-verify: mọi số trong doc này là tính toán/thiết kế, chưa có ảnh render nào.
