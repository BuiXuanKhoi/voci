import Foundation
import Testing
@testable import VolarCore

/// User Story 4 (reject `.taskDone` cycles): §6.2 #5, a longer chain variant, self-reference, a
/// valid non-closing edge, and proof that `.afterDate`/`.external` never participate in cycle
/// validation.
@Suite("Condition dependency graph cycle detection")
struct DependencyGraphTests {

    /// Runs `body`, returning the thrown `DependencyError` if any, or `nil` if it completed
    /// without throwing. Kept as an explicit do/catch (rather than relying on a specific
    /// `#expect(throws:)` overload) so both "throws this exact error" and "does not throw" are
    /// asserted the same straightforward way.
    private func capturedDependencyError(_ body: () throws -> Void) -> DependencyError? {
        do {
            try body()
            return nil
        } catch let error as DependencyError {
            return error
        } catch {
            Issue.record("Unexpected error type: \(error)")
            return nil
        }
    }

    // §6.2 #5: A already has a `.taskDone(B)` condition; attempting to add `.taskDone(A)` to B is
    // rejected as a direct cycle (A -> B -> A).
    @Test("adding .taskDone(A) to B is rejected when A already has .taskDone(B)")
    func directCycleIsRejected() {
        let taskB = makeTask(id: fixedUUID(2), title: "B")
        let taskA = makeTask(id: fixedUUID(1), title: "A", conditions: [.taskDone(taskB.id)])
        let tasks = [taskA, taskB]

        #expect(wouldCreateCycle(from: taskB.id, dependsOn: taskA.id, in: tasks))

        let error = capturedDependencyError {
            try validateCondition(adding: .taskDone(taskA.id), to: taskB.id, in: tasks)
        }

        #expect(error == .cycle(from: "B", to: "A"))
    }

    // Transitive chain: A -> B -> C (via `.taskDone`); attempting to add `.taskDone(A)` to C is
    // rejected as a cycle (A -> B -> C -> A).
    @Test("transitive chain A->B->C rejects adding .taskDone(A) to C")
    func transitiveChainCycleIsRejected() {
        let taskC = makeTask(id: fixedUUID(3), title: "C")
        let taskB = makeTask(id: fixedUUID(2), title: "B", conditions: [.taskDone(taskC.id)])
        let taskA = makeTask(id: fixedUUID(1), title: "A", conditions: [.taskDone(taskB.id)])
        let tasks = [taskA, taskB, taskC]

        #expect(wouldCreateCycle(from: taskC.id, dependsOn: taskA.id, in: tasks))

        let error = capturedDependencyError {
            try validateCondition(adding: .taskDone(taskA.id), to: taskC.id, in: tasks)
        }

        #expect(error == .cycle(from: "C", to: "A"))
    }

    // Self-reference: a task cannot have a `.taskDone` condition pointing at itself.
    @Test("self-reference is rejected")
    func selfReferenceIsRejected() {
        let taskA = makeTask(id: fixedUUID(1), title: "A")
        let tasks = [taskA]

        #expect(wouldCreateCycle(from: taskA.id, dependsOn: taskA.id, in: tasks))

        let error = capturedDependencyError {
            try validateCondition(adding: .taskDone(taskA.id), to: taskA.id, in: tasks)
        }

        #expect(error == .selfDependency(title: "A"))
    }

    // A valid new `.taskDone` condition that does not close a loop is accepted (no throw).
    @Test("valid non-closing .taskDone edge is accepted")
    func validNonClosingEdgeIsAccepted() {
        let taskA = makeTask(id: fixedUUID(1), title: "A")
        let taskB = makeTask(id: fixedUUID(2), title: "B")
        let tasks = [taskA, taskB]

        #expect(!wouldCreateCycle(from: taskA.id, dependsOn: taskB.id, in: tasks))

        let error = capturedDependencyError {
            try validateCondition(adding: .taskDone(taskB.id), to: taskA.id, in: tasks)
        }

        #expect(error == nil)
    }

    // `.afterDate` and `.external` never carry a graph edge, so they can never throw — even when
    // the snapshot already contains an unrelated `.taskDone` cycle, and even for a "self"-shaped
    // payload that would be rejected if it were `.taskDone`.
    @Test(".afterDate never throws from validateCondition")
    func afterDateNeverThrows() {
        let taskA = makeTask(id: fixedUUID(1), title: "A", conditions: [.taskDone(fixedUUID(2))])
        let taskB = makeTask(id: fixedUUID(2), title: "B", conditions: [.taskDone(fixedUUID(1))])
        let tasks = [taskA, taskB]

        let error = capturedDependencyError {
            try validateCondition(adding: .afterDate(referenceNow), to: taskA.id, in: tasks)
        }

        #expect(error == nil)
    }

    @Test(".external never throws from validateCondition")
    func externalNeverThrows() {
        let taskA = makeTask(id: fixedUUID(1), title: "A", conditions: [.taskDone(fixedUUID(2))])
        let taskB = makeTask(id: fixedUUID(2), title: "B", conditions: [.taskDone(fixedUUID(1))])
        let tasks = [taskA, taskB]

        let error = capturedDependencyError {
            try validateCondition(
                adding: .external(description: "waiting", satisfied: false),
                to: taskA.id,
                in: tasks
            )
        }

        #expect(error == nil)
    }

    // MARK: - cyclePath

    // Mirrors `directCycleIsRejected`, but asserts the actual path shape rather than just the
    // boolean: A already has `.taskDone(B)` (edge A -> B); adding `.taskDone(A)` to B proposes the
    // edge B -> A. The closed path starts and ends at the proposed edge's `source` (B): B -> A
    // (new edge) -> B (existing edge).
    @Test("cyclePath returns the closed path for a direct two-task cycle")
    func cyclePathDirectCycle() {
        let taskB = makeTask(id: fixedUUID(2), title: "B")
        let taskA = makeTask(id: fixedUUID(1), title: "A", conditions: [.taskDone(taskB.id)])
        let tasks = [taskA, taskB]

        let path = cyclePath(from: taskB.id, dependsOn: taskA.id, in: tasks)

        #expect(path == [taskB.id, taskA.id, taskB.id])
    }

    // Transitive chain A -> B -> C (existing `.taskDone` edges); proposing `.taskDone(A)` on C
    // (edge C -> A) closes the loop. The returned path starts and ends at C (the proposed edge's
    // source), then follows the existing edges C used to reach it back: C -> A -> B -> C.
    @Test("cyclePath returns the closed path for a transitive three-task cycle")
    func cyclePathTransitiveCycle() {
        let taskC = makeTask(id: fixedUUID(3), title: "C")
        let taskB = makeTask(id: fixedUUID(2), title: "B", conditions: [.taskDone(taskC.id)])
        let taskA = makeTask(id: fixedUUID(1), title: "A", conditions: [.taskDone(taskB.id)])
        let tasks = [taskA, taskB, taskC]

        let path = cyclePath(from: taskC.id, dependsOn: taskA.id, in: tasks)

        #expect(path == [taskC.id, taskA.id, taskB.id, taskC.id])
    }

    // Self-edge is a trivial one-node cycle per the contract, regardless of `snapshot` contents —
    // it never even needs to look at `snapshot`.
    @Test("cyclePath returns [source, source] for a self-edge")
    func cyclePathSelfEdge() {
        let taskA = makeTask(id: fixedUUID(1), title: "A")

        let path = cyclePath(from: taskA.id, dependsOn: taskA.id, in: [taskA])

        #expect(path == [taskA.id, taskA.id])
    }

    // A brand-new, non-closing edge between two unrelated tasks: no existing path from `target`
    // back to `source`, so there is nothing to close.
    @Test("cyclePath returns nil when the proposed edge would not close a cycle")
    func cyclePathNoCycle() {
        let taskA = makeTask(id: fixedUUID(1), title: "A")
        let taskB = makeTask(id: fixedUUID(2), title: "B")
        let tasks = [taskA, taskB]

        let path = cyclePath(from: taskA.id, dependsOn: taskB.id, in: tasks)

        #expect(path == nil)
    }

    // MARK: - findCycle

    // A small acyclic chain (B depends on A) has no cycle anywhere in it.
    @Test("findCycle returns nil for an acyclic graph")
    func findCycleAcyclicGraph() {
        let taskA = makeTask(id: fixedUUID(1), title: "A")
        let taskB = makeTask(id: fixedUUID(2), title: "B", conditions: [.taskDone(taskA.id)])
        let tasks = [taskA, taskB]

        #expect(findCycle(in: tasks) == nil)
    }

    // A -> B -> C -> A already exists in the snapshot (no proposed edge involved — this is a
    // graph that somehow got persisted cyclic already, which `findCycle` must still be able to
    // report on). Traversal starts at the first snapshot entry (A) and follows edges in
    // `conditions` order, so the deterministic result closes back at A.
    @Test("findCycle finds an existing three-task cycle")
    func findCycleExistingCycle() {
        let taskA = makeTask(id: fixedUUID(1), title: "A", conditions: [.taskDone(fixedUUID(2))])
        let taskB = makeTask(id: fixedUUID(2), title: "B", conditions: [.taskDone(fixedUUID(3))])
        let taskC = makeTask(id: fixedUUID(3), title: "C", conditions: [.taskDone(fixedUUID(1))])
        let tasks = [taskA, taskB, taskC]

        #expect(findCycle(in: tasks) == [taskA.id, taskB.id, taskC.id, taskA.id])
    }

    // Two disconnected components: D -> E is a clean acyclic chain, A <-> B is a genuine two-task
    // cycle. `findCycle` must fully explore the clean component (finding nothing) and then still
    // find the cycle in the second one, proving components don't interfere with each other.
    @Test("findCycle finds a cycle in one of several connected components")
    func findCycleMultipleComponents() {
        let taskE = makeTask(id: fixedUUID(5), title: "E")
        let taskD = makeTask(id: fixedUUID(4), title: "D", conditions: [.taskDone(taskE.id)])
        let taskA = makeTask(id: fixedUUID(1), title: "A", conditions: [.taskDone(fixedUUID(2))])
        let taskB = makeTask(id: fixedUUID(2), title: "B", conditions: [.taskDone(fixedUUID(1))])
        let tasks = [taskD, taskE, taskA, taskB]

        #expect(findCycle(in: tasks) == [taskA.id, taskB.id, taskA.id])
    }

    // A task with a `.taskDone` condition pointing at itself — data that `validateCondition`
    // would never let in through the front door, but `findCycle` still has to handle it safely
    // (contract §5: adversarial/already-cyclic data must not hang or crash) and report it as the
    // trivial cycle it is.
    @Test("findCycle finds a self-loop")
    func findCycleSelfLoop() {
        let taskA = makeTask(id: fixedUUID(1), title: "A", conditions: [.taskDone(fixedUUID(1))])

        #expect(findCycle(in: [taskA]) == [taskA.id, taskA.id])
    }
}
