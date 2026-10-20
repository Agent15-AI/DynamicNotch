import Foundation

/// Download speed, measured on demand.
///
/// The only thing in the app that reaches the network without being asked to
/// carry data somewhere - so it never runs on its own, has no schedule, and
/// holds nothing between runs.
///
/// Idea borrowed from Vorssaint's speed test; implementation here is this
/// project's own.
@MainActor
@Observable
final class SpeedTest {
    static let shared = SpeedTest()

    private(set) var running = false
    private(set) var megabitsPerSecond: Double?
    private(set) var message: String?

    private var task: URLSessionDataTask?

    private init() {}

    /// 25 MB from Cloudflare's speed endpoint. Big enough that the connection
    /// leaves slow start, small enough to finish on a poor line.
    private static let url = URL(string: "https://speed.cloudflare.com/__down?bytes=25000000")!

    func run() {
        guard !running else { return }
        running = true
        message = nil
        megabitsPerSecond = nil

        let started = Date()
        // Ephemeral so a second run measures the network, not the cache.
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: Self.url) { data, _, error in
            let elapsed = Date().timeIntervalSince(started)
            Task { @MainActor in
                self.running = false
                guard let data, error == nil, elapsed > 0 else {
                    self.message = "Could not reach the test server"
                    return
                }
                self.megabitsPerSecond = Double(data.count) * 8 / elapsed / 1_000_000
            }
        }
        self.task = task
        task.resume()
        // A session holds its delegate queue until invalidated; one per press
        // would otherwise outlive every test ever run.
        session.finishTasksAndInvalidate()
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }

    var text: String {
        if running { return "Testing…" }
        if let megabitsPerSecond { return String(format: "%.0f Mbps", megabitsPerSecond) }
        return message ?? "Not tested"
    }
}
