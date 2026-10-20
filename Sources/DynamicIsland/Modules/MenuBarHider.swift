import AppKit
import ApplicationServices
import MenuBarShim
import os

/// Every automatic drag is logged: they move other apps' icons, so when one
/// lands wrong the log says what was aimed where. `log show --predicate
/// 'subsystem == "dev.local.dynamicisland"'`.
let menuBarLog = Logger(subsystem: "dev.local.dynamicisland", category: "menubar")

/// Ice, rebuilt for macOS 27: the capsule sits at the right-hand end of the
/// menu bar, and clicking it hides the icons you picked.
///
/// macOS 27 draws the whole bar as one window owned by `MenuBarAgent`. The
/// per-icon windows Ice moved are gone, which is exactly why Ice hangs on
/// "Loading menu bar items". Two things replace them:
///
/// - **Hiding** is a visibility restriction (`MenuBarShim`): macOS keeps the
///   system items and app bundle ids we allow and hides the rest, reflowing the
///   bar. It hides by membership, so which icons hide is a list you tick, not a
///   position you drag to. It is bound to this process: quit or crash and every
///   icon comes back on its own.
/// - **Position** is a real ⌘-drag. Nothing else moves an item on 27 -
///   `Preferred Position`, the agent's position table and pid-targeted events
///   are all ignored - but a ⌘-drag posted at the HID level is indistinguishable
///   from the user's own, and the agent persists it. So when the capsule is not
///   already immediately left of Control Center, it is dragged there, once, while
///   the pointer is idle.
///
/// Right of the capsule then sits only what macOS pins: Control Center, Siri
/// and the clock. Nothing can be dragged past those, not even by hand.
@MainActor
@Observable
final class MenuBarHider {
    static let shared = MenuBarHider()

    /// Toggles from outside the app - Shortcuts, Raycast, a shell script.
    static let toggleNotification = Notification.Name("dev.local.dynamicisland.toggleMenuBar")
    /// Marks events we post, so our own taps let them through.
    nonisolated static let syntheticTag: Int64 = 0x4459_4E49 // "DYNI"

    private(set) var collapsed = false
    /// Why hiding cannot work here, for Settings to show. Nil when it can.
    private(set) var problem: String?

    private var assertion: AnyObject?
    /// Replaced restrictions, released once their successor is active.
    private var retiring: [AnyObject] = []
    private var applied: Allowlist?
    private var rehide: Task<Void, Never>?
    private var watchdog: DispatchSourceProcess?
    private var placing = false
    private var placementGaveUp: Date?
    private var started = false
    private let clock = ClockRelay()

    private struct Allowlist: Equatable {
        var system: [Int]
        var bundles: [String]
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        observe()
        guard Settings.shared.menuBar else { return }
        // The bar is still settling for the first second or two after launch.
        Task {
            try? await Task.sleep(for: .seconds(2))
            MenuBarItems.shared.scan()
            if Settings.shared.menuBarCollapsed { collapse() } else { placeIfNeeded() }
        }
    }

    /// The module switch in Settings.
    func reload() {
        if !Settings.shared.menuBar, collapsed { expand() }
        if Settings.shared.menuBar { placeIfNeeded() }
        StatusItem.shared.refresh()
    }

    private func observe() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.toggleNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarHider.shared.toggle() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { MenuBarHider.shared.appLaunched(bundleID) }
        }
        // Leaving a fullscreen app brings the bar back - the first chance to
        // place the capsule if it could not be placed while the bar was away.
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarHider.shared.settle(after: 1.5, reapply: false) }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarHider.shared.settle(after: 3, reapply: true) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarHider.shared.settle(after: 2, reapply: false) }
        }
    }

    private func appLaunched(_ bundleID: String?) {
        guard Settings.shared.menuBar else { return }
        // A new app's icon: hidden unless it was set to show, which needs its
        // bundle id in the allowlist. Also give it time to appear before
        // checking the capsule is still rightmost.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if collapsed { apply(force: false) } else { MenuBarItems.shared.scan(); placeIfNeeded() }
        }
    }

    private func settle(after seconds: Double, reapply: Bool) {
        guard Settings.shared.menuBar else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if collapsed {
                if reapply { apply(force: true) }
            } else {
                MenuBarItems.shared.scan()
                placeIfNeeded()
            }
        }
    }

    // MARK: - Hiding

    func toggle() {
        collapsed ? expand() : collapse()
    }

    func show() {
        if collapsed { expand() }
    }

    func collapse() {
        guard Settings.shared.menuBar else { return }
        rehide?.cancel()
        // Read the bar while nothing is hidden: the list in Settings and the
        // clock's position both come from this.
        MenuBarItems.shared.scan()
        // An open « lays icons out left of the notch. Fold it first, so hiding
        // hides them rather than leaving them parked on the other side.
        if let toggle = MenuBarItems.shared.overflowToggle(), toggle.expanded {
            Self.click(at: CGPoint(x: toggle.frame.midX, y: toggle.frame.midY))
        }
        collapsed = true
        Settings.shared.menuBarCollapsed = true
        apply(force: true)
        clock.enable(frame: MenuBarItems.shared.items.first { $0.key == "com.apple.menuextra.clock" }?.frame)
        StatusItem.shared.refresh()
        watchAgent()
    }

    /// The restriction lives in `MenuBarAgent`. If the agent restarts - a crash,
    /// or a switch in "Remove Apple icons" that relaunches it - every icon comes
    /// back while we still think they are hidden. Nothing announces an agent
    /// launch, but the kernel does announce a process exit: a kqueue process
    /// source on the agent's pid fires once when it dies, and costs nothing
    /// until then. It used to be a check every three seconds for as long as
    /// icons were hidden - most of this app's idle wakeups.
    private func watchAgent() {
        watchdog?.cancel()
        watchdog = nil
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: MenuBarItems.agentBundleID)
            .first?.processIdentifier else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                MenuBarHider.shared.agentExited()
            }
        }
        watchdog = source
        source.resume()
    }

    private func agentExited() {
        watchdog?.cancel()
        watchdog = nil
        guard collapsed else { return }
        // launchd brings the agent straight back; wait for the new one, then
        // hand it the restriction again.
        Task {
            // No upper bound: giving up would leave nothing watching, and a
            // late agent would bring every icon back unnoticed. One check a
            // second, only while icons are hidden and the agent is gone.
            while NSRunningApplication.runningApplications(withBundleIdentifier: MenuBarItems.agentBundleID).isEmpty {
                try? await Task.sleep(for: .seconds(1))
                guard collapsed else { return }
            }
            try? await Task.sleep(for: .seconds(0.5))
            guard collapsed else { return }
            NSLog("menu bar: MenuBarAgent restarted, hiding again")
            apply(force: true)
            watchAgent()
        }
    }

    func expand() {
        rehide?.cancel()
        watchdog?.cancel()
        collapsed = false
        Settings.shared.menuBarCollapsed = false
        clock.disable()
        release()
        StatusItem.shared.refresh()
        scheduleRehide()
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard !collapsed else { return }
            MenuBarItems.shared.scan()
            placeIfNeeded()
        }
    }

    /// Whether an icon hides when the capsule is clicked. Apps default to
    /// hidden and Apple's modules to shown, which is what Ice does out of the
    /// box: everything that is not Apple's goes in the hidden section.
    func hides(_ item: MenuBarItems.Item) -> Bool {
        switch item.kind {
        case .pinned: false
        case .collateral: true
        case .system: Settings.shared.menuBarChoices[item.choiceKey] ?? false
        case .standIn: Settings.shared.menuBarChoices[item.choiceKey] ?? true
        case .app: Settings.shared.menuBarChoices[item.choiceKey] ?? !item.key.hasPrefix("com.apple.")
        }
    }

    func setHides(_ hides: Bool, _ item: MenuBarItems.Item) {
        Settings.shared.menuBarChoices[item.choiceKey] = hides
        if collapsed { apply(force: false) }
    }

    /// Everything that stays: Apple's system items not switched to hide, and
    /// every running app not switched to hide. Built from running apps rather
    /// than the scan, so an icon that appears later is already accounted for.
    private func allowlist() -> Allowlist {
        let choices = Settings.shared.menuBarChoices
        let system = (0...8).filter { id in
            id == MenuBarItems.clockID || id == MenuBarItems.controlCenterID || choices["system.\(id)"] != true
        }
        var bundles = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !MenuBarItems.hostBundles.contains(id) else { continue }
            let hidden = choices[id] ?? !id.hasPrefix("com.apple.")
            if !hidden { bundles.insert(id) }
        }
        if let own = Bundle.main.bundleIdentifier { bundles.insert(own) }
        return Allowlist(system: system, bundles: bundles.sorted())
    }

    /// Swaps in a restriction for the current allowlist. The old one is only
    /// released once the new one is active, so a change never flashes every
    /// icon back for a moment.
    private func apply(force: Bool) {
        guard collapsed else { return }
        let list = allowlist()
        guard force || list != applied else { return }
        guard DIMenuBarRestrictionAvailable() else {
            fail("This Mac's menu bar has no way to hide icons (needs macOS 27).")
            return
        }
        if let assertion { retiring.append(assertion) }
        let next = DIMenuBarRestrict(list.system.map { NSNumber(value: $0) }, list.bundles) { @Sendable error in
            let message = error?.localizedDescription
            Task { @MainActor in MenuBarHider.shared.activated(error: message) }
        }
        guard let next else {
            fail("macOS refused to hide menu bar icons.")
            return
        }
        assertion = next as AnyObject
        applied = list
        problem = nil
    }

    private func activated(error: String?) {
        retiring.forEach(DIMenuBarRestrictionRelease)
        retiring = []
        guard let error else { return }
        NSLog("menu bar restriction failed: \(error)")
        fail("macOS refused to hide menu bar icons: \(error)")
    }

    private func release() {
        if let assertion { DIMenuBarRestrictionRelease(assertion) }
        retiring.forEach(DIMenuBarRestrictionRelease)
        retiring = []
        assertion = nil
        applied = nil
    }

    private func fail(_ message: String) {
        problem = message
        release()
        collapsed = false
        Settings.shared.menuBarCollapsed = false
        clock.disable()
        StatusItem.shared.refresh()
        HUD.shared.show(.utility(symbol: "exclamationmark.triangle.fill", title: "Can't hide icons", detail: message), for: 3)
    }

    /// Clicking the clock opens Notification Center - except while a
    /// restriction is held, when the clock silently refuses. So the click is
    /// caught, the restriction dropped, the click replayed and the restriction
    /// put straight back. Hidden icons flicker for a moment; Notification
    /// Center stays open.
    fileprivate func relayClockClick(at point: CGPoint) {
        guard collapsed, let current = assertion else { return }
        DIMenuBarRestrictionRelease(current)
        assertion = nil
        applied = nil
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            Self.click(at: point)
            try? await Task.sleep(for: .milliseconds(450))
            apply(force: true)
        }
    }

    // MARK: - Hiding again by itself

    /// Like Ice's auto-rehide: once revealed, the icons hide again after a
    /// while - but never out from under an open menu or a pointer still in the
    /// bar, which is someone in the middle of using one of them.
    private func scheduleRehide() {
        rehide?.cancel()
        let delay = Settings.shared.menuBarRehideDelay
        guard Settings.shared.menuBar, delay > 0 else { return }
        rehide = Task {
            try? await Task.sleep(for: .seconds(delay))
            while !Task.isCancelled, !collapsed {
                if !Self.menuIsOpen, !Self.pointerInMenuBar {
                    collapse()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static var pointerInMenuBar: Bool {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.contains { $0.frame.contains(point) && point.y >= $0.frame.maxY - 40 }
    }

    /// Any other app's menu or Control Center panel on screen.
    private static var menuIsOpen: Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let owner = window[kCGWindowOwnerPID as String] as? pid_t ?? own
            return owner != own && layer > Int(CGWindowLevelForKey(.mainMenuWindow)) && layer <= Int(CGWindowLevelForKey(.popUpMenuWindow))
        }
    }

    // MARK: - Rearranging, like Ice's layout editor

    /// True while `arrange` is moving icons.
    private(set) var arranging = false
    /// What the last rearrangement could not do. Nil when it all landed.
    private(set) var arrangeProblem: String?

    /// Puts the bar in `order` (icon ids, left to right). Each misplaced icon
    /// is ⌘-dragged into its slot and the bar read back before the next move,
    /// so a drop that did not land is retried rather than built on. Moves only
    /// ever go leftwards - never past the capsule, never into Control Center,
    /// Siri and the clock, which macOS pins.
    func arrange(_ order: [String]) {
        guard !placing, MenuBarItems.shared.authorized else { return }
        placing = true
        arranging = true
        arrangeProblem = nil
        let wasCollapsed = collapsed
        Task {
            defer {
                placing = false
                arranging = false
            }
            // A hidden icon has no place on the bar to be dragged from.
            if wasCollapsed {
                expand()
                try? await Task.sleep(for: .milliseconds(900))
            }
            rehide?.cancel()
            var openedOverflow = false
            if await Self.pointerIdle(for: 0.4, within: 6), Self.menuBarShowing {
                // Folded icons only have phantom frames; the open « lays them
                // out for real, where they can be picked up.
                if let toggle = MenuBarItems.shared.overflowToggle(), !toggle.expanded {
                    await Task.detached { Self.click(at: CGPoint(x: toggle.frame.midX, y: toggle.frame.midY)) }.value
                    openedOverflow = true
                    try? await Task.sleep(for: .milliseconds(600))
                }
                for _ in 0..<(order.count * 2 + 2) {
                    let bar = MenuBarItems.shared.realLayout().filter { order.contains($0.id) }
                    let wanted = order.filter { id in bar.contains { $0.id == id } }
                    guard let slot = wanted.indices.first(where: { bar[$0].id != wanted[$0] }),
                          let mover = bar.first(where: { $0.id == wanted[slot] })
                    else { break }
                    // Between the neighbours' centres, where the agent slots a
                    // drop; the leftmost slot is the first icon's left edge.
                    let anchor = bar[slot]
                    let x = slot > 0 ? (bar[slot - 1].frame.midX + anchor.frame.midX) / 2 : anchor.frame.minX + 3
                    let from = CGPoint(x: mover.frame.midX, y: mover.frame.midY)
                    await Task.detached { Self.commandDrag(from: from, to: CGPoint(x: x, y: from.y)) }.value
                    try? await Task.sleep(for: .milliseconds(700))
                }
                let final = MenuBarItems.shared.realLayout().filter { order.contains($0.id) }
                let wanted = order.filter { id in final.contains { $0.id == id } }
                if final.map(\.id) != wanted {
                    arrangeProblem = "Some icons would not move. macOS refuses drops next to icons it pins."
                }
            } else {
                arrangeProblem = "Couldn't move icons while the menu bar is hidden or the mouse is in use."
            }
            if openedOverflow, let toggle = MenuBarItems.shared.overflowToggle(), toggle.expanded {
                await Task.detached { Self.click(at: CGPoint(x: toggle.frame.midX, y: toggle.frame.midY)) }.value
                try? await Task.sleep(for: .milliseconds(400))
            }
            MenuBarItems.shared.scan()
            if wasCollapsed { collapse() } else { scheduleRehide() }
        }
    }

    // MARK: - Keeping the capsule rightmost

    /// Drags the capsule to just left of Control Center if anything movable
    /// sits between them. `manual` is the Settings button: it skips the
    /// back-off and waits less for the pointer to go still.
    func placeIfNeeded(manual: Bool = false) {
        guard Settings.shared.menuBar, !collapsed, !placing, MenuBarItems.shared.authorized else { return }
        if !manual, let gaveUp = placementGaveUp, Date().timeIntervalSince(gaveUp) < 300 { return }
        placing = true
        Task {
            var openedOverflow = false
            defer { placing = false }
            for _ in 0..<3 {
                MenuBarItems.shared.scan()
                let bar = MenuBarItems.shared.items.map { "\($0.id)@\(Int($0.frame.minX))" }.joined(separator: " ")
                menuBarLog.info("capsule check: \(bar, privacy: .public)")
                // Two of the bar's icons can be ours - the capsule and the Now
                // Playing stand-in - so the capsule is found by its own label.
                capsuleFrame = await Task.detached(operation: { MenuBarItems.ownFrame(described: "Hide menu bar icons") }).value
                guard var drag = placement() else { break }
                // A drag with the bar hidden would land in the fullscreen app.
                guard await Self.pointerIdle(for: manual ? 0.4 : 1.5, within: manual ? 5 : 30),
                      Self.menuBarShowing, !collapsed
                else { break }
                // Born leftmost on a full bar, the capsule is folded behind
                // the « and its frame is a phantom. Opening the « lays it out
                // for real, left of the notch, where it can be picked up.
                if let toggle = MenuBarItems.shared.overflowToggle(), !toggle.expanded,
                   drag.from.x <= toggle.frame.maxX {
                    await Task.detached { Self.click(at: CGPoint(x: toggle.frame.midX, y: toggle.frame.midY)) }.value
                    openedOverflow = true
                    try? await Task.sleep(for: .milliseconds(600))
                    MenuBarItems.shared.scan()
                    guard let unfolded = placement(),
                          let own = await Task.detached(operation: { MenuBarItems.ownFrame() }).value
                    else { break }
                    drag = (CGPoint(x: own.midX, y: own.midY), unfolded.to)
                }
                await Task.detached { Self.commandDrag(from: drag.from, to: drag.to) }.value
                try? await Task.sleep(for: .milliseconds(900))
            }
            // Fold the « back if we opened it.
            if openedOverflow, let toggle = MenuBarItems.shared.overflowToggle(), toggle.expanded {
                await Task.detached { Self.click(at: CGPoint(x: toggle.frame.midX, y: toggle.frame.midY)) }.value
                try? await Task.sleep(for: .milliseconds(400))
            }
            MenuBarItems.shared.scan()
            if placement() == nil {
                placementGaveUp = nil
            } else if Self.menuBarShowing {
                placementGaveUp = Date()
                NSLog("menu bar: capsule could not be moved to the right end")
            }
        }
    }

    /// A ⌘-drag for another of this app's items, with the same care: only when
    /// the bar is showing and nobody is using the mouse.
    static func drag(from: CGPoint, to: CGPoint) async {
        guard await pointerIdle(for: 1.5, within: 30), menuBarShowing else { return }
        await Task.detached { commandDrag(from: from, to: to) }.value
    }

    /// Where to drag from and to, or nil when the capsule is already rightmost.
    /// The capsule's frame as its own process reports it, for `placement`.
    private var capsuleFrame: CGRect?

    private func placement() -> (from: CGPoint, to: CGPoint)? {
        let bar = MenuBarItems.shared.items
        let ours = bar.filter(\.isOwn)
        let capsule = capsuleFrame.map { frame in ours.min { abs($0.frame.midX - frame.midX) < abs($1.frame.midX - frame.midX) } }
        guard let own = capsule ?? ours.first,
              let anchor = bar.filter(\.isPositionPinned).min(by: { $0.frame.minX < $1.frame.minX }),
              own.frame.maxX <= anchor.frame.minX + 1
        else { return nil }
        let between = bar.filter { !$0.isOwn && $0.frame.minX > own.frame.minX && $0.frame.midX < anchor.frame.minX }
        guard let last = between.max(by: { $0.frame.maxX < $1.frame.maxX }) else { return nil }
        // Between the two neighbours' centres is where the agent slots a drop
        // most reliably; inside the pinned cluster it refuses the drop outright.
        let x = min((last.frame.midX + anchor.frame.midX) / 2, anchor.frame.minX - 3)
        return (CGPoint(x: own.frame.midX, y: own.frame.midY), CGPoint(x: x, y: own.frame.midY))
    }

    /// False while a fullscreen app has the bar tucked away, or the bar is set
    /// to hide itself - a drag then would press into whatever is under it.
    private static var menuBarShowing: Bool {
        guard NSMenu.menuBarVisible() else { return false }
        // The bar's own window. `menuBarVisible()` still says true while an
        // accessory app is active, and macOS 27 draws no bar at all then -
        // measured: the window is simply gone.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard windows.contains(where: {
            $0[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.mainMenuWindow))
                && $0[kCGWindowOwnerName as String] as? String == "Window Server"
        }) else { return false }
        if UserDefaults.standard.bool(forKey: "_HIHideMenuBar") { return false }
        guard let front = NSWorkspace.shared.frontmostApplication else { return true }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return true }
        var fullscreen: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &fullscreen)
        return (fullscreen as? Bool) != true
    }

    /// Waits for a moment when nobody is using the mouse or keyboard, so the
    /// drag never takes the pointer out of someone's hand.
    private static func pointerIdle(for quiet: Double, within limit: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDown,
                                    .scrollWheel, .keyDown, .flagsChanged]
        while Date() < deadline {
            let idle = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
            if idle >= quiet { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// A ⌘-drag, posted at the HID level like a real mouse. Runs off the main
    /// thread on purpose: dragging our own item runs AppKit's tracking loop on
    /// our main thread, and posting from there too interleaves the two and the
    /// drop reverts. The physical mouse is decoupled for the second it takes
    /// and the pointer is put back where it was.
    nonisolated private static func commandDrag(from: CGPoint, to: CGPoint) {
        menuBarLog.info("drag (\(Int(from.x), privacy: .public),\(Int(from.y), privacy: .public)) -> (\(Int(to.x), privacy: .public),\(Int(to.y), privacy: .public))")
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.userData = syntheticTag
        let home = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            CGAssociateMouseAndMouseCursorPosition(1)
            if let home { CGWarpMouseCursorPosition(home) }
        }
        func post(_ type: CGEventType, _ point: CGPoint) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, from)
        usleep(40_000)
        post(.leftMouseDown, from)
        usleep(180_000)
        // Small steps: the agent tracks slot crossings, and long jumps bounce.
        let steps = max(6, min(24, Int(abs(to.x - from.x) / 30)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y))
            usleep(30_000)
        }
        usleep(120_000)
        post(.leftMouseUp, to)
        usleep(60_000)
    }

    /// A real click, with the pointer put straight back.
    nonisolated private static func click(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.userData = syntheticTag
        let home = CGEvent(source: nil)?.location
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(50_000)
        }
        if let home { CGWarpMouseCursorPosition(home) }
    }
}

// MARK: - Clock clicks while hidden

/// Catches plain left clicks on the clock while icons are hidden and hands
/// them to `relayClockClick`. Active only while collapsed; the tap lives on
/// the main run loop, which is idle enough that it never times out for long.
@MainActor
private final class ClockRelay {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The clock's distance from its display's right edge, its width and the
    /// bar's height - the same on every display, since each draws the bar.
    private var inset: CGFloat = 0
    private var width: CGFloat = 0
    private var height: CGFloat = 0
    private var swallowUp = false

    func enable(frame: CGRect?) {
        guard let frame, let display = Self.display(at: CGPoint(x: frame.midX, y: frame.midY)) else { return }
        let bounds = CGDisplayBounds(display)
        inset = bounds.maxX - frame.maxX
        width = frame.width
        height = frame.maxY - bounds.minY
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                // Only plain values cross into the main actor; the event stays here.
                let location = event.location
                let flags = event.flags
                let synthetic = event.getIntegerValueField(.eventSourceUserData) == MenuBarHider.syntheticTag
                let swallow = MainActor.assumeIsolated {
                    Unmanaged<ClockRelay>.fromOpaque(info).takeUnretainedValue()
                        .swallows(type, at: location, flags: flags, synthetic: synthetic)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("menu bar: clock tap unavailable - Notification Center stays closed while icons are hidden")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func disable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        swallowUp = false
    }

    private func swallows(_ type: CGEventType, at location: CGPoint, flags: CGEventFlags, synthetic: Bool) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            swallowUp = false
            return false
        }
        if synthetic { return false }
        if type == .leftMouseUp {
            defer { swallowUp = false }
            return swallowUp
        }
        swallowUp = false
        // Modifier clicks keep their meaning - ⌘-drag still rearranges.
        guard flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty,
              isOnClock(location)
        else { return false }
        swallowUp = true
        MenuBarHider.shared.relayClockClick(at: location)
        return true
    }

    /// From the clock's left edge to the display's right edge: the strip past
    /// the clock holds only the privacy dot, so a click there is a clock click
    /// that landed wide.
    private func isOnClock(_ point: CGPoint) -> Bool {
        guard width > 0, let display = Self.display(at: point) else { return false }
        let bounds = CGDisplayBounds(display)
        return point.y < bounds.minY + height && point.x >= bounds.maxX - inset - width
    }

    private static func display(at point: CGPoint) -> CGDirectDisplayID? {
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 1, &display, &count) == .success && count > 0 ? display : nil
    }
}

