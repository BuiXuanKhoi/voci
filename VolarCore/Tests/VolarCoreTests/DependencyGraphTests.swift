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
}
