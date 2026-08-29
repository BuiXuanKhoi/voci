// Sources/Views/Sidebar.swift — Focus nav trên, nút nói ở đáy
// Ported from `design/volar-mac.jsx`'s sidebar column.
import SwiftUI

struct Sidebar: View {
    @Environment(AppState.self) private var appState: AppState

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(spacing: 0) {
            tasksSectionLabel

            // 2026-08-24 (anh Khôi): ba section, không còn task con nào lồng dưới.
            //
            // Peek 3 task (thêm 2026-08-20, "cho giống sidebar Notion") bỏ hẳn: từ khi Today trở
            // thành trang của việc đang phải làm, mấy hàng peek chỉ lặp lại đúng thứ cột chính đã
            // nói, mà lại nói bằng chữ nhỏ hơn ở chỗ khuất hơn. Sidebar giờ làm đúng một việc:
            // chuyển section.
            //
            // Today ĐẬM hơn hai cái kia kể cả khi không được chọn (anh Khôi: "đậm màu Today để
            // user focus bấm vào") — nó là chỗ người ta phải quay về, hai cái còn lại là nơi để
            // tra khi cần.
            VStack(spacing: 2) {
                // "Now", không phải "Today" (anh Khôi 2026-08-24): màn này trả lời "việc phải làm
                // NGAY BÂY GIỜ là gì", không phải "hôm nay có những gì". Case của enum vẫn là
                // `.today` — đổi tên case là sửa chừng mười lăm chỗ để đúng một nhãn chữ, mà nhãn
                // chữ mới là thứ người dùng đọc.
                SectionHeaderRow(icon: .focus, label: "Now", active: appState.selectedSection == .today, emphasized: true) {
                    appState.selectedSection = .today
                }
                SectionHeaderRow(icon: .archive, label: "Archived", active: appState.selectedSection == .archived) {
                    appState.selectedSection = .archived
                }
                SectionHeaderRow(icon: .check, label: "Completed", active: appState.selectedSection == .completed) {
                    appState.selectedSection = .completed
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)

            // 2026-08-24 (anh Khôi): nút nói xuống ĐÁY sidebar. Nó là hành động, không phải điều
            // hướng — để trên đầu thì nó chen vào giữa mắt và ba mục nav, mà nav mới là thứ người
            // ta quét khi vừa mở cửa sổ. Ở đáy nó vẫn là thứ to nhất trong cột và vẫn nằm sát tay.
            //
            // Vẫn gói trong một `VStack(spacing: 0)` riêng để đúng một `.tourAnchor(.capture)`
            // trùm được cả nút lẫn hàng phím ⌃⌥M (guided tour, chặng 1: `Sources/Views/Tour/*`).
            VStack(spacing: 0) {
                captureButton
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)

                keyBadgeRow
            }
            .tourAnchor(.capture)
        }
        .padding(.bottom, 12)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(VolarColor.border).frame(width: 0.5)
        }
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
    //
    // "Tasks", không phải "Focus" (anh Khôi 2026-08-24): ba hàng dưới nhãn này là Now / Archived /
    // Completed — ba rổ việc, không liên quan gì tới phiên focus. Nhãn cũ đặt ngay trên chúng đọc
    // thành "mấy cái này thuộc về Focus", mà không.
    private var tasksSectionLabel: some View {
        Text("Tasks")
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(VolarColor.textSec)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
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
                // `.strokeBorder`, not `.stroke`: sau `.clipShape`, `.stroke` vẽ giữa đường path
                // nên nửa ngoài bị cắt mất — lỗi viền mỏng đi một nửa.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(accentColor.opacity(configuration.isPressed ? 0.9 : 0.27), lineWidth: configuration.isPressed ? 1 : 0.5)
            )
            .animation(VolarMotion.press, value: configuration.isPressed)
    }
}

/// Một hàng chuyển section trong sidebar: icon + nhãn. Không còn chevron gập — từ 2026-08-24
/// không section nào có task con lồng bên dưới nữa, nên không còn gì để gập.
///
/// `emphasized` — chỉ "Now" (anh Khôi: "bold bằng màu của mình mà đậm hơn để user biết và bấm
/// vào"). Nó là hàng DUY NHẤT trong sidebar được tiêu màu accent, kể cả khi đang không được chọn:
/// hai hàng còn lại là nơi để tra khi cần, còn đây là chỗ trả lời "bây giờ tôi phải làm gì".
///
/// Điều đó cố ý phá luật "một điểm bão hoà trên màn hình" mà `Theme.swift` đặt ra, và phá có giới
/// hạn: chip NOW trong cột chính dùng `nowAccent` (mint dành riêng cho task đang chạy), còn hàng
/// này dùng `accent.solid` — accent người dùng tự chọn được. Hai thứ khác token, không đánh nhau.
private struct SectionHeaderRow: View {
    let icon: VolarIconName
    let label: String
    let active: Bool
    var emphasized: Bool = false
    let action: () -> Void

    @Environment(AppState.self) private var appState: AppState
    @State private var isHovering = false

    private var accentColors: Accent { appState.accent.accent }

    private var tint: Color {
        if emphasized { return accentColors.solid }
        return active ? VolarColor.textPri : VolarColor.textSec
    }

    private var rowBackground: Color {
        if active { return emphasized ? accentColors.surface : VolarColor.surfaceHi }
        return isHovering ? VolarColor.cardHover : .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VolarIcon(icon, size: emphasized ? 14 : 13, color: tint, weight: emphasized ? .semibold : .regular)
                    .frame(width: 16, alignment: .leading)
                Text(label)
                    .font(.system(size: emphasized ? 14 : 12.5, weight: emphasized ? .bold : (active ? .semibold : .medium)))
                    .tracking(-0.02)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, emphasized ? 8 : 6)
            // BUG FIX 2026-08-09 (anh Khôi báo khi chạy thật: "Upcoming/Inbox bấm hoài mà nó không
            // vào") — giữ nguyên từ `SidebarItem`, cái type mà hàng này thay thế; nhiều file khác
            // trong app trỏ về đây cho lời giải thích đầy đủ. Với `.buttonStyle(.plain)`, SwiftUI
            // chỉ hit-test phần label THỰC SỰ VẼ RA. `Spacer(minLength: 0)` ở trên và hai `.padding`
            // này không vẽ gì cả, nên vùng bấm thật của hàng không phải cả hàng mà là mấy mảnh rời
            // rạc, với lỗ thủng ở giữa. Chuyện này khó phát hiện đúng vì cái nền highlight
            // (`.background` ngay dưới) được vẽ ở lớp NGOÀI `Button`, nên hàng TRÔNG như bấm được
            // cả dải trong khi thực tế không. `.contentShape` đặt SAU padding để hình chữ nhật
            // hit-test trùm luôn cả padding, tức đúng bằng vùng nền mà mắt nhìn thấy.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
        .accessibilityLabel(label)
        .accessibilityHint(active ? "Current section" : "Show \(label)")
    }
}
