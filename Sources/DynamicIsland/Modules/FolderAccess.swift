import Foundation

/// Whether macOS has let us read a protected folder, remembered across launches.
///
/// Downloads, Desktop and Documents are TCC-protected: the first `contentsOfDirectory`
/// raises a permission dialog. That dialog is fine once. What is not fine is
/// raising it on every launch, which is what a folder watcher started
/// unconditionally does - an unanswered prompt is not a denial, so macOS asks
/// again next time, and a TCC grant is keyed to the code signature, so every
/// rebuild looks like a new app and starts the cycle over.
///
/// So the rule is the same as for Calendar and Bluetooth: never touch the folder
/// on launch unless a previous read already succeeded. The first read happens
/// when the user presses Allow, which is the one moment a dialog is expected.
enum FolderAccess {
    /// Reads the folder. Returns nil when macOS refused, which is the signal
    /// that the permission has not been granted.
    static func listing(_ folder: URL) -> Set<String>? {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return Set(names.filter { !$0.hasPrefix(".") })
        } catch {
            return nil
        }
    }

    /// Probes the folder off the main thread, then hands the baseline back.
    ///
    /// Two reasons this cannot be a plain synchronous read on launch. A TCC
    /// dialog blocks the calling thread until it is answered, so reading on the
    /// main thread freezes the whole island behind a dialog the user may not be
    /// at the machine to answer. And the flag is cleared *before* the attempt,
    /// so an attempt that never comes back is remembered as a failure - which
    /// means one unanswered dialog, not a fresh one on every launch.
    static func probe(_ key: String, _ folder: URL, then handler: @escaping @MainActor (Set<String>) -> Void) {
        setGranted(key, false)
        DispatchQueue.global(qos: .utility).async {
            let names = listing(folder)
            DispatchQueue.main.async {
                guard let names else { return }
                setGranted(key, true)
                MainActor.assumeIsolated { handler(names) }
            }
        }
    }

    static func granted(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: "granted-" + key)
    }

    static func setGranted(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: "granted-" + key)
    }

    /// Deliberately raises the dialog, then remembers the answer.
    @discardableResult
    static func request(_ key: String, _ folder: URL) -> Bool {
        let ok = listing(folder) != nil
        setGranted(key, ok)
        return ok
    }
}
