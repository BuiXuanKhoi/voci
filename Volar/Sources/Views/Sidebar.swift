// Sources/Views/Sidebar.swift — capture button + Focus nav + on-device footer
// Ported from `design/volar-mac.jsx`'s sidebar column.
import SwiftUI

struct Sidebar: View {
    @Environment(AppState.self) private var appState: AppState

    /// Drives the `PaywallView` sheet from the sidebar's own "Pro" CTA (below). Lives here rather
    /// than inside `ProSidebarRow` itself so the sheet is attached once, at the `Sidebar` level —
    /// a `@State` owned by a small subview that gets re-created would lose its presented state.
    @State private var showPaywall = false
    /// The sidebar's own sign-in surface, so the paywall's "Sign in to subscribe" CTA is not a dead
    /// button when the paywall was opened from here (see the `.sheet` pair at the bottom of `body`).
    @State private var showSignInSheet = false
    @State private var pendingSignInAfterPaywall = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(spacing: 0) {
            // Grouped in their own `VStack(spacing: 0)` — identical to being direct children of
            // the outer `VStack` above (same individual paddings, same spacing) — purely so a
            // single `.tourAnchor(.capture)` can cover both the "Tap to speak" button AND the
            // ⌃⌥M key badges together (guided tour, stop 1: `Sources/Views/Tour/*`). Regrouping
            // rather than tagging `captureButton` alone, per that feature's own instruction to
            // prefer covering both over a tighter single-button hole, as long as doing so doesn't
            // shift any existing layout — and it doesn't, since nesting a zero-spacing `VStack`
            // changes nothing about how its children are laid out.
            VStack(spacing: 0) {
                captureButton
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                keyBadgeRow
                    .padding(.bottom, 4)
            }
            .tourAnchor(.capture)

            focusSectionLabel

            // Today/Upcoming/Inbox are LIVE as of 2026-07-27 (port of the Windows reference —
            // SidebarControl.xaml.cs's `ApplyNavRow`/`OnNavRowTapped`). Before that, only Today was
            // real: Upcoming/Inbox rendered hardcoded counts (12/3) and had empty `{}` actions.
            // Membership/counts come from `AppState.upcomingNavCount`/`inboxNavCount`
            // (`Sources/Model/TaskSections.swift`); `active` now reflects `appState.selectedSection`
            // instead of the old `true`/`false` literals.
            // 2026-08-22 (anh Khôi, so với sidebar Linear): ba section giờ là HEADER của nhóm
            // task chứ không còn là nav row nặng. Cụ thể bỏ icon, bỏ count, bỏ thanh accent 2px —
            // chúng làm header hút mắt hơn chính mấy task nằm dưới, tức ngược đúng cái phân cấp
            // Linear dựng ("Workspace ▾" mờ, item con mới là thứ đọc được). Count không mất khỏi
            // app: `TodayView` vẫn đọc `upcomingNavCount`/`inboxNavCount` cho dòng mô tả section.
            VStack(spacing: 8) {
                sectionGroup(.today, "Today", todayPeek)
                sectionGroup(.upcoming, "Upcoming", upcomingPeek)
                sectionGroup(.inbox, "Inbox", inboxPeek)
            }
            .padding(.horizontal, 8)
            .animation(VolarMotion.list, value: collapsed)

            Spacer(minLength: 0)

            // "Pro" sits between the Spacer and the footer, per anh Khôi's ask — its own row, NOT
            // another `SectionHeaderRow` (those switch section; this one has to visually shout, or
            // stay quiet, depending on `accountTier`). `ProSidebarRow` reads `accountTier` itself and
            // picks between a bright upsell CTA and a silent "already Pro" badge — see its doc
            // comment for why those two states must never blend into one.
            ProSidebarRow(isPro: appState.accountTier == .pro) { showPaywall = true }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            onDeviceFooter
                .padding(.horizontal, 10)
        }
        .padding(.bottom, 12)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(VolarColor.border).frame(width: 0.5)
        }
        // `onNeedSignIn` is NOT left at its default no-op here. Purchasing requires a session
        // (`Entitlements.purchase` throws `.notSignedIn`), so a signed-out visitor who opens this
        // paywall lands on its "Sign in to subscribe" CTA — and with the default closure that button
        // does nothing at all. Since the sidebar is now the most prominent way into the paywall, that
        // dead end would be the common path, not an edge case.
        //
        // The handoff goes through `onDismiss` rather than flipping both flags inside the callback:
        // asking SwiftUI to tear down one sheet and present another in the same update routinely
        // drops the second presentation, leaving the user with a paywall that just closes.
        // `pendingSignInAfterPaywall` separates "closed via the CTA" from "closed with the X button",
        // which must open nothing. Mirrors `SettingsView.accountTab`'s pair exactly.
        .sheet(isPresented: $showPaywall, onDismiss: {
            guard pendingSignInAfterPaywall else { return }
            pendingSignInAfterPaywall = false
            showSignInSheet = true
        }) {
            PaywallView(onNeedSignIn: {
                pendingSignInAfterPaywall = true
                showPaywall = false
            })
        }
        .sheet(isPresented: $showSignInSheet) {
            SignInSheet()
        }
    }

    // MARK: - Section peek (anh Khôi chốt 2026-08-20, gợi ý từ sidebar của Notion)
    //
    // Ba task đầu của Upcoming và Inbox hiện thẳng dưới nav row của chúng. CHỈ hai section này,
    // KHÔNG có Today: main column đã dành cả một hero card cho NOW + một row peek cho NEXT +
    // drawer Later, nên lồng thêm Today vào sidebar là hiện đúng mấy task đó hai lần cùng lúc.
    // Cái sidebar peek giải quyết là thứ đang KHUẤT tầm mắt — Upcoming/Inbox chỉ thấy được sau
    // khi đổi section.
    //
    // "Ba task đầu" của mỗi bên không cùng một phép so, và đó là chủ ý:
    //   - Upcoming: sớm nhất trước. `upcomingGroups` đã sắp theo ngày tăng dần nên `flatMap` giữ
    //     nguyên thứ tự đó. Mốc hiển thị lấy từ `TaskSections.upcomingDate`, KHÔNG phải
    //     `TaskItem.timeBadge` — một task hoãn tới thứ Tư (`.afterDate`) không có deadline nào để
    //     `timeBadge` đọc, mà nó vẫn thuộc Upcoming (xem header của TaskSections.swift).
    //   - Inbox: mới capture nhất trước. Inbox theo định nghĩa là task KHÔNG có ngày, nên không có
    //     deadline lẫn rank engine để xếp; `appState.inboxTasks` vốn đã sắp `createdAt` giảm dần.
    //     Cột phải là TUỔI ("3d"), không phải hạn — thứ vừa nói ra không nên chìm mất.

    /// Section nào đang gập. `@State` chứ không `@AppStorage`: gập là thao tác tức thời trong
    /// một phiên làm việc, không phải cấu hình — nhớ qua lần mở app sau chỉ thêm một khoá settings
    /// cho thứ chưa ai đòi.
    @State private var collapsed: Set<NavSection> = []

    /// Header + ba task của một section. Bấm section KHÁC thì chuyển sang nó; bấm lại chính section
    /// đang mở thì gập/mở peek — thay vì tách chevron thành nút riêng 9pt. Một nút phủ trọn hàng
    /// vừa là đích bấm dễ trúng hơn, vừa khỏi lồng Button-trong-Button (đúng luật vùng bấm phải
    /// phủ đúng vùng nhìn thấy — họ bug 2026-08-09 chép trong `SectionHeaderRow`).
    @ViewBuilder
    private func sectionGroup(_ section: NavSection, _ label: String, _ rows: [PeekEntry]) -> some View {
        let isActive = appState.selectedSection == section
        let isCollapsed = collapsed.contains(section)
        VStack(alignment: .leading, spacing: 1) {
            SectionHeaderRow(label: label, active: isActive, collapsed: isCollapsed) {
                if isActive {
                    if isCollapsed { collapsed.remove(section) } else { collapsed.insert(section) }
                } else {
                    appState.selectedSection = section
                    // Chuyển tới một section đang gập mà nó vẫn gập thì cú bấm trông như không ăn.
                    collapsed.remove(section)
                }
            }
            if !isCollapsed {
                peekRows(rows)
            }
        }
    }

    private static let peekLimit = 3

    /// Ba task đầu của Today, THEO ĐÚNG THỨ TỰ ENGINE (`appState.openTasks`) — tức là cùng NOW và
    /// NEXT mà cột chính đang hiện, ở đúng thứ tự đó.
    ///
    /// Lúc đầu Today cố ý KHÔNG có peek (cột chính đã dành hẳn một hero card cho NOW + một row cho
    /// NEXT, nên lồng thêm vào sidebar là hiện cùng mấy task đó hai lần). Anh Khôi lật lại
    /// 2026-08-20: cả ba section đều phải có, cho giống sidebar Notion. Sự trùng lặp đó là có
    /// thật và là cái giá đã biết trước, không phải sót.
    private var todayPeek: [PeekEntry] {
        let now = Date()
        return appState.openTasks.prefix(Self.peekLimit).map { task in
            PeekEntry(
                task: task,
                // `timeBadge` (giờ của hạn) chứ không phải nhãn ngày như Upcoming: mọi thứ trong
                // Today đều là hôm nay, nên ngày không mang thông tin gì, chỉ giờ mới mang.
                trailing: task.timeBadge ?? "",
                tint: DeadlineUrgency.tint(for: task, now: now)
            )
        }
    }

    /// Struct chứ không phải tuple `(task:trailing:)`: `ForEach` cần định danh từng row, mà Swift
    /// KHÔNG cho key path trỏ vào phần tử tuple (`\.task.id` trên một tuple là lỗi compile). Cho nó
    /// `Identifiable` luôn để `ForEach(rows)` khỏi cần tham số `id:`.
    private struct PeekEntry: Identifiable {
        let task: TaskItem
        let trailing: String
        /// `DeadlineUrgency.tint` — `nil` giữ nguyên `textMut` như mọi nhãn phụ khác.
        let tint: Color?
        var id: UUID { task.id }
    }

    private var upcomingPeek: [PeekEntry] {
        // `startOfTomorrow` trong `AppState` là `private`, nên gọi lại chính hàm thuần mà nó gọi,
        // thay vì tự dựng một định nghĩa "sau hôm nay" thứ hai (một nguồn luật, khác chỗ gọi).
        let now = Date()
        let cutoff = TaskSections.startOfTomorrow(now: now, timeZone: .current)
        return appState.upcomingGroups.flatMap(\.tasks).prefix(Self.peekLimit).map { task in
            PeekEntry(
                task: task,
                trailing: Self.upcomingLabel(TaskSections.upcomingDate(task, startOfTomorrow: cutoff)),
                tint: DeadlineUrgency.tint(for: task, now: now)
            )
        }
    }

    private var inboxPeek: [PeekEntry] {
        // Inbox theo định nghĩa không có hạn, nên `tint` luôn `nil` ở đây — vẫn đi qua cùng một
        // hàm thay vì hardcode, để nếu định nghĩa Inbox có đổi thì màu tự đúng theo.
        appState.inboxTasks.prefix(Self.peekLimit).map {
            PeekEntry(
                task: $0,
                trailing: Self.ageLabel($0.createdAt),
                tint: DeadlineUrgency.tint(for: $0, now: Date())
            )
        }
    }

    @ViewBuilder
    private func peekRows(_ rows: [PeekEntry]) -> some View {
        ForEach(rows) { row in
            SectionPeekRow(task: row.task, trailing: row.trailing, tint: row.tint) {
                appState.openDetail(row.task.id)
            }
        }
    }

    /// Cột phải của một row Upcoming, đủ ngắn để sống trong sidebar 220pt: giờ nếu là ngày mai,
    /// thứ trong tuần nếu còn trong tuần này, ngày-tháng nếu xa hơn (lúc đó "Thu" đã mơ hồ).
    private static func upcomingLabel(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        if calendar.isDateInTomorrow(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        return days <= 6
            ? date.formatted(.dateTime.weekday(.abbreviated))
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Tuổi của một capture trong Inbox — "today" cho hôm nay, còn lại "3d".
    private static func ageLabel(_ createdAt: Date, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: createdAt),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        return days <= 0 ? "today" : "\(days)d"
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        if appState.ambient != .none {
            // Was `VolarColor.surface.opacity(0.45)` — a magic number duplicating what
            // `GlassLevel.bgOpacity` already exists to express ("opacity of the ink tint layered
            // over the system material"). Reusing it instead of inventing a second constant.
            Rectangle()
                .fill(appState.glass.material)
                .overlay(VolarColor.surface.opacity(appState.glass.bgOpacity))
        } else {
            VolarColor.surface
        }
    }

    private var captureButton: some View {
        Button {
            // Stays on `toggleCapture()` on purpose. `handleHotkey()` saves a pending confirm card,
            // which is right for a BARE keypress whose meaning has to depend on state — but this
            // button says "Tap to speak", and a button that saves your task when its label offers to
            // listen is a surprise, not a shortcut. Same reasoning keeps the Windows sidebar button
            // on ToggleCaptureAsync (SidebarControl.xaml.cs's OnCaptureButtonClick).
            appState.toggleCapture()
        } label: {
            HStack(spacing: 7) {
                VolarIcon(.mic, size: 13, color: accentColors.solid, weight: .semibold)
                Text(appState.captureState == .recording ? "Tap to stop" : "Tap to speak")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(-0.06)
            }
            .foregroundStyle(accentColors.solid)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
        }
        .buttonStyle(CaptureButtonStyle(accentColor: accentColors.solid))
    }

    private var keyBadgeRow: some View {
        HStack(spacing: 4) {
            KeyBadge("⌃")
            KeyBadge("⌥")
            KeyBadge("M")
        }
        .frame(maxWidth: .infinity)
    }

    // §5.4 (specs/009-light-mode-list-v2/design.md): 11pt/.semibold/uppercase/tracking+0.5/textSec.
    // Was 10.5pt/.medium/textMut (3.4:1, below AA) — textMut is reserved for tertiary labels now,
    // never section headers.
    private var focusSectionLabel: some View {
        Text("Focus")
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(VolarColor.textSec)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    /// Whether speech is ACTUALLY running in the cloud right now — computed the same two-part way
    /// `SettingsView`'s "Groq status" row does (`speechEngineChoice == .groq` + `GroqEngine.isConfigured`,
    /// see `SettingsView.generalTab`), not just the raw picker selection. `AppState.selectedEngine`
    /// silently falls back to on-device whenever Groq is picked but not configured (signed out) — so
    /// checking only `speechEngineChoice == .groq` would have this footer claim "Cloud" for someone
    /// who is, in fact, still running fully on-device. Both conditions must hold.
    ///
    /// This footer used to hardcode "On-device / nothing leaves your Mac" — true when Apple/WhisperKit
    /// is the engine, flatly FALSE since 2026-07-27 now that Groq cloud is the default choice
    /// (`AppState.speechEngineChoice`'s `init` fallback). It sits on every Mac screenshot submitted to
    /// the App Store, so a hardcoded on-device claim while cloud is active would misstate the app's
    /// actual privacy behavior — this computed property is what keeps the label honest.
    private var isCloudSpeechActive: Bool {
        appState.speechEngineChoice == .groq && GroqEngine.isConfigured
    }

    private var onDeviceFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(accentColors.solid).frame(width: 5, height: 5)
                Text(isCloudSpeechActive ? "Cloud" : "On-device")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
            }
            // Cloud branch is deliberately NOT "nothing leaves your Mac" — that sentence is only
            // true on-device. It says what actually happens (audio goes to Volar's recognition
            // service) plus how to opt back out, instead of repeating the on-device promise here.
            Text(isCloudSpeechActive
                 ? "Audio is sent to Volar's speech recognition service to turn it into text. Switch to on-device anytime in Settings."
                 : "Audio is parsed locally. Nothing leaves your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(VolarColor.textSec)
                .lineSpacing(2)
        }
        .padding(10)
        // Was `VolarColor.veil(0.03)`, an ad hoc alpha. §3 has no named token for a static
        // (always-on, non-hover) subtle box, so reusing `cardHover` — same "one low-alpha ink
        // surface" the row hover uses (§5.2) — instead of inventing another one-off constant.
        .background(VolarColor.cardHover)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            // `.strokeBorder`, not `.stroke`: after `.clipShape` above, `.stroke` draws centered
            // on the path and the outer half gets clipped away — the known half-width-border bug.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(VolarColor.border, lineWidth: 0.5)
        )
    }
}

/// Gives the "Tap to speak" capture button a press-down highlight (mirrors the prototype's
/// mousedown/up-driven `holdHint` inset glow) using `ButtonStyle`'s own `isPressed` state, rather
/// than a second overlapping gesture recognizer that could compete with the button's tap.
private struct CaptureButtonStyle: ButtonStyle {
    let accentColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(accentColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                // `.strokeBorder`, not `.stroke` — see `onDeviceFooter` comment above for why.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(accentColor.opacity(configuration.isPressed ? 0.9 : 0.27), lineWidth: configuration.isPressed ? 1 : 0.5)
            )
            .animation(VolarMotion.press, value: configuration.isPressed)
    }
}

/// Header của một nhóm trong sidebar — tên section + chevron gập. Thay cho `SidebarItem` cũ
/// (icon + count + thanh accent 2px): xem chú thích ở `Sidebar.body` cho lý do bỏ cả ba.
/// Vẫn giữ nền `surfaceHi` khi active, vì khác Linear thì ba mục này CHÍNH LÀ điều hướng của app —
/// bỏ nốt dấu hiệu section đang mở là bỏ luôn thứ duy nhất nói cho người dùng biết họ đang ở đâu.
private struct SectionHeaderRow: View {
    let label: String
    let active: Bool
    let collapsed: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                    .tracking(-0.02)
                    .foregroundStyle(active ? VolarColor.textPri : VolarColor.textSec)
                    .lineLimit(1)
                VolarIcon(.chevronDown, size: 9, color: VolarColor.textMut, weight: .semibold)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    // Chevron chỉ mờ đi chứ không biến mất khi không hover: sidebar này không có
                    // chỗ nào khác nói cho người dùng biết nhóm gập được.
                    .opacity(isHovering || collapsed ? 1 : 0.5)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            // BUG FIX 2026-08-09 (anh Khôi báo khi chạy thật: "Upcoming/Inbox bấm hoài mà nó không
            // vào") — giữ nguyên từ `SidebarItem`, cái type mà hàng này thay thế; nhiều file khác
            // trong app trỏ về đây cho lời giải thích đầy đủ. Với `.buttonStyle(.plain)`, SwiftUI
            // chỉ hit-test phần label THỰC SỰ VẼ RA. `Spacer(minLength: 0)` ở trên và hai `.padding`
            // này không vẽ gì cả, nên vùng bấm thật của hàng không phải cả hàng mà là mấy mảnh rời
            // rạc — chữ và chevron — với lỗ thủng ở giữa. Chuyện này khó phát hiện đúng vì cái nền
            // highlight (`.background` ngay dưới) được vẽ ở lớp NGOÀI `Button`, nên hàng TRÔNG như
            // bấm được cả dải trong khi thực tế không. `.contentShape` đặt SAU padding để hình chữ
            // nhật hit-test trùm luôn cả padding, tức đúng bằng vùng nền mà mắt nhìn thấy.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(active ? VolarColor.surfaceHi : (isHovering ? VolarColor.cardHover : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
        .accessibilityLabel(label)
        .accessibilityHint(active
            ? (collapsed ? "Expand section" : "Collapse section")
            : "Show \(label)")
    }
}

/// Một task lồng dưới header Today/Upcoming/Inbox — tên (cắt đuôi) + một cột mono ngắn bên phải.
/// Không phải `TaskRow`: `TaskRow` mang checkbox, chip blocked, context menu, số thứ tự… trong
/// 220pt trừ thụt lề thì không còn chỗ cho bất cứ thứ nào trong số đó. Cũng không phải
/// `SectionHeaderRow`: row này không đổi section, nó mở detail panel — bấm vào một task ở đâu
/// trong app
/// cũng ra cùng một chỗ (`AppState.openDetail`, đúng quy ước `TaskRow`/`NextPeekRow` đang theo).
private struct SectionPeekRow: View {
    let task: TaskItem
    let trailing: String
    /// Màu nhãn ngày theo `DeadlineUrgency`; `nil` = `textMut` như cũ.
    let tint: Color?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                // Màu urgency chuyển từ cột chữ bên phải sang cái chấm bên TRÁI: ở bên phải nó là
                // màu của một nhãn ngày (đọc ra "cái nhãn này đỏ"), ở bên trái nó là màu của cả
                // hàng (đọc ra "việc này gấp") — đúng chỗ Linear đặt màu trong Favorites.
                // `tint` nil (Inbox không có hạn) không đổi thành trong suốt: một hàng thiếu chấm
                // sẽ lệch lề so với hàng bên cạnh. Xám = "không có hạn", vẫn là một trạng thái.
                Circle()
                    .fill(tint ?? VolarColor.textMut)
                    .frame(width: 6, height: 6)
                Text(task.title)
                    .font(.system(size: 13))
                    // `textPri` chứ không `textSec`: mấy hàng này giờ là nội dung chính của
                    // sidebar, header mới là thứ được phép mờ.
                    .foregroundStyle(VolarColor.textPri)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if !trailing.isEmpty {
                    Text(trailing)
                        .font(Font.volarMono(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(VolarColor.textMut)
                        // Cột ngày/tuổi không bao giờ bị ép co lại: tít task dài thì cắt đuôi
                        // chính nó, không phải cắt con số bên phải.
                        .layoutPriority(1)
                }
            }
            // Thụt 16pt: chấm lùi 8pt so với chữ của header bên trên (header padding ngang 8) —
            // đủ để đọc ra quan hệ cha/con, không sâu như 33pt cũ (thụt để né cái icon nay đã bỏ)
            // vốn đẩy tít task vào giữa cột rồi cắt đuôi gần hết.
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 4.5)
            // Cùng lý do đã ghi trong `SectionHeaderRow`: `Spacer` và `padding` không vẽ gì, thiếu dòng
            // này thì vùng bấm thủng lỗ chỗ trong khi nền hover trông như cả dải.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovering ? VolarColor.cardHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
        .accessibilityLabel(trailing.isEmpty ? task.title : "\(task.title), \(trailing)")
    }
}

/// The sidebar's "Pro" row — deliberately NOT a `SectionHeaderRow` (those are flat nav rows for
/// switching sections; this doesn't navigate anywhere, it sells or confirms a subscription).
/// Private to `Sidebar`, same convention as `SectionHeaderRow`/`CaptureButtonStyle` above.
///
/// Two states that must never blend into one:
///  - `isPro == false` — a bright accent-filled CTA (gradient fill, accent stroke, hover feedback
///    exactly like `SectionHeaderRow`'s own `@State private var isHovering`) that calls `onTapUpsell`.
///    This is the ONE thing in the sidebar allowed to look like a sales pitch.
///  - `isPro == true` — a quiet, unclickable status row: no accent fill, no hover animation, no
///    action at all. Re-pitching Pro to someone who already paid for it is a product bug, not a
///    style choice (same "don't sell twice" rule `PaywallView.alreadyProBody` already follows for
///    the paywall sheet itself) — so this branch has nothing wired to `onTapUpsell`.
private struct ProSidebarRow: View {
    let isPro: Bool
    let onTapUpsell: () -> Void

    @Environment(AppState.self) private var appState: AppState
    @State private var isHovering = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        if isPro {
            HStack(spacing: 7) {
                VolarIcon(.check, size: 12, color: VolarColor.done, weight: .semibold)
                Text("Pro")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        } else {
            Button(action: onTapUpsell) {
                HStack(spacing: 7) {
                    VolarIcon(.sparkle, size: 13, color: accentColors.solid, weight: .semibold)
                    Text("Pro")
                        .font(.system(size: 12.5, weight: .semibold))
                        .tracking(-0.06)
                        .foregroundStyle(accentColors.solid)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                // Cùng lỗi, cùng cách sửa như `SectionHeaderRow` ở trên (xem comment dài ở đó): hàng này
                // cũng là `Button` + `.buttonStyle(.plain)` với `Spacer` + padding không vẽ gì, và
                // gradient fill của nó cũng nằm NGOÀI `Button` — nên nó cũng trông như bấm được cả
                // dải trong khi chỉ có icon và chữ "Pro" là ăn click. Sửa luôn ở đây thay vì đợi ai
                // đó báo tiếp: đây là nút BÁN HÀNG, một nút upsell khó bấm là mất tiền thật.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Gradient fill (accentColors.solid -> .hover) rather than the flat `.surface` tint
            // `SectionHeaderRow`'s `active` state uses — this row needs to read as visibly brighter than
            // an active nav row, not just "selected".
            .background(
                LinearGradient(
                    colors: [accentColors.solid.opacity(0.24), accentColors.hover.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                // `.strokeBorder`, not `.stroke` — see `onDeviceFooter` comment above for why.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(accentColors.solid.opacity(isHovering ? 0.75 : 0.45), lineWidth: isHovering ? 1 : 0.75)
            )
            .onHover { isHovering = $0 }
            .animation(VolarMotion.hover, value: isHovering)
        }
    }
}
