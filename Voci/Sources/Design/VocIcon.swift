// Sources/Design/VocIcon.swift — icon name catalog + SF Symbols rendering (spec §3)
import SwiftUI

/// Every icon used by the prototype's `VocIcon` component (`design/tokens.jsx`). Keeping the
/// case list stable lets views request icons by role instead of by raw SF Symbol name.
enum VocIconName: String, CaseIterable, Sendable {
    case mic, focus, inbox, upcoming, today, plus, search
    case chevron, chevronDown, settings, check, clock, bell, sparkle, flag, bolt
    case cmd, project, waveform, home, back, x, eject
    case pause, play, stop, volume, volumeOff

    /// The closest native SF Symbol for each design icon — native-first per §6: always a system
    /// symbol, never a hand-drawn custom `Shape`, even where the visual match isn't pixel-exact.
    var systemName: String {
        switch self {
        case .mic: return "mic"
        case .focus: return "scope"
        case .inbox: return "tray"
        case .upcoming: return "calendar"
        case .today: return "calendar"
        case .plus: return "plus"
        case .search: return "magnifyingglass"
        case .chevron: return "chevron.right"
        case .chevronDown: return "chevron.down"
        case .settings: return "gearshape"
        case .check: return "checkmark"
        case .clock: return "clock"
        case .bell: return "bell"
        case .sparkle: return "sparkles"
        case .flag: return "flag"
        case .bolt: return "bolt.fill"
        case .cmd: return "command"
        case .project: return "folder"
        case .waveform: return "waveform"
        case .home: return "house"
        case .back: return "chevron.left"
        case .x: return "xmark"
        case .eject: return "eject.fill"
        case .pause: return "pause.fill"
        case .play: return "play.fill"
        case .stop: return "stop.fill"
        case .volume: return "speaker.wave.2.fill"
        case .volumeOff: return "speaker.slash.fill"
        }
    }
}

/// `VocIcon(_ name:size:color:weight:)` — the one place views reach for an icon glyph.
struct VocIcon: View {
    let name: VocIconName
    var size: CGFloat
    var color: Color
    var weight: Font.Weight

    init(_ name: VocIconName, size: CGFloat = 14, color: Color = VociColor.textPri, weight: Font.Weight = .regular) {
        self.name = name
        self.size = size
        self.color = color
        self.weight = weight
    }

    var body: some View {
        Image(systemName: name.systemName)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
    }
}
