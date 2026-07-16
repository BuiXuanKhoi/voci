// Sources/Views/PopoverView.swift — 5-state quick-capture popover (spec §4/§5, voci-popover.jsx)
import SwiftUI
// T074: `TaskConflict` (contract C, `VociCore/Sources/VociCore/ConflictCheck.swift`, sibling-owned
// — not yet landed) is the only VociCore symbol this file needs directly.
import VociCore

/// Ported from `design/voci-popover.jsx`'s `VociPopover`, driven entirely by
/// `appState.captureState` (`.idle/.recording/.parsing/.parsed/.saving/.done/.error`) instead of
/// the JSX's local/controlled `state` prop. Sizes itself to a fixed 380pt width internally, so
/// callers (the popover-hosting window/`NSPopover`, wired in Phase 3) just place this view.
///
/// Phase 3 (T024) reworks the confirm card for `ParsedTask` v2 (contracts/parsing-contract.md):
/// each present attribute renders as a dismissible chip; uncertain (<0.7 confidence) chips render
/// dashed with "?" and require an explicit tap to accept before they can be saved (constitution
/// II); `.taskDone` conditions below that bar show a task PICKER, never auto-attach; up to 10
/// tasks confirm as a compact set (still glance-and-dismiss — Enter saves all); a one-time sheet
/// gates the first cloud parse. All actual resolution/materialization lives in
/// `AppState.confirmSave()` (T025) — this file only renders `appState.confirmDrafts` and reports
/// taps back through `AppState`'s chip-interaction methods.
struct PopoverView: View {
    @Environment(AppState.self) private var appState: AppState
    @State private var mounted = false

    private let width: CGFloat = 380

    var body: some View {
        let accent = appState.accent.accent

        VStack(alignment: .leading, spacing: 0) {
            hintRow(accent: accent)
            waveformSection(accent: accent)

            if showTranscript {
                transcriptSection()
                    .transition(.opacity)
            }

            if showParsedCard {
                parsedCard()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showActions {
                actionsRow(accent: accent)
                    .transition(.opacity)
            }

            if appState.captureState == .error {
                errorActionsRow(accent: accent)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: width)
        .vociGlass(level: .heavy, cornerRadius: 18)
        .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 24)
        .scaleEffect(mounted ? 1 : 0.96)
        .opacity(mounted ? 1 : 0)
        .animation(VociMotion.state, value: appState.captureState)
        .onAppear {
            // Appear animation: scale 0.96 -> 1 + fade, mirrors the JSX `mounted` flag flipped on
            // the next animation frame.
            withAnimation(.spring(response: 0.2, dampingFraction: 0.86)) {
                mounted = true
            }
        }
    }

    // MARK: - Visibility (mirrors JSX `showWave` / `showTranscript` / `showParsedCard` / `showActions`)

    private var showWave: Bool {
        appState.captureState == .recording || appState.captureState == .parsing
    }

    private var showTranscript: Bool {
        appState.captureState != .idle && appState.captureState != .error
    }

    private var showParsedCard: Bool {
        (appState.captureState == .parsed || appState.captureState == .saving || appState.captureState == .done)
            && !appState.confirmDrafts.isEmpty
    }

    private var showActions: Bool {
        appState.captureState == .parsed || appState.captureState == .saving
    }

    // MARK: - Hint row

    private func hintRow(accent: Accent) -> some View {
        HStack(alignment: .center) {
            leftHint(accent: accent)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Kbd("Esc")
                Text("cancel").opacity(0.6)
            }
            .foregroundStyle(VociColor.textMut)
        }
        .font(.system(size: 11.5))
    }

    @ViewBuilder
    private func leftHint(accent: Accent) -> some View {
        switch appState.captureState {
        case .idle:
            EmptyView()
        case .recording:
            HStack(spacing: 6) {
                PulsingDot()
                Text("Listening…")
            }
            .foregroundStyle(VociColor.textMut)
            .transition(.opacity)
        case .parsing:
            Text("Parsing with AI…").foregroundStyle(accent.solid)
                .transition(.opacity)
        case .parsed:
            Text(appState.confirmDrafts.count > 1 ? "Looks right? Hit return to save all." : "Looks right? Hit return.")
                .foregroundStyle(VociColor.textMut)
                .transition(.opacity)
        case .saving:
            Text("Saving…").foregroundStyle(accent.solid)
                .transition(.opacity)
        case .done:
            Text("Saved").foregroundStyle(VociColor.done)
                .transition(.opacity)
        case .error:
            // `lineLimit` widened from the v1 2 lines to 3 — the cloud-consent explanation
            // (T024) runs longer than a typical capture-failure message; unrelated error copy
            // still fits comfortably within 3 lines.
            Text(appState.captureErrorDetail ?? "Didn't catch that.")
                .foregroundStyle(VociColor.destruct)
                .lineLimit(3)
                .transition(.opacity)
        }
    }

    // MARK: - Waveform / done check / error copy

    @ViewBuilder
    private func waveformSection(accent: Accent) -> some View {
        Group {
            if showWave {
                Waveform(
                    active: appState.captureState == .recording,
                    color: accent.solid,
                    glow: accent.glow,
                    bars: 32,
                    height: 42
                )
                .transition(.opacity)
            } else {
                HStack {
                    switch appState.captureState {
                    case .done:
                        ZStack {
                            Circle()
                                .fill(VociColor.done)
                                .frame(width: 32, height: 32)
                                .shadow(color: Color(voci: 0x5BD17A, opacity: 0.5), radius: 24)
                            VocIcon(.check, size: 18, color: Color(voci: 0x0E2A16), weight: .bold)
                        }
                        .transition(.opacity)
                    case .error:
                        // Matches the existing `pendingServerConsent` convention: this generic
                        // "Try again" placeholder is shown for every `.error` state, including
                        // consent prompts — unchanged from the pre-T024 behavior.
                        Text("Try again")
                            .font(.system(size: 13))
                            .foregroundStyle(VociColor.destruct)
                            .transition(.opacity)
                    default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
        .frame(height: 42)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Transcript

    private func transcriptSection() -> some View {
        HStack(alignment: .top, spacing: 2) {
            Text(transcriptText)
                .font(.system(size: 14.5))
                .lineSpacing(2)
                .foregroundStyle(appState.captureState == .recording ? VociColor.textPri : VociColor.textSec)
            if appState.captureState == .recording {
                BlinkingCaret(color: appState.accent.accent.solid)
            }
        }
        .frame(minHeight: 42, alignment: .topLeading)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// While `.recording`, the live streamed transcript from `SpeechCapture`. Otherwise, the
    /// first confirmed task's title stands in for it (multi-task: "+N more"), muted, matching the
    /// JSX's non-recording transcript styling.
    private var transcriptText: String {
        if appState.captureState == .recording {
            return appState.liveTranscript
        }
        guard let first = appState.confirmDrafts.first else { return appState.liveTranscript }
        let extra = appState.confirmDrafts.count - 1
        return extra > 0 ? "\(first.task.title)  +\(extra) more" : first.task.title
    }

    // MARK: - Parsed card (T024 — chips v2)

    /// One `VStack` holding every confirmed draft's chip set, separated by hairlines when there's
    /// more than one (multi-task confirm: a compact reviewable set, still glance-and-dismiss).
    private func parsedCard() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(appState.confirmDrafts.enumerated()), id: \.element.id) { offset, draft in
                if offset > 0 {
                    Rectangle().fill(VociColor.border).frame(height: 0.5)
                }
                taskDraftCard(draft, showRemove: appState.confirmDrafts.count > 1)
            }
        }
        .padding(12)
        .background(VociColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VociColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 6)
    }

    private func taskDraftCard(_ draft: ConfirmDraft, showRemove: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(draft.task.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(VociColor.textPri)
                    .lineLimit(3)
                Spacer(minLength: 4)
                if showRemove {
                    Button {
                        appState.removeDraft(draft.id)
                    } label: {
                        VocIcon(.x, size: 9, color: VociColor.textMut)
                    }
                    .buttonStyle(.plain)
                }
            }
            attributeChips(draft)
            conditionRows(draft)
            conflictAdvisoryRow(draft)
        }
    }

    /// T074: AT MOST ONE calm advisory line — never a dialog, never a red/shame color (FR-036),
    /// never blocking (`Enter` still saves regardless — this row has no bearing on `actionsRow`'s
    /// Save button at all). Tapping it only dismisses the row itself; it never auto-modifies the
    /// draft (constitution II) — a fuller "bump the deadline" quick-action is a reasonable future
    /// enhancement but is NOT implemented here (self-review note, flagged in the final report as a
    /// deliberate scope decision, not an oversight).
    @ViewBuilder
    private func conflictAdvisoryRow(_ draft: ConfirmDraft) -> some View {
        if let conflict = draft.conflicts.first, !draft.conflictDismissed {
            HStack(alignment: .top, spacing: 6) {
                Text("\u{26A0}\u{FE0F}")
                    .font(.system(size: 11))
                Text(conflictAdvisoryText(conflict))
                    .font(.system(size: 11.5))
                    .foregroundStyle(VociColor.textSec)
                    .lineLimit(2)
                Spacer(minLength: 4)
            }
            .padding(.top, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                appState.dismissConflictAdvisory(forDraft: draft.id)
            }
        }
    }

    /// One short, calm sentence per `TaskConflict` case (contract C) — no exclamation-mark alarm
    /// copy, matching the example in the task brief ("3 tasks already due tomorrow — add anyway?").
    private func conflictAdvisoryText(_ conflict: TaskConflict) -> String {
        switch conflict {
        case .deadlineCapacity(let existingCount, _, let windowEnd):
            let day = windowEnd.formatted(.dateTime.weekday(.wide))
            return "\(existingCount) task\(existingCount == 1 ? "" : "s") already due \(day) — add anyway?"
        case .deadlineCollision(_, let title):
            return "Clashes with \u{201C}\(title)\u{201D} — add anyway?"
        case .dependsOnBlocked(_, let title):
            return "Waiting on \u{201C}\(title)\u{201D}, which is overdue"
        case .competesWithFrog(_, let title):
            return "Competes with today's frog, \u{201C}\(title)\u{201D}"
        case .possibleDuplicate(_, let title, _):
            return "Looks similar to \u{201C}\(title)\u{201D} — add anyway?"
        }
    }

    /// Deadline / estimate / priority / reminder / recurrence / kind — every PRESENT attribute
    /// renders as a dismissible chip; absent ones render nothing (T024).
    @ViewBuilder
    private func attributeChips(_ draft: ConfirmDraft) -> some View {
        FlowLayout(spacing: 6) {
            if let deadline = draft.task.deadline, !draft.dismissed.contains(.deadline) {
                Chip(
                    label: deadline.value.formatted(.dateTime.month().day().hour().minute()),
                    uncertain: deadline.isUncertain,
                    accepted: draft.accepted.contains(.deadline),
                    onAccept: { appState.acceptUncertainAttribute(.deadline, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.deadline, forDraft: draft.id) }
                )
            }
            if let estimate = draft.task.estimateMinutes, !draft.dismissed.contains(.estimate) {
                Chip(
                    label: formattedDuration(estimate.value),
                    uncertain: estimate.isUncertain,
                    accepted: draft.accepted.contains(.estimate),
                    onAccept: { appState.acceptUncertainAttribute(.estimate, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.estimate, forDraft: draft.id) }
                )
            }
            if let priority = draft.task.priority, !draft.dismissed.contains(.priority) {
                Chip(
                    label: priorityLabel(priority.value),
                    uncertain: priority.isUncertain,
                    accepted: draft.accepted.contains(.priority),
                    onAccept: { appState.acceptUncertainAttribute(.priority, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.priority, forDraft: draft.id) }
                )
            }
            if let reminder = draft.task.reminderOverride, !draft.dismissed.contains(.reminder) {
                Chip(
                    label: reminderLabel(reminder.value),
                    uncertain: reminder.isUncertain,
                    accepted: draft.accepted.contains(.reminder),
                    onAccept: { appState.acceptUncertainAttribute(.reminder, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.reminder, forDraft: draft.id) }
                )
            }
            if let recurrence = draft.task.recurrence, !draft.dismissed.contains(.recurrence) {
                Chip(
                    label: recurrenceLabel(recurrence.value),
                    uncertain: recurrence.isUncertain,
                    accepted: draft.accepted.contains(.recurrence),
                    onAccept: { appState.acceptUncertainAttribute(.recurrence, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.recurrence, forDraft: draft.id) }
                )
            }
            // `.task` is the default/absent case — only a non-default kind (`.review`) is a
            // "present" attribute worth a chip (T024: "kind" is in the dismissible-chip list).
            if draft.task.kind != .task, !draft.dismissed.contains(.kind) {
                Chip(
                    label: kindLabel(draft.task.kind),
                    uncertain: false,
                    accepted: true,
                    onAccept: nil,
                    onDismiss: { appState.dismissAttribute(.kind, forDraft: draft.id) }
                )
            }
            // Mi-1 (constitution II): `followUpReview` used to silently materialize an extra
            // `.review` task with no confirm-card representation at all. Defaults ON (matching the
            // parser's signal) but glance-and-dismiss like every other chip — dismissing it here
            // is what `confirmSave` reads to skip creating the derived task.
            if draft.task.followUpReview, !draft.dismissed.contains(.followUpReview) {
                Chip(
                    label: "+ Review after done",
                    uncertain: false,
                    accepted: true,
                    onAccept: nil,
                    onDismiss: { appState.dismissAttribute(.followUpReview, forDraft: draft.id) }
                )
            }
        }
    }

    /// Every `ParsedCondition`, in order — `.taskDone` gets the constitution-II picker row;
    /// `.afterDate`/`.external` get an ordinary (dismissible, uncertain-gated) chip.
    @ViewBuilder
    private func conditionRows(_ draft: ConfirmDraft) -> some View {
        let visible = draft.task.conditions.indices.filter { !draft.dismissedConditions.contains($0) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visible, id: \.self) { index in
                    conditionRow(draft.task.conditions[index], index: index, draft: draft)
                }
            }
        }
    }

    @ViewBuilder
    private func conditionRow(_ condition: ParsedCondition, index: Int, draft: ConfirmDraft) -> some View {
        HStack(spacing: 6) {
            Circle().fill(VociColor.textMut).frame(width: 5, height: 5)
            switch condition {
            case .taskDone(let titleQuery, let confidence):
                taskDoneRow(titleQuery: titleQuery, confidence: confidence, index: index, draft: draft)
            case .afterDate(let date, let confidence):
                Chip(
                    label: "After \(date.formatted(.dateTime.month().day()))",
                    uncertain: confidence < 0.7,
                    accepted: draft.acceptedConditions.contains(index),
                    onAccept: { appState.acceptUncertainCondition(at: index, forDraft: draft.id) },
                    onDismiss: { appState.dismissCondition(at: index, forDraft: draft.id) }
                )
            case .external(let description, let confidence):
                Chip(
                    label: "Waiting: \(description)",
                    uncertain: confidence < 0.7,
                    accepted: draft.acceptedConditions.contains(index),
                    onAccept: { appState.acceptUncertainCondition(at: index, forDraft: draft.id) },
                    onDismiss: { appState.dismissCondition(at: index, forDraft: draft.id) }
                )
            }
        }
    }

    /// `.taskDone`: if it was already auto-resolved (parser confidence >= 0.7 AND a confident
    /// fuzzy title match — `AppState.preResolveConditions`), render a normal solid chip naming
    /// the matched task. Otherwise this is exactly the constitution-II case — < 0.7, or no
    /// confident match — and it MUST NOT auto-attach: show the picker instead.
    @ViewBuilder
    private func taskDoneRow(titleQuery: String, confidence: Double, index: Int, draft: ConfirmDraft) -> some View {
        if let resolvedID = draft.resolvedTaskDone[index], confidence >= 0.7 {
            let title = appState.openTasks.first { $0.id == resolvedID }?.title ?? titleQuery
            Chip(
                label: "After: \(title)",
                uncertain: false,
                accepted: true,
                onAccept: nil,
                onDismiss: { appState.dismissCondition(at: index, forDraft: draft.id) }
            )
        } else {
            dependencyPicker(titleQuery: titleQuery, index: index, draft: draft)
        }
    }

    /// The task PICKER constitution II mandates for a `.taskDone` below 0.7 confidence — a native
    /// `Menu` (not the custom `Chip`, which bundles its own dismiss button as a `Menu` label
    /// child; nesting a `Button` inside a `Menu`'s label doesn't reliably get its own tap target,
    /// so the dismiss "x" here is a sibling control instead). Capped defensively at 100 open
    /// titles — same bound the cloud contract uses — so this stays O(1) to render even at
    /// hundreds of tasks (self-review "performance"); `openTasks` only ever lists the user's own
    /// tasks (self-review "security" — no cross-user/global data).
    private func dependencyPicker(titleQuery: String, index: Int, draft: ConfirmDraft) -> some View {
        HStack(spacing: 4) {
            Menu {
                Button("Skip — no dependency") {
                    appState.resolveTaskDone(at: index, to: nil, forDraft: draft.id)
                }
                if !appState.openTasks.isEmpty {
                    Divider()
                    ForEach(appState.openTasks.prefix(100)) { task in
                        Button(task.title) {
                            appState.resolveTaskDone(at: index, to: task.id, forDraft: draft.id)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text("?").font(.system(size: 10, weight: .bold))
                    Text("After: \u{201C}\(titleQuery)\u{201D}")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(VociColor.textSec)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .overlay(
                    Capsule().strokeBorder(VociColor.textMut, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                appState.dismissCondition(at: index, forDraft: draft.id)
            } label: {
                VocIcon(.x, size: 9, color: VociColor.textMut)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Chip label formatting

    private func priorityLabel(_ raw: Int) -> String {
        switch raw {
        case 1: return "High priority"
        case 2: return "Medium priority"
        case 3: return "Low priority"
        default: return "Priority \(raw)" // engine allows up to 4 (data-model.md); no crash on the edge value
        }
    }

    private func reminderLabel(_ policy: ReminderPolicy) -> String {
        policy.repeatEvery != nil ? "Custom reminders" : "\(policy.offsets.count) reminder\(policy.offsets.count == 1 ? "" : "s")"
    }

    private func recurrenceLabel(_ recurrence: Recurrence) -> String {
        switch recurrence {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .every(let days): return "Every \(days)d"
        }
    }

    private func kindLabel(_ kind: TaskKind) -> String {
        kind == .review ? "Review" : kind.rawValue.capitalized
    }

    /// Mirrors `TaskItem.durationLabel`'s formatting ("45 min" / "1 hr" / "1h 30m"); duplicated
    /// here (rather than reaching into `TaskItem`) because `ParsedTask` is a distinct, smaller
    /// pre-save value type and this file must not modify frozen Model files.
    private func formattedDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let mins = minutes % 60
        if mins == 0 { return hours == 1 ? "1 hr" : "\(hours) hrs" }
        return "\(hours)h \(mins)m"
    }

    // MARK: - Actions (parsed / saving)

    private func actionsRow(accent: Accent) -> some View {
        HStack(spacing: 8) {
            Button {
                appState.cancelCapture()
            } label: {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VociColor.textPri)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(VociColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .keyboardShortcut(.cancelAction)

            Button {
                appState.confirmSave()
            } label: {
                Group {
                    if appState.captureState == .saving {
                        Spinner(color: accent.solid, size: 14)
                    } else {
                        HStack(spacing: 8) {
                            Text(saveLabel)
                            Text("↵").opacity(0.85).font(.system(size: 12))
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(appState.captureState == .saving ? accent.surface : accent.solid)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        appState.captureState == .saving ? accent.surface : Color.white.opacity(0.18),
                        lineWidth: 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: appState.captureState == .saving ? .clear : accent.glow, radius: 10, x: 0, y: 4)
            .disabled(appState.captureState == .saving)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 10)
    }

    /// "Save task" / "Save 3 tasks" — multi-task confirm still saves the whole batch in one Enter
    /// (glance-and-dismiss, constitution V).
    private var saveLabel: String {
        appState.confirmDrafts.count > 1 ? "Save \(appState.confirmDrafts.count) tasks" : "Save task"
    }

    // MARK: - Error retry / consent rows

    @ViewBuilder
    private func errorActionsRow(accent: Accent) -> some View {
        if appState.pendingServerConsent {
            dictationConsentActionsRow(accent: accent)
        } else if appState.pendingCloudConsent {
            cloudConsentActionsRow(accent: accent)
        } else {
            HStack(spacing: 8) {
                Button {
                    appState.cancelCapture()
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VociColor.textPri)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(VociColor.border, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .keyboardShortcut(.cancelAction)

                Button {
                    appState.startCapture()
                } label: {
                    Text("Try again")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(accent.solid)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
    }

    /// Shown instead of the usual Dismiss/Try again pair when `appState.pendingServerConsent` —
    /// on-device recognition failed because Dictation is off. Offers the private fix (enable
    /// Dictation) alongside the explicit-consent escape hatch (Apple's servers); the warning copy
    /// itself lives in `AppState.captureErrorDetail`, surfaced above by `leftHint`.
    private func dictationConsentActionsRow(accent: Accent) -> some View {
        VStack(spacing: 8) {
            Button {
                appState.openDictationSettings()
            } label: {
                Text("Open Dictation Settings")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(accent.solid)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .keyboardShortcut(.defaultAction)

            Button {
                appState.useServerRecognition()
            } label: {
                Text("Use Apple servers instead (sends audio online)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VociColor.destruct)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(VociColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(.top, 10)
    }

    /// Shown instead of Dismiss/Try again when `appState.pendingCloudConsent` — the ONE-TIME
    /// cloud-parse privacy opt-in (T024): the explanatory copy itself lives in
    /// `AppState.captureErrorDetail` (surfaced above by `leftHint`), making clear that only TEXT
    /// (never audio) would leave the device. Default action (Enter) is the privacy-preserving
    /// decline, matching constitution I's on-device-first bias when the user doesn't read closely.
    private func cloudConsentActionsRow(accent: Accent) -> some View {
        VStack(spacing: 8) {
            Button {
                appState.resolveCloudConsent(allow: false)
            } label: {
                Text("Keep parsing on-device only")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(accent.solid)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .keyboardShortcut(.defaultAction)

            Button {
                appState.resolveCloudConsent(allow: true)
            } label: {
                Text("Allow cloud parsing (sends this text online)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VociColor.textSec)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(VociColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(.top, 10)
    }
}

// MARK: - Private subviews

/// Tiny mono key chip — local to the popover (distinct from `Components.swift`'s accent-aware
/// `KeyBadge`; this one is always the neutral "Esc" style from the JSX `Kbd`).
private struct Kbd: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.65))
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A dismissible confirm-card attribute/condition chip (T024). Solid border for confident/present
/// values; dashed border + a leading "?" for uncertain (<0.7) values pending an explicit tap to
/// accept — tapping the body of an uncertain, not-yet-accepted chip accepts it (constitution II:
/// never silently committed). The trailing "x" always dismisses (removes) the attribute from what
/// gets saved — a one-way action; there's no undo affordance within a confirm session (the chip
/// simply stops rendering once its backing `AppState` state says "dismissed"/"resolved-away").
private struct Chip: View {
    let label: String
    var uncertain: Bool = false
    var accepted: Bool = false
    var onAccept: (() -> Void)?
    var onDismiss: () -> Void

    private var showsDashed: Bool { uncertain && !accepted }

    var body: some View {
        HStack(spacing: 5) {
            if showsDashed {
                Text("?").font(.system(size: 10, weight: .bold))
            }
            Text(label)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onDismiss) {
                VocIcon(.x, size: 8, color: VociColor.textMut)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(showsDashed ? VociColor.textSec : VociColor.textPri)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(showsDashed ? Color.clear : Color.white.opacity(0.06))
        .overlay(
            Capsule().strokeBorder(
                showsDashed ? VociColor.textMut : VociColor.border,
                style: StrokeStyle(lineWidth: 0.5, dash: showsDashed ? [3, 2] : [])
            )
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            if showsDashed { onAccept?() }
        }
    }
}

/// Left-to-right wrapping row for the confirm card's chip set — a fixed `HStack` would clip or
/// squeeze chips once several attributes are present on the fixed 380pt-wide popover. `Layout`
/// has been available since macOS 13, well within this project's macOS 14 floor.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : x
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Expanding-ring pulse behind the "Listening…" dot, approximating the JSX `voci-pulse` keyframe
/// box-shadow animation with a scaling/fading ring overlay.
private struct PulsingDot: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(VociColor.high)
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(VociColor.high, lineWidth: 2)
                    .scaleEffect(expanded ? 2.4 : 1)
                    .opacity(expanded ? 0 : 0.7)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}

/// Hard on/off caret blink (JSX `voci-caret` uses `steps(2, start)`, i.e. no easing/cross-fade),
/// driven by a periodic `TimelineView` tick rather than an interpolated SwiftUI animation so the
/// transition stays a hard cut.
private struct BlinkingCaret: View {
    let color: Color
    private let interval: TimeInterval = 0.45

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let on = Int(elapsed / interval) % 2 == 0
            Rectangle()
                .fill(color)
                .frame(width: 2, height: 16)
                .opacity(on ? 1 : 0)
        }
    }
}

#Preview("Recording") {
    let state = AppState()
    state.captureState = .recording
    state.liveTranscript = "Customer call with Acme tomorrow at 2pm"
    return PopoverView()
        .environment(state)
        .padding(40)
        .background(VociColor.bg)
}

#Preview("Parsed") {
    let state = AppState()
    state.captureState = .parsed
    state.confirmDrafts = [
        // Field order follows the contract's declared order (Swift's synthesized memberwise init
        // requires exact declaration order at the call site) — every optional passed explicitly
        // since the contract text doesn't show `= nil` defaults on the struct itself.
        ConfirmDraft(task: ParsedTask(
            title: "Customer call — Acme onboarding feedback",
            notes: "Customer call with Acme tomorrow at 2pm about onboarding feedback, high priority",
            deadline: ParsedValue(value: Date().addingTimeInterval(86_400), confidence: 0.92),
            estimateMinutes: ParsedValue(value: 30, confidence: 0.6),
            priority: ParsedValue(value: 1, confidence: 0.95),
            reminderOverride: nil,
            recurrence: nil,
            kind: .task,
            conditions: [.taskDone(titleQuery: "finish the onboarding deck", confidence: 0.4)],
            subtasks: [],
            followUpReview: false,
            sourceTranscript: "Customer call with Acme tomorrow at 2pm about onboarding feedback, high priority"
        ))
    ]
    return PopoverView()
        .environment(state)
        .padding(40)
        .background(VociColor.bg)
}
