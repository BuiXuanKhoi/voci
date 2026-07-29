// Sources/Views/TaskDetailView.swift — task detail sheet: edit-in-place + read-aloud + actions.
// Phase 1 originally shipped this read-only. T-manual-edit (2026-07-29, anh Khôi — see
// specs/002-workflow-command-center/contracts/manual-edit-contract.md §4) turns it into an
// edit-in-place surface for all 7 manually-editable fields (title, description, priority, start
// time, deadline, duration, remind period) instead of adding a separate Edit sheet — the same UI
// decision the contract froze for this file. Every edit commits through `AppState.updateTask`
// (the manual-edit contract's single write path, §1.4, owned by a sibling agent) — this file never
// touches `TaskStore` directly. Reads the live task off `AppState.detailTask` (rather than taking
// one as a param) so toggling done / editing elsewhere is reflected immediately while the sheet is
// open.
import SwiftUI
import VolarCore

struct TaskDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let task = appState.detailTask {
            // `.id(task.id)` gives `TaskDetailEditor` a fresh identity — and therefore freshly
            // re-seeded `@State` edit buffers — whenever the sheet switches to a DIFFERENT task.
            // Re-renders of the SAME task (e.g. `detailTask` recomputing after this view's own
            // commit, or after some unrelated background change) keep the existing identity, so
            // in-progress edits in the buffers are never stomped — see `TaskDetailEditor`'s own
            // header comment for the full argument.
            TaskDetailEditor(task: task, appState: appState)
                .id(task.id)
        } else {
            // Sheet is mid-dismiss (or detailTaskID got cleared out from under us) — nothing to show.
            EmptyView()
        }
    }
}

/// Owns the edit-in-place `@State` buffers for exactly one task's detail sheet. A dedicated `View`
/// struct (not a set of private methods on `TaskDetailView` itself) for the same reason
/// `DeadlineControl`/`NotesEditorControl` in `PopoverView.swift` are: `@State` needs a stable
/// identity to seed once and hold across re-renders, which a `@ViewBuilder` method sharing its
/// parent's identity can't own independently.
///
/// COMMIT MECHANISM (frozen by manual-edit-contract.md §4 — do not replace with a Save button, do
/// not drop a branch):
///   (a) a discrete control (priority/duration/remind-period `Menu`, deadline/start-time
///       `DatePicker`) changes value -> commit immediately;
///   (b) the title or description text field loses focus -> commit;
///   (c) the Close button is tapped -> commit, then `appState.closeDetail()`;
///   (d) `.onDisappear` -> commit (safety net for Esc / click-outside, which never runs (c)).
///
/// Every path funnels through `commitIfChanged()`, which is idempotent BY CONSTRUCTION: it diffs
/// the buffers against `task`'s CURRENT fields (no separate "did I already save this" flag needed)
/// and calls `appState.updateTask` only when something differs. This works because `task` is
/// re-supplied fresh on every re-render (`TaskDetailView.body` reads `appState.detailTask`, which
/// is recomputed from `appState.tasks`) while `@State` buffers persist across re-renders of the
/// SAME identity — so once a successful `updateTask` round-trips back through `tasks` ->
/// `detailTask` -> a fresh `task` parameter here, the buffers and `task` agree again and the next
/// `commitIfChanged()` (e.g. `.onDisappear` firing right after a control already committed) is
/// correctly a no-op instead of a redundant `fetchAll` + reminder-schedule rebuild.
private struct TaskDetailEditor: View {
    let task: TaskItem
    let appState: AppState

    @State private var titleBuffer: String
    @State private var detailsBuffer: String
    @State private var priorityBuffer: Priority
    @State private var deadlineBuffer: Date?
    @State private var startTimeBuffer: Date?
    @State private var durationBuffer: Int?
    @State private var remindPeriodBuffer: TimeInterval?

    /// Cycle-detection contract §4: NOT one of the seven commit-mechanism buffers above — a
    /// dependency edit is validated and written immediately at tap time
    /// (`appState.addTaskDependency`/`removeTaskDependency`), so this only ever holds the inline
    /// error string from the most recent `addTaskDependency` rejection (kept until the next
    /// dependency action, per the contract). It never participates in `commitIfChanged()`.
    @State private var dependencyError: String?

    private enum EditableField: Hashable { case title, details }
    @FocusState private var focusedField: EditableField?

    private var accentColors: Accent { appState.accent.accent }

    /// UNVERIFIED: explicit `State(initialValue:)` assignment inside a custom `init` (rather
    /// than each property's own default-value expression) is the standard SwiftUI way to seed
    /// `@State` from an init parameter — needed here since every buffer starts from `task`, which
    /// isn't available to a stored-property default expression. This shape is used throughout
    /// Apple's own SwiftUI documentation and believed correct on macOS 14+ (this app's floor), but
    /// this file was written entirely on Windows with no Xcode to compile it against.
    init(task: TaskItem, appState: AppState) {
        self.task = task
        self.appState = appState
        _titleBuffer = State(initialValue: task.title)
        _detailsBuffer = State(initialValue: task.details)
        _priorityBuffer = State(initialValue: task.priority)
        _deadlineBuffer = State(initialValue: task.deadline)
        _startTimeBuffer = State(initialValue: task.startTime)
        _durationBuffer = State(initialValue: task.durationMinutes)
        _remindPeriodBuffer = State(initialValue: task.reminderOverride?.remindPeriod)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            metaRow
            descriptionSection
            dependencySection
            actions
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 520)
        .volarGlass(level: .heavy, cornerRadius: 16)
        .onChange(of: focusedField) { oldValue, _ in
            // Mechanism branch (b): fires on every focus transition; only commit when LEAVING a
            // field (oldValue != nil) — landing focus in a field for the first time has nothing to
            // commit yet, and would otherwise fire a spurious commit on sheet open.
            if oldValue != nil {
                commitIfChanged()
            }
        }
        .onDisappear {
            // Mechanism branch (d): safety net for Esc / click-outside, neither of which runs the
            // Close button's own commit (branch (c), below in `actions`).
            commitIfChanged()
        }
    }

    // MARK: - Commit

    /// See this struct's header comment for the full idempotency argument. `title` is flattened
    /// (newlines -> spaces) and trimmed, falling back to the existing `task.title` when blank —
    /// same "never save an empty title, never block on it either" rule
    /// `AppState.ConfirmDraft.effectiveTitle` already establishes (`AppState.swift` ~L315), so this
    /// view doesn't need its own separate validation-error UI for a cleared title field.
    private func commitIfChanged() {
        let flattenedTitle = titleBuffer
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = flattenedTitle.isEmpty ? task.title : flattenedTitle

        let changed =
            resolvedTitle != task.title
            || detailsBuffer != task.details
            || priorityBuffer != task.priority
            || deadlineBuffer != task.deadline
            || startTimeBuffer != task.startTime
            || durationBuffer != task.durationMinutes
            || remindPeriodBuffer != task.reminderOverride?.remindPeriod
        guard changed else { return }

        appState.updateTask(
            task.id,
            title: resolvedTitle,
            details: detailsBuffer,
            priority: priorityBuffer,
            startTime: startTimeBuffer,
            deadline: deadlineBuffer,
            durationMinutes: durationBuffer,
            remindPeriod: remindPeriodBuffer
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if task.frog && !task.done {
                Circle()
                    .fill(VolarColor.high)
                    .frame(width: 6, height: 6)
                    .shadow(color: VolarColor.high.opacity(0.5), radius: 3)
            }
            TextField("Title", text: $titleBuffer)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .lineLimit(2)
                .focused($focusedField, equals: .title)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Meta row (priority · deadline · duration · start time · remind period · status) —
    // labels mirror `TaskRow` where a field also appears there.

    private var priorityColor: Color {
        switch priorityBuffer {
        case .high: return VolarColor.high
        case .medium: return VolarColor.med
        case .low: return VolarColor.low
        }
    }

    private var priorityLabel: String {
        switch priorityBuffer {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    private var bullet: some View {
        Text("\u{00B7}").opacity(0.4)
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            priorityMenu
            bullet
            deadlineControl
            bullet
            durationMenu
            bullet
            startTimeControl
            bullet
            remindPeriodMenu
            bullet
            Text(task.done ? "Done" : "Open")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(VolarColor.textSec)
    }

    /// Mechanism branch (a): a `Menu` selection commits in the same step it mutates the buffer —
    /// a menu tap is a single atomic user action with no separate "confirm" step of its own.
    /// `.menuStyle(.borderlessButton)` + `.fixedSize()` matches the existing custom-labeled `Menu`
    /// convention this app already uses (`PopoverView.swift`'s `dependencyPicker`).
    private var priorityMenu: some View {
        Menu {
            Button("High") { priorityBuffer = .high; commitIfChanged() }
            Button("Medium") { priorityBuffer = .medium; commitIfChanged() }
            Button("Low") { priorityBuffer = .low; commitIfChanged() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(priorityColor).frame(width: 6, height: 6)
                Text(priorityLabel)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var deadlineControl: some View {
        DateBufferControl(
            placeholder: "deadline",
            value: Binding(
                get: { deadlineBuffer },
                set: { deadlineBuffer = $0; commitIfChanged() }
            )
        )
    }

    private var startTimeControl: some View {
        DateBufferControl(
            placeholder: "start time",
            value: Binding(
                get: { startTimeBuffer },
                set: { startTimeBuffer = $0; commitIfChanged() }
            )
        )
    }

    private static let durationPresets = [5, 10, 15, 30, 45, 60, 90, 120, 180, 240]

    private var durationBufferLabel: String {
        guard let durationBuffer, durationBuffer > 0 else { return "Add duration" }
        return Self.durationPresetLabel(durationBuffer)
    }

    private static func durationPresetLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return hours == 1 ? "1 hr" : "\(hours) hrs" }
        return "\(hours)h \(remainder)m"
    }

    private var durationMenu: some View {
        Menu {
            ForEach(Self.durationPresets, id: \.self) { minutes in
                Button(Self.durationPresetLabel(minutes)) {
                    durationBuffer = minutes
                    commitIfChanged()
                }
            }
            Divider()
            Button("No duration") {
                durationBuffer = nil
                commitIfChanged()
            }
        } label: {
            Text(durationBufferLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Preset cadences (seconds) — same list `PopoverView`'s confirm-card reminder editor uses
    /// (manual-edit-contract.md §3), kept in sync by eye since the two files are file-disjoint
    /// (owned by different agents) and neither exposes a shared constant to the other.
    private static let remindPeriodPresets: [TimeInterval] = [900, 1800, 3600, 7200, 14400, 86400]

    private static func remindPeriodLabel(_ seconds: TimeInterval) -> String {
        switch seconds {
        case 900: return "15m"
        case 1800: return "30m"
        case 3600: return "1h"
        case 7200: return "2h"
        case 14400: return "4h"
        case 86400: return "1 day"
        default: return "\(Int(seconds / 60))m"
        }
    }

    private var remindPeriodBufferLabel: String {
        guard let remindPeriodBuffer else { return "Add reminder" }
        return "Remind \(Self.remindPeriodLabel(remindPeriodBuffer))"
    }

    /// "Default reminders" sets the buffer back to `nil` — per manual-edit-contract.md §1.1/§1.4
    /// that means "no user-specified cadence," which falls back to the task's underlying
    /// `fractionsRemaining` proportional reminders rather than clearing reminders outright.
    private var remindPeriodMenu: some View {
        Menu {
            ForEach(Self.remindPeriodPresets, id: \.self) { seconds in
                Button(Self.remindPeriodLabel(seconds)) {
                    remindPeriodBuffer = seconds
                    commitIfChanged()
                }
            }
            Divider()
            Button("Default reminders") {
                remindPeriodBuffer = nil
                commitIfChanged()
            }
        } label: {
            Text(remindPeriodBufferLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DESCRIPTION")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.77)
                .foregroundStyle(VolarColor.textMut)

            ScrollView {
                TextField("No description", text: $detailsBuffer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundStyle(VolarColor.textSec)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .focused($focusedField, equals: .details)
            }
            .frame(maxHeight: .infinity)
            .background(VolarColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .volarHairline(cornerRadius: 12)

            readButton
        }
        .frame(maxHeight: .infinity)
    }

    /// Reads the PERSISTED `task.details` (not `detailsBuffer`) — same as before this change:
    /// unsaved keystrokes aren't spoken until they've committed, which keeps this button's
    /// behavior exactly what it already was.
    private var readButton: some View {
        Button {
            appState.speakDetails(of: task)
        } label: {
            HStack(spacing: 8) {
                VolarIcon(.volume, size: 13, color: accentColors.solid, weight: .regular)
                Text("Read description")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(accentColors.solid)
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .buttonStyle(.plain)
        .background(accentColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accentColors.solid.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Waiting on (dependencies) — cycle-detection-contract.md §4.
    //
    // Deliberately NOT wired through the buffer/`commitIfChanged()` mechanism above: every
    // action here writes straight through `appState.addTaskDependency`/`removeTaskDependency` at
    // the moment of the tap. A dependency edit has to be validated (cycle check) right then —
    // deferring it to whatever later point `commitIfChanged()` would fire is exactly the "swallow
    // the error" bug this contract exists to close.

    private var dependencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WAITING ON")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.77)
                .foregroundStyle(VolarColor.textMut)

            if task.conditions.isEmpty {
                Text("Nothing")
                    .font(.system(size: 12))
                    .foregroundStyle(VolarColor.textMut)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(task.conditions.enumerated()), id: \.offset) { index, condition in
                        conditionRow(condition, index: index)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                addDependencyMenu
                if let dependencyError {
                    Text(dependencyError)
                        .font(.system(size: 11))
                        .foregroundStyle(VolarColor.high)
                        .lineLimit(2)
                }
            }
        }
    }

    /// One `.taskDone`/`.afterDate`/`.external` condition, with its own "x" removing exactly that
    /// index via `appState.removeTaskDependency` — same "gather then act on a stable index" shape
    /// `PopoverView`'s `conditionRows`/`dependencyPicker` already use for the confirm card.
    private func conditionRow(_ condition: VolarCore.Condition, index: Int) -> some View {
        HStack(spacing: 6) {
            Text(conditionLabel(condition))
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                appState.removeTaskDependency(task.id, at: index)
            } label: {
                VolarIcon(.x, size: 9, color: VolarColor.textMut)
            }
            .buttonStyle(.plain)
        }
    }

    /// `.taskDone` resolves against `appState.openTasks` (an id that no longer resolves there —
    /// already done, or deleted out from under this condition — reads as "Unknown task" rather
    /// than silently dropping the row, per constitution II). `.afterDate`/`.external` render their
    /// own payload directly; neither needs a task lookup.
    private func conditionLabel(_ condition: VolarCore.Condition) -> String {
        switch condition {
        case .taskDone(let id):
            return appState.openTasks.first { $0.id == id }?.title ?? "Unknown task"
        case .afterDate(let date):
            return "After \(date.formatted(.dateTime.month().day().hour().minute()))"
        case .external(let description, _):
            return "Waiting: \(description)"
        }
    }

    /// Contract §4: the candidate list excludes this task itself and any task it already depends
    /// on (re-picking one would either no-op or look like it silently did something). Same
    /// `openTasks`-backed `Menu` convention as `PopoverView`'s `dependencyPicker`. A rejection
    /// (non-nil return) replaces `dependencyError` and stays up until the next dependency action —
    /// no alert modal per the contract.
    private var addDependencyMenu: some View {
        let existingDependencyIDs: Set<UUID> = Set(
            task.conditions.compactMap {
                if case .taskDone(let id) = $0 { return id }
                return nil
            }
        )
        // Capped at 100 — same defensive bound `PopoverView`'s `dependencyPicker` uses for its
        // `openTasks` section, so this menu stays O(1) to render even with hundreds of open tasks
        // (self-review "performance").
        let candidates = appState.openTasks
            .filter { $0.id != task.id && !existingDependencyIDs.contains($0.id) }
            .prefix(100)
        return Menu {
            if candidates.isEmpty {
                Text("No other tasks")
            } else {
                ForEach(candidates) { candidate in
                    Button(candidate.title) {
                        dependencyError = appState.addTaskDependency(task.id, dependsOn: candidate.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                VolarIcon(.plus, size: 9, color: VolarColor.textMut, weight: .bold)
                Text("Add dependency")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(VolarColor.textSec)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                // Mechanism branch (c): commit before dismissing, so a click on Close itself
                // (which does not trigger `.onChange(of: focusedField)` if the click lands
                // somewhere that never took focus) never drops a pending edit. `.onDisappear`
                // below would also catch it, but this avoids relying on dismiss-animation timing.
                commitIfChanged()
                appState.closeDetail()
            } label: {
                Text("Close")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(VolarColor.veil(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .volarHairline(cornerRadius: 9)

            Button(role: .destructive) {
                appState.deleteTask(task.id)
                appState.closeDetail()
            } label: {
                Text("Delete")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.high)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(VolarColor.high.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(VolarColor.high.opacity(0.25), lineWidth: 0.5)
            )

            Spacer(minLength: 0)

            Button {
                appState.toggleDone(task.id)
            } label: {
                Text(task.done ? "Mark not done" : "Mark done")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: accentColors.glow, radius: 12, y: 4)
        }
    }
}

/// Shared `.popover` + `DatePicker` control for the `deadline`/`startTime` buffers (both
/// `Date?`): a plain muted "Add …" label when absent, the formatted instant when present — tapping
/// either opens the same popover, which also offers a "Clear" button to go back to `nil`. Mirrors
/// `PopoverView.swift`'s `DeadlineControl` shape (`.popover`, deliberately NOT a `Menu` — a
/// `Menu`'s `NSMenu` backing on macOS is known to render an embedded live control like `DatePicker`
/// unreliably, see that struct's own doc comment) without depending on it directly, since it's
/// `private` to that file and this file is a different agent's file-disjoint scope.
private struct DateBufferControl: View {
    let placeholder: String
    @Binding var value: Date?
    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            if let value {
                Text(value.formatted(.dateTime.month().day().hour().minute()))
            } else {
                Text("Add \(placeholder)")
                    .foregroundStyle(VolarColor.textMut)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPicker) {
            // No explicit `.datePickerStyle(...)` override (same reasoning as `DeadlineControl`'s
            // own picker — self-review "Swift-blind risk": macOS's exact non-graphical
            // `DatePickerStyle` case name could not be verified from this environment). `.automatic`
            // is the default and resolves to a reasonably compact date+time control on macOS.
            VStack(alignment: .trailing, spacing: 8) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { value ?? Date() },
                        set: { value = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                if value != nil {
                    Button("Clear") {
                        value = nil
                        showingPicker = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VolarColor.textMut)
                }
            }
            .padding(12)
            .fixedSize()
        }
    }
}

#Preview {
    let appState = AppState(tasks: SampleData.tasks)
    appState.detailTaskID = SampleData.tasks.first?.id
    return TaskDetailView()
        .environment(appState)
}
