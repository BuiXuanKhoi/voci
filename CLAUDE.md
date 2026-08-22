<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan:
`specs/002-workflow-command-center/plan.md` (feature: Volar v2 — Voice-first
Workflow Command Center; supersedes 001-nexttask-engine, whose engine it extends).
<!-- SPECKIT END -->

## 🔴 CẤM tự chạy probe script (anh Khôi chốt 2026-08-09)

**KHÔNG BAO GIỜ tự chạy `supabase/scripts/probe-*.ts`** — không phải sau khi sửa prompt, không
phải để "verify nhanh", không phải vì task nói "kiểm tra lại". Áp dụng cho MỌI agent/session.

**Luật này KHÔNG phụ thuộc vào permission mode.** Kể cả đang chạy bypass-permissions /
auto-accept — tức là không có hộp thoại nào chặn lại — vẫn phải hỏi anh Khôi trước.
Bypass-permissions nghĩa là "anh Khôi không muốn bị hỏi về từng thao tác file/lệnh thông thường",
KHÔNG có nghĩa "được tiêu tiền của anh Khôi mà không hỏi". Việc harness không chặn không phải là
sự cho phép. Cùng nguyên tắc đó áp cho mọi thao tác tốn tiền thật hoặc khó đảo ngược, không riêng
probe.

Bốn script này (`probe-time-parsing`, `probe-breakdown`, `probe-cues`, `probe-followup`) gọi
Gemini **thật** bằng **đúng prompt production**. Vì 98,8% input token là prompt cố định
(systemInstruction + date rules), câu test ngắn KHÔNG làm nó rẻ đi: mỗi case ≈ $0.0018 ≈ 47đ, một
lượt quét đủ 4 script ≈ 65 call ≈ 3.000đ. Tự chạy sau mỗi lần sửa đã đốt **55.000đ trong 3 ngày
7→9/8** mà không sinh ra giá trị nào ngoài sự yên tâm.

**Đúng quy trình:**
- Sửa prompt xong → **DỪNG**, báo anh Khôi rằng thay đổi này cần probe xác nhận, ghi rõ **script
  nào + vì sao + ước lượng số call**, rồi **chờ anh quyết**.
- Anh Khôi tự chạy, hoặc anh cho phép thì mới chạy.
- Được phép **không giới hạn**: `--dry-run` (in prompt ra, không gọi mạng, $0) và `deno check`.

Không tự ý "chạy thử một case cho chắc". Một case cũng phải hỏi.
