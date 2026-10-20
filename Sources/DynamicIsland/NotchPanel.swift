import AppKit
import SwiftUI

/// Borderless, non-activating panel pinned to the top centre of one screen.
///
/// Created once at its largest size and never resized - only the SwiftUI content
/// inside it changes size. Resizing a window under the cursor costs a
/// WindowServer round trip per frame and fights the content animation.
@MainActor
final class NotchPanel: NSPanel {
    let state = NotchState()
    let screenID: CGDirectDisplayID
    /// Whether this panel's display carries the menu bar. Read at layout
    /// time, not from `self.screen`, which is nil while the panel is hidden -
    /// exactly when the fullscreen lockout needs to consult it.
    private(set) var ownsMenuBar = false

    init(screen: NSScreen, screenID: CGDirectDisplayID) {
        self.screenID = screenID
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // Left false deliberately. The tracking area's own `.mouseMoved` option
        // is scoped to its rect; turning this on delivers moves across the whole
        // 720x276 panel frame instead, waking the app far from the notch.
        acceptsMouseMovedEvents = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .statusBar + 1
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        applyCaptureExclusion()

        contentView = NotchContainerView(state: state)
        reposition(on: screen)
    }

    /// Sized to the largest the island can ever be, so the window itself never
    /// has to change while the content animates.
    func reposition(on screen: NSScreen) {
        ownsMenuBar = screen.ownsMenuBar
        state.physicalNotch = screen.notchSize
        state.ownsTopEdge = screen.ownsMenuBar || screen.notchSize != nil
        state.menuBarHeight = max(screen.menubarHeight, 24)
        state.topEdgeIsCrossing = screen.hasScreenAbove

        let settings = Settings.shared
        let width = max(settings.openWidth, state.hoverSize.width) + 120
        // The tallest tab - home with stats and lyrics - is the open
        // height plus 80, and its shadow needs another 32 below it.
        let height = max(settings.openHeight, state.hoverSize.height) + 116

        setFrame(
            NSRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.maxY - height,
                width: width,
                height: height
            ),
            display: false
        )
    }

    /// `.none` keeps the island out of screen recordings and screenshots.
    func applyCaptureExclusion() {
        sharingType = Settings.shared.hideFromCapture ? .none : .readOnly
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
