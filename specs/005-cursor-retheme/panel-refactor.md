# Commit 2 — `TaskDetailView`: `.sheet` → inspector panel bên phải (kiểu Cursor)

Ngày: 2026-08-07 · Phạm vi: **chỉ macOS** · Nhánh: `macos`
**Commit riêng, tách hẳn khỏi commit retheme** (anh Khôi yêu cầu: revert được độc lập).

Đây KHÔNG phải retheme. Đây là đổi **kiến trúc điều hướng**. Vì thế nó có test/rủi ro riêng.

---

## 1. Hiện trạng

```
TaskRow.swift:87        .onTapGesture { appState.openDetail(task.id) }
TodayView.swift:552     .onTapGesture { appState.openDetail(active.id) }   ← NOW spotlight
TodayView.swift:1071    .onTapGesture { appState.openDetail(task.id) }     ← NextPeekRow
AppState.swift:2047     func openDetail(_ id: UUID) { detailTaskID = id }
VolarApp.swift:168-175  .sheet(isPresented: detailTaskID != nil) { TaskDetailView().frame(480×520) }
```

Sheet 480×520 rơi đè giữa cửa sổ → che cả task list lẫn NOW spotlight.

## 2. Đích

```
TodayView.body:  HStack { Sidebar() ; mainColumn }
              →  HStack { Sidebar() ; mainColumn ; detailPanel }
```

- `detailPanel` render khi `appState.detailTask != nil`, ẩn hẳn khỏi cây view khi `nil`.
- Rộng **300pt** cố định, nền `VolarColor.surface`, hairline `VolarColor.border` 0.5pt ở cạnh TRÁI.
- Chuyển task = bấm row khác → panel đổi nội dung, **không đóng-mở**.
- Xoá hẳn `.sheet` ở `VolarApp.swift:168-175`.
- `openDetail`/`closeDetail`/`detailTaskID` **giữ nguyên chữ ký** — mọi call site không đổi.

### Bề rộng cửa sổ
`VolarApp.swift:47` đang `minWidth: 820`. Sidebar 172 + cột giữa tối thiểu 380 + panel 300 = **852**
⇒ nâng `minWidth` 820 → **880**. Không làm panel co giãn ở pass này (giữ 300 cố định); nếu sau này
cần responsive thì đó là việc riêng.

---

## 3. ⚠️ Rủi ro số 1 — MẤT CHỮ ĐANG GÕ khi chuyển task

Đây là chỗ duy nhất có thể gây **mất dữ liệu người dùng**, phải xử đúng trước mọi thứ khác.

**Vì sao sheet không có vấn đề này:** trong sheet không thể chuyển sang task khác mà không đóng
sheet trước. Trong panel thì bấm một row khác là đổi ngay lập tức.

**Cơ chế hiện có:** `TaskDetailView.swift:26` gắn `.id(task.id)` lên `TaskDetailEditor`. Khi đổi
task, SwiftUI **huỷ** editor cũ và dựng cái mới với `@State` buffer nạp lại từ đầu. Nếu buffer cũ
chưa commit thì chữ vừa gõ bay mất.

**Lý do tin là ĐÃ AN TOÀN (nhưng phải chứng minh trên Mac):** header của `TaskDetailEditor` ghi
đường commit (d) là `.onDisappear` — "safety net cho Esc / click ra ngoài". Khi `.id()` đổi,
SwiftUI tear down view cũ ⇒ `.onDisappear` của nó **có chạy**, và `TaskDetailEditor` giữ
`let task: TaskItem` của chính danh tính cũ nên `commitIfChanged()` vẫn diff đúng task cũ.

**=> Việc bắt buộc:** giữ nguyên cả 4 đường commit (a)(b)(c)(d) của `manual-edit-contract.md §4`.
**Không được bỏ `.onDisappear`** với lý do "panel không bao giờ biến mất" — nó CÓ biến mất, hai lần:
khi `detailTask` về `nil`, và khi `.id()` đổi sang task khác. Đường (d) chính là thứ đang giữ dữ liệu.

**Test phải viết (chưa có):** gõ dở title task A → bấm sang task B → quay lại A → title phải là chữ
vừa gõ. Đây là test quan trọng nhất của cả commit này.

---

## 4. Esc — cố ý KHÔNG bind

Sheet được SwiftUI cho Esc miễn phí. Panel thì không. **Không thêm binding Esc cho panel.**

Lý do: Esc đang là phím thoát của capture popover (`PopoverView`'s `escCancelButton`) và của
command bar ⌘K vừa thêm ở commit 1. Thêm người thứ ba tranh Esc là chuốc lấy lỗi "bấm Esc lại
đóng nhầm thứ khác", loại lỗi rất khó lần ra.

Đóng panel bằng: nút Close sẵn có (đường commit (c)), hoặc bấm lại đúng row đang mở (toggle).
→ Cần sửa `openDetail` thành toggle: bấm lại task đang mở thì `detailTaskID = nil`.

---

## 5. Việc, theo thứ tự

| # | Việc | File |
|---|---|---|
| 1 | `openDetail` thành toggle (bấm lại task đang mở → đóng) | `App/AppState.swift` |
| 2 | Bỏ `.sheet` của detail, nâng `minWidth` 820→880 | `App/VolarApp.swift` |
| 3 | Thêm cột thứ ba vào `HStack`, bọc `TaskDetailView` trong container 300pt + hairline trái | `Views/TodayView.swift` |
| 4 | Đổi header doc của `TaskDetailView` từ "sheet" sang "inspector panel"; giữ nguyên 100% cơ chế commit | `Views/TaskDetailView.swift` |
| 5 | Test chuyển-task-giữa-chừng (§3) | `Volar/Tests/…` |

Việc 3 và 4 đụng file mà commit 1 vừa sửa ⇒ **phải chạy SAU khi commit 1 đã commit xong**, không
song song.

---

## 6. Không được đụng

- Cơ chế commit 4 đường của `manual-edit-contract.md §4`. Không thay bằng nút Save.
- `.id(task.id)` ở `TaskDetailView.swift:26`.
- Thứ tự attach overlay trong `TodayView.body` (comment dài trong file giải thích tour overlay phải
  là modifier tạo-overlay CUỐI CÙNG — panel là con của `HStack`, không phải overlay, nên không đụng).
- `FocusOverlay` vẫn phủ toàn cửa sổ kể cả khi panel mở — focus mode là chế độ một-việc, panel
  không được thò ra bên cạnh nó.
- Đường ghi dữ liệu: mọi edit vẫn đi qua `AppState.updateTask`.

## 7. Chưa verify

Máy Windows không có Xcode. Toàn bộ commit này là Swift viết mù. Rủi ro cao nhất, theo thứ tự:
`.onDisappear` có thật sự chạy khi `.id()` đổi hay không (§3 — nếu KHÔNG thì đây là bug mất dữ liệu,
phải sửa bằng cách commit tường minh trước khi đổi `detailTaskID`), layout ba cột ở bề rộng tối thiểu,
và `FocusOverlay` khi panel đang mở.
