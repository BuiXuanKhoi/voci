// Sources/Views/PopoverView.swift — 5-state quick-capture popover (spec §4/§5, volar-popover.jsx)
import SwiftUI
// T074: `TaskConflict` (contract C, `VolarCore/Sources/VolarCore/ConflictCheck.swift`, sibling-owned
// — not yet landed) is the only VolarCore symbol this file needs directly.
import VolarCore

/// Ported from `design/volar-popover.jsx`'s `VolarPopover`, driven entirely by
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

            // Studio Dark: this inner group is the popover's one lit thing — the task actively
            // being captured/confirmed — so it (and only it) sits inside the warm spotlight pool.
            // `hintRow`/`errorActionsRow` stay outside, same as `menubar-now.html`'s `.pop-head`/
            // `.dock` sitting outside `.stage`. `showTranscript`'s condition (non-idle, non-error)
            // doubles as "is there a NOW thing to light right now".
            VStack(alignment: .leading, spacing: 0) {
                waveformSection(accent: accent)

                if showTranscript {
                    transcriptSection()
                        .transition(.opacity)
                }

                if showParsedCard {
                    parsedCard()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if showVoiceDoneCard {
                    voiceDoneCard(accent: accent)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if showActions {
                    actionsRow(accent: accent)
                        .transition(.opacity)
                }
            }
            .volarSpotlight(isActive: showTranscript)

            if appState.captureState == .error {
                errorActionsRow(accent: accent)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: width)
        .volarGlass(level: .heavy, cornerRadius: 18)
        .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 24)
        .scaleEffect(mounted ? 1 : 0.96)
        .opacity(mounted ? 1 : 0)
        .animation(VolarMotion.state, value: appState.captureState)
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
        !showVoiceDoneCard
            && (appState.captureState == .parsed || appState.captureState == .saving || appState.captureState == .done)
            && !appState.confirmDrafts.isEmpty
    }

    private var showActions: Bool {
        !showVoiceDoneCard && (appState.captureState == .parsed || appState.captureState == .saving)
    }

    /// T036: a voice-done confirm (one-tap/disambiguation) or "no matching task" row is pending —
    /// mutually exclusive with the normal parsed-task confirm card / its Cancel+Save actions row,
    /// which render their own controls instead (`voiceDoneCard(accent:)`).
    private var showVoiceDoneCard: Bool {
        appState.voiceDoneConfirm != nil || appState.voiceDoneNoMatchTranscript != nil
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
            .foregroundStyle(VolarColor.textMut)
        }
        .font(.system(size: 11.5))
        // FIX D: the hint row above promises "Esc cancel", but nothing actually had
        // `.keyboardShortcut(.cancelAction)` wired during `.recording`/`.parsing` — those two
        // states show no Cancel button at all (`actionsRow`/`errorActionsRow`'s own Esc-bound
        // Cancel/Dismiss buttons only ever render for `.parsed`/`.saving`/`.error`), so the
        // promised shortcut silently did nothing. A zero-size, invisible button carries the
        // shortcut instead of adding new visible chrome.
        .background(escCancelButton)
    }

    /// FIX D: invisible `.cancelAction`-bound button, mounted only while the hint row's "Esc
    /// cancel" copy has no other Cancel control backing it up.
    @ViewBuilder
    private var escCancelButton: some View {
        if appState.captureState == .recording || appState.captureState == .parsing {
            Button("") { appState.cancelCapture() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func leftHint(accent: Accent) -> some View {
        if let confirm = appState.voiceDoneConfirm {
            Text(confirm.candidates.count == 1 ? "Got it — confirm?" : "A few matches — pick one.")
                .foregroundStyle(VolarColor.textMut)
                .transition(.opacity)
        } else if appState.voiceDoneNoMatchTranscript != nil {
            Text("Didn't find a matching task.")
                .foregroundStyle(VolarColor.reschedule)
                .transition(.opacity)
        } else {
            leftHintByCaptureState(accent: accent)
        }
    }

    @ViewBuilder
    private func leftHintByCaptureState(accent: Accent) -> some View {
        switch appState.captureState {
        case .idle:
            EmptyView()
        case .recording:
            HStack(spacing: 6) {
                PulsingDot(color: accent.solid)
                Text("Listening…")
            }
            .foregroundStyle(VolarColor.textMut)
            .transition(.opacity)
        case .parsing:
            Text("Parsing with AI…").foregroundStyle(accent.solid)
                .transition(.opacity)
        case .parsed:
            Text(appState.confirmDrafts.count > 1 ? "Looks right? Hit return to save all." : "Looks right? Hit return.")
                .foregroundStyle(VolarColor.textMut)
                .transition(.opacity)
        case .saving:
            Text("Saving…").foregroundStyle(accent.solid)
                .transition(.opacity)
        case .done:
            Text("Saved").foregroundStyle(VolarColor.done)
                .transition(.opacity)
        case .error:
            // `lineLimit` widened from the v1 2 lines to 3 — the cloud-consent explanation
            // (T024) runs longer than a typical capture-failure message; unrelated error copy
            // still fits comfortably within 3 lines.
            Text(appState.captureErrorDetail ?? "Didn't catch that.")
                .foregroundStyle(VolarColor.reschedule)
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
                .background(
                    // "Mic" breathing-glow affordance (menubar-now.html `.mic.live`) — active ONLY
                    // while `.recording` (never a resting loop), using the general/cool accent, not
                    // the reserved NOW amber ("nothing else warm").
                    MicBreathingGlow(isActive: appState.captureState == .recording, color: accent.glow)
                )
                .transition(.opacity)
            } else {
                HStack {
                    switch appState.captureState {
                    case .done:
                        ZStack {
                            Circle()
                                .fill(VolarColor.done)
                                .frame(width: 32, height: 32)
                                .shadow(color: VolarColor.done.opacity(0.5), radius: 24)
                            VolarIcon(.check, size: 18, color: VolarColor.bg, weight: .bold)
                        }
                        .transition(.opacity)
                    case .error:
                        // Matches the existing `pendingServerConsent` convention: this generic
                        // "Try again" placeholder is shown for every `.error` state, including
                        // consent prompts — unchanged from the pre-T024 behavior. Recolored off the
                        // destructive-red token onto the calm `reschedule` neutral (no red, anywhere).
                        Text("Try again")
                            .font(.system(size: 13))
                            .foregroundStyle(VolarColor.reschedule)
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
                .foregroundStyle(appState.captureState == .recording ? VolarColor.textPri : VolarColor.textSec)
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
                    Rectangle().fill(VolarColor.border).frame(height: 0.5)
                }
                taskDraftCard(draft, showRemove: appState.confirmDrafts.count > 1, isPrimary: offset == 0)
            }
        }
        .padding(12)
        .background(VolarColor.card)
        .overlay(
            // NOW focus ring — this card is the one thing about to be saved (Enter), so its border
            // takes the reserved amber ring instead of the neutral hairline.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VolarColor.nowRing, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 6)
    }

    /// `isPrimary` (the first draft) is the NOW task — its title carries the one warm accent this
    /// popover uses. Any additional batched drafts (multi-task confirm) stay neutral, so there's
    /// still exactly one lit focal point even when several tasks are being saved together.
    private func taskDraftCard(_ draft: ConfirmDraft, showRemove: Bool, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(draft.task.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isPrimary ? VolarColor.nowAccentSoft : VolarColor.textPri)
                    .lineLimit(3)
                Spacer(minLength: 4)
                if showRemove {
                    Button {
                        appState.removeDraft(draft.id)
                    } label: {
                        VolarIcon(.x, size: 9, color: VolarColor.textMut)
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
                Text(conflictAdvisoryText(conflict))
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.reschedule)
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
                // Deadline is a timer readout — mono instrument face, per foundations.html §05.
                Chip(
                    label: deadline.value.formatted(.dateTime.month().day().hour().minute()),
                    uncertain: deadline.isUncertain,
                    accepted: draft.accepted.contains(.deadline),
                    mono: true,
                    onAccept: { appState.acceptUncertainAttribute(.deadline, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.deadline, forDraft: draft.id) }
                )
            }
            if let estimate = draft.task.estimateMinutes, !draft.dismissed.contains(.estimate) {
                // Estimate is a duration readout — mono instrument face.
                Chip(
                    label: formattedDuration(estimate.value),
                    uncertain: estimate.isUncertain,
                    accepted: draft.accepted.contains(.estimate),
                    mono: true,
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
            Circle().fill(VolarColor.instrumentDim).frame(width: 5, height: 5)
            switch condition {
            case .taskDone(let titleQuery, let confidence):
                taskDoneRow(titleQuery: titleQuery, confidence: confidence, index: index, draft: draft)
            case .afterDate(let date, let confidence):
                Chip(
                    label: "After \(date.formatted(.dateTime.month().day()))",
                    uncertain: confidence < 0.7,
                    accepted: draft.acceptedConditions.contains(index),
                    mono: true,
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
        // FIX C: used to also require `confidence >= 0.7`, so an explicit LOW-confidence picker
        // choice (`resolveTaskDone`, constitution II's whole reason for existing) rendered no
        // feedback at all — the resolved chip only ever showed for the auto-resolved (>=0.7) path.
        // `draft.resolvedTaskDone[index]` alone is the correct gate: it's populated by BOTH
        // `preResolveConditions` (confident auto-match) AND the user's own explicit picker tap
        // (`AppState.resolveTaskDone`), and an unresolved condition is simply absent from it either
        // way (falls through to the picker below, unchanged).
        if let resolvedID = draft.resolvedTaskDone[index] {
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
                .foregroundStyle(VolarColor.instrument.opacity(0.85))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .overlay(
                    Capsule().strokeBorder(VolarColor.instrumentDim, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                appState.dismissCondition(at: index, forDraft: draft.id)
            } label: {
                VolarIcon(.x, size: 9, color: VolarColor.textMut)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Voice-done confirm card (T036, contract A `VoiceDoneIntent`/`VoiceMatch`)

    /// Same card shell as `parsedCard()` (Studio Dark card background + the reserved NOW ring —
    /// this is, like the parsed-task card, the one thing about to be acted on) but a completely
    /// different body: a one-tap/one-word confirm for a single confident candidate, a bounded
    /// disambiguation list for several, or the "no matching task" state (constitution II: state
    /// zero-match, never guess — and never silently fall back to new-task capture without asking).
    @ViewBuilder
    private func voiceDoneCard(accent: Accent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let confirm = appState.voiceDoneConfirm {
                voiceDoneConfirmContent(confirm, accent: accent)
            } else if appState.voiceDoneNoMatchTranscript != nil {
                voiceDoneNoMatchContent(accent: accent)
            }
        }
        .padding(12)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VolarColor.nowRing, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 6)
    }

    /// One confident candidate -> a single "Yes — <title>" one-tap/one-word button (glance-and-
    /// dismiss). Several -> a bounded (`prefix(10)`, matching the defensive cap already applied
    /// when `AppState.presentVoiceDoneConfirm` constructs this) tappable list — constitution II's
    /// disambiguation requirement, never an auto-pick.
    @ViewBuilder
    private func voiceDoneConfirmContent(_ confirm: VoiceDoneConfirm, accent: Accent) -> some View {
        Text(voiceDoneQuestion(confirm))
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(VolarColor.nowAccentSoft)
            .lineLimit(2)

        if confirm.candidates.count == 1, let only = confirm.candidates.first {
            HStack(spacing: 8) {
                voiceDoneDismissButton
                voiceDoneConfirmButton(title: voiceDoneOneTapLabel(confirm.action, title: only.title), accent: accent) {
                    appState.confirmVoiceDone(taskId: only.taskId)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(confirm.candidates.prefix(10), id: \.taskId) { match in
                    Button {
                        appState.confirmVoiceDone(taskId: match.taskId)
                    } label: {
                        Text(match.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(VolarColor.textPri)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                    }
                    .buttonStyle(.plain)
                    .background(VolarColor.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(VolarColor.border, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(.top, 2)
            voiceDoneDismissButton
        }
    }

    private func voiceDoneQuestion(_ confirm: VoiceDoneConfirm) -> String {
        // T042: `.delegate` extends this frozen-adjacent 2-case ternary into a proper switch — see
        // `VoiceDoneAction`'s doc comment (AppState.swift) for why delegation reuses this same card.
        let verb: String
        switch confirm.action {
        case .complete: verb = "Mark done"
        case .clearExternal: verb = "Clear"
        case .delegate: verb = "Hand off to Claude"
        }
        if confirm.candidates.count == 1 {
            return "\(verb): \u{201C}\(confirm.candidates[0].title)\u{201D}?"
        }
        switch confirm.action {
        case .complete: return "Which task is done?"
        case .clearExternal: return "Which one cleared?"
        case .delegate: return "Which task did you hand off?"
        }
    }

    /// One-tap confirm button label — `.delegate` always has exactly one candidate (`AppState.
    /// presentDelegationConfirm` only ever targets the current `activeTask`), so this branch is the
    /// one that actually renders in practice; the multi-candidate list below still falls back to
    /// each candidate's own title for `.complete`/`.clearExternal`.
    private func voiceDoneOneTapLabel(_ action: VoiceDoneAction, title: String) -> String {
        switch action {
        case .complete, .clearExternal: return "Yes — \(title)"
        case .delegate: return "Yes — hand off"
        }
    }

    /// Zero candidates but a done/clear phrase was clearly detected — states it plainly (no red/
    /// shame styling, FR-036) and offers the explicit capture-instead escape hatch, never a guess.
    @ViewBuilder
    private func voiceDoneNoMatchContent(accent: Accent) -> some View {
        Text("Didn't find a matching task for that.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(VolarColor.textSec)
            .lineLimit(2)
        HStack(spacing: 8) {
            voiceDoneDismissButton
            voiceDoneConfirmButton(title: "Capture as new task instead", accent: accent) {
                appState.captureVoiceDoneAsNewTask()
            }
        }
    }

    /// Accent-solid one-word/one-tap affirmative — matches `actionsRow`'s Save button styling
    /// (Studio Dark) so this card reads as the same family as the normal confirm card.
    private func voiceDoneConfirmButton(title: String, accent: Accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 34)
        }
        .buttonStyle(.plain)
        .background(accent.solid)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: accent.glow, radius: 10, x: 0, y: 4)
        .keyboardShortcut(.defaultAction)
    }

    /// Neutral "not this" / cancel — matches `actionsRow`'s Cancel button styling exactly.
    private var voiceDoneDismissButton: some View {
        Button {
            appState.dismissVoiceDoneConfirm()
        } label: {
            Text("Not this")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 14)
                .frame(height: 34)
        }
        .buttonStyle(.plain)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .keyboardShortcut(.cancelAction)
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
                    .foregroundStyle(VolarColor.textPri)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(VolarColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
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
                        .foregroundStyle(VolarColor.textPri)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(VolarColor.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(VolarColor.border, lineWidth: 0.5)
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
                    .foregroundStyle(VolarColor.reschedule)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(VolarColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
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
                    .foregroundStyle(VolarColor.textSec)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(VolarColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
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
            .foregroundStyle(VolarColor.textSec)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(VolarColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
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
    /// NEW — marks this chip as an "instrument readout" (a timer/estimate value, not a category)
    /// per foundations.html §05: renders `label` in `Font.volarMono`, tinted `.instrument` (cool),
    /// never the reserved NOW amber. Confidence styling (dashed border/"?" glyph) still wins when
    /// the value is uncertain — mono only changes the font/base color, not the accept affordance.
    var mono: Bool = false
    var onAccept: (() -> Void)?
    var onDismiss: () -> Void

    private var showsDashed: Bool { uncertain && !accepted }

    var body: some View {
        HStack(spacing: 5) {
            if showsDashed {
                Text("?").font(.system(size: 10, weight: .bold))
            }
            Text(label)
                .font(mono ? Font.volarMono(size: 11.5, weight: .medium) : .system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onDismiss) {
                VolarIcon(.x, size: 8, color: VolarColor.textMut)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(showsDashed ? VolarColor.textSec : (mono ? VolarColor.instrument : VolarColor.textPri))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(showsDashed ? Color.clear : (mono ? VolarColor.instrumentDim.opacity(0.16) : VolarColor.card))
        .overlay(
            Capsule().strokeBorder(
                showsDashed ? VolarColor.textMut : (mono ? VolarColor.instrumentDim : VolarColor.border),
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

/// Expanding-ring pulse behind the "Listening…" dot, approximating the JSX `volar-pulse` keyframe
/// box-shadow animation with a scaling/fading ring overlay.
private struct PulsingDot: View {
    /// Was hardcoded to `VolarColor.high` (a priority-badge color, not a listening indicator) —
    /// now takes the caller's accent so it stays the general/cool instrument color, never a warm
    /// tone that could compete with the reserved NOW amber.
    var color: Color = VolarColor.instrument
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(color, lineWidth: 2)
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

/// Soft radial "breathing" glow behind the waveform — mirrors `menubar-now.html`'s `.mic.live`
/// breathing box-shadow, active ONLY while `isActive` (driven by `appState.captureState ==
/// .recording`, never a resting loop: like `PulsingDot`, the animation is only ever started while
/// this view is mounted, and SwiftUI tears the `withAnimation`/`repeatForever` down the moment the
/// parent's `if`/state branch removes it). Respects Reduce Motion by rendering a static glow
/// instead of animating. UNVERIFIED: not rendered/build-checked on this machine (Windows, no Xcode).
private struct MicBreathingGlow: View {
    let isActive: Bool
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Group {
            if isActive {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color)
                    .opacity(reduceMotion ? 0.6 : (breathing ? 1 : 0.5))
                    .blur(radius: 18)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard isActive, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

/// Hard on/off caret blink (JSX `volar-caret` uses `steps(2, start)`, i.e. no easing/cross-fade),
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
        .background(VolarColor.bg)
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
        .background(VolarColor.bg)
}
