import Foundation
import Testing
@testable import VociCore

/// User Story 4 (reject dependency cycles): §6.2 #5, a longer chain variant, self-dependency,
/// and a valid non-closing edge.
@Suite("Dependency graph cycle detection")
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

    // §6.2 #5: A already depends on B; attempting to make B depend on A is rejected as a cycle.
    @Test("B depending on A is rejected when A already depends on B")
    func directCycleIsRejected() {
        let taskB = makeTask(id: fixedUUID(2), title: "B")
        let taskA = makeTask(id: fixedUUID(1), title: "A", dependsOn: [taskB.id])
        let tasks = [taskA, taskB]

        #expect(wouldCreateCycle(from: taskB.id, dependsOn: taskA.id, in: tasks))

        let error = capturedDependencyError {
            try validateDependency(from: taskB.id, dependsOn: taskA.id, in: tasks)
        }

        #expect(error == .cycle(from: "B", to: "A"))
    }

    // Longer chain: A -> B -> C; attempting to make C depend on A is rejected as a cycle.
    @Test("longer chain A->B->C rejects C depending on A")
    func longerChainCycleIsRejected() {
        let taskC = makeTask(id: fixedUUID(3), title: "C")
        let taskB = makeTask(id: fixedUUID(2), title: "B", dependsOn: [taskC.id])
        let taskA = makeTask(id: fixedUUID(1), title: "A", dependsOn: [taskB.id])
        let tasks = [taskA, taskB, taskC]

        #expect(wouldCreateCycle(from: taskC.id, dependsOn: taskA.id, in: tasks))

        let error = capturedDependencyError {
            try validateDependency(from: taskC.id, dependsOn: taskA.id, in: tasks)
        }

        #expect(error == .cycle(from: "C", to: "A"))
    }

    // A task cannot depend on itself.
    @Test("self-dependency is rejected")
    func selfDependencyIsRejected() {
        let taskA = makeTask(id: fixedUUID(1), title: "A")
        let tasks = [taskA]

        #expect(wouldCreateCycle(from: taskA.id, dependsOn: taskA.id, in: tasks))

        let error = capturedDependencyError {
            try validateDependency(from: taskA.id, dependsOn: taskA.id, in: tasks)
        }

        #expect(error == .selfDependency(title: "A"))
    }

    // A valid new dependency that does not close a loop is accepted (no throw).
    @Test("valid non-closing edge is accepted")
    func validNonClosingEdgeIsAccepted() {
        let taskA = makeTask(id: fixedUUID(1), title: "A")
        let taskB = makeTask(id: fixedUUID(2), title: "B")
        let tasks = [taskA, taskB]

        #expect(!wouldCreateCycle(from: taskA.id, dependsOn: taskB.id, in: tasks))

        let error = capturedDependencyError {
            try validateDependency(from: taskA.id, dependsOn: taskB.id, in: tasks)
        }

        #expect(error == nil)
    }
}
