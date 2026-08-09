// Shared/Sync/SyncMerge.swift — pure decisions for the sync engine: which side wins a conflict,
// what an HTTP failure MEANS, and how the opaque cursor advances.
//
// UNVERIFIED: written on Windows, never compiled.
//
// Convention this repo already follows for exactly this kind of code (`CueFiring.swift`,
// `WaitingMode.swift`, `FullScreenEscalationDecision.swift`'s own headers): no `Date()`, no
// `UserDefaults`, no `URLSession`, no `ModelContext` — every already-resolved signal is a plain
// parameter, so `SharedTests/SyncMergeTests.swift` (group D) can drive every branch with hand-built
// values and zero networking/storage involved.
import Foundation

/// The two, and only two, outcomes of applying one remote record against local state. Kept apart
/// from `SyncFailure` (a network/account-level outcome) on purpose — this is a per-RECORD verdict
/// that runs once for every row `TaskStore.applyRemote(_:)` is handed, not once per sync attempt.
enum MergeDecision: Sendable, Equatable {
    case apply
    case skip
}

enum SyncMerge {
    // MARK: - LWW (client-contract.md §4, design.md §5)

    /// Last-write-wins at the RECORD level, decided purely from the two clocks — never from which
    /// side is "local" vs "remote" in some other sense. `localUpdatedAt == nil` means this id has
    /// never been seen locally at all (a brand-new pull), which always applies: there is nothing to
    /// compare against, so the remote row can't lose to something that doesn't exist yet.
    ///
    /// STRICT `>` (not `>=`) is the whole contract here: a remote row with a timestamp EQUAL to the
    /// local one is a no-op re-delivery (the 2-second overlap window in `sync_exchange`'s SQL is
    /// expected to resend already-applied rows — see migration 0005's own header on that), not a
    /// conflict to resolve. Applying it again would be harmless but wasteful; skipping it is the
    /// correct, idempotent answer. A remote row OLDER than local is the actual losing case: the
    /// local edit is newer and must not be clobbered by something that arrived after but was
    /// authored before.
    static func decide(localUpdatedAt: Date?, remoteUpdatedAt: Date) -> MergeDecision {
        guard let localUpdatedAt else { return .apply }
        return remoteUpdatedAt > localUpdatedAt ? .apply : .skip
    }

    // MARK: - Failure classification (client-contract.md §3.3 — the ONE lookup table)

    /// Maps an already-resolved HTTP outcome (or its absence, for a transport failure) onto the
    /// THREE-WAY split `SyncContracts.swift`'s `SyncFailure` exists to enforce. Nothing here talks
    /// to the network — `SyncClient` does the actual request and hands this function the result.
    ///
    /// `status == nil` means the request never got an HTTP response at all (DNS failure, timeout,
    /// TLS handshake failure, offline) — `transportError` is expected non-nil in that case, but this
    /// function tolerates it being `nil` too (defensive: a caller bug shouldn't be able to make this
    /// throw or crash, only ever produce SOME `SyncFailure`).
    ///
    /// 401 maps to `.signedOut` regardless of `message` — PostgREST itself can return a 401 for
    /// reasons that never reach `sync_exchange`'s own `raise exception 'sync_not_authenticated'`
    /// (e.g. an already-expired JWT rejected before the function body even runs), and every one of
    /// those reasons means the same thing to this client: the session is dead, go sign in again.
    /// 403 is the opposite: the two codes this app raises on purpose (`sync_pro_required` /
    /// `sync_disabled`) are matched EXACTLY, because collapsing them would defeat the entire reason
    /// they're two different strings (contract §3.3 — "gộp cả ba... là cách chắc chắn nhất để user
    /// tắt công tắc ở máy khác rồi ngồi debug wifi"). A 403 with any other message (or none) falls
    /// through to `.server` — some future RPC-level check this build doesn't know how to name yet.
    static func classify(status: Int?, message: String?, transportError: Error?) -> SyncFailure {
        guard let status else {
            let description = transportError.map { "\($0.localizedDescription)" } ?? "no response"
            return .offline(description)
        }
        if status == 403, message == "sync_pro_required" { return .proRequired }
        if status == 403, message == "sync_disabled" { return .disabled }
        if status == 401 { return .signedOut }
        return .server(status: status, message: message)
    }

    // MARK: - Cursor advance (client-contract.md §6, §3.1's `hasMore` note)

    /// `candidate` is the cursor value THIS response returned for one of the two streams
    /// (`cursorTasks` xor `cursorCompletions`) — call this once per stream, never mixing the two
    /// (client-contract.md §4: two cursors exist specifically so a full page of one stream can never
    /// make the other stream's cursor jump past rows it hasn't seen yet).
    ///
    /// `candidate == nil` (contract §3.1: the RPC returns `null` when its own page was empty AND the
    /// caller had no prior cursor either) keeps `previous` — there is nothing to advance to.
    /// `previous == nil` with a non-nil `candidate` always adopts it (nothing to compare against).
    ///
    /// Both non-nil: cursors are OPAQUE strings (contract §6 — never parsed to `Date`, precision
    /// loss risk), so "forward" here is necessarily a best-effort string comparison rather than a
    /// true instant comparison. This is sound in practice ONLY because every cursor value in this
    /// system is produced by the same source in the same fixed-width ISO-8601 shape
    /// (`sync_exchange`'s `to_json(timestamptz)` output, always `SyncDate`-compatible) — lexical
    /// order and chronological order coincide for that shape. It is NOT a general-purpose string
    /// comparison and would need revisiting if the server ever changed its timestamp rendering.
    /// Guards a provably-backward candidate (a misbehaving/rolled-back server, or two responses
    /// applied out of order) from ever regressing the stored cursor and re-fetching rows the client
    /// has already applied.
    static func nextCursor(previous: String?, candidate: String?) -> String? {
        guard let candidate else { return previous }
        guard let previous else { return candidate }
        return candidate >= previous ? candidate : previous
    }

    // MARK: - Cursor staleness (design.md §6 — the "offline longer than the tombstone" valve)

    /// How long the SERVER keeps a tombstone before it is swept (design.md §6, migration
    /// `0005_sync_schema.sql`). Declared here — not only in SQL — because the client's own margin
    /// below is defined RELATIVE to it, and a reader has to be able to see both numbers at once.
    static let serverTombstoneRetentionDays = 90

    /// A stored cursor older than this is thrown away and its stream re-pulled from scratch.
    ///
    /// 🔴 THE `60 < 90` RELATIONSHIP IS THE WHOLE POINT — NEVER CHANGE ONE NUMBER WITHOUT THE OTHER.
    /// A cursor N days old means "the last thing this device saw from the server was N days ago".
    /// Past `serverTombstoneRetentionDays` the server has swept the tombstones, so a device resuming
    /// on such a cursor pulls every still-alive task, never learns which ones were DELETED, and
    /// re-pushes its stale copies — resurrecting deleted tasks and spreading them to every other
    /// device (design.md §6 called this out as accepted; this valve is anh Khôi closing it).
    /// Resetting to `nil` costs one full re-pull, which is harmless: it is an ordinary sync round,
    /// LWW arbitrates every row exactly as usual, and NOTHING local is deleted. The 30-day gap is
    /// the margin for clock skew, a device that resumes mid-sweep, and any future change to the
    /// server's sweep schedule. Raising this at or above `serverTombstoneRetentionDays` re-opens the
    /// exact hole it exists to close; lowering the server's retention toward this does the same.
    static let cursorMaxAgeDays = 60

    /// Valve 1: hand back the cursor only while it is still trustworthy, `nil` otherwise.
    ///
    /// Contract §6 says a cursor is an OPAQUE string and must never be parsed into a `Date`. This
    /// function is the one deliberate exception and it does not violate the reason for that rule:
    /// the rule exists so a cursor never ROUND-TRIPS through `Date` (Postgres emits 6 fractional
    /// digits, `Date` cannot hold them, and a re-serialized cursor would skip rows). Here the parsed
    /// value is used only to answer "is this older than `cursorMaxAgeDays`"; the string that goes
    /// back on the wire is always the original, byte for byte, or nothing at all.
    ///
    /// An UNPARSEABLE cursor also returns `nil`: a value this client cannot read is a value it
    /// cannot vouch for, and the cost of being wrong is one extra full pull versus resurrected
    /// tasks. `now` is a parameter, never `Date()` — this file stays pure and testable (file header).
    static func cursorAfterStalenessCheck(_ cursor: String?, now: Date) -> String? {
        guard let cursor, let stamp = SyncDate.parse(cursor) else { return nil }
        let maxAge = TimeInterval(cursorMaxAgeDays) * 24 * 60 * 60
        // A cursor from the FUTURE (server clock ahead of this device) is not stale — only elapsed
        // time in the positive direction can have outrun the server's sweep.
        return now.timeIntervalSince(stamp) > maxAge ? nil : cursor
    }
}
