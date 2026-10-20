import AppKit
import Foundation

/// Outdated apps, in one list.
///
/// Homebrew always, and the App Store too when `mas` is installed. Both are
/// asked only when you press Check - this is the one module that touches the
/// network, and it never does so on its own. No background checking, no daily
/// timer, nothing at rest.
///
/// Idea borrowed from Vorssaint's app updates; implementation here is this
/// project's own.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    struct Item: Identifiable, Equatable {
        var id: String { source.rawValue + name }
        let name: String
        let current: String
        let latest: String
        let source: Source

        enum Source: String { case formula, cask, appStore }

        var detail: String {
            current.isEmpty ? latest : "\(current) → \(latest)"
        }

        var symbol: String {
            switch source {
            case .formula: "shippingbox.fill"
            case .cask: "app.fill"
            case .appStore: "bag.fill"
            }
        }
    }

    private(set) var items: [Item] = []
    private(set) var checking = false
    private(set) var working: String?
    private(set) var lastChecked: Date?
    private(set) var message: String?

    private init() {}

    /// Homebrew's own path, wherever it landed. Apple Silicon puts it in
    /// /opt/homebrew; Intel and some manual installs use /usr/local.
    private static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static var mas: String? {
        ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    var brewAvailable: Bool { Self.brew != nil }

    func check() {
        guard !checking else { return }
        guard let brew = Self.brew else {
            message = "Homebrew not installed"
            return
        }
        checking = true
        message = nil
        let mas = Self.mas

        DispatchQueue.global(qos: .userInitiated).async {
            var found: [Item] = []

            // JSON rather than the plain listing: the human-readable output
            // changes between Homebrew releases, the schema does not.
            if let data = Self.run(brew, ["outdated", "--json=v2"]),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for entry in root["formulae"] as? [[String: Any]] ?? [] {
                    guard let name = entry["name"] as? String else { continue }
                    found.append(Item(
                        name: name,
                        current: (entry["installed_versions"] as? [String])?.first ?? "",
                        latest: entry["current_version"] as? String ?? "",
                        source: .formula
                    ))
                }
                for entry in root["casks"] as? [[String: Any]] ?? [] {
                    guard let name = entry["name"] as? String else { continue }
                    found.append(Item(
                        name: name,
                        current: (entry["installed_versions"] as? [String])?.first
                            ?? entry["installed_version"] as? String ?? "",
                        latest: entry["current_version"] as? String ?? "",
                        source: .cask
                    ))
                }
            }

            if let mas, let data = Self.run(mas, ["outdated"]),
               let text = String(data: data, encoding: .utf8) {
                // `mas outdated` prints: <id> <Name> (<old> -> <new>)
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    let rest = parts[1]
                    let name = rest.components(separatedBy: " (").first ?? rest
                    let versions = rest.components(separatedBy: " (").last?
                        .replacingOccurrences(of: ")", with: "") ?? ""
                    found.append(Item(
                        name: name.trimmingCharacters(in: .whitespaces),
                        current: "",
                        latest: versions.replacingOccurrences(of: " -> ", with: " → "),
                        source: .appStore
                    ))
                }
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.items = found.sorted { $0.name.lowercased() < $1.name.lowercased() }
                    self.checking = false
                    self.lastChecked = .now
                    if found.isEmpty { self.message = "Everything is up to date" }
                }
            }
        }
    }

    /// Upgrades one item. Homebrew only - the App Store cannot be driven from
    /// here, so those rows open the App Store instead.
    func upgrade(_ item: Item) {
        guard item.source != .appStore else {
            NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
            return
        }
        guard let brew = Self.brew, working == nil else { return }
        working = item.name
        let arguments = item.source == .cask
            ? ["upgrade", "--cask", item.name]
            : ["upgrade", item.name]

        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.run(brew, arguments)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.working = nil
                    self.items.removeAll { $0.id == item.id }
                    HUD.shared.show(
                        .utility(symbol: "arrow.down.circle.fill",
                                 title: item.name, detail: "Updated"),
                        for: 2.4
                    )
                }
            }
        }
    }

    /// `nonisolated` and it must be: this runs on a background queue, and a static
    /// on a `@MainActor` class inherits that isolation. Without this the closure
    /// inside it trips `dispatch_assert_queue` and takes the app down with
    /// SIGTRAP - a real crash, hit on the very first Check.
    // MARK: - Homebrew manager

    struct Package: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let cask: Bool
        var installed: Bool
    }

    private(set) var results: [Package] = []
    private(set) var searching = false

    /// Searches formulae and casks by name.
    ///
    /// `brew search` hits the local tap index, not the network, so this stays
    /// fast and works offline. Installed state comes from one `brew list` rather
    /// than a query per row.
    func search(_ term: String) {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let brew = Self.brew, !query.isEmpty, !searching else {
            if query.isEmpty { results = [] }
            return
        }
        searching = true

        DispatchQueue.global(qos: .userInitiated).async {
            let installed = Set(
                (String(data: Self.run(brew, ["list", "-1"]) ?? Data(), encoding: .utf8) ?? "")
                    .split(separator: "\n").map(String.init)
            )

            func names(_ arguments: [String]) -> [String] {
                guard let data = Self.run(brew, arguments),
                      let text = String(data: data, encoding: .utf8) else { return [] }
                return text.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    // `brew search` prints section headers like "==> Formulae".
                    .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
            }

            let formulae = names(["search", "--formula", query]).prefix(20)
            let casks = names(["search", "--cask", query]).prefix(20)
            let found = formulae.map { Package(name: $0, cask: false, installed: installed.contains($0)) }
                + casks.map { Package(name: $0, cask: true, installed: installed.contains($0)) }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.results = found
                    self.searching = false
                }
            }
        }
    }

    func clearSearch() {
        results = []
    }

    /// Installs or removes one package.
    ///
    /// Removal is `brew uninstall`, which is Homebrew's own reversible-by-
    /// reinstall path - nothing here deletes anything Homebrew does not own.
    func toggleInstall(_ package: Package) {
        guard let brew = Self.brew, working == nil else { return }
        working = package.name
        let installing = !package.installed
        var arguments = [installing ? "install" : "uninstall"]
        if package.cask { arguments.append("--cask") }
        arguments.append(package.name)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.run(brew, arguments)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.working = nil
                    if let index = self.results.firstIndex(where: { $0.id == package.id }) {
                        self.results[index].installed = installing
                    }
                    HUD.shared.show(
                        .utility(symbol: installing ? "shippingbox.fill" : "trash.fill",
                                 title: package.name,
                                 detail: installing ? "Installed" : "Removed"),
                        for: 2.4
                    )
                }
            }
        }
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Homebrew shells out to git and curl, which need a sane PATH.
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        ) { _, new in new }
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
