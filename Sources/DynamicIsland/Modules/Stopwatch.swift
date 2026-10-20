import Foundation

/// Stopwatch.
///
/// Like the countdown, this stores dates rather than counting. Nothing ticks
/// while the island is shut; the UI derives elapsed time whenever it draws.
@MainActor
@Observable
final class Stopwatch {
    static let shared = Stopwatch()

    private(set) var startedAt: Date?
    private(set) var accumulated: TimeInterval = 0
    private(set) var laps: [TimeInterval] = []

    var running: Bool { startedAt != nil }

    var elapsed: TimeInterval {
        guard let startedAt else { return accumulated }
        return accumulated + Date().timeIntervalSince(startedAt)
    }

    private static let startedKey = "stopwatchStartedAt"
    private static let accumulatedKey = "stopwatchAccumulated"
    private static let lapsKey = "stopwatchLaps"

    private init() {}

    /// Called explicitly at launch; the singleton is lazy.
    func restoreState() {
        let defaults = UserDefaults.standard
        accumulated = defaults.double(forKey: Self.accumulatedKey)
        laps = defaults.array(forKey: Self.lapsKey) as? [TimeInterval] ?? []
        // A stopwatch left running keeps counting across the quit, because the
        // elapsed time is derived from the start date rather than a tick.
        if let stamp = defaults.object(forKey: Self.startedKey) as? Double, stamp > 0 {
            startedAt = Date(timeIntervalSince1970: stamp)
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(startedAt?.timeIntervalSince1970 ?? 0, forKey: Self.startedKey)
        defaults.set(accumulated, forKey: Self.accumulatedKey)
        defaults.set(laps, forKey: Self.lapsKey)
    }

    func toggle() {
        if let startedAt {
            accumulated += Date().timeIntervalSince(startedAt)
            self.startedAt = nil
        } else {
            startedAt = Date()
        }
        persist()
    }

    func lap() {
        guard running else { return }
        laps.insert(elapsed, at: 0)
        persist()
    }

    func reset() {
        startedAt = nil
        accumulated = 0
        laps.removeAll()
        persist()
    }

    /// `m:ss.hh`, or `h:mm:ss.hh` past an hour.
    static func text(_ interval: TimeInterval) -> String {
        let total = max(0, interval)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let hundredths = Int((total - floor(total)) * 100)
        return h > 0
            ? String(format: "%d:%02d:%02d.%02d", h, m, s, hundredths)
            : String(format: "%d:%02d.%02d", m, s, hundredths)
    }
}
