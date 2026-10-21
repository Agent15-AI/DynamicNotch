import AppKit

/// Search, install and remove Homebrew packages without a terminal.
///
/// On demand only. Nothing is listed until asked, no index is kept, and
/// `brew` is never run in the background - which also means this can never be
/// the thing that woke your Mac to check for updates.
///
/// ponytail: `brew` is the whole implementation. Parsing the JSON API from
/// formulae.brew.sh would be a second source of truth about what is installed
/// locally, and would still need `brew` to do anything about it.
@MainActor
@Observable
final class Homebrew {
    static let shared = Homebrew()

    struct Package: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let cask: Bool
        var installed: Bool
    }

    private(set) var results: [Package] = []
    private(set) var installed: Set<String> = []
    private(set) var busy: String?
    private(set) var searching = false
    /// Nil until looked for; empty string means Homebrew is not installed.
    private(set) var path: String?

    private init() {}

    var available: Bool { !(path ?? "").isEmpty }

    /// The two places Homebrew puts itself: Apple silicon and Intel.
    func locate() {
        guard path == nil else { return }
        path = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }

    func search(_ text: String) {
        locate()
        let query = text.trimmingCharacters(in: .whitespaces)
        guard available, query.count >= 2, !searching else {
            if query.count < 2 { results = [] }
            return
        }
        searching = true
        let brew = path!
        Task {
            // The installed list comes back with the search so a result can say
            // whether it is already here, which is the first thing you want to
            // know and the thing `brew search` does not tell you.
            async let formulae = Self.run(brew, ["search", "--formula", query])
            async let casks = Self.run(brew, ["search", "--cask", query])
            async let present = Self.run(brew, ["list", "-1"])

            let here = Set(await present.split(whereSeparator: \.isNewline).map(String.init))
            installed = here
            var found = await formulae.split(whereSeparator: \.isNewline)
                .map { Package(name: String($0), cask: false, installed: here.contains(String($0))) }
            found += await casks.split(whereSeparator: \.isNewline)
                .map { Package(name: String($0), cask: true, installed: here.contains(String($0))) }
            // Exact and prefix matches first: searching "wget" should not list
            // twenty packages that merely mention it before wget itself.
            results = found
                .filter { Self.isPackageName($0.name) }
                .sorted { left, right in
                    let l = left.name.lowercased() == query.lowercased()
                    let r = right.name.lowercased() == query.lowercased()
                    if l != r { return l }
                    let lp = left.name.lowercased().hasPrefix(query.lowercased())
                    let rp = right.name.lowercased().hasPrefix(query.lowercased())
                    return lp == rp ? left.name.count < right.name.count : lp
                }
                .prefix(12)
                .map { $0 }
            searching = false
        }
    }

    func install(_ package: Package) { act(package, install: true) }
    func remove(_ package: Package) { act(package, install: false) }

    private func act(_ package: Package, install: Bool) {
        guard available, busy == nil else { return }
        busy = package.name
        let brew = path!
        let arguments = [install ? "install" : "uninstall"]
            + (package.cask ? ["--cask"] : [])
            + [package.name]
        Task {
            let output = await Self.run(brew, arguments, timeout: 600)
            busy = nil
            // `brew` reports failure in prose on stdout as often as in its exit
            // code, so the receipt says which package and lets the user look.
            // One test for both: "No such keg" is an Error line too, and only
            // looking for that one reported "Removed" for a package `brew`
            // refused to uninstall because something else depends on it.
            let worked = !output.lowercased().contains("error")
            if worked, let index = results.firstIndex(where: { $0.id == package.id }) {
                results[index].installed = install
            }
            HUD.shared.show(.utility(
                symbol: worked ? (install ? "shippingbox.fill" : "trash.fill") : "exclamationmark.triangle.fill",
                title: worked ? (install ? "Installed" : "Removed") : "Homebrew failed",
                detail: package.name), for: 2.2)
        }
    }

    /// `brew search` writes its headings and its failures to the same stream as
    /// its results, so "Error: No formulae or casks found" arrived as a package
    /// called `Error:` - with an ANSI colour escape still wrapped round it,
    /// because `HOMEBREW_COLOR=0` is not honoured on that line. Rather than
    /// blacklisting each thing it can say, only accept what a package name can
    /// actually look like.
    nonisolated private static func isPackageName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 64, let first = text.first, first.isLetter || first.isNumber
        else { return false }
        return text.allSatisfy { $0.isLowercase || $0.isNumber || "@+._-".contains($0) }
    }

    nonisolated private static func run(_ brew: String, _ arguments: [String],
                                        timeout: TimeInterval = 60) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brew)
                process.arguments = arguments
                // Homebrew asks questions and paints progress bars when it
                // thinks a human is watching. Neither works from here.
                var environment = ProcessInfo.processInfo.environment
                environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
                environment["HOMEBREW_NO_ENV_HINTS"] = "1"
                environment["HOMEBREW_COLOR"] = "0"
                process.environment = environment

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: "")
                    return
                }
                // The limit is armed before the read, because the read is what
                // waits: it returns only once `brew` closes its output. Checked
                // after the read, as this used to be, a hung `brew` was never
                // stopped and the row said "working" until the app quit.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                // Read before waiting: a full pipe buffer deadlocks a process
                // that is still writing to it.
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
