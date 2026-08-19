// Volar/Sources/App/WindowChrome.swift
//
// Sơn titlebar của cửa sổ chính cùng một màu với thân app (anh Khôi, 2026-08-09: "header màu
// trắng mà body đen nhìn xấu"; lặp lại 2026-08-19 và 2026-08-20 vì hai lần fix trước đều chưa
// chạy được — xem "VÌ SAO HAI LẦN TRƯỚC HỎNG" bên dưới).
//
// VÌ SAO CẦN FILE NÀY: `VolarApp.applicationDidFinishLaunching` set `NSApp.appearance` (đọc từ
// pref System/Light/Dark) để các control AppKit như `Picker`/`Menu` vẽ đúng appearance. Nhưng
// `NSApp.appearance` KHÔNG tự sơn lại `NSWindow.backgroundColor` — titlebar vẫn giữ màu hệ thống
// mặc định trừ khi ta set riêng, đó là việc file này làm.
//
// VÌ SAO KHÔNG DÙNG `.windowStyle(.hiddenTitleBar)`: style đó bật `fullSizeContentView`, content
// tràn lên dải titlebar và ba nút đỏ-vàng-xanh sẽ đè lên `greetingHeader` của `TodayView`.
// `titlebarAppearsTransparent` cho đúng kết quả (một màu) mà không đổi một pixel layout nào.
//
// VÌ SAO HAI LẦN TRƯỚC HỎNG:
//   (1) 2026-08-09: gọi `apply` đúng một lần trong `makeNSView`, lúc đó `view.window` còn `nil`
//       → guard im lặng thoát, titlebar không bao giờ được sơn.
//   (2) 2026-08-19: thay bằng vòng retry 10 lần qua `DispatchQueue.main.async`. Mười hop đó chạy
//       hết gần như tức thì, vẫn có thể tiêu sạch TRƯỚC KHI SwiftUI dựng `NSWindow` → lại bỏ cuộc
//       vĩnh viễn. Và cả hai bản đều tự dựng một `NSColor` dynamic RIÊNG (copy hex của
//       `VolarColor.bg`), resolve một lần lúc gán: nếu thời điểm đó appearance hiện hành còn là
//       aqua thì `backgroundColor` thành TRẮNG và đứng im ở đó — titlebar trắng trong khi thân
//       app đen, đúng cái ảnh anh Khôi gửi. Màu trắng đó còn khiến AppKit lật luôn appearance của
//       vùng titlebar/toolbar sang light (nó chọn tương phản theo độ sáng nền), nên icon toolbar
//       cũng đổi sang glyph tối.
//
// BẢN NÀY: không polling, không copy hex. `viewDidMoveToWindow` báo đúng khoảnh khắc `NSWindow`
// có thật; `viewDidChangeEffectiveAppearance` báo mỗi lần Light↔Dark đổi (kể cả khi user đổi pick
// trong Settings, vì `NSApp.appearance` đổi thì effective appearance của view đổi theo). Màu lấy
// thẳng từ token `VolarColor.bg` và được resolve dưới ĐÚNG appearance của cửa sổ tại thời điểm áp
// (`performAsCurrentDrawingAppearance`), nên không còn cửa cho một giá trị resolve sai đứng lại.
//
// UNVERIFIED — viết trên Windows, không có Swift toolchain. Chưa compile, chưa render lần nào.

import AppKit
import SwiftUI

/// Gắn vào cây view của cửa sổ chính (`.background(WindowChrome())` trong `VolarApp`) để sơn
/// titlebar cùng màu `VolarColor.bg`.
///
/// Là `NSViewRepresentable` chứ không phải một lệnh gọi một lần trong `AppDelegate` vì `NSWindow`
/// của một scene `Window(id:)` có thể được SwiftUI dựng lại: user đóng cửa sổ bằng ⌘W rồi mở lại
/// từ menu bar (`openWindow(id: "main")`) là một luồng có thật trong app này.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowChromeView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowChromeView)?.applyChrome()
    }
}

/// Toàn bộ việc sơn nằm ở đây, chạy bằng hai hook có sẵn của AppKit thay vì tự hẹn giờ:
/// `viewDidMoveToWindow` (window vừa có thật / vừa đổi) và `viewDidChangeEffectiveAppearance`
/// (Light↔Dark vừa đổi).
private final class WindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyChrome()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }

    /// Bỏ qua `NSPanel` để không đụng tới `CapturePanel` hay dropdown của `MenuBarExtra` — cả hai
    /// tự lo chrome của mình. Cùng cách loại trừ mà `AppDelegate.showMainWindow()` dùng.
    func applyChrome() {
        guard let window, !(window is NSPanel) else { return }
        // Titlebar thôi vẽ nền riêng và để lộ `backgroundColor` của window bên dưới — đây là thứ
        // làm header và body thành một màu. KHÔNG kèm `.fullSizeContentView`, layout giữ nguyên.
        window.titlebarAppearsTransparent = true
        // Chữ "Volar" trên titlebar bị ẩn: một dải màu liền không nên có chữ lơ lửng giữa nó.
        // Lựa chọn THẨM MỸ — đổi thành `.visible` nếu anh Khôi muốn giữ tiêu đề.
        window.titleVisibility = .hidden
        // Resolve `VolarColor.bg` dưới đúng appearance của cửa sổ ngay lúc gán. Đây là chỗ hai bản
        // trước sai: chúng resolve dưới appearance đang hiện hành lúc launch (có thể là aqua) rồi
        // giữ nguyên giá trị trắng đó mãi.
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.backgroundColor = NSColor(VolarColor.bg)
        }
    }
}
