// Sources/Views/TaskDetailView.swift — task detail INSPECTOR PANEL: edit-in-place + read-aloud +
// actions. Panel-refactor (2026-08-07, specs/005-cursor-retheme/panel-refactor.md) moved this from
// a modal `.sheet` (the `.sheet` used to live in `VolarApp.swift`, gated on
// `appState.detailTaskID != nil`) to a 300pt column docked in `TodayView.body`'s own `HStack`,
// alongside `Sidebar`/`mainColumn` — see that file's `detailPanel`. Nothing about the commit
// mechanism below changed for that move; only the presentation container did.
// Phase 1 originally shipped this read-only. T-manual-edit (2026-07-29, anh Khôi — see
// specs/002-workflow-command-center/contracts/manual-edit-contract.md §4) turns it into an
// edit-in-place surface for all 7 manually-editable fields (title, description, priority, start
// time, deadline, duration, remind period) instead of adding a separate Edit panel — the same UI
// decision the contract froze for this file. Every edit commits through `AppState.updateTask`
// (the manual-edit contract's single write path, §1.4, owned by a sibling agent) — this file never
// touches `TaskStore` directly. Reads the live task off `AppState.detailTask` (rather than taking
// one as a param) so toggling done / editing elsewhere is reflected immediately while the panel is
// open.
import SwiftUI
import VolarCore

struct TaskDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let task = appState.detailTask {
            // `.id(task.id)` gives `TaskDetailEditor` a fresh identity — and therefore freshly
            // re-seeded `@State` edit buffers — whenever the panel switches to a DIFFERENT task
            // (clicking a different row while the panel is already open, which is the whole reason
            // this is a panel now instead of a sheet: a sheet could never be switched without
            // closing it first). Re-renders of the SAME task (e.g. `detailTask` recomputing after
            // this view's own commit, or after some unrelated background change) keep the existing
            // identity, so in-progress edits in the buffers are never stomped — see
            // `TaskDetailEditor`'s own header comment for the full argument.
            TaskDetailEditor(task: task, appState: appState)
                .id(task.id)
        } else {
            // Panel is closed (or `detailTaskID` got cleared out from under us) — nothing to show.
            // `TodayView.detailPanel` also wraps this whole view in an `if appState.detailTask !=
            // nil` at the `HStack` level, so in practice this branch just means "don't reserve any
            // visual weight" rather than "hide a 300pt empty box."
            EmptyView()
        }
    }
}

/// Owns the edit-in-place `@State` buffers for exactly one task's detail panel. A dedicated `View`
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                metaRow
                descriptionSection
                dependencySection
                actions
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: focusedField) { oldValue, _ in
            // Mechanism branch (b): fires on every focus transition; only commit when LEAVING a
            // field (oldValue != nil) — landing focus in a field for the first time has nothing to
            // commit yet, and would otherwise fire a spurious commit on panel open.
            if oldValue != nil {
                commitIfChanged()
            }
        }
        .onDisappear {
            // Mechanism branch (d): safety net for Esc / click-outside, neither of which runs the
            // Close button's own commit (branch (c), below in `actions`) — STILL load-bearing now
            // that this is a panel, not a sheet (panel-refactor.md §3). This view disappears twice:
            // when `detailTask` goes back to `nil` (panel closes), and when `TaskDetailView`'s
            // `.id(task.id)` changes because the user clicked a DIFFERENT row while this panel was
            // already open — SwiftUI tears down the old `.id()`-identified view (firing this
            // `.onDisappear` on it) before building the new one. That second case is the only
            // reason a panel can lose an in-progress edit that a sheet never could (a sheet has to
            // close before another task can be opened at all), which is exactly what this branch
            // protects against. Do not delete this modifier on the theory that "the panel never
            // disappears" — it does, and this is the safety net for both times it does.
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

    // MARK: - Meta row — vertical inspector field list (priority / deadline / duration /
    // start time / remind period / status), one label+value row per field. See `metaRow`'s own
    // doc comment for why this is a `VStack` of rows rather than the single `HStack` it used to
    // be. Field labels mirror `TaskRow` where a field also appears there.

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

    /// Vertical inspector field list — one label/value row per field, the standard inspector
    /// idiom (Xcode's and Cursor's inspectors both lay out this way). The original `metaRow` was
    /// a single `HStack` of six controls plus five `·` separators, sized for the old 480pt
    /// `.sheet` presentation; that needs roughly 450pt and does not fit this view's current
    /// 340pt panel / ~300pt content width, and `HStack` doesn't wrap, so trailing controls got
    /// clipped. A vertical list has no width ceiling of its own — each row only needs to fit
    /// label + value on one line, which it does at any panel width this app uses.
    ///
    /// The label style (10pt medium, 0.7 tracking, uppercase, `textMut`) matches
    /// `SectionHeader` (`Components.swift`) and `DiffRow` (`DiffRow.swift`), the two other places
    /// this app already renders an uppercase field label — not invented fresh here. The row VALUE
    /// font/color (12pt medium `textSec`) is `metaRow`'s original styling, applied to the
    /// container so each control still renders exactly as it did before; each label's own
    /// explicit `.font`/`.foregroundStyle` below is more specific and wins over that container
    /// styling, so labels render at 10pt `textMut`, not the 12pt `textSec` value style.
    private var metaRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            metaFieldRow("PRIORITY") { priorityMenu }
            metaFieldRow("DEADLINE") { deadlineControl }
            metaFieldRow("DURATION") { durationMenu }
            metaFieldRow("START") { startTimeControl }
            metaFieldRow("REMIND") { remindPeriodMenu }
            metaFieldRow("STATUS") { Text(task.done ? "Done" : "Open") }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(VolarColor.textSec)
    }

    /// One `metaRow` line: uppercase muted label at the leading edge, the field's existing
    /// control at the trailing edge, a flexible `Spacer` between them doing the right-alignment
    /// work so a control's own `.fixedSize()` (kept as-is on every menu below) never has to
    /// fight the row for space.
    private func metaFieldRow<Value: View>(
        _ label: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.7) // 0.07em at 10pt — matches `SectionHeader`/`DiffRow`'s field label
                .textCase(.uppercase)
                .foregroundStyle(VolarColor.textMut)
            Spacer(minLength: 12)
            value()
        }
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
                .font(Font.volarMono(size: 12, weight: .medium))
                .monospacedDigit()
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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .volarHairline(cornerRadius: 8)

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
            // Vùng bấm phủ đúng vùng nhìn thấy (luật anh Khôi chốt 2026-08-09) — xem
            // `Sidebar.swift`'s `SidebarItem` cho giải thích đầy đủ về họ bug này.
            .contentShape(Rectangle())
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

    /// Two rows, not the single `HStack` this used to be. The original row packed Close, Delete,
    /// a `Spacer`, and the Mark done/not done toggle side by side, sized for the old 480pt
    /// `.sheet` presentation; "Mark not done" (the longer of the two toggle labels) alone needs
    /// roughly 304pt next to Close and Delete, which does not fit this view's current 340pt panel
    /// / ~300pt content width — the row would clip or spill. Splitting into a primary row (the
    /// toggle, full width) over a secondary row (Close/Delete, spread) is both the inspector idiom
    /// and gives the primary action — the one anh Khôi reaches for most, done/not-done — its own
    /// full-width weight instead of competing for space with two secondary buttons.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                appState.toggleDone(task.id)
            } label: {
                Text(task.done ? "Mark not done" : "Mark done")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    // Vùng bấm phủ đúng vùng nhìn thấy (luật 2026-08-09). Đây là nút chính của cả
                    // panel — full-width đúng để nó DỄ bấm, mà thiếu dòng này thì cả dải rộng ấy
                    // chỉ ăn click ở đúng chỗ chữ, tức phản tác dụng hoàn toàn với ý đồ thiết kế.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: accentColors.glow, radius: 12, y: 4)

            HStack(spacing: 8) {
                Button {
                    // Mechanism branch (c): commit before dismissing, so a click on Close itself
                    // (which does not trigger `.onChange(of: focusedField)` if the click lands
                    // somewhere that never took focus) never drops a pending edit. `.onDisappear`
                    // below would also catch it, but this avoids relying on dismiss-animation
                    // timing.
                    commitIfChanged()
                    appState.closeDetail()
                } label: {
                    Text("Close")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        // Vùng bấm phủ đúng vùng nhìn thấy (luật 2026-08-09).
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(VolarColor.veil(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .volarHairline(cornerRadius: 6)

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    appState.deleteTask(task.id)
                    appState.closeDetail()
                } label: {
                    // `destruct` (not `high`) — this is the token for irreversible actions; `high`
                    // is priority-only and reads almost identically to `destruct` on the graphite
                    // ground.
                    Text("Delete")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VolarColor.destruct)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        // Vùng bấm phủ đúng vùng nhìn thấy (luật 2026-08-09). Nút XOÁ, nên đáng nói
                        // thêm: mở rộng vùng bấm ở đây làm nút dễ bấm NHẦM hơn đúng bằng mức nó dễ
                        // bấm TRÚNG hơn. Chấp nhận được vì `Spacer(minLength: 0)` ngay trên đã đẩy
                        // nút này về sát mép phải, cách "Close" một khoảng rộng — không có chuyện
                        // hai vùng bấm chạm nhau. Nếu sau này bố cục đổi và hai nút sát lại thì phải
                        // xem lại chỗ này, đừng chỉ giữ nguyên vì nó đang chạy.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(VolarColor.destruct.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(VolarColor.destruct.opacity(0.25), lineWidth: 0.5)
                )
            }
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
