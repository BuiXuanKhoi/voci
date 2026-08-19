// Shared/Model/DeadlineUrgency.swift — "còn bao nhiêu phần đường tới hạn", đo bằng TỈ LỆ.
// Anh Khôi chốt 2026-08-20:
//
//   còn ≥ 1/2 quãng đường  → calm   (không đổi màu — badge giữ nguyên accent mint)
//   còn 1/4 … 1/2          → near   (`VolarColor.med`, vàng-nâu)
//   còn < 1/4              → tight  (`VolarColor.high`, đất nung)
//
// "Quãng đường" = từ lúc TẠO task tới hạn (`deadline − createdAt`), không phải từ bây giờ. Đây là
// nguyên văn luật anh Khôi đưa và anh đã xác nhận sau khi em nêu hai chỗ nó lệch với cảm nhận thật:
// task tạo lúc 9:00 hạn 9:10 sẽ là `calm` suốt 5 phút đầu dù chỉ còn 10 phút, còn task tạo từ tháng
// 3 hạn tháng sau sẽ là `tight` dù còn nguyên một tháng. Đó là hệ quả biết trước của phép đo theo
// tỉ lệ, không phải lỗi — nếu sau này thấy vướng khi dùng thật thì đổi sang mốc tuyệt đối (giờ/ngày
// còn lại), một chỗ duy nhất trong file này.
//
// KHÔNG áp cho task ĐÃ QUÁ HẠN (`remaining <= 0`), dù về mặt số học nó thuộc dải `tight`: quá hạn
// đã có luật riêng có từ trước và luật đó là một quyết định chống-xấu-hổ, không phải chỗ trống —
// specs/010-calendar-and-hard-deadlines/design.md §3.2 row 2: hạn MỀM quá hạn đọc bằng `textSec`
// trung tính, chỉ hạn CỨNG quá hạn mới được `VolarColor.high`. Nếu file này tô màu mọi thứ quá hạn
// thì nó lặng lẽ lật quyết định đó.
//
// Cả hai dải màu đều nằm trong bảng có sẵn (`med`/`high`) — KHÔNG có đỏ. `Theme.swift` ghi thẳng
// "No red, ever, for status/badges (anti-shame rule)", `destruct` là ngoại lệ duy nhất và dành cho
// nút Xoá. Anh Khôi đã cân nhắc và giữ luật này khi chốt bảng màu.
//
// Thuần: `now` luôn là tham số, không đọc đồng hồ hệ thống — cùng quy ước `TaskSections`/`VolarCore`.
//
// UNVERIFIED — viết trên Windows, không có Swift toolchain. Chưa compile, chưa chạy.
import Foundation
import SwiftUI

enum DeadlineUrgency: Sendable, Equatable, CaseIterable {
    /// Còn ≥ 1/2 quãng đường tới hạn.
    case calm
    /// Còn 1/4 … 1/2.
    case near
    /// Còn < 1/4.
    case tight

    /// `nil` khi không có gì để đo: task không hạn, task đã xong, hoặc task đã quá hạn (xem header).
    static func of(_ task: TaskItem, now: Date) -> DeadlineUrgency? {
        guard !task.done, let deadline = task.deadline else { return nil }

        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return nil }

        let total = deadline.timeIntervalSince(task.createdAt)
        // Hạn đặt trước cả lúc tạo task (nhập tay lùi ngày, hoặc parser đoán sai): quãng đường ≤ 0
        // thì tỉ lệ vô nghĩa. Coi là gấp nhất thay vì chia cho 0 hay trả `nil` — hạn vẫn có thật và
        // vẫn đang tới gần.
        guard total > 0 else { return .tight }

        let left = remaining / total
        if left >= 0.5 { return .calm }
        return left >= 0.25 ? .near : .tight
    }

    /// Màu ĐÈ lên nhãn hạn của row. `nil` = giữ nguyên màu mặc định của nhãn đó (accent ở
    /// `TimeBadge`, `textMut` ở row peek trong sidebar) — "còn nhiều thời gian" không cần một dấu
    /// hiệu riêng, sự im lặng chính là dấu hiệu.
    var tint: Color? {
        switch self {
        case .calm: return nil
        case .near: return VolarColor.med
        case .tight: return VolarColor.high
        }
    }

    /// Tiện cho call site: đi thẳng từ task sang màu cần tô.
    static func tint(for task: TaskItem, now: Date) -> Color? {
        of(task, now: now)?.tint
    }
}
