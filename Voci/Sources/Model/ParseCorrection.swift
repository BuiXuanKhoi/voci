// Sources/Model/ParseCorrection.swift — local-only correction log (constitution V, FR-044).
//
// OWNERSHIP (Phase 3, feature 002, T026): this file owns `ParseCorrection` + its append API. The
// UI hook that CALLS `ParseCorrectionLog.record` on every chip edit belongs to the PopoverView
// agent — this file only provides the model + API surface.
import Foundation
import SwiftData

/// One user correction of a parsed attribute — logged when the user edits a confirm-card chip
/// before/at save time (constitution V: "Every user correction ... MUST be logged locally as the
/// dataset for improving parsing — without violating Principle I"). Local-only: this file has no
/// network code path, and nothing in this codebase egresses `ParseCorrection` rows anywhere
/// (FR-044) — the only persistence is the local SwiftData store already used for `VociTask`/
/// `CompletionEvent`.
@Model
final class ParseCorrection {
    @Attribute(.unique) var id: UUID
    /// Which `ParsedTask` attribute this correction is about — e.g. "deadline", "priority",
    /// "conditions[0].titleQuery", "recurrence". Free-form `String` (not an enum) so a new chip
    /// kind added later by another agent can log a correction without a matching case added here.
    var attribute: String
    /// The value the parser produced, stringified for display/logging (e.g. "Tomorrow 2:00 PM").
    var parsedValue: String
    /// The value the user actually confirmed/typed instead.
    var correctedValue: String
    /// Verbatim utterance the correction came from — same "always retained" rule as
    /// `ParsedTask.sourceTranscript`.
    var transcript: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        attribute: String,
        parsedValue: String,
        correctedValue: String,
        transcript: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.attribute = attribute
        self.parsedValue = parsedValue
        self.correctedValue = correctedValue
        self.transcript = transcript
        self.createdAt = createdAt
    }
}

/// Append API — mirrors `CompletionLog`'s "caseless enum + `ModelContext`" convention (see
/// `CompletionLog.swift`) so both local logging surfaces share the same call shape. Does not call
/// `context.save()` itself (same convention as `CompletionLog.recordCompletion`) — the caller
/// batches the save with whatever else it's persisting in the same transaction.
enum ParseCorrectionLog {
    @discardableResult
    static func record(
        attribute: String,
        parsed: String,
        corrected: String,
        transcript: String,
        in context: ModelContext
    ) -> ParseCorrection {
        let correction = ParseCorrection(
            attribute: attribute,
            parsedValue: parsed,
            correctedValue: corrected,
            transcript: transcript
        )
        context.insert(correction)
        return correction
    }
}
