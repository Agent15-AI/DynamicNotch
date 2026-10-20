import Foundation

/// Current Focus / Do Not Disturb state.
///
/// macOS records active Focus assertions in a JSON file under the user's
/// library, so this is a file watch - no polling, and nothing runs while Focus
/// is unchanged. There is no public API for reading another process's Focus.
@MainActor
@Observable
final class FocusMode {
    static let shared = FocusMode()

    private(set) var active = false
    /// Human name of the mode, when one can be resolved.
    private(set) var name: String?

    var symbol: String {
        guard active else { return "moon" }
        guard let value = name?.lowercased() else { return "moon.fill" }
        if value.contains("sleep") { return "bed.double.fill" }
        if value.contains("work") { return "briefcase.fill" }
        if value.contains("personal") { return "person.fill" }
        if value.contains("driv") { return "car.fill" }
        if value.contains("fitness") { return "figure.run" }
        if value.contains("game") { return "gamecontroller.fill" }
        if value.contains("read") { return "book.fill" }
        return "moon.fill"
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1

    private var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
    }

    private init() {}

    func start() {
        guard Settings.shared.focus else { return }
        read()
        watch()
    }

    private func watch() {
        descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                let flags = source.data
                if flags.contains(.delete) || flags.contains(.rename) {
                    // macOS replaces the file rather than writing in place.
                    self.stopWatching()
                    self.watch()
                }
                self.read()
            }
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        descriptor = -1
    }

    private func read() {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["data"] as? [[String: Any]]
        else { active = false; name = nil; return }

        // An assertion present means a Focus is on; its mode identifier carries
        // the name, in the form com.apple.<something>.mode.<name>.
        let assertions = records.compactMap { $0["storeAssertionRecords"] as? [[String: Any]] }.flatMap { $0 }
        guard let first = assertions.first,
              let details = first["assertionDetails"] as? [String: Any]
        else { active = false; name = nil; return }

        active = true
        if let identifier = details["assertionDetailsModeIdentifier"] as? String {
            name = identifier.split(separator: ".").last.map(String.init)?.replacingOccurrences(of: "-", with: " ")
        } else {
            name = nil
        }
    }
}
