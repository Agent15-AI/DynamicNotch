import AppKit
import ApplicationServices

/// Every icon in the menu bar, left to right, and what macOS 27 lets us do
/// with each.
///
/// Read from `MenuBarAgent`'s accessibility tree. On macOS 27 the whole bar is
/// one window owned by that agent, and its tree is the only place that lists
/// Apple's modules (Wi-Fi, Battery...) and everyone else's icons together, in
/// on-screen order: an `AXWindow` per display holding one group per icon. An
/// app's icon nests that app's `AXApplication` (or a bare `AXButton` it owns);
/// Apple's are an `AXMenuBarItem` with a `com.apple.menuextra.*` identifier.
@MainActor
@Observable
final class MenuBarItems {
    static let shared = MenuBarItems()

    /// What hiding can do with an icon, which is decided by macOS rather than
    /// by us: the restriction hides by bundle id and by nine system ids.
    enum Kind: Equatable {
        /// An app's icon. Hides and shows by bundle id - every icon of one app
        /// together.
        case app
        /// One of Apple's modules the restriction names individually.
        case system(Int)
        /// Control Center and the clock. macOS keeps them whatever we ask.
        case pinned
        /// Hides whenever anything is hidden and cannot be kept: Apple's other
        /// modules (Focus...) and icons whose process has no app bundle to allow.
        case collateral
        /// Now Playing: hides with the rest like `collateral`, but when set to
        /// show, `NowPlayingStandIn` puts this app's own in its place.
        case standIn
    }

    struct Item: Identifiable {
        /// Bundle id for an app, `com.apple.menuextra.*` for Apple's modules.
        let key: String
        let name: String
        let kind: Kind
        let pid: pid_t
        /// On screen, Core Graphics coordinates (top-left origin, y down).
        var frame: CGRect
        /// The key, plus which of that app's icons this is, left to right - one
        /// app can own several, and each is placed separately.
        var id: String

        init(key: String, name: String, kind: Kind, pid: pid_t, frame: CGRect) {
            self.key = key
            self.name = name
            self.kind = kind
            self.pid = pid
            self.frame = frame
            self.id = key
        }

        var isOwn: Bool { pid == ProcessInfo.processInfo.processIdentifier }

        /// Where the hide choice is stored. System modules by id, so the choice
        /// follows the thing the restriction actually switches.
        var choiceKey: String {
            if case .system(let id) = kind { return "system.\(id)" }
            return key
        }

        /// SystemUIServer (Siri) sits among Control Center and the clock and,
        /// like them, cannot be dragged. Everything else can.
        var isPositionPinned: Bool {
            kind == .pinned || key == "com.apple.systemuiserver"
        }

        var icon: NSImage? {
            if key.hasPrefix(MenuBarItems.modulePrefix) {
                return NSImage(systemSymbolName: MenuBarItems.symbol(for: key), accessibilityDescription: name)
            }
            if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon { return icon }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: key).map {
                NSWorkspace.shared.icon(forFile: $0.path)
            }
        }
    }

    /// The bar as last read, left to right, main display only.
    private(set) var items: [Item] = []
    /// Every icon worth listing in Settings, by key. Kept across scans made
    /// while icons are hidden, so a hidden icon does not drop out of the very
    /// list used to bring it back.
    private(set) var known: [String: Item] = [:]
    private var watcher: Task<Void, Never>?

    static let agentBundleID = "com.apple.MenuBarAgent"
    nonisolated static let modulePrefix = "com.apple.menuextra."

    private init() {}

    var authorized: Bool { AXIsProcessTrusted() }

    /// The rows for Settings: everything but our own capsule, in bar order.
    var listed: [Item] {
        known.values.filter { !$0.isOwn }.sorted { $0.frame.minX < $1.frame.minX }
    }

    // MARK: - Permission

    func requestAccess() {
        // Spelled out rather than via `kAXTrustedCheckOptionPrompt`, which is
        // an imported `var` and so not concurrency-safe to touch from here.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Opens the Accessibility list in System Settings. Needed as well as the
    /// prompt: macOS shows that prompt once per app signature and never again.
    func openSettingsPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Re-checks until permission appears, then scans and stops. The grant
    /// lands while the app is in the background and nothing announces it.
    func watchForAccess() {
        guard !authorized, watcher == nil else { return }
        watcher = Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.authorized {
                    self.scan()
                    MenuBarHider.shared.placeIfNeeded()
                    self.watcher = nil
                    return
                }
            }
            self?.watcher = nil
        }
    }

    // MARK: - Reading the bar

    /// Reads the bar. While icons are hidden the scan only sees what is left,
    /// so it adds to `known` instead of replacing it.
    func scan() {
        guard authorized,
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentBundleID).first
        else {
            items = []
            return
        }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        // A wedged agent must never hang the app.
        AXUIElementSetMessagingTimeout(root, 0.3)
        let main = CGDisplayBounds(CGMainDisplayID())

        // One AXWindow per display and Space, all carrying the same icons, so
        // the first that has any is the whole bar.
        let window = Self.children(root).first {
            Self.role($0) == "AXWindow" && !Self.children($0).isEmpty
        }
        var found: [Item] = []
        for group in window.map(Self.children) ?? [] {
            guard let frame = Self.frame(group),
                  frame.minY < 50,
                  main.contains(CGPoint(x: frame.midX, y: frame.midY)),
                  let item = describe(group, frame: frame, agentPID: agent.processIdentifier)
            else { continue }
            found.append(item)
        }
        items = found.sorted { $0.frame.minX < $1.frame.minX }
        var seen: [String: Int] = [:]
        for index in items.indices {
            let ordinal = seen[items[index].key, default: 0]
            seen[items[index].key] = ordinal + 1
            items[index].id = "\(items[index].key)#\(ordinal)"
        }

        if MenuBarHider.shared.collapsed {
            // What is left has reflowed while the rest keeps its old place, so
            // mixing the two scrambles the order. Keep the last full reading;
            // only an icon that appeared since is added.
            for item in items where known[item.id] == nil { known[item.id] = item }
        } else {
            known = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The bar with every icon where it really is. The agent's tree keeps a
    /// phantom frame for icons folded behind the « even once it is open; each
    /// owner's own extras bar reports the real one, so the icons are read from
    /// the tree and placed from their owners. Our own process is skipped - its
    /// main thread is the one asking.
    func realLayout() -> [Item] {
        scan()
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentBundleID).first
        else { return items }
        var framesByOwner: [pid_t: [CGRect]] = [:]
        var moduleFrames: [String: CGRect] = [:]
        for pid in Set(items.map(\.pid)) where pid != ProcessInfo.processInfo.processIdentifier {
            let owner = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(owner, 0.2)
            guard let bar = Self.attribute(owner, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
            for child in Self.children(bar as! AXUIElement) {
                guard let frame = Self.frame(child) ?? Self.positionFrame(child) else { continue }
                if pid == agent.processIdentifier {
                    // The agent's own modules, named by the item inside; its
                    // one bare button is the « itself.
                    let leaf = Self.role(child) == "AXMenuBarItem" ? child
                        : Self.children(child).first { Self.role($0) == "AXMenuBarItem" }
                    if let leaf, let identifier = Self.string(leaf, kAXIdentifierAttribute) {
                        moduleFrames[identifier] = frame
                    }
                } else {
                    framesByOwner[pid, default: []].append(frame)
                }
            }
        }
        var ordinal: [pid_t: Int] = [:]
        var placed = items
        for index in placed.indices {
            let item = placed[index]
            if item.pid == agent.processIdentifier {
                if let frame = moduleFrames[item.key] { placed[index].frame = frame }
            } else if let frames = framesByOwner[item.pid]?.sorted(by: { $0.minX < $1.minX }) {
                let n = ordinal[item.pid, default: 0]
                ordinal[item.pid] = n + 1
                if n < frames.count { placed[index].frame = frames[n] }
            }
        }
        return placed.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// macOS 27's own overflow toggle («). When the bar is fuller than the
    /// space beside the notch, the leftmost icons fold behind it - and a new
    /// status item, ours included, is born leftmost. It is the one button in
    /// the agent's extras bar; its label says which way it will go.
    func overflowToggle() -> (frame: CGRect, expanded: Bool)? {
        guard authorized,
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentBundleID).first
        else { return nil }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        guard let bar = Self.attribute(root, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        for child in Self.children(bar as! AXUIElement) where Self.role(child) == "AXButton" {
            guard let frame = Self.frame(child) ?? Self.positionFrame(child) else { continue }
            let label = Self.string(child, kAXDescriptionAttribute) ?? ""
            return (frame, Self.overflowHideLabels.contains(label))
        }
        return nil
    }

    /// Our own item's frame, as our own process reports it. While the capsule
    /// is folded behind the « the agent's tree keeps a phantom frame for it even
    /// after the « opens; this one is where it really is. Must run off the main
    /// thread - the main thread is what answers it.
    nonisolated static func ownFrame(described label: String? = nil) -> CGRect? {
        let own = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetMessagingTimeout(own, 0.5)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(own, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return nil }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
        let items = children as? [AXUIElement] ?? []
        let item = label.map { label in
            items.first {
                var description: CFTypeRef?
                AXUIElementCopyAttributeValue($0, kAXDescriptionAttribute as CFString, &description)
                return description as? String == label
            }
        } ?? items.first
        guard let item else { return nil }
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// Every translation of the expanded «'s label, from the agent's own
    /// strings table - it is labelled in the system language, not ours.
    private static let overflowHideLabels: Set<String> = {
        var labels: Set<String> = ["Hide Menu Bar Items"]
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/MenuBarAgent.app/Contents/Resources/MenuBarCore.loctable")
        guard let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return labels }
        for case let strings as [String: Any] in table.values {
            if let label = strings["menuBar.hideOverflowItemsAccessibilityLabel"] as? String { labels.insert(label) }
        }
        return labels
    }()

    private func describe(_ group: AXUIElement, frame: CGRect, agentPID: pid_t) -> Item? {
        for child in Self.children(group) {
            if Self.role(child) == "AXGroup" {
                // Apple's module: a group wrapping one AXMenuBarItem.
                for leaf in Self.children(child) where Self.role(leaf) == "AXMenuBarItem" {
                    guard let identifier = Self.string(leaf, kAXIdentifierAttribute) else { continue }
                    let description = Self.string(leaf, kAXDescriptionAttribute) ?? ""
                    // "Wi-Fi, connected, 3 bars" - the name is the first part.
                    let name = description.split(separator: ",").first.map(String.init)
                        ?? String(identifier.dropFirst(Self.modulePrefix.count)).capitalized
                    return Item(key: identifier, name: name, kind: Self.kind(forModule: identifier),
                                pid: agentPID, frame: frame)
                }
                continue
            }
            // An app's icon: its AXApplication, or a button it owns.
            var pid: pid_t = 0
            AXUIElementGetPid(child, &pid)
            guard pid > 0, pid != agentPID else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            var name = app?.localizedName ?? Self.string(child, kAXTitleAttribute) ?? "Unknown"
            // Apple's hosts are named for the process, not the icon: "Siri"
            // (Siri AI.app) draws Spotlight, "SystemUIServer" draws Siri. The
            // icon's own title says which it is.
            if app?.bundleIdentifier?.hasPrefix("com.apple.") == true, let title = Self.iconTitle(pid: pid) {
                name = title
            }
            guard let bundleID = app?.bundleIdentifier else {
                // No bundle id means nothing the restriction can name, so it
                // hides along with everything else and cannot be kept.
                return Item(key: "pid.\(name)", name: name, kind: .collateral, pid: pid, frame: frame)
            }
            return Item(key: bundleID, name: name, kind: Self.kind(forBundle: bundleID), pid: pid, frame: frame)
        }
        return nil
    }

    private static func iconTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let bar = attribute(app, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let icon = children(bar as! AXUIElement).first
        else { return nil }
        return string(icon, kAXTitleAttribute) ?? string(icon, kAXDescriptionAttribute)
    }

    // MARK: - What each icon is

    /// MBSystemItemIdentifier, the nine Apple items the restriction can name.
    /// Verified on 27.0: 0 battery, 1 bluetooth, 2 clock, 3 displays,
    /// 4 keyboard (input menu), 5 sound, 6 Wi-Fi, 7 screen mirroring,
    /// 8 Control Center.
    static let clockID = 2
    static let controlCenterID = 8

    private static func kind(forModule identifier: String) -> Kind {
        switch identifier.dropFirst(modulePrefix.count) {
        case "battery": .system(0)
        case "bluetooth": .system(1)
        case "display", "displays": .system(3)
        case "textinput", "keyboard": .system(4)
        case "sound": .system(5)
        case "wifi": .system(6)
        case "screen-mirroring", "screenmirroring": .system(7)
        case "clock", "controlcenter": .pinned
        case "now-playing": .standIn
        default: .collateral
        }
    }

    private static func kind(forBundle bundleID: String) -> Kind {
        switch bundleID {
        case "com.apple.TextInputMenuAgent": .system(4)
        // Apple's hosts the restriction does not take by bundle id. The
        // screen-recording indicator is one, and macOS keeps it on purpose.
        case "com.apple.screencaptureui", "com.apple.controlcenter": .pinned
        default: .app
        }
    }

    /// Bundle ids that are never worth putting in the allowlist: they host
    /// Apple's modules, which the restriction handles by system id instead.
    static let hostBundles: Set<String> = [
        agentBundleID, "com.apple.TextInputMenuAgent", "com.apple.controlcenter", "com.apple.screencaptureui",
    ]

    nonisolated fileprivate static func symbol(for key: String) -> String {
        switch key.dropFirst(modulePrefix.count) {
        case "battery": "battery.75percent"
        case "bluetooth": "dot.radiowaves.left.and.right"
        case "wifi": "wifi"
        case "sound": "speaker.wave.2.fill"
        case "display", "displays": "sun.max.fill"
        case "textinput", "keyboard": "keyboard"
        case "screen-mirroring", "screenmirroring": "rectangle.on.rectangle"
        case "clock": "clock"
        case "controlcenter": "switch.2"
        case "now-playing": "play.circle.fill"
        case "focusmode", "focus": "moon.fill"
        case "airdrop": "airplayaudio"
        default: "circle.grid.2x2"
        }
    }

    // MARK: - AX plumbing

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func role(_ element: AXUIElement) -> String {
        attribute(element, kAXRoleAttribute) as? String ?? ""
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        (attribute(element, name) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The « reports position and size but no `AXFrame`.
    private static func positionFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let value = attribute(element, "AXFrame"), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }
}
