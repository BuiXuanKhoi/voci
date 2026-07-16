// Sources/Orchestrator/AppLinkHandler.swift — inbound `volar://` app-link routing (US4,
// specs/002-workflow-command-center/contracts/phase6-contract.md §A +
// specs/002-workflow-command-center/contracts/app-links.md, the authoritative behavioral spec).
//
// URL SCHEME: `volar` — confirmed in Volar/Resources/Info.plist's `CFBundleURLTypes` (the project
// was renamed Voci -> Volar; that Info.plist comment already documents that nothing implements
// `.onOpenURL` yet, i.e. this file is that missing handler). This file does not hard-fail on a
// different scheme (SwiftUI's `.onOpenURL` only ever routes URLs matching a registered scheme in
// the first place) but does log+ignore one, defensively, rather than assume the caller pre-filtered.
//
// CAPTURE SEAM: per this task's instructions, capture parsing itself is NOT implemented here
// (`volar://capture?text=...&source=...` must "hand text to the existing capture pipeline" without
// bypassing the confirm card — app-links.md). This file exposes `onCapture`, a closure the
// app-wiring agent sets in `AppState`/`VolarApp.swift` to the existing entry point
// (`AppState.proceedToCapture(transcript:)` per `Volar/Sources/App/AppState.swift`, which already
// runs transcripts through the parser + confirm-card flow — see that file's `finishRecording`/
// `proceedToCapture`). Leaving this file free of any UI/AppState import keeps it testable in
// isolation and keeps this task's file ownership to exactly the two Orchestrator files.
import Foundation
import VolarCore

/// Routes inbound `volar://` URLs (`.onOpenURL`). Inbound-only, one-way, idempotent,
/// non-destructive (Constitution I/II, app-links.md's own framing): a signal may surface work for
/// review but can never complete, delete, or create a task on its own.
@MainActor
final class AppLinkHandler {
    private let store: TaskStore
    private let delegation: DelegationTracker

    /// For the ambiguous `ai-done` case, the candidate waiting tasks so the UI can show a one-tap
    /// card (contract A). Cleared once resolved (see `resolveDisambiguation`/`dismissDisambiguation`
    /// below) or superseded by a later `handle(_:)` call.
    private(set) var pendingDisambiguation: [UUID] = []

    /// Capture seam (see file header): the app-wiring agent assigns this to the existing capture
    /// pipeline entry point. `text` is already percent-decoded (URLComponents does this
    /// automatically); `source` is the optional origin reference app-links.md documents for
    /// `volar://capture`. Left `nil` (default) is a safe no-op — a capture link received before
    /// wiring is complete is logged and dropped, never silently guessed at or force-unwrapped.
    var onCapture: ((_ text: String, _ source: String?) -> Void)?

    init(store: TaskStore, delegation: DelegationTracker) {
        self.store = store
        self.delegation = delegation
    }

    /// SwiftUI `.onOpenURL` entry. Routes `<scheme>://ai-done?cwd=...&tty=...` per app-links.md's
    /// matching ladder (exactly-one-waiting -> cwd prefix-match -> ambient disambiguation card;
    /// unknown/none -> log+ignore). Idempotent; NEVER completes a task. Also
    /// `<scheme>://capture?text=` -> feeds the existing capture/parse pipeline (never bypasses the
    /// confirm card). Malformed input (unparsable URL, missing host, unknown host) is logged and
    /// ignored — this method never throws or crashes on bad input.
    func handle(_ url: URL) {
        guard let scheme = url.scheme, scheme.caseInsensitiveCompare("volar") == .orderedSame else {
            log("ignored URL with unexpected scheme: \(url.absoluteString)")
            return
        }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host,
            !host.isEmpty
        else {
            log("malformed or hostless URL, ignored: \(url.absoluteString)")
            return
        }
        let params = Self.queryDictionary(components)
        switch host {
        case "ai-done":
            handleAIDone(params: params)
        case "capture":
            handleCapture(params: params)
        default:
            log("unknown app-link host \(host), ignored")
        }
    }

    /// User tapped a candidate on the one-tap disambiguation card: resolve exactly that task
    /// (never auto-picks — the whole reason this card exists is Principle II, "never silently
    /// pick"). A no-op if `taskId` isn't among the current candidates (stale card / already
    /// resolved by another path).
    func resolveDisambiguation(taskId: UUID) {
        guard pendingDisambiguation.contains(taskId) else { return }
        delegation.markNeedsReview(taskId: taskId)
        pendingDisambiguation.removeAll()
    }

    /// User dismissed the disambiguation card without picking (e.g. "none of these" / not now).
    /// Purely local UI state — no task is touched.
    func dismissDisambiguation() {
        pendingDisambiguation.removeAll()
    }

    // MARK: - ai-done

    private func handleAIDone(params: [String: String]) {
        // `tty` (app-links.md: "Reserved... Accepted and stored, unused in v2") is deliberately
        // read here (`params["tty"]`) only to confirm parsing never throws on it — `DelegationMeta`
        // (Volar/Sources/Model/Recurrence.swift, frozen/out of this task's file ownership) has no
        // `tty` field to persist it into, so "stored" isn't achievable without editing that struct;
        // it is accepted and otherwise ignored until a future schema change adds the field.
        _ = params["tty"]
        let waiting = waitingTaskIDs()
        guard !waiting.isEmpty else {
            log("ai-done received with no tasks currently waiting on AI — ignored")
            return
        }
        // Step 1: exactly one task waiting-on-AI overall -> unambiguous, regardless of cwd/tty.
        if waiting.count == 1, let only = waiting.first {
            resolve(only)
            return
        }
        // Step 2: cwd prefix-match against each waiting task's DelegationMeta.cwdHint. The hint is
        // captured at delegate-time and is typically a project root; the signal's `cwd` is the
        // directory the agent actually ran in, which may be that root or a subdirectory of it —
        // so the match direction is "hint prefixes cwd", not the reverse.
        if let cwd = params["cwd"], !cwd.isEmpty {
            let matches = waiting.filter { taskId in
                guard let hint = delegation.cwdHint(for: taskId), !hint.isEmpty else { return false }
                return cwd.hasPrefix(hint)
            }
            if matches.count == 1, let only = matches.first {
                resolve(only)
                return
            }
            if matches.count > 1 {
                // Still ambiguous, but narrow the one-tap card to the relevant subset rather than
                // every waiting task in the app — strictly more useful, still "waiting tasks" per
                // app-links.md's card description.
                pendingDisambiguation = matches
                log("ai-done ambiguous after cwd match (\(matches.count) candidates) — exposed for disambiguation")
                return
            }
        }
        // Step 3: ambient one-tap disambiguation card listing (all) waiting tasks.
        pendingDisambiguation = waiting
        log("ai-done ambiguous (\(waiting.count) tasks waiting) — exposed for disambiguation")
    }

    private func resolve(_ taskId: UUID) {
        delegation.markNeedsReview(taskId: taskId)
        pendingDisambiguation.removeAll()
    }

    /// Tasks currently carrying an unsatisfied "waiting on AI" condition — the live candidate set
    /// for the matching ladder. Sharing `DelegationTracker.isWaitingOnAI` (rather than redefining
    /// the recognition rule here) keeps this file and `DelegationTracker` from ever disagreeing on
    /// what "waiting" means (self-review "conflict").
    private func waitingTaskIDs() -> [UUID] {
        store.fetchAll()
            .filter { $0.status != .done && $0.status != .archived }
            .filter { $0.conditions.contains(where: DelegationTracker.isWaitingOnAI) }
            .map(\.id)
    }

    // MARK: - capture

    private func handleCapture(params: [String: String]) {
        guard let text = params["text"], !text.isEmpty else {
            log("capture link missing required text= param — ignored")
            return
        }
        guard let onCapture else {
            log("capture link received before the capture pipeline hook was wired — dropped")
            return
        }
        onCapture(text, params["source"])
    }

    // MARK: - Parsing helpers

    private static func queryDictionary(_ components: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value else { continue }
            result[item.name] = value
        }
        return result
    }

    private func log(_ message: String) {
        // Local-only diagnostic (Constitution I: inbound signals are logged locally, never
        // shipped anywhere) — mirrors `TaskStore`'s existing `print("[Volar...")` convention
        // (see `TaskStore.sanitizedConditions`).
        print("[Volar.AppLinkHandler] \(message)")
    }
}
