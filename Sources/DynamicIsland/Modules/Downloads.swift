import AppKit
import Foundation

/// Announces finished downloads.
///
/// Watches the Downloads folder with a `DispatchSource` and diffs the listing on
/// change - no polling, and nothing runs while the folder is quiet.
@MainActor
@Observable
final class Downloads {
    static let shared = Downloads()

    /// Extensions browsers use for a download still in flight. A file is only
    /// announced once it no longer carries one.
    private static let partial: Set<String> = ["crdownload", "download", "part", "tmp", "partial", "opdownload"]

    private var known: Set<String> = []
    private var watcher: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var started = false

    private var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    private init() {}

    static let permissionKey = "downloads"

    var authorized: Bool { FolderAccess.granted(Self.permissionKey) }

    /// Raises the folder dialog on purpose, from the button in Settings.
    func requestAccess() {
        FolderAccess.probe(Self.permissionKey, folder, refused: {
            Permissions.open("Privacy_FilesAndFolders")
        }) { [weak self] baseline in
            self?.attach(baseline)
        }
    }

    func start() {
        // Never the first toucher of a protected folder. See `FolderAccess`.
        guard Settings.shared.downloads, authorized, watcher == nil else { return }
        FolderAccess.probe(Self.permissionKey, folder) { [weak self] baseline in
            self?.attach(baseline)
        }
    }

    private func attach(_ baseline: Set<String>) {
        guard watcher == nil else { return }
        known = baseline
        descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.diff() }
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        watcher = source
        started = true
    }

    private func listing() -> Set<String> {
        FolderAccess.listing(folder) ?? []
    }

    /// Newest by modification time. Alphabetical order picks the wrong file
    /// whenever two land together - and "the one that just finished" is the one
    /// worth announcing.
    private func newest(_ names: Set<String>, in folder: URL) -> String? {
        names.max { a, b in
            let left = (try? folder.appendingPathComponent(a).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? folder.appendingPathComponent(b).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left < right
        }
    }

    private func diff() {
        let current = listing()
        defer { known = current }
        guard started else { return }

        let added = current.subtracting(known)
            .filter { !Self.partial.contains(($0 as NSString).pathExtension.lowercased()) }
        // A rename from foo.crdownload to foo lands here as one addition, which
        // is exactly the moment worth announcing.
        guard let name = newest(added, in: folder) else { return }

        // The icon is read after a beat, not on the rename. A file the browser
        // has only just moved into place still reports the generic document
        // icon, which is what made a finished download look like a broken one -
        // by the time the type is registered the real icon is there.
        let url = folder.appendingPathComponent(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard Settings.shared.downloads,
                  FileManager.default.fileExists(atPath: url.path)
            else { return }
            HUD.shared.show(
                .download(name: name, icon: NSWorkspace.shared.icon(forFile: url.path)),
                for: 2.6
            )
        }
    }

}
