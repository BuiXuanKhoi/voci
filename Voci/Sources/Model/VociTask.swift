// Sources/Model/VociTask.swift — SwiftData-persisted task, mapped to/from TaskItem
import Foundation
import SwiftData
import VociCore

/// The SwiftData-persisted counterpart of `TaskItem`. Status and the `when` bucket are stored as
/// plain `String` raw values (rather than the enums directly) so the model doesn't depend on
/// `VociCore.TaskStatus` being `Codable`/`PersistentModel`-storable — this keeps the persistence
/// layer decoupled from the engine's value type shape.
@Model
final class VociTask {
    @Attribute(.unique) var id: UUID
    var title: String
    /// SwiftData needs a default for lightweight migration of existing stores created before
    /// this field existed.
    var details: String = ""
    var priorityRaw: Int
    var statusRaw: String
    var deadline: Date?
    var dependsOn: [UUID]
    var createdAt: Date
    var whenRaw: String
    var durationMinutes: Int?
    var frog: Bool

    init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        priority: Priority,
        status: TaskStatus = .todo,
        deadline: Date? = nil,
        dependsOn: [UUID] = [],
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
        self.dependsOn = dependsOn
        self.createdAt = createdAt
        self.whenRaw = Self.rawValue(for: when)
        self.durationMinutes = durationMinutes
        self.frog = frog
    }

    var asTaskItem: TaskItem {
        TaskItem(
            id: id,
            title: title,
            details: details,
            priority: Priority(rawValue: priorityRaw) ?? .medium,
            status: Self.status(from: statusRaw),
            deadline: deadline,
            dependsOn: dependsOn,
            createdAt: createdAt,
            when: Self.when(from: whenRaw),
            durationMinutes: durationMinutes,
            frog: frog
        )
    }

    func apply(_ item: TaskItem) {
        title = item.title
        details = item.details
        priorityRaw = item.priority.rawValue
        statusRaw = Self.rawValue(for: item.status)
        deadline = item.deadline
        dependsOn = item.dependsOn
        createdAt = item.createdAt
        whenRaw = Self.rawValue(for: item.when)
        durationMinutes = item.durationMinutes
        frog = item.frog
    }

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
