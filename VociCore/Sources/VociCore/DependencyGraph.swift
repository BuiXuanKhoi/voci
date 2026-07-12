import Foundation

/// Errors thrown by `validateDependency(from:dependsOn:in:)` when a proposed `dependsOn` edge
/// would violate the dependency graph's DAG invariant.
///
/// Both payloads carry human-readable titles (rather than raw ids) so the app can render a
/// message such as *"'A' đang chờ 'B' — không thể để 'B' chờ ngược lại 'A'."* directly from the
/// error (Constitution Principle II: never silently guess or drop — always explain).
public enum DependencyError: Error, Equatable {
    /// Adding "`from` dependsOn `to`" would close a cycle in the existing graph.
    case cycle(from: String, to: String)
    /// A task cannot depend on itself.
    case selfDependency(title: String)
}

/// Validates a proposed dependency edge "`source` dependsOn `target`" against the existing
/// snapshot's `dependsOn` edges, throwing when adding it would violate the DAG invariant
/// (Constitution Principle III; spec FR-011/FR-012).
///
/// - A self-edge (`source == target`) always throws `.selfDependency`.
/// - Otherwise, if `target` can already reach `source` by following existing `dependsOn` edges,
///   adding "`source` dependsOn `target`" would close a cycle (`source` -> `target` -> ... ->
///   `source`), and this throws `.cycle(from:to:)`.
/// - Returns normally (no throw) when the edge is safe to persist.
///
/// This function is pure: it neither mutates `tasks` nor reads the clock or any external state.
/// The caller (app layer) is responsible for actually persisting the edge only when this does
/// not throw; cycle detection is intentionally performed at edge-creation time so the
/// `nextTask(from:now:calendar:)` hot path may assume the graph is already acyclic.
public func validateDependency(
    from source: UUID,
    dependsOn target: UUID,
    in tasks: [Task]
) throws {
    if source == target {
        throw DependencyError.selfDependency(title: title(for: source, in: tasks))
    }
    if wouldCreateCycle(from: source, dependsOn: target, in: tasks) {
        throw DependencyError.cycle(
            from: title(for: source, in: tasks),
            to: title(for: target, in: tasks)
        )
    }
}

/// Non-throwing predicate: would adding "`source` dependsOn `target`" close a cycle in the
/// existing `dependsOn` graph described by `tasks`?
///
/// A self-edge (`source == target`) is treated as a trivial cycle and returns `true`. Otherwise
/// this performs a depth-first search starting from `target`, following existing `dependsOn`
/// edges outward; if `source` is reachable from `target`, the new edge would close a loop.
///
/// Pure: neither mutates `tasks` nor reads the clock or any external state. O(V+E) over the
/// existing graph.
public func wouldCreateCycle(
    from source: UUID,
    dependsOn target: UUID,
    in tasks: [Task]
) -> Bool {
    if source == target {
        return true
    }

    var dependsOnByID: [UUID: [UUID]] = [:]
    dependsOnByID.reserveCapacity(tasks.count)
    for task in tasks {
        dependsOnByID[task.id] = task.dependsOn
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
        if let neighbors = dependsOnByID[current] {
            stack.append(contentsOf: neighbors)
        }
    }
    return false
}

/// Looks up a task's title by id for use in error messages; falls back to the id's string form
/// if the task is not found in the snapshot (should not normally happen for a valid edge, but
/// keeps this helper total).
private func title(for id: UUID, in tasks: [Task]) -> String {
    tasks.first(where: { $0.id == id })?.title ?? id.uuidString
}
