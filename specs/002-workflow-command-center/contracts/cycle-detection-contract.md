# Contract: Cycle dependency detection + UI (tạo task & sửa task)

**Anh Khôi yêu cầu 2026-07-29.** User nói "A đợi B", rồi "B đợi C", rồi "C đợi A" → phải phát hiện,
báo lỗi, **hiển thị vòng lặp** đó, và giải thích hậu quả. Áp dụng cho **cả lúc tạo** (một tràng
task nói liền, kể cả vòng với task ĐÃ CÓ) **lẫn lúc sửa** task.

Anh Khôi đã chốt 3 điểm:
1. **Cảnh báo sớm + CHẶN Save** cho tới khi user gỡ một cạnh. Không bao giờ để task nằm trong DB với
   quan hệ bị bỏ mà user không biết.
2. **Làm luôn UI sửa dependency** trong `TaskDetailView` — đó mới là chỗ "lỗi khi sửa task" có nghĩa.
3. Mọi câu thông báo **tiếng Anh**, nhất quán với phần còn lại của app.

## Vì sao phải làm (hiện trạng, đã kiểm code 2026-07-29)

Thuật toán `wouldCreateCycle` (`VolarCore/DependencyGraph.swift:59`) ĐÚNG — DFS O(V+E), có `visited`
nên không treo kể cả input đã cyclic. Vấn đề là **lỗi bị nuốt**:

| Đường ghi | Gặp cycle | Ai gọi |
|---|---|---|
| `TaskStore.addCondition` | throw + có sẵn câu tiếng người (`describe`, `TaskStore.swift:558`) | chỉ `confirmSave`, mà nó bọc `try?` → **nuốt** |
| `add`/`addBatch` → `sanitizedConditions` | **lọc bỏ im lặng**, chỉ `print` | đường CHÍNH khi user nói một tràng |
| `mergeIntoExisting` → `sanitizedConditions` | im lặng | merge vào task trùng |

Và `DependencyError.cycle(from:to:)` **chỉ mang 2 tên task, không mang đường đi** — không đủ để vẽ
"A → B → C → A".

---

## Phân công (file-disjoint, hợp đồng §1 là ĐÓNG BĂNG)

| Agent | File sở hữu |
|---|---|
| 1 | `VolarCore/Sources/VolarCore/DependencyGraph.swift`, `VolarCore/Tests/VolarCoreTests/DependencyGraphTests.swift` |
| 2 | `Volar/Sources/App/AppState.swift`, `Volar/Tests/DependencyCycleTests.swift` (mới) |
| 3 | `Volar/Sources/Views/PopoverView.swift` |
| 4 | `Volar/Sources/Model/TaskStore.swift`, `Volar/Sources/Views/TaskDetailView.swift`, `Volar/Tests/TaskDependencyStoreTests.swift` (mới) |

Agent 2 gọi API của Agent 1 và Agent 4 theo đúng chữ ký §1; không chờ nhau.

---

## §1 — API đóng băng

### 1.1 VolarCore (Agent 1)

```swift
/// Đường đi khép kín mà việc thêm `.taskDone(target)` vào `source` sẽ tạo ra.
/// Phần tử đầu == phần tử cuối, VD [A, B, C, A]. `nil` = không tạo vòng.
/// Self-edge (source == target) trả [source, source].
public func cyclePath(from source: UUID, dependsOn target: UUID, in snapshot: [Task]) -> [UUID]?

/// MỘT vòng đã tồn tại sẵn trong graph `.taskDone` của `snapshot`, khép kín như trên.
/// `nil` = graph đã acyclic. Deterministic: duyệt node theo thứ tự `snapshot`, cạnh theo
/// thứ tự `conditions`, nên cùng input luôn ra cùng một vòng.
public func findCycle(in snapshot: [Task]) -> [UUID]?
```

- `wouldCreateCycle` giữ NGUYÊN chữ ký public (đang có test và call site) — hiện thực lại thành
  `cyclePath(...) != nil` để không có hai bản logic đi lệch nhau.
- `DependencyError` **KHÔNG đổi** — `contracts/volarcore-api.md` đã đóng băng nó; app dựng câu
  thông báo giàu hơn từ `cyclePath`/`findCycle` chứ không đổi payload của error.
- Chỉ `.taskDone` là cạnh. `.afterDate`/`.external` không bao giờ tham gia.
- Duyệt **lặp, không đệ quy** (DFS 3 màu cho `findCycle`), có `visited` — dữ liệu độc hại/đã cyclic
  không được phép làm treo hay tràn stack.

### 1.2 `AppState` — trạng thái vòng của batch đang confirm (Agent 2)

```swift
struct ConfirmCycle: Equatable {
    /// Tên hiển thị, khép kín: ["A", "B", "C", "A"]
    var titles: [String]
    /// Những cạnh TRONG vòng mà user gỡ được ngay trên confirm card (cạnh thuộc một draft của
    /// batch này). Cạnh thuộc task đã persist không gỡ được từ đây.
    var removableEdges: [RemovableEdge]

    struct RemovableEdge: Equatable, Identifiable {
        var id: String { "\(draftID)-\(conditionIndex)" }
        var draftID: ConfirmDraft.ID
        var conditionIndex: Int
        /// "C waits on A"
        var label: String
    }
}

/// `nil` = batch sạch. Khác `nil` = PopoverView phải hiện hàng cảnh báo và KHOÁ Save.
private(set) var confirmCycle: ConfirmCycle?
```

### 1.3 `AppState` — sửa dependency của task đã tạo (Agent 2)

```swift
/// Thêm "task `id` đợi task `dependsOn` xong". Trả `nil` khi thành công, hoặc câu thông báo
/// tiếng Anh (đã có đường đi đầy đủ của vòng) khi bị từ chối.
@discardableResult
func addTaskDependency(_ id: UUID, dependsOn: UUID) -> String?

/// Gỡ condition thứ `conditionIndex` khỏi task `id`. No-op nếu id/index không hợp lệ.
func removeTaskDependency(_ id: UUID, at conditionIndex: Int)
```

Cả hai, sau khi ghi store thành công: `tasks = store.fetchAll()` → `notifyEligibilityAndScheduleResurface(before:now:)` → `syncCalendarMirror()`. **Gỡ một cạnh có thể làm task khác đủ điều kiện chạy ngay** — bỏ bước eligibility là mất thông báo "đã mở khoá".

### 1.4 `TaskStore` (Agent 4)

```swift
/// Gỡ condition thứ `index`. Trả `false` nếu id không tồn tại hoặc index ngoài khoảng.
@discardableResult
func removeCondition(at index: Int, from id: UUID) -> Bool
```

`addCondition` giữ nguyên (đã throw sẵn, đúng như cần).

---

## §2 — Agent 2: phát hiện vòng cho batch đang confirm

Hàm nội bộ `recomputeConfirmCycle()` dựng một **snapshot ảo** rồi hỏi `VolarCore.findCycle`:

1. **Bản đồ id** — dựng `targetID` GIỐNG HỆT `confirmSave` đang làm: draft `.addNew` → dùng chính
   `draft.id` làm id ảo; draft `.useExisting(x)` → dùng `x`. Chỉ lấy draft `isIncluded`.
   **⚠️ Đây là chỗ dễ sai nhất.** Một draft `.useExisting(X)` KHÔNG phải node mới — nó là chính task
   X đã tồn tại. Phải **gộp cạnh của draft vào node X sẵn có**, tuyệt đối không thêm node thứ hai
   trùng id (thêm trùng thì `findCycle` đọc nhầm graph và bỏ sót/bịa vòng).
2. **Cạnh của mỗi draft** = `resolvedTaskDone` (id thật) + `intraBatchTaskDone` (dịch qua `targetID`),
   **bỏ mọi index nằm trong `dismissedConditions`**, bỏ cạnh trỏ vào chính nó, bỏ cạnh trỏ tới
   draft không có trong `targetID`. Đúng cùng bộ luật `confirmSave` dùng khi build
   `intraBatchAttachments` — nếu hai chỗ lệch nhau thì cảnh báo sẽ nói dối.
3. Snapshot = `tasks.map(\.snapshot())` (task đã có) hợp nhất với các node draft ở trên.
   `VolarCore.Task(id:title:status:priority:deadline:conditions:estimateMinutes:parentId:createdAt:)`.
4. `findCycle` → `[UUID]` → đổi sang tên (tra `tasks` trước, rồi `effectiveTitle` của draft) →
   `titles`. Với mỗi cạnh `path[i] → path[i+1]`: nếu `path[i]` là id của một draft trong batch thì
   tìm `conditionIndex` tương ứng và thêm vào `removableEdges` với nhãn `"<from> waits on <to>"`.

**Gọi `recomputeConfirmCycle()` sau MỌI thứ đổi tập cạnh:** cuối `buildConfirmDrafts`,
`dismissCondition`, `acceptUncertainCondition`, `resolveTaskDone`, `resolveTaskDoneToDraft`,
`setDraftIncluded`, **và `setDuplicateResolution`** (đổi `.useExisting` là đổi id của node — bỏ sót
chỗ này là cảnh báo sai ngay).

**`confirmSave()`**: thêm guard đầu hàm `guard confirmCycle == nil else { return }` làm lưới an
toàn, và **bỏ `try?` ở pass 2** (`try? store.addCondition(...)`) → đổi thành `try` trong `do` block
sẵn có, để nếu vẫn lọt thì rơi vào `catch` đã có và hiện câu tiếng người thay vì nuốt.

Test `Volar/Tests/DependencyCycleTests.swift` (no-store `AppState()` như `ConfirmCardManualEditTests`):
vòng 3 task hoàn toàn trong batch; vòng đi qua 1 task đã persist; gỡ một cạnh (`dismissCondition`)
→ `confirmCycle` về `nil`; batch sạch → luôn `nil`; draft bị untick → cạnh của nó biến mất khỏi
graph; `.useExisting` gộp đúng node (không nhân đôi); `confirmSave` không lưu gì khi còn vòng.

## §3 — Agent 3: `PopoverView`

Hàng cảnh báo **cấp BATCH**, đặt ngay TRÊN `actionsRow` — **không** đặt trong `taskDraftCard`, vì
một vòng có thể xuyên nhiều draft nên nó không thuộc về draft nào cả.

- Nội dung: dòng tiêu đề + chuỗi vòng `A → B → C → A` + một câu hậu quả
  ("None of these can ever start — each is waiting on the next.").
- Mỗi `removableEdges` → một nút `"Remove: C waits on A"` gọi
  `appState.dismissCondition(at: edge.conditionIndex, forDraft: edge.draftID)`.
- **Khoá Save**: thêm `|| appState.confirmCycle != nil` vào `.disabled(...)` VÀ `.opacity(...)` của
  nút Save (`PopoverView.swift:1131`, `:1130`). `.keyboardShortcut(.defaultAction)` phải bị khoá
  theo — Enter tuyệt đối không được lách qua.
- Register: **đây là ERROR thật, không phải advisory.** Khác hẳn `conflictAdvisoryRow`/
  `overdueAdvisoryRow` (bình thản, không chặn, dismiss được) — hàng này KHÔNG dismiss được, vì bỏ
  qua nó không làm vòng biến mất. Dùng `VolarColor.high`.

## §4 — Agent 4: `TaskStore` + `TaskDetailView`

`TaskStore.removeCondition(at:from:)` theo §1.4.

`TaskDetailView` thêm khu **"Waiting on"** dưới phần description:
- Liệt kê `task.conditions`: `.taskDone` → tên task (tra `appState.openTasks`, không tìm thấy thì
  "Unknown task"); `.afterDate` → "After <ngày>"; `.external` → "Waiting: <mô tả>". Mỗi hàng có nút ×
  gọi `appState.removeTaskDependency(task.id, at: index)`.
- Nút "Add dependency" → `Menu` liệt kê `appState.openTasks` (bỏ chính nó và các task đã là
  dependency) → gọi `appState.addTaskDependency(task.id, dependsOn: picked.id)`.
- Trả về chuỗi khác `nil` → hiện **inline dưới nút đó**, `VolarColor.high`, giữ nguyên cho tới lần
  thao tác kế tiếp. Không dùng alert modal.
- **Không đụng cơ chế commit (a)(b)(c)(d) của phần sửa 7 field** đã có trong file — dependency đi
  đường riêng (`addTaskDependency`/`removeTaskDependency`), KHÔNG qua buffer `@State`, vì nó phải
  validate ngay tại thời điểm bấm chứ không phải lúc commit.

Test `Volar/Tests/TaskDependencyStoreTests.swift`: `removeCondition` gỡ đúng phần tử; index ngoài
khoảng trả `false` và không đụng dữ liệu; `addCondition` tạo vòng vẫn throw như cũ.

---

## §5 — Luật chung

- Máy này là Windows, **KHÔNG build được Swift**. Không chắc API thì theo tiền lệ đã có trong repo
  và đánh `// UNVERIFIED:` kèm lý do.
- Không sửa file ngoài danh sách sở hữu. Cần thứ của agent khác → dùng đúng chữ ký §1.
- **Mọi chuỗi hiển thị bằng tiếng Anh.** Comment code tiếng Anh, theo mật độ/giọng văn sẵn có.
- `VolarCore` là package thuần, **không được import SwiftUI/SwiftData** vào đó.
- Tự review 6 mục: (1) đúng §1, (2) không rò file, (3) đường chặn thật sự chặn (Enter có lách được
  không), (4) side-effect eligibility/reminder/calendar, (5) biên (vòng qua task đã persist, draft
  untick, `.useExisting`, self-edge, id không tồn tại), (6) chỗ nào không verify được thì nói rõ.
