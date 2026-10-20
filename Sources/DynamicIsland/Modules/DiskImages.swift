import AppKit
import Foundation

/// Turns "mount, drag to Applications, eject, bin the download" into one click.
///
/// Event-driven and free at rest: `NSWorkspace` posts a mount notification, and
/// nothing here runs between mounts. The volume is only read once, when macOS
/// says a new one appeared.
///
/// Idea borrowed from Vorssaint's disk image installer; the implementation is
/// this project's own.
@MainActor
@Observable
final class DiskImages {
    static let shared = DiskImages()

    /// The app waiting to be installed, and the volume it came from.
    private(set) var pending: (app: URL, volume: URL)?

    private init() {}

    /// Always listens - a mount notification costs nothing until a disk
    /// arrives - so switching the module on works without a relaunch.
    /// `inspect` is where the setting is honoured.
    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.inspect(url) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated {
                if self?.pending?.volume == url { self?.pending = nil }
            }
        }
    }

    private func inspect(_ volume: URL) {
        guard Settings.shared.diskImages else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: volume, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        // Exactly one app, or this is not the "drag me to Applications" layout
        // and guessing which one the user wanted would be worse than saying
        // nothing at all.
        let apps = contents.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { return }

        pending = (app, volume)
        HUD.shared.show(
            .install(name: app.deletingPathExtension().lastPathComponent,
                     icon: NSWorkspace.shared.icon(forFile: app.path)),
            for: 6
        )
    }

    /// Copies the app in, replaces any older copy, and ejects the image.
    ///
    /// The old copy goes to the Trash rather than being deleted - an update that
    /// turns out to be worse is a thing that happens, and Trash is the undo.
    func install() {
        guard let (app, volume) = pending else { return }
        pending = nil
        let name = app.lastPathComponent
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(name)

        HUD.shared.show(
            .utility(symbol: "arrow.down.app.fill", title: "Installing", detail: name),
            for: 30
        )

        // Copying a bundle is real work and must not block the island.
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = FileManager()
            var failure: String?
            do {
                if manager.fileExists(atPath: destination.path) {
                    try manager.trashItem(at: destination, resultingItemURL: nil)
                }
                try manager.copyItem(at: app, to: destination)
            } catch {
                failure = error.localizedDescription
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failure {
                        HUD.shared.show(
                            .utility(symbol: "exclamationmark.triangle.fill",
                                     title: "Could not install",
                                     detail: failure),
                            for: 4
                        )
                        return
                    }
                    try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                    HUD.shared.show(
                        .utility(symbol: "checkmark.circle.fill",
                                 title: name.replacingOccurrences(of: ".app", with: ""),
                                 detail: "Installed and ejected"),
                        for: 3
                    )
                }
            }
        }
    }

    func dismiss() {
        pending = nil
    }
}
