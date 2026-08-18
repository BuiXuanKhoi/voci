# 009 — Light mode + List v2 ("Volar Paper")

**Anh Khôi chốt 2026-08-19.** Opus thiết kế, Sonnet execute. Kế thừa RETHEME 3 "Volar Graphite"
(`specs/005-cursor-retheme/design-spec.md`) — **Graphite chưa từng build trên Mac**, pass này chồng
lên nó và sẽ được verify cùng một lượt.

## §0 — Vấn đề đang sửa

Anh Khôi báo bốn câu, gần như cùng một gốc rễ:

1. "UI danh sách mờ nhạt quá"
2. "kiểu màu và tab gần như chìm vào giao diện"
3. "phần header ở trên vẫn màu trắng, khác với màu app quá"
4. "màu trước đây xấu và đại trà quá, nhìn qua rất mờ nhạt"

**Gốc rễ của (1)+(2)+(4):** app tiêu toàn bộ ngân sách tương phản vào ~20 lớp veil gần giống hệt
nhau, **trên một nền quá đen để các lớp đó đọc được**. Số đo trên bản hiện tại:

| Thứ | Giá trị | Hệ quả |
|---|---|---|
| `bg` | `#0F0F11` | đen hơn cả nền hệ thống của Apple — mọi veil alpha thấp chết trên nó |
| `card` (nền row) | `white @ .035` trên `#0F0F11` → `#18181A` | chênh nền trang **9/255** |
| `cardHover` | `white @ .06` | chênh trạng thái thường 2.5% → hover vô hình |
| `border` | `white @ .07`, 0.5pt | 1px @ 7% trên Retina → vô hình |
| tab active | `accent @ .15` | một vệt nhạt, không đọc ra "trạng thái" |
| header section | `textMut #6B6B74` | 3.6:1, code ghi rõ là **cố ý dưới AA** |

Mỗi row đều mang nền riêng + viền riêng, giống hệt nhau dù là NOW hay task thứ 14 ⇒ mắt không có gì
để bám. Notion/Framer/Cursor làm **ngược lại**: phẳng hơn nhưng đậm hơn — row không nền không viền,
nằm thẳng trên nền trang; hover là bề mặt DUY NHẤT nên 5% đã đọc rõ; selected là fill đặc.

Về (4) — hai màu cũ đều là lựa chọn đại trà: `#0F0F11` là "đen mặc định của mọi dashboard", và tím
`#7C5CFF` (đề xuất ban đầu của tôi) chính là **tím AI-startup** mà Linear/Vercel/mọi landing page
2024–2026 đang dùng. Pass này bỏ cả hai, lấy **bảng màu hệ thống macOS của Apple** làm nguồn (§3).

**Gốc rễ của (3):** xem §4.

## §1 — Quyết định anh Khôi đã chốt (không đem ra bàn lại)

- **Một họ màu nhấn duy nhất: TÍM, lấy theo `systemPurple` của Apple.** Mọi màu khác trong app là
  trắng–đen–xám hệ thống.
- **Ink lấy theo thang xám hệ thống của Apple**, không tự bịa hex.
- **Phân cấp bằng CÁCH DÙNG, không bằng hue.** Tím bão hoà chỉ xuất hiện ở **thanh 3px + chip nhỏ**,
  không bao giờ là một mảng nền lớn. Nó là điểm bão hoà duy nhất trên màn hình nên sẽ nổi bật.
- **Mint (`#8FEDCB` family) lui về chỉ còn logo.** Luật cũ "mint = NOW duy nhất" **hết hiệu lực**.
  Luật thay thế: *thanh tím + chip tím = NOW duy nhất*.
- **Ice blue `instrument` bỏ.** Instrument readout (WIP, timer, step count) từ nay là chữ mono màu
  `textSec` — không màu.
- **Light mode: có**, kèm picker System/Light/Dark trong Settings, mặc định System.
- **List v2 làm cả 4 mục:** đánh số, dòng lý do xếp hạng, chip blocked/waiting, quick-action hover.

## §2 — Cơ chế light mode: 0 call-site thay đổi

71 chỗ gọi `Color.white.opacity(...)` / `VolarColor.veil(...)` nằm rải 26 file. **Không sửa chỗ nào.**

Dùng dynamic color của hệ (`NSColor(name:dynamicProvider:)` trên macOS, `UIColor(dynamicProvider:)`
trên iOS). SwiftUI `Color` bọc một `NSColor`/`UIColor` dynamic vẫn giữ tính dynamic và tự resolve
theo appearance của view. Nghĩa là **mọi `static let` trong `VolarColor` đổi giá trị tại chỗ, tên
token không đổi, không file view nào phải sửa** — đúng kỷ luật hai đợt retheme trước.

`veil(_:)` cũng thành dynamic: trắng ở dark, **đen ở light**. Đây là mảnh quan trọng nhất — không có
nó thì 71 chỗ kia biến mất sạch trên nền trắng.

`Shared/` được compile bởi CẢ `Volar` (macOS) lẫn `VolarIOS`, nên helper phải có nhánh
`#if canImport(AppKit)` / `#elseif canImport(UIKit)`.

**Không dùng `Color(nsColor: .systemPurple)` trực tiếp.** Lý do: các `NSColor` hệ thống đổi giá trị
theo accent color user chọn trong System Settings và theo phiên bản macOS, nên hai máy sẽ ra hai
màu khác nhau. Ta **chép giá trị hex** của Apple vào token (bảng §3) để màu là cố định và kiểm soát
được, nhưng vẫn nằm trong ngôn ngữ màu của hệ.

## §3 — Bảng token đầy đủ (nguồn sự thật duy nhất)

Mọi giá trị dưới đây là hex Apple công bố cho system colors / system grays, trừ ba chỗ đánh dấu
`(pha)` là màu pha giữa accent và ink — có nêu công thức.

Format: `token = light / dark`.

### 3.1 Ink — thang xám hệ thống Apple

| Token | Light | Dark | Nguồn |
|---|---|---|---|
| `bg` | `#FFFFFF` | `#1C1C1E` | Apple systemGray6 dark |
| `surface` | `#F2F2F7` | `#232326` | systemGray6 light / giữa gray6–gray5 dark |
| `surfaceHi` | `#E5E5EA` | `#2C2C2E` | Apple systemGray5 |
| `card` | `.clear` | `.clear` | **đổi thành trong suốt** — row không còn nền riêng (§5.1) |
| `cardHover` | `black @ .05` | `white @ .06` | bề mặt duy nhất trên màn hình |
| `border` | `black @ .10` | `white @ .10` | 0.07 → 0.10 |
| `borderHi` | `black @ .18` | `white @ .18` | 0.12 → 0.18 |
| `veil(x)` | `black @ x` | `white @ x` | đảo cực theo mode |

> **Đây là thay đổi quan trọng nhất của cả pass.** `bg` từ `#0F0F11` lên `#1C1C1E` (Apple) và
> `surfaceHi` `#2C2C2E`: delta giữa nền trang và row được chọn nhảy từ **9/255 lên 16/255**, tức
> **gấp gần 2×**, mà không cần một lớp veil nào. Nền đen quá sâu là lý do kỹ thuật khiến mọi thứ
> "chìm" — Apple không dùng `#0F0F11` cho nền cửa sổ, và đó không phải ngẫu nhiên.

### 3.2 Text

| Token | Light | Dark | Contrast vs `bg` | Nguồn |
|---|---|---|---|---|
| `textPri` | `#1C1C1E` | `#F2F2F7` | 16.1:1 / 14.8:1 — AAA | label color |
| `textSec` | `#6E6E73` | `#98989D` | 5.4:1 / 6.4:1 — AA | secondaryLabel / systemGray dark |
| `textMut` | `#8E8E93` | `#7C7C80` | 3.4:1 / 4.0:1 — tertiary only | systemGray |

`textMut` **không được dùng cho header section nữa** (§5.4) và không bao giờ cho body copy.

### 3.3 Accent tím — Apple `systemPurple` + biến thể accessible

`VolarAccent.indigo` giữ nguyên tên `case` (nó persist bằng rawValue; đã là misnomer từ trước).

| Vai trò | Light | Dark | Nguồn |
|---|---|---|---|
| `solid` | `#8944AB` | `#BF5AF2` | systemPurple accessible light / systemPurple dark |
| `hover` | `#6E3589` | `#DA8FFF` | tối/sáng thêm một bậc; dark = systemPurple accessible dark |
| `surface` | `solid @ .10` | `solid @ .16` | |
| `glow` | `solid @ .30` | `solid @ .40` | |

Vì sao **không** dùng `#AF52DE` (systemPurple light thường): trên nền trắng nó chỉ đạt **3.6:1**,
rớt AA cho chữ và cho cả chữ trắng đặt lên nó. `#8944AB` là biến thể accessible Apple công bố đúng
cho tình huống này — **6.0:1 trên trắng**, và chữ trắng trên nó cũng 6.0:1. Một giá trị phục vụ cả
hai chiều.

Ba family còn lại (`teal`/`amber`/`magenta`) **giữ nguyên hue**, chỉ bổ sung cặp giá trị light bằng
cách hạ lightness ~25%. Chúng opt-in, không phải mặc định, và không đáng tốn thời gian tinh chỉnh.

### 3.4 NOW / spotlight — giữ nguyên TÊN token, đổi VALUE

Đây là chỗ luật "tím chỉ ở thanh và chip" được mã hoá thành token:

| Token | Light | Dark | Ghi chú |
|---|---|---|---|
| `nowAccent` | `#8944AB` | `#BF5AF2` | thanh trái 3px + chip "NOW" |
| `nowAccentSoft` | `#A855C9` | `#DA8FFF` | hover của chip |
| `nowAccentDeep` | `#6E3589` | `#9A3FD0` | trạng thái nhấn |
| `nowSurface` **(mới)** | `#F5EAFA` `(pha)` | `#2E2036` `(pha)` | **nền row NOW** — accent pha vào `bg` ~8% |
| `nowGlow` | `#8944AB @ .08` | `#BF5AF2 @ .20` | |
| `nowGlowSoft` | `#8944AB @ .04` | `#BF5AF2 @ .10` | |
| `nowRing` | `#8944AB @ .45` | `#BF5AF2 @ .55` | |

Row NOW **không** được fill bằng `nowAccent` đặc. Lý do: chữ trắng trên `#BF5AF2` chỉ 3.1:1, và một
mảng tím lớn phá luôn nguyên tắc "trắng đen + một điểm nhấn". Thay vào đó: nền `nowSurface` rất
nhạt, chữ vẫn `textPri`, và **toàn bộ độ bão hoà dồn vào thanh 3px + chip nhỏ**. Đó là cách Apple
đánh dấu hàng được chọn trong Mail/Notes, và là cách duy nhất giữ được cả tương phản chữ lẫn tính
"một điểm sáng".

`SpotlightBackground` giữ nguyên code, chỉ ăn theo giá trị token mới.

### 3.5 Priority / status — theo system colors Apple, trừ chỗ luật cấm-đỏ chi phối

| Token | Light | Dark | Ghi chú |
|---|---|---|---|
| `high` | `#C04A26` `(pha)` | `#FF9F6B` `(pha)` | cam đất, **không phải đỏ báo động** — luật anti-shame |
| `med` | `#8A6D3B` | `#D9B77A` | nâu vàng trầm |
| `low` | `black @ .28` | `white @ .30` | |
| `done` | `#248A3D` | `#30D158` | Apple systemGreen accessible light / systemGreen dark |
| `destruct` | `#D70015` | `#FF453A` | Apple systemRed accessible light / systemRed dark |
| `reschedule` | `#6E6E73` | `#98989D` | `= textSec`, cố ý trung tính |
| `instrument` | `= textSec` | `= textSec` | **bỏ ice blue** |
| `instrumentDim` | `= textMut` | `= textMut` | |

Luật cấm-đỏ giữ nguyên: **không đỏ cho overdue/badge/status**; `destruct` chỉ dùng cho nút xoá —
đó là hành động không đảo ngược được của hệ thống, không phải nhãn đánh giá người dùng.

## §4 — Titlebar (câu hỏi (3) của anh Khôi)

`Volar/Sources/App/WindowChrome.swift` đã viết + đã wire (`VolarApp.swift:253`) nhưng **chưa build
lần nào**, và có một lỗi thật:

```swift
DispatchQueue.main.async { Self.apply(to: view.window) }   // makeNSView
...
private static func apply(to window: NSWindow?) {
    guard let window, !(window is NSPanel) else { return }   // ← im lặng thoát
```

Scene `Window(id:)` gắn view vào cây **trước khi** `NSWindow` tồn tại, nên cú `async` một-lần này
bắn lúc `view.window` còn `nil` ⇒ `guard` thoát, không thử lại, titlebar giữ màu mặc định. Đúng
triệu chứng anh Khôi thấy.

**Sửa:**
1. `apply` thử lại có giới hạn (tối đa 10 vòng run-loop) tới khi `view.window != nil`. Có bộ đếm
   cứng để không bao giờ thành vòng lặp vô hạn nếu window thật sự không bao giờ tới.
2. `window.backgroundColor` phải nhận **`NSColor` dynamic** (không phải giá trị đã resolve một
   lần), nếu không titlebar sẽ đứng im khi user đổi Light↔Dark.

## §5 — List v2 (danh sách)

### 5.1 Bỏ chrome từng row
- `card` → `.clear`; **xoá `.overlay(stroke(rowBorderColor))`** trong `TaskRow`.
- `Density.rowGap` → `0 / 0 / 2` (cozy/comfy/roomy). Row nằm sát nhau.
- Không hairline giữa từng row. Chỉ có hairline **giữa các section**.

### 5.2 Hover là bề mặt duy nhất
- hover = `cardHover`, bo góc 6, phủ hết chiều rộng row.
- Vì là fill duy nhất trên màn hình nên nó đọc rõ dù alpha thấp.

### 5.3 Selected / NOW
- **NOW**: nền `nowSurface` + thanh trái **3px** `nowAccent` + chip "NOW" nền `nowAccent` chữ
  trắng (light) / `#1C1C1E` (dark). Chữ tiêu đề vẫn `textPri`.
- **Selected (không phải NOW)**: nền `surfaceHi` đặc + thanh trái **2px** `accent.solid`.
- Bỏ hẳn kiểu wash `accent @ .15` làm nền row.

### 5.4 Header section
`11pt / .semibold / uppercase / tracking +0.5 / textSec` (KHÔNG `textMut`).

### 5.5 Checkbox
`17 → 18pt`, viền `veil(0.28) → veil(0.45)`.

### 5.6 Bốn thứ bổ sung

1. **Đánh số 1·2·3** ở đầu mỗi row mở — mono 11pt `textMut`, width cố định 18pt để tiêu đề thẳng
   hàng. Số = vị trí trong thứ tự engine, **không phải id**. Task done không có số.
2. **Dòng lý do xếp hạng** — nối vào subrow sẵn có, sau priority/duration. Nguồn: API mới
   `VolarCore.rankReason(for:now:calendar:)` (§6). Ví dụ: "quá hạn 2h", "hạn hôm nay 16:00", "ưu
   tiên cao". **Chỉ hiện cho 3 row đầu** — dưới nữa là nhiễu.
3. **Chip blocked/waiting** — task có `Condition` chưa thoả: chip viền `borderHi`, chữ `textMut`,
   icon khoá; nội dung lấy từ condition (`.taskDone` → "chờ: <tên task>", `.afterDate` → "từ
   <giờ>", `.external` → chính `description`). Row bị chặn hiển thị ở opacity 0.55 nhưng **KHÔNG bị
   ẩn** — luật "app không được nuốt mất việc".
4. **Quick-action khi hover** — góc phải row, chỉ hiện khi `isHovering`: Start, Break down.
   ("Defer" từng nằm trong danh sách này, anh Khôi **bỏ** 2026-08-19 — xem backlog.)
   Ba `Button(.plain)` + `.contentShape(Rectangle())` cuối label (luật vùng-bấm-phủ-vùng-nhìn).
   Context menu giữ nguyên, không bỏ.

### 5.7 Drawer "Later"
Mặc định **mở 5 dòng đầu** thay vì thu gọn hoàn toàn. Một phần cảm giác "mờ nhạt" là do màn hình
gần như trống.

## §6 — VolarCore: lý do xếp hạng

Thêm vào `NextTask.swift` (KHÔNG tạo file mới, KHÔNG đụng `orderedBefore`):

```swift
public enum RankReason: Sendable, Equatable {
    case inProgress
    case overdue(by: TimeInterval)
    case dueToday(Date)
    case priority(Int)
    case none
}

public func rankReason(for task: Task, now: Date, calendar: Calendar) -> RankReason
```

**Bắt buộc dùng lại đúng các helper private sẵn có** (`statusRank`, `isNearTermDeadline`,
`priorityRank`) — không được viết lại ngưỡng. Đây là bài học đã trả giá một lần
(`AppState.eligibleOrder` từng là bản sao tay của `eligibleTasks`, xem backlog).

Thứ tự xét phải khớp tier của `orderedBefore`: inProgress → overdue → dueToday → priority → none.

Test: `VolarCore/Tests/VolarCoreTests/RankReasonTests.swift` — mỗi case một test, cộng một test bất
biến "task đứng đầu `eligibleTasksOrdered` không bao giờ trả `.none` khi có task khác có deadline
hôm nay".

## §7 — Appearance plumbing

- `VolarApp.swift:378` `NSApp.appearance = NSAppearance(named: .darkAqua)` — **không xoá, đổi thành
  đọc từ pref**: `.system → nil`, `.light → .aqua`, `.dark → .darkAqua`. Lý do gốc của dòng này
  (control AppKit vẽ theo appearance hệ thống chứ không theo palette hardcode) vẫn đúng; giờ nó chỉ
  cần theo lựa chọn của user thay vì cứng dark.
- Pref mới `volar.appearance` (String: `system`/`light`/`dark`), persist trong `UserDefaults`, đọc
  trong `AppState.init`. Đây cũng là dịp sửa luôn backlog dòng 948 (`accent`/`density` không
  persist) — **cùng một cơ chế, cùng một file, làm một thể**.
- `SettingsView` → General: picker "Appearance" (System / Light / Dark).

## §8 — Chia việc cho Sonnet (file-disjoint)

**Wave 1 — song song, không file nào giẫm chân:**

| Agent | File được sở hữu | Nội dung |
|---|---|---|
| A | `Shared/Design/Theme.swift` | §2 + §3 toàn bộ |
| B | `VolarCore/Sources/VolarCore/NextTask.swift`, `VolarCore/Tests/VolarCoreTests/RankReasonTests.swift` | §6 |
| C | `Volar/Sources/App/VolarApp.swift`, `Volar/Sources/App/WindowChrome.swift`, `Volar/Sources/Views/SettingsView.swift`, `Volar/Sources/AppState.swift` | §4 + §7 |
| D | `Volar/Sources/Views/Sidebar.swift` | §5.3 áp cho tab, §5.4 |

**Wave 2 — sau khi A và B xong (cần token mới + API mới):**

| Agent | File | Nội dung |
|---|---|---|
| E | `Shared/Views/TaskRow.swift`, `Shared/Views/Components.swift` | §5.1, 5.2, 5.3, 5.5, 5.6 |
| F | `Volar/Sources/Views/TodayView.swift` | §5.4, 5.6.1 (cấp số thứ tự), 5.7 |

**Luật bắt buộc cho mọi agent:**

- KHÔNG sửa file ngoài danh sách của mình. Thấy chỗ cần sửa ở file khác → **BÁO, đừng sửa**.
- KHÔNG chạy `supabase/scripts/probe-*.ts` (luật `CLAUDE.md`).
- Không có Swift toolchain trên máy này ⇒ viết mù, **không được báo "đã build xanh"**.
- Self-review 6 mục trước khi báo xong: (1) token nào tự bịa không có trong §3, (2) chỗ nào còn
  hardcode hex, (3) vùng bấm có phủ vùng nhìn thấy không (`.contentShape`), (4) `.stroke` vs
  `.strokeBorder` khi kèm `.clipShape`, (5) contrast của mọi cặp chữ/nền ở **cả hai** mode, (6)
  `#Preview` còn đọc được ở cả hai mode không.

## §9 — Hệ quả đã biết, không sửa đợt này

- **Windows (WinUI 3) và iOS sẽ lệch design** thêm một bậc. Đồng bộ là pass riêng, chờ macOS chốt
  bằng mắt trước.
- Bộ logo mint (`#A9F5DA`/`#74DDB6`) giờ **không còn màu nào trong app khớp với nó**. Cần quyết
  riêng: vẽ lại logo theo tím, hay giữ mint làm màu thương hiệu tách khỏi UI. → backlog.
- `VolarAccent.teal` từng "đứng quá gần mint" — vấn đề đó **tự tan** khi mint rời khỏi UI.
- `AmbientBackground` (mưa/tuyết/than hồng) chưa được xét trên nền trắng. Nhiều khả năng phải tắt
  hoặc đảo cực ở light mode. → backlog.
