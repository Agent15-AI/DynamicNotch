import AppKit
import SwiftUI

/// One-press system actions.
///
/// A grid of plain tiles rather than a settings form: every one of these is a
/// single action with an immediate, visible result, so the control should be the
/// smallest thing that can carry a glyph and a name. Labels say what happens
/// ("Lock screen"), never what the thing is ("Security") - a specific label is
/// what makes a grid like this scannable instead of a puzzle.
struct ToolsTab: View {
    enum Mode: String, CaseIterable, Identifiable {
        case actions, system, convert, cleanup, updates, ports, brew
        var id: String { rawValue }
        var title: String {
            switch self {
            case .actions: "Actions"
            case .system: "System"
            case .convert: "Convert"
            case .cleanup: "Cleanup"
            case .updates: "Updates"
            case .ports: "Ports"
            case .brew: "Brew"
            }
        }
    }

    @State private var mode: Mode = Mode(rawValue: Settings.shared.toolsMode) ?? .actions
    @Namespace private var indicator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Mode.allCases) { item in
                    Segment(title: item.title, selected: mode == item, indicator: indicator) {
                        withAnimation(Motion.content) { mode = item }
                        Settings.shared.toolsMode = item.rawValue
                    }
                }
            }
            .staggered(0)

            switch mode {
            case .actions: ActionsSection()
            case .system: SystemSection()
            case .convert: ConvertSection()
            case .cleanup: CleanupSection()
            case .updates: UpdatesSection()
            case .ports: PortsSection()
            case .brew: BrewSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ActionsSection: View {
    var utilities = Utilities.shared
    var menuBar = MenuBarHider.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            KeepAwakeCard().staggered(0)

            Rectangle()
                .fill(Theme.edge)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("QUICK ACTIONS").sectionLabel()
                // Adaptive rather than a fixed six across. Fourteen tiles in six
                // columns is three rows, and the third row did not fit: measured
                // 227pt of content in the 181pt the panel leaves below its
                // header. `clipped()` hid the overflow, which was the smaller
                // half of the problem - the container hit-tests against the
                // panel rect, so a press on that row landed on nothing, and the
                // pointer travelling there left the island and closed it.
                // Reaching for Empty Trash shut the notch instead.
                //
                // ponytail: the grid already knows how to pick a column count.
                // At the default 640pt panel this settles on seven, so the same
                // fourteen tiles are two rows, and adding one later reflows
                // rather than falling off the bottom.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 4)], spacing: 4) {
                    ToolTile(
                        symbol: utilities.micMuted ? "mic.slash.fill" : "mic.fill",
                        title: utilities.micMuted ? "Unmute mic" : "Mute mic",
                        tinted: utilities.micMuted
                    ) { utilities.toggleMicMute() }

                    ToolTile(symbol: "lock.fill", title: "Lock screen") {
                        utilities.lockScreen()
                    }

                    ToolTile(symbol: "moon.fill", title: "Sleep display") {
                        utilities.sleepDisplays()
                    }

                    // A disabled control has to say why it is disabled, or it
                    // reads as broken. "No disks" is the reason, in the one
                    // place the eye is already looking.
                    ToolTile(
                        symbol: "eject.fill",
                        title: utilities.ejectableVolumes.isEmpty ? "No disks" : "Eject disks",
                        disabled: utilities.ejectableVolumes.isEmpty,
                        help: utilities.ejectableVolumes.isEmpty
                            ? "Nothing removable is mounted"
                            : "Eject \(utilities.ejectableVolumes.count) removable disk(s)"
                    ) { utilities.ejectAll() }

                    ToolTile(
                        symbol: utilities.hiddenFilesShown ? "eye.slash.fill" : "eye.fill",
                        title: utilities.hiddenFilesShown ? "Hide hidden" : "Show hidden",
                        tinted: utilities.hiddenFilesShown
                    ) { utilities.toggleHiddenFiles() }

                    ToolTile(
                        symbol: utilities.desktopIconsShown ? "menubar.dock.rectangle" : "rectangle.dashed",
                        title: utilities.desktopIconsShown ? "Hide desktop" : "Show desktop",
                        tinted: !utilities.desktopIconsShown
                    ) { utilities.toggleDesktopIcons() }

                    // Tinted while collapsed, like the other stateful tiles -
                    // with the icons gone the menu bar itself gives no clue
                    // whether anything is hidden or the bar is simply empty.
                    ToolTile(
                        symbol: menuBar.collapsed ? "menubar.arrow.down.rectangle" : "menubar.arrow.up.rectangle",
                        title: menuBar.collapsed ? "Show icons" : "Hide icons",
                        tinted: menuBar.collapsed,
                        disabled: !Settings.shared.menuBar,
                        help: Settings.shared.menuBar
                            ? "Hide the menu bar icons you picked in Settings (⌘⌃B)"
                            : "Turn menu bar hiding on in Settings → Menu Bar"
                    ) { menuBar.toggle() }

                    ToolTile(symbol: "link", title: "Clean link") {
                        utilities.cleanClipboardURL()
                    }

                    // The tile and ⌃⌘V are the same action. The tile is here
                    // because the shortcut is not discoverable, and because the
                    // island is often already open when you notice the formatting.
                    ToolTile(
                        symbol: "textformat",
                        title: "Paste plain",
                        disabled: !Settings.shared.plainPaste,
                        help: Settings.shared.plainPaste
                            ? "Paste the clipboard without its formatting (⌃⌘V)"
                            : "Turn plain-text paste on in Settings → Modules"
                    ) { utilities.pastePlainText() }

                    ToolTile(symbol: "eyedropper", title: "Pick colour") {
                        utilities.pickColour()
                    }

                    ToolTile(symbol: "circle.lefthalf.filled", title: "Dark mode") {
                        utilities.toggleDarkMode()
                    }

                    ToolTile(
                        symbol: "text.viewfinder",
                        title: ScreenOCR.shared.running ? "Reading…" : "Copy text",
                        disabled: !ScreenOCR.shared.available
                    ) { ScreenOCR.shared.capture() }

                    ToolTile(symbol: "arrow.clockwise", title: "Restart Finder") {
                        utilities.restartFinder()
                    }

                    ToolTile(symbol: "wifi", title: "Copy IP") {
                        utilities.copyLocalIP()
                    }

                    ToolTile(
                        symbol: "equal.square",
                        title: "Calculator",
                        help: Settings.shared.calculator
                            ? "Scientific calculator - or double-tap the right ⌥"
                            : "Scientific calculator - the double-tap is off in Settings"
                    ) { CalculatorWindow.shared.show() }


                    ToolTile(symbol: "video.fill", title: "Mirror") {
                        CameraPreview.shared.toggle()
                    }

                    // Tinted while it is running, and the tooltip carries the one
                    // number worth knowing: how long until it interrupts you.
                    ToolTile(
                        symbol: Settings.shared.eyeBreak ? "eye.fill" : "eye",
                        title: Settings.shared.eyeBreak ? "Eye break on" : "Eye break",
                        tinted: Settings.shared.eyeBreak,
                        help: Settings.shared.eyeBreak
                            ? EyeBreak.shared.untilNext.map { "Next look-away in \($0)" }
                                ?? "Every \(Int(Settings.shared.eyeBreakMinutes)) minutes"
                            : "Remind me to look away every \(Int(Settings.shared.eyeBreakMinutes)) minutes"
                    ) { Settings.shared.eyeBreak.toggle() }

                    // Disabled only on a count we actually took. nil is "could
                    // not read the Trash", and that is not the same answer as
                    // "the Trash is empty" - treating it as one is what left
                    // this permanently greyed out.
                    ToolTile(
                        symbol: "trash.fill",
                        title: utilities.trashArmed ? "Tap to confirm"
                            : utilities.trashCount == 0 ? "Trash empty" : "Empty Trash",
                        tinted: utilities.trashArmed,
                        disabled: utilities.trashCount == 0,
                        help: utilities.trashArmed
                            ? "Press again to empty the Trash - this cannot be undone"
                            : utilities.trashCount.map { $0 == 0 ? "Nothing in the Trash" : "\($0) items" }
                                ?? "Empty the Trash"
                    ) { utilities.emptyTrash() }
                }
                .staggered(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Keep the Mac from idling to sleep, for a while or until told otherwise.
///
/// One full-width row: state on the left, the lengths on the right. Presets and
/// no picker, the same call the timer makes - the answer is almost always one of
/// a handful of durations.
///
/// The remaining time is derived from an end date, so nothing counts while this
/// runs. The only thing alive is a power assertion the system holds.
private struct KeepAwakeCard: View {
    var utilities = Utilities.shared

    private static let presets: [(String, Int?)] = [
        ("15m", 15), ("30m", 30), ("1h", 60), ("2h", 120), ("4h", 240), ("∞", nil),
    ]

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: utilities.keepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 16))
                .foregroundStyle(utilities.keepingAwake ? Theme.gold : Theme.tertiary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: -1) {
                Text(utilities.keepingAwake ? "Staying awake" : "Sleeps normally")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Group {
                    if utilities.keepingAwake, utilities.awakeUntil != nil {
                        // A live clock only while there is something to count,
                        // and only while the island is open to see it.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(utilities.awakeRemaining ?? "")
                                .monospacedDigit()
                        }
                    } else if let condition = utilities.condition {
                        Text(condition.title)
                    } else if utilities.keepingAwake {
                        Text("Until you stop it")
                    } else {
                        Text("Pick how long")
                    }
                }
                .font(TypeScale.caption)
                .foregroundStyle(utilities.keepingAwake ? Theme.secondary : Theme.tertiary)
            }
            .frame(width: 118, alignment: .leading)

            Spacer(minLength: 0)

            if utilities.keepingAwake {
                DurationChip(label: "Stop", prominent: true) { utilities.stopKeepingAwake() }
                    .frame(width: 74)
            } else {
                HStack(spacing: 5) {
                    ForEach(Self.presets, id: \.0) { label, minutes in
                        DurationChip(label: label) { utilities.keepAwake(minutes: minutes) }
                            .frame(width: 46)
                    }
                    // Conditions rather than clocks: hold until the cable comes
                    // out, or until the external display goes away.
                    // Symbols, not characters: 🖵 has no glyph in the system
                    // fonts and drew as a boxed question mark.
                    ForEach(Utilities.Condition.allCases) { condition in
                        DurationChip(label: condition.title,
                                     symbol: condition == .whilePluggedIn ? "bolt.fill" : "display") {
                            utilities.keepAwake(while: condition)
                        }
                        .frame(width: 40)
                        .help(condition.title)
                    }
                }
            }
        }
        .animation(Motion.content, value: utilities.keepingAwake)
    }
}

private struct DurationChip: View {
    var label: String
    /// Drawn instead of the label when set; the label becomes its spoken name.
    var symbol: String?
    var prominent = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).accessibilityLabel(label)
                } else {
                    Text(label)
                }
            }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(fill == .clear ? Theme.secondary : Theme.notchBlack)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill == .clear ? Color.white.opacity(0.07) : fill)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(Pressable())
        .hoverHighlight($hovering)
    }

    /// Stop is the destructive-ish one, so it wears the accent rather than the
    /// gold every other chip uses on hover.
    private var fill: Color {
        if prominent { return Theme.core }
        return hovering ? Theme.gold : .clear
    }
}

/// Icon over a name. The whole tile is the target, not the glyph inside it -
/// contiguous hit areas are what stop a grid of small controls feeling fiddly.
private struct ToolTile: View {
    var symbol: String
    var title: String
    var tinted = false
    var disabled = false
    /// What the tile does, or why it cannot. Defaults to the label, which is
    /// what it said before there was anything more specific to say.
    var help: String?
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(height: 17)
                Text(title)
                    .font(.system(size: 8.5))
                    .foregroundStyle(disabled ? Theme.tertiary : Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering && !disabled ? Color.white.opacity(0.07) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(Pressable())
        .hoverHighlight($hovering)
        .disabled(disabled)
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityHint(help ?? "")
    }

    private var tint: Color {
        if disabled { return Theme.tertiary.opacity(0.5) }
        return tinted ? Theme.gold : Theme.primary
    }
}

// MARK: - Cleanup

/// Uninstall an app with its leftovers, and sweep caches and logs.
///
/// Uninstall moves things to the Trash; the sweep deletes. Each says which on
/// its own button. That
/// sentence is the feature: an uninstaller you have to trust is a worse product
/// than one whose mistakes you can drag back out.
private struct CleanupSection: View {
    var cleanup = Cleanup.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            uninstaller.frame(width: 232)

            Rectangle()
                .fill(Theme.edge)
                .frame(width: 1)
                .padding(.vertical, 2)

            caches.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var uninstaller: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("UNINSTALL").sectionLabel()
                Spacer(minLength: 0)
                if cleanup.target != nil {
                    TextAction("Clear", tint: Theme.tertiary) { cleanup.clearTarget() }
                }
            }

            if cleanup.target == nil {
                // ponytail: the system's own open panel. Dropping onto the
                // island is already the shelf's gesture, and overloading it by
                // which tab happens to be showing would be a trap.
                EmptyState(symbol: "trash.square",
                           title: "Uninstall an app",
                           detail: "Takes its leftovers with it",
                           actionTitle: "Choose app…",
                           action: choose)
            } else {
                Text(cleanup.targetName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)

                if cleanup.scanning {
                    Text("Looking for leftovers…")
                        .font(TypeScale.caption)
                        .foregroundStyle(Theme.tertiary)
                } else {
                    Text(cleanup.leftovers.isEmpty
                         ? "No leftovers found"
                         : "\(cleanup.leftovers.count) leftovers · "
                           + ByteCountFormatter.string(fromByteCount: cleanup.leftoverBytes, countStyle: .file))
                        .font(TypeScale.caption)
                        .foregroundStyle(Theme.secondary)

                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(cleanup.leftovers) { item in
                                HStack(spacing: 6) {
                                    Text(item.label)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(Theme.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    Text(item.size)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(Theme.tertiary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)

                    TextAction("Move all to Trash", tint: Theme.core) { cleanup.uninstall() }
                }
            }
        }
    }

    @ViewBuilder
    private var caches: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("CACHES AND LOGS").sectionLabel()
                Spacer(minLength: 0)
                if !cleanup.junk.isEmpty {
                    // Says what it does, and how much of it. This half does not
                    // go to the Trash, so it arms before it acts - the same two
                    // presses the Empty Trash tile asks for, because it is the
                    // same irreversible gesture.
                    TextAction(
                        cleanup.cleaning
                            ? "Deleting…"
                            : cleanup.armed
                                ? "Delete permanently?"
                                : "Free " + ByteCountFormatter.string(
                                    fromByteCount: cleanup.selectedBytes, countStyle: .file
                                ),
                        tint: cleanup.cleaning || cleanup.selectedBytes == 0
                            ? Theme.tertiary : Theme.core
                    ) {
                        guard !cleanup.cleaning, cleanup.selectedBytes > 0 else { return }
                        cleanup.armOrClean()
                    }
                }
            }
            .animation(Motion.content, value: cleanup.armed)
            .animation(Motion.content, value: cleanup.cleaning)

            if cleanup.junk.isEmpty {
                EmptyState(symbol: "sparkles",
                           title: cleanup.sweeping ? "Measuring" : "Free up space",
                           detail: cleanup.sweeping
                               ? "Walking the folders"
                               : "Sizes caches and logs under your Library",
                           actionTitle: "Scan",
                           busy: cleanup.sweeping) { cleanup.sweep() }
            } else {
                HStack(spacing: 6) {
                    // Still counting is worth saying out loud. The list fills in
                    // as folders are sized, so a total that keeps climbing looks
                    // like a bug unless the row admits it is not finished.
                    Text(cleanup.sweeping
                         ? "Measuring · \(cleanup.junk.count) so far"
                         : ByteCountFormatter.string(
                            fromByteCount: cleanup.selectedBytes, countStyle: .file
                         ) + " of \(cleanup.junk.count) folders")
                        .font(TypeScale.caption)
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    if !cleanup.sweeping {
                        let all = cleanup.selected.count == cleanup.junk.count
                        TextAction(all ? "None" : "All", tint: Theme.tertiary) {
                            cleanup.selectAll(!all)
                        }
                    }
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(cleanup.junk) { item in
                            JunkRow(item: item, on: cleanup.selected.contains(item.id)) {
                                cleanup.toggle(item)
                            }
                        }
                    }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        // The app is an accessory and the island never activates it, so without
        // this the open panel opens behind whatever is frontmost - the button
        // looked like it did nothing at all.
        NSApp.activate(ignoringOtherApps: true)
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Inspect"
        // The island floats above everything, so an expanded one sits on top of
        // the open panel - which is what the overlap looked like. Out of the way
        // first, then back afterwards with the result showing.
        PanelManager.shared.collapseAll()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Cleanup.shared.inspect(url)
            PanelManager.shared.focusIsland(tab: .tools)
        }
    }
}

/// One cache folder, and whether it is going.
///
/// The whole row toggles, not a 12pt checkbox - the tick is an indicator, the
/// row is the target. A deselected row stays legible rather than greying out to
/// nothing: it is still information about what is on the disk, it is just not
/// being deleted.
private struct JunkRow: View {
    var item: Cleanup.Item
    var on: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9))
                    .foregroundStyle(on ? Theme.core : Theme.tertiary)
                Text(item.label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(on ? Theme.secondary : Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(item.size)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(on ? Theme.primary : Theme.tertiary)
            }
            .padding(.vertical, 1.5)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.06) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(Pressable(scale: 0.99))
        .hoverHighlight($hovering)
        .help(item.contentsOnly ? "Emptied, the folder itself stays" : item.url.path)
        .accessibilityLabel("\(item.label), \(item.size)")
        .accessibilityValue(on ? "Selected" : "Not selected")
    }
}

// MARK: - Updates

private struct UpdatesSection: View {
    var updates = Updates.shared
    @State private var term = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Search doubles as the package manager: type to find something to
            // install, leave it empty to see what is outdated.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                TextField("Search Homebrew", text: $term)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.primary)
                    .onSubmit { updates.search(term) }
                if !term.isEmpty {
                    TextAction("Clear", tint: Theme.tertiary) {
                        term = ""
                        updates.clearSearch()
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .staggered(0)

            if !updates.results.isEmpty || updates.searching {
                packages
            } else {
                outdated
            }
        }
    }

    private var packages: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 3) {
                ForEach(updates.results) { package in
                    PackageRow(package: package, working: updates.working == package.name)
                }
            }
        }
    }

    private var outdated: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("OUTDATED").sectionLabel()
                if let checked = updates.lastChecked, !updates.checking {
                    Text(checked.formatted(date: .omitted, time: .shortened))
                        .font(TypeScale.caption)
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 0)
                if !updates.items.isEmpty {
                    TextAction(updates.checking ? "Checking…" : "Check again", tint: Theme.gold) {
                        updates.check()
                    }
                }
            }
            .staggered(0)

            if updates.items.isEmpty {
                EmptyState(
                    symbol: updates.brewAvailable ? "shippingbox" : "exclamationmark.triangle",
                    title: updates.message ?? (updates.checking ? "Asking Homebrew" : "Check for updates"),
                    detail: updates.brewAvailable
                        ? "Homebrew and the App Store, only when you ask"
                        : "Install Homebrew to use this",
                    actionTitle: updates.brewAvailable ? "Check now" : nil,
                    busy: updates.checking,
                    action: updates.brewAvailable ? { updates.check() } : nil
                )
                .staggered(1)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(Array(updates.items.enumerated()), id: \.element.id) { index, item in
                            UpdateRow(item: item, working: updates.working == item.name)
                                .staggered(min(index + 1, 6))
                        }
                    }
                }
            }
        }
    }
}

private struct PackageRow: View {
    var package: Updates.Package
    var working: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: package.cask ? "app.fill" : "shippingbox.fill")
                .font(.system(size: 10))
                .foregroundStyle(package.installed ? Theme.gold : Theme.tertiary)
                .frame(width: 14)

            Text(package.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)

            Text(package.cask ? "cask" : "formula")
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)

            Spacer(minLength: 0)

            TextAction(
                working ? "Working…" : (package.installed ? "Remove" : "Install"),
                tint: working ? Theme.tertiary : (package.installed ? Theme.core : Theme.gold)
            ) {
                Updates.shared.toggleInstall(package)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.05) : .clear)
        )
        .hoverHighlight($hovering)
    }
}

private struct UpdateRow: View {
    var item: Updates.Item
    var working: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 10))
                .foregroundStyle(Theme.gold)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: -1) {
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(item.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            TextAction(working ? "Updating…" : "Update", tint: working ? Theme.tertiary : Theme.core) {
                Updates.shared.upgrade(item)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.05) : .clear)
        )
        .hoverHighlight($hovering)
    }
}


// MARK: - System

/// The detailed monitor: everything the home tab's six tiles cannot fit.
///
/// Sampled by `SystemStats`, which runs only while the island is open, plus
/// battery figures that IOKit pushes to us. The speed test is the one thing here
/// that touches the network, and only when pressed.
private struct SystemSection: View {
    var stats = SystemStats.shared
    var sensors = Sensors.shared
    var battery = Battery.shared
    var speed = SpeedTest.shared
    var devices = DeviceBatteries.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("MEMORY AND POWER").sectionLabel()
                Row(label: "RAM", value: stats.memoryUsed, fraction: stats.memory)
                Row(label: "Swap", value: stats.swapUsed.isEmpty ? "None" : stats.swapUsed,
                    fraction: stats.swap)
                Row(label: "Temperature", value: sensors.text, fraction: sensors.fraction)
                // Red when it is low, not when it is full - the pressure colour
                // the other rows use painted an 89% battery as a warning.
                Row(label: "Battery", value: "\(battery.percent)%",
                    fraction: Double(battery.percent) / 100, warn: battery.lowPower)
                if let watts = battery.watts {
                    Detail(label: battery.pluggedIn ? "Charging at" : "Drawing",
                           value: String(format: "%.1f W", watts))
                }
                if let health = battery.health, let cycles = battery.cycleCount {
                    Detail(label: "Health", value: "\(health)% · \(cycles) cycles")
                }
                if let remaining = battery.remainingText {
                    Detail(label: "Remaining", value: remaining)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 244)

            Rectangle()
                .fill(Theme.edge)
                .frame(width: 1)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("NETWORK").sectionLabel()
                    Spacer(minLength: 0)
                    TextAction(speed.running ? "Testing…" : "Speed test", tint: Theme.gold) {
                        speed.run()
                    }
                }
                Detail(label: "Down", value: SystemStats.rate(stats.down))
                Detail(label: "Up", value: SystemStats.rate(stats.up))
                Detail(label: "Since boot",
                       value: ByteCountFormatter.string(fromByteCount: Int64(stats.downTotal), countStyle: .file)
                           + " in · "
                           + ByteCountFormatter.string(fromByteCount: Int64(stats.upTotal), countStyle: .file)
                           + " out")
                Detail(label: "Speed", value: speed.text)
                if !devices.devices.isEmpty {
                    Text("DEVICES").sectionLabel().padding(.top, 4)
                    ForEach(devices.devices.prefix(3)) { device in
                        Detail(label: device.name, value: device.detail ?? "\(device.percent)%")
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // With the home tab's stats switched off nothing else starts the sampler,
        // and RAM, swap and the network rates sat at zero.
        .onAppear { stats.start(always: true) }
    }

    /// Label, meter, value - the stat tile's grammar turned on its side, because
    /// a column of these reads better than a row when there is room for words.
    private struct Row: View {
        var label: String
        var value: String
        var fraction: Double
        /// When the meter turns red. Defaults to "nearly full", which is what
        /// pressure means for memory, swap and heat.
        var warn: Bool?

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    Text(value)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule()
                            .fill(warn ?? (fraction >= 0.85) ? Theme.core : Theme.gold)
                            .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private struct Detail: View {
        var label: String
        var value: String

        var body: some View {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiary)
                Spacer(minLength: 0)
                Text(value)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }
}

/// What is listening on a port, and a button to stop it.
///
/// The answer to "address already in use" without a terminal. Nothing is read
/// until Refresh is pressed - see `Ports`.
private struct PortsSection: View {
    var ports = Ports.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ports.listeners.isEmpty {
                EmptyState(
                    symbol: "app.connected.to.app.below.fill",
                    title: ports.scanning ? "Looking…" : "Nothing listening yet",
                    detail: "Find what is holding a port, and stop it",
                    actionTitle: ports.scanning ? nil : "Look for listeners",
                    busy: ports.scanning
                ) { ports.refresh() }
                    .staggered(0)
            } else {
                HStack {
                    Text("LISTENING").sectionLabel()
                    Spacer()
                    TextAction("Refresh", tint: Theme.tertiary) { ports.refresh() }
                }
                .staggered(0)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(Array(ports.listeners.enumerated()), id: \.element.id) { index, listener in
                            PortRow(listener: listener).staggered(min(index, 6) + 1)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PortRow: View {
    var listener: Ports.Listener
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Text("\(listener.port)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.core)
                .frame(width: 46, alignment: .leading)

            if let path = listener.bundlePath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable().frame(width: 13, height: 13)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 13)
            }

            Text(listener.name)
                .font(.system(size: 11))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)

            Spacer(minLength: 6)

            if hovering {
                TextAction("Stop", tint: Theme.core) { Ports.shared.stop(listener) }
            } else {
                Text("pid \(listener.pid)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0.035))
        )
        .contentShape(Rectangle())
        .hoverHighlight($hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(listener.name) on port \(listener.port)")
    }
}

/// Homebrew, without a terminal. On demand only - see `Homebrew`.
private struct BrewSection: View {
    var brew = Homebrew.shared
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !brew.available, brew.path != nil {
                EmptyState(symbol: "shippingbox",
                           title: "Homebrew is not installed",
                           detail: "Looked in /opt/homebrew and /usr/local")
                    .staggered(0)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                    TextField("Search formulae and casks", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.primary)
                        .onSubmit { brew.search(query) }
                    if brew.searching {
                        ProgressView().controlSize(.mini)
                    } else if !query.isEmpty {
                        TextAction("Search", tint: Theme.core) { brew.search(query) }
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .staggered(0)
                .onAppear { brew.locate() }

                if brew.results.isEmpty {
                    Text(query.isEmpty
                         ? "Type a name and press Return."
                         : (brew.searching ? "Searching…" : "Nothing found."))
                        .font(TypeScale.caption)
                        .foregroundStyle(Theme.tertiary)
                        .staggered(1)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 3) {
                            ForEach(Array(brew.results.enumerated()), id: \.element.id) { index, package in
                                BrewRow(package: package).staggered(min(index, 6) + 1)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BrewRow: View {
    var package: Homebrew.Package
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: package.cask ? "macwindow" : "terminal")
                .font(.system(size: 10))
                .foregroundStyle(package.installed ? Theme.gold : Theme.tertiary)
                .frame(width: 14)

            Text(package.name)
                .font(.system(size: 11))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)

            if package.installed {
                Text("installed")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Theme.gold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Theme.gold.opacity(0.15)))
            }

            Spacer(minLength: 6)

            if Homebrew.shared.busy == package.name {
                ProgressView().controlSize(.mini)
            } else if hovering, Homebrew.shared.busy == nil {
                TextAction(package.installed ? "Remove" : "Install",
                           tint: package.installed ? Theme.core : Theme.gold) {
                    package.installed ? Homebrew.shared.remove(package) : Homebrew.shared.install(package)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0.035))
        )
        .contentShape(Rectangle())
        .hoverHighlight($hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(package.name)\(package.installed ? ", installed" : "")")
    }
}
