import AppKit
import ScreenCaptureKit
import SwiftUI

/// Ice's layout editor, rebuilt: the menu bar's real icons in two strips -
/// Shown and Hidden - that you drag to reorder, or drag from one strip to the
/// other to change whether an icon hides.
///
/// Same shape as Ice's `LayoutBar`: each strip is an AppKit view whose tiles
/// are the icons' own pixels, captured from the bar. Dragging a tile turns it
/// into a gap, the others slide apart under the pointer, and on drop the real
/// icon is moved next to its new neighbour - left of the tile to its right, or
/// right of the one to its left. The move itself is `MenuBarHider.arrange`.
@MainActor
final class MenuBarLayout {
    static let shared = MenuBarLayout()

    enum Section { case shown, hidden }

    let shownStrip = LayoutStrip(section: .shown)
    let hiddenStrip = LayoutStrip(section: .hidden)
    private var tiles: [String: LayoutTile] = [:]
    /// Captured icon pixels, by item id. Kept for the session: a hidden icon
    /// has no pixels to capture, so it keeps its last picture.
    private var images: [String: NSImage] = [:]
    /// A tile is in the air; the strips must not be rebuilt under it.
    var dragging = false

    private init() {}

    /// Rebuilds both strips from the last reading of the bar.
    func reload() {
        guard !dragging, !MenuBarHider.shared.arranging else { return }
        var shown: [LayoutTile] = []
        var hidden: [LayoutTile] = []
        // Control Center, Siri and the clock are left out: macOS pins them, so
        // there is nothing to drag, and the clock alone is wider than a strip.
        for item in MenuBarItems.shared.listed where !item.isPositionPinned {
            let tile = tiles[item.id] ?? LayoutTile()
            tiles[item.id] = tile
            tile.item = item
            tile.image = images[item.id]
            if MenuBarHider.shared.hides(item) {
                hidden.append(tile)
            } else {
                shown.append(tile)
            }
        }
        shownStrip.tiles = shown
        hiddenStrip.tiles = hidden
    }

    /// A tile landed in `strip`. Its neighbours there say where the real icon
    /// goes; the strip says whether it hides.
    func dropped(_ tile: LayoutTile, in strip: LayoutStrip) {
        guard let item = tile.item, let index = strip.tiles.firstIndex(of: tile) else { return }
        let hider = MenuBarHider.shared

        let wantsHidden = strip.section == .hidden
        if hider.hides(item) != wantsHidden {
            hider.setHides(wantsHidden, item)
        }

        let current = MenuBarItems.shared.listed.filter { !$0.isPositionPinned }.map(\.id)
        var order = current.filter { $0 != item.id }
        let right = strip.tiles[(index + 1)...].first?.item
        let left = strip.tiles[..<index].last?.item
        let from = current.firstIndex(of: item.id) ?? 0
        if let left, let passed = current.firstIndex(of: left.id), passed > from,
           let slot = order.firstIndex(of: left.id) {
            // Dragged rightwards past `left`: sit right after it. Anchoring to
            // the right neighbour instead would jump over any hidden icons
            // between the two, which this strip does not show.
            order.insert(item.id, at: slot + 1)
        } else if let right, let slot = order.firstIndex(of: right.id) {
            order.insert(item.id, at: slot)
        } else if let left, let slot = order.firstIndex(of: left.id) {
            order.insert(item.id, at: slot + 1)
        } else {
            // Alone in its strip: membership changed, position stays.
            order = current
        }
        if order != current { hider.arrange(order) } else { reload() }
    }

    /// Captures every icon that is on screen right now, from one picture of
    /// the bar. Needs Screen Recording; without it the tiles draw app icons.
    func capture() async {
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.screens.first else { return }
        let items = MenuBarItems.shared.realLayout().filter { !$0.isOwn }
        guard let barHeight = items.map(\.frame.maxY).max(), barHeight > 0 else { return }
        let strip = CGRect(x: 0, y: 0, width: screen.frame.width, height: barHeight)
        guard let picture = try? await SCScreenshotManager.captureImage(in: strip) else { return }
        let scale = CGFloat(picture.width) / strip.width
        let wallpaper = await Self.wallpaper(in: strip, width: picture.width, height: picture.height)
        let hider = MenuBarHider.shared
        // Icons folded behind a closed « keep a phantom frame over the « or
        // their neighbours - capturing there drew the « into someone's tile.
        let folded = MenuBarItems.shared.overflowToggle().flatMap { $0.expanded ? nil : $0.frame.maxX }
        for item in items {
            // Hidden icons keep a stale frame over whatever took their place.
            if hider.collapsed, hider.hides(item) { continue }
            let overlaps = items.contains { $0.id != item.id && $0.frame.intersection(item.frame).width > 4 }
            if overlaps || (folded.map { item.frame.minX < $0 } ?? false) {
                // A wrong picture is worse than the app icon.
                images[item.id] = nil
                continue
            }
            let pixels = CGRect(x: item.frame.minX * scale, y: item.frame.minY * scale,
                                width: item.frame.width * scale, height: item.frame.height * scale)
            guard item.frame.minX >= 0, item.frame.maxX <= strip.maxX, let crop = picture.cropping(to: pixels)
            else { continue }
            let behind = wallpaper?.cropping(to: pixels)
            images[item.id] = NSImage(cgImage: Self.lifted(crop, over: behind) ?? crop, size: item.frame.size)
        }
        reload()
    }

    /// The wallpaper strip behind the bar, captured on its own. macOS 27's
    /// bar is transparent, so this is exactly what sits behind every icon.
    private static func wallpaper(in strip: CGRect, width: Int, height: Int) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: {
                  $0.title == "Wallpaper" && $0.owningApplication?.bundleIdentifier == "com.apple.WindowManager"
              })
        else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = strip
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    }

    /// Lifts an icon off the wallpaper it was captured over - otherwise every
    /// tile carries a dark square of it. How far each pixel is from the
    /// wallpaper behind it is how much icon it holds, and the colour is
    /// un-mixed from the wallpaper so edges stay soft and coloured icons keep
    /// their colour. Without a wallpaper capture, a row's outermost pixels
    /// stand in for it - right for padded icons, wrong for tight ones like the
    /// battery, which is why the capture comes first.
    static func lifted(_ image: CGImage, over behind: CGImage?) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 6, height > 0, let pixels = rgba(image), let base = pixels.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let wall = behind.flatMap { $0.width == width && $0.height == height ? rgba($0) : nil }
        let wallBase = wall?.data?.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = base + y * width * 4
            var edge = [0.0, 0.0, 0.0]
            for x in [0, 1, width - 2, width - 1] {
                for c in 0..<3 { edge[c] += Double(row[x * 4 + c]) / 4 }
            }
            for x in 0..<width {
                let pixel = row + x * 4
                var background = edge
                if let wallBase {
                    let under = wallBase + (y * width + x) * 4
                    background = (0..<3).map { Double(under[$0]) }
                }
                // Distance from the background, per channel, against the most
                // it could be - so a fully covering glyph reads as 1.
                var coverage = 0.0
                for c in 0..<3 {
                    let reach = max(background[c], 255 - background[c], 1)
                    coverage = max(coverage, abs(Double(pixel[c]) - background[c]) / reach)
                }
                // Wallpaper texture is small differences; drop them.
                let alpha = max(0, min(1, (coverage - 0.08) / 0.92))
                for c in 0..<3 {
                    let colour = background[c] + (Double(pixel[c]) - background[c]) / max(coverage, 0.01)
                    pixel[c] = UInt8(max(0, min(255, colour)) * alpha)
                }
                pixel[3] = UInt8(alpha * 255)
            }
        }
        return pixels.makeImage()
    }

    private static func rgba(_ image: CGImage) -> CGContext? {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }
}

// MARK: - A strip

/// One section's icons, laid out from the right like the real bar.
final class LayoutStrip: NSView {
    let section: MenuBarLayout.Section
    private let gap: CGFloat = 2

    var tiles: [LayoutTile] = [] {
        didSet { layoutTiles(animated: !oldValue.isEmpty) }
    }

    init(section: MenuBarLayout.Section) {
        self.section = section
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.layoutTile])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutTiles(animated: false)
    }

    private func layoutTiles(animated: Bool) {
        for view in subviews where !tiles.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        let total = tiles.reduce(0) { $0 + $1.width } + gap * CGFloat(max(tiles.count - 1, 0))
        var x = max(8, bounds.width - 8 - total)
        for tile in tiles {
            if tile.superview !== self { addSubview(tile) }
            // Native size, like Ice: a captured slice is the bar's full height,
            // and squeezing it into a shorter tile flattened every icon.
            let height = min(tile.height, bounds.height)
            let frame = CGRect(x: x, y: (bounds.height - height) / 2, width: tile.width, height: height)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    tile.animator().frame = frame
                }
            } else {
                tile.frame = frame
            }
            x += tile.width + gap
        }
    }

    // MARK: Dropping

    /// Slots the dragged tile under the pointer: after every tile whose centre
    /// is left of it. Moving the gap shifts the neighbour by the gap's width,
    /// which is exactly the hysteresis that stops it flickering back.
    private func track(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let tile = info.draggingSource as? LayoutTile, let item = tile.item else { return [] }
        // macOS hides these with everything else and offers no way to keep
        // them, so they cannot go in Shown.
        if section == .shown, item.kind == .collateral { return [] }
        let x = convert(info.draggingLocation, from: nil).x
        var arranged = tiles.filter { $0 !== tile }
        arranged.insert(tile, at: arranged.filter { $0.frame.midX < x }.count)
        if arranged != tiles { tiles = arranged }
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let tile = sender?.draggingSource as? LayoutTile, let index = tiles.firstIndex(of: tile) {
            tiles.remove(at: index)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let tile = sender.draggingSource as? LayoutTile, tiles.contains(tile) else { return false }
        MenuBarLayout.shared.dropped(tile, in: self)
        return true
    }
}

// MARK: - A tile

/// One icon: its captured picture, or its app's icon until there is one.
final class LayoutTile: NSView, NSDraggingSource {
    var item: MenuBarItems.Item? {
        didSet {
            toolTip = item?.name
            setAccessibilityLabel(item?.name)
        }
    }
    var image: NSImage? { didSet { needsDisplay = true } }
    /// While dragged, the tile is the gap it will fill.
    private var isGap = false { didSet { needsDisplay = true } }

    var width: CGFloat { max(image?.size.width ?? item?.frame.width ?? 28, 22) }
    var height: CGFloat { image?.size.height ?? 24 }

    init() {
        super.init(frame: .zero)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard !isGap, let item else { return }
        if let image {
            image.draw(in: bounds)
        } else if let icon = item.icon {
            let side: CGFloat = 16
            icon.isTemplate = item.key.hasPrefix(MenuBarItems.modulePrefix)
            let rect = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            if icon.isTemplate {
                // Tint template symbols for the dark strip.
                let tinted = NSImage(size: rect.size, flipped: false) { drawRect in
                    icon.draw(in: drawRect)
                    NSColor.white.set()
                    drawRect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect)
            } else {
                icon.draw(in: rect)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard item != nil else { return }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(Data(), forType: .layoutTile)
        let dragging = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let snapshot = bitmapImageRepForCachingDisplay(in: bounds)
        if let snapshot {
            cacheDisplay(in: bounds, to: snapshot)
            let picture = NSImage(size: bounds.size)
            picture.addRepresentation(snapshot)
            dragging.setDraggingFrame(bounds, contents: picture)
        }
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        MenuBarLayout.shared.dragging = true
        session.animatesToStartingPositionsOnCancelOrFail = false
        DispatchQueue.main.async { self.isGap = true }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isGap = false
        MenuBarLayout.shared.dragging = false
        // Dropped outside both strips, or refused: put everything back.
        if operation == [] { MenuBarLayout.shared.reload() }
    }
}

extension NSPasteboard.PasteboardType {
    static let layoutTile = Self("dev.local.dynamicisland.layout-tile")
}

// MARK: - SwiftUI

/// A strip in the Settings form, styled as a slice of menu bar.
struct LayoutStripView: NSViewRepresentable {
    let strip: LayoutStrip
    /// Read so a change to the bar or to a hide switch redraws the strips.
    let revision: [String]

    func makeNSView(context: Context) -> LayoutStrip { strip }

    func updateNSView(_ nsView: LayoutStrip, context: Context) {
        MenuBarLayout.shared.reload()
    }
}
