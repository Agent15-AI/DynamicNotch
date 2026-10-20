import Foundation
import UserNotifications

/// A countdown.
///
/// Stores an end date, not a tick. One work item fires at completion; the UI
/// derives the remaining time from the date whenever it draws. Nothing repeats
/// while the island is closed.
@MainActor
@Observable
final class CountdownTimer {
    static let shared = CountdownTimer()

    private(set) var endsAt: Date?
    /// Set when paused, so resuming keeps the remaining time.
    private(set) var pausedRemaining: TimeInterval?

    var running: Bool { endsAt != nil }
    var paused: Bool { pausedRemaining != nil }

    var remaining: TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endsAt else { return 0 }
        return max(0, endsAt.timeIntervalSinceNow)
    }

    /// Fraction elapsed, for the ring.
    var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(1 - remaining / total, 0), 1)
    }

    private var total: TimeInterval = 0
    private var completion: DispatchWorkItem?

    private static let endsKey = "timerEndsAt"
    private static let totalKey = "timerTotal"
    private static let pausedKey = "timerPausedRemaining"
    /// macOS keeps this pending even after the app quits, which is what makes a
    /// running timer survive a quit rather than silently vanishing.
    private static let notificationID = "dev.local.dynamicisland.timer"

    private init() {}

    /// Reload a timer that was running when the app last quit.
    ///
    /// Called explicitly at launch: the singleton is lazy, so relying on `init`
    /// meant a restored timer only came back once something happened to touch
    /// this type - which for a quit-and-relaunch was never.
    func restoreState() {
        let defaults = UserDefaults.standard
        total = defaults.double(forKey: Self.totalKey)

        if let paused = defaults.object(forKey: Self.pausedKey) as? Double, paused > 0 {
            pausedRemaining = paused
            return
        }
        guard let stamp = defaults.object(forKey: Self.endsKey) as? Double, stamp > 0 else { return }

        let end = Date(timeIntervalSince1970: stamp)
        let remaining = end.timeIntervalSinceNow
        if remaining > 0 {
            // Re-arm in-process; the pending notification is replaced rather than
            // duplicated, since it carries a fixed identifier.
            schedule(after: remaining)
        } else {
            clearPersisted()
            HUD.shared.show(.timer, for: 3.0)
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(total, forKey: Self.totalKey)
        defaults.set(endsAt?.timeIntervalSince1970 ?? 0, forKey: Self.endsKey)
        defaults.set(pausedRemaining ?? 0, forKey: Self.pausedKey)
    }

    private func clearPersisted() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.endsKey)
        defaults.removeObject(forKey: Self.totalKey)
        defaults.removeObject(forKey: Self.pausedKey)
    }

    func start(minutes: Double) {
        cancel()
        total = minutes * 60
        schedule(after: total)
    }

    func pause() {
        guard running, !paused else { return }
        pausedRemaining = remaining
        completion?.cancel()
        completion = nil
        endsAt = nil
        cancelNotification()
        persist()
    }

    func resume() {
        guard let pausedRemaining else { return }
        self.pausedRemaining = nil
        schedule(after: pausedRemaining)
    }

    /// Add time to a running or paused timer.
    func extend(minutes: Double) {
        let seconds = minutes * 60
        total += seconds
        if let paused = pausedRemaining {
            pausedRemaining = paused + seconds
            persist()
        } else if running {
            completion?.cancel()
            schedule(after: remaining + seconds)
        }
    }

    func cancel() {
        completion?.cancel()
        completion = nil
        endsAt = nil
        pausedRemaining = nil
        total = 0
        cancelNotification()
        clearPersisted()
    }

    private func schedule(after seconds: TimeInterval) {
        endsAt = Date().addingTimeInterval(seconds)
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        completion = work
        // Wall clock: an uptime deadline stops while the Mac sleeps, so a timer
        // that ran out during a lid close fired late, with the header showing 0:00.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds, execute: work)
        scheduleNotification(after: seconds)
        persist()
    }

    /// The one genuinely native piece: macOS owns this alert, so it lands even
    /// if the app is quit before the timer runs out.
    private func scheduleNotification(after seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Timer finished"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.notificationID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    private func fire() {
        completion = nil
        endsAt = nil
        pausedRemaining = nil
        total = 0
        clearPersisted()
        HUD.shared.show(.timer, for: 3.0)
    }

    /// `m:ss`, or `h:mm:ss` past an hour.
    var text: String {
        let value = Int(remaining.rounded())
        let (h, m, s) = (value / 3600, (value % 3600) / 60, value % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
