import AppKit
import Foundation

/// Finding things that can go: an app's leftovers, and the caches and logs that
/// accumulate under `~/Library`.
///
/// The two halves dispose of things differently, on purpose.
///
/// **Uninstall trashes.** It finds leftovers by guessing - a bundle id, or
/// failing that a name - and a name match can be wrong: uninstalling something
/// called "Google" matches the Application Support folder Chrome, Drive and
/// Earth all share. A wrong guess has to be undoable, so that half is
/// `trashItem` and always will be.
///
/// **The cache sweep deletes.** It guesses nothing: every entry is named by the
/// app that owns it and everything under `Caches` and `Logs` regenerates by
/// definition. Trashing them freed no space until the Trash was emptied, which
/// is the opposite of what a button called "free up space" is for. What makes
/// this safe is not reversibility, it is `protected` below.
///
/// Scanning is on demand and off the main thread - sizing a cache folder means
/// walking it, and some of them are large.
///
/// Idea borrowed from Vorssaint's uninstaller and cleaner; implementation here
/// is this project's own.
@MainActor
@Observable
final class Cleanup {
    static let shared = Cleanup()

    struct Item: Identifiable, Equatable {
        var id: String { url.path }
        let url: URL
        let label: String
        let bytes: Int64
        /// Empty the folder but leave the folder itself. A sandboxed app's
        /// `Data/Library/Caches` is created for it by macOS when the container
        /// is built, not by the app on demand - removing the directory outright
        /// is not something the app knows how to recover from. Idea from Purge's
        /// `shouldDeleteContentsOnly`.
        var contentsOnly = false

        var size: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    private init() {}

    // MARK: - Uninstall

    private(set) var target: URL?
    private(set) var targetName = ""
    private(set) var leftovers: [Item] = []
    private(set) var scanning = false

    var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.bytes } }

    /// Anywhere an app is allowed to leave state behind. Deliberately only the
    /// user's own library - system paths need an admin prompt and are not worth
    /// the risk of a wrong match.
    private nonisolated static let libraryFolders = [
        "Application Support", "Caches", "Containers", "Group Containers",
        "Logs", "Preferences", "Saved Application State", "WebKit",
        "HTTPStorages", "Cookies", "LaunchAgents", "Application Scripts",
    ]

    func inspect(_ app: URL) {
        guard app.pathExtension == "app" else { return }
        target = app
        targetName = app.deletingPathExtension().lastPathComponent
        leftovers = []
        scanning = true

        let bundleID = Bundle(url: app)?.bundleIdentifier
        let name = targetName
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")

        DispatchQueue.global(qos: .userInitiated).async {
            var found: [Item] = []
            let manager = FileManager()

            for folder in Self.libraryFolders {
                let directory = library.appendingPathComponent(folder)
                let entries = (try? manager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? []
                for entry in entries {
                    if Self.matches(entry.lastPathComponent, bundleID: bundleID, name: name) {
                        found.append(Item(
                            url: entry,
                            label: folder + "/" + entry.lastPathComponent,
                            bytes: Self.size(of: entry)
                        ))
                        continue
                    }
                    // A vendor folder. Chrome does not keep its state in
                    // anything called "Google Chrome" - it keeps it in
                    // `Application Support/Google/Chrome`, and a scan that only
                    // reads the top level of each folder found nothing at all
                    // for it. Descend one level, and take the child rather than
                    // the parent: `Google` is shared with Drive and Earth, and
                    // claiming it would take them with it.
                    guard Self.nestable.contains(folder),
                          (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    else { continue }
                    let children = (try? manager.contentsOfDirectory(
                        at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                    )) ?? []
                    for child in children
                    where Self.matchesNested(child.lastPathComponent, bundleID: bundleID, name: name) {
                        found.append(Item(
                            url: child,
                            label: folder + "/" + entry.lastPathComponent + "/" + child.lastPathComponent,
                            bytes: Self.size(of: child)
                        ))
                    }
                }
            }

            let sorted = found.sorted { $0.bytes > $1.bytes }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.leftovers = sorted
                    self.scanning = false
                }
            }
        }
    }

    /// Conservative on purpose. A bundle id match is exact or a dotted prefix -
    /// `com.acme.app` also owns `com.acme.app.helper`, but must never claim
    /// `com.acme.apples`. A name match has to be the whole file name, because
    /// matching a substring of "Notes" would sweep half the library.
    private nonisolated static func matches(_ component: String, bundleID: String?, name: String) -> Bool {
        let stem = (component as NSString).deletingPathExtension
        if let bundleID, !bundleID.isEmpty {
            if stem == bundleID { return true }
            if stem.hasPrefix(bundleID + ".") { return true }
            // Group containers are prefixed with a team id: group.com.acme.app.
            if stem.hasSuffix("." + bundleID) || stem.contains("." + bundleID + ".") { return true }
        }
        return stem.caseInsensitiveCompare(name) == .orderedSame
    }

    /// Folders where an app's state may sit one level down, under its vendor.
    /// Not `Preferences` or `Containers`: those are flat by convention, and
    /// descending into them would only invent matches.
    private nonisolated static let nestable: Set<String> = ["Application Support", "Caches", "Logs"]

    /// Inside a vendor folder the bundle id's last component is the app's own
    /// name - `com.google.Chrome` owns `Google/Chrome`.
    ///
    /// Only used one level down, where the parent has already narrowed the field
    /// to one vendor. Applied at the top level it would be far too loose. The
    /// length floor keeps generic leaves like `app` or `ui` out.
    private nonisolated static func matchesNested(
        _ component: String, bundleID: String?, name: String
    ) -> Bool {
        if matches(component, bundleID: bundleID, name: name) { return true }
        guard let leaf = bundleID?.split(separator: ".").last, leaf.count >= 4 else { return false }
        return (component as NSString).deletingPathExtension
            .caseInsensitiveCompare(String(leaf)) == .orderedSame
    }

    func clearTarget() {
        target = nil
        targetName = ""
        leftovers = []
    }

    /// Trashes the app and everything found beside it.
    ///
    /// Three stages, in the order that matters. Behaviour compared against
    /// Vorssaint's uninstaller (GPL-3; read for behaviour, no code taken) after
    /// this reported "0 items moved" for Sophos and did nothing else.
    ///
    /// 1. Quit the app first. A bundle that is still running holds files open
    ///    and rewrites the very preferences being removed, so trashing it
    ///    either fails or leaves the leftovers behind seconds later. Embedded
    ///    helpers do not always carry the main bundle id, so they are matched by
    ///    path as well.
    /// 2. `NSWorkspace.recycle`, which is Finder-backed and reports real errors.
    /// 3. Anything still on disk goes to Finder itself. Finder owns privilege
    ///    elevation - it raises the standard administrator prompt - and this is
    ///    the only route that can move a root-owned app like the ones under
    ///    `/Applications/Sophos`. `recycle` never prompts, which is why stage 2
    ///    alone still came back empty-handed.
    func uninstall() {
        guard let app = target else { return }
        var items = leftovers.map(\.url)
        items.append(app)
        let name = targetName
        let vendorUninstaller = Self.vendorUninstaller(beside: app)
        clearTarget()

        let bundle = app.resolvingSymlinksInPath().standardizedFileURL
        for running in NSWorkspace.shared.runningApplications {
            guard let url = running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL,
                  url == bundle || url.path.hasPrefix(bundle.path + "/")
            else { continue }
            running.terminate()
        }

        let total = items.count
        let paths = items.map(\.path)
        NSWorkspace.shared.recycle(items) { _, _ in
            // Off the main thread: Finder's administrator prompt is answered by a
            // person, and waiting for it on the main thread froze the island -
            // hover, hotkeys and all - for as long as the prompt was up.
            DispatchQueue.global(qos: .userInitiated).async {
                let urls = paths.map { URL(fileURLWithPath: $0) }
                let stubborn = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                if !stubborn.isEmpty { Self.trashViaFinder(stubborn) }
                // Re-checked after Finder has had its turn, because a cancel
                // must not read as success.
                let remaining = urls.filter { FileManager.default.fileExists(atPath: $0.path) }.count
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Self.reportUninstall(moved: total - remaining, remaining: remaining,
                                             name: name, vendorUninstaller: vendorUninstaller)
                    }
                }
            }
        }
    }

    /// What the uninstall managed, said once.
    private static func reportUninstall(
        moved: Int, remaining: Int, name: String, vendorUninstaller: URL?
    ) {
        guard moved > 0 else {
            HUD.shared.show(
                .utility(
                    symbol: "exclamationmark.triangle.fill",
                    title: "Could not remove \(name)",
                    detail: vendorUninstaller != nil
                        ? "Use its own uninstaller"
                        : "Permission denied"
                ),
                for: 4.0
            )
            if let vendorUninstaller { NSWorkspace.shared.open(vendorUninstaller) }
            return
        }
        HUD.shared.show(
            .utility(
                symbol: "trash.fill",
                title: moved == 1 ? "1 item moved" : "\(moved) items moved",
                detail: remaining == 0
                    ? "In the Trash, not deleted"
                    : "\(remaining) refused"
            ),
            for: 2.6
        )
    }

    /// Asks Finder to trash these, which raises the administrator prompt when
    /// the files need it. A reversible move to the Trash, never a delete.
    ///
    /// Blocking on purpose: a person answers the prompt, and the count reported
    /// afterwards has to be taken once they have. Called off the main thread.
    ///
    /// ponytail: paths go in as escaped AppleScript literals rather than as
    /// arguments, because a file name containing a quote would otherwise end the
    /// literal and the rest of it would be run as script.
    private nonisolated static func trashViaFinder(_ urls: [URL]) {
        let targets = urls
            .map { "set end of t to POSIX file \(literal($0.path))" }
            .joined(separator: "\n")
        let source = """
        set t to {}
        \(targets)
        tell application "Finder" to delete t
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    private nonisolated static func literal(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// An installer-managed app usually ships its own remover beside it.
    ///
    /// Sophos is the case that produced this: six bundles in a root-owned
    /// `/Applications/Sophos`, one of them called "Remove Sophos Endpoint".
    /// Nothing we are allowed to do removes the others, and that one does.
    private nonisolated static func vendorUninstaller(beside app: URL) -> URL? {
        let folder = app.deletingLastPathComponent()
        // Only inside a vendor folder. Every `/Applications` has something
        // called "Uninstall …" in it somewhere, and offering an unrelated one
        // would be worse than offering nothing.
        guard folder.lastPathComponent != "Applications" else { return nil }
        let siblings = (try? FileManager().contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return siblings.first { sibling in
            guard sibling.pathExtension == "app" else { return false }
            let stem = sibling.deletingPathExtension().lastPathComponent.lowercased()
            return stem.hasPrefix("remove ") || stem.hasPrefix("uninstall")
        }
    }

    // MARK: - Caches and logs

    /// Never offered by the sweep, and never deleted by it.
    ///
    /// Not because deleting them breaks anything - caches regenerate - but
    /// because regenerating *these* costs a download nobody asked for.
    /// Spotify's cache is downloaded music, Playwright's is a gigabyte of
    /// browser binaries, ollama's holds model blobs, and LockDown checks its own
    /// integrity and can demand a reinstall. The rest are here for the same
    /// reason: an index or a sync state that takes real time to rebuild.
    ///
    /// Prefix match, lowercased, so `ms-playwright-go` is covered by
    /// `ms-playwright` without a second entry.
    private nonisolated static let protected = [
        "com.spotify.client", "ms-playwright", "puccinialin", "ollama",
        "lockdown browser", "com.docker", "docker", "jetbrains",
        "com.apple.dt.xcode", "adobe", "steam", "com.microsoft.onedrive",
        "cloudkit", "com.apple.containermanagerd", "com.google.drivefs",
        // macOS refuses to remove this one even with Full Disk Access, so
        // offering it only produces a row that always fails.
        "diagnosticreportsfornewhardware",
        // Apple Media Services - the media-authentication stack behind the App
        // Store, Music and TV. Caught by inspection, not by the fragments
        // below: `com.apple.AppleMediaServices` and `com.apple.amsengagementd`
        // were both being offered. Prefixes rather than a fragment because the
        // obvious fragment is `ams`, which also appears in "teams", "streams"
        // and "params".
        "com.apple.ams", "com.apple.applemediaservices",
    ]

    /// Substrings that mark a folder as identity, authentication, or payment
    /// state rather than a cache.
    ///
    /// Taken from Purge (MIT, © 2026 Jithin Sabu) - specifically its note that
    /// these were "caught deleting in the wild", each one forcing a
    /// re-authorization against the Apple ID and a fresh login-keychain prompt.
    /// That is a cost no button called "free up space" should ever impose, and
    /// it is not one this project would have found without the report.
    ///
    /// Substring, not prefix, because the offenders span naming conventions:
    /// `com.apple.amsaccountsd`, `com.apple.iCloudNotificationAgent` and a bare
    /// `PassKit` share no common start. Over-matching is the safe direction -
    /// the folder is merely not offered, and these are all small. Fragments stay
    /// specific for that reason: `authkit` rather than a bare `auth`, which
    /// would also swallow anything by an "Author".
    private nonisolated static let protectedFragments = [
        "account", "icloud", "itunescloud", "appleid", "authkit",
        "authentication", "authorization", "identityservice", "keychain",
        "passkit", "passwords",
    ]

    private nonisolated static func isProtected(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if protected.contains(where: { lowered.hasPrefix($0) }) { return true }
        return protectedFragments.contains { lowered.contains($0) }
    }

    private(set) var junk: [Item] = []
    private(set) var sweeping = false

    var junkBytes: Int64 { junk.reduce(0) { $0 + $1.bytes } }

    // MARK: - Choosing what goes

    /// Which rows the delete acts on. Everything found starts selected - that is
    /// the answer almost every time, and a list that arrives entirely unticked
    /// makes the user do the work twice.
    ///
    /// The point of having it at all is that this half deletes outright. One row
    /// the user would rather keep is otherwise a reason to skip the whole sweep.
    private(set) var selected: Set<String> = []

    var selectedItems: [Item] { junk.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    func toggle(_ item: Item) {
        disarm()
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func selectAll(_ on: Bool) {
        disarm()
        selected = on ? Set(junk.map(\.id)) : []
    }

    /// Deleting outright cannot be undone, so the button arms first and only
    /// acts on a second press - the same two-step the Empty Trash tile uses, so
    /// the one irreversible gesture in the app is the same gesture everywhere.
    private(set) var armed = false
    private var disarmWork: DispatchWorkItem?

    func armOrClean() {
        guard armed else {
            armed = true
            disarmWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.armed = false }
            disarmWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            return
        }
        disarm()
        clean(selectedItems)
    }

    private func disarm() {
        disarmWork?.cancel()
        disarmWork = nil
        armed = false
    }

    /// Sizes the biggest cache and log folders. On demand: walking every cache
    /// directory is real work and must never happen on its own.
    ///
    /// Results are published **as each folder finishes**, not in one batch at the
    /// end. Measured on a real library the whole sweep takes well over twenty
    /// seconds, and a spinner that sits there for twenty seconds reads as a hang.
    /// Filling the list in as it goes turns the same wait into progress.
    func sweep() {
        guard !sweeping else { return }
        sweeping = true
        junk = []
        selected = []
        disarm()
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")

        DispatchQueue.global(qos: .userInitiated).async {
            let manager = FileManager()

            func offer(_ url: URL, label: String, contentsOnly: Bool = false,
                       budget: TimeInterval = 4) {
                let bytes = Self.size(of: url, budget: budget)
                // Anything under a megabyte is noise in a list this short.
                guard bytes > 1_000_000 else { return }
                let item = Item(url: url, label: label, bytes: bytes, contentsOnly: contentsOnly)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.junk.append(item)
                        self.selected.insert(item.id)
                        // Biggest first, so the row worth acting on is always at
                        // the top even while the rest is still arriving.
                        self.junk.sort { $0.bytes > $1.bytes }
                    }
                }
            }

            for folder in ["Caches", "Logs"] {
                let directory = library.appendingPathComponent(folder)
                let entries = (try? manager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? []
                for entry in entries {
                    // Filtered before sizing. Walking Spotify's 6.6 GB only to
                    // refuse to offer it is work for nothing.
                    guard !Self.isProtected(entry.lastPathComponent) else { continue }
                    offer(entry, label: entry.lastPathComponent)
                }
            }

            // Crash logs. Their own folder rather than part of `Logs` above,
            // because that scan only reads the top level and these sit one down.
            let reports = library.appendingPathComponent("Logs/DiagnosticReports")
            offer(reports, label: "Logs/DiagnosticReports", contentsOnly: true)

            // Build caches, which are usually the largest regenerable thing on
            // a developer's disk and sit nowhere near `Library/Caches`. Both
            // rebuild on the next build or simulator launch. Taken from
            // Vorssaint's cleaner policy (GPL-3; behaviour only, no code).
            for path in ["Developer/Xcode/DerivedData", "Developer/CoreSimulator/Caches"] {
                offer(library.appendingPathComponent(path), label: path, contentsOnly: true)
            }

            // No container scan here, deliberately. Sandboxed apps keep their
            // caches in `Containers/<id>/Data/Library/Caches`, which this sweep
            // cannot see, and reaching them looked like the biggest available
            // win. It does not survive measurement: this machine has 716
            // containers, and at least one of them blocks forever on a plain
            // `contentsOfDirectory` - a cloud-backed provider waiting on the
            // network. Timed, the rest of the sweep finishes in 0.63s and the
            // container pass never returned at all, past sixty seconds.
            //
            // A deadline between containers cannot help, because the time is
            // spent inside one blocking read that no deadline can interrupt.
            // Surviving it would mean doing each read on a thread we are willing
            // to abandon, and a permanently blocked thread is exactly the kind
            // of cost this app exists to avoid. ponytail: the feature is not
            // worth that, so it is not here.

            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.sweeping = false }
            }
        }
    }

    /// True while a delete is in flight, so the button can say so and cannot be
    /// pressed twice.
    private(set) var cleaning = false

    /// Deletes outright. See the note at the top of this file for why this half
    /// does not go through the Trash.
    ///
    /// The work happens off the main thread. It used to run inline on the main
    /// actor, walking and unlinking gigabytes while holding it - the island
    /// froze for the duration and the press looked like it had done nothing,
    /// which is most of what "unreliable" meant here.
    func clean(_ items: [Item]) {
        let targets = items.filter { !Self.isProtected($0.url.lastPathComponent) }
        guard !targets.isEmpty, !cleaning else { return }
        cleaning = true
        // Off the list immediately. The rows are going; leaving them sitting
        // there through a multi-second delete invites a second press.
        junk.removeAll { targets.contains($0) }
        selected.subtract(targets.map(\.id))

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.remove(targets)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.cleaning = false
                    // The capacity read happens once per island open, so without
                    // this the disk tile still showed the old number and the
                    // whole thing looked like it had not run.
                    SystemStats.shared.refreshDisk()

                    var parts: [String] = []
                    if result.deleted > 0 { parts.append("\(result.deleted) cleared") }
                    if result.failed > 0 { parts.append("\(result.failed) refused") }
                    HUD.shared.show(
                        .utility(
                            symbol: result.failed > 0 ? "exclamationmark.triangle.fill" : "sparkles",
                            title: result.freed > 0
                                ? ByteCountFormatter.string(fromByteCount: result.freed, countStyle: .file) + " freed"
                                : "Nothing freed",
                            detail: parts.isEmpty ? "Nothing to clean" : parts.joined(separator: " · ")
                        ),
                        for: 3.0
                    )
                    // Re-measure rather than trusting what is left on screen. A
                    // partly-refused folder is still there, at a smaller size,
                    // and a list that keeps claiming it went is the thing that
                    // made this feature feel untrustworthy.
                    self.sweep()
                }
            }
        }
    }

    /// Removes one batch and reports what actually went.
    ///
    /// Contents first, always, then the folder itself. `removeItem` on a
    /// directory is one call that wholly succeeds or wholly fails, so a single
    /// locked file inside a 1.4 GB cache used to cost the entire 1.4 GB - the
    /// row disappeared, the HUD said it was cleared, and the disk gave back
    /// nothing. Per child, one bad file costs only that file.
    ///
    /// ponytail: no `trashItem` fallback any more. The point of this half is to
    /// free space, and moving a folder to the Trash frees none until the Trash
    /// is emptied. Deleting children individually already salvages the partial
    /// case that fallback existed for.
    private nonisolated static func remove(
        _ items: [Item]
    ) -> (deleted: Int, failed: Int, freed: Int64) {
        let manager = FileManager()
        var deleted = 0
        var failed = 0
        var freed: Int64 = 0

        for item in items {
            // Belt and braces. Nothing protected can reach this list, and a
            // future caller passing one straight in still cannot delete it.
            guard !Self.isProtected(item.url.lastPathComponent) else { continue }
            // Already gone - the owning app cleared its own cache between the
            // scan and the press. Not a failure, and not worth reporting.
            guard manager.fileExists(atPath: item.url.path) else { continue }

            let children = (try? manager.contentsOfDirectory(
                at: item.url, includingPropertiesForKeys: nil, options: []
            )) ?? []
            var refused = 0
            for child in children where (try? manager.removeItem(at: child)) == nil {
                refused += 1
            }
            if !item.contentsOnly, refused == 0 {
                if (try? manager.removeItem(at: item.url)) == nil { refused += 1 }
            }

            // Measured, not assumed. The row's size was an estimate taken under
            // a time budget, and a refused child means some of it is still
            // there - reporting `item.bytes` counted space that never came back.
            let left = manager.fileExists(atPath: item.url.path) ? size(of: item.url, budget: 2) : 0
            freed += max(0, item.bytes - left)
            if refused > 0, left >= item.bytes { failed += 1 } else { deleted += 1 }
        }
        return (deleted, failed, freed)
    }

    // MARK: - Shared

    /// ponytail: its own `FileManager`, not one handed in. Swift 6 will not let
    /// an instance cross into a background closure, and a fresh one costs
    /// nothing.
    ///
    /// `nonisolated` for the same reason as `Updates.run`: this walks folders on
    /// a background queue, and a static on a `@MainActor` class is MainActor by
    /// inheritance unless it says otherwise.
    /// Sizes a folder, giving up after `budget` seconds and returning what it
    /// has counted so far.
    ///
    /// The budget is not a nicety. Without it a single folder can stall the
    /// whole sweep indefinitely - measured here, the list sat on "Measuring"
    /// past a hundred seconds and never finished, and `find` over five of this
    /// machine's container caches did not return inside two minutes either. A
    /// deadline between folders cannot help with that, because the time is spent
    /// inside one walk.
    ///
    /// A truncated answer understates the folder, which is the safe direction:
    /// the row is offered smaller than it is, and the figure reported after a
    /// delete is measured from what actually went.
    ///
    /// The clock is read every 256 entries rather than every entry - `Date()` in
    /// the inner loop of a walk over hundreds of thousands of files is itself a
    /// measurable cost.
    private nonisolated static func size(of url: URL, budget: TimeInterval = 4) -> Int64 {
        let manager = FileManager()
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isDirectory == true {
            let deadline = Date().addingTimeInterval(budget)
            var seen = 0
            let walker = manager.enumerator(at: url, includingPropertiesForKeys: keys,
                                            options: [.skipsHiddenFiles])
            while let child = walker?.nextObject() as? URL {
                let childValues = try? child.resourceValues(forKeys: Set(keys))
                total += Int64(childValues?.totalFileAllocatedSize ?? childValues?.fileAllocatedSize ?? 0)
                seen += 1
                if seen & 0xFF == 0, Date() > deadline { break }
            }
        } else {
            total = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
