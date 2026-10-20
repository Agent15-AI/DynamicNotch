import AppKit

/// What is listening on a port, and a way to stop it.
///
/// The answer to "port 3000 is already in use" without leaving the island for a
/// terminal. On demand only - nothing is listed until the Tools tab asks, and
/// nothing watches sockets.
///
/// ponytail: `lsof` already enumerates sockets, already resolves them to
/// processes, and is already on every Mac. Reading the same tables through
/// `libproc` would be several hundred lines to arrive at the same list.
@MainActor
@Observable
final class Ports {
    static let shared = Ports()

    struct Listener: Identifiable, Equatable {
        var id: String { "\(pid):\(port)" }
        let port: Int
        let pid: pid_t
        let name: String
        /// Set when the process belongs to an app bundle, for the icon.
        let bundlePath: String?
    }

    private(set) var listeners: [Listener] = []
    private(set) var scanning = false

    private init() {}

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task {
            let found = await Self.scan()
            listeners = found
            scanning = false
        }
    }

    /// Sends SIGTERM, the signal a process can clean up after. A dev server
    /// that ignores it is a dev server that would have needed SIGKILL from a
    /// terminal too, and killing harder from a menu bar app is not a decision
    /// worth making on someone's behalf.
    func stop(_ listener: Listener) {
        guard kill(listener.pid, SIGTERM) == 0 else {
            HUD.shared.show(
                .utility(symbol: "exclamationmark.triangle.fill", title: "Could not stop",
                         detail: "\(listener.name) on \(listener.port)"), for: 2.2)
            return
        }
        listeners.removeAll { $0.id == listener.id }
        HUD.shared.show(
            .utility(symbol: "stop.circle.fill", title: "Stopped",
                     detail: "\(listener.name) on port \(listener.port)"), for: 1.8)
        // A process takes a moment to actually go, so the list is re-read
        // rather than trusted to the removal above.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    }

    /// Only this user's processes. `lsof` without root shows exactly those,
    /// which is also the only set worth offering to stop.
    nonisolated private static func scan() async -> [Listener] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        process.waitUntilExit()

        // `-F pcn` is one field per line, tagged by its first character: p is a
        // pid and starts a record, c is the command, n is the socket. Parsing
        // that is exact, unlike splitting lsof's columns - process names may
        // contain spaces.
        var found: [Listener] = []
        var seen = Set<String>()
        var pid: pid_t = 0
        var name = ""
        for line in text.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = pid_t(value) ?? 0; name = ""
            case "c": name = value
            case "n":
                // "*:3000", "127.0.0.1:3000", "[::1]:3000"
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]), pid > 0
                else { continue }
                let listener = Listener(
                    port: port, pid: pid, name: name,
                    bundlePath: NSRunningApplication(processIdentifier: pid)?.bundleURL?.path)
                // One row per process per port: a server bound to both IPv4 and
                // IPv6 is one thing to stop, not two.
                if seen.insert(listener.id).inserted { found.append(listener) }
            default: break
            }
        }
        return found.sorted { $0.port < $1.port }
    }
}
