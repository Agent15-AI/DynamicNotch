import AppKit
import UserNotifications

/// Daily alarms.
///
/// Scheduled with `UNCalendarNotificationTrigger`, so macOS fires them even if
/// this app is not frontmost - and unlike a timer of our own, nothing has to be
/// running in between.
@MainActor
@Observable
final class Alarms: NSObject {
    static let shared = Alarms()

    struct Alarm: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var hour: Int
        var minute: Int
        var enabled: Bool = true
        var label: String = "Alarm"

        var time: String { String(format: "%02d:%02d", hour, minute) }
    }

    private(set) var items: [Alarm] = []
    private(set) var authorized = false

    private static let key = "alarms"

    private override init() {
        super.init()
        load()
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization()
    }

    private func refreshAuthorization() {
        // Copy the one value out before crossing actors; the settings object
        // itself is not sendable.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
            Task { @MainActor in self.authorized = granted }
        }
    }

    func requestAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.authorized = granted
                if granted { self.rescheduleAll() }
            }
        }
    }

    func add(hour: Int, minute: Int) {
        items.append(Alarm(hour: hour, minute: minute))
        items.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        persist()
        if !authorized { requestAccess() } else { rescheduleAll() }
    }

    func remove(_ alarm: Alarm) {
        items.removeAll { $0.id == alarm.id }
        persist()
        rescheduleAll(dropping: [alarm.id.uuidString])
    }

    func toggle(_ alarm: Alarm) {
        guard let index = items.firstIndex(where: { $0.id == alarm.id }) else { return }
        items[index].enabled.toggle()
        persist()
        rescheduleAll()
    }

    /// Next alarm due, for the header.
    var next: Alarm? {
        let now = Calendar.current.dateComponents([.hour, .minute], from: .now)
        let minutesNow = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let enabled = items.filter(\.enabled)
        return enabled.first { $0.hour * 60 + $0.minute > minutesNow } ?? enabled.first
    }

    /// Only the alarms' own requests are cleared. Clearing everything also took
    /// the countdown timer's notification, which is what lands if the app quits
    /// before the timer runs out.
    private func rescheduleAll(dropping removed: [String] = []) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: items.map(\.id.uuidString) + removed)
        for alarm in items where alarm.enabled {
            var components = DateComponents()
            components.hour = alarm.hour
            components.minute = alarm.minute

            let content = UNMutableNotificationContent()
            content.title = alarm.label
            content.body = alarm.time
            content.sound = .default

            center.add(UNNotificationRequest(
                identifier: alarm.id.uuidString,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            ))
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([Alarm].self, from: data)
        else { return }
        items = stored
    }
}

extension Alarms: UNUserNotificationCenterDelegate {
    /// Show the alarm in the island as well as the notification, and let macOS
    /// display it even though this app is frontmost-less.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let title = notification.request.content.title
        // Alarms only - they are the calendar-triggered requests. The countdown
        // timer posts its own activity when it fires, and labelling it an alarm
        // on top of that replaced "Time's up" with the wrong card.
        if notification.request.trigger is UNCalendarNotificationTrigger {
            Task { @MainActor in HUD.shared.show(.alarm(label: title), for: 4.0) }
        }
        completionHandler([.banner, .sound])
    }
}
