// SharedTests/TaskSearchIndexTests.swift — chỉ mục term → task (`Shared/Model/TaskSearchIndex.swift`).
//
// Ca dựng theo đúng ví dụ anh Khôi đưa 2026-08-20: task gốc nói cả một câu dài
// ("Làm task dems search trước 9h30 … sửa query để tokenize được trong Solr") nhưng tiêu đề chỉ
// giữ lại phần đầu. Điều phải chứng minh là chữ "Solr" — chỉ tồn tại trong câu nói gốc — vẫn tra
// ra được task đó, thứ mà so-khớp-tiêu-đề không đời nào làm được.
//
// UNVERIFIED (viết trên Windows, không có Xcode).
import Foundation
import XCTest
@testable import Volar

final class TaskSearchIndexTests: XCTestCase {

    private func task(
        _ title: String,
        transcript: String? = nil,
        notes: String? = nil
    ) -> TaskItem {
        TaskItem(
            title: title,
            priority: .medium,
            when: .later,
            notes: notes,
            sourceTranscript: transcript
        )
    }

    /// Ví dụ gốc của anh Khôi.
    private var demsSearch: TaskItem {
        task(
            "Làm task dems search",
            transcript: "Làm task dems search trước 9h30, task này phải xong đầu tiên, nội dung là sửa query để có thể tokenize được trong Solr"
        )
    }

    /// Kho nhiễu cỡ thật. Số lượng CÓ Ý NGHĨA với các test IDF bên dưới: "làm task" phải xuất hiện
    /// ở phần lớn task thì nó mới tự trở thành chữ chung chung — đó chính là cơ chế thay cho danh
    /// sách stop-word. Một kho 3 task thì chữ nào cũng có vẻ đặc trưng, và đó là câu trả lời ĐÚNG
    /// về mặt thông tin chứ không phải lỗi.
    private var noise: [TaskItem] {
        [
            task("Làm task Custom Metadata Autotest", transcript: "Làm task custom metadata autotest"),
            task("Làm task review PR", transcript: "Làm task review PR của Minh"),
            task("Gọi cho nha sĩ", transcript: "Gọi cho nha sĩ đặt lịch"),
            task("Làm task import CSV", transcript: "Làm task import CSV cho khách"),
            task("Làm task fix login", transcript: "Làm task fix login bug"),
            task("Làm task deploy staging", transcript: "Làm task deploy staging chiều nay"),
            task("Họp team sprint", transcript: "Họp team sprint thứ 5"),
            task("Làm task update docs", transcript: "Làm task update docs API"),
            task("Mua sữa", transcript: "Mua sữa cho con"),
            task("Làm task refactor parser", transcript: "Làm task refactor parser"),
            task("Làm task viết test", transcript: "Làm task viết test cho store"),
        ]
    }

    // MARK: - Cái mà so-khớp-tiêu-đề không làm được

    func testFindsTaskByAWordThatOnlyExistsInTheTranscript() {
        let target = demsSearch
        let index = TaskSearchIndex(tasks: [target] + noise)
        let hits = index.matches(for: "Solr", limit: 5)
        XCTAssertEqual(hits.first?.id, target.id)
    }

    func testFindsTaskByADomainWordFromTheBody() {
        let target = demsSearch
        let index = TaskSearchIndex(tasks: [target] + noise)
        XCTAssertEqual(index.matches(for: "tokenize query", limit: 5).first?.id, target.id)
    }

    func testTypoInATermStillResolves() {
        // "dem" (thiếu s) vẫn phải ra task chứa "dems" — lỗi nghe một ký tự không được làm mất
        // trắng một term hiếm.
        let target = demsSearch
        let index = TaskSearchIndex(tasks: [target] + noise)
        XCTAssertEqual(index.matches(for: "dem search", limit: 5).first?.id, target.id)
    }

    // MARK: - IDF: chữ chung chung tự mất trọng lượng, không cần danh sách stop-word

    func testAFillerOnlyQueryNeverScoresLikeARealMatch() {
        // Đây là test canh chính cái lỗi đã suýt lọt: bản đầu chuẩn hoá theo "tổng IDF của các term
        // TRONG QUERY", khiến query toàn chữ đệm đạt đúng 1.0 (mọi term của nó đều khớp) và mỗi lần
        // capture sẽ dội lên 5 gợi ý rác. Với mẫu số đúng, "làm task" trên kho này ra ~0.37.
        let index = TaskSearchIndex(tasks: [demsSearch] + noise)
        let fillerTop = index.matches(for: "làm task", limit: 10).first?.score ?? 0
        XCTAssertLessThan(fillerTop, 0.5)
    }

    func testFullTitleSeparatesTheRightTaskFromTheFillerCrowd() {
        // Query thật là cả tiêu đề, và đây mới là hình dạng đáng tin: task đúng phải tách hẳn khỏi
        // đám task cùng mở đầu "Làm task".
        let target = demsSearch
        let index = TaskSearchIndex(tasks: [target] + noise)
        let hits = index.matches(for: "Làm task dems search", limit: 10)
        XCTAssertEqual(hits.first?.id, target.id)
        let targetScore = hits.first?.score ?? 0
        let runnerUp = hits.dropFirst().first?.score ?? 0
        XCTAssertGreaterThan(targetScore, runnerUp * 2, "task đúng phải hơn hẳn, không phải hơn sít sao")
    }

    func testRareWordOutranksCommonWord() {
        let target = demsSearch
        let index = TaskSearchIndex(tasks: [target] + noise)
        let rare = index.matches(for: "Solr", limit: 5).first?.score ?? 0
        let common = index.matches(for: "task", limit: 5).first?.score ?? 0
        XCTAssertGreaterThan(rare, common)
    }

    // MARK: - Biên

    func testEmptyIndexAndEmptyQueryReturnNothing() {
        XCTAssertTrue(TaskSearchIndex(tasks: []).matches(for: "solr", limit: 5).isEmpty)
        XCTAssertTrue(TaskSearchIndex(tasks: [demsSearch]).matches(for: "   ", limit: 5).isEmpty)
    }

    func testUnrelatedQueryFindsNothingAboveTheHintBar() {
        let index = TaskSearchIndex(tasks: [demsSearch] + noise)
        for hit in index.matches(for: "đổ xăng xe máy", limit: 10) {
            XCTAssertLessThan(hit.score, 0.35)
        }
    }

    func testSingleCharacterTokensAreNotIndexed() {
        let index = TaskSearchIndex(tasks: [task("a b c dems")])
        XCTAssertTrue(index.matches(for: "a", limit: 5).isEmpty)
    }

    func testResultsAreDeterministicWhenScoresTie() {
        // Hai task giống hệt nhau về term: thứ tự trả về phải ổn định giữa các lần chạy, nếu không
        // danh sách gợi ý sẽ nhảy loạn.
        let a = task("Sửa query Solr")
        let b = task("Sửa query Solr")
        let index = TaskSearchIndex(tasks: [a, b])
        let first = index.matches(for: "solr", limit: 5).map(\.id)
        let second = index.matches(for: "solr", limit: 5).map(\.id)
        XCTAssertEqual(first, second)
    }
}
