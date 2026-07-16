import Foundation

/// Errors thrown by `validateCondition(adding:to:in:)` when a proposed `.taskDone` condition
/// would violate the `.taskDone` dependency graph's DAG invariant.
///
/// Both payloads carry human-readable titles (rather than raw ids) so the app can render a
/// message such as *"'A' đang chờ 'B' — không thể để 'B' chờ ngược lại 'A'."* directly from the
/// error (Constitution Principle II: never silently guess or drop — always explain).
public enum DependencyError: Error, Equatable {
    /// Adding "`from` depends on (via `.taskDone`) `to`" would close a cycle in the existing
    /// graph.
    case cycle(from: String, to: String)
    /// A task cannot depend on itself.
    case selfDependency(title: String)
}

/// Validates adding `condition` to task `id` within `snapshot`, throwing when it would violate
/// the `.taskDone` graph's DAG invariant (Constitution Principle III; spec FR-011/FR-012).
///
/// Only `.taskDone` payloads participate in the dependency graph:
/// - A `.taskDone` self-reference (`id == target`) always throws `.selfDependency`.
/// - A `.taskDone` edge that would close a cycle (the target can already reach `id` by following
///   existing `.taskDone` edges) throws `.cycle(from:to:)`.
/// - `.afterDate` and `.external` conditions never throw — they carry no graph edge.
///
/// This function is pure: it neither mutates `snapshot` nor reads the clock or any external
/// state, and never persists anything itself. Cycle detection is intentionally performed at
/// condition-creation time so the `nextTask(from:now:calendar:)` hot path may assume the `.taskDone` graph
/// is already acyclic.
public func validateCondition(
    adding condition: Condition,
    to id: UUID,
    in snapshot: [Task]
) throws {
    guard case .taskDone(let target) = condition else {
        return
    }
    if id == target {
        throw DependencyError.selfDependency(title: title(for: id, in: snapshot))
    }
    if wouldCreateCycle(from: id, dependsOn: target, in: snapshot) {
        throw DependencyError.cycle(
            from: title(for: id, in: snapshot),
            to: title(for: target, in: snapshot)
        )
    }
}

/// Non-throwing predicate: would adding a `.taskDone(target)` condition to task `source` close a
/// cycle in the existing `.taskDone` graph described by `snapshot`?
///
/// A self-edge (`source == target`) is treated as a trivial cycle and returns `true`. Otherwise
/// this performs a depth-first search starting from `target`, following existing `.taskDone`
/// edges outward; if `source` is reachable from `target`, the new edge would close a loop.
///
/// Pure: neither mutates `snapshot` nor reads the clock or any external state. O(V+E) over the
/// existing `.taskDone` graph. The `visited` set bounds the traversal even over adversarial
/// (already-cyclic) input data, so this never hangs.
public func wouldCreateCycle(
    from source: UUID,
    dependsOn target: UUID,
    in snapshot: [Task]
) -> Bool {
    if source == target {
        return true
    }

    var taskDoneEdgesByID: [UUID: [UUID]] = [:]
    taskDoneEdgesByID.reserveCapacity(snapshot.count)
    for task in snapshot {
        taskDoneEdgesByID[task.id] = task.conditions.compactMap { condition in
            guard case .taskDone(let dependencyID) = condition else { return nil }
            return dependencyID
        }
    }

    var visited: Set<UUID> = []
    var stack: [UUID] = [target]
    while let current = stack.popLast() {
        if current == source {
            return true
        }
        guard visited.insert(current).inserted else {
            continue
        }
        if let neighbors = taskDoneEdgesByID[current] {
            stack.append(contentsOf: neighbors)
        }
    }
    return false
}

/// Looks up a task's title by id for use in error messages; falls back to the id's string form
/// if the task is not found in the snapshot (should not normally happen for a valid edge, but
/// keeps this helper total).
private func title(for id: UUID, in snapshot: [Task]) -> String {
    snapshot.first(where: { $0.id == id })?.title ?? id.uuidString
}
