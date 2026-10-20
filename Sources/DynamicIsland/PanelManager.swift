import AppKit

/// One panel per screen, rebuilt when the display layout changes.
///
/// A panel per screen keeps hover fully event-driven. The alternative - one panel
/// that follows the cursor - would need a global mouse monitor to know when the
/// cursor changed screen, which is the drain this project exists to avoid.
@MainActor
final class PanelManager {
    static let shared = PanelManager()

    private var panels: [CGDirectDisplayID: NotchPanel] = [:]

    private var lockedOut = false
    private var fullscreenOut = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    /// One pointer monitor for the whole app.
    ///
    /// Costs nothing at rest - a mouse that is not moving produces no events -
    /// and unlike a timer it never wakes the machine on its own. It is the only
    /// way to track the pointer over a window that passes clicks through.
    func watchPointer() {
        // Mouse-downs ride the monitor that was already here rather than a second
        // one. They arrive only on an actual click, so they cost nothing at rest -
        // the property that decides whether this app is worth running.
        let mask: NSEvent.EventTypeMask =
            [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let handler: (NSEvent) -> Void = { event in
            let pressed = event.type == .leftMouseDown
                || event.type == .rightMouseDown
                || event.type == .otherMouseDown
            MainActor.assumeIsolated { PanelManager.shared.dispatchPointer(pressed: pressed) }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handler(event)
            return event
        }
    }

    private func dispatchPointer(pressed: Bool) {
        let location = NSEvent.mouseLocation
        for panel in panels.values {
            guard let view = panel.contentView as? NotchContainerView else { continue }
            // Suppression is applied before the move: the move that follows a
            // click is the one that would otherwise arm the open.
            if pressed { view.pointerPressed(at: location) }
            view.pointerMoved(to: location)
        }
    }

    /// An app in fullscreen hides the menu bar.
    ///
    /// `NSMenu.menuBarVisible()` is the signal, not `visibleFrame` - comparing
    /// `visibleFrame.maxY` to `frame.maxY` is always true on a display that has
    /// no menu bar of its own, so a second monitor made the app hide every panel
    /// permanently.
    func watchFullscreen() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PanelManager.shared.updateFullscreen() }
        }
        // Deliberately not evaluated at launch: `menuBarVisible()` reads false
        // while the app is still starting, which hid every panel until the next
        // space change. Only real transitions drive this.
    }

    private func updateFullscreen() {
        guard Settings.shared.hideInFullscreen else {
            if fullscreenOut { fullscreenOut = false; applyVisibility() }
            return
        }
        let hidden = !NSMenu.menuBarVisible()
        guard fullscreenOut != hidden else { return }
        fullscreenOut = hidden
        applyVisibility()
    }

    /// Hotkey target: the island on whichever display has the pointer, falling
    /// back to the first panel.
    func toggleFocusedIsland() {
        // Fallback order matters with two displays: the pointer's screen, then
        // the one with the menu bar. `panels.values.first` alone is dictionary
        // order, so the hotkey opened a different island run to run.
        let panel = panels.values.first { $0.screenID == NSScreen.underPointer?.displayID }
            ?? panels.values.first { $0.screenID == NSScreen.main?.displayID }
            ?? panels.values.first
        guard let panel else { return }
        if panel.state.mode == .expanded { panel.state.collapse() } else { panel.state.open() }
    }

    /// Opens the island on a given tab, on whichever display the pointer is on.
    func focusIsland(tab: NotchState.Tab) {
        let panel = panels.values.first { $0.screenID == NSScreen.underPointer?.displayID }
            ?? panels.values.first { $0.screenID == NSScreen.main?.displayID }
            ?? panels.values.first
        panel?.state.open(on: tab)
    }

    func collapseAll() {
        for panel in panels.values { panel.state.collapse() }
    }

    private func applyVisibility() {
        for panel in panels.values {
            // The fullscreen signal is a single global flag, so it can only
            // speak for the display that owns the menu bar. Applied to every
            // panel, one app going fullscreen on the built-in also blanked the
            // island on an external monitor that had nothing covering it.
            //
            // `ownsMenuBar` alone was still too broad. `NSMenu.menuBarVisible()`
            // has no per-screen variant - it reports "something is fullscreen"
            // and nothing about where - so with a monitor plugged in, an app
            // going fullscreen on the *external* display also hid the island on
            // the built-in Mac, which had a menu bar and nothing covering it.
            //
            // The live per-screen menu bar height is the missing information.
            // The display actually covered loses its menu bar; the other keeps
            // it. Read from `NSScreen.screens` rather than `panel.screen`, which
            // is nil precisely while the panel is hidden.
            let screen = NSScreen.screens.first { $0.displayID == panel.screenID }
            let covered = fullscreenOut && panel.ownsMenuBar && (screen?.menubarHeight ?? 0) <= 0
            let hidden = lockedOut || covered
            if hidden {
                panel.state.collapse()
                panel.orderOut(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }
    }

    /// Nothing to draw behind the lock screen, and the panels would sit above it.
    /// Distributed notifications, so this costs nothing while unlocked.
    func watchLockScreen() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PanelManager.shared.setLockedOut(true) }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PanelManager.shared.setLockedOut(false) }
        }
    }

    private func setLockedOut(_ locked: Bool) {
        guard lockedOut != locked else { return }
        lockedOut = locked
        applyVisibility()
    }

    func applyCaptureExclusion() {
        for panel in panels.values { panel.applyCaptureExclusion() }
    }

    private var rebuildWork: DispatchWorkItem?

    /// Rebuilds now, and again once the layout has settled.
    ///
    /// `didChangeScreenParametersNotification` fires while macOS is still
    /// rearranging: docking a display posts it several times, and the geometry
    /// read during the first one is not the geometry you end up with. A panel
    /// built from that reading keeps a frame its screen no longer has, so the
    /// island ends up somewhere the pointer never goes - it is not gone, it is
    /// in the wrong place, which looks exactly the same.
    func scheduleRebuild() {
        rebuild()
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func rebuild() {
        let wanted = targetScreens()
        let wantedIDs = Set(wanted.map(\.1))

        for (id, panel) in panels where !wantedIDs.contains(id) {
            // Shut it down before dropping it. Opening is not local to a panel -
            // it grabs Escape and starts the stats sampler, both global - so a
            // panel torn off while open, or with a hover still pending, left the
            // hotkey held and the sampler running for an island that no longer
            // exists. Unplugging a display with the island up did exactly that.
            panel.state.hoverEnded()
            panel.orderOut(nil)
            panels[id] = nil
        }

        for (screen, id) in wanted {
            if let existing = panels[id] {
                existing.reposition(on: screen)
            } else {
                let panel = NotchPanel(screen: screen, screenID: id)
                panel.orderFrontRegardless()
                panels[id] = panel
            }
        }

        // A panel created while locked or covered must not come back on screen
        // just because it is new.
        applyVisibility()
    }

    /// Re-lays out every panel without recreating them - used when a size setting
    /// changes.
    func resize() {
        for (screen, id) in targetScreens() {
            panels[id]?.reposition(on: screen)
        }
    }

    private func targetScreens() -> [(NSScreen, CGDirectDisplayID)] {
        let all = NSScreen.screens.compactMap { screen -> (NSScreen, CGDirectDisplayID)? in
            screen.displayID.map { (screen, $0) }
        }
        guard Settings.shared.displayScope == .all else {
            // Prefer the notched built-in; fall back to the main display.
            let preferred = all.first { $0.0.notchFrame != nil } ?? all.first { $0.0 == NSScreen.main }
            return preferred.map { [$0] } ?? []
        }
        return all
    }
}
