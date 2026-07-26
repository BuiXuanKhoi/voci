// Sources/Views/Tour/TourAnchor.swift — anchor-preference plumbing that lets `TourOverlay.swift`
// find the REAL, on-screen frame of the button/region a tour stop is teaching, without either side
// (the tagged view in `Sidebar.swift`/`TodayView.swift`, or the overlay that reads it) hardcoding a
// frame. Standard SwiftUI `PreferenceKey` idiom — see Apple's own `alignmentGuide`/anchor-preference
// docs — kept in its own small file since it's pure plumbing, not a view.
import SwiftUI

/// Collects every `.tourAnchor(_:)`-tagged view's bounds, keyed by which UI element it is. Read via
/// `.overlayPreferenceValue(TourAnchorKey.self)` at the ancestor that contains every tagged view
/// (`TodayView.body`'s outer `ZStack`, which contains both `Sidebar` and `mainColumn`) — SwiftUI
/// preference values bubble up through `reduce(value:nextValue:)`, merging every tagged
/// descendant's single-entry dictionary into one combined map by the time they reach that ancestor.
struct TourAnchorKey: PreferenceKey {
    typealias Value = [TourAnchorID: Anchor<CGRect>]

    /// MUST be a COMPUTED static property (`{ [:] }`), not a stored `static let`/`static var` — this
    /// target builds with `SWIFT_STRICT_CONCURRENCY: complete` under Swift 6 (`project.yml`), where
    /// a mutable stored `static` (which `Value` — a `Dictionary`, no `Sendable` conformance required
    /// but still triggers the same global-mutable-state rule as any other stored static in a
    /// strict-concurrency build) is a hard compile error, not a warning. `PreferenceKey.defaultValue`
    /// is a protocol requirement Apple's own APIs typically satisfy with a stored `static let` —
    /// fine under the default/minimal concurrency checking most SwiftUI code ships with, but not
    /// under this project's `complete` setting. A computed property has no stored global to flag.
    static var defaultValue: Value { [:] }

    /// Later-merged values win ties (`{ _, new in new }`) — in practice no two `.tourAnchor(_:)`
    /// call sites ever tag the same `TourAnchorID` at once, so this tiebreak is never actually
    /// exercised; it exists only because `reduce`'s merge closure is non-optional.
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Tags this view as the real on-screen element for `id` — `TourOverlay` resolves the anchor
    /// back to a concrete `CGRect` via `GeometryProxy`'s `subscript(_:)` once it has both the
    /// anchor (from here) and a `GeometryProxy` for its own coordinate space (`TodayView.body`'s
    /// `GeometryReader` wrapping `TourOverlay`). Uses `.bounds` (not `.center`/a custom anchor) so
    /// the overlay can cut a hole and draw a ring sized to the WHOLE element, not just its center
    /// point.
    func tourAnchor(_ id: TourAnchorID) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: $0] }
    }
}
