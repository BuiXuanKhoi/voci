// Sources/Integrations/CalendarAccess.swift — EventKit permission surface: requests access and
// reports STATUS + a bare calendar count. Actually reading/writing event data is NOT this file's
// job — see `CalendarSync.swift` (same module, shares this class's `eventStore`) for that.
//
// SCOPE (updated — Volar now writes calendar events, see below): this file itself still only ever
// touches `store.calendars(for: .event).count`, a bare integer — it never reads event titles,
// times, attendees, locations, or any other event content, and never calls an EventKit mutator
// itself. What changed is what the REST of the app does with the grant this file obtains:
// `CalendarSync` (sibling file) now creates a dedicated "Volar" calendar and mirrors the user's own
// scheduled tasks into it as events — one-way, Volar → Calendar, never the reverse (reading events
// to create tasks is explicitly out of scope). `CalendarSync` never touches any calendar it did not
// create; see that file's header and `ensureVolarCalendar()`/`reconcile(tasks:)` for the mechanism
// that bounds the blast radius to just that one calendar. `AppState.busyIntervals` (task-engine
// scheduling awareness) stays hardcoded `[]` regardless — mirroring INTO the calendar and reading
// FROM it for scheduling are two separate, independently-gated features, and only the former exists
// today.
//
// WHY THIS REQUESTS "FULL" ACCESS (read this before touching the usage strings, entitlement, or
// privacy doc — all three must make the same claim this file backs up): EventKit on macOS 14
// exposes exactly two request calls: `requestFullAccessToEvents()` and
// `requestWriteOnlyAccessToEvents()`. There is no `requestReadOnlyAccessToEvents` — the write-only
// grant cannot be used to read a single event or even list calendars for reading. So the ONLY
// EventKit API that grants read access on this OS version is "full access," which also happens to
// be exactly what Volar now genuinely needs, since it both reads (calendar count today, busy
// intervals possibly later) and writes (via `CalendarSync`, into its own calendar only). "Requests
// full access, uses it read-only" is no longer the story for this app as a whole — but the write
// half is scoped to a single app-created calendar by construction, never to calendars the user
// already had. If a future macOS adds a finer-grained request API, revisit this file, the two
// usage-description strings (Info.plist), and `docs/app-store-privacy.md` together.
//
// WHY `@MainActor`: `EKEventStore` is not `Sendable`, and this target builds with
// `SWIFT_STRICT_CONCURRENCY: complete` under Swift 6 (see VolarApp.swift's own `@Sendable` notes
// for a case where this repo got bitten by assuming a closure was MainActor-isolated when it
// wasn't — same class of bug this annotation exists to prevent here). Pinning the whole class to
// the main actor means the store, and every property callers read (`status`, `calendarCount`,
// `lastError`), are always touched from one isolation domain — no `Task.detached`, no hopping
// across actors with a non-Sendable store in hand. `CalendarSync` is `@MainActor` too and shares
// THIS `eventStore` instance rather than constructing its own, so there is exactly one
// `EKEventStore` in the whole app — two instances would maintain separate internal caches that can
// go stale/conflict relative to each other (Apple's own docs warn against this).
import EventKit
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class CalendarAccess {
    enum Status: Equatable, Sendable {
        case notDetermined
        case denied
        case restricted
        case granted
        case unavailable
    }

    private(set) var status: Status
    private(set) var calendarCount: Int
    private(set) var lastError: String?

    // Held lazily so that simply constructing `CalendarAccess` — which `AppState` does
    // unconditionally at launch (per agent A's contract) — does nothing observable to the user.
    // `EKEventStore()` itself does not prompt TCC (only `requestFullAccessToEvents()` does), but
    // there is no reason to spin up a store, or hold a live EventKit connection, before the user
    // has ever asked to see calendar status. `refreshStatus()`/`requestAccess()` are the only
    // things that touch this, and both go through `eventStore`, which allocates on first use only.
    private var _eventStore: EKEventStore?
    /// `internal` (not `private`) so `CalendarSync` — constructed as `CalendarSync(access:)` and
    /// living in the same module/target — shares this exact instance instead of making its own.
    /// Two `EKEventStore`s in one process is the documented footgun this avoids: each keeps its
    /// own internal object cache, so a calendar/event saved through one can appear stale or
    /// missing through the other until a refetch. `CalendarSync` never constructs `EKEventStore()`
    /// itself for this reason. Still `@MainActor`-isolated same as everything else here — no
    /// Sendable-store shenanigans just because visibility widened.
    var eventStore: EKEventStore {
        if let existing = _eventStore { return existing }
        let store = EKEventStore()
        _eventStore = store
        return store
    }

    init() {
        self.status = Self.map(EKEventStore.authorizationStatus(for: .event))
        self.calendarCount = 0
        self.lastError = nil
    }

    /// Requests full calendar access (the only read-capable request on macOS 14 — see file header)
    /// and refreshes `status`/`calendarCount` from the result. Never throws to the caller, never
    /// force-unwraps: any EventKit failure lands in `lastError` with `status` re-derived from
    /// `authorizationStatus(for:)` rather than assumed.
    func requestAccess() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            status = granted ? .granted : Self.map(EKEventStore.authorizationStatus(for: .event))
            lastError = nil
            calendarCount = granted ? eventStore.calendars(for: .event).count : 0
        } catch {
            // Re-derive from the OS's own record rather than guessing — e.g. the user backgrounding
            // the TCC sheet without choosing surfaces here as a thrown error on some OS versions,
            // and `authorizationStatus(for:)` is the source of truth for what actually happened.
            status = Self.map(EKEventStore.authorizationStatus(for: .event))
            lastError = error.localizedDescription
        }
    }

    /// Re-reads the current OS-level authorization state without prompting — safe to call any
    /// time (e.g. a Settings "Refresh" button after the user flips the toggle in System Settings
    /// and comes back, since this app is never notified of that change automatically).
    func refreshStatus() {
        status = Self.map(EKEventStore.authorizationStatus(for: .event))
        if status == .granted {
            calendarCount = eventStore.calendars(for: .event).count
        } else {
            calendarCount = 0
        }
    }

    /// Opens System Settings' Privacy → Calendars pane so a denied/restricted user can flip the
    /// toggle without hunting for it themselves.
    /// // UNVERIFIED: the `Privacy_Calendars` pane-anchor string cannot be exercised from Windows —
    /// confirm on a Mac that this URL actually lands on the Calendars row (Apple has silently
    /// renamed these anchors across OS versions before; a wrong/removed anchor just opens the
    /// top-level Privacy & Security pane instead of failing, so this degrades gracefully either way).
    func openSystemSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else {
            return
        }
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        // iOS has no deep link into a specific Settings pane (unlike macOS's
        // x-apple.systempreferences: scheme) — opening this app's own Settings page (where the
        // Calendars permission row lives) is the correct fallback. Same pattern as
        // `AppState.openDictationSettings()`'s iOS branch — match that file's convention rather
        // than inventing a new one.
        // UNVERIFIED: UIApplication.openSettingsURLString opens THIS APP's Settings page in the
        // iOS Settings app; verified against Apple's documented constant name, not exercised on a
        // real device/simulator from this machine.
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    /// The `EKAuthorizationStatus` → `Status` mapping, factored out as an internal static func so
    /// `CalendarAccessTests` can assert every case without touching a real `EKEventStore` (which
    /// would require live TCC state to test meaningfully).
    static func map(_ ekStatus: EKAuthorizationStatus) -> Status {
        switch ekStatus {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .fullAccess:
            return .granted
        case .writeOnly:
            // Write-only does NOT satisfy Volar's read-only need — Volar can only ever read
            // calendars/events, so a write-only grant is functionally no grant at all. Treated as
            // `.denied` (not `.granted`) so the Settings UI still offers "Open System Settings"
            // rather than claiming the feature works.
            return .denied
        case .authorized:
            // Deprecated pre-macOS-14 case (old-style single-tier authorization). Mapped to
            // `.granted` for backward compatibility on the off chance this ever runs on an older
            // OS than the 14.0 floor declares — should be unreachable in practice.
            return .granted
        @unknown default:
            return .unavailable
        }
    }

    // MARK: - Reading forward (backlog "Đường vào Volar" [I3])

    /// One upcoming calendar event, for Glance to lean on.
    struct UpcomingEvent: Equatable, Sendable {
        let title: String
        let start: Date
        /// Whole minutes from `now` until it starts, floored, never negative.
        let minutesAway: Int
    }

    /// The next event starting within `window`, or `nil`.
    ///
    /// WHY THIS EXISTS: time blindness is the ADHD symptom Volar is worst at helping with, and
    /// Glance is the only surface that can address it without asking anyone to open an app. Knowing
    /// "a meeting starts in 12 minutes" is what stops Glance from cheerfully suggesting a 45-minute
    /// task into a wall. The permission for this was already granted and already requested for the
    /// task mirror — this reads it back for the first time.
    ///
    /// Three exclusions, each load-bearing:
    ///  - **Volar's own mirror calendar.** Without this, Glance would announce your own tasks back
    ///    to you as if they were meetings — the mirror writes every deadline into a calendar.
    ///    `CalendarSync.volarCalendarID` is the identifier to pass here.
    ///  - **All-day events.** "Alice's birthday" is not a thing that starts in 12 minutes.
    ///  - **Already-started events.** Glance answers "what's coming", not "what you're late for";
    ///    an event in progress has nothing actionable left to say on a one-second surface.
    ///
    /// Returns `nil` on anything other than full access rather than throwing: a missing calendar
    /// permission must degrade Glance to its normal self, never to an error.
    func nextEvent(
        within window: TimeInterval = 2 * 60 * 60,
        now: Date = Date(),
        excludingCalendarID: String? = nil
    ) -> UpcomingEvent? {
        guard status == .granted else { return nil }

        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(window),
            calendars: nil
        )
        let next = eventStore.events(matching: predicate)
            .filter { event in
                guard !event.isAllDay else { return false }
                guard let start = event.startDate, start > now else { return false }
                if let excludingCalendarID, event.calendar?.calendarIdentifier == excludingCalendarID {
                    return false
                }
                return true
            }
            .min { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }

        guard let next, let start = next.startDate else { return nil }
        let title = (next.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return UpcomingEvent(
            title: title.isEmpty ? "Untitled event" : title,
            start: start,
            minutesAway: max(0, Int(start.timeIntervalSince(now) / 60))
        )
    }
}
