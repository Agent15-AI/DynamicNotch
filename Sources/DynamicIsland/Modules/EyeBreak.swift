import AppKit
import Foundation

/// The 20-20-20 rule: every 20 minutes, look at something 20 feet away for 20
/// seconds.
///
/// One work item per interval, never a repeating timer - the same shape as the
/// countdown and the alarms. A twenty-minute interval is three wakeups an hour,
/// which is the cheapest reminder this app has.
///
/// Off by default. Everything else in the island answers a question you asked;
/// this one interrupts, so it has to be switched on deliberately.
///
/// The clock measures time at the screen, not wall time: locking the Mac, closing
/// the lid or letting it sleep drops the pending break, and coming back starts a
/// fresh interval. A break that fires the moment you sit down, because it came due
/// while you were at lunch, teaches people to ignore it.
@MainActor
@Observable
final class EyeBreak {
    static let shared = EyeBreak()

    /// When the next break is due, or nil when nothing is scheduled.
    private(set) var nextBreak: Date?
    /// Set for the twenty seconds of the break itself.
    private(set) var restingUntil: Date?

    /// How long to look away. Not adjustable: it is the name of the rule.
    private static let rest: TimeInterval = 20

    private var pending: DispatchWorkItem?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        watchAway()
        reload()
    }

    /// Called when the module or its interval changes in Settings.
    func reload() {
        pending?.cancel()
        pending = nil
        restingUntil = nil
        guard Settings.shared.eyeBreak else {
            nextBreak = nil
            return
        }
        schedule(after: max(60, Settings.shared.eyeBreakMinutes * 60))
    }

    private func schedule(after seconds: TimeInterval) {
        pending?.cancel()
        nextBreak = Date().addingTimeInterval(seconds)
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func fire() {
        pending = nil
        guard Settings.shared.eyeBreak else { return }

        // Never over a call. The microphone being live is the one cheap signal
        // that an interruption would land in front of other people, and five
        // minutes later is soon enough for a reminder about eye strain.
        if AudioMonitor.shared.micRunning {
            schedule(after: 5 * 60)
            return
        }

        let until = Date().addingTimeInterval(Self.rest)
        restingUntil = until
        HUD.shared.show(.eyeBreak(until: until), for: Self.rest)
        // The next interval starts when this break ends, so the twenty seconds are
        // not counted as work.
        schedule(after: Self.rest + max(60, Settings.shared.eyeBreakMinutes * 60))
    }

    /// Ends the break early, from a click on the activity.
    func skip() {
        guard restingUntil != nil else { return }
        restingUntil = nil
        // Replaces the activity rather than leaving the island blank, so the click
        // visibly did something.
        HUD.shared.show(
            .utility(symbol: "eye.slash", title: "Break skipped",
                     detail: "Next in \(Int(Settings.shared.eyeBreakMinutes)) min"),
            for: 1.6
        )
    }

    /// Lock, sleep and wake. All three are posted by the system; nothing polls to
    /// find out whether anyone is there.
    private func watchAway() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { EyeBreak.shared.away() }
        }
        distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { EyeBreak.shared.back() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EyeBreak.shared.away() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EyeBreak.shared.back() }
        }
    }

    private func away() {
        pending?.cancel()
        pending = nil
        nextBreak = nil
        restingUntil = nil
    }

    private func back() {
        guard Settings.shared.eyeBreak, pending == nil else { return }
        schedule(after: max(60, Settings.shared.eyeBreakMinutes * 60))
    }

    /// Remaining time until the next break, for the Tools card.
    var untilNext: String? {
        guard let nextBreak else { return nil }
        let seconds = max(0, Int(nextBreak.timeIntervalSinceNow))
        return seconds >= 60 ? "\(seconds / 60) min" : "\(seconds)s"
    }
}
