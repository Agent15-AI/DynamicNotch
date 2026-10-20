import SwiftUI

/// Per-screen island state. One instance per panel.
@MainActor
@Observable
final class NotchState {
    /// Hover opens the island directly - there is no intermediate peek state and
    /// no click required.
    enum Mode { case collapsed, expanded }

    var mode: Mode = .collapsed
    var tab: Tab = .home
    /// True while a file drag is hovering, so the shelf can highlight.
    var dropTargeted = false

    /// How the island was opened. A pointer-opened island closes when the pointer
    /// leaves; one opened by the hotkey must not, or any stray mouse movement
    /// shuts it the instant it appears.
    private(set) var openedByPointer = false

    /// True once the pointer has been inside the open island.
    ///
    /// An island opened by the hotkey ignores pointer-exit, so a stray mouse
    /// movement cannot shut it the instant it appears. That rule on its own
    /// leaves it open forever: move away and it stays. Once the pointer has
    /// actually been inside it, leaving is a deliberate act and closes it.
    var pointerEnteredSinceOpen = false

    enum Tab: String, CaseIterable, Identifiable {
        case home, shelf, clock, tools, notes, mixer
        var id: String { rawValue }

        /// Named for what it holds, not a vague umbrella - a specific label is
        /// what makes the rail predictable.
        var title: String {
            switch self {
            case .home: "Now Playing"
            case .shelf: "Shelf"
            case .clock: "Clock"
            case .tools: "Tools"
            case .notes: "Notes"
            case .mixer: "App volume"
            }
        }

        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .shelf: "tray.fill"
            case .clock: "clock"
            case .tools: "wrench.adjustable.fill"
            case .notes: "square.and.pencil"
            case .mixer: "slider.horizontal.3"
            }
        }
    }

    // MARK: - Screen metrics, set by the panel

    /// Physical notch size on this screen, if it has one.
    var physicalNotch: CGSize?
    var menuBarHeight: CGFloat = 24
    /// Set by the panel. See `NSScreen.hasScreenAbove`.
    var topEdgeIsCrossing = false
    /// Whether the top of this display belongs to the system - a menu bar, a
    /// notch, or both. False on an external monitor with no menu bar of its own,
    /// where pixel zero is whatever window is up there.
    var ownsTopEdge = true
    var hasPhysicalNotch: Bool { physicalNotch != nil }

    /// Vertical space the expanded panel must leave clear so content never sits
    /// under the physical cutout.
    var notchInset: CGFloat { max(physicalNotch?.height ?? 0, 26) }

    /// Horizontal gap the header must leave for the physical cutout. The header
    /// runs either side of it, which is otherwise dead space.
    var notchGap: CGFloat { (physicalNotch?.width ?? 0) + 16 }

    private let settings = Settings.shared

    // MARK: - Sizing

    var collapsedSize: CGSize {
        CGSize(width: closedWidth, height: closedHeight)
    }

    private var closedHeight: CGFloat {
        if let notch = physicalNotch {
            switch settings.notchHeightMode {
            case .matchNotch: return notch.height
            case .matchMenuBar: return menuBarHeight
            case .custom: return settings.notchHeightCustom
            }
        }
        return settings.externalMatchMenuBar ? menuBarHeight : settings.externalHeight
    }

    private var closedWidth: CGFloat {
        if let notch = physicalNotch {
            return settings.notchWidthMode == .matchNotch ? notch.width : settings.notchWidthCustom
        }
        return settings.externalWidth
    }

    /// A live activity needs room for its animation and label, so the closed
    /// island grows for the moment one is showing - the same move the real
    /// Dynamic Island makes. Hover targeting is unaffected: that reads
    /// `collapsedSize`, not this.
    ///
    /// The cutout is added on top of that allowance, not taken out of it. The
    /// 132pt is what the glyph and the label need, and on a notched Mac the
    /// middle of the island is a hole - so leaving the two to share 132pt gave
    /// the label about 66pt of visible screen on the right while it asked for
    /// 91, and the rest of every long title ran under the bezel. Growing by the
    /// gap as well keeps the same usable width either side of the hole as a
    /// display without one, which is why external monitors never showed this.
    private var activeSize: CGSize {
        guard HUD.shared.current != nil else { return collapsedSize }
        let base = collapsedSize
        return CGSize(
            width: base.width + 132 + (hasPhysicalNotch ? notchGap : 0),
            height: max(base.height, 34)
        )
    }

    /// Height per tab, because the tabs do not hold the same amount.
    ///
    /// Home carries the stats strip; Tools carries a keep-awake card and
    /// fourteen tiles. Left at one height, Tools needed about 280pt in a 196pt
    /// panel and the overflow pushed the tab rail and the segment row clean off
    /// the top - so neither could be clicked, and the only way back to another
    /// tab was the hotkey. Content that does not fit is a layout bug, not a
    /// scroll bug.
    ///
    /// +30 was measured against twelve tiles and never revisited when two more
    /// were added: two extra tiles is a whole extra row, and at +30 that row sat
    /// below the panel where it could neither be seen nor pressed. The grid now
    /// reflows to seven columns, and the rest of this is the margin that keeps a
    /// receipt from having to overlap the last row.
    private var expandedHeight: Double {
        switch tab {
        // The lyric row under the player: 29pt and its 7pt gap.
        case .home: settings.openHeight + (settings.stats ? 44 : 0)
            + (NowPlaying.shared.hasTrack && Lyrics.shared.showing ? 36 : 0)
        case .tools: settings.openHeight + 64
        // Six app rows at 30pt each. Fewer and the list is a scroll bar with
        // two entries visible, which is a worse control than a longer panel.
        case .mixer: settings.openHeight + 50
        default: settings.openHeight
        }
    }

    var size: CGSize {
        switch mode {
        case .collapsed: activeSize
        case .expanded: CGSize(width: settings.openWidth, height: expandedHeight)
        }
    }

    /// The area that reacts to the pointer. Larger than what is drawn, so the
    /// island is reachable even when nothing is visible - and deliberately
    /// generous, because a target you cannot see needs a forgiving edge.
    /// The closed island itself, plus the configured slop - never the footprint
    /// of the island that opens.
    ///
    /// Earlier this spanned `openWidth`, the shape boring.notch uses. That made
    /// the target easy to hit and made it fire constantly: the band covered the
    /// whole top-centre of the screen, so crossing the area the *open* island
    /// would later occupy was enough to open it. Reaching for a menu near the
    /// middle of the menu bar opened the island on the way.
    ///
    /// Anchoring to the notch costs a little precision and buys back the thing
    /// that matters - the island opens when you go to the notch, and only then.
    /// `Behaviour ▸ Extra width` and `Extra depth` widen it if the default is
    /// too tight; depth matters more than width, because the notch is a hole
    /// with no pixels behind it and the pointer is invisible while over it.
    ///
    /// Depth depends on what is actually at the top of that display.
    ///
    /// With a menu bar or a notch, the top of the screen belongs to the system
    /// and a band as deep as the island costs nothing. The pad on top of that is
    /// for the notch alone: it is a hole with no pixels behind it, so the pointer
    /// is invisible while over it and the target has to spill into screen you can
    /// see.
    ///
    /// Without either - an external monitor with "Displays have separate Spaces"
    /// off - pixel zero is live app content. A browser's tab row starts there, so
    /// a band as deep as the island opened it every time the middle tab was
    /// clicked. There the target is the screen edge itself: you have to push the
    /// pointer into it, which clicking a tab never does.
    ///
    /// Unconditional, deliberately. An earlier version widened this back to the
    /// island whenever something was drawn to aim at, which sounds reasonable and
    /// silently undid the whole fix - a live microphone is enough to paint the
    /// idle island, so in practice the band was 24pt deep again and the tab row
    /// kept firing it.
    var hoverSize: CGSize {
        let depth = ownsTopEdge
            ? collapsedSize.height + (hasPhysicalNotch ? settings.hoverHeightPad : 0)
            : Self.edgeStripDepth
        return CGSize(width: collapsedSize.width + settings.hoverWidthPad * 2, height: depth)
    }

    /// The screen edge, and nothing more. This is the same gesture macOS itself
    /// requires to pull down an auto-hidden menu bar: push into the edge until
    /// the pointer stops. Anything deeper overlaps a tab row that starts at
    /// pixel zero, and no depth that can be clicked is small enough to separate
    /// them - which is why the click rule below carries the rest of the weight.
    private static let edgeStripDepth: CGFloat = 2

    /// Crossing to a display above should not open the island on the way past,
    /// so such a screen waits a little longer before opening.
    var effectiveHoverDelay: Double {
        topEdgeIsCrossing ? max(settings.hoverDelay, 0.25) : settings.hoverDelay
    }

    /// Whether anything is actually painted while collapsed.
    var idleVisible: Bool {
        switch settings.idleStyle {
        case .always: true
        // A peek is a deliberate momentary appearance, so it shows even when the
        // idle island is set to hidden - that is the whole point of it.
        //
        // A live microphone used to show through Hidden too, on the argument that
        // an indicator you cannot see is not an indicator. It is not ours to
        // override: macOS already puts its own orange dot in the menu bar, so the
        // warning exists either way, and ours sat there permanently for anyone
        // who keeps a mic open. Hidden now means hidden.
        case .hidden: HUD.shared.current != nil
        case .whenActive: HUD.shared.current != nil
            || AudioMonitor.shared.micActive
            || (NowPlaying.shared.hasTrack && NowPlaying.shared.playing)
        }
    }

    // MARK: - Shape

    var bottomRadius: CGFloat {
        guard mode == .expanded else { return closedCornerRadius }
        return 26
    }

    private var closedCornerRadius: CGFloat {
        guard settings.cornerScaling else { return 13 }
        // Scale with height so a taller island does not look like a slab.
        return max(8, min(20, closedHeight * 0.4))
    }

    var topRadius: CGFloat { hasPhysicalNotch ? 7 : 0 }

    /// True while content is swapping, so the view can blur across the change.
    private(set) var swapping = false
    private var swapWork: DispatchWorkItem?

    /// Set by the container view. Confirms the pointer is still in the strip.
    var pointerIsInHoverRect: (() -> Bool)?

    private var openWork: DispatchWorkItem?

    /// Set by a click inside the hover band, cleared when the pointer leaves it.
    ///
    /// Geometry alone cannot tell "aiming at the island" from "aiming at the tab
    /// underneath it" when both live at pixel zero - on a display with no menu
    /// bar the browser's tab row starts exactly where the island's target does,
    /// so every band deep enough to hit is also deep enough to misfire. What
    /// separates them is intent, and a click is the clearest statement of it
    /// there is: pressing the mouse says the pointer arrived for whatever is
    /// under it, not for us.
    private var hoverSuppressed = false

    /// Opens after `hoverDelay` so brushing past on the way to the menu bar does
    /// not trigger it. One-shot work item, cancelled on exit - never a repeating
    /// timer.
    func hoverBegan() {
        guard settings.openOnHover, mode == .collapsed, !hoverSuppressed else { return }
        // Idempotent: mouseMoved calls this repeatedly while the pointer sits on
        // the notch, and rescheduling on every move would push the deadline back
        // forever so it never fired.
        guard openWork == nil else { return }
        // Re-checked at fire time: a missed exit event would otherwise open the
        // island after the pointer had already left the strip.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            openWork = nil
            guard pointerIsInHoverRect?() ?? true else { return }
            open(byPointer: true)
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveHoverDelay, execute: work)
    }

    func hoverEnded() {
        openWork?.cancel()
        openWork = nil
        // Leaving the band is what re-arms it. Anything shorter - a timeout, the
        // mouse-up - re-opens under a pointer that never went anywhere, which is
        // the misfire again with extra steps.
        hoverSuppressed = false
        collapse()
    }

    /// A click landed inside the band. Drop any pending open and stay shut until
    /// the pointer leaves.
    func hoverPressed() {
        guard mode == .collapsed else { return }
        openWork?.cancel()
        openWork = nil
        hoverSuppressed = true
    }

    /// `requested` wins over the remembered tab. Assigning `tab` before calling
    /// this used to be overwritten by the restore below, so a dropped file or a
    /// clicked screenshot opened on whatever tab was last used, not the shelf.
    func open(byPointer: Bool = false, on requested: Tab? = nil) {
        guard mode != .expanded else {
            if let requested { tab = requested }
            return
        }
        if let requested {
            tab = requested
        } else if settings.rememberTab, let saved = Tab(rawValue: settings.lastTab) {
            tab = saved
        }
        openedByPointer = byPointer
        pointerEnteredSinceOpen = false
        beginSwap()
        if settings.haptics { Motion.tick() }
        withAnimation(Motion.morph) { mode = .expanded }
        Hotkeys.shared.setEscapeActive(true)
        // Sampling starts with the island and stops with it - a closed island
        // must never be paying for stats.
        SystemStats.shared.start()
        // Read here rather than from the row's `onAppear`: a row that renders
        // nothing until the value is known never appears, so its `onAppear`
        // never fires and it can never learn the value. The brightness keys can
        // also change it behind our back, so every open re-reads.
        Utilities.shared.readBrightness()
        // Same reason, one cable further out: a monitor's own buttons move its
        // brightness without telling anyone, so the sliders ask on every open
        // rather than being watched. Off the main thread - see `readLevels`.
        ExternalBrightness.shared.readLevels()
        // Same reason: the Trash fills up while the island is shut, and a tile
        // that disables itself on a stale count is a button that looks broken.
        Utilities.shared.refresh()
        // Here rather than in the sources strip's `onAppear`: the strip decides
        // whether to exist from this list, and a view cannot populate the list
        // it is deciding on - it drew nothing, then filled in a frame later.
        VolumeMixer.shared.refresh()
        // Accessory levels for the battery tooltip and Tools ▸ System.
        DeviceBatteries.shared.refresh()
        // A copy made without switching apps is picked up here instead.
        Clipboard.shared.capture()
        // At most once per half hour, and only because someone looked.
        Weather.shared.refreshIfStale()
        // A track whose artist arrived after its title was looked up without
        // one. Free when nothing changed - see `Lyrics.refresh`.
        Lyrics.shared.refresh()
    }

    func collapse() {
        guard mode != .collapsed else { return }
        beginSwap()
        // Exit uses the faster curve: the user has already left.
        settings.lastTab = tab.rawValue
        Hotkeys.shared.setEscapeActive(false)
        SystemStats.shared.stop()
        withAnimation(Motion.exit) {
            mode = .collapsed
            if !settings.rememberTab { tab = .home }
        }
    }

    /// Holds the cross-fade blur on for exactly as long as the swap takes.
    private func beginSwap() {
        swapWork?.cancel()
        swapping = true
        let work = DispatchWorkItem { [weak self] in
            withAnimation(Motion.content) { self?.swapping = false }
        }
        swapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }
}
