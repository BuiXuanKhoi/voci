// Sources/Model/TaskCue.swift — implementation-intention cue: keeps the user's own if-then
// utterance ("ngủ dậy thì test feature này") and surfaces it back verbatim at the right moment.
//
// PINNED PUBLIC SURFACE (specs/006-cues-and-waiting/design.md §2, chốt bởi Opus 2026-08-08):
// `CueKind`/`TaskCue` below are copied VERBATIM from the design doc, including the Vietnamese doc
// comments — T3 (`Parsing/CloudParser.swift` etc.) references this exact type. Do not rename a
// field or change its shape here without re-syncing that task; no compiler catches a mismatch
// across the two owners, only a shared source of truth does (same convention already used for
// `ParsedCapture.swift`).
//
// Cue is a SURFACING layer only, never an eligibility gate (design.md §1): it is deliberately NOT
// a `VolarCore.Condition` case, and nothing in this file may cause a task to be hidden. See
// `CueFiring.swift` for the pure decision logic that reads this type.
import Foundation

enum CueKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// Phiên tương tác đầu tiên sau một khoảng nghỉ dài (xem `CueFiring.wakeGapHours`).
    /// CỐ Ý không neo vào giờ đồng hồ — pha ngủ trễ ở ADHD phổ biến gấp ~10 lần dân số chung
    /// (`docs/adhd-research-v1.md` §6), nên "buổi sáng" của user này không phải 7h.
    case wake
    /// Ritual cuối ngày (neo theo hành vi đóng máy, không neo giờ cứng).
    case dayEnd
    /// Máy KHÔNG phân giải được ("tới văn phòng", "sau khi ăn trưa", "khi gặp sếp").
    /// Vẫn giữ nguyên `verbatim` và vẫn có giá trị: sức mạnh của implementation intention nằm
    /// ở liên kết nếu-thì user ĐÃ hình thành trong đầu; app chỉ cần đọc lại đúng lời họ.
    case unknown
}

struct TaskCue: Sendable, Equatable, Codable {
    /// Loại cue máy hiểu được. `.unknown` là hợp lệ và phổ biến — không bao giờ vứt cue chỉ vì
    /// không fire được.
    var kind: CueKind
    /// NGUYÊN VĂN lời user ("ngủ dậy thì test feature này"). LUÔN có, kể cả `.unknown`.
    /// Đây là thứ được đọc lại cho user, không phải `kind`.
    var verbatim: String
    var createdAt: Date
    /// SÀN CHỐNG NUỐT VIỆC (bắt buộc): quá mốc này cue thành inert — `verbatim` vẫn hiển thị
    /// được nhưng không còn nâng thứ tự nổi lên nữa. Mặc định `createdAt + 48h`.
    /// Task KHÔNG BAO GIỜ bị ẩn vì cue (xem §1), nên đây là hàng rào thứ hai, không phải thứ nhất.
    var expiresAt: Date

    /// `createdAt + 48h` — the one place the 48h constant lives (design.md §2's stated default),
    /// so every construction site (parser plumbing, tests, any future UI) computes the same
    /// expiry instead of each hand-rolling `.addingTimeInterval(48 * 3600)` separately.
    static func defaultExpiry(from createdAt: Date) -> Date {
        createdAt.addingTimeInterval(48 * 3600)
    }
}
