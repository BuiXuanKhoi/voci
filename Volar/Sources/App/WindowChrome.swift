// Volar/Sources/App/WindowChrome.swift
//
// Sơn titlebar của cửa sổ chính cùng một màu với thân app (anh Khôi, 2026-08-09: "header màu
// trắng mà body đen nhìn xấu"; lặp lại 2026-08-19 vì fix lần đầu chưa từng chạy được — xem hai
// ghi chú "FIX (009)" bên dưới).
//
// VÌ SAO CẦN FILE NÀY: `VolarApp.applicationDidFinishLaunching` set `NSApp.appearance` (đọc từ
// pref System/Light/Dark từ specs/009-light-mode-list-v2/design.md §7 — xem doc comment ở đó) để
// các control AppKit như `Picker`/`Menu` vẽ đúng appearance thay vì lúc nào cũng đen. Nhưng
// `NSApp.appearance` chỉ quyết control AppKit vẽ thế nào, KHÔNG tự sơn lại `NSWindow.backgroundColor`
// — titlebar vẫn giữ màu hệ thống mặc định trừ khi ta set riêng, đó là việc file này làm.
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
        // FIX (009, §4): tại thời điểm `makeNSView`, view chưa được gắn vào cây nên `view.window`
        // còn `nil` — scene `Window(id:)` của SwiftUI gắn view vào cây TRƯỚC KHI `NSWindow` thật
        // sự tồn tại. Bản cũ gọi `apply(to:)` đúng một lần ở đây rồi thôi, nên `guard let window`
        // trong `apply` im lặng thoát và titlebar không bao giờ được sơn. `apply(to:attempt:)` bên
        // dưới giờ tự lặp lại tới khi `view.window != nil`, có bộ đếm cứng (xem doc comment của
        // nó) để không bao giờ thành vòng lặp vô hạn.
        DispatchQueue.main.async { Self.apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // `view.window` gần như chắc chắn đã tồn tại ở đây (view đã từng được `makeNSView` gắn
        // vào cây trước đó), nhưng vẫn đi qua đường `apply(to:attempt:)` như cũ để dùng chung một
        // chỗ, một cách xử lý duy nhất.
        DispatchQueue.main.async { Self.apply(to: nsView) }
    }

    /// Thử lại theo vòng run-loop tới khi `view.window != nil`, tối đa 10 lần rồi bỏ cuộc vĩnh
    /// viễn (self-review (1): `attempt < Self.maxAttempts` là điều kiện DUY NHẤT cho việc gọi lại
    /// — không có nhánh nào khác gọi `apply`/lặp thêm, nên 10 lần là trần cứng thật sự, kể cả nếu
    /// `NSWindow` không bao giờ xuất hiện).
    ///
    /// Bỏ qua `NSPanel` để không bao giờ đụng tới `CapturePanel` hay dropdown của `MenuBarExtra` —
    /// cả hai đều là panel và đều tự lo phần chrome của mình (xem `CapturePanel.swift`). Cùng cách
    /// loại trừ mà `AppDelegate.showMainWindow()` dùng để tìm cửa sổ chính. `NSPanel` chỉ kiểm
    /// tra được SAU KHI `window` đã tồn tại (retry loop chỉ đợi sự tồn tại của `NSWindow`, không
    /// đợi nó "là đúng loại"), nên panel bị loại ngay vòng đầu tiên nó xuất hiện — không tốn thêm
    /// vòng lặp nào.
    private static let maxAttempts = 10

    private static func apply(to view: NSView, attempt: Int = 0) {
        guard let window = view.window else {
            guard attempt < maxAttempts else { return }
            DispatchQueue.main.async { Self.apply(to: view, attempt: attempt + 1) }
            return
        }
        guard !(window is NSPanel) else { return }
        // Titlebar thôi vẽ nền riêng của nó và để lộ `backgroundColor` của window bên dưới —
        // đây là thứ làm header và body thành một màu. KHÔNG kèm `.fullSizeContentView`, nên
        // content không tràn lên và layout giữ nguyên (xem doc comment đầu file).
        window.titlebarAppearsTransparent = true
        // Chữ "Volar" trên titlebar bị ẩn: một dải màu liền không nên có chữ lơ lửng giữa nó, và
        // tên app đã có ở Dock + menu bar. Đây là lựa chọn THẨM MỸ, không phải kỹ thuật — đổi
        // thành `.visible` nếu anh Khôi muốn giữ tiêu đề.
        window.titleVisibility = .hidden
        window.backgroundColor = dynamicBg
    }

    /// FIX (009, §4 self-review (2)): `NSColor(VolarColor.bg)` không đủ tin cậy ở đây — tại thời
    /// điểm file này viết, `VolarColor.bg` (`Shared/Design/Theme.swift`, sở hữu bởi một agent khác
    /// đang sửa song song đợt 009 này) VẪN LÀ `Color(volar: 0x0F0F11)`, một hex tĩnh resolve một
    /// lần, không phải `NSColor(name:dynamicProvider:)` — nên bọc nó lại đúng lúc này sẽ đứng im
    /// khi user đổi Light↔Dark. Đây KHÔNG PHẢI một quyết định bỏ qua token: đây là một bản COPY CÓ
    /// CHỦ Ý của giá trị hex mà specs/009-light-mode-list-v2/design.md §3.1 quy định cho `bg`
    /// (`#FFFFFF` light / `#1C1C1E` dark), tự dựng `NSColor` dynamic ngay tại đây để titlebar chắc
    /// chắn đổi màu theo appearance bất kể Theme.swift đợt này kết thúc thế nào. Nếu sau này
    /// Theme.swift XÁC NHẬN `VolarColor.bg` đã dynamic thật, chỗ này có thể đổi lại thành
    /// `NSColor(VolarColor.bg)` để hết trùng lặp giá trị — nhưng phải verify trên Mac trước, không
    /// đoán mù như file này đang phải làm.
    private static let dynamicBg = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // `CGFloat(0x1C) / 255`, không phải `0x1C / 255` — hai literal Int chia nguyên sẽ ra 0.
        return isDark
            ? NSColor(srgbRed: CGFloat(0x1C) / 255, green: CGFloat(0x1C) / 255, blue: CGFloat(0x1E) / 255, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }
}
