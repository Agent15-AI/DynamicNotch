import AppKit
import UniformTypeIdentifiers

/// Drop files onto the notch, park them, drag them back out or AirDrop them.
///
/// ponytail: holds file URLs, it does not copy anything. Nothing is duplicated
/// on disk and there is no store to garbage-collect. Files that move or get
/// deleted behind our back are pruned on next read.
@MainActor
@Observable
final class Shelf {
    static let shared = Shelf()

    private(set) var items: [URL] = []

    /// Security-scoped bookmarks, so a parked file is still reachable after a
    /// relaunch. Plain paths would survive the quit but not the sandbox rules
    /// macOS applies to files reached from another app's drag.
    private static let key = "shelfBookmarks"

    private init() { load() }

    private func load() {
        guard let stored = UserDefaults.standard.array(forKey: Self.key) as? [Data] else { return }
        items = stored.compactMap { data in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    private func save() {
        let bookmarks = items.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.key)
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) {
            items.append(url)
        }
        prune()
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func prune() {
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
    }

    func airDrop() {
        prune()
        guard !items.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop)
        else { return }
        service.perform(withItems: items)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}
