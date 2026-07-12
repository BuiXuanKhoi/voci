# Backlog — voci

- [ ] Cân nhắc thêm `.claude/` (đặc biệt `.claude/settings.local.json`) vào `.gitignore` để tránh commit nhầm thông tin nhạy cảm. (2026-07-12 — cảnh báo từ `specify init`)
- [ ] Cân nhắc migrate `docs/voci-voice-task-engine-spec.md` sang flow Spec Kit (constitution/specify) nếu muốn dùng spec-driven đầy đủ. (2026-07-12 — spec doc viết trước khi init Spec Kit)
- [ ] FR-013 (feature 001 nextTask) phần **app/persistence-side**: khi xóa task phải strip `id` của nó khỏi `dependsOn` của mọi task khác trong storage, và **notify user một lần** khi việc này đổi trạng thái blocked của task phụ thuộc. `VociCore` (pure engine) chỉ xử lý phần eligibility (coi archived/deleted là resolved); phần mutate storage + notify thuộc feature persistence/reminder, chưa có task. (2026-07-12 — hoãn vì ngoài scope engine, ghi lại theo phân tích /speckit-analyze N1)
