// Sources/Views/PopoverView.swift — 5-state quick-capture popover (spec §4/§5, voci-popover.jsx)
import SwiftUI

/// Ported from `design/voci-popover.jsx`'s `VociPopover`, driven entirely by
/// `appState.captureState` (`.idle/.recording/.parsing/.parsed/.saving/.done/.error`) instead of
/// the JSX's local/controlled `state` prop. Sizes itself to a fixed 380pt width internally, so
/// callers (the popover-hosting window/`NSPopover`, wired in Phase 3) just place this view.
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
            }

            if showParsedCard, let parsed = appState.parsed {
                parsedCard(parsed)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showActions {
                actionsRow(accent: accent)
            }

            if appState.captureState == .error {
                errorActionsRow(accent: accent)
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
        .animation(.easeOut(duration: 0.16), value: appState.captureState)
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
        appState.captureState == .parsed || appState.captureState == .saving || appState.captureState == .done
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
        case .parsing:
            Text("Parsing with AI…").foregroundStyle(accent.solid)
        case .parsed:
            Text("Looks right? Hit return.").foregroundStyle(VociColor.textMut)
        case .saving:
            Text("Saving…").foregroundStyle(accent.solid)
        case .done:
            Text("Saved").foregroundStyle(VociColor.done)
        case .error:
            Text(appState.captureErrorDetail ?? "Didn't catch that.")
                .foregroundStyle(VociColor.destruct)
                .lineLimit(2)
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
                    case .error:
                        Text("Try again")
                            .font(.system(size: 13))
                            .foregroundStyle(VociColor.destruct)
                    default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
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

    /// While `.recording`, the live streamed transcript from `SpeechCapture`. Otherwise, a
    /// "parsed-derived sentence" (there is no separate raw-transcript field kept past recording —
    /// `ParsedTask` doesn't carry the original sentence — so the parsed title stands in for it,
    /// shown muted, matching the JSX's non-recording transcript styling).
    private var transcriptText: String {
        if appState.captureState == .recording {
            return appState.liveTranscript
        }
        return appState.parsed?.title ?? appState.liveTranscript
    }

    // MARK: - Parsed card

    private func parsedCard(_ parsed: ParsedTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ParseRow(label: "Task") {
                Text(parsed.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(VociColor.textPri)
            }
            ParseRow(label: "When") {
                TimeBadge(parsed.when)
            }
            ParseRow(label: "Priority") {
                PriorityBadge(parsed.priority)
            }
            ParseRow(label: "Context") {
                HStack(spacing: 6) {
                    Circle().fill(VociColor.textMut).frame(width: 5, height: 5)
                    Text(contextLine(parsed))
                        .font(.system(size: 12.5))
                        .foregroundStyle(VociColor.textSec)
                }
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

    /// "\(context) · \(duration)" per the JSX `ParseRow` Context row. `HeuristicNLParser` never
    /// currently fills `context` (see `NLParser.swift`), so this degrades gracefully: duration
    /// alone, or an em dash if both are missing, rather than a dangling "· ".
    private func contextLine(_ parsed: ParsedTask) -> String {
        var parts: [String] = []
        if let context = parsed.context, !context.isEmpty { parts.append(context) }
        if let minutes = parsed.durationMinutes, minutes > 0 { parts.append(formattedDuration(minutes)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
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
                            Text("Save task")
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

    // MARK: - Error retry

    @ViewBuilder
    private func errorActionsRow(accent: Accent) -> some View {
        if appState.pendingServerConsent {
            dictationConsentActionsRow(accent: accent)
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

/// "Task/When/Priority/Context" label+value row, ported from the JSX `ParseRow`
/// (`gridTemplateColumns: '64px 1fr'`).
private struct ParseRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.735) // 0.07em at 10.5pt
                .foregroundStyle(VociColor.textMut)
                .frame(width: 64, alignment: .leading)
            content
            Spacer(minLength: 0)
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
    state.parsed = ParsedTask(
        title: "Customer call — Acme onboarding feedback",
        when: "Tomorrow · 2:00 PM",
        priority: .high,
        durationMinutes: 30,
        context: "Created in Cursor"
    )
    return PopoverView()
        .environment(state)
        .padding(40)
        .background(VociColor.bg)
}
