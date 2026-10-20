import AppKit

/// This app's own Now Playing icon, shown in place of Apple's while menu bar
/// icons are hidden.
///
/// macOS 27 hides its Now Playing module whenever any icon is hidden: the
/// restriction names nine system items and Now Playing is not one of them, and
/// no bundle id keeps it (Pelmet measured the same and ships a stand-in too).
/// So when Now Playing is set to show, this icon appears for as long as the
/// real one is away - only while something is playing, as Apple's does - and a
/// click opens the island, which carries the media controls.
@MainActor
final class NowPlayingStandIn: NSObject {
    static let shared = NowPlayingStandIn()

    private var item: NSStatusItem?

    private override init() {}

    /// Re-run whenever hiding, the Now Playing choice or the track changes.
    func update() {
        let hider = MenuBarHider.shared
        let wanted = Settings.shared.menuBar
            && hider.collapsed
            && Settings.shared.menuBarChoices["com.apple.menuextra.now-playing"] == false
            && NowPlaying.shared.hasTrack
        if wanted, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            // Named, so a ⌘-drag while icons are hidden is remembered.
            item.autosaveName = "dynamicisland.menubar.nowplaying"
            item.button?.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Now Playing")
            item.button?.target = self
            item.button?.action = #selector(clicked)
            self.item = item
        }
        let appearing = wanted && item?.isVisible != true
        item?.isVisible = wanted
        if appearing { place() }
        item?.button?.toolTip = [NowPlaying.shared.title, NowPlaying.shared.artist]
            .filter { !$0.isEmpty }.joined(separator: " - ")
    }

    /// Puts the stand-in where Now Playing sits among the icons that stay:
    /// right after the nearest of them to its left. A new status item is born
    /// at the far left and only a real ⌘-drag moves it - which macOS then
    /// remembers, so this drags at most once per arrangement.
    private func place() {
        let listed = MenuBarItems.shared.listed
        guard let index = listed.firstIndex(where: { $0.key == "com.apple.menuextra.now-playing" }),
              let anchor = listed[..<index].last(where: { $0.kind != .collateral && !MenuBarHider.shared.hides($0) })
        else { return }
        Task {
            // Let the bar settle into its hidden layout first.
            try? await Task.sleep(for: .seconds(1))
            guard item?.isVisible == true else { return }
            MenuBarItems.shared.scan()
            let bar = MenuBarItems.shared.items.filter { !$0.isOwn }
            guard let left = bar.first(where: { $0.key == anchor.key }),
                  let own = await Task.detached(operation: { MenuBarItems.ownFrame(described: "Now Playing") }).value
            else { return }
            let right = bar.first { $0.frame.minX >= left.frame.maxX - 1 }
            let placed = own.minX >= left.frame.maxX - 1 && own.maxX <= (right?.frame.minX ?? .greatestFiniteMagnitude) + 1
            guard !placed else { return }
            let x = right.map { (left.frame.midX + $0.frame.midX) / 2 } ?? left.frame.maxX + 6
            menuBarLog.info("stand-in at \(Int(own.minX), privacy: .public), after \(left.id, privacy: .public)@\(Int(left.frame.minX), privacy: .public) -> \(Int(x), privacy: .public)")
            await MenuBarHider.drag(from: CGPoint(x: own.midX, y: own.midY), to: CGPoint(x: x, y: own.midY))
        }
    }

    @objc private func clicked() {
        PanelManager.shared.toggleFocusedIsland()
    }
}
