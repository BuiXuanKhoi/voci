// Tests/SyncMergeTests.swift — XCTest coverage for the pure decision surface in
// `Shared/Sync/SyncMerge.swift`: LWW (`decide`), HTTP failure classification (`classify`), and
// opaque-cursor advance (`nextCursor`). Every test drives the `enum SyncMerge`'s static functions
// directly with hand-built values — no `URLSession`/`ModelContext`/`Date()` involved, mirroring
// `CueFiringTests`/`WaitingModeTests`'s own "drive the pure function directly" style.
//
// Group D (Test) — written against code already on disk by groups A/B/C
// (specs/008-sync/client-contract.md §0). Does NOT touch `Shared/Sync/*.swift` itself.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): confirm
// on Mac that `xcodebuild test` picks this file up and every assertion below still holds once
// compiled for real.
import XCTest
import Foundation
@testable import Volar

final class SyncMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - decide(localUpdatedAt:remoteUpdatedAt:) — client-contract.md §4, design.md §5

    func testDecideLocalNilAlwaysApplies() {
        // Never seen locally at all (brand-new pull) — nothing to compare against.
        let decision = SyncMerge.decide(localUpdatedAt: nil, remoteUpdatedAt: now)
        XCTAssertEqual(decision, .apply)
    }

    func testDecideRemoteNewerThanLocalApplies() {
        let local = now
        let remote = now.addingTimeInterval(1)
        XCTAssertEqual(SyncMerge.decide(localUpdatedAt: local, remoteUpdatedAt: remote), .apply)
    }

    /// The ping-pong guard: an EQUAL timestamp is a no-op re-delivery (the 2-second overlap window
    /// in `sync_exchange`'s SQL is expected to resend already-applied rows), never a conflict to
    /// re-resolve. Getting this wrong (`>=` instead of `>`, or vice versa applied to the wrong
    /// side) is exactly the bug that makes two devices push the same row back and forth forever —
    /// this case gets its own test per client-contract.md's explicit call-out, not folded into the
    /// "older" case below.
    func testDecideEqualTimestampsSkipsNotApply() {
        let same = now
        XCTAssertEqual(SyncMerge.decide(localUpdatedAt: same, remoteUpdatedAt: same), .skip)
    }

    func testDecideRemoteOlderThanLocalSkips() {
        let local = now
        let remote = now.addingTimeInterval(-1)
        XCTAssertEqual(SyncMerge.decide(localUpdatedAt: local, remoteUpdatedAt: remote), .skip)
    }

    // MARK: - classify(status:message:transportError:) — client-contract.md §3.3's ONE lookup table
    //
    // All five rows of the table, one test each, plus the disjointness guarantee §8.2 depends on.

    func testClassify403ProRequiredMapsToProRequired() {
        let failure = SyncMerge.classify(status: 403, message: "sync_pro_required", transportError: nil)
        XCTAssertEqual(failure, .proRequired)
    }

    func testClassify403DisabledMapsToDisabled() {
        let failure = SyncMerge.classify(status: 403, message: "sync_disabled", transportError: nil)
        XCTAssertEqual(failure, .disabled)
    }

    func testClassify401MapsToSignedOutRegardlessOfMessage() {
        // Doc comment: PostgREST can 401 for reasons that never reach `sync_exchange`'s own
        // `raise exception 'sync_not_authenticated'` (e.g. an already-expired JWT) — every 401
        // means the same thing to this client, so this must hold even with the "official" message
        // AND with no message at all.
        XCTAssertEqual(
            SyncMerge.classify(status: 401, message: "sync_not_authenticated", transportError: nil),
            .signedOut
        )
        XCTAssertEqual(SyncMerge.classify(status: 401, message: nil, transportError: nil), .signedOut)
    }

    func testClassifyTransportFailureMapsToOffline() {
        struct DummyTransportError: Error {}
        let failure = SyncMerge.classify(status: nil, message: nil, transportError: DummyTransportError())
        guard case .offline = failure else {
            return XCTFail("expected .offline, got \(failure)")
        }
    }

    func testClassifyNoResponseAndNoTransportErrorStillMapsToOffline() {
        // Defensive tolerance the doc comment calls out explicitly: a caller bug (no status, no
        // error) must still produce SOME `SyncFailure`, never throw/crash.
        let failure = SyncMerge.classify(status: nil, message: nil, transportError: nil)
        guard case .offline = failure else {
            return XCTFail("expected .offline, got \(failure)")
        }
    }

    func testClassifyOtherStatusMapsToServer() {
        XCTAssertEqual(
            SyncMerge.classify(status: 500, message: "internal error", transportError: nil),
            .server(status: 500, message: "internal error")
        )
    }

    func testClassify403WithUnrecognizedMessageMapsToServerNotProOrDisabled() {
        // A 403 with any message OTHER than the two exact strings this app raises on purpose falls
        // through to `.server` — it must NOT be guessed into `.proRequired`/`.disabled`.
        let failure = SyncMerge.classify(status: 403, message: "some_other_reason", transportError: nil)
        XCTAssertEqual(failure, .server(status: 403, message: "some_other_reason"))
    }

    /// §8.2's central guarantee, stated as its own test rather than left implicit in the table
    /// tests above: `.disabled` and `.proRequired` are never equal to each other, and there is no
    /// input — including one that deliberately tries to LOOK like a gate rejection while actually
    /// being a transport failure — that classifies as either of them from the offline path. This
    /// is the exact property "gộp cả ba... là cách chắc chắn nhất để user tắt công tắc ở máy khác
    /// rồi ngồi debug wifi" (contract §3.3) depends on staying true after future edits.
    func testDisabledAndProRequiredAreNeverEqualAndOfflineNeverBecomesEither() {
        XCTAssertNotEqual(SyncFailure.disabled, SyncFailure.proRequired)

        struct DummyTransportError: Error {}
        // `status: nil` — a transport failure — with a message that HAPPENS to spell one of the
        // two magic gate strings must still resolve purely from the absent status, never from the
        // message text alone.
        let lookalike1 = SyncMerge.classify(
            status: nil, message: "sync_disabled", transportError: DummyTransportError()
        )
        let lookalike2 = SyncMerge.classify(
            status: nil, message: "sync_pro_required", transportError: DummyTransportError()
        )
        XCTAssertNotEqual(lookalike1, .disabled)
        XCTAssertNotEqual(lookalike1, .proRequired)
        XCTAssertNotEqual(lookalike2, .disabled)
        XCTAssertNotEqual(lookalike2, .proRequired)
        guard case .offline = lookalike1 else { return XCTFail("expected .offline, got \(lookalike1)") }
        guard case .offline = lookalike2 else { return XCTFail("expected .offline, got \(lookalike2)") }
    }

    // MARK: - nextCursor(previous:candidate:) — client-contract.md §6, §3.1's `hasMore` note

    func testNextCursorBothNilStaysNil() {
        XCTAssertNil(SyncMerge.nextCursor(previous: nil, candidate: nil))
    }

    func testNextCursorCandidateNilKeepsPrevious() {
        XCTAssertEqual(SyncMerge.nextCursor(previous: "2026-08-09T10:00:00.000000+00:00", candidate: nil), "2026-08-09T10:00:00.000000+00:00")
    }

    func testNextCursorPreviousNilAdoptsCandidate() {
        XCTAssertEqual(SyncMerge.nextCursor(previous: nil, candidate: "2026-08-09T10:00:00.000000+00:00"), "2026-08-09T10:00:00.000000+00:00")
    }

    func testNextCursorCandidateAheadOfPreviousAdvances() {
        let previous = "2026-08-09T10:00:00.000000+00:00"
        let candidate = "2026-08-09T10:00:05.000000+00:00"
        XCTAssertEqual(SyncMerge.nextCursor(previous: previous, candidate: candidate), candidate)
    }

    func testNextCursorCandidateEqualToPreviousStaysAtCandidate() {
        // `>=`, not `>` — an unchanged cursor round-tripped back must not be treated as regression.
        let value = "2026-08-09T10:00:00.000000+00:00"
        XCTAssertEqual(SyncMerge.nextCursor(previous: value, candidate: value), value)
    }

    /// The one case client-contract.md §4b's whole "never lose data" story depends on at the
    /// cursor layer: a candidate that is LEXICALLY BEHIND the stored previous value (a
    /// misbehaving/rolled-back server, or two responses applied out of order) must never regress
    /// the cursor — regressing it would make the client re-request rows it has already applied,
    /// which is harmless, but the DANGEROUS mirror image (silently accepting a bad forward jump)
    /// is exactly what this guard exists to block.
    func testNextCursorCandidateBehindPreviousKeepsPrevious() {
        let previous = "2026-08-09T10:00:05.000000+00:00"
        let candidate = "2026-08-09T10:00:00.000000+00:00" // lexically (and chronologically) earlier
        XCTAssertEqual(SyncMerge.nextCursor(previous: previous, candidate: candidate), previous)
    }

    // MARK: - cursorAfterStalenessCheck(_:now:) — design.md §6, the "offline longer than the
    // tombstone" valve. Cursor strings below are built with `SyncDate.string(from:)` so these tests
    // use the exact wire format the server produces, never a hand-typed literal.

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 24 * 60 * 60)
    }

    func testCursorAfterStalenessCheckNilInNilOut() {
        XCTAssertNil(SyncMerge.cursorAfterStalenessCheck(nil, now: now))
    }

    func testCursorAfterStalenessCheckOneDayOldReturnedUnchanged() {
        let cursor = SyncDate.string(from: daysAgo(1))
        XCTAssertEqual(SyncMerge.cursorAfterStalenessCheck(cursor, now: now), cursor)
    }

    func testCursorAfterStalenessCheck59DaysOldReturnedUnchanged() {
        let cursor = SyncDate.string(from: daysAgo(59))
        XCTAssertEqual(SyncMerge.cursorAfterStalenessCheck(cursor, now: now), cursor)
    }

    func testCursorAfterStalenessCheck61DaysOldReturnsNil() {
        let cursor = SyncDate.string(from: daysAgo(61))
        XCTAssertNil(SyncMerge.cursorAfterStalenessCheck(cursor, now: now))
    }

    /// The boundary is EXACTLY `cursorMaxAgeDays` days old — the implementation uses strict `>`, so
    /// an age exactly equal to the limit must still be trusted. Asserted against the constant
    /// itself, not a restated `60`, so an edit to `cursorMaxAgeDays` alone still exercises the real
    /// boundary instead of silently testing the wrong day count.
    func testCursorAfterStalenessCheckExactlyAtBoundaryReturnedUnchanged() {
        let cursor = SyncDate.string(from: daysAgo(Double(SyncMerge.cursorMaxAgeDays)))
        XCTAssertEqual(SyncMerge.cursorAfterStalenessCheck(cursor, now: now), cursor)
    }

    func testCursorAfterStalenessCheckUnparseableReturnsNil() {
        XCTAssertNil(SyncMerge.cursorAfterStalenessCheck("not a timestamp", now: now))
    }

    /// A cursor from the FUTURE (server clock ahead of this device) must never be treated as stale —
    /// only elapsed time in the positive direction can have outrun the server's sweep.
    func testCursorAfterStalenessCheckFutureCursorReturnedUnchanged() {
        let cursor = SyncDate.string(from: now.addingTimeInterval(1_000_000))
        XCTAssertEqual(SyncMerge.cursorAfterStalenessCheck(cursor, now: now), cursor)
    }

    /// Pins the invariant the whole valve depends on: the client's own margin must stay strictly
    /// below how long the server keeps a tombstone. This test exists so a future edit that changes
    /// one of these two constants alone fails HERE, in a two-second unit test, instead of silently
    /// resurrecting deleted tasks in production months later.
    func testCursorMaxAgeStaysBelowServerTombstoneRetention() {
        XCTAssertLessThan(SyncMerge.cursorMaxAgeDays, SyncMerge.serverTombstoneRetentionDays)
    }

    // MARK: - gate(state:) — design.md §8, the client-side pre-check that keeps task content
    // (including `sourceTranscript`) from leaving the machine just to be rejected server-side.

    private func syncState(isPro: Bool, syncEnabled: Bool) -> SyncState {
        SyncState(isPro: isPro, syncEnabled: syncEnabled, enabledAt: nil, enabledByDevice: nil, devices: [])
    }

    func testGateNilStateIsUnknown() {
        // Never successfully fetched — must NOT read as a denial.
        XCTAssertEqual(SyncMerge.gate(state: nil), .unknown)
    }

    func testGateNotProSwitchOnIsBlockedProRequired() {
        let state = syncState(isPro: false, syncEnabled: true)
        XCTAssertEqual(SyncMerge.gate(state: state), .blocked(.proRequired))
    }

    func testGateProSwitchOffIsBlockedDisabled() {
        let state = syncState(isPro: true, syncEnabled: false)
        XCTAssertEqual(SyncMerge.gate(state: state), .blocked(.disabled))
    }

    func testGateProSwitchOnIsAllowed() {
        let state = syncState(isPro: true, syncEnabled: true)
        XCTAssertEqual(SyncMerge.gate(state: state), .allowed)
    }

    /// Pins the ORDER to match the two `raise exception`s inside `sync_exchange` (migration 0005):
    /// Pro is checked before the switch, so an account that is both non-Pro and switched off gets
    /// `.proRequired` from the client — the same reason the server would give — rather than the
    /// two sides reporting different things for the same account.
    func testGateNeitherProNorSwitchedOnIsBlockedProRequiredNotDisabled() {
        let state = syncState(isPro: false, syncEnabled: false)
        XCTAssertEqual(SyncMerge.gate(state: state), .blocked(.proRequired))
    }

    /// `SyncState.unknown` (the STATE, `SyncContracts.swift`'s static default with `isPro: false`)
    /// is a real fetched value and a completely different thing from `SyncGate.unknown` (the GATE,
    /// meaning "never fetched at all"). Only a genuine `nil` produces the gate's `.unknown` — a
    /// state that merely happens to be named `.unknown` still resolves through the ordinary
    /// Pro-then-switch logic like any other fetched `SyncState`.
    func testGateSyncStateDotUnknownIsBlockedProRequiredNotGateUnknown() {
        XCTAssertEqual(SyncMerge.gate(state: SyncState.unknown), .blocked(.proRequired))
    }
}
