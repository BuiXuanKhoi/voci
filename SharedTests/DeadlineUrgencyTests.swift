// SharedTests/DeadlineUrgencyTests.swift — biên của ba dải màu hạn (Shared/Model/DeadlineUrgency.swift).
// Đây là chỗ duy nhất bắt được lỗi nếu ai đó đổi ngưỡng hay đổi mẫu số của tỉ lệ: giao diện tô sai
// màu thì phải nhìn bằng mắt trên Mac mới thấy, còn ở đây thì test đỏ ngay.
//
// UNVERIFIED (viết trên Windows, không có Xcode): xác nhận trên Mac rằng `xcodegen generate` +
// `xcodebuild test` có nhặt file này vào target `VolarTests`, như mọi file khác trong thư mục.
import Foundation
import XCTest
import VolarCore
@testable import Volar

final class DeadlineUrgencyTests: XCTestCase {

    /// Mốc cố định, không đọc đồng hồ hệ thống.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Task có quãng đường tổng 100 phút, còn lại `remainingMinutes` phút tính từ `now`.
    private func task(remainingMinutes: Double, totalMinutes: Double = 100, done: Bool = false) -> TaskItem {
        let deadline = Self.now.addingTimeInterval(remainingMinutes * 60)
        let createdAt = deadline.addingTimeInterval(-totalMinutes * 60)
        return TaskItem(
            title: "t",
            priority: .medium,
            status: done ? .done : .todo,
            deadline: deadline,
            createdAt: createdAt,
            when: .later
        )
    }

    // MARK: - Ba dải

    func testHalfLeftOrMoreIsCalm() {
        XCTAssertEqual(DeadlineUrgency.of(task(remainingMinutes: 100), now: Self.now), .calm)
        XCTAssertEqual(DeadlineUrgency.of(task(remainingMinutes: 60), now: Self.now), .calm)
    }

    func testExactlyHalfIsStillCalm() {
        // Biên đóng ở phía calm: "còn ≥ 1/2" nghĩa là đúng 1/2 vẫn yên.
        XCTAssertEqual(DeadlineUrgency.of(task(remainingMinutes: 50), now: Self.now), .calm)
    }

    func testBetweenQuarterAndHalfIsNear() {
        XCTAssertEqual(DeadlineUrgency.of(task(remainingMinutes: 49), now: Self.now), .near)
        XCTAssertEqual(DeadlineUrgency.of(task(remainingMinutes: 30), now: Self.now), .near)
    }

    func testExactlyQuarterIsStillNear() {
        XCTAssertEqual(DeadlineUrgency.of(task(remainingMinutes: 25), now: Self.now), .near)
    }

    func testUnderQuarterIsTight() {
        XCTAssertEqual(DeadlineUrgency.of(task(remainingMinutes: 24), now: Self.now), .tight)
        XCTAssertEqual(DeadlineUrgency.of(task(remainingMinutes: 1), now: Self.now), .tight)
    }

    // MARK: - Không có gì để đo

    func testNoDeadlineIsNil() {
        let undated = TaskItem(title: "t", priority: .medium, when: .later)
        XCTAssertNil(DeadlineUrgency.of(undated, now: Self.now))
    }

    func testDoneTaskIsNil() {
        XCTAssertNil(DeadlineUrgency.of(task(remainingMinutes: 1, done: true), now: Self.now))
    }

    func testOverdueIsNilNotTight() {
        // Quá hạn KHÔNG rơi vào dải `tight`: nó có luật riêng có từ trước (design.md §3.2 — hạn mềm
        // quá hạn đọc bằng màu trung tính, chỉ hạn cứng mới được `high`). Nếu ai đó đổi chỗ này
        // thành `.tight`, mọi task mềm quá hạn sẽ bị tô đất nung và luật chống-xấu-hổ mất hiệu lực.
        XCTAssertNil(DeadlineUrgency.of(task(remainingMinutes: -5), now: Self.now))
        XCTAssertNil(DeadlineUrgency.of(task(remainingMinutes: 0), now: Self.now))
    }

    func testDeadlineBeforeCreationIsTightNotACrash() {
        // Hạn lùi trước cả lúc tạo (nhập tay, hoặc parser đoán sai): tổng quãng đường ≤ 0 nên tỉ lệ
        // vô nghĩa. Phải ra `tight`, không được chia cho 0.
        let deadline = Self.now.addingTimeInterval(10 * 60)
        let created = deadline.addingTimeInterval(60) // tạo SAU hạn
        let weird = TaskItem(title: "t", priority: .medium, deadline: deadline, createdAt: created, when: .later)
        XCTAssertEqual(DeadlineUrgency.of(weird, now: Self.now), .tight)
    }

    // MARK: - Màu

    func testCalmHasNoTintAndTheOtherTwoDo() {
        // "Còn nhiều thời gian" không có dấu hiệu riêng — sự im lặng chính là dấu hiệu.
        XCTAssertNil(DeadlineUrgency.calm.tint)
        XCTAssertNotNil(DeadlineUrgency.near.tint)
        XCTAssertNotNil(DeadlineUrgency.tight.tint)
    }
}
