# 008 — Sync engine: một tài khoản, bốn máy, không bao giờ nuốt mất việc

> Opus thiết kế 2026-08-09 theo yêu cầu anh Khôi. Lý do đột ngột cần: anh Khôi chốt **Apple Watch
> phải chạy được khi KHÔNG có iPhone bên cạnh** ⇒ `WCSession` không đủ (nó chỉ sống khi hai máy ở
> gần nhau) ⇒ sync từ "tính năng paid tier để sau" thành **thứ chặn Phase 3 của
> `specs/007-apple-three-platforms/plan.md`**. Thứ tự anh chốt: **sync trước, watch sau.**
>
> Thay thế/gộp các mục backlog: "Ba field cho sync" (2026-08-09), "Sync Mac ↔ iPhone cho paid
> tier" (2026-07-27), và trả lời `plan.md` 007 §11 câu 3 (câu trả lời là **CÓ**, ngược với khuyến
> nghị trong plan đó).
>
> **Ba điều anh Khôi chốt thêm sau khi đọc bản đầu (2026-08-09), đã hợp nhất vào tài liệu này:**
> **(1)** sync là **opt-in** — điều kiện là *Pro AND user bật công tắc*, hai điều kiện (§8).
> **(2)** công tắc ở mức **tài khoản**, không phải từng máy ⇒ nó sống ở server và đi vào RLS policy
> (§8.0–§8.3). **(3)** hết hạn Pro **không xoá gì cả** — *"bản gốc luôn ở device tạo ra nó, bản trên
> cloud chỉ là replica"* (§2). Kèm xác nhận mô hình ghi là **write-through, không rollback** (§7).
>
> Kim chỉ nam, mượn nguyên văn `docs/adhd-automation-v1.md:214`: *"app là MÔ HÌNH của thực tế, mô
> hình luôn trễ; mục tiêu là ĐỐI CHIẾU RẺ, không phải sync hoàn hảo — không bao giờ phạt user vì
> app bị cũ."*
>
> ⚠️ Toàn bộ Swift trong tài liệu này là **UNVERIFIED** (máy dev Windows, không có Swift/Xcode).
> SQL đã `deno check` không áp dụng — SQL chưa apply, chưa deploy, chỉ là file.

---

## 0. Năm phát hiện khi đọc code — đọc trước khi làm bất cứ gì

**(1) Không có `updatedAt`. Không có gì cả.** grep `updatedAt|lastModified|CloudKit|WCSession|syncEngine`
trên toàn bộ `Shared/`, `Volar/`, `VolarIOS/`, `VolarCore/`: **0 kết quả**. `VolarTask` có
`createdAt` và `completedAt`, không có mốc "sửa lần cuối". Nghĩa là *last-write-wins hôm nay không
có "last" để so*. Đây đúng là mục backlog anh Khôi đã chốt 2026-08-09 ("ba field cho sync ... macOS/
Windows bổ sung **khi thực sự làm sync**"). Bây giờ chính là lúc đó.

**(2) Server hiện KHÔNG có một bảng nào chứa nội dung user.** Toàn bộ schema `public` là 5 bảng:
`entitlements`, `usage_counters`, `promo_codes`, `promo_redemptions`, `promo_attempts`. Task chưa
bao giờ rời máy trừ khi đi qua `/parse` tới Gemini (không lưu). ⇒ Sync là **lần đầu tiên nội dung
task nằm ở trạng thái nghỉ trên server của mình**. Đây là một cam kết riêng tư mới, không phải mở
rộng cam kết cũ. Phải nói thẳng ra, §9.

**(3) `@Attribute(.unique) var id: UUID` có ở CẢ BỐN `@Model`** — `VolarTask.swift:71`,
`CompletionLog.swift:15`, `ParseCorrection.swift:17`, `ReminderRecord.swift:15`. Backlog gọi đây là
"🔴 MỐC CHẶN TRƯỚC KHI SHIP iOS" vì **CloudKit cấm**. Hệ quả của §1 dưới đây: chọn Supabase thì
ràng buộc đó **biến mất luôn**, mốc chặn đóng lại mà không phải sửa một dòng nào trên dữ liệu thật.
Đó là một trong những lý do mạnh nhất của §1, không phải hệ quả phụ.

**(4) `ReminderRecord` là dữ liệu SUY RA, không phải dữ liệu gốc.** `ReminderRecord.derive(...)`
(`ReminderRecord.swift:165`) là hàm thuần: `(taskId, deadline, createdAt, priority, reminderOverride,
globalPolicy, now) -> [ReminderRecord]`. Nó còn nằm ở **ModelContainer riêng** (`Schema([ReminderRecord.self])`,
`ReminderScheduler.swift:831`), tách hẳn khỏi container của task. ⇒ **Không sync nó.** Mỗi máy tự
derive lại từ task đã sync. Xem §3.

**(5) `ParseCorrection` có lời hứa "không bao giờ rời máy" viết ngay trong file.**
`ParseCorrection.swift:10-14`: *"Local-only: this file has no network code path, and nothing in this
codebase egresses `ParseCorrection` rows anywhere (FR-044)"*, gắn với constitution V + Principle I.
⇒ **Không sync, và không được lặng lẽ sync.** Xem §3.

---

## 1. Quyết định lớn nhất: Supabase, KHÔNG phải CloudKit

**Chốt: dựng sync trên Supabase (Postgres + RLS + RPC). Không bật CloudKit, không thêm entitlement
iCloud, không bao giờ.**

Đây là **lệch với `docs/product-vision-v2.md`**, nơi mục Tier-3 số 10 viết nguyên văn "iPhone/Watch
companion + **CloudKit sync** + nhắc đa thiết bị". Cần anh Khôi gật chính thức vào chỗ lệch này
(§10, câu Q1).

Lý do (theo thứ tự quan trọng):

1. **CloudKit bỏ rơi bản Windows.** Nhánh `window` đã có **1106/1106 test xanh, full parity 17/17
   view WinUI 3** (memory 2026-07-26). CloudKit không phục vụ .NET được (CloudKit Web Services
   buộc đăng nhập bằng Apple ID qua JS của Apple). Chọn CloudKit = **khai tử bản Windows hoặc chấp
   nhận vĩnh viễn hai hệ dữ liệu không nói chuyện với nhau**. Supabase phục vụ cả 4 máy bằng đúng
   MỘT giao thức: một HTTP POST kèm JSON.
2. **Sync là tính năng trả tiền ⇒ cổng phải ở phía server.** CloudKit private database đồng bộ
   client-to-client; server của mình không đứng giữa, nên **không có chỗ nào để từ chối một user
   free**. Với Supabase, cổng tier nằm trong RLS policy + RPC — không bypass được bằng build sửa.
3. **Hai danh tính vs một.** Danh tính của Volar là Supabase Auth (email OTP,
   `contracts/account-auth.md`), entitlement gắn với `auth.users.id`. CloudKit gắn với tài khoản
   iCloud. Chọn CloudKit là chấp nhận "user Pro theo Supabase, dữ liệu theo iCloud" — hai thứ có
   thể lệch nhau (đăng nhập Volar bằng email A, iCloud của máy là B), và không có cách nào hoà giải.
4. **`@Attribute(.unique)` được ở lại.** Xem §0(3). CloudKit đòi gỡ `.unique` khỏi 4 model *trên dữ
   liệu người dùng thật*, đúng thứ backlog gọi là "không sửa được sau khi đã có user thật". Chọn
   Supabase = không phải đụng tới nó, và `.unique` còn **có ích** cho sync (upsert theo id an toàn,
   không đẻ hàng trùng khi pull đua với insert nội bộ).
5. **Anh Khôi không debug được CloudKit từ Windows.** Không Swift, không Xcode, không CloudKit
   Dashboard, và schema CloudKit phải deploy Development→Production bằng tay. Lỗi sync CloudKit nổi
   tiếng là mù. Supabase thì debug được bằng `curl` + `psql` ngay trên máy này.

**Cái giá phải trả, nói thẳng:** phải tự viết engine sync (~700–900 dòng Swift + ~200 dòng SQL).
CloudKit cho không phần đó. Đổi lại, cái giá của CloudKit là **không giới hạn và không đo được từ
máy này**.

**Điều kiện duy nhất lật ngược quyết định này:** anh Khôi bỏ hẳn bản Windows **VÀ** coi "nội dung
task nằm trên server của mình" là điều không chấp nhận được. Cả hai phải cùng đúng.

---

## 2. Quyết định lớn thứ hai: sync là bản SAO, không bao giờ là bản GỐC

**Chốt (anh Khôi, 2026-08-09), nguyên văn:** *"task tạo ở đâu nằm ở đó thôi — **bản gốc luôn ở
device tạo ra nó, bản trên cloud chỉ là replica**."*

Mỗi máy luôn giữ một bản replica ĐẦY ĐỦ trên đĩa. Server không bao giờ là nơi duy nhất chứa một
task. Đây là bất biến chi phối mọi thứ còn lại, và là câu trả lời dứt khoát cho §8:

- Tắt sync, hết Pro, mất mạng, xoá tài khoản → **máy vẫn còn nguyên mọi task nó từng thấy**.
- Máy B đã kéo về replica của task do máy A tạo thì **B giữ nguyên replica đó và sửa được bình
  thường** khi sync ngừng — **không đánh dấu chỉ-đọc, không xoá, không làm mờ**. Nó chỉ không đẩy
  đi đâu nữa.
- Không có khái niệm "task chỉ có trên cloud". Không lazy-load, không phân trang phía UI.
- ⇒ Không có kịch bản nào mà thao tác về tài khoản/thanh toán/công tắc làm biến mất việc của user.

Với sản phẩm ADHD, *mất một task là hỏng niềm tin vĩnh viễn*. Bất biến này là hàng rào thứ nhất;
LWW + tombstone + `sync_rejects` (§4, §5) là hàng rào thứ hai và thứ ba.

---

## 3. Sync cái gì — và cái gì CỐ Ý không

| Dữ liệu | Quyết định | Lý do |
|---|---|---|
| `VolarTask` | **Hai chiều** | Lõi. `TaskCue`, `Recurrence`, `ReminderPolicy`, `DelegationMeta`, `conditions` là field của nó nên đi kèm miễn phí. ⚠️ `isSensitive` thì **KHÔNG** đi kèm miễn phí — xem ngay dưới bảng. |
| `CompletionEvent` | **Hai chiều, chỉ-thêm** | Bất biến từ lúc tạo (`CompletionLog.swift:11`). Không bao giờ update/delete ⇒ **không thể xung đột**: `on conflict do nothing`. Watch bấm xong thì phải đẻ được event, nên vẫn cần chiều lên. |
| `ReminderRecord` | **KHÔNG** | Suy ra được — §0(4). Mỗi máy tự `derive` từ task đã sync. Sync nó vừa thừa vừa sai: budget notification khác nhau từng máy, và state `delivered/satisfied` là bài toán khác (chống nổ chuông), xem §11. |
| `ParseCorrection` | **KHÔNG — và cần anh Khôi gật riêng nếu muốn đổi** | §0(5). Đẩy nó lên = biến "transcript nguyên văn" từ *dữ liệu tạm để parse một câu* thành *dataset huấn luyện nằm trên server*. Lời hứa khác hẳn. |
| Settings (`hasOnboardedV1`, `morningFrogLastShown`, `triageLastShownWeek`, ambient background) | **KHÔNG** | Bản chất per-device. Grep `@AppStorage`/`UserDefaults`: chỉ 4 khoá, đều là trạng thái UI. |
| Global `ReminderPolicy`, `VoiceDeliveryMode` | **KHÔNG (đợt này)** | Là preference cấp user thật, đáng sync — nhưng là domain sync thứ hai. §11. |
| Focus session | **KHÔNG (đợt này)** | Hiện **không persist chút nào** (chỉ sống trong `AppState`). Muốn sync phải persist trước. §11. |
| Frog của ngày | **Đi kèm `VolarTask.frog`** | ⚠️ Bất biến "chỉ một frog" là bất biến TOÀN CỤC, LWW theo từng hàng không giữ được nó: hai máy offline set hai frog khác nhau ⇒ merge xong có hai frog. Cách chữa rẻ: đọc ra thì chọn frog có `updatedAt` mới nhất, `AppState` tự dọn. Ghi ở đây để khỏi tưởng là bug. |
| `VolarTask.isSensitive` | **Hai chiều, nhưng phải THÊM TAY vào payload** | Xem §3.1 ngay dưới. |

### 3.1 `isSensitive` — trường duy nhất không tự đi theo `TaskItem` (bổ sung 2026-08-10)

Phát hiện khi Opus review bản implement đầu tiên. `isSensitive` nghĩa là *"đừng đọc to tiêu đề task
này"* (`VoiceReminderChannel.speakReminder`). Nó **chỉ sống trên `VolarTask`**, cố ý không xỏ qua
`TaskItem` (`VolarTask.swift:120` + `TaskStore.swift` giải thích seam đó, và `ReminderScheduler`
đang dựa vào nó). Nhưng `SyncPayload` dựng từ `TaskItem` ⇒ **cờ này lặng lẽ không đi qua sync**.

Hậu quả cụ thể: task đánh dấu nhạy cảm ở máy A, sang máy B mất cờ, máy B **đọc to tiêu đề thật**.
Một dòng kiểu *"đi khám lại kết quả sinh thiết"* bị đọc giữa phòng họp là loại sự cố người dùng gỡ
app ngay và không quay lại. Đây không phải lỗi thẩm mỹ.

**Chốt: đưa `isSensitive` thẳng vào payload sync (đọc từ `VolarTask` lúc dựng, ghi lại lúc apply),
KHÔNG kéo nó lên `TaskItem`** — seam kia có lý do và kéo lên sẽ lan ra nhiều file.

🔴 **Hướng an toàn khi thiếu dữ liệu TRÊN DÂY là `true`, không phải `false`.** Payload không có key
`isSensitive` (client phiên bản khác — bản .NET Windows là ca thật) ⇒ decode ra **`true`**, coi như
nhạy cảm. Thà im lặng nhầm còn hơn đọc to nhầm.

**Bất đối xứng ba chiều, cố ý — đừng "sửa cho nhất quán":**

| Chỗ | Mặc định | Vì sao |
|---|---|---|
| Cột local (`VolarTask.isSensitive`) | `false` | Đổi thành `true` sẽ biến **mọi task đang có** của user thành nhạy cảm lúc nâng cấp, hỏng mọi lời nhắc đang chạy — để bảo vệ đúng 0 task, vì chưa từng có đường nào set `true`. |
| Đọc local (`TaskStore.isSensitive(_:)`) | `?? false` | `nil` ở đây nghĩa là **"không tìm thấy task"**, không phải "thiếu dữ liệu". |
| Decode trên dây (`TaskPayload`) | `?? true` | Ở đây thiếu key thật sự nghĩa là **"một client khác không nói được điều này"**, và đoán sai theo hướng đọc-to là hướng gây hại. |

**Hệ quả cần biết trước:** bản .NET Windows hiện chưa có trường này. Chừng nào nó chưa gửi
`isSensitive`, **mọi task tạo trên Windows sẽ thành "nhạy cảm" trên máy Apple** ⇒ lời nhắc đọc câu
chung chung thay vì tiêu đề. Đó là suy giảm nhìn thấy được, nhưng là hướng lệch AN TOÀN — và cách
chữa là bản .NET implement trường đó, không phải đảo mặc định.

---

## 4. Giao thức: MỘT RPC, một transaction, push trước pull sau

**Chốt: client gọi thẳng PostgREST RPC `POST /rest/v1/rpc/sync_exchange`. KHÔNG dựng edge
function.**

Lý do:
1. Sync là lời gọi mạng dày nhất của app. Edge function thêm cold start + một tầng phải deploy/
   version, mà nó chẳng làm gì ngoài chuyển tiếp.
2. **Push và pull nằm trong CÙNG một transaction** ⇒ không bao giờ có trạng thái "đẩy xong, kéo
   hỏng, cursor sai". Tách hai lời gọi là tự chuốc split-brain.
3. Hình dạng lời gọi y hệt mọi thứ repo này đã hand-roll: một `URLRequest` POST + JSON + hai header
   (`apikey`, `Authorization: Bearer`) — đúng lý do `AccountService.swift:1-13` từ chối gói
   `supabase-swift`. Client .NET cũng chỉ cần đúng một POST đó.

```
POST /rest/v1/rpc/sync_exchange
  apikey: <publishable key>            // đã có sẵn ở AccountService.apiKey
  Authorization: Bearer <access_token> // đã có sẵn ở AccountService.validAccessToken()
  {
    "p_cursor_tasks":       "2026-08-09T10:00:00Z" | null,
    "p_cursor_completions": "2026-08-09T10:00:00Z" | null,
    "p_device":             "<uuid ổn định của máy>",
    "p_device_label":       "MacBook Pro · macOS",
    "p_tasks":              [ {id, updatedAt, deletedAt, schemaVersion, payload}, ... ],
    "p_completions":        [ {id, taskId, completedAt, payload}, ... ],
    "p_limit":              500
  }
→ 200 { cursorTasks, cursorCompletions, tasks[], completions[], hasMore, rejected[] }
→ 403 "sync_pro_required"  — chưa/hết Pro          → gợi ý nâng cấp
→ 403 "sync_disabled"      — công tắc đang tắt      → gợi ý bật, KHÔNG phải lỗi
→ lỗi mạng                 — offline/timeout        → im lặng, thử lại sau
```

Ba kết cục cuối là **ba thứ khác nhau**, không được gộp — xem §8.2. Sau mọi 403, client gọi
`POST /rest/v1/rpc/volar_sync_state` (không bị gate) để lấy trạng thái thật.

**Cursor là `server_updated_at`, không phải `updated_at`.** Hai đồng hồ khác nhau, cố ý:

- `updated_at` = đồng hồ **logic của client**, chỉ dùng để **phân xử ai thắng**.
- `server_updated_at` = `now()` của Postgres, chỉ dùng làm **con trỏ "tôi đã thấy tới đâu"**.

Trộn hai cái vào một cột là lỗi kinh điển: một máy lệch đồng hồ sang năm 2030 vừa thắng mọi xung
đột vĩnh viễn, vừa đẩy cursor của mọi máy khác vượt qua dữ liệu thật. Tách ra thì lệch đồng hồ chỉ
hỏng phân xử, không làm mất bản ghi — và §5 kẹp luôn phần phân xử.

**Khoảng chồng lấn 2 giây.** Hai transaction lấy `now()` lúc bắt đầu; cái bắt đầu sau vẫn có thể
commit trước ⇒ có khe. Hàm luôn quét `server_updated_at > p_cursor - interval '2 seconds'`. Áp dụng
lại một bản ghi đã áp dụng là **no-op** (LWW idempotent), nên chồng lấn không tốn gì ngoài vài
hàng thừa. Đây là chủ ý, không phải nợ kỹ thuật — nó rẻ hơn nhiều so với một per-user sequence có
row lock.

**🔴 THỨ TỰ BẮT BUỘC: áp dữ liệu xuống đĩa XONG rồi mới ghi cursor. Không bao giờ ngược lại.**
(Bổ sung 2026-08-10 — bản đầu của §4 không nói rõ, và đây là loại thứ tự người sau sẽ đảo lại "cho
gọn" mà không biết mình vừa làm gì.)

```
nhận response → applyRemote + applyRemoteCompletions → save() THÀNH CÔNG → rồi mới ghi cursor
```

Cursor nghĩa là **"tôi đã đọc tới đây rồi, đừng gửi lại nữa"**. Ghi nó trước khi dữ liệu thật sự nằm
trên đĩa là tự khai một lời nói dối mà không có cách nào rút lại: lần sync sau server **không trả
lại** những hàng đó nữa, vì client đã bảo là đọc rồi. **Mất vĩnh viễn, im lặng, không tự phục hồi
được.**

Hai đường dẫn tới đúng lỗi đó, và **cả hai đều phải chặn**:

1. **App bị kill giữa chừng.** iOS đình chỉ app rất nhanh khi vào background — đúng lúc chu kỳ 30
   giây (§7) vừa chạy. Chặn bằng thứ tự ở trên.
2. **`context.save()` NÉM LỖI mà không ai nghe** (đĩa đầy, lỗi ràng buộc). `TaskStore.save()` viết
   `try? context.save()` — nuốt lỗi im lặng. Nếu `applyRemote` vẫn trả về bình thường thì cursor
   vẫn nhảy, và **mất dữ liệu xảy ra mà không cần crash nào cả.** ⇒ `applyRemote` /
   `applyRemoteCompletions` phải **NÉM LỖI khi ghi đĩa hỏng**, và engine phải coi đó là một lượt
   sync thất bại: **không nhảy cursor, không xoá `lastFailure`, để lượt sau kéo lại.**

**Khoảng chồng lấn 2 giây KHÔNG cứu được ca này** — nó sinh ra để vá khe commit của transaction và
chỉ lùi đúng 2 giây; app chết (hoặc đĩa đầy) sau đó thì dữ liệu nằm ngoài hẳn cửa sổ ấy.

**Có nên nhét việc ghi cursor vào cùng một transaction SwiftData với việc áp dữ liệu không? KHÔNG —
và đây là lý do.** Cursor sống ở `UserDefaults`, không có cách nào cho nó tham gia một transaction
của `ModelContext`; muốn nguyên tử thật thì phải biến cursor thành một `@Model` riêng, tức thêm một
entity vào schema + một lần migration nữa cho một cái kho vốn đã đổi 6 lần trong 3 tuần. Cái giá đó
mua về đúng một thứ: khỏi **kéo lại** vài hàng. Mà kéo lại thì **vô hại** — LWW idempotent, áp lại
một hàng đã áp là no-op (chính là lý do khoảng chồng lấn 2 giây tồn tại được).

Nói cách khác: với thứ tự đúng, **mọi khe crash đều rơi về phía AN TOÀN** (kéo thừa), không có khe
nào rơi về phía nguy hiểm (bỏ sót). Một transaction chung sẽ đổi "kéo thừa" lấy "thêm một entity và
một migration" — sai hướng đánh đổi.

---

## 5. Xung đột: LWW theo BẢN GHI, và kẻ thua được giữ lại

**Chốt: last-write-wins ở mức bản ghi, so bằng `updated_at`. Bản thua KHÔNG bị vứt — nó rơi vào
`public.sync_rejects`.**

Ba lựa chọn đã cân:

| Cách | Mất gì trong tình huống tệ nhất | Giá |
|---|---|---|
| **LWW bản ghi** (chọn) | Hai máy offline cùng sửa 1 task: máy A đổi tiêu đề, máy B bấm xong → **một trong hai sửa đổi biến mất khỏi bản live** (vẫn còn trong `sync_rejects`). | Thấp. Một cột + một `where` trong upsert. |
| LWW theo field | Không mất gì trong ca trên. | Cao: ~25 field × timestamp, SwiftData không có metadata per-field, mọi đường ghi phải đóng dấu. |
| Operation log / CRDT | Không mất gì bao giờ. | Rất cao: sắp thứ tự, idempotency, nén log, và client phải replay được. Quá tay cho một user với ≤4 máy. |

Vì sao LWW bản ghi là đủ **cho sản phẩm này**: bất đối xứng giữa hai loại mất mát.

- Mất **cả task** (tạo/xoá) = thảm hoạ. LWW **không bao giờ** gây ra nó: id do client sinh, `insert`
  không bao giờ bị ghi đè bởi sự vắng mặt, và xoá là tombstone (§6).
- Mất **một field sửa đồng thời** = khó chịu. Hiếm (một người, hai máy, cùng một task, cùng lúc,
  cùng offline), và `sync_rejects` giữ nguyên văn bản thua để cứu được.

`sync_rejects` chỉ ghi khi push **thật sự bị từ chối vì cũ** — tức chỉ khi có xung đột thật. Nó
không phải bản sao toàn bộ lịch sử; nó là hộp đen. UI cho nó (§11) hoãn, dữ liệu thì không hoãn.

**Kẹp lệch đồng hồ:** server nhận `updated_at` nhưng lấy `least(updated_at, now() + 1 phút)`. Một
máy sai giờ không thể chiếm quyền thắng vĩnh viễn. Client đọc lại `updated_at` server trả về và
nhận làm chuẩn.

---

## 6. Xoá: tombstone, cả trên server LẪN trên máy

**Chốt: `deleted_at timestamptz` trên server; và `VolarTask.deletedAt: Date?` soft-delete luôn ở
local.**

Tombstone phía server là bắt buộc, không phải lựa chọn: xoá cứng thì máy đang offline không bao giờ
biết đã có lệnh xoá — nó chỉ thấy "server không có task này" và **đẩy ngược lên, hồi sinh task**.
Đây đúng loại lỗi backlog 2026-08-09 gọi là "làm user gỡ app".

Soft-delete phía **local** là quyết định đáng cân hơn. Hai cách:

- (a) Xoá cứng local + một outbox riêng ghi lệnh xoá. ⇒ pull phải biết bỏ qua id đang có trong
  outbox, nếu không nó re-insert lại task vừa xoá. Thêm một cơ chế thứ hai và một cái bẫy thứ hai.
- (b) **Soft-delete local** (chọn): xoá trở thành một lần sửa field bình thường. Toàn bộ engine sync
  chỉ còn **MỘT** cơ chế. Giá: mọi `FetchDescriptor` trong `TaskStore.swift` phải lọc
  `deletedAt == nil` (5 chỗ: `fetchModel`, `fetchAllModels`, `fetchChildren`, `hasChildren`, và
  predicate trong `delete`). Đổi lại "không nuốt mất việc" đúng thêm một tầng nữa — cái đã xoá vẫn
  nằm trên đĩa.

`TaskStore.delete(_:)` giữ nguyên phần dọn tham chiếu (`.taskDone` trỏ tới id đã xoá, `parentId` của
con) và vẫn trả `eligibilityDiff` — chỉ đổi `context.delete(target)` thành đặt `deletedAt`.

**Giữ tombstone bao lâu:** server **90 ngày**, sau đó pg_cron dọn (ghi note, KHÔNG implement — đúng
convention của 0002/0004). Local **30 ngày**. Hệ quả cố ý: một máy offline **>90 ngày** rồi online
lại sẽ **hồi sinh** những task nó đã xoá lúc offline. Đó là hướng lệch an toàn (giữ thừa hơn nuốt
mất) và được chọn có ý thức, không phải sót.

---

## 7. Hàng đợi offline: cờ bẩn + đẩy nguyên hàng, đóng dấu ở ĐÚNG MỘT chỗ

**Chốt: KHÔNG có op-queue. Ba field trên `VolarTask` là toàn bộ hàng đợi.**

```swift
// UNVERIFIED — chưa compile bao giờ.
// Thêm vào VolarTask (@Model). Cả ba đều theo đúng convention lightweight-migration
// mà file này đã dùng cho `details`/`kindRaw`/`switchAwayCount`: non-optional phải có
// default là một biểu thức khởi tạo TRẦN (không tham chiếu static property), optional
// thì không cần gì.
var updatedAt: Date = Date(timeIntervalSince1970: 0)  // 0 = "chưa backfill", xem dưới
var deletedAt: Date?                                   // §6
var syncedAt: Date?                                    // updatedAt đã được server xác nhận

/// Hàng này đang chờ đẩy?
var isPendingSync: Bool { syncedAt == nil || syncedAt! < updatedAt }
```

Đẩy = gửi **mọi hàng `isPendingSync`** (batch ≤500). Ưu điểm so với op-queue: tự gộp (sửa 20 lần
một task = 1 lần đẩy), sống sót crash mà không cần cơ chế nào thêm, không bao giờ sai thứ tự. Nhược
điểm: mất các trạng thái trung gian — không sao, LWW bản ghi vốn đã vứt chúng rồi, hai thứ nhất
quán với nhau.

**Đóng dấu `updatedAt` ở đâu — đây là chỗ dễ hỏng nhất của cả thiết kế.** Rải `updatedAt = Date()`
vào 12 mutator của `TaskStore` là công thức để cái thứ 13 quên mất và task đó im lặng không bao giờ
sync. Nhưng **cả 12 mutator đều kết thúc bằng `save()`** (`TaskStore.swift:582`). Vậy:

```swift
// UNVERIFIED — `changedModelsArray` là API SwiftData; phải xác nhận tên + tính khả dụng
// trên macOS 14 / iOS 17 / watchOS 10 khi build trên Mac.
private func save() {
    let stamp = Date()
    for model in context.insertedModelsArray + context.changedModelsArray {
        (model as? VolarTask)?.updatedAt = stamp
    }
    try? context.save()
}
```

Một chỗ duy nhất, bắt được cả mutator hiện tại lẫn mọi mutator viết sau này. **Nếu API đó không
tồn tại/không dùng được trên Mac**, phương án dự phòng là một helper `private func touch(_ model:
VolarTask)` gọi tường minh ở 12 chỗ, kèm một test đếm số call site — kém hơn hẳn, nhưng phải có
đường lui viết sẵn.

**Backfill một lần** cho user đã cài: `fetchAll()` gặp hàng có `updatedAt == Date(timeIntervalSince1970: 0)`
thì đặt `= completedAt ?? createdAt`, y hệt cơ chế `foldLegacyDependsOn()` đang có
(`VolarTask.swift:241`) — idempotent, chạy mãi cũng không sao.

**Khi nào chạy** (anh Khôi sửa 2026-08-10, xem ngay dưới): app vào foreground · sau mỗi lần sửa
(debounce ~2s) · **mỗi ~30 giây khi app đang FOREGROUND** · watch: lúc activate + lúc refresh
complication. **Không realtime, không websocket, không APNs** đợt này (§12).

**Vì sao 30 giây chứ không phải 5 phút — anh Khôi chốt 2026-08-10.** Bản đầu của §7 viết "mỗi 5
phút khi đang mở". Câu hỏi làm lộ vấn đề: *hai máy cùng đang mở thì bên kia biết lúc nào?* Với 5
phút thì máy A bấm xong, người dùng nhìn sang máy B vẫn thấy task nằm nguyên đó — và **họ đọc điều
đó thành "app không ăn", không phải "chờ tí nữa"**. Với sản phẩm ADHD, một cái tick không xuất hiện
là mất niềm tin ngay lập tức, không phải một bất tiện nhỏ. Anh Khôi chọn hạ chu kỳ thay vì thêm
Supabase Realtime, vì nó không cần một mẩu hạ tầng mới nào.

Ba ràng buộc đi kèm, **không được bỏ sót cái nào**:

1. **Chỉ chạy khi FOREGROUND. Xuống background là dừng hẳn** — huỷ timer, không để nó sống tiếp
   dưới nền. Thiếu điều này thì "30 giây" biến ngay thành một cỗ máy đốt pin, và đó là loại lỗi
   người dùng không bao giờ quy được về sync.
2. **KHÔNG áp cho watch.** Watch giữ nguyên activate-based như trên. Một chiếc watch chạy LTE mà
   poll 30 giây thì hết pin trước bữa trưa.
3. **Có backoff, và đợt này LÀM.** Sau **4 lượt liên tiếp không có gì mới** thì nhân đôi chu kỳ
   (30s → 60s → 120s → 240s, **trần 300s**); gặp `.offline` thì lùi ngay một nấc. **Về lại 30 giây
   ngay lập tức** khi có bất kỳ dấu hiệu nào rằng cửa sổ này đang sống: user sửa gì đó local · app
   vừa vào foreground · lượt vừa rồi kéo về được thay đổi thật · **mạng vừa khôi phục** (xem ngay
   dưới). Nghĩa là **một máy đang được dùng thì luôn ở 30 giây**; chỉ máy mở mà bỏ đó mới trôi ra
   xa. Không có backoff thì một laptop mở cả ngày = ~2.880 request/ngày/máy thuần tiếng ồn, nhân
   bốn máy — tốn quota mà không mua được gì.

**Trigger reset thứ tư: mạng khôi phục (`NWPathMonitor`) — bổ sung 2026-08-10.** Ba trigger đầu bỏ
sót đúng một ca, và là ca người dùng để ý nhất: **app đang foreground, mất mạng, rồi có mạng lại,
mà user không chạm vào gì cả.** Mỗi lượt `.offline` lùi một nấc, nên mất mạng chừng mười phút là
chạm trần 300s. User không gõ gì (không có `.localEdit`) và không rời app (không có `.foreground`)
⇒ không trigger reset nào chạy ⇒ mạng về rồi vẫn **chờ tới 5 phút** mới có lượt thử kế tiếp. Từ
phía người dùng đó là app đơ — và đơ đúng vào lúc họ vừa lấy lại wifi nên đang ngồi chờ nó chạy.

`NWPathMonitor` (framework `Network`, có đủ trên macOS/iOS/watchOS nên **không cần `#if os()`**) vá
đúng ca đó. Bốn ràng buộc để nó không phản tác dụng:

- **Chỉ phản ứng khi CHUYỂN TRẠNG THÁI** `unsatisfied → satisfied`, không phải mọi sự kiện monitor
  bắn ra. `NWPathMonitor` bắn khá dày khi đổi interface (wifi ↔ LTE); không lọc thì nó thành một cỗ
  máy gọi API.
- **Chỉ khi lượt trước thất bại vì `.offline`.** Mạng đổi interface trong lúc mọi thứ đang chạy tốt
  thì không có lý do gì phải sync gấp.
- **Đi qua đúng `requestSync(reason:)`** như mọi trigger khác, để "một chỗ duy nhất quyết định có
  chạy round bây giờ không" vẫn đúng. Debounce 2 giây tự gộp nếu nó trùng một `.localEdit`.
- `NWPathMonitor` **đôi khi báo `.satisfied` trước khi thật sự đi được** (captive portal, wifi vừa
  associate xong). Vô hại ở đây: lời gọi hỏng chỉ im lặng và lùi thêm một nấc. Ghi ra để người sau
  khỏi tưởng là bug và đi "sửa".

**Write-through — và đẩy hỏng thì TUYỆT ĐỐI không rollback local.** anh Khôi xác nhận mô hình ghi:
*"khi update và mark done sẽ update cả cloud lẫn on device."* Cơ chế cờ bẩn ở trên chính là hình
dạng đúng của câu đó, với một điều kiện phải viết ra rõ:

1. `TaskStore` ghi local và `save()` — **giao dịch kết thúc TẠI ĐÂY**. UI đã cập nhật, việc đã xong.
2. `updatedAt` được đóng dấu ⇒ hàng thành pending.
3. `SyncEngine` đẩy. Thành công thì đặt `syncedAt`; **thất bại thì không làm gì cả** — hàng vẫn
   pending, lần đẩy sau tự gom.

Hỏng mạng, 403 vì công tắc tắt, server 500, app bị kill giữa chừng: **không đường nào trong số đó
được phép đụng vào dữ liệu local.** Một app ADHD mà bấm "xong" rồi thấy dấu tích bật ngược lại vì
wifi rớt thì đã phá đúng thứ nó tồn tại để bảo vệ. Cờ bẩn là thứ biến "đẩy hỏng" thành một no-op
thay vì một sự kiện mất dữ liệu — đó là lý do nó được chọn thay cho "ghi thẳng, chờ server xác
nhận".

**Đặt ở đâu:** thư mục mới `Shared/Sync/` — `SyncEngine.swift` (actor, mạng), `SyncPayload.swift`
(Codable wire type, PINNED như `TaskCue`), `SyncMerge.swift` (**quyết định thuần**: `(local,
remote) -> Apply | Skip`, không `Date()`, không `URLSession`, không `ModelContext` — đúng
convention `CueFiring`/`WaitingMode`/`FullScreenEscalationDecision`, để test được mà không cần
mạng). `TaskStore` chỉ mọc thêm `pendingForSync()` / `applyRemote(_:)`.

⚠️ **`SyncPayload` không được là `TaskItem`.** `TaskItem` không `Codable`, và quan trọng hơn: shape
trên dây phải đổi CHẬM hơn shape trong app. `SyncPayload` là struct riêng, `schemaVersion: Int`,
field-đối-field, và bản .NET copy verbatim.

---

## 8. Cổng: HAI điều kiện — Pro **VÀ** user tự bật

**Chốt (anh Khôi, 2026-08-09), nguyên văn:** *"nếu pro và user bật sync across device thì sync task
lên db."* ⇒ **Pro một mình KHÔNG tự bật sync.** Sync là **opt-in**, hai điều kiện chứ không một.

**Chốt thứ hai: công tắc ở mức TÀI KHOẢN, không phải từng máy.** anh Khôi đã được nêu rõ mặt trái
và vẫn chọn account-level. Mặt trái đó phải được viết ra ở đây và nói thẳng trong UI (§8.1):

> **Một máy bật là dữ liệu của MỌI máy đang đăng nhập tài khoản đó lên cloud.** Và một máy mới đăng
> nhập sau đó **tự động bắt đầu sync mà không hỏi lại**.

### 8.0 Công tắc phải sống ở SERVER

`UserDefaults` không dùng được. "Mức tài khoản" mà lưu trên từng máy thì chỉ là lời hứa suông: bốn
máy sẽ tin bốn trạng thái khác nhau, và cái máy tin nhầm sẽ đẩy dữ liệu lên trong đúng lúc user
tưởng đã tắt. Nên: **một dòng `public.sync_prefs` mỗi tài khoản**, mọi máy đọc cùng một chỗ.

Và vì nó đã ở server, nó **đi thẳng vào RLS policy** cùng `volar_is_pro()`:

```sql
volar_sync_allowed() = volar_is_pro() AND volar_sync_enabled()
```

Đây là điểm chặt hơn hẳn gate ở client, đừng bỏ lỡ: **một máy đang offline, chưa kịp biết user vừa
tắt sync ở máy khác, vẫn KHÔNG ghi lên được.** Gate ở client là lời khuyên; gate ở policy là luật.

### 8.1 Bật lần đầu: màn xác nhận phải trung thực

Bật là một hành động một-chiều-về-mặt-riêng-tư (dữ liệu đã lên server rồi thì tắt không thu hồi
được, xem §8.3). Nên nó cần một màn xác nhận, và màn đó **không được giấu mặt trái của
account-level**. Nội dung bắt buộc:

- Bật sync sẽ đẩy **toàn bộ task trên máy này** lên server Volar — kể cả `sourceTranscript`, tức
  lời nói nguyên văn.
- Công tắc này **áp cho cả tài khoản**: mọi máy khác đang đăng nhập tài khoản này cũng sẽ bắt đầu
  đẩy dữ liệu của chúng lên, và mọi máy đăng nhập sau này cũng vậy — không hỏi lại.
- Tắt lại bất cứ lúc nào, nhưng **tắt không xoá cái đã lên**; muốn xoá thì có nút riêng.

⚠️ **Giới hạn đã biết, và tôi cố ý KHÔNG chữa:** màn xác nhận **không liệt kê được** máy nào đang
đăng nhập tài khoản này ở lần bật đầu tiên. Muốn liệt kê thì phải có bảng đăng ký thiết bị mà mọi
máy ping vào lúc khởi động — tức là **báo về server sự tồn tại của từng máy TRƯỚC KHI user đồng ý**,
đúng cái mà màn xác nhận này sinh ra để bảo vệ. Nên: bảng `sync_devices` chỉ được ghi từ bên trong
`sync_exchange` (chỉ máy thật sự đang sync mới có tên), Settings hiển thị danh sách đó **sau khi đã
bật**, còn màn xác nhận lần đầu nói thẳng **luật** thay vì bịa ra một danh sách nó không có.

### 8.2 Máy khác biết công tắc đổi bằng cách nào

Hai đường, cả hai đều cần:

1. **`volar_sync_state()`** — RPC đọc được **kể cả khi hết Pro hoặc đã tắt sync** (cố ý không gate,
   nếu không thì một máy bị từ chối sẽ không bao giờ biết vì sao). Trả `{isPro, syncEnabled,
   enabledAt, enabledByDevice, devices[]}`. Client gọi lúc khởi động, lúc vào foreground, và **sau
   mọi 403**. Đây là cơ chế lan truyền: không push, không websocket — poll rẻ ở đúng ba thời điểm
   user có thể nhận ra sự thay đổi.
2. **Mã lỗi phân biệt được từ `sync_exchange`.** Ba tình huống trông giống nhau ở tầng HTTP nhưng
   phải hiển thị khác hẳn:

   | Mã | Nghĩa | UI |
   |---|---|---|
   | `sync_pro_required` (403) | hết/chưa có Pro | "Sync là tính năng Pro" + gợi ý nâng cấp |
   | `sync_disabled` (403) | công tắc đang tắt | "Sync đang tắt cho tài khoản này" + nút bật. **KHÔNG phải lỗi** |
   | lỗi mạng | offline/timeout | **im lặng**, thử lại sau. Không hiện gì |

   Gộp cả ba thành "sync lỗi" là cách chắc chắn nhất để user tắt công tắc ở máy khác rồi ngồi debug
   wifi. Bắt buộc phân biệt.

### 8.3 Tắt công tắc — khác gì hết Pro?

**Về dữ liệu: không khác gì cả. Cả hai đều KHÔNG xoá gì.** (anh Khôi chốt: *"giữ nguyên trên B"*.)

| | Local | Trên server | Đẩy/kéo |
|---|---|---|---|
| **Hết Pro** | nguyên vẹn, sửa được bình thường | giữ **vô thời hạn** | dừng cả hai chiều |
| **Tắt công tắc** | nguyên vẹn, sửa được bình thường | giữ **vô thời hạn** | dừng cả hai chiều |
| **Bấm "Xoá dữ liệu trên server"** | nguyên vẹn | **xoá thật** | — |

Khác biệt duy nhất là **câu chữ** và **cách bật lại**: hết Pro thì gia hạn, tắt công tắc thì bật
lại. Cả hai đều **không** cần làm gì với dữ liệu.

Chi tiết phải đúng:

- Hàng đang pending ở máy offline lúc công tắc tắt: **giữ nguyên cờ pending**. Lần đẩy tiếp theo bị
  RLS từ chối → client đọc `volar_sync_state()`, thấy tắt, dừng lại. **Không xoá cờ, không xoá
  hàng.** Bật lại thì hàng đợi tự chảy tiếp, LWW lo phần còn lại. Không mất gì.
- **Xoá thật chỉ có một đường: `volar_sync_purge()`, user tự bấm.** Không job nào gọi nó, tắt công
  tắc **không** gọi nó. Lý do: tắt nhầm một công tắc không được phép là một hành động huỷ diệt, và
  "tắt rồi bật lại" phải là chuyện vô hại.
- **Bật lại một công tắc đang bật** không phải một lần bật mới — `enabled_at` giữ mốc cũ, để
  Settings hiển thị "đã bật từ ..." là mốc thật.
- **Tắt thì LUÔN được, kể cả đã hết Pro.** Policy viết là `sync_enabled is false or
  volar_is_pro()`. Một user hết hạn mà không tắt được công tắc của chính mình là thiết kế thù địch.

### 8.4 Vì sao gate bằng Pro là hợp lệ

Không mâu thuẫn với nguyên tắc "TÍNH NĂNG miễn phí hết — chỉ COMPUTE cao cấp (cloud) là trả tiền"
(`product-vision-v2.md:104`): sync là **lưu trữ + băng thông trên server của mình**, đúng loại
"cloud" nguyên tắc nói tới, không phải khoá một tính năng chạy trên máy user. App local vẫn đầy đủ
100% ở tier free. `product-vision-v2.md` cũng đã ghi sẵn "v3 ships (iPhone/Watch + sync): cân nhắc
$9.99+ — **mốc nâng mạnh nhất**".

**Xoá tài khoản**: cả năm bảng `sync_*` đều `references auth.users(id) on delete cascade` ⇒
`POST /subscription/delete-account` (đang dùng `auth.admin.deleteUser`) tự động xoá sạch. **Bắt
buộc** — Apple Guideline 5.1.1(v).

**Hệ quả sản phẩm, và nó lại hoá ra đẹp:** watch của user free **vẫn chạy khi iPhone ở gần** (qua
`WCSession`, plan 007 §7 bẫy 3 vẫn đúng), và **chỉ standalone khi có Pro + công tắc bật**. Đó là
ranh giới free/paid tự nhiên nhất mà sản phẩm này từng có — không cắt tính năng, chỉ cắt "chạy được
khi xa điện thoại", đúng cái tốn tiền server.

---

## 9. Bảo mật + riêng tư

**Ranh giới an ninh = cách ly giữa các user, và nó phải do DATABASE ép, không phải do TypeScript.**

Repo hiện có convention: bật RLS, **không policy nào**, mọi thứ đi qua service-role trong edge
function (`entitlements`, `usage_counters`, ...). **Đợt này lệch convention đó có chủ ý**, và lý do
phải ghi vào header migration:

> Với `entitlements` thì quên một `.eq("user_id", ...)` chỉ lộ tier. Với `sync_tasks` thì quên một
> `.eq` là **lộ toàn bộ task của người khác**. Đây là dữ liệu nhạy cảm nhất sản phẩm có. Ranh giới
> không được phép là "lập trình viên nhớ viết `where`".

Nên: `sync_*` dùng **RLS policy thật** trên `(select auth.uid())`, RPC để `security invoker`, và
client gọi bằng **JWT của chính user** — Postgres từ chối ở tầng dưới cùng dù code phía trên có sai.
`(select auth.uid())` bọc trong `select` là bắt buộc (InitPlan, tính một lần thay vì mỗi hàng).

Cổng cũng nhét vào policy, qua `public.volar_sync_allowed()` = `volar_is_pro()` **AND**
`volar_sync_enabled()` (cả ba đều `security definer`, `set search_path = ''`, tự đọc `auth.uid()`
bên trong, **không nhận tham số user** — không có gì để giả mạo) ⇒ user free **hoặc** một máy chưa
biết công tắc đã tắt đều không ghi được `sync_tasks` **kể cả gọi thẳng PostgREST bằng curl**, không
chỉ là bị client từ chối.

Ngoại lệ duy nhất dùng `security definer` cho một RPC là `volar_sync_purge()` — và nó là ngoại lệ
có lý do: không bảng nào cấp `delete` cho `authenticated` (vì "xoá là `deleted_at`", và một hộp đen
xoá được thì không còn là hộp đen), nên cho user một nút xoá thật mà không mở quyền DELETE ra cho
PostgREST thì phải đi đường definer.

**Payload là JSONB, không phải 25 cột.** Server đợt này là ống dẫn ngu — nó không đọc nội dung task.
Đổi lại schema Swift đổi được mà không cần migration production (model này đã đổi 6 lần trong 3
tuần). Giá: chưa search/lọc phía server được — sau này promote vài cột ra là migration **cộng thêm**,
rẻ. Chặn kích thước bằng `check (octet_length(payload::text) <= 65536)`.

**Riêng tư — nói thẳng, không giấu:** `payload` chứa `title`, `notes`, và **`sourceTranscript` (lời
nói nguyên văn)**. Bật sync = nội dung task **nằm ở trạng thái nghỉ trên server Volar**. Đây là cam
kết mới (§0(2)), phải vào `docs/app-store-privacy.md` và nhãn dinh dưỡng App Store trước khi ship —
`app-store-privacy.md` hiện đang khẳng định điều ngược lại cho CalendarSync và tự yêu cầu "phải suy
lại từ đầu nếu có server-side sync". Không được log `payload` ở bất kỳ đâu.

**E2EE: chốt KHÔNG, đợt này.** Danh tính là email-OTP — **không có mật khẩu để KDF ra khoá**. Chỉ
còn hai đường: recovery phrase (user ADHD làm mất, và mất phrase = mất dữ liệu — vi phạm thẳng §2)
hoặc ký gửi khoá trên server (vô nghĩa). Đây là chủ ý, không phải nợ.

---

## 10. Xác thực trên Watch — và tin xấu: VẪN phải viết `WCSession`

**Chốt: watch nhận danh tính bằng **pair-code một lần** chuyền từ iPhone qua `WCSession` lúc thiết
lập; sau đó watch có **session riêng** và tự refresh qua LTE, không cần iPhone nữa.**

Ba sự thật ép ra thiết kế này:

1. **Keychain KHÔNG chia sẻ giữa iPhone và Watch** — hai thiết bị, hai keychain. `KeychainStore.swift`
   dùng service `tech.kioh.Volar.account`, không access group, và `account-auth.md` còn cấm thêm
   `kSecAttrAccessGroup`. Watch khởi đầu **không có gì**.
2. **Gõ OTP 6 số + địa chỉ email trên màn 40mm là không chấp nhận được.**
3. **KHÔNG được chuyền thẳng `refresh_token` của iPhone sang.** GoTrue **xoay vòng** refresh token:
   watch dùng token đó một lần là **iPhone bị đá ra khỏi phiên**. Hai máy cần **hai chuỗi session
   độc lập**, và chuỗi mới chỉ sinh ra từ một lần đăng nhập thật. Đây là cái bẫy tôi suýt rơi vào,
   ghi lại để không ai "đơn giản hoá" ngược về đó.

Luồng:

```
iPhone (đã đăng nhập)                        Watch
  POST /rest/v1/rpc/volar_mint_pair_code  →  (server: mã ngẫu nhiên 32 byte, lưu hash, TTL 5 phút,
                                              dùng đúng 1 lần, gắn với auth.uid())
  ── WCSession.sendMessage(code) ──────────→  POST /functions/v1/subscription/pair-claim {code}
                                              (server service-role: đổi mã lấy magiclink token cho
                                               user đó → watch tự POST /auth/v1/verify → session RIÊNG)
```

⚠️ **UNVERIFIED**: bước đổi mã lấy session dựa vào `auth.admin.generateLink({type:'magiclink'})` +
`POST /auth/v1/verify`. Nếu API admin không cho, **đường lui**: watch hiện mã 6 ký tự trên màn hình,
user gõ vào iPhone — vẫn không cần bàn phím trên watch.

**Công tắc account-level làm nhẹ được đúng một nửa việc trên watch, không nhiều hơn.** Watch
**không** cần màn bật sync riêng và **không** cần màn xác nhận (§8.1) — nó thừa hưởng trạng thái
của tài khoản, chỉ đọc `volar_sync_state()` rồi hiển thị. Nhưng nó **không** làm nhẹ phần pair-code:
watch vẫn cần một session riêng của chính nó, vì lý do (3) ở trên. Nói cách khác: bớt được 2 màn
hình watchOS, không bớt được một dòng nào của cơ chế xác thực.

⇒ **Trả lời `plan.md` 007 §11 câu 3: CÓ, watch phải chạy standalone, VÀ `WCSession` vẫn phải viết.**
Không phải để chở dữ liệu (đó là việc của sync), mà để (a) chuyền pair-code, (b) phục vụ watch của
user **free** khi iPhone ở gần (§8). Plan 007 §7 bẫy 3 nói "dữ liệu tới watch qua `WCSession` chứ
không qua cloud" — sau đợt này câu đó thành: **cả hai, và mỗi cái phục vụ một tier.**

---

## 11. Ba thứ sync PHƠI RA mà không tự sửa được — cần anh Khôi quyết

Đây không phải việc của sync, nhưng sync biến chúng từ lý thuyết thành bug user nhìn thấy.

1. **🔴 "Hôm nay" theo máy hay theo tài khoản?** (backlog 2026-08-09 đã gọi đây là *"điều kiện tiên
   quyết của sync"*). `VolarCore/NextTask.swift:164` `isNearTermDeadline` hỏi "deadline có cùng
   NGÀY LỊCH với `now` không" — **hai máy khác múi giờ trả lời khác nhau trên cùng một dữ liệu**.
   Trước sync thì không ai thấy. Sau sync: Mac ở VN và watch trên máy bay chỉ hai việc khác nhau,
   không test nào bắt được. **Phải chốt trước khi bật sync**, không phải sau.
2. **🔴 Drift engine giữa các platform.** `nextTask` + `ReminderRecord.derive` được **port tay** sang
   C# (Windows) và sẽ có bản riêng cho watch. Lệch một tầng so sánh hoặc một trong 8 hằng số của
   `derive` thì không compiler nào kêu. Sync làm hai máy **chỉ hai việc khác nhau trên cùng dữ liệu**
   — triệu chứng giống hệt lỗi sync, nhưng nguyên nhân không nằm ở sync. Đề xuất đang treo trong
   backlog (bộ ~40–60 conformance vector JSON) **nên được duyệt cùng đợt này**.
3. **Nổ chuông.** Không sync `ReminderRecord` (§3) ⇒ Mac, iPhone và Watch cùng derive và **cùng
   kêu**. Trên iPhone+Watch có ghép đôi thì hệ thống tự dedupe; watch standalone thì không. Đợt này
   **chấp nhận nổ**, ghi ra để khỏi tưởng là bug. Chữa đúng cách là cơ chế "claim" phía server, §12.

---

## 12. Cái gì đợt này KHÔNG làm (ghi để khỏi trôi)

- **Không** merge theo field, không operation log, không CRDT. LWW bản ghi + `sync_rejects` (§5).
- **Không** realtime: không websocket, không Supabase Realtime, không APNs đánh thức sync. Chỉ poll
  theo sự kiện + chu kỳ ~30 giây khi foreground (§7).

  **Vì sao không, viết ra để đợt sau khỏi bàn lại:** Realtime tốn pin (một socket phải giữ sống),
  tốn quota kết nối đồng thời (Supabase tính theo số connection, không theo số request), và —
  điểm quyết định — **vẫn phải giữ poll làm lưới đỡ** cho mọi máy vừa mở lại, vừa mất sóng, vừa bị
  hệ điều hành ngắt socket. Nên nó là **chi phí CỘNG THÊM, không phải thay thế**. Điều kiện xét
  lại: khi có người dùng thật phàn nàn 30 giây là chậm — không phải khi ai đó thấy Realtime nghe
  hay hơn.

- 🔴 **NGUYÊN TẮC CHO MỌI ĐỢT SAU — nếu có thêm push/Realtime thì push CHỈ LÀ LỜI NHẮC.**
  Tín hiệu đẩy được phép nói đúng một câu: *"có thay đổi, đi kéo đi."* Nó **không bao giờ chở nội
  dung bản ghi**. Hai lý do, cả hai đều đủ một mình:
  1. Máy đang offline lúc broadcast mà nội dung nằm trong tin nhắn thì **nó mất bản ghi ấy vĩnh
     viễn** — không có đường nào lấy lại, vì broadcast không có lịch sử. Còn nếu mất một tín hiệu
     "đi kéo đi" thì lần poll sau cursor vẫn kéo đủ, không sót gì. Mất tín hiệu là vô hại; mất
     nội dung là mất việc của người dùng.
  2. Giữ đúng **MỘT đường đọc dữ liệu**. Hai đường (push chở nội dung + cursor pull) là hai đường
     phải trông nhau, và mọi bug "hai máy lệch nhau" sẽ phải điều tra ở cả hai — trong khi cái
     duy nhất khó debug của cả feature này chính là bug chỉ hiện ra khi có hai máy.

  **Cursor pull là nguồn chân lý. Push chỉ là gợi ý về thời điểm.**
- **Không** sync `ParseCorrection` (§0(5)), settings, focus session, global `ReminderPolicy`.
- **Không** sync `ReminderRecord` và **không** chống nổ chuông đa thiết bị (§11.3).
- **Không** UI xung đột ("2 máy cùng sửa task này"). Dữ liệu vào `sync_rejects`, mắt người chưa thấy.
- **Không** E2EE (§9).
- **Không** viết client .NET. Schema và giao thức thiết kế để phục vụ nó; code là việc riêng của
  nhánh `window`, và theo plan 007 §8 `supabase/` chỉ có một chủ là trunk.
- **Không** promote cột nào ra khỏi `payload`, không search phía server, không web app.
- **Không** có đường nào TỰ ĐỘNG xoá dữ liệu server: hết Pro không xoá, tắt công tắc không xoá,
  không job dọn dẹp nào chạm vào hàng còn sống. Chỉ `volar_sync_purge()` do user tự bấm.
- **Không** liệt kê thiết bị ở màn xác nhận lần bật ĐẦU TIÊN — làm được thì phải phone-home trước
  khi có sự đồng ý (§8.1). Sau khi bật thì Settings liệt kê thật.
- **Không** có công tắc sync riêng cho từng máy. anh Khôi chọn account-level, biết rõ mặt trái.
- **Không** apply migration, **không** deploy, **không** đụng database production. `0005` chỉ là file.
- **Không** gỡ `@Attribute(.unique)` khỏi bất kỳ `@Model` nào — §1 lý do 4 làm việc đó thành không
  cần thiết vĩnh viễn.

---

## 13. Khối lượng v1 (ước lượng để anh Khôi cân)

| Việc | Nơi | Ước lượng |
|---|---|---|
| Migration + RLS + 5 RPC | `supabase/migrations/0005_sync_tasks.sql` | ~640 dòng — **đã viết trong đợt này** |
| Ba field + backfill + soft-delete | `Shared/Model/VolarTask.swift`, `TaskStore.swift` | ~120 dòng sửa, 5 `FetchDescriptor` |
| Engine sync | `Shared/Sync/` (4 file mới) | ~700–900 dòng |
| Test merge thuần + payload codec | `SharedTests/` | ~400 dòng |
| Công tắc: màn xác nhận lần đầu, Settings, danh sách thiết bị, nút "Xoá dữ liệu trên server" | `AppState`, Settings | ~220 dòng |
| Ba trạng thái từ chối phân biệt được (`sync_pro_required` / `sync_disabled` / offline) | `SyncEngine`, Settings | ~60 dòng |
| Pair-code watch (RPC + `pair-claim` + `WCSession`) | SQL + `subscription/index.ts` + Swift | ~250 dòng |

≈ **4–5 phiên Sonnet file-disjoint**, cộng một phiên Opus review cuối. Điều kiện tiên quyết:
§11.1 phải được chốt trước.
