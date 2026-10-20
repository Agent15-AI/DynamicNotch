import AppKit

/// The capsule in the menu bar.
///
/// One item does both jobs. Left-click hides or shows the icons (when the menu
/// bar module is on); right-click, or Control-click, opens the menu with
/// Settings and Quit - an app you cannot find is an app you cannot turn off.
/// `MenuBarHider` keeps it at the right-hand end of the bar.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    static let shared = StatusItem()

    private var item: NSStatusItem?
    private var menuBarEntry: NSMenuItem?
    private var chooseEntry: NSMenuItem?

    private override init() {}

    /// Stable, so the position a ⌘-drag gives it is remembered across launches.
    static let autosaveName = "dynamicisland.menubar.island"

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.item = item
        refresh()
        // The bar belongs to MenuBarAgent on macOS 27, so the press itself is
        // delivered to that process, not us - which a global monitor does see.
        NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { _ in
            MainActor.assumeIsolated { StatusItem.shared.lastRightDown = Date() }
        }
    }

    private var lastRightDown = Date.distantPast

    /// Filled while everything shows, outlined while icons are hidden. Never a
    /// chevron: macOS 27 puts its own « overflow button in the bar, and that
    /// one moves icons to the far side of the notch rather than hiding them.
    func refresh() {
        let hidden = Settings.shared.menuBar && MenuBarHider.shared.collapsed
        let image = NSImage(
            systemSymbolName: hidden ? "capsule" : "capsule.fill",
            accessibilityDescription: hidden ? "Show menu bar icons" : "Hide menu bar icons"
        )
        image?.size = NSSize(width: 15, height: 9)
        image?.isTemplate = true
        item?.button?.image = image
        item?.button?.toolTip = Settings.shared.menuBar
            ? (hidden ? "Show hidden icons (⌘⌃B)" : "Hide icons (⌘⌃B) · right-click for menu")
            : "Dynamic Island"
    }

    @objc private func clicked() {
        // Right-click only. Not Control-click: on macOS 27 the bar is drawn
        // by MenuBarAgent and the click reaches us second-hand, so
        // `currentEvent` can be an older event of ours - one that carried
        // Control turned every plain left-click into the menu. The global
        // monitor's record of a real right press backs it up.
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp || Date().timeIntervalSince(lastRightDown) < 0.8
        if rightClick || !Settings.shared.menuBar {
            showMenu()
        } else {
            MenuBarHider.shared.toggle()
        }
    }

    /// Popped up at the pointer, which is on the capsule. Not the usual
    /// attach-the-menu-and-performClick trick: on macOS 27 the item is hosted
    /// by MenuBarAgent and that round trip only sometimes opened the menu.
    private func showMenu() {
        buildMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let menuBar = menu.addItem(
            withTitle: "Hide menu bar icons",
            action: #selector(toggleMenuBar),
            keyEquivalent: "b"
        )
        menuBar.keyEquivalentModifierMask = [.command, .control]
        menuBar.target = self
        menuBarEntry = menuBar

        let choose = menu.addItem(withTitle: "Choose Icons to Hide…", action: #selector(chooseIcons), keyEquivalent: "")
        choose.target = self
        chooseEntry = choose

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dynamic Island", action: #selector(quit), keyEquivalent: "q")
            .target = self
        return menu
    }

    /// The entry says what pressing it will do, which flips with the state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menuBarEntry?.isHidden = !Settings.shared.menuBar
        chooseEntry?.isHidden = !Settings.shared.menuBar
        menuBarEntry?.title = MenuBarHider.shared.collapsed ? "Show menu bar icons" : "Hide menu bar icons"
    }

    @objc private func toggleMenuBar() {
        MenuBarHider.shared.toggle()
    }

    @objc private func checkForUpdates() {
        Updater.shared.check()
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func chooseIcons() {
        SettingsWindow.shared.show(tab: "menubar")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
