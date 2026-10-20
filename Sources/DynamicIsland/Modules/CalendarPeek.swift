import AppKit
import EventKit
import Foundation

/// The week strip and its event list.
///
/// One fetch covers the whole visible strip; picking a day filters in memory
/// rather than hitting EventKit again. Refreshed on EventKit's change
/// notification and when the island opens - never on a timer.
@MainActor
@Observable
final class CalendarPeek {
    static let shared = CalendarPeek()

    struct Event: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        /// First video-call URL found in the event, if any.
        let joinURL: URL?
        /// Identifier Calendar.app understands, for opening the event itself.
        let externalID: String?

        var isPast: Bool { end < .now }
    }

    private(set) var authorized = false
    /// Day the strip is showing. Always a start-of-day.
    private(set) var selectedDay: Date = Foundation.Calendar.current.startOfDay(for: .now)

    private var byDay: [Date: [Event]] = [:]
    /// The one pending "up next" reminder. See `scheduleReminder`.
    private var reminder: DispatchWorkItem?
    /// Occurrences already announced, by id and start - a recurring event
    /// shares one identifier across every occurrence.
    private var reminded: Set<String> = []

    private let store = EKEventStore()
    private var cal: Foundation.Calendar { .current }

    private init() {}

    /// Days in the strip: two behind, four ahead. Centred on today rather than
    /// starting the week on Sunday - the useful days are the ones just ahead.
    var strip: [Date] {
        let today = cal.startOfDay(for: .now)
        return (-2 ... 4).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    /// Events for the selected day only.
    var events: [Event] { byDay[selectedDay] ?? [] }

    func hasEvents(on day: Date) -> Bool {
        !(byDay[cal.startOfDay(for: day)] ?? []).isEmpty
    }

    func isSelected(_ day: Date) -> Bool {
        cal.isDate(day, inSameDayAs: selectedDay)
    }

    func select(_ day: Date) {
        selectedDay = cal.startOfDay(for: day)
    }

    /// Called whenever the island opens, so a selection made yesterday does not
    /// persist into today.
    func resetToToday() {
        selectedDay = cal.startOfDay(for: .now)
        refresh()
    }

    func start() {
        guard Settings.shared.calendar else { return }
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Read the status; never ask for it here. Requesting at launch means a
        // permission dialog every single start until it is granted, and an app
        // that is rebuilt often re-asks forever - the grant is keyed to the code
        // signature, so each new build looks like a new app to TCC. The prompt
        // now comes only from the button in the calendar tab, which is the one
        // moment the user has actually asked for calendar data.
        readAuthorization()
        if authorized { refresh() }
        // Timers do not run while the Mac sleeps; the next reminder is worked
        // out again on wake from the real clock.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CalendarPeek.shared.refresh() }
        }
    }

    private func readAuthorization() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Called from the permission notice, never at launch.
    func requestAccess() {
        Task { @MainActor in
            _ = try? await store.requestFullAccessToEvents()
            readAuthorization()
            refresh()
        }
    }

    func refresh() {
        guard authorized, let first = strip.first, let last = strip.last,
              let end = cal.date(byAdding: .day, value: 1, to: last)
        else { return }

        // Whole-day bounds, not a rolling window from "now" - a 24h window from
        // mid-afternoon spills into tomorrow morning and reports it as today.
        let predicate = store.predicateForEvents(withStart: first, end: end, calendars: nil)

        var grouped: [Date: [Event]] = [:]
        for event in store.events(matching: predicate) where event.status != .canceled {
            guard let startDate = event.startDate else { continue }
            let day = cal.startOfDay(for: startDate)
            grouped[day, default: []].append(
                Event(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Untitled",
                    start: startDate,
                    end: event.endDate ?? startDate,
                    isAllDay: event.isAllDay,
                    joinURL: Self.joinURL(for: event),
                    externalID: event.calendarItemExternalIdentifier
                )
            )
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.start < $1.start }
        }
        byDay = grouped
        scheduleReminder()
    }

    // MARK: - Up next

    /// One work item, for the next event's start minus the lead time. Nothing
    /// runs between events: it fires, announces, and schedules the one after.
    /// Wall-clock deadline, so a sleep in between does not push it late.
    func scheduleReminder() {
        reminder?.cancel()
        reminder = nil
        let lead = Settings.shared.upNextMinutes * 60
        guard Settings.shared.calendar, authorized, lead > 0 else { return }
        let now = Date()
        let next = byDay.values.joined()
            .filter { !$0.isAllDay && $0.start > now && !reminded.contains(Self.key($0)) }
            .min { $0.start < $1.start }
        let work: DispatchWorkItem
        let fireAt: Date
        if let next {
            work = DispatchWorkItem { [weak self] in self?.remind(next) }
            fireAt = next.start.addingTimeInterval(-lead)
        } else {
            // Nothing left in the strip: look again tomorrow, when it moves on.
            guard let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) else { return }
            work = DispatchWorkItem { [weak self] in self?.refresh() }
            fireAt = tomorrow.addingTimeInterval(60)
        }
        reminder = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, fireAt.timeIntervalSince(now)), execute: work)
    }

    private func remind(_ event: Event) {
        reminded.insert(Self.key(event))
        let minutes = Int((event.start.timeIntervalSinceNow / 60).rounded())
        var detail = minutes <= 0 ? "Starting now" : "In \(minutes) min · \(event.start.formatted(date: .omitted, time: .shortened))"
        if event.joinURL != nil { detail += " · Join" }
        HUD.shared.show(.upcoming(title: event.title, detail: detail, joinURL: event.joinURL), for: 8)
        scheduleReminder()
    }

    private static func key(_ event: Event) -> String {
        "\(event.id)@\(event.start.timeIntervalSince1970)"
    }

    /// Opens the event in Calendar. Falls back to launching Calendar on the
    /// right day when the identifier is not one it accepts.
    func open(_ event: Event) { Self.open(externalID: event.externalID) }

    /// Also how the command bar's calendar answers open their rows.
    static func open(externalID: String?) {
        if let id = externalID,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = URL(string: "ical://") { NSWorkspace.shared.open(url) }
    }

    /// Meeting links live in different fields depending on the invite source.
    private static func joinURL(for event: EKEvent) -> URL? {
        if let url = event.url, Self.isMeetingLink(url) { return url }
        let haystack = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) ?? []
        return matches.compactMap(\.url).first(where: Self.isMeetingLink)
    }

    private static func isMeetingLink(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return ["zoom.us", "meet.google.com", "teams.microsoft.com", "webex.com", "whereby.com"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
