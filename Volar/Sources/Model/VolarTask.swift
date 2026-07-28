// Sources/Model/VolarTask.swift — SwiftData-persisted task (v2 shape), mapped to/from TaskItem.
//
// MIGRATION STRATEGY (data-model.md "Persisted layer" + tasks.md T013): this project has never
// declared a `VersionedSchema`/`SchemaMigrationPlan` — `TaskStore.init()` has always built its
// container from a bare `Schema([VolarTask.self])`. Introducing a versioned schema now, purely to
// carry one field rename (`dependsOn` -> `conditions`), would add SwiftData's most fragile
// surface (custom migration stages, `willMigrate`/`didMigrate` closures, real-world reports of
// silent data loss on stage misconfiguration) for a one-time, easily-reversible transform. Chosen
// instead: DEFENSIVE IN-PLACE — `dependsOn` stays as a deprecated stored attribute (still decodes
// old rows via ordinary SwiftData lightweight migration, which only requires new attributes to
// have defaults — already this file's existing convention, see `details` below), and
// `foldLegacyDependsOn()` copies any non-empty legacy ids into `.taskDone` conditions the first
// time a row is fetched, then clears it. Idempotent (no-op once empty), and safe to run on every
// launch indefinitely (cost is one empty-array check per row when there's nothing to migrate).
// // UNVERIFIED: confirm on Mac that opening an existing (pre-v2) store with this file's new
// optional/defaulted attributes added performs the expected SwiftData lightweight migration
// in-place (no data loss, no crash) rather than requiring a destructive store reset.
import Foundation
import SwiftData
import VolarCore

/// Wire-format mirror of `VolarCore.Condition` for JSON persistence. Hand-rolled (rather than
/// requiring `VolarCore.Condition` to be `Codable`, which the frozen contract does not promise, or
/// relying on `Codable` synthesis for an enum with associated values) so the on-disk shape is
/// explicit and stable. Case names/payloads match `contracts/volarcore-api.md` 1:1 by inspection —
/// keep this in lockstep if the engine's `Condition` cases ever change.
private struct ConditionDTO: Codable {
    private enum Kind: String, Codable { case taskDone, afterDate, external }
    private var kind: Kind
    private var taskId: UUID?
    private var date: Date?
    private var description: String?
    private var satisfied: Bool?

    init(_ condition: VolarCore.Condition) {
        switch condition {
        case .taskDone(let id):
            kind = .taskDone; taskId = id
        case .afterDate(let date):
            kind = .afterDate; self.date = date
        case .external(let description, let satisfied):
            kind = .external; self.description = description; self.satisfied = satisfied
        }
    }

    /// Decodes back to the engine type; a structurally-invalid element (e.g. `.taskDone` missing
    /// its id) decodes to `nil` rather than throwing, so one bad element can be dropped instead of
    /// invalidating the whole `conditions` array (see `VolarTask.conditions` getter below).
    var asCondition: VolarCore.Condition? {
        switch kind {
        case .taskDone: return taskId.map { .taskDone($0) }
        case .afterDate: return date.map { .afterDate($0) }
        case .external:
            guard let description, let satisfied else { return nil }
            return .external(description: description, satisfied: satisfied)
        }
    }
}

/// The SwiftData-persisted counterpart of `TaskItem`. Status and the `when` bucket are stored as
/// plain `String` raw values (rather than the enums directly) so the model doesn't depend on
/// `VolarCore.TaskStatus` being `Codable`/`PersistentModel`-storable — this keeps the persistence
/// layer decoupled from the engine's value type shape. `conditions`/`recurrence`/
/// `reminderOverride`/`delegation` follow the same decoupling principle one level further: each is
/// stored as a JSON-encoded `Data` blob behind a computed accessor, so a malformed/foreign blob
/// (hostile store edit, partial write, cross-version skew) fails CLOSED to an empty/`nil` value
/// instead of throwing or crashing the app on load (constitution-adjacent trust-boundary note —
/// see `TaskStore`'s doc comments for the write-side half of this boundary).
@Model
final class VolarTask {
    @Attribute(.unique) var id: UUID
    var title: String
    /// SwiftData needs a default for lightweight migration of existing stores created before
    /// this field existed.
    var details: String = ""
    var priorityRaw: Int
    var statusRaw: String
    var deadline: Date?
    /// Mirrors `TaskItem.startTime` (see that file for full semantics: when the user said they'd
    /// start an urgent task — does NOT drive ordering/eligibility/reminders). No explicit `= nil`
    /// default, matching this file's existing convention for every other `Optional`-typed stored
    /// attribute (`deadline`/`durationMinutes`/`notes`/`parentId`/... above and below) — SwiftData
    /// lightweight migration only requires an explicit default for NON-optional attributes;
    /// `Optional` already defaults to `nil` for a row written before this column existed.
    var startTime: Date?
    /// DEPRECATED — superseded by `conditions`. Kept only so pre-v2 rows still decode; folded and
    /// cleared by `foldLegacyDependsOn()` on first load (see migration note at the top of this
    /// file). Never written to by any v2 code path.
    var dependsOn: [UUID] = []
    var createdAt: Date
    var whenRaw: String
    var durationMinutes: Int?
    var frog: Bool

    // MARK: - v2 stored attributes (all optional or explicitly defaulted for lightweight
    // migration of rows written before this field existed).

    var notes: String?
    var sourceTranscript: String?
    var kindRaw: String = "task"
    var resumeNote: String?
    var switchAwayCount: Int = 0
    var completedAt: Date?
    var parentId: UUID?
    /// Phase 4 (T072-support, `contracts/phase4-contract.md` §E + §B): when `true`, the spoken
    /// reminder channel (`VoiceReminderChannel.speakReminder`, sibling-owned §B) MUST speak a
    /// generic phrase ("You have a reminder") instead of this task's title — never announce a
    /// sensitive task's content out loud. Migration-safe default `false` (lightweight SwiftData
    /// migration of existing rows, same convention as `kindRaw`/`switchAwayCount` above).
    ///
    /// SEAM NOTE (self-review "conflict", flagged in this task's final report): this field exists
    /// ONLY here on the persisted model, deliberately NOT threaded through `TaskItem`/`TaskStore`/
    /// any task-editing UI — none of those files are among this task's 5 owned files
    /// (`TaskItem.swift` in particular is out of scope), and the contract explicitly calls the UI
    /// toggle "optional/nice-to-have." Every task currently defaults to `false` (never sensitive)
    /// until a future change wires a real read/write path from the UI down to this attribute. The
    /// Reminders agent's fire-time fresh reload (constitution IV already requires re-reading the
    /// task from storage at fire time) is expected to read this attribute directly off `VolarTask`
    /// rather than via `TaskItem`, which doesn't carry it.
    var isSensitive: Bool = false
    // Literal (not `Self.emptyJSONArray`) so the `@Model` macro sees a plain, unambiguous default
    // expression for schema/lightweight-migration inference rather than a cross-property
    // reference. // UNVERIFIED: confirm this attribute default is honored for existing rows on
    // first launch after upgrade (SwiftData lightweight migration of a new non-optional `Data`
    // attribute) on Mac.
    private var conditionsData: Data = Data("[]".utf8)
    private var recurrenceData: Data?
    private var reminderOverrideData: Data?
    private var delegationData: Data?

    init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        priority: Priority,
        status: TaskStatus = .todo,
        deadline: Date? = nil,
        startTime: Date? = nil,
        createdAt: Date = Date(),
        when: When,
        durationMinutes: Int? = nil,
        frog: Bool = false
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.priorityRaw = priority.rawValue
        self.statusRaw = Self.rawValue(for: status)
        self.deadline = deadline
        self.startTime = startTime
        self.createdAt = createdAt
        self.whenRaw = Self.rawValue(for: when)
        self.durationMinutes = durationMinutes
        self.frog = frog
    }

    // MARK: - v2 computed accessors (JSON blob <-> value type, failure-tolerant both ways)

    var status: TaskStatus {
        get { Self.status(from: statusRaw) }
        set { statusRaw = Self.rawValue(for: newValue) }
    }

    var conditions: [VolarCore.Condition] {
        get {
            // Decode element-by-element (rather than `[ConditionDTO].self` in one shot) so a
            // single structurally-invalid or unrecognized-`kind` element (e.g. a future condition
            // kind this build doesn't know about) is skipped instead of throwing and wiping the
            // ENTIRE array — mirrors `ConditionDTO.asCondition`'s existing per-element tolerance.
            // A fully corrupt/non-array blob still fails closed to `[]`.
            guard let rawElements = try? JSONSerialization.jsonObject(with: conditionsData) as? [Any] else {
                return []
            }
            return rawElements.compactMap { element -> VolarCore.Condition? in
                guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
                guard let dto = try? JSONDecoder().decode(ConditionDTO.self, from: elementData) else { return nil }
                return dto.asCondition
            }
        }
        set {
            let dtos = newValue.map(ConditionDTO.init)
            conditionsData = (try? JSONEncoder().encode(dtos)) ?? VolarTask.emptyJSONArray
        }
    }

    var kind: TaskKind {
        get { TaskKind(rawValue: kindRaw) ?? .task }
        set { kindRaw = newValue.rawValue }
    }

    var recurrence: Recurrence? {
        get { recurrenceData.flatMap { try? JSONDecoder().decode(Recurrence.self, from: $0) } }
        set { recurrenceData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var reminderOverride: ReminderPolicy? {
        get { reminderOverrideData.flatMap { try? JSONDecoder().decode(ReminderPolicy.self, from: $0) } }
        set { reminderOverrideData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var delegation: DelegationMeta? {
        get { delegationData.flatMap { try? JSONDecoder().decode(DelegationMeta.self, from: $0) } }
        set { delegationData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    // MARK: - Migration (see file header)

    /// Folds any legacy `dependsOn` ids into `.taskDone` conditions and clears `dependsOn`.
    /// Returns whether it changed anything, so `TaskStore.fetchAll()` only pays for a `save()`
    /// when at least one row actually needed it. Safe to call unconditionally on every load
    /// (idempotent; O(1) when `dependsOn` is already empty, which is every row after the first
    /// migrated fetch). De-dupes against ids already present as `.taskDone` conditions so a
    /// second migration pass (e.g. an interrupted first save) can never double-add an edge.
    ///
    /// Correctness note: this does NOT re-run cycle detection. The legacy `dependsOn` graph was
    /// already validated acyclic under v1's `validateDependency` at write time; folding each edge
    /// 1:1 into `.taskDone` preserves the same edge set, so the v2 DAG invariant carries over
    /// without needing a full-snapshot `validateCondition` pass here (and this method has no
    /// access to the full snapshot anyway — it operates on one row).
    @discardableResult
    func foldLegacyDependsOn() -> Bool {
        guard !dependsOn.isEmpty else { return false }
        var current = conditions
        let existing: Set<UUID> = Set(current.compactMap {
            if case .taskDone(let id) = $0 { return id }
            return nil
        })
        for legacyID in dependsOn where !existing.contains(legacyID) {
            current.append(.taskDone(legacyID))
        }
        conditions = current
        dependsOn = []
        return true
    }

    // MARK: - TaskItem <-> VolarTask

    var asTaskItem: TaskItem {
        TaskItem(
            id: id,
            title: title,
            details: details,
            priority: Priority(rawValue: priorityRaw) ?? .medium,
            status: status,
            deadline: deadline,
            startTime: startTime,
            conditions: conditions,
            createdAt: createdAt,
            when: Self.when(from: whenRaw),
            durationMinutes: durationMinutes,
            frog: frog,
            notes: notes,
            sourceTranscript: sourceTranscript,
            kind: kind,
            recurrence: recurrence,
            reminderOverride: reminderOverride,
            resumeNote: resumeNote,
            switchAwayCount: switchAwayCount,
            completedAt: completedAt,
            parentId: parentId,
            delegation: delegation
        )
    }

    /// General-purpose full sync from an edited `TaskItem` back onto this model. Not on the v2
    /// completion path (`TaskStore.toggle` mutates fields directly so it can enforce recurrence
    /// reset / cascade precisely) — kept as the one obvious place a future "edit task" API writes
    /// through, mirroring `asTaskItem`'s field-for-field symmetry.
    func apply(_ item: TaskItem) {
        title = item.title
        details = item.details
        priorityRaw = item.priority.rawValue
        status = item.status
        deadline = item.deadline
        startTime = item.startTime
        conditions = item.conditions
        createdAt = item.createdAt
        whenRaw = Self.rawValue(for: item.when)
        durationMinutes = item.durationMinutes
        frog = item.frog
        notes = item.notes
        sourceTranscript = item.sourceTranscript
        kind = item.kind
        recurrence = item.recurrence
        reminderOverride = item.reminderOverride
        resumeNote = item.resumeNote
        switchAwayCount = item.switchAwayCount
        completedAt = item.completedAt
        parentId = item.parentId
        delegation = item.delegation
    }

    private static let emptyJSONArray = Data("[]".utf8)

    private static func rawValue(for status: TaskStatus) -> String {
        switch status {
        case .todo: return "todo"
        case .inProgress: return "inProgress"
        case .done: return "done"
        case .archived: return "archived"
        }
    }

    private static func status(from raw: String) -> TaskStatus {
        switch raw {
        case "inProgress": return .inProgress
        case "done": return .done
        case "archived": return .archived
        default: return .todo
        }
    }

    private static func rawValue(for when: When) -> String {
        when == .now ? "now" : "later"
    }

    private static func when(from raw: String) -> When {
        raw == "now" ? .now : .later
    }
}
