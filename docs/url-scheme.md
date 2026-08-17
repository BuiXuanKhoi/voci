# Nối Volar vào workflow của bạn

Volar không cố tích hợp với từng ứng dụng. Nó mở hai cửa và để bạn tự nối: một **lược đồ URL**
mà mọi launcher và công cụ automation trên Mac đều gọi được, và ba **App Intents** mà Shortcuts,
Siri và Spotlight nhìn thấy.

Nguyên tắc phía sau: bạn đã có sẵn công cụ mình quen. Volar nên gọi được từ đó rồi biến mất, chứ
không bắt bạn mở thêm một app nữa.

> Tài liệu này viết cho người dùng. Đặc tả kỹ thuật đầy đủ (thuật toán so khớp, hình dạng hook,
> hợp đồng cài/gỡ) nằm ở [`specs/002-workflow-command-center/contracts/app-links.md`](../specs/002-workflow-command-center/contracts/app-links.md).

---

## 1. Lược đồ URL — `volar://`

Chạy được ở bất cứ đâu mở được URL: Alfred, Raycast, Keyboard Maestro, Stream Deck,
BetterTouchTool, Hammerspoon, Shortcuts, hoặc `open` trong Terminal.

### Thêm một task

```
volar://capture?text=<văn bản đã URL-encode>&source=<nguồn, tuỳ chọn>
```

| Tham số | Bắt buộc | Ý nghĩa |
|---|---|---|
| `text` | có | Nội dung task. Đi qua đúng bộ parse như khi bạn gõ trong app — nó tự đọc ra ngày, giờ, độ ưu tiên. Tối đa 2000 ký tự. |
| `source` | không | Ghi chú nguồn gốc, lưu kèm task. Ví dụ `Alfred`, `Mail`. |

Ví dụ chạy được ngay trong Terminal:

```bash
open "volar://capture?text=g%E1%BB%8Di%20Acme%20th%E1%BB%A9%20S%C3%A1u%202%20gi%E1%BB%9D&source=Terminal"
```

**Đường này luôn hiện thẻ xác nhận trong Volar.** Bạn đang ngồi trước màn hình khi bấm phím tắt,
nên một cái liếc mắt là bắt được ngày bị parse sai. (Siri thì khác — xem phần 2.)

### Báo "agent chạy xong"

```
volar://ai-done?cwd=<đường dẫn dự án, base64>
```

Dùng khi một tác vụ dài chạy xong và bạn muốn Volar nhắc việc tiếp theo. Volar tự tìm task đang
chờ khớp với thư mục đó. Nếu không đoán được chắc chắn, nó hỏi thay vì đoán bừa.

Volar cài sẵn hook này cho Claude Code qua **Settings → Connect Claude Code**. Muốn nối công cụ
khác thì bắn cùng URL đó khi công cụ kết thúc:

```bash
open "volar://ai-done?cwd=$(printf %s "$PWD" | base64)"
```

`cwd` phải base64 vì đường dẫn có dấu cách hay ký tự tiếng Việt sẽ làm vỡ URL.

---

## 2. Shortcuts, Siri và Spotlight

Volar cung cấp ba hành động. Chúng xuất hiện trong app **Shortcuts** (mục Volar), gọi được bằng
giọng nói qua Siri, và tìm được trong Spotlight.

| Hành động | Câu nói ví dụ | Trả về |
|---|---|---|
| **Add Task** | *"Add a task to Volar"* | Đọc lại **kết quả đã parse**: "Added: Gọi Acme" |
| **What Am I Doing** | *"What am I doing in Volar"* | Task hiện tại, kèm hạn và số phút còn lại nếu đang trong phiên Focus |
| **Start Focus** | *"Start focus in Volar"* | Bắt đầu phiên 25 phút trên task hiện tại |

### Vì sao Siri không hiện thẻ xác nhận

Vì lúc đó bạn không nhìn màn hình. Thẻ xác nhận chỉ có tác dụng khi có người đứng ở đó — nếu nó
bật lên trên máy Mac ở nhà trong khi bạn đang đi bộ, task sẽ **không** được tạo, mà bạn lại tưởng
là đã tạo rồi. Đó là kiểu hỏng tệ nhất.

Nên thay vào đó, Siri **đọc lại thứ nó đã parse ra**, không phải đọc lại câu bạn vừa nói. Sai ngày
là bạn nghe thấy ngay.

Luật vẫn là một luật: *mọi lần capture đều phải cho bạn thấy nó hiểu ra cái gì — qua kênh mà bạn
đang thật sự có mặt.* Trước màn hình thì là thẻ xác nhận. Trong tai nghe thì là câu Siri đọc lại.

Riêng khi câu nói phức tạp — nhiều task một lúc, nghi trùng với task đã có, hoặc có điều kiện phụ
thuộc — Siri sẽ nói thẳng *"cần bạn xác nhận, tôi đã mở trong Volar"* và **chưa lưu gì cả**. Volar
không tự đoán thay bạn ở những chỗ đó.

---

## 3. Vài cách nối sẵn

**Bôi đen ở đâu cũng bắt được.** Chọn chữ trong bất kỳ app nào → chuột phải → *New Task in Volar*.
Không cần cài gì, có sẵn sau khi chạy Volar lần đầu. Nếu chưa thấy trong menu, vào
System Settings → Keyboard → Keyboard Shortcuts → Services để bật.

**Tự động bật Focus.** Trong Shortcuts, tạo Automation: *When Focus "Work" turns on* → chạy
**Start Focus** của Volar. Bật chế độ Work của macOS là Volar vào phiên luôn.

**Task đầu ngày.** Automation: *9:00 every weekday* → **Add Task** với nội dung cố định. Không ai
phải có mặt để bấm gì cả.

**Nút trên Stream Deck.** Gán nút vào lệnh System → Open URL với `volar://capture?text=...`.

**Alfred / Raycast.** Tạo workflow nhận đầu vào rồi mở
`volar://capture?text={query}&source=Alfred`. Nhớ URL-encode `{query}`.

---

## Giới hạn đã biết

- Ba App Intents chỉ chạy khi Volar đang chạy. Volar là app thanh menu nên bình thường nó luôn
  chạy; nếu đã thoát hẳn, macOS thường tự mở lại ngầm để phục vụ, nhưng lần gọi đầu có thể chậm.
- `volar://` là **một chiều, vào Volar**. Không có đường lấy dữ liệu ra — cố ý, để không phải mở
  một mặt API mà chưa có ai bảo trì.
- Services menu chỉ nhận chữ, chưa nhận file hay link.
