import AppKit
import CoreServices
import Foundation

/// Catches a screenshot the moment it is written and offers it back.
///
/// Same shape as `Downloads`: a `DispatchSource` on the folder, a diff of the
/// listing on write. Nothing runs while nobody is capturing.
///
/// The point is what happens next - the shot can be dragged straight out of the
/// closed island into whatever needed it, without a trip through the Desktop.
@MainActor
@Observable
final class Screenshots {
    static let shared = Screenshots()

    private static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "pdf"]

    private var known: Set<String> = []
    private var watcher: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var started = false

    private init() {}

    /// Wherever `screencapture` has been told to write. Defaults to the Desktop,
    /// which is also where macOS puts it when the key is unset.
    private var folder: URL {
        let stored = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let stored, !stored.isEmpty {
            return URL(fileURLWithPath: (stored as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    static let permissionKey = "screenshots"

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
        guard Settings.shared.screenshots, authorized, watcher == nil else { return }
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

    func stop() {
        watcher?.cancel()
        watcher = nil
        descriptor = -1
        started = false
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
            .filter { Self.imageTypes.contains(($0 as NSString).pathExtension.lowercased()) }
        guard let name = newest(added, in: folder) else { return }

        // `screencapture` creates the file before it has finished writing it, so
        // reading the image on this event gets an empty or half-written frame.
        // One work item, cancelled by nothing and repeating never.
        let url = folder.appendingPathComponent(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.announce(url)
        }
    }

    private func announce(_ url: URL) {
        guard Settings.shared.screenshots, Self.isCapture(url),
              let image = NSImage(contentsOf: url), image.size.width > 0
        else { return }
        HUD.shared.show(
            .screenshot(name: url.lastPathComponent, image: Self.downsampled(image), url: url),
            for: 4.5
        )
    }

    /// `screencapture` tags what it writes. Trust the tag when Spotlight has one
    /// and fall back to accepting, so the feature still works on a volume that
    /// is not indexed - the cost of being wrong is one thumbnail of an image the
    /// user just put there anyway.
    private static func isCapture(_ url: URL) -> Bool {
        guard let item = MDItemCreate(nil, url.path as CFString),
              let flag = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool
        else { return true }
        return flag
    }

    /// A full-resolution Retina screenshot held in the HUD is tens of megabytes
    /// for a thumbnail drawn at 30pt.
    private static func downsampled(_ image: NSImage, to side: CGFloat = 220) -> NSImage {
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        guard scale < 1 else { return image }
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = NSImage(size: size)
        small.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        small.unlockFocus()
        return small
    }
}
