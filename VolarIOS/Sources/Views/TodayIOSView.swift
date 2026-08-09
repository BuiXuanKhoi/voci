// VolarIOS/Sources/Views/TodayIOSView.swift — Today tab content.
// Ported from `design/volar-mobile.jsx`'s `VolarMobileApp` content area (specs/004-ios-port/plan.md
// §2.1/§4/§6). Behavioral reference (empty-state gating, "later" derivation, greeting placement):
// `Volar/Sources/Views/TodayView.swift` (macOS) — see this file's header comment there for what a
// desktop-only piece looks like; none of those pieces are ported here (full list in the
// implementing agent's final report point 6).
import SwiftUI

/// The Today tab's scrollable content: header, NOW hero card, "Later today"/"Completed" sections,
/// or the "All clear." empty state. Hosted inside `RootTabView`'s `Today` tab (A2, Phase 1) — this
/// view owns none of the tab bar / mic FAB chrome around it.
struct TodayIOSView: View {
    @Environment(AppState.self) private var appState: AppState

    private var accentColors: Accent { appState.accent.accent }

    /// Every open task except whichever one the engine picked as NOW — same membership as
    /// `TodayView.remainingOpenTasks` (macOS) so "Later today" never double-renders the hero task.
    private var laterOpenTasks: [TaskItem] {
        guard let active = appState.activeTask else { return appState.openTasks }
        return appState.openTasks.filter { $0.id != active.id }
    }

    var body: some View {
        Group {
            // Same gating as `TodayView.mainColumn` (macOS): once there is nothing open, show the
            // "All clear." card instead of the list — this hides "Completed" too when the day is
            // fully clear, matching the existing production behavior rather than a new invention.
            if appState.openTasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .background(VolarColor.bg)
    }

    // MARK: - Populated list
    //
    // DESIGN-FIDELITY NOTE (self-review point 4): the prototype's content area is a plain
    // `ScrollView`. This uses `List` instead — `.swipeActions` (required by this task's contract)
    // only renders on rows hosted inside a `List`; a `ScrollView`/`VStack` compiles the modifier but
    // silently drops the gesture. Every row below strips List's default chrome (hidden separators,
    // clear row backgrounds, `.listStyle(.plain)`, `.scrollContentBackground(.hidden)`) so the
    // result reads the same as the prototype's stacked cards while swipe-to-delete/-done actually
    // work. UNVERIFIED: this `listRow*` combination is a well-known SwiftUI idiom but its exact
    // rendered spacing/hairline behavior hasn't been checked on this machine (no Xcode/Swift
    // toolchain — Windows).
    private var taskList: some View {
        List {
            header
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if let active = appState.activeTask {
                MobileTaskCard(task: active, size: .hero) {
                    appState.toggleDone(active.id)
                }
                .padding(.top, 6)
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { appState.openDetail(active.id) }
            }

            if !laterOpenTasks.isEmpty {
                sectionHeaderRow(title: "LATER TODAY", count: laterOpenTasks.count)
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                ForEach(laterOpenTasks) { task in
                    taskRow(task)
                }
            }

            if !appState.doneTasks.isEmpty {
                sectionHeaderRow(title: "COMPLETED", count: appState.doneTasks.count)
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                ForEach(appState.doneTasks) { task in
                    taskRow(task)
                }
            }

            // Bottom clearance so the mic FAB (`IOSMetrics.fabSize`) + tab bar never cover the last
            // row — the prototype budgets ~200pt of trailing scroll padding for the same reason.
            Color.clear
                .frame(height: 200)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(VolarColor.bg)
        .animation(VolarMotion.list, value: appState.tasks)
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 4, leading: IOSMetrics.screenPadH, bottom: 4, trailing: IOSMetrics.screenPadH)
    }

    /// One "Later today"/"Completed" row: tap opens the detail sheet, leading swipe toggles
    /// done/undo, trailing swipe deletes. `AppState.openDetail`/`toggleDone`/`deleteTask` are the
    /// exact frozen calls `TaskRow.swift` (macOS) wires to the same three gestures.
    @ViewBuilder
    private func taskRow(_ task: TaskItem) -> some View {
        MobileTaskCard(task: task) {
            appState.toggleDone(task.id)
        }
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { appState.openDetail(task.id) }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                appState.deleteTask(task.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(VolarColor.destruct)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                appState.toggleDone(task.id)
            } label: {
                Label(task.done ? "Undo" : "Done", systemImage: task.done ? "arrow.uturn.backward" : "checkmark")
            }
            // No red/mint here: "Done" reuses the success token, "Undo" the informational ice-blue
            // instrument token — same two tokens used everywhere else on this screen.
            .tint(task.done ? VolarColor.instrument : VolarColor.done)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(todayDateLabel)
                .font(IOSMetrics.eyebrow)
                .tracking(IOSMetrics.eyebrowTracking)
                .textCase(.uppercase)
                .foregroundStyle(accentColors.solid)

            Text(greeting)
                .font(IOSMetrics.screenTitle)
                .tracking(IOSMetrics.titleTracking)
                .foregroundStyle(VolarColor.textPri)

            Text("\(appState.openTasks.count) tasks today · \(appState.doneTasks.count) already done")
                .font(IOSMetrics.caption)
                .foregroundStyle(VolarColor.textSec)
                .padding(.top, 2)
        }
        .padding(.top, 8)
    }

    private var todayDateLabel: String {
        Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Time-of-day greeting ("Good morning."/"Good afternoon."/"Good evening."/"Good night.").
    /// `Volar/Sources/Views/TodayView.swift` (macOS) has no time-varying greeting of its own — its
    /// header just titles the screen "Today" — so the wording is drawn from the closest existing
    /// analog in the reference codebase, `MorningFrogView.swift`'s "Good morning." (sentence case,
    /// trailing period), extended to the other dayparts the prototype's "Good morning, Alex." calls
    /// for. No user name exists on `AppState` to interpolate, so the name is dropped.
    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date.now) {
        case 5..<12: return "Good morning."
        case 12..<17: return "Good afternoon."
        case 17..<22: return "Good evening."
        default: return "Good night."
        }
    }

    // MARK: - Section header ("LATER TODAY" / "COMPLETED")

    private func sectionHeaderRow(title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(IOSMetrics.sectionHeader)
                .tracking(IOSMetrics.sectionTracking)
                .foregroundStyle(VolarColor.textMut)
            Rectangle()
                .fill(VolarColor.border)
                .frame(height: 0.5)
            Text("\(count)")
                .font(IOSMetrics.caption)
                .foregroundStyle(VolarColor.textMut)
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    // MARK: - Empty state ("All clear.")

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(accentColors.surface)
                    .frame(width: 80, height: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(accentColors.solid.opacity(0.20), lineWidth: 0.5)
                    )
                VolarIcon(.mic, size: 36, color: accentColors.solid, weight: .light)
            }

            // No exact `IOSMetrics` role matches the prototype's 22pt headline here (nearest is
            // `.nowTitle` at 17pt) — reused rather than introducing an ad hoc size, since only
            // `IOSMetrics`/`VolarColor` tokens are allowed on this screen. See final-report point 4.
            Text("All clear.")
                .font(IOSMetrics.nowTitle)
                .foregroundStyle(VolarColor.textPri)

            Text("Tap the mic and speak your next task.")
                .font(IOSMetrics.caption)
                .foregroundStyle(VolarColor.textSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(.horizontal, IOSMetrics.screenPadH)
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
