import AppKit

/// Files, from the index macOS already keeps.
///
/// ponytail: no crawler, no index, no watcher. Spotlight maintains all three
/// and an `NSMetadataQuery` is a question asked of it, not a thing that runs.
/// `mdfind` would be a subprocess per keystroke and would throw away the sort
/// keys, so the in-process query wins on both counts.
///
/// A query is live once it has gathered - it keeps posting updates as the disk
/// changes - so it is stopped and dropped the moment the bar closes. One left
/// running is a permanent wakeup source, which is the single thing this app is
/// built not to have.
@MainActor
@Observable
final class FileSearch {
    static let shared = FileSearch()

    private(set) var results: [URL] = []
    /// Called when results arrive, because they arrive long after the keystroke
    /// that asked for them. Every other source in the command bar is synchronous.
    var onChange: (() -> Void)?

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var asked = ""

    private init() {}

    /// Debounced, with a floor. Restarting the query on every keystroke thrashes
    /// the index, and a one- or two-letter query matches most of the disk.
    func search(_ text: String) {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        guard wanted != asked else { return }
        asked = wanted
        pending?.cancel()
        guard wanted.count >= 3, Settings.shared.fileSearch else {
            stop()
            if !results.isEmpty { results = []; onChange?() }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.start(wanted) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        query?.stop()
        query = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    func reset() {
        stop()
        asked = ""
        results = []
    }

    private func start(_ text: String) {
        stop()
        let query = NSMetadataQuery()
        // `kMDItemFSName` is the name on disk, which is what people search by.
        // `kMDItemDisplayName` hides extensions and localises app names, so a
        // search for "pdf" matches nothing and "Systemeinstellungen" matches
        // on a German Mac.
        query.predicate = NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*\(text)*")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        // What you touched last is what you meant, nearly always. This one line
        // is most of the difference between search that feels psychic and
        // search that returns a thousand files in alphabetical order.
        query.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false),
            NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false),
        ]
        // A broad match otherwise delivers a notification per batch of results.
        query.notificationBatchingInterval = 0.25
        query.operationQueue = .main

        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering,
                     NSNotification.Name.NSMetadataQueryDidUpdate] {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.gathered() }
            }
            observers.append(observer)
        }
        self.query = query
        query.start()
    }

    private func gathered() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var seen = Set<String>()
        var found: [URL] = []
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  Self.isInteresting(path), seen.insert(path).inserted
            else { continue }
            found.append(URL(fileURLWithPath: path))
            if found.count == 6 { break }
        }
        guard found != results else { return }
        results = found
        onChange?()
    }

    /// An unfiltered query for "config" is several thousand bundle internals and
    /// caches. Cutting them is the difference between this being usable and
    /// being unusable, and it is the step every hand-rolled file search skips.
    private static func isInteresting(_ path: String) -> Bool {
        if path.hasPrefix("/System") || path.hasPrefix("/private") || path.hasPrefix("/usr") { return false }
        if path.hasPrefix("/Library") || path.hasPrefix(NSHomeDirectory() + "/Library") { return false }
        for part in [
            "/node_modules/", "/.git/", "/.build/", "/DerivedData/", "/Pods/",
            "/.venv/", "/site-packages/", "/__pycache__/", "/vendor/",
            ".app/", ".framework/", ".xcodeproj/", ".xcassets/", ".bundle/", ".lproj/",
        ] where path.contains(part) { return false }
        return true
    }

    // MARK: - Presentation

    /// The containing folder, written the way a person would say it. A file
    /// result without its folder is unidentifiable the moment two of them share
    /// a name, which for "index.html" or "notes.md" is immediately.
    static func folder(of url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}
