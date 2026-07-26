// Sources/Views/CaptureSheet.swift — 5-state voice-capture bottom-sheet CONTENT (plan §2.2, T2).
//
// Behavior ported 1:1 from `Volar/Sources/Views/PopoverView.swift` (macOS popover, READ-ONLY
// reference) — same `appState.captureState` state machine, same `ConfirmDraft` chip accept/
// dismiss interaction, same voice-done confirm card, same server/cloud consent rows. Form
// (layout) ported from `design/volar-mobile.jsx`'s `MobileVoiceSheet` — centered status pill, big
// waveform, centered transcript, Cancel/Save action pair. This view renders CONTENT ONLY:
// `RootTabView` (agent A2) owns `.sheet(...)`/`.presentationDetents`/`.presentationDragIndicator`/
// `.presentationBackground` — this file never calls those on itself.
//
// Tap-to-toggle capture itself lives in `MicFAB.swift`; this file only reacts to
// `appState.captureState`, never starts/stops capture on its own.
import SwiftUI
// `VolarCore.TaskConflict` (contract C) — the only VolarCore symbol this file needs directly,
// same as `PopoverView`.
import VolarCore

struct CaptureSheet: View {
    @Environment(AppState.self) private var appState: AppState

    var body: some View {
        let accent = appState.accent.accent

        ScrollView {
            VStack(alignment: .center, spacing: 0) {
                grabber

                if appState.captureState == .error {
                    errorHeader()
                } else {
                    statusPill(accent: accent)
                        .padding(.bottom, 18)
                }

                waveformOrCheck(accent: accent)

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

                if appState.captureState == .error {
                    errorActionsRow(accent: accent)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, IOSMetrics.screenPadH)
            .padding(.top, 14)
            // Generous home-indicator clearance — the sheet has no system nav bar to absorb it.
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .background(sheetBackground)
        .animation(VolarMotion.state, value: appState.captureState)
    }

    // MARK: - Chrome

    private var grabber: some View {
        Capsule()
            .fill(VolarColor.veil(0.20))
            .frame(width: 38, height: 5)
            .padding(.bottom, 14)
            .accessibilityHidden(true)
    }

    /// Top-rounded (`IOSMetrics.sheetRadius`) glass fill — bottom stays flush with the sheet edge,
    /// unlike `Shared/Design/Glass.swift`'s `volarGlass()` which rounds all four corners (wrong
    /// for a bottom sheet). Same material/tint/opacity formula as `GlassBackground` (plan §4.2:
    /// "đúng công thức GlassBackground sẵn có, chỉ đổi chỗ dùng"), just clipped to only the top
    /// two corners.
    private var sheetBackground: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: IOSMetrics.sheetRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: IOSMetrics.sheetRadius,
            style: .continuous
        )
        return shape
            .fill(appState.glass.material)
            .overlay(shape.fill(VolarColor.bg.opacity(appState.glass.bgOpacity)))
            .overlay(shape.stroke(VolarColor.borderHi, lineWidth: 0.5))
            .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Visibility (mirrors `PopoverView`'s `showWave`/`showTranscript`/`showParsedCard`/`showActions`)

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

    private var showVoiceDoneCard: Bool {
        appState.voiceDoneConfirm != nil || appState.voiceDoneNoMatchTranscript != nil
    }

    // MARK: - Status pill (non-error states) — `MobileVoiceSheet`'s centered capsule

    @ViewBuilder
    private func statusPill(accent: Accent) -> some View {
        if let confirm = appState.voiceDoneConfirm {
            pill(
                text: confirm.candidates.count == 1 ? "Got it — confirm?" : "A few matches — pick one.",
                foreground: VolarColor.textSec, background: VolarColor.veil(0.08)
            )
        } else if appState.voiceDoneNoMatchTranscript != nil {
            pill(text: "Didn't find a matching task.", foreground: VolarColor.reschedule, background: VolarColor.veil(0.08))
        } else {
            switch appState.captureState {
            case .idle:
                EmptyView()
            case .recording:
                pill(dot: true, dotColor: accent.solid, text: "Listening…", foreground: accent.solid, background: accent.surface)
            case .parsing:
                pill(text: "Parsing with AI…", foreground: accent.solid, background: accent.surface)
            case .parsed:
                pill(text: "Confirm or edit", foreground: accent.solid, background: accent.surface)
            case .saving:
                pill(text: "Saving…", foreground: accent.solid, background: accent.surface)
            case .done:
                // Sage `VolarColor.done`, NOT mint — mint is reserved for the NOW task only.
                pill(text: "Saved", foreground: VolarColor.done, background: VolarColor.done.opacity(0.14))
            case .error:
                EmptyView() // handled by `errorHeader()` instead
            }
        }
    }

    private func pill(dot: Bool = false, dotColor: Color = .clear, text: String, foreground: Color, background: Color) -> some View {
        HStack(spacing: 8) {
            if dot {
                PulsingDot(color: dotColor)
            }
            Text(text)
                .font(IOSMetrics.caption)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(background)
        .clipShape(Capsule())
        .transition(.opacity)
    }

    // MARK: - Error header (replaces the status pill while `.error`)

    /// No colored pill for `.error` — the consent copy (`pendingServerConsent`/
    /// `pendingCloudConsent`) runs several sentences long (`AppState.captureErrorDetail`), which
    /// doesn't fit a capsule. Consolidates `PopoverView.leftHintByCaptureState`'s `.error` text
    /// branch and its waveform-section "Try again" placeholder into one block.
    private func errorHeader() -> some View {
        Text(appState.captureErrorDetail ?? "Didn't catch that.")
            .font(IOSMetrics.caption)
            .foregroundStyle(VolarColor.reschedule)
            .multilineTextAlignment(.center)
            .lineLimit(6)
            .padding(.bottom, 18)
    }

    // MARK: - Waveform / done check

    @ViewBuilder
    private func waveformOrCheck(accent: Accent) -> some View {
        if showWave {
            Waveform(
                active: appState.captureState == .recording,
                color: accent.solid,
                glow: accent.glow,
                bars: 28,
                height: 64
            )
            .transition(.opacity)
        } else if appState.captureState == .done {
            ZStack {
                Circle()
                    .fill(VolarColor.done)
                    .frame(width: 56, height: 56)
                    .shadow(color: VolarColor.done.opacity(0.5), radius: 24)
                VolarIcon(.check, size: 26, color: VolarColor.bg, weight: .bold)
            }
            .padding(.vertical, 4)
            .transition(.opacity)
        }
    }

    // MARK: - Transcript

    private func transcriptSection() -> some View {
        HStack(alignment: .top, spacing: 2) {
            Text(transcriptText)
                .font(.volar(size: 18))
                .multilineTextAlignment(.center)
                .foregroundStyle(appState.captureState == .recording ? VolarColor.textPri : VolarColor.textSec)
            if appState.captureState == .recording {
                BlinkingCaret(color: appState.accent.accent.solid)
            }
        }
        .frame(minHeight: 44, maxWidth: .infinity, alignment: .center)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Same fallback as `PopoverView.transcriptText`: live transcript while `.recording`, else the
    /// first confirmed draft's title (+N more for a batch).
    private var transcriptText: String {
        if appState.captureState == .recording {
            return appState.liveTranscript
        }
        guard let first = appState.confirmDrafts.first else { return appState.liveTranscript }
        let extra = appState.confirmDrafts.count - 1
        return extra > 0 ? "\(first.task.title)  +\(extra) more" : first.task.title
    }

    // MARK: - Parsed card

    private func parsedCard() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(appState.confirmDrafts.enumerated()), id: \.element.id) { offset, draft in
                if offset > 0 {
                    Rectangle().fill(VolarColor.border).frame(height: 0.5)
                }
                taskDraftCard(draft, showRemove: appState.confirmDrafts.count > 1, isPrimary: offset == 0)
            }
        }
        .padding(IOSMetrics.cardPadH)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: IOSMetrics.cardRadius, style: .continuous)
                .stroke(VolarColor.nowRing, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: IOSMetrics.cardRadius, style: .continuous))
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `isPrimary` (the first draft) carries the one warm-lit title (`nowAccentSoft`) — matches
    /// `PopoverView.taskDraftCard`'s "exactly one lit focal point even in a multi-task confirm" rule.
    private func taskDraftCard(_ draft: ConfirmDraft, showRemove: Bool, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(draft.task.title)
                    .font(IOSMetrics.nowTitle)
                    .foregroundStyle(isPrimary ? VolarColor.nowAccentSoft : VolarColor.textPri)
                    .lineLimit(3)
                Spacer(minLength: 4)
                if showRemove {
                    removeButton { appState.removeDraft(draft.id) }
                }
            }
            attributeChips(draft)
            conditionRows(draft)
            conflictAdvisoryRow(draft)
        }
    }

    /// AT MOST ONE calm advisory line, never blocking Save — mirrors
    /// `PopoverView.conflictAdvisoryRow` exactly (constitution II / FR-036: no red, no dialog).
    @ViewBuilder
    private func conflictAdvisoryRow(_ draft: ConfirmDraft) -> some View {
        if let conflict = draft.conflicts.first, !draft.conflictDismissed {
            HStack(alignment: .top, spacing: 6) {
                Text(conflictAdvisoryText(conflict))
                    .font(IOSMetrics.meta)
                    .foregroundStyle(VolarColor.reschedule)
                    .lineLimit(2)
                Spacer(minLength: 4)
            }
            .padding(.top, 2)
            .frame(minHeight: IOSMetrics.minTouch, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                appState.dismissConflictAdvisory(forDraft: draft.id)
            }
        }
    }

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

    /// Every PRESENT attribute renders as a dismissible chip; absent ones render nothing. Mirrors
    /// `PopoverView.attributeChips` field-for-field.
    @ViewBuilder
    private func attributeChips(_ draft: ConfirmDraft) -> some View {
        FlowLayout(spacing: 8) {
            if let deadline = draft.task.deadline, !draft.dismissed.contains(.deadline) {
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
            if draft.task.kind != .task, !draft.dismissed.contains(.kind) {
                Chip(
                    label: kindLabel(draft.task.kind),
                    uncertain: false,
                    accepted: true,
                    onAccept: nil,
                    onDismiss: { appState.dismissAttribute(.kind, forDraft: draft.id) }
                )
            }
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

    @ViewBuilder
    private func conditionRows(_ draft: ConfirmDraft) -> some View {
        let visible = draft.task.conditions.indices.filter { !draft.dismissedConditions.contains($0) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
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

    /// `.taskDone`: if already resolved (confident auto-match OR explicit picker choice), a solid
    /// chip naming the matched task; otherwise the constitution-II picker (never auto-attach below
    /// 0.7 confidence). Mirrors `PopoverView.taskDoneRow`'s `resolvedTaskDone`-only gate exactly.
    @ViewBuilder
    private func taskDoneRow(titleQuery: String, confidence: Double, index: Int, draft: ConfirmDraft) -> some View {
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

    /// Native `Menu` picker for a `.taskDone` condition below 0.7 confidence. `.menuStyle` is
    /// intentionally left at the default (`.automatic`) rather than `PopoverView`'s
    /// `.borderlessButton` — that style is macOS/Catalyst-only and doesn't exist on iOS.
    private func dependencyPicker(titleQuery: String, index: Int, draft: ConfirmDraft) -> some View {
        HStack(spacing: 6) {
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
                    Text("?").font(.system(size: 11, weight: .bold))
                    Text("After: \u{201C}\(titleQuery)\u{201D}")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(IOSMetrics.meta)
                .foregroundStyle(VolarColor.instrument.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(minHeight: IOSMetrics.minTouch)
                .overlay(
                    Capsule().strokeBorder(VolarColor.instrumentDim, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                )
            }
            .contentShape(Rectangle())

            removeButton { appState.dismissCondition(at: index, forDraft: draft.id) }
        }
    }

    /// Small "x" dismiss control. Tappable area expanded to ~44pt via a negative `contentShape`
    /// inset (`Rectangle().inset(by: -N)`) rather than growing the visible glyph itself — sizing
    /// every chip's dismiss control to a literal 44×44 box would blow out 1:1 layout fidelity to
    /// `PopoverView`'s compact chip row. // UNVERIFIED: `Rectangle().inset(by:)` with a negative
    /// value to enlarge (not shrink) a hit-testing region is a known SwiftUI technique but not
    /// build-verified on this machine (Windows, no Xcode).
    private func removeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VolarIcon(.x, size: 10, color: VolarColor.textMut)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle().inset(by: -14))
    }

    // MARK: - Voice-done confirm card (T036, contract A)

    @ViewBuilder
    private func voiceDoneCard(accent: Accent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let confirm = appState.voiceDoneConfirm {
                voiceDoneConfirmContent(confirm, accent: accent)
            } else if appState.voiceDoneNoMatchTranscript != nil {
                voiceDoneNoMatchContent(accent: accent)
            }
        }
        .padding(IOSMetrics.cardPadH)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: IOSMetrics.cardRadius, style: .continuous)
                .stroke(VolarColor.nowRing, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: IOSMetrics.cardRadius, style: .continuous))
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func voiceDoneConfirmContent(_ confirm: VoiceDoneConfirm, accent: Accent) -> some View {
        Text(voiceDoneQuestion(confirm))
            .font(IOSMetrics.nowTitle)
            .foregroundStyle(VolarColor.nowAccentSoft)
            .lineLimit(2)

        if confirm.candidates.count == 1, let only = confirm.candidates.first {
            HStack(spacing: 10) {
                voiceDoneDismissButton
                voiceDoneConfirmButton(title: voiceDoneOneTapLabel(confirm.action, title: only.title), accent: accent) {
                    appState.confirmVoiceDone(taskId: only.taskId)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(confirm.candidates.prefix(10), id: \.taskId) { match in
                    Button {
                        appState.confirmVoiceDone(taskId: match.taskId)
                    } label: {
                        Text(match.title)
                            .font(IOSMetrics.rowTitle)
                            .foregroundStyle(VolarColor.textPri)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(minHeight: IOSMetrics.minTouch)
                    }
                    .buttonStyle(.plain)
                    .background(VolarColor.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(VolarColor.border, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.top, 2)
            voiceDoneDismissButton
        }
    }

    private func voiceDoneQuestion(_ confirm: VoiceDoneConfirm) -> String {
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

    private func voiceDoneOneTapLabel(_ action: VoiceDoneAction, title: String) -> String {
        switch action {
        case .complete, .clearExternal: return "Yes — \(title)"
        case .delegate: return "Yes — hand off"
        }
    }

    @ViewBuilder
    private func voiceDoneNoMatchContent(accent: Accent) -> some View {
        Text("Didn't find a matching task for that.")
            .font(IOSMetrics.rowTitle)
            .foregroundStyle(VolarColor.textSec)
            .lineLimit(2)
        HStack(spacing: 10) {
            voiceDoneDismissButton
            voiceDoneConfirmButton(title: "Capture as new task instead", accent: accent) {
                appState.captureVoiceDoneAsNewTask()
            }
        }
    }

    private func voiceDoneConfirmButton(title: String, accent: Accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(IOSMetrics.rowTitle)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: IOSMetrics.minTouch)
        }
        .buttonStyle(.plain)
        .background(accent.solid)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VolarColor.veil(0.18), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: accent.glow, radius: 10, x: 0, y: 4)
    }

    private var voiceDoneDismissButton: some View {
        Button {
            appState.dismissVoiceDoneConfirm()
        } label: {
            Text("Not this")
                .font(IOSMetrics.rowTitle)
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 16)
                .frame(minHeight: IOSMetrics.minTouch)
        }
        .buttonStyle(.plain)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Chip label formatting (mirrors `PopoverView`'s private formatters exactly)

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

    /// Mirrors `TaskItem.durationLabel`'s formatting; duplicated (not reached into `TaskItem`)
    /// because `ParsedTask` is a distinct pre-save value type, same rationale as `PopoverView`'s
    /// own copy of this formatter.
    private func formattedDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let mins = minutes % 60
        if mins == 0 { return hours == 1 ? "1 hr" : "\(hours) hrs" }
        return "\(hours)h \(mins)m"
    }

    // MARK: - Actions (parsed / saving) — Cancel + Save task, `MobileVoiceSheet`'s button pair

    private func actionsRow(accent: Accent) -> some View {
        HStack(spacing: 10) {
            Button {
                appState.cancelCapture()
            } label: {
                Text("Cancel")
                    .font(IOSMetrics.rowTitle)
                    .foregroundStyle(VolarColor.textPri)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.plain)
            .background(VolarColor.veil(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                appState.confirmSave()
            } label: {
                Group {
                    if appState.captureState == .saving {
                        Spinner(color: accent.solid, size: 18)
                    } else {
                        Text(saveLabel)
                            .font(IOSMetrics.rowTitle)
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }
            .buttonStyle(.plain)
            .background(appState.captureState == .saving ? accent.surface : accent.solid)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        appState.captureState == .saving ? accent.surface : VolarColor.veil(0.18),
                        lineWidth: 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: appState.captureState == .saving ? .clear : accent.glow, radius: 12, x: 0, y: 6)
            .disabled(appState.captureState == .saving)
        }
        .padding(.top, 14)
    }

    /// "Save task" / "Save 3 tasks" — multi-task confirm still saves the whole batch in one tap.
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
            HStack(spacing: 10) {
                Button {
                    appState.cancelCapture()
                } label: {
                    Text("Dismiss")
                        .font(IOSMetrics.rowTitle)
                        .foregroundStyle(VolarColor.textPri)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.plain)
                .background(VolarColor.veil(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(VolarColor.border, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    appState.startCapture()
                } label: {
                    Text("Try again")
                        .font(IOSMetrics.rowTitle)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.plain)
                .background(accent.solid)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(VolarColor.veil(0.18), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.top, 14)
        }
    }

    /// Dictation-off consent — mirrors `PopoverView.dictationConsentActionsRow`. The button opens
    /// this app's iOS Settings page (`AppState.openDictationSettings()` already branches
    /// `#if os(iOS)` to `UIApplication.openSettingsURLString` — there's no deep link into the
    /// system Dictation pane on iOS the way macOS has one, per that method's doc comment), so the
    /// label reads "Open Settings" rather than the macOS copy's "Open Dictation Settings".
    private func dictationConsentActionsRow(accent: Accent) -> some View {
        VStack(spacing: 10) {
            Button {
                appState.openDictationSettings()
            } label: {
                Text("Open Settings")
                    .font(IOSMetrics.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.plain)
            .background(accent.solid)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(VolarColor.veil(0.18), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                appState.useServerRecognition()
            } label: {
                Text("Use Apple servers instead (sends audio online)")
                    .font(IOSMetrics.meta)
                    .foregroundStyle(VolarColor.reschedule)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: IOSMetrics.minTouch)
            }
            .buttonStyle(.plain)
            .background(VolarColor.veil(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.top, 14)
    }

    /// One-time cloud-parse consent — mirrors `PopoverView.cloudConsentActionsRow` exactly,
    /// including the privacy-preserving decline being the visually primary (filled) button.
    private func cloudConsentActionsRow(accent: Accent) -> some View {
        VStack(spacing: 10) {
            Button {
                appState.resolveCloudConsent(allow: false)
            } label: {
                Text("Keep parsing on-device only")
                    .font(IOSMetrics.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.plain)
            .background(accent.solid)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(VolarColor.veil(0.18), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                appState.resolveCloudConsent(allow: true)
            } label: {
                Text("Allow cloud parsing (sends this text online)")
                    .font(IOSMetrics.meta)
                    .foregroundStyle(VolarColor.textSec)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: IOSMetrics.minTouch)
            }
            .buttonStyle(.plain)
            .background(VolarColor.veil(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.top, 14)
    }
}

// MARK: - Private subviews

/// Dismissible confirm-card attribute/condition chip — ported from `PopoverView`'s private `Chip`.
/// (That type is file-private there, and `PopoverView` compiles into a different app target
/// anyway, so it's redefined here rather than shared.) Same accept/dismiss semantics: tapping an
/// uncertain (<0.7, not-yet-accepted) chip's body accepts it (constitution II — never silently
/// committed); the trailing "x" always dismisses it from what gets saved.
private struct Chip: View {
    let label: String
    var uncertain: Bool = false
    var accepted: Bool = false
    var mono: Bool = false
    var onAccept: (() -> Void)?
    var onDismiss: () -> Void

    private var showsDashed: Bool { uncertain && !accepted }

    var body: some View {
        HStack(spacing: 6) {
            if showsDashed {
                Text("?").font(.system(size: 11, weight: .bold))
            }
            Text(label)
                .font(mono ? Font.volarMono(size: 12.5, weight: .medium) : IOSMetrics.meta)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onDismiss) {
                VolarIcon(.x, size: 9, color: VolarColor.textMut)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle().inset(by: -12))
        }
        .foregroundStyle(showsDashed ? VolarColor.textSec : (mono ? VolarColor.instrument : VolarColor.textPri))
        .padding(.horizontal, 11)
        .frame(height: 30)
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

/// Left-to-right wrapping row for the confirm card's chip set — same technique as
/// `PopoverView`'s own `FlowLayout` (`Layout`, available since iOS 16, inside this feature's iOS
/// 17 floor), redefined here for the same file-private/cross-target reason as `Chip` above.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

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

/// Expanding-ring pulse behind the "Listening…" dot — a BOUNDED, mount-scoped animation: started
/// `onAppear`, and torn down by SwiftUI the instant the parent `if`/switch branch that renders
/// this view stops rendering it (it only ever exists while `.recording`, never as a resting-state
/// loop). Matches `PopoverView.PulsingDot`'s exact technique.
///
/// Self-review note: this DOES use `.repeatForever(autoreverses:)` internally, same as
/// `PopoverView.PulsingDot` on macOS. `Shared/Design/Theme.swift`'s motion doc comment scopes the
/// "never `.repeatForever`" rule to "any MenuBarExtra/NSStatusItem-hosted view" (a process-lifetime
/// concern specific to macOS's menu bar) and to token-level/resting motion — not to a transient
/// indicator that lives only as long as one specific, dismissable sheet state. Called out here
/// explicitly rather than silently reusing the pattern without flagging it.
private struct PulsingDot: View {
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

/// Hard on/off caret blink, driven by a periodic `TimelineView` tick — NOT an interpolated
/// `withAnimation`/`.repeatForever` (this is the technique the task brief specifically asks for).
/// Matches `PopoverView.BlinkingCaret` exactly.
private struct BlinkingCaret: View {
    let color: Color
    private let interval: TimeInterval = 0.45

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let on = Int(elapsed / interval) % 2 == 0
            Rectangle()
                .fill(color)
                .frame(width: 2, height: 18)
                .opacity(on ? 1 : 0)
        }
    }
}

#Preview("Recording") {
    let state = AppState()
    state.captureState = .recording
    state.liveTranscript = "Customer call with Acme tomorrow at 2pm"
    return CaptureSheet()
        .environment(state)
        .background(VolarColor.bg)
}

#Preview("Parsed") {
    let state = AppState()
    state.captureState = .parsed
    state.confirmDrafts = [
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
    return CaptureSheet()
        .environment(state)
        .background(VolarColor.bg)
}
