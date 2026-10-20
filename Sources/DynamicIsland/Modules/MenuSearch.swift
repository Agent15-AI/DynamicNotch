import AppKit
import ApplicationServices

/// Every menu command in the app you were just using, searchable.
///
/// "Export as PDF", "Merge Cells", "Toggle Word Wrap" - the things that live
/// four levels into a menu you have to go hunting for with the mouse. Paletro
/// is an entire app for this and Raycast folded it in as Search Menu Bar Items;
/// it is the one command-bar feature that works in software this app knows
/// nothing about.
///
/// ponytail: no index and no cache between openings. The menu tree is read once
/// per bar opening, on the first query that could match something, and thrown
/// away on close. Menus change as an app's state changes - half of them are
/// disabled until something is selected - so a cache kept any longer would be
/// wrong more often than it was fast.
@MainActor
@Observable
final class MenuSearch {
    static let shared = MenuSearch()

    struct Item: Identifiable {
        let id = UUID()
        /// "Format ▸ Font ▸ Show Fonts", for the subtitle.
        let path: String
        let title: String
        /// "⇧⌘F", or empty.
        let shortcut: String
        /// Root-first, for opening the menus on the way down. See `press`.
        let ancestors: [AXUIElement]
        let element: AXUIElement
    }

    /// The app that was in front before the bar took the keyboard.
    private(set) var appName = ""
    private var app: NSRunningApplication?
    private var items: [Item]?

    private init() {}

    var available: Bool { AXIsProcessTrusted() && app != nil }

    /// Called as the bar opens, and deliberately *before* it activates: once
    /// our own panel is key, `frontmostApplication` is us, and the menus we
    /// would read are our own.
    func prepare() {
        items = nil
        appName = ""
        guard Settings.shared.menuSearch else { app = nil; return }
        let front = NSWorkspace.shared.frontmostApplication
        // Reading our own menu bar would offer the user "Quit DynamicIsland"
        // and nothing else useful.
        app = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        appName = app?.localizedName ?? ""
    }

    func close() {
        items = nil
        app = nil
        appName = ""
    }

    /// Walked on first use rather than on open, so a bar opened to type a sum
    /// never touches another app's menus.
    func search(_ text: String) -> [(Int, Item)] {
        guard available, text.count >= 2 else { return [] }
        if items == nil { items = walk() }
        return (items ?? []).compactMap { item in
            // Matched on the leaf title only. Including the path would make
            // every item under "Format" match `format`, which buries the one
            // actually called that.
            guard let score = CommandBar.score(item.title, query: text, tight: true) else { return nil }
            return (score, item)
        }
    }

    /// Runs the command.
    ///
    /// Pressing the leaf alone is not enough in every app: some populate a
    /// submenu only once its parent has been opened, so the press lands on a
    /// stale element. Pressing each ancestor root-first opens the chain the way
    /// the mouse would, and the leaf press then lands on a live menu.
    func press(_ item: Item) {
        app?.activate()
        // The activation has to land before the menu opens, or the press goes
        // to a menu bar that is not frontmost and is ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            for ancestor in item.ancestors {
                AXUIElementPerformAction(ancestor, kAXPressAction as CFString)
            }
            AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        }
    }

    // MARK: - Reading the tree

    /// Bounds. Xcode's menu bar is thousands of items deep in places, and a
    /// command bar that stalls for a second while you type is worse than one
    /// that misses a command buried five submenus down.
    private static let maxDepth = 5
    private static let maxItems = 2_000

    private func walk() -> [Item] {
        guard let pid = app?.processIdentifier else { return [] }
        let application = AXUIElementCreateApplication(pid)
        // Without this, one unresponsive app freezes the bar. The AX API blocks
        // the calling thread until the target answers, and the target may be
        // beachballing - which is exactly when someone reaches for a launcher.
        AXUIElementSetMessagingTimeout(application, 0.4)

        guard let bar = copy(application, kAXMenuBarAttribute) else { return [] }
        var found: [Item] = []
        // The Apple menu is first and is the same everywhere; it is not what
        // anyone is searching their app's menus for.
        for barItem in children(of: bar).dropFirst() {
            guard let title = string(barItem, kAXTitleAttribute), !title.isEmpty else { continue }
            descend(barItem, path: [title], ancestors: [], depth: 0, into: &found)
            if found.count >= Self.maxItems { break }
        }
        return found
    }

    private func descend(_ element: AXUIElement, path: [String], ancestors: [AXUIElement],
                         depth: Int, into found: inout [Item]) {
        guard depth < Self.maxDepth, found.count < Self.maxItems else { return }
        // A menu bar item holds one AXMenu, whose children are the commands.
        for menu in children(of: element) {
            for entry in children(of: menu) {
                guard found.count < Self.maxItems else { return }
                guard let title = string(entry, kAXTitleAttribute),
                      !title.trimmingCharacters(in: .whitespaces).isEmpty
                else { continue }   // separators have no title

                let below = children(of: entry)
                if below.isEmpty {
                    // A greyed-out command cannot be run, and offering one is
                    // offering a result that does nothing when pressed.
                    guard bool(entry, kAXEnabledAttribute) else { continue }
                    found.append(Item(
                        path: (path + [title]).joined(separator: " ▸ "),
                        title: title,
                        shortcut: shortcut(entry),
                        ancestors: ancestors + [element],
                        element: entry
                    ))
                } else {
                    descend(entry, path: path + [title], ancestors: ancestors + [element],
                            depth: depth + 1, into: &found)
                }
            }
        }
    }

    /// "⇧⌘F". The modifier mask is the Carbon one, and bit 3 means the command
    /// key is *not* held - the one flag whose sense is inverted.
    private func shortcut(_ element: AXUIElement) -> String {
        guard let key = string(element, kAXMenuItemCmdCharAttribute), !key.isEmpty else { return "" }
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXMenuItemCmdModifiersAttribute as CFString, &value)
        let mask = (value as? Int) ?? 0
        var text = ""
        if mask & 4 != 0 { text += "⌃" }
        if mask & 2 != 0 { text += "⌥" }
        if mask & 1 != 0 { text += "⇧" }
        if mask & 8 == 0 { text += "⌘" }
        return text + key.uppercased()
    }

    // MARK: - AX helpers

    private func copy(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let result = value, CFGetTypeID(result) == AXUIElementGetTypeID()
        else { return nil }
        return (result as! AXUIElement)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return true }
        return (value as? Bool) ?? true
    }
}
