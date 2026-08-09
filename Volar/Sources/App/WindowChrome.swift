// Volar/Sources/App/WindowChrome.swift
//
// Sơn titlebar của cửa sổ chính cùng một màu với thân app (anh Khôi, 2026-08-09: "header màu
// trắng mà body đen nhìn xấu").
//
// VÌ SAO CẦN FILE NÀY: `VolarApp.applicationDidFinishLaunching` đã ép
// `NSApp.appearance = .darkAqua` (xem doc comment ở đó — nó tồn tại để các control AppKit như
// `Picker`/`Menu` không vẽ chữ đen trên nền gần đen). Nhưng `.darkAqua` chỉ làm titlebar thành
// XÁM ĐẬM (~#2A2A2E), trong khi `VolarColor.bg` là #0F0F11 — gần đen hẳn. Hai màu đó chênh nhau
// đủ để đọc ra thành "hai mảng khác màu dán vào nhau", đúng như anh Khôi mô tả. `.darkAqua`
// KHÔNG phải bug và không được gỡ; nó chỉ không đủ.
//
// VÌ SAO KHÔNG DÙNG `.windowStyle(.hiddenTitleBar)` (cách 1 dòng, thuần SwiftUI): style đó bật
// `fullSizeContentView`, content tràn lên chiếm cả dải titlebar, và ba nút đỏ-vàng-xanh (x≈13–70,
// y≈6–26) sẽ nằm ĐÈ lên `greetingHeader` của `TodayView` — view đó bắt đầu ở
// `.padding(.horizontal, 28)` + `.padding(.top, 20)`, tức chữ tiêu đề section rơi đúng vào vùng
// traffic lights. Sửa được, nhưng phải căn lại padding bằng mắt trên Mac, mà file này viết mù
// trên Windows. `titlebarAppearsTransparent` đạt đúng kết quả anh Khôi yêu cầu (một màu) mà
// KHÔNG đổi một pixel layout nào: titlebar vẫn chiếm chỗ cũ, content vẫn bắt đầu ngay dưới nó.
//
// UNVERIFIED — viết trên Windows, không có Swift toolchain. Chưa compile, chưa render lần nào.

import AppKit
import SwiftUI

/// Gắn vào cây view của cửa sổ chính (`.background(WindowChrome())` trong `VolarApp`) để sơn
/// titlebar cùng màu `VolarColor.bg`.
///
/// Là `NSViewRepresentable` chứ không phải một lệnh gọi một lần trong `AppDelegate` vì `NSWindow`
/// của một scene `Window(id:)` có thể được SwiftUI dựng lại: user đóng cửa sổ bằng ⌘W rồi mở lại
/// từ menu bar (`openWindow(id: "main")`) là một luồng có thật trong app này. Một lần set ở
/// `applicationDidFinishLaunching` sẽ mất tác dụng sau lần dựng lại đó; gắn vào view thì mỗi lần
/// cửa sổ tồn tại là một lần style được áp lại.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Hoãn một vòng run-loop: tại thời điểm `makeNSView`, view chưa được gắn vào cây nên
        // `view.window` còn `nil`. Cùng lý do với `AppDelegate.showMainWindow()`'s own deferral.
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }

    /// Bỏ qua `NSPanel` để không bao giờ đụng tới `CapturePanel` hay dropdown của `MenuBarExtra` —
    /// cả hai đều là panel và đều tự lo phần chrome của mình (xem `CapturePanel.swift`). Cùng cách
    /// loại trừ mà `AppDelegate.showMainWindow()` dùng để tìm cửa sổ chính.
    private static func apply(to window: NSWindow?) {
        guard let window, !(window is NSPanel) else { return }
        // Titlebar thôi vẽ nền riêng của nó và để lộ `backgroundColor` của window bên dưới —
        // đây là thứ làm header và body thành một màu. KHÔNG kèm `.fullSizeContentView`, nên
        // content không tràn lên và layout giữ nguyên (xem doc comment đầu file).
        window.titlebarAppearsTransparent = true
        // Chữ "Volar" trên titlebar bị ẩn: một dải màu liền không nên có chữ lơ lửng giữa nó, và
        // tên app đã có ở Dock + menu bar. Đây là lựa chọn THẨM MỸ, không phải kỹ thuật — đổi
        // thành `.visible` nếu anh Khôi muốn giữ tiêu đề.
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(VolarColor.bg)
    }
}
