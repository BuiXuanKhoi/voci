// Tests/CalendarAccessTests.swift — XCTest coverage for `Sources/Integrations/CalendarAccess.swift`
// (calendar permission surface: requests access, reports status + a bare calendar count — the
// actual read/write of calendar events happens in `CalendarSync`, covered by
// `CalendarSyncTests.swift`; see `CalendarAccess.swift`'s file header for why "full access" is
// requested even though this specific class only ever reads a count).
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here):
//   1. Confirm on Mac that `CalendarAccessTests` builds and runs under the `VolarTests` target,
//      same as `ReminderSchedulerTests` already does.
//   2. `testConstructingDoesNotThrowAndReportsAStatus` below depends on THIS MACHINE'S live TCC
//      authorization state for Calendars (whatever it happens to be — notDetermined/denied/
//      granted/restricted). It intentionally asserts only shape (a valid `Status`, a non-negative
//      count, no error), never a specific status value, precisely because that value is
//      environment-dependent and cannot be pinned down from here.
//
// Deliberately NOT tested here: `requestAccess()`. Calling it would fire a real TCC permission
// prompt on whatever machine/CI runs this suite — at best a hang waiting on a dialog nothing will
// dismiss, at worst a permanent "denied" recorded against the test runner's bundle ID. Everything
// safe to assert about `requestAccess()` without triggering that prompt is instead covered
// indirectly via the `Status` mapping tests below, since `requestAccess()`'s only real logic
// (beyond the EventKit call itself) is picking a `Status` from a Bool/error, which mirrors
// `CalendarAccess.map(_:)`.
import XCTest
import EventKit
@testable import Volar

@MainActor
final class CalendarAccessTests: XCTestCase {

    // MARK: - Status is Equatable

    func testStatusIsEquatable() {
        XCTAssertEqual(CalendarAccess.Status.notDetermined, CalendarAccess.Status.notDetermined)
        XCTAssertEqual(CalendarAccess.Status.granted, CalendarAccess.Status.granted)
        XCTAssertNotEqual(CalendarAccess.Status.granted, CalendarAccess.Status.denied)
        XCTAssertNotEqual(CalendarAccess.Status.denied, CalendarAccess.Status.restricted)
        XCTAssertNotEqual(CalendarAccess.Status.unavailable, CalendarAccess.Status.notDetermined)
    }

    // MARK: - Construction is safe and side-effect-free

    /// // UNVERIFIED: the concrete `status` value this asserts depends on this machine's live TCC
    /// state for Calendars, which cannot be controlled or previewed from this Windows dev
    /// environment. What IS asserted unconditionally: construction never throws/crashes, the
    /// resulting status is one of the five valid cases (trivially true given the enum, but this
    /// also exercises that `init()` runs `EKEventStore.authorizationStatus(for:)` without issue),
    /// `calendarCount` starts at a sane non-negative default, and `lastError` is nil (nothing has
    /// gone wrong because nothing async has run yet — construction alone must never touch
    /// `requestFullAccessToEvents` or produce an error).
    func testConstructingDoesNotThrowAndReportsAStatus() {
        let access = CalendarAccess()

        let validStatuses: Set<CalendarAccess.Status> = [
            .notDetermined, .denied, .restricted, .granted, .unavailable,
        ]
        XCTAssertTrue(validStatuses.contains(access.status))
        XCTAssertGreaterThanOrEqual(access.calendarCount, 0)
        XCTAssertNil(access.lastError, "construction alone must never produce an error — no request has been made yet")
    }

    // MARK: - EKAuthorizationStatus → Status mapping (the testable, TCC-independent core)

    func testMapNotDetermined() {
        XCTAssertEqual(CalendarAccess.map(.notDetermined), .notDetermined)
    }

    func testMapRestricted() {
        XCTAssertEqual(CalendarAccess.map(.restricted), .restricted)
    }

    func testMapDenied() {
        XCTAssertEqual(CalendarAccess.map(.denied), .denied)
    }

    func testMapFullAccessIsGranted() {
        XCTAssertEqual(CalendarAccess.map(.fullAccess), .granted)
    }

    /// The one mapping worth calling out by name: write-only access does NOT satisfy what Volar
    /// actually needs, which is BOTH read (the calendar count in this class, and potentially busy
    /// intervals later) AND write (`CalendarSync`'s task mirroring) — a write-only grant gives
    /// write but zero read capability, so it must map to `.denied`, never `.granted`, or the
    /// Settings UI would wrongly claim a fully working connection. `CalendarSync.reconcile(tasks:)`
    /// also gates on `access.status == .granted` for the same reason: only `.fullAccess`/
    /// `.authorized` provide both halves of what this app needs.
    func testMapWriteOnlyIsDeniedNotGranted() {
        XCTAssertEqual(CalendarAccess.map(.writeOnly), .denied)
        XCTAssertNotEqual(CalendarAccess.map(.writeOnly), .granted)
    }

    /// Deprecated pre-macOS-14 case, kept mapped to `.granted` for backward compatibility even
    /// though this target's 14.0 floor should make it unreachable in practice.
    func testMapDeprecatedAuthorizedIsGranted() {
        XCTAssertEqual(CalendarAccess.map(.authorized), .granted)
    }
}
