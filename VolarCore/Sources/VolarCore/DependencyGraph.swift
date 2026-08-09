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
/// Implemented directly in terms of `cyclePath` so there is exactly one place the "does this edge
/// close a loop" logic lives — this is a thin boolean view over it, kept as its own public
/// function only because it already has call sites and tests that only need the bool, not the
/// path (feature 002's cycle-detection-contract.md §1.1 froze this signature).
///
/// Pure: neither mutates `snapshot` nor reads the clock or any external state. O(V+E) over the
/// existing `.taskDone` graph. Bounded traversal even over adversarial (already-cyclic) input
/// data, so this never hangs.
public func wouldCreateCycle(
    from source: UUID,
    dependsOn target: UUID,
    in snapshot: [Task]
) -> Bool {
    cyclePath(from: source, dependsOn: target, in: snapshot) != nil
}

/// The closed path a new `.taskDone(target)` condition on `source` would create, or `nil` if it
/// would not close a cycle.
///
/// The returned path always starts and ends at `source` — e.g. `[source, target, X, source]`
/// reads as "source would wait on target, target already (transitively) waits on X, and X already
/// waits on source." A self-edge (`source == target`) is a trivial one-node cycle and returns
/// `[source, source]` without touching `snapshot` at all.
///
/// Otherwise this looks for *some* existing `.taskDone` path from `target` back to `source` —
/// that path, plus the proposed `source -> target` edge prepended, is the cycle the new edge
/// would close. The search is iterative DFS over an explicit stack (no recursion, so adversarial
/// or already-cyclic `snapshot` data can't blow the call stack), and deterministic: at each node
/// it tries outgoing edges in `conditions` order, so the same input always yields the same path
/// even when more than one existing path from `target` to `source` exists.
public func cyclePath(from source: UUID, dependsOn target: UUID, in snapshot: [Task]) -> [UUID]? {
    if source == target {
        return [source, source]
    }
    let edges = taskDoneEdges(in: snapshot)
    guard let pathFromTargetToSource = pathIterativeDFS(from: target, to: source, edges: edges) else {
        return nil
    }
    return [source] + pathFromTargetToSource
}

/// Finds one cycle already present in the `.taskDone` graph described by `snapshot`, or `nil` if
/// the graph is acyclic.
///
/// Deterministic: components are visited in `snapshot` order (so the first unvisited task starts
/// the first DFS), and within a node, outgoing `.taskDone` edges are tried in `conditions` order —
/// so the same `snapshot` always reports the same cycle, even when several exist or the graph has
/// several connected components.
///
/// Implemented as an iterative three-color (white/gray/black) DFS: "gray" means the node is an
/// ancestor still on the current search path, "black" means its whole subtree is already fully
/// explored. A cycle is found the moment an edge points at a gray node — that node is the closing
/// point, so the cycle is the slice of the current path from it to here, plus itself again to
/// close it. Uses an explicit stack rather than recursion, and every node is colored at most once
/// before becoming black, so this is O(V+E) and cannot hang or overflow the stack even on data
/// that is already cyclic or adversarially malformed (e.g. a self-loop, or edges pointing at ids
/// absent from `snapshot`, which are simply treated as leaves).
public func findCycle(in snapshot: [Task]) -> [UUID]? {
    let edges = taskDoneEdges(in: snapshot)

    // `nil` in this map means "white" (unvisited) — including for ids that show up only as the
    // target of a `.taskDone` edge but have no `Task` of their own in `snapshot` (a dangling
    // reference to a deleted/absent task). Those still get visited and marked black like any
    // other node, they just have no outgoing edges (`edges[id] ?? []` is empty), so they can
    // never themselves close a cycle.
    enum TraversalColor {
        case gray
        case black
    }
    var color: [UUID: TraversalColor] = [:]
    color.reserveCapacity(snapshot.count)

    for startTask in snapshot {
        let start = startTask.id
        guard color[start] == nil else {
            continue
        }

        var pathStack: [UUID] = [start]
        var nextEdgeIndex: [Int] = [0]
        color[start] = .gray

        while let current = pathStack.last {
            let neighbors = edges[current] ?? []
            let idx = nextEdgeIndex[nextEdgeIndex.count - 1]

            guard idx < neighbors.count else {
                // Fully explored `current`'s subtree with no cycle found through it.
                color[current] = .black
                pathStack.removeLast()
                nextEdgeIndex.removeLast()
                continue
            }

            nextEdgeIndex[nextEdgeIndex.count - 1] += 1
            let next = neighbors[idx]

            switch color[next] {
            case .gray:
                // `next` is an ancestor still on the current path — the edge current -> next
                // closes a loop. The cycle is everything on the path from `next` down to
                // `current`, plus `next` again to show it closing.
                guard let ancestorIndex = pathStack.firstIndex(of: next) else {
                    // Unreachable: `.gray` is only ever set for nodes currently on `pathStack`.
                    continue
                }
                var cycle = Array(pathStack[ancestorIndex...])
                cycle.append(next)
                return cycle
            case .black:
                // Already fully explored elsewhere with no cycle found — skip.
                break
            case nil:
                color[next] = .gray
                pathStack.append(next)
                nextEdgeIndex.append(0)
            }
        }
    }
    return nil
}

/// Builds an adjacency map of `.taskDone` edges: `task.id -> [ids its conditions point at, in
/// conditions order]`. Shared by `cyclePath`/`findCycle`/`wouldCreateCycle` so there is exactly
/// one place that decides "what counts as a graph edge" — only `.taskDone`; `.afterDate` and
/// `.external` never contribute one.
private func taskDoneEdges(in snapshot: [Task]) -> [UUID: [UUID]] {
    var edges: [UUID: [UUID]] = [:]
    edges.reserveCapacity(snapshot.count)
    for task in snapshot {
        edges[task.id] = task.conditions.compactMap { condition in
            guard case .taskDone(let dependencyID) = condition else { return nil }
            return dependencyID
        }
    }
    return edges
}

/// Finds *some* path from `start` to `goal` following `edges`, or `nil` if `goal` isn't
/// reachable. Iterative DFS over an explicit stack (no recursion) with a `visited` set, so this
/// terminates and cannot overflow the call stack even if `edges` already contains cycles of its
/// own. Deterministic: at each node, outgoing edges are tried in the order `edges` lists them
/// (which callers build in `conditions` order), so repeated calls on the same input always return
/// the same path even when more than one exists.
private func pathIterativeDFS(from start: UUID, to goal: UUID, edges: [UUID: [UUID]]) -> [UUID]? {
    if start == goal {
        return [start]
    }

    var visited: Set<UUID> = [start]
    var pathStack: [UUID] = [start]
    var nextEdgeIndex: [Int] = [0]

    while let current = pathStack.last {
        let neighbors = edges[current] ?? []
        let idx = nextEdgeIndex[nextEdgeIndex.count - 1]

        guard idx < neighbors.count else {
            pathStack.removeLast()
            nextEdgeIndex.removeLast()
            continue
        }

        nextEdgeIndex[nextEdgeIndex.count - 1] += 1
        let next = neighbors[idx]

        if next == goal {
            pathStack.append(next)
            return pathStack
        }
        if visited.insert(next).inserted {
            pathStack.append(next)
            nextEdgeIndex.append(0)
        }
    }
    return nil
}

/// Looks up a task's title by id for use in error messages; falls back to the id's string form
/// if the task is not found in the snapshot (should not normally happen for a valid edge, but
/// keeps this helper total).
private func title(for id: UUID, in snapshot: [Task]) -> String {
    snapshot.first(where: { $0.id == id })?.title ?? id.uuidString
}
