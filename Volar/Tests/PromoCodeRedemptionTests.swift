// Tests/PromoCodeRedemptionTests.swift — pure-logic coverage for the "1 free month of Pro" promo
// code redemption feature (`AccountService.redeemPromoCode`/`AppState.redeemPromoCode`,
// `POST /functions/v1/subscription/redeem`).
//
// SCOPE (per this feature's task brief): no networking — `AccountService` is a real actor that
// hits Supabase over `URLSession`, and this file never constructs a live one. What IS covered is
// everything pure and reachable without a network round trip:
//   1. `AccountService.normalizeCode(_:)` — the ONE place client-side normalization happens (trim
//      whitespace/newlines, then uppercase) before a code is ever sent on the wire.
//   2. `AccountService.mapRedeemError(status:data:)` — the redeem-specific status -> `AccountError`
//      mapping (404/409/410/429), plus the fallback to the shared opaque `.http` shape for anything
//      NOT specifically documented by the redeem contract (400/401/503/etc).
//   3. `AccountError`'s `LocalizedError` messages for the four new redeem-specific cases.
//   4. `RedeemResult`'s `Codable` shape against the LOCKED contract's exact 200 body.
//   5. `AppState.redeemPromoCode`'s synchronous empty-code guard (never flips `accountBusy`, never
//      dispatches a `Task`) and `lastRedeemedUntil`'s plain state-transition surface.
//
// Both `normalizeCode` and `mapRedeemError` are `static` on `AccountService` (a PLAIN, non-
// `@MainActor` actor) and therefore `nonisolated`/directly callable by default — a plain actor's
// static members are nonisolated unless marked otherwise (see `AccountService.shared`'s own doc
// comment for the exact precedent this relies on) — so both are reachable from this file with no
// `await` and no actor instance. Both were widened from `private` to internal specifically so this
// file can reach them via `@testable import` (which only relaxes `internal`, not `private` — see
// `CaptureHotkeyAndTitleEditTests.swift`'s own note on that same distinction), mirroring
// `AppState.applyTextCaptureParseResult`'s existing precedent of loosening one method's access
// purely so a test can drive it directly.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): not run
// against a real `VolarTests` bundle.
import XCTest
@testable import Volar

final class PromoCodeRedemptionTests: XCTestCase {

    // MARK: - Normalization (Task 1: "trim whitespace/newlines then uppercase, ONE place")

    func testNormalizeCodeTrimsWhitespaceAndNewlinesThenUppercases() {
        XCTAssertEqual(AccountService.normalizeCode("  volar-abc\n"), "VOLAR-ABC")
    }

    func testNormalizeCodeIsIdempotentOnAnAlreadyNormalizedCode() {
        XCTAssertEqual(AccountService.normalizeCode("VOLAR-ABC"), "VOLAR-ABC")
    }

    func testNormalizeCodeCollapsesWhitespaceOnlyInputToEmpty() {
        XCTAssertEqual(AccountService.normalizeCode("   \n\t "), "")
    }

    func testNormalizeCodePreservesInternalCharactersVerbatim() {
        // Only leading/trailing whitespace is trimmed — internal punctuation/digits pass through
        // unchanged (aside from case), matching a promo code shape like "VOLAR-2026-SUMMER".
        XCTAssertEqual(AccountService.normalizeCode(" volar-2026-summer "), "VOLAR-2026-SUMMER")
    }

    // MARK: - Status -> AccountError mapping (contract's redeem status table)

    func testMapRedeemError404IsPromoCodeInvalid() {
        XCTAssertEqual(AccountService.mapRedeemError(status: 404, data: Data()), .promoCodeInvalid)
    }

    func testMapRedeemError409IsPromoCodeAlreadyRedeemed() {
        XCTAssertEqual(AccountService.mapRedeemError(status: 409, data: Data()), .promoCodeAlreadyRedeemed)
    }

    func testMapRedeemError410IsPromoCodeExhausted() {
        XCTAssertEqual(AccountService.mapRedeemError(status: 410, data: Data()), .promoCodeExhausted)
    }

    func testMapRedeemError429IsPromoCodeTooManyAttempts() {
        XCTAssertEqual(AccountService.mapRedeemError(status: 429, data: Data()), .promoCodeTooManyAttempts)
    }

    func testMapRedeemErrorUndocumentedStatusFallsBackToOpaqueHTTPShape() {
        // 503 (and anything else not in the redeem contract's status table) falls through to the
        // SAME `.http(status:code:)` shape every other endpoint on `AccountService` already uses —
        // no second, redeem-only fallback shape invented for this one method.
        let body = #"{"error":"service_unavailable"}"#.data(using: .utf8)!
        XCTAssertEqual(
            AccountService.mapRedeemError(status: 503, data: body),
            .http(status: 503, code: "service_unavailable")
        )
    }

    func testMapRedeemError400FallsBackToOpaqueHTTPShapeWithDecodedCode() {
        let body = #"{"error":"invalid_request"}"#.data(using: .utf8)!
        XCTAssertEqual(
            AccountService.mapRedeemError(status: 400, data: body),
            .http(status: 400, code: "invalid_request")
        )
    }

    // MARK: - AccountError messages (must not claim more than the server said — self-review §2)

    func testPromoCodeInvalidMessageDoesNotDistinguishUnknownFromExpired() {
        // The server deliberately collapses unknown/expired/deactivated into one `code_invalid` —
        // this message must not imply more precision than that.
        XCTAssertEqual(AccountError.promoCodeInvalid.errorDescription, "That code isn't valid.")
    }

    func testPromoCodeAlreadyRedeemedMessage() {
        XCTAssertEqual(AccountError.promoCodeAlreadyRedeemed.errorDescription, "You've already used this code.")
    }

    func testPromoCodeExhaustedMessage() {
        XCTAssertEqual(AccountError.promoCodeExhausted.errorDescription, "This code has been fully claimed.")
    }

    func testPromoCodeTooManyAttemptsMessage() {
        XCTAssertEqual(AccountError.promoCodeTooManyAttempts.errorDescription, "Too many attempts. Try again tomorrow.")
    }

    // MARK: - RedeemResult decoding (LOCKED 200 body shape)

    func testRedeemResultDecodesTheDocumented200Body() throws {
        let json = #"""
        {"tier":"pro","expiresAt":"2026-08-27T00:00:00Z","grantedDays":30,"source":"promo"}
        """#.data(using: .utf8)!
        let result = try JSONDecoder().decode(RedeemResult.self, from: json)
        XCTAssertEqual(result.tier, .pro)
        XCTAssertEqual(result.expiresAt, "2026-08-27T00:00:00Z")
        XCTAssertEqual(result.grantedDays, 30)
        XCTAssertEqual(result.source, "promo")
    }

    // MARK: - AppState.redeemPromoCode: empty-code no-op guard (synchronous, no networking)

    @MainActor
    func testRedeemPromoCodeIsANoOpForAnEmptyCode() {
        let state = AppState()
        state.redeemPromoCode("")
        XCTAssertFalse(state.accountBusy, "an empty code must never flip accountBusy — there's nothing to submit")
        XCTAssertNil(state.accountError)
    }

    @MainActor
    func testRedeemPromoCodeIsANoOpForAWhitespaceOnlyCode() {
        let state = AppState()
        state.redeemPromoCode("   \n\t")
        XCTAssertFalse(state.accountBusy)
    }

    // MARK: - lastRedeemedUntil: plain state-transition surface

    @MainActor
    func testFreshAppStateHasNoRedemptionConfirmation() {
        let state = AppState()
        XCTAssertNil(state.lastRedeemedUntil, "no confirmation should be showing before any redeem attempt")
    }

    @MainActor
    func testLastRedeemedUntilCanBeDrivenDirectlyLikeTextCaptureTestsDrivesItsOwnState() {
        // Mirrors `TextCaptureTests`' own convention of setting a plain, non-`private` `var`
        // directly to exercise the STATE surface `SettingsView` reads, without going through the
        // real (network-bound) actor call — see this file's header comment.
        let state = AppState()
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        state.lastRedeemedUntil = expiry
        XCTAssertEqual(state.lastRedeemedUntil, expiry)
    }
}
