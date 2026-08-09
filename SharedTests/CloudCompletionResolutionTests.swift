// Tests/CloudCompletionResolutionTests.swift — pure decision-logic coverage for the cloud
// completion-paraphrase rescue (`AppState.resolveCloudMatch`, `Sources/App/AppState.swift`).
//
// SCOPE: `VoiceDone.classify` (Sources/Speech/VoiceDone.swift) Jaccard-matches a "xong/done"
// utterance against open-task titles on-device; a paraphrase shares no tokens and comes back with
// ZERO candidates. `AppState.resolveCompletionViaCloud` asks Cloud (`IntentRouter.resolveCompletion`
// -> `CloudParser.resolveCompletion`, `Sources/Parsing/{IntentParsing,CloudParser}.swift`) to
// semantically match the SAME candidate titles instead, and `AppState.resolveCloudMatch` is the
// pure, `static` (not `private`) safety-check function that decides whether the server's answer is
// trustworthy enough to present to the user. This file exercises ONLY that pure function — no
// `URLSession`, no real `AppState`/`IntentRouter`/`CloudParser` instance, no networking of any kind,
// per this task's explicit instruction. `AppState.resolveCloudMatch`'s own doc comment records why
// it was pulled out as a `static` function in the first place: exactly so this file could exist
// without spinning up a live `AppState`.
//
// The wire-decode trust-boundary checks inside `CloudParser.resolveCompletion` itself (malformed
// JSON, out-of-range `matchIndex` from the SERVER's own zero-candidate edge case, non-finite
// `confidence`, unrecognized `intent`) are NOT re-tested here — that logic lives behind a private
// `URLSession` round trip in a different file and isn't reachable without performing real
// networking, which this task explicitly rules out. Everything downstream of "a `CompletionResolution`
// value already exists" is what's covered below.
//
// UNVERIFIED (written entirely on Windows — no Xcode/swift toolchain available in this environment):
// not run against a real `VolarTests` bundle. Compile-by-inspection only.
import XCTest
@testable import Volar

@MainActor
final class CloudCompletionResolutionTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSnapshot(_ titles: [String]) -> [(id: UUID, title: String)] {
        titles.map { (UUID(), $0) }
    }

    /// Computed, not a stored `let` initialized inline at class-body scope: `AppState`'s constant is
    /// `@MainActor`-isolated (the enclosing class), and reading it from a computed property's getter
    /// — invoked fresh from within each already-`@MainActor` test method — is unambiguously safe
    /// under Swift 6 strict concurrency, whereas a stored property's default-value expression
    /// evaluates during (implicit) `init`, whose isolation is less obviously guaranteed here.
    private var threshold: Double { AppState.cloudCompletionConfidenceThreshold }

    // MARK: - Off-by-one: index at both boundaries

    func testIndexOneResolvesToFirstCandidate() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3", "Đi chợ", "Gọi khách hàng"])
        let resolution = CloudParser.CompletionResolution.resolved(
            index: 1, title: "Viết báo cáo Q3", confidence: 0.9
        )

        let match = AppState.resolveCloudMatch(resolution, snapshot: snapshot)

        XCTAssertEqual(match?.taskId, snapshot[0].id, "index: 1 must pick candidates[0], never candidates[1] — the off-by-one this feature exists to get right")
        XCTAssertEqual(match?.title, "Viết báo cáo Q3")
    }

    func testIndexNResolvesToLastCandidate() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3", "Đi chợ", "Gọi khách hàng"])
        let resolution = CloudParser.CompletionResolution.resolved(
            index: snapshot.count, title: "Gọi khách hàng", confidence: 0.9
        )

        let match = AppState.resolveCloudMatch(resolution, snapshot: snapshot)

        XCTAssertEqual(match?.taskId, snapshot[2].id, "index == N must pick the LAST candidate, snapshot[N-1]")
        XCTAssertEqual(match?.title, "Gọi khách hàng")
    }

    // MARK: - Index out of range

    func testIndexZeroIsRejected() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3", "Đi chợ"])
        let resolution = CloudParser.CompletionResolution.resolved(
            index: 0, title: "Viết báo cáo Q3", confidence: 0.9
        )

        XCTAssertNil(AppState.resolveCloudMatch(resolution, snapshot: snapshot), "index 0 is not a valid 1-based position — must never wrap to any candidate")
    }

    func testIndexNPlusOneIsRejected() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3", "Đi chợ"])
        let resolution = CloudParser.CompletionResolution.resolved(
            index: snapshot.count + 1, title: "Đi chợ", confidence: 0.9
        )

        XCTAssertNil(AppState.resolveCloudMatch(resolution, snapshot: snapshot), "index == N+1 is one past the end — must be rejected, not clamped")
    }

    /// Defensive: an empty snapshot combined with any `.resolved` index must degrade to `nil`
    /// rather than trapping on `1...0` — `resolveCompletionViaCloud` never actually calls this with
    /// an empty snapshot (it guards before ever reaching the network), but `resolveCloudMatch` is
    /// `static` specifically to be exercised directly like this, independent of that caller-side
    /// guard.
    func testEmptySnapshotNeverCrashesAndRejects() {
        let resolution = CloudParser.CompletionResolution.resolved(index: 1, title: "anything", confidence: 0.9)

        XCTAssertNil(AppState.resolveCloudMatch(resolution, snapshot: []))
    }

    // MARK: - Title-echo mismatch

    func testTitleEchoMismatchIsRejected() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3", "Đi chợ"])
        // Index 1 is in range, but the model echoed a DIFFERENT title than what's actually at that
        // position — must be treated as no match, never as "trust the index" or "trust the title."
        let resolution = CloudParser.CompletionResolution.resolved(
            index: 1, title: "Đi chợ", confidence: 0.9
        )

        XCTAssertNil(AppState.resolveCloudMatch(resolution, snapshot: snapshot), "an index/title disagreement must reject the match rather than picking either side")
    }

    func testTitleEchoMatchIgnoringSurroundingWhitespaceIsAccepted() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3"])
        // The comparison is against TRIMMED strings — incidental whitespace in the model's echo
        // must not cause a false rejection.
        let resolution = CloudParser.CompletionResolution.resolved(
            index: 1, title: "  Viết báo cáo Q3  ", confidence: 0.9
        )

        XCTAssertNotNil(AppState.resolveCloudMatch(resolution, snapshot: snapshot))
    }

    // MARK: - Confidence threshold

    func testConfidenceJustBelowThresholdIsRejected() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3"])
        let resolution = CloudParser.CompletionResolution.resolved(
            index: 1, title: "Viết báo cáo Q3", confidence: threshold - 0.01
        )

        XCTAssertNil(AppState.resolveCloudMatch(resolution, snapshot: snapshot))
    }

    func testConfidenceAtThresholdIsAccepted() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3"])
        // The contract is `confidence >= threshold` (inclusive) — exactly-at-the-bar must pass.
        let resolution = CloudParser.CompletionResolution.resolved(
            index: 1, title: "Viết báo cáo Q3", confidence: threshold
        )

        XCTAssertNotNil(AppState.resolveCloudMatch(resolution, snapshot: snapshot))
    }

    func testConfidenceJustAboveThresholdIsAccepted() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3"])
        let resolution = CloudParser.CompletionResolution.resolved(
            index: 1, title: "Viết báo cáo Q3", confidence: threshold + 0.01
        )

        XCTAssertNotNil(AppState.resolveCloudMatch(resolution, snapshot: snapshot))
    }

    func testNonFiniteConfidenceIsRejected() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3"])
        let resolution = CloudParser.CompletionResolution.resolved(
            index: 1, title: "Viết báo cáo Q3", confidence: .nan
        )

        XCTAssertNil(AppState.resolveCloudMatch(resolution, snapshot: snapshot), "NaN must never compare >= threshold as true by accident")
    }

    // MARK: - `.none` / `.unavailable` both degrade to "no match" (caller then uses an empty
    // candidate list, exactly today's pre-existing "no matching task" behavior)

    func testNoneProducesNoMatch() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3"])

        XCTAssertNil(AppState.resolveCloudMatch(.none, snapshot: snapshot))
    }

    func testUnavailableProducesNoMatch() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3"])

        XCTAssertNil(AppState.resolveCloudMatch(.unavailable, snapshot: snapshot))
    }

    // MARK: - Score carries the cloud confidence (VoiceMatch has no separate provenance field)

    func testResolvedMatchCarriesConfidenceAsScore() {
        let snapshot = makeSnapshot(["Viết báo cáo Q3"])
        let resolution = CloudParser.CompletionResolution.resolved(
            index: 1, title: "Viết báo cáo Q3", confidence: 0.83
        )

        let match = AppState.resolveCloudMatch(resolution, snapshot: snapshot)

        XCTAssertEqual(match?.score, 0.83)
    }
}
