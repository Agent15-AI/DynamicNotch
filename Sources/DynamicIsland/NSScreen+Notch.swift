//  Notch geometry from public AppKit API.
//  Adapted from DynamicNotchKit (MrKai77), MIT.

import AppKit

extension NSScreen {
    var notchSize: NSSize? {
        guard
            let left = auxiliaryTopLeftArea?.width,
            let right = auxiliaryTopRightArea?.width
        else { return nil }
        return NSSize(width: frame.width - left - right, height: safeAreaInsets.top)
    }

    /// Screen-coordinate rect of the physical notch cutout, if there is one.
    var notchFrame: NSRect? {
        guard let size = notchSize else { return nil }
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    var menubarHeight: CGFloat { frame.maxY - visibleFrame.maxY }

    /// Notch size on a notched display, or a pill sized to the menu bar on a
    /// display without one so external monitors still get an island.
    var islandBaseSize: NSSize {
        notchSize ?? NSSize(width: 190, height: max(menubarHeight, 24))
    }

    /// True when another display sits directly above this one, sharing its top
    /// edge.
    ///
    /// That edge is then a crossing, not a wall: the pointer slides through onto
    /// the display above instead of stopping. A thin top-edge hover strip is
    /// unreachable on such a screen and has to be deepened.
    var hasScreenAbove: Bool {
        NSScreen.screens.contains { other in
            other != self
                && abs(other.frame.minY - frame.maxY) < 2
                && other.frame.maxX > frame.minX
                && other.frame.minX < frame.maxX
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[.init("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// True when this display carries the menu bar.
    ///
    /// With "Displays have separate Spaces" off, a second display has none at
    /// all - which is why `menubarHeight` is 0 there and why a global menu-bar
    /// signal can never speak for it.
    var ownsMenuBar: Bool { menubarHeight > 0 }

    /// The display the pointer is on.
    ///
    /// Not `NSScreen.main`: that follows the key window, and an accessory app
    /// has none - so it reports whichever display some other app was last
    /// focused on. A panel opened from the external display landed on the
    /// built-in.
    static var underPointer: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) } ?? main
    }
}
