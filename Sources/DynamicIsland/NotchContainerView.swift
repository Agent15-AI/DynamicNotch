import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns all input for one screen's island.
///
/// SwiftUI's `.onHover` is unreliable inside a non-activating accessory panel,
/// so hover, hit testing and drag targeting live here in AppKit and the SwiftUI
/// layer stays presentational.
///
/// Tracking is a single `.mouseEnteredAndExited` area sized to the island - never
/// a global mouse monitor. The process sleeps until the cursor crosses that edge.
/// The panel is never key, so AppKit swallows the first click into every SwiftUI
/// control inside it. Without this, buttons and sliders in the expanded island
/// silently do nothing.
@MainActor
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Inclusive containment.
///
/// `NSRect.contains` is half-open: it excludes the max edge. The hover band's top
/// edge *is* the top of the screen, and a pointer shoved into that edge reports
/// exactly `screen.maxY` - so the half-open test rejected it and the island
/// refused to open unless the pointer stopped a little lower down.
private func containsInclusive(_ rect: NSRect, _ point: NSPoint) -> Bool {
    point.x >= rect.minX && point.x <= rect.maxX
        && point.y >= rect.minY && point.y <= rect.maxY
}

/// The only registered drag destination in the panel.
///
/// A window is a drop target exactly where a registered view sits under the
/// pointer - drag targeting walks view frames and ignores `hitTest`, so the
/// container returning nil there bought nothing. With the whole 760x276
/// container registered, every drag over that block was captured and AppKit does
/// not fall through to the window beneath: on a display with no menu bar that is
/// a slab of real content where files could not be dropped at all. Only this
/// strip is registered, and it grows to the island once a drag is accepted, so
/// the dead zone is the drop target itself and nothing more.
@MainActor
private final class DropStrip: NSView {
    // Weak, not unowned. The container owns this view, so normally it cannot
    // outlive it - but AppKit retains a drag destination for the length of a
    // session, and a display unplugged mid-drag tears the container down first.
    // `unowned` turns that into a crash; this makes it a no-op.
    weak var owner: NotchContainerView?

    // Drags only. Clicks, scrolls and hover all belong to the container, which
    // sits behind this and does its own hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.dragEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.dragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        owner?.dragExited()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        owner?.dragPerformed(sender) ?? false
    }
}

@MainActor
final class NotchContainerView: NSView {
    private let state: NotchState
    private let dropStrip = DropStrip()

    init(state: NotchState) {
        self.state = state
        super.init(frame: .zero)

        let host = FirstMouseHostingView(rootView: NotchView(state: state))
        host.sizingOptions = []
        // The panel deliberately covers the notch, so SwiftUI must not inset its
        // content for the safe area the notch creates.
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)

        dropStrip.owner = self
        dropStrip.registerForDraggedTypes([.fileURL])
        addSubview(dropStrip)

        // The island grows on a delay after hover, so the tracking rect has to be
        // rebuilt when the size actually changes, not when the mouse arrives.
        state.pointerIsInHoverRect = { [weak self] in self?.cursorIsInsideIsland ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The strip covers the whole island while it is open, so a file can be
    /// dropped anywhere on it, and shrinks back to the closed target otherwise.
    /// Driven by events rather than observation: the pointer monitor already
    /// fires on every move, and the drag handlers set it directly because a drag
    /// session produces no mouse-moved events of its own.
    private func syncDropStrip() {
        // Zero-sized with the shelf off: a registered view that answers "no drop"
        // still stops the drag reaching the window underneath, so the only way to
        // get out of the way completely is to have no area at all.
        let wanted: NSRect =
            if !Settings.shared.shelf { .zero }
            else if state.mode == .expanded { islandRect }
            else { dragRect() }
        // Assigned only on a real change. This runs on every pointer move, and a
        // frame set is a layout pass however equal the value.
        guard dropStrip.frame != wanted else { return }
        dropStrip.frame = wanted
    }

    override func layout() {
        super.layout()
        syncDropStrip()
    }

    /// Island rect in view coordinates, anchored top-centre to match SwiftUI.
    private var islandRect: NSRect { rect(state.size) }

    /// What the pointer reacts to. While collapsed this is deliberately larger
    /// than the drawn island - with the idle state hidden there is nothing to aim
    /// at, so the target has to be forgiving.
    private var hoverRect: NSRect {
        state.mode == .expanded ? islandRect : rect(state.hoverSize)
    }

    private func rect(_ size: CGSize) -> NSRect {
        NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Points outside the island fall through, so the panel never swallows menu
    /// bar or desktop clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Collapsed, the island paints nothing the user can aim at, so it must
        // not intercept clicks - the menu bar and desktop are underneath.
        // Hover still works: tracking areas are geometry, not hit testing.
        guard state.mode == .expanded else {
            if state.dropTargeted, containsInclusive(hoverRect, local) { return self }
            // Claim the closed island's own footprint so scroll gestures reach
            // us - but only where that is free. Under a physical notch it is
            // bezel, and a drawn island is its own target. On a display with no
            // notch and nothing drawn it is live UI: on an external monitor with
            // no menu bar that strip is the browser's tab row, and claiming it
            // swallowed those clicks outright.
            if Settings.shared.scrollGesture, state.hasPhysicalNotch || state.idleVisible,
               rect(state.collapsedSize).contains(local) { return self }
            // A screenshot activity is the one collapsed state you are meant to
            // grab, so it claims its own drawn area for the seconds it is up.
            if HUD.shared.screenshotURL != nil, rect(state.size).contains(local) { return self }
            // Same idea for a mounted disk image: the offer is only an offer if
            // it can be accepted where it is shown.
            // A calendar reminder with a call link, an install offer:
            // activities that do something when clicked claim their area too.
            if HUD.shared.clickAction != nil, rect(state.size).contains(local) { return self }
            return nil
        }
        guard islandRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// Called by the shared pointer monitor with a screen-space location.
    ///
    /// Hit testing is done here rather than by an `NSTrackingArea`. A tracking
    /// area only receives enter/exit where the window is hit-testable, and this
    /// panel deliberately returns nil from `hitTest` so clicks fall through to
    /// the menu bar. That combination silently drops most activations - a fast
    /// flick registers nothing at all.
    /// A click landed somewhere. If it was inside the closed band, whatever is
    /// under the pointer wanted it - not us.
    func pointerPressed(at screenPoint: NSPoint) {
        guard state.mode == .collapsed, let window else { return }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard containsInclusive(hoverRect, point) else { return }
        state.hoverPressed()
    }

    func pointerMoved(to screenPoint: NSPoint) {
        syncDropStrip()
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        switch state.mode {
        case .collapsed:
            if containsInclusive(hoverRect, point) { state.hoverBegan() } else { state.hoverEnded() }
        case .expanded:
            // Typing outranks the pointer. Once a text view has focus the
            // pointer is on its way to the keyboard, and where it ends up says
            // nothing about whether the user is done - closing on it threw away
            // whatever was being typed in the notes tab.
            guard !isEditingText, !isPickingFile else { return }
            // Hysteresis: a few points of slop so boundary jitter while the
            // pointer rests on an edge does not flicker the island shut.
            guard !containsInclusive(islandRect.insetBy(dx: -6, dy: -6), point) else {
                state.pointerEnteredSinceOpen = true
                return
            }
            // An island the pointer opened closes as soon as the pointer leaves.
            // One opened by the hotkey waits until the pointer has been inside
            // it at least once - otherwise a stray movement shuts it the instant
            // it appears, and without the second half it never shuts at all.
            guard state.openedByPointer || state.pointerEnteredSinceOpen else { return }
            state.collapse()
        }
    }


    /// Whether the keyboard is being used inside the island.
    ///
    /// SwiftUI's `TextEditor` and `TextField` both end up with an `NSTextView`
    /// as first responder - the field editor in the second case - so this one
    /// test covers every place text can be entered.
    private var isEditingText: Bool {
        window?.firstResponder is NSTextView
    }

    /// Whether one of our own open panels is up.
    ///
    /// Choosing an app to uninstall means moving the pointer off the island, and
    /// the island closed behind the panel - so the leftovers it found were
    /// listed inside a shut island and looked like nothing had happened.
    private var isPickingFile: Bool {
        NSApp.windows.contains { $0 is NSOpenPanel && $0.isVisible }
    }

    // The app is an accessory and the panel is never key, so without this the
    // first click is treated as an activating click and never reaches the view.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Handlers are no-ops unless the mode actually changes. Growing the island
    // rebuilds the tracking area, which lands the cursor inside the new area and
    // re-fires the same event - without these guards that is an infinite
    // enter/exit loop that never lets the CPU idle.
    private var cursorIsInsideIsland: Bool {
        guard let window else { return false }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return containsInclusive(hoverRect, local)
    }

    /// Scroll down on the island to open, up to close.
    ///
    /// Free at rest: `scrollWheel` only arrives when the pointer is already over
    /// the view, so there is no monitor and nothing polls.
    override func scrollWheel(with event: NSEvent) {
        if handleSwipe(event) { return }
        guard Settings.shared.scrollGesture else { return super.scrollWheel(with: event) }
        // Ignore the tail of a flick, or one gesture toggles repeatedly.
        guard abs(event.scrollingDeltaY) > 1.5, event.momentumPhase == [] else { return }

        if state.mode == .collapsed {
            if event.scrollingDeltaY < 0 { state.open() }
            return
        }

        // Expanded: the close gesture is confined to the header strip. Anywhere
        // else the scroll belongs to whatever content is under the pointer -
        // swallowing it here made the calendar unscrollable, since SwiftUI never
        // saw the event.
        let point = convert(event.locationInWindow, from: nil)
        let header = NSRect(
            x: islandRect.minX,
            y: islandRect.maxY - state.notchInset,
            width: islandRect.width,
            height: state.notchInset
        )
        guard containsInclusive(header, point) else { return super.scrollWheel(with: event) }
        if event.scrollingDeltaY > 0 { state.collapse() }
    }

    // MARK: - Swipe to change track

    private var swipeTravel: CGFloat = 0
    private var swipeFired = false

    /// Swipe sideways on the closed island to change track.
    ///
    /// Free at rest for the same reason the open gesture is: `scrollWheel` only
    /// arrives when the pointer is already over the view, so there is no monitor.
    ///
    /// Collapsed only. Expanded, a horizontal scroll belongs to whatever is under
    /// the pointer - swallowing it there would break the calendar the same way
    /// the vertical gesture once did, and the expanded panel already has both
    /// transport buttons and a draggable scrubber.
    ///
    /// Returns true when the event was consumed.
    private func handleSwipe(_ event: NSEvent) -> Bool {
        guard Settings.shared.swipeGesture, state.mode == .collapsed,
              NowPlaying.shared.hasTrack
        else { return false }

        // One flick is one track, however long the tail runs.
        if event.phase == .began { swipeTravel = 0; swipeFired = false }
        guard event.momentumPhase == [] else { return swipeFired }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }

        swipeTravel += event.scrollingDeltaX
        guard !swipeFired, abs(swipeTravel) > 28 else { return true }
        swipeFired = true
        // Same axis convention as the open gesture: content follows the fingers,
        // so pushing it left brings on what comes next.
        NowPlaying.shared.send(swipeTravel < 0 ? .next : .previous)
        if Settings.shared.haptics { Motion.tick() }
        return true
    }

    // MARK: - Screenshot hand-off

    /// Set on mouse-down over a screenshot activity. Dragging carries the file
    /// out; releasing without dragging parks it on the shelf.
    private var pendingScreenshot: URL?
    private var pressOrigin: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard state.mode == .collapsed, rect(state.size).contains(point)
        else { return super.mouseDown(with: event) }
        if let action = HUD.shared.clickAction {
            action()
            return
        }
        guard let url = HUD.shared.screenshotURL else { return super.mouseDown(with: event) }
        pendingScreenshot = url
        pressOrigin = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url = pendingScreenshot else { return super.mouseDragged(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        // Hysteresis, so a slightly unsteady click is still a click.
        guard hypot(point.x - pressOrigin.x, point.y - pressOrigin.y) > 6 else { return }
        pendingScreenshot = nil

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let side: CGFloat = 52
        item.setDraggingFrame(
            NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
            contents: NSWorkspace.shared.icon(forFile: url.path)
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let url = pendingScreenshot else { return super.mouseUp(with: event) }
        pendingScreenshot = nil
        Shelf.shared.add([url])
        state.open(on: .shelf)
    }

    // MARK: - Drag and drop

    /// The closed drop target, and the strip's own frame while collapsed.
    private func dragRect() -> NSRect {
        guard state.mode == .collapsed else { return islandRect }
        var rect = hoverRect
        // A drag needs a deeper target than a hover: the pointer is carrying
        // something and cannot be placed as precisely.
        let depth = max(state.menuBarHeight, 28)
        rect.origin.y = bounds.maxY - depth
        rect.size.height = depth
        rect = rect.insetBy(dx: -40, dy: 0)
        return rect
    }

    /// A screenshot dragged *out* of the island must not immediately re-enter it -
    /// the island would open under the cursor and hide the drag in progress.
    private func isOwnDrag(_ sender: any NSDraggingInfo) -> Bool {
        sender.draggingSource as AnyObject? === self
    }

    // Called by `DropStrip`, which is the registered destination. Reaching one of
    // these already means the pointer is inside the strip, so there is no rect
    // test left to do here.
    fileprivate func dragEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !isOwnDrag(sender), Settings.shared.shelf else { return [] }
        state.dropTargeted = true
        state.open(on: .shelf)
        // Grown here, not on the next mouse-moved: a drag session runs its own
        // modal loop and posts none, so without this the strip would still be
        // the closed target and a drop onto the open island would miss it.
        syncDropStrip()
        return .copy
    }

    fileprivate func dragUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !isOwnDrag(sender), Settings.shared.shelf else { return [] }
        if !state.dropTargeted {
            state.dropTargeted = true
            state.open(on: .shelf)
            syncDropStrip()
        }
        return .copy
    }

    fileprivate func dragExited() {
        state.dropTargeted = false
        state.collapse()
        syncDropStrip()
    }

    fileprivate func dragPerformed(_ sender: any NSDraggingInfo) -> Bool {
        defer { syncDropStrip() }
        guard state.mode == .expanded else { state.dropTargeted = false; return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        state.dropTargeted = false
        guard !urls.isEmpty else { return false }
        Shelf.shared.add(urls)
        state.tab = .shelf
        return true
    }
}

extension NotchContainerView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}
