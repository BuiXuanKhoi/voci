// SharedTests/FuzzyMatchScoreTests.swift — `AppState.fuzzyMatchScore`, hạt nhân so khớp mờ mà cả
// hai bar đều dựa vào: 0.70 (tự động gắn phụ thuộc `.taskDone`, `preResolveConditions`/
// `resolveTaskRefs`) và 0.35 (gợi ý task trùng trên thẻ confirm, `duplicateCandidates`).
//
// Mọi ca dưới đây là ca THẬT, không phải ca bịa:
//   - "Làm task Dem Search" ↔ "dems search" là ca anh Khôi gặp 2026-08-20 và công thức Jaccard cũ
//     cho 0.20, tức app im lặng không tìm ra task đã có.
//   - "Làm task Dem Search" ↔ "Làm task Custom Metadata Autotest" là hai task thật trong ảnh chụp
//     màn hình cùng ngày; công thức cũ cho 0.50 ở nhánh lỏng, vượt bar gợi ý trùng 0.45, tức app
//     hỏi "có phải cùng một việc không" cho hai việc chẳng liên quan gì.
//
// Hai ca đó là lý do file này tồn tại: chúng phải KHÔNG BAO GIỜ quay lại.
//
// UNVERIFIED (viết trên Windows, không có Xcode): xác nhận trên Mac rằng `xcodebuild test` nhặt
// file này vào target, như mọi file khác trong thư mục.
import XCTest
@testable import Volar

@MainActor
final class FuzzyMatchScoreTests: XCTestCase {

    private let autoAttachBar = 0.70   // preResolveConditions / resolveTaskRefs
    private let hintBar = 0.35         // duplicateCandidates

    private func score(_ query: String, _ candidate: String) -> Double {
        AppState.fuzzyMatchScore(query: query, candidate: candidate)
    }

    // MARK: - Ca hồi quy của anh Khôi

    func testShortenedMentionMatchesLongerStoredTitle() {
        // Chữ đệm "Làm task" trong tiêu đề đã lưu KHÔNG được kéo điểm xuống — đây chính là chỗ
        // Jaccard theo từ sai (0.50, trượt bar 0.70).
        XCTAssertGreaterThanOrEqual(score("dems search", "Làm task Dems Search"), autoAttachBar)
    }

    func testOneCharacterTypoStillMatches() {
        // "Dem" vs "Dems": ca thật của anh Khôi. Jaccard theo từ cho 0.20.
        XCTAssertGreaterThanOrEqual(score("dems search", "Làm task Dem Search"), autoAttachBar)
    }

    func testTwoUnrelatedTasksSharingFillerWordsNeverAutoAttach() {
        // Hai task thật trên màn hình anh Khôi, cùng mở đầu bằng "Làm task".
        //
        // ĐO ĐƯỢC, KHÔNG PHẢI MONG MUỐN: cặp này ~0.42. Nó KHÔNG về 0 như so một CỤM NGẮN với một
        // tiêu đề ("dems search" vs tiêu đề kia = 0.00) — ở đây hai bên đều là tiêu đề đầy đủ nên
        // phần "lam task " chung vẫn cộng điểm cho Dice. Nghĩa là cặp này vẫn xuất hiện trong danh
        // sách GỢI Ý trùng (bar 0.35).
        //
        // Đó là lựa chọn có ý thức, không phải sót: anh Khôi chốt 2026-08-20 "thà tìm ra task trùng
        // còn hơn không tìm ra cái nào" — sai ở tầng gợi ý tốn một cái liếc mắt, sót thì đẻ ra task
        // trùng thật. Điều BẮT BUỘC là nó không bao giờ chạm bar 0.70, vì trên bar đó app tự gắn
        // phụ thuộc mà không hỏi ai.
        let value = score("Làm task Dem Search", "Làm task Custom Metadata Autotest")
        XCTAssertLessThan(value, autoAttachBar)
    }

    func testShortMentionDoesNotLeakAcrossUnrelatedTasks() {
        // Đường mà cụm ngắn đi qua (`preResolveConditions`) thì sạch tuyệt đối: cụm anh Khôi nói
        // không dính một trigram nào của task kia.
        XCTAssertEqual(score("dems search", "Làm task Custom Metadata Autotest"), 0, accuracy: 0.001)
    }

    func testIdenticalTitlesScoreOne() {
        XCTAssertEqual(score("Dems Search", "Dems Search"), 1.0, accuracy: 0.001)
    }

    // MARK: - Chốt chặn query ngắn (thứ giữ bar 0.70 không bị vô hiệu hoá)

    func testSingleCommonWordNeverAutoAttaches() {
        // Không có chốt này thì containment = 1.00 và MỌI task có chữ "search" bị gắn phụ thuộc.
        XCTAssertLessThan(score("search", "Làm task Dems Search"), autoAttachBar)
    }

    func testFillerWordAloneNeverAutoAttaches() {
        XCTAssertLessThan(score("task", "Làm task Dems Search"), autoAttachBar)
    }

    // MARK: - Chuẩn hoá

    func testDiacriticsAndCaseAreIgnored() {
        XCTAssertEqual(score("nộp thuế quý ba", "NOP THUE QUY BA"), 1.0, accuracy: 0.001)
    }

    func testPunctuationDoesNotBreakAMatch() {
        // Bản token cũ chỉ cắt theo khoảng trắng, nên "search," và "search" là hai thứ khác nhau.
        XCTAssertGreaterThanOrEqual(score("dems search", "Làm task: Dems Search!"), autoAttachBar)
    }

    // MARK: - Biên

    func testEmptyAndTinyInputsScoreZeroInsteadOfCrashing() {
        XCTAssertEqual(score("", "Dems Search"), 0)
        XCTAssertEqual(score("Dems Search", ""), 0)
        XCTAssertEqual(score("   ", "Dems Search"), 0)
    }

    func testCrossLanguageIsStillNotSolvedHere() {
        // Ghi lại một GIỚI HẠN đã biết, không phải một mong muốn: trigram so ký tự, nên "gọi cho
        // Minh" ↔ "call Minh" không thể khớp ở tầng này. Việc đó là của Gemini (prompt đã yêu cầu
        // model chép nguyên văn tiêu đề khớp từ `openTaskTitles`). Nếu ngày nào đó test này đỏ
        // nghĩa là có người thêm được so khớp ngữ nghĩa vào đây — lúc đó xoá test, đừng "sửa" nó.
        XCTAssertLessThan(score("gọi cho Minh", "Call Minh about the invoice"), 0.70)
    }
}
