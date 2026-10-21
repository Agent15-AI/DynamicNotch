import CoreAudio
import SwiftUI

struct ExpandedView: View {
    @Bindable var state: NotchState
    var morph: Namespace.ID
    var receipt: HUD.Kind?

    var body: some View {
        VStack(spacing: 0) {
            Header(state: state)
                .frame(height: state.notchInset)

            Group {
                switch state.tab {
                case .home: HomeTab(state: state, morph: morph)
                case .shelf: ShelfTab(state: state)
                case .clock: ClockTab()
                case .tools: ToolsTab()
                case .notes: NotesTab()
                case .mixer: MixerTab()
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Belt and braces after the Tools overflow: a tab whose content is
            // taller than the panel must be cut off at the bottom, never allowed
            // to grow upward over the header and swallow its clicks.
            .clipped()
        }
        .overlay(alignment: .bottom) { Receipt(current: receipt) }
    }
}

// MARK: - Receipt

/// What the last one-press action did, shown where the press happened.
///
/// The live activities only render in the *closed* island, so every receipt a
/// Tools tile posted went into a view that was not on screen. Press "Copy IP"
/// with the island open and precisely nothing appears - which is what a dead
/// button looks like, and is why most of the grid was reported as not working
/// when the actions had in fact run. Same `HUD` state, drawn here as well.
///
/// Only the kinds a person triggers from inside the panel. A download or a
/// track change is news from elsewhere and belongs to the closed island, where
/// it is not covering the thing being used.
///
/// Takes the value rather than reading `HUD.shared` itself. See `NotchView` for
/// why - the read has to happen up there to be observed at all.
private struct Receipt: View {
    var current: HUD.Kind?

    var body: some View {
        Group {
            if let message {
                HStack(spacing: 7) {
                    // The glyph springs in, which is what actually catches the
                    // eye - the pointer is still down on the tile below.
                    UtilityActivity(symbol: message.symbol, size: 15)
                    Text(message.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text(message.detail)
                        .font(TypeScale.caption)
                        .foregroundStyle(Theme.tertiary)
                }
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    // Solid, not another translucent layer: the panel behind it
                    // is already `.ultraThinMaterial`, and glass on glass stops
                    // being readable.
                    Capsule().fill(Theme.shell)
                        .overlay(Capsule().stroke(Theme.edgeHighlight, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
                )
                // Enters and leaves along the same edge - a receipt that slid up
                // and then faded in place reads as two different objects.
                .transition(
                    Motion.reduced
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
            }
        }
        .padding(.bottom, 7)
        // Critically damped: nothing was thrown, so nothing should overshoot.
        .animation(Motion.content, value: current)
        // Never a target. It sits over the control that was just pressed, and
        // the pointer is still there.
        .allowsHitTesting(false)
    }

    private var message: (symbol: String, title: String, detail: String)? {
        switch current {
        case .utility(let symbol, let title, let detail): (symbol, title, detail)
        case .color(let hex, _): ("eyedropper", hex, "Copied")
        default: nil
        }
    }
}

// MARK: - Header

/// Runs either side of the physical cutout. That strip is otherwise dead space,
/// and putting the tabs and status there is what lets the body use its full
/// height for content.
private struct Header: View {
    @Bindable var state: NotchState
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Array(NotchState.Tab.allCases.enumerated()), id: \.element.id) { index, tab in
                    TabPill(tab: tab, selected: state.tab == tab, indicator: indicator) {
                        withAnimation(Motion.content) { state.tab = tab }
                    }
                    .staggered(index)
                }
            }
            // Seven tabs and a status cluster either side of the cutout is a
            // tight fit; the rail is what must not compress.
            .layoutPriority(1)

            Spacer(minLength: state.notchGap)

            StatusCluster().staggered(1)
        }
        .padding(.horizontal, 12)
    }
}

private struct TabPill: View {
    var tab: NotchState.Tab
    var selected: Bool
    var indicator: Namespace.ID
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Theme.primary : Theme.tertiary)
                .frame(width: 27, height: 20)
                .background {
                    if selected {
                        // One capsule that slides between tabs, rather than two
                        // that fade - the selection reads as a moving object.
                        Capsule().fill(Color.white.opacity(0.13))
                            .matchedGeometryEffect(id: "tab", in: indicator)
                    } else if hovering {
                        Capsule().fill(Color.white.opacity(0.06))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .hoverHighlight($hovering)
        .help(tab.title)
        .accessibilityLabel(tab.title)
    }
}

private struct StatusCluster: View {
    var battery = Battery.shared
    var countdown = CountdownTimer.shared
    var audio = AudioMonitor.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if audio.micActive { MicIndicator(size: 9) }

            if countdown.running || countdown.paused {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(countdown.text)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(countdown.paused ? Theme.tertiary : Theme.core)
                        .monospacedDigit()
                }
                .help("Timer")
            }

            HStack(spacing: 4) {
                Text("\(battery.percent)%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(battery.lowPower ? Theme.core : Theme.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                BatteryGauge(
                    percent: battery.percent,
                    charging: battery.pluggedIn,
                    low: battery.lowPower,
                    width: 22
                )
            }
            .help(batteryHelp)

            OutputButton()
            SamplerButton()

            Button { SettingsWindow.shared.show() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(hovering ? Theme.primary : Theme.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
            .hoverHighlight($hovering)
            .help("Settings")
        }
    }
}

extension StatusCluster {
    /// The Mac first, then every accessory that reports a level - the one
    /// place all the batteries you own are listed together.
    fileprivate var batteryHelp: String {
        var lines = ["Mac \(battery.percent)% · " + (battery.remainingText ?? (battery.pluggedIn ? "Charging" : "On battery"))]
        lines += DeviceBatteries.shared.devices.map { "\($0.name) \($0.detail ?? "\($0.percent)%")" }
        return lines.joined(separator: "\n")
    }
}

/// Picks a colour from anywhere on screen and copies the hex.
///
/// ponytail: `NSColorSampler` is the system's own loupe - the magnifier, the
/// pixel grid, the escape-to-cancel and the multi-display handling are all
/// already written. This is the whole feature.
private struct SamplerButton: View {
    @State private var hovering = false

    var body: some View {
        Button(action: sample) {
            Image(systemName: "eyedropper")
                .font(.system(size: 10))
                .foregroundStyle(hovering ? Theme.primary : Theme.tertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .hoverHighlight($hovering)
        .help("Pick a colour")
    }

    private func sample() {
        Utilities.shared.pickColour()
    }
}

private struct OutputButton: View {
    var audio = AudioMonitor.shared
    @State private var hovering = false

    var body: some View {
        Button(action: present) {
            Image(systemName: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(hovering ? Theme.primary : Theme.tertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .hoverHighlight($hovering)
        .help("Audio output and microphone")
    }

    private func present() {
        let menu = NSMenu()
        let current = audio.currentOutput
        let multi = MultiOutput.shared
        // AirPlay receivers last, under their own heading. They are ordinary
        // CoreAudio devices once macOS knows about them, so the only thing that
        // was missing is being able to tell which is which.
        let outputs = audio.outputs.filter { !$0.isAirPlay } + audio.outputs.filter(\.isAirPlay)
        var headed = false
        for output in outputs {
            if output.isAirPlay, !headed {
                headed = true
                menu.addItem(.separator())
                menu.addItem(NSMenuItem.sectionHeader(title: "AirPlay"))
            }
            let item = NSMenuItem(title: output.name, action: nil, keyEquivalent: "")
            item.state = output.id == current ? .on : .off
            item.image = NSImage(systemSymbolName: output.symbol, accessibilityDescription: nil)
            item.representedObject = output.id
            item.target = OutputMenuTarget.shared
            item.action = #selector(OutputMenuTarget.pick(_:))
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "No output devices", action: nil, keyEquivalent: ""))
        }

        // Several at once, as a checklist. A submenu rather than more rows in the
        // list above: ticking a device here means "play to this as well", which is
        // a different question from "play to this instead", and the two read as
        // one confusing list when they share a level.
        if outputs.count > 1 {
            menu.addItem(.separator())
            let several = NSMenuItem(title: multi.active ? "Playing to several" : "Play to several…",
                                     action: nil, keyEquivalent: "")
            several.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
            let submenu = NSMenu()
            for output in outputs {
                let item = NSMenuItem(title: output.name,
                                      action: #selector(OutputMenuTarget.toggleMulti(_:)),
                                      keyEquivalent: "")
                item.state = multi.contains(output) ? .on : .off
                item.image = NSImage(systemSymbolName: output.symbol, accessibilityDescription: nil)
                item.representedObject = output
                item.target = OutputMenuTarget.shared
                submenu.addItem(item)
            }
            if multi.active {
                submenu.addItem(.separator())
                let stop = NSMenuItem(title: "Stop", action: #selector(OutputMenuTarget.stopMulti(_:)),
                                      keyEquivalent: "")
                stop.target = OutputMenuTarget.shared
                submenu.addItem(stop)
            }
            several.submenu = submenu
            menu.addItem(several)
        }

        let inputs = audio.inputs
        if !inputs.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Microphone"))
            let currentInput = audio.currentInput
            for input in inputs {
                let item = NSMenuItem(title: input.name, action: #selector(OutputMenuTarget.pickInput(_:)), keyEquivalent: "")
                item.state = input.id == currentInput ? .on : .off
                item.representedObject = input.id
                item.target = OutputMenuTarget.shared
                menu.addItem(item)
            }
        }
        // Screen coordinates: the panel is not key, so there is no reliable view
        // to anchor to.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

@MainActor
private final class OutputMenuTarget: NSObject {
    static let shared = OutputMenuTarget()

    @objc func pick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else { return }
        AudioMonitor.shared.selectOutput(id)
    }

    @objc func pickInput(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else { return }
        AudioMonitor.shared.selectInput(id)
    }

    @objc func toggleMulti(_ sender: NSMenuItem) {
        guard let output = sender.representedObject as? AudioMonitor.Output else { return }
        MultiOutput.shared.toggle(output)
    }

    @objc func stopMulti(_ sender: NSMenuItem) {
        MultiOutput.shared.stop()
    }
}

// MARK: - Home

private struct HomeTab: View {
    var state: NotchState
    var morph: Namespace.ID
    var nowPlaying = NowPlaying.shared

    var stats = SystemStats.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                MediaColumn(morph: morph)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .staggered(0)

                Rectangle()
                    .fill(Theme.edge)
                    .frame(width: 1)
                    .padding(.vertical, 2)

                ContextColumn()
                    .frame(width: 190, alignment: .leading)
                    .staggered(1)
            }
            .frame(maxHeight: .infinity)

            if Settings.shared.stats {
                // A full-width rule, then the strip: the stats belong to the whole
                // island rather than to either column above them.
                Rectangle()
                    .fill(Theme.edge)
                    .frame(height: 1)
                    .padding(.bottom, 8)
                StatsStrip().staggered(2)
            }
        }
    }
}

private struct MediaColumn: View {
    var morph: Namespace.ID
    var nowPlaying = NowPlaying.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if nowPlaying.hasTrack { playing } else { idle }

            // Outside the branch on purpose. A browser tab playing video
            // claims no Now Playing session at all, so `hasTrack` is false and
            // the idle card is showing - which is exactly the moment you most
            // want to be told what is making the noise.
            SourcesStrip()

            Spacer(minLength: 6)

            Rectangle()
                .fill(Theme.edge)
                .frame(height: 1)
                .padding(.bottom, 7)

            // Two sliders, the pair of things you reach for without leaving
            // what you are doing. Volume belongs beside a player; brightness has
            // no home anywhere else in the app.
            OutputVolumeRow()
            BrightnessRow().padding(.top, 6)
            ExternalBrightnessRows()
        }
    }

    /// Title, artist, scrubber and transport, stacked tight against each other.
    ///
    /// These used to be pushed apart by a spacer, which left a band of nothing
    /// between the artist and the scrubber and pinned the transport to the
    /// bottom of the panel. Grouped, they read as one control rather than two
    /// unrelated halves - and the space that frees is worth more below.
    /// The lyric runs under the whole player, starting beneath the cover. Tucked
    /// under the transport it had the text column's width and sat between the
    /// buttons and the sliders, where it read as one more control.
    private var playing: some View {
        VStack(alignment: .leading, spacing: 7) {
            player
            LyricLine()
        }
    }

    private var player: some View {
        HStack(alignment: .top, spacing: 13) {
            Artwork(morph: morph)
            VStack(alignment: .leading, spacing: 0) {
                // The sound graph sits beside what is playing, level with the
                // title and artist - the two lines it describes - rather than
                // in a row of its own the panel has no height for.
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        MarqueeText(
                            text: nowPlaying.title,
                            font: .system(size: 14, weight: .semibold),
                            color: Theme.primary
                        )
                        // A new title is a new marquee. Kept, it held the previous
                        // title's measured width - so a long title after a short one
                        // never scrolled, and a short one after a long one did.
                        .id(nowPlaying.title)
                        Text(nowPlaying.artist.isEmpty ? nowPlaying.sourceName : nowPlaying.artist)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .padding(.top, 1)
                    }
                    if Settings.shared.soundGraph {
                        SoundGraph().frame(width: 78, height: 28)
                    }
                }

                Scrubber().padding(.top, 7)
                Transport().padding(.top, 4)
                Spacer(minLength: 0)
            }
        }
    }

    private var idle: some View {
        HStack(spacing: 14) {
            ArcReactor(size: 62, intensity: 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("ONLINE").sectionLabel()
                Text("Nothing playing")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
                // ponytail: no BatteryDetail here any more - `PowerRow` sits
                // below in both states and said the same thing twice.
            }
            Spacer(minLength: 0)
        }
    }
}

/// Display brightness.
///
/// Deliberately the same grammar as the volume row below it: glyph, system
/// slider, trailing value. Two controls that look alike and behave alike read as
/// one pair rather than two features.
///
/// Hides itself when `DisplayServices` cannot be reached - an external-only
/// setup has no built-in panel to dim, and a dead slider is worse than none.
private struct BrightnessRow: View {
    var utilities = Utilities.shared

    var body: some View {
        Group {
            if utilities.brightnessAvailable {
                HStack(spacing: 9) {
                    Image(systemName: glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 18, height: 18)

                    Slider(
                        value: Binding(
                            get: { Double(utilities.brightness) },
                            set: { utilities.setBrightness(Float($0)) }
                        ),
                        in: 0 ... 1
                    )
                    .controlSize(.mini)
                    .tint(Theme.gold)

                    Text("\(Int((utilities.brightness * 100).rounded()))%")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                        .monospacedDigit()
                        .frame(width: 96, alignment: .trailing)
                }
            }
        }
    }

    /// Fills in as it brightens, the way the brightness keys draw it.
    private var glyph: String {
        utilities.brightness < 0.34 ? "sun.min.fill"
            : utilities.brightness < 0.67 ? "sun.max" : "sun.max.fill"
    }
}

/// One slider per external monitor, over DDC. Same grammar as the built-in row
/// above it, with the monitor's name where the percentage sits - which display a
/// slider belongs to is the one thing you cannot guess from a row of identical
/// sliders.
///
/// Absent entirely when there is no external monitor, or when the private
/// `IOAVService` symbols are missing. See `ExternalBrightness`.
private struct ExternalBrightnessRows: View {
    var external = ExternalBrightness.shared

    var body: some View {
        ForEach(external.displays) { display in
            HStack(spacing: 9) {
                Image(systemName: "display")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 18, height: 18)

                Slider(
                    value: Binding(
                        get: { Double(display.level) },
                        set: { external.setLevel(Float($0), for: display) }
                    ),
                    in: 0 ... 1
                )
                .controlSize(.mini)
                .tint(Theme.gold)

                Text(display.name)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 96, alignment: .trailing)
            }
            .padding(.top, 6)
            .help("\(display.name) · brightness over DDC")
        }
    }
}

/// System output volume, with the device it is going to.
///
/// The system's own slider: keyboard-operable and accessible for free, which a
/// hand-drawn bar is not. The speaker glyph is the mute toggle, so the two
/// controls people reach for sit in one row.
private struct OutputVolumeRow: View {
    var audio = AudioMonitor.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Button { audio.setMuted(!audio.muted) } label: {
                Image(systemName: glyph)
                    .font(.system(size: 11))
                    .foregroundStyle(audio.muted ? Theme.core : (hovering ? Theme.primary : Theme.secondary))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
            .hoverHighlight($hovering)
            .help(audio.muted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { Double(audio.volume) },
                    set: { audio.setVolume(Float($0)) }
                ),
                in: 0 ... 1
            )
            .controlSize(.mini)
            .tint(audio.muted ? Theme.tertiary : Theme.core)

            Text(audio.currentOutputName)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 96, alignment: .trailing)
        }
    }

    /// Matches what the volume keys draw: the number of waves tracks the level.
    private var glyph: String {
        if audio.muted || audio.volume <= 0.001 { return "speaker.slash.fill" }
        if audio.volume < 0.34 { return "speaker.wave.1.fill" }
        if audio.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

private struct Artwork: View {
    var morph: Namespace.ID
    var nowPlaying = NowPlaying.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let art = nowPlaying.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(Theme.shell)
                        ArcReactor(size: 42, intensity: 0.5)
                    }
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .matchedGeometryEffect(id: "art", in: morph)
            .shadow(color: .black.opacity(0.55), radius: 10, y: 4)

            // Source badge: which app the audio is coming from, without a label.
            if let icon = nowPlaying.sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.black.opacity(0.45), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
                    .padding(6)
            }
        }
    }
}

/// Playback position. The clock only runs while the island is open AND something
/// is playing - a ticking bar behind a closed notch is pure wasted power.
private struct Scrubber: View {
    var nowPlaying = NowPlaying.shared

    /// Where the finger is, while it is down. Non-nil for the whole drag.
    ///
    /// Load-bearing twice over. It is what makes the bar track the pointer
    /// instead of only jumping on release - a scrub with no feedback until you
    /// let go is indistinguishable from one that ignored you. And it stops the
    /// clock below fighting the drag: the live position keeps advancing while
    /// you hold, so without this the bar snapped back to the song every tick.
    @State private var scrubbing: Double?

    var body: some View {
        // The periodic rebuild is what redraws the position, and it also tore
        // down the view carrying the gesture twice a second - which is what a
        // drag that would not start looks like. Frozen while the finger is down;
        // nothing needs animating then, because the bar is following the hand.
        if nowPlaying.playing, scrubbing == nil {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in bar }
        } else {
            bar
        }
    }

    private var bar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                LevelBar(fraction: fraction)
                    .frame(height: 3.5)
                    .frame(maxHeight: .infinity)
                    // Taller than it looks, so a 3.5pt bar is still grabbable.
                    .contentShape(Rectangle())
                    // Tapping and dragging are two gestures here, not one.
                    //
                    // `DragGesture(minimumDistance: 0)` is documented to fire on
                    // a plain click, and in an ordinary window it does. This
                    // panel is never key and never activates, so AppKit delivers
                    // mouseDown and mouseUp with no mouseDragged in between -
                    // the drag never starts, `onChanged` never runs and
                    // `onEnded` never arrives. That is exactly why dragging
                    // worked and clicking did nothing: dragging is the one
                    // gesture that produces the event the recogniser waits for.
                    //
                    // ponytail: SwiftUI's own spatial tap already reports where
                    // it landed, so the click path needs no state of its own.
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                guard nowPlaying.duration > 0, geo.size.width > 0 else { return }
                                let target = ratio(value.location.x, in: geo.size.width)
                                nowPlaying.seek(to: target * nowPlaying.duration)
                            }
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard nowPlaying.duration > 0, geo.size.width > 0 else { return }
                                scrubbing = ratio(value.location.x, in: geo.size.width)
                            }
                            .onEnded { value in
                                defer { scrubbing = nil }
                                // Nothing moved means this was a click, which
                                // the tap above has already handled - without
                                // the guard both gestures fire and seek twice.
                                //
                                // Two tests, either of which is enough, because
                                // dragging is the path that already works and
                                // must not become collateral. `scrubbing` is set
                                // by `onChanged`; the translation is read from
                                // the gesture itself and holds even if this
                                // panel ever stops delivering `onChanged` the
                                // way the click already fails to.
                                guard scrubbing != nil || value.translation != .zero,
                                      nowPlaying.duration > 0, geo.size.width > 0
                                else { return }
                                let target = ratio(value.location.x, in: geo.size.width)
                                nowPlaying.seek(to: target * nowPlaying.duration)
                            }
                    )
            }
            .frame(height: 11)
            HStack {
                // Reads the scrubbed time while dragging, so the number under
                // your eye is the one you are about to land on.
                Text(Self.clock(displayed))
                Spacer()
                // Remaining, not total - "how long left" is the question people
                // actually have.
                Text("-" + Self.clock(max(nowPlaying.duration - displayed, 0)))
            }
            .font(.system(size: 10))
            .foregroundStyle(scrubbing == nil ? Theme.tertiary : Theme.secondary)
            .monospacedDigit()
        }
    }

    private func ratio(_ x: CGFloat, in width: CGFloat) -> Double {
        min(max(x / width, 0), 1)
    }

    /// The scrub target while dragging, the song otherwise.
    private var displayed: Double {
        guard let scrubbing else { return nowPlaying.livePosition }
        return scrubbing * nowPlaying.duration
    }

    private var fraction: Double {
        guard nowPlaying.duration > 0 else { return 0 }
        if let scrubbing { return scrubbing }
        return min(max(nowPlaying.livePosition / nowPlaying.duration, 0), 1)
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct Transport: View {
    var nowPlaying = NowPlaying.shared

    var body: some View {
        HStack(spacing: 4) {
            Control("shuffle", "Shuffle", active: nowPlaying.shuffling, size: 11) {
                nowPlaying.toggleShuffle()
            }
            Spacer(minLength: 0)
            Control("backward.fill", "Previous", size: 13) { nowPlaying.send(.previous) }
            Control(nowPlaying.playing ? "pause.fill" : "play.fill",
                    nowPlaying.playing ? "Pause" : "Play", size: 17) {
                nowPlaying.send(.togglePlayPause)
            }
            Control("forward.fill", "Next", size: 13) { nowPlaying.send(.next) }
            Spacer(minLength: 0)
            Control("repeat", "Repeat", active: nowPlaying.repeating, size: 11) {
                nowPlaying.toggleRepeat()
            }
        }
        .frame(maxWidth: 230)
    }
}

private struct Control: View {
    var symbol: String
    var label: String
    var active = false
    var size: CGFloat
    var action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, _ label: String, active: Bool = false, size: CGFloat, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.active = active
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size + 17, height: size + 13)
                .background(
                    Circle().fill(hovering ? Color.white.opacity(0.08) : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(Pressable(scale: 0.88))
        .hoverHighlight($hovering)
        .help(label)
        .accessibilityLabel(label)
    }

    private var tint: Color {
        if active { return Theme.core }
        return hovering ? Theme.primary : Theme.secondary
    }
}

// MARK: - Context column

/// Calendar lives beside the player rather than behind a tab - a week strip is
/// small enough that hiding it costs more than it saves.
private struct ContextColumn: View {
    var calendar = CalendarPeek.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WeekStrip()

            if !calendar.authorized {
                PermissionNotice(
                    message: Permissions.grantsMayBeStale
                        ? "Calendar was granted to an older build"
                        : "Calendar access is off",
                    action: "Allow",
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
                    onTap: { calendar.requestAccess() }
                )
            } else if calendar.events.isEmpty {
                EmptyState(symbol: "calendar.badge.checkmark",
                           title: Foundation.Calendar.current.isDateInToday(calendar.selectedDay)
                               ? "No events today"
                               : "Nothing on \(calendar.selectedDay.formatted(.dateTime.weekday(.abbreviated).day()))",
                           detail: "Enjoy your free time")
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(calendar.events) { EventRow(event: $0) }
                    }
                    .padding(.bottom, 4)
                }
                // Fade where the list meets the panel edge rather than cutting it.
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            Spacer(minLength: 0)
        }
        // A day picked on a previous open must not persist into today.
        .onAppear { calendar.resetToToday() }
    }
}

private struct WeekStrip: View {
    var calendar = CalendarPeek.shared
    var weather = Weather.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: -2) {
                // Follows the selection, so picking a day into the next month
                // does not leave a stale heading.
                Text(calendar.selectedDay.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .contentTransition(.opacity)
                if let temperature = weather.temperature, Settings.shared.weather {
                    // The year is the least useful thing in the strip; the
                    // weather takes its line when there is a reading.
                    Button { weather.openApp() } label: {
                        HStack(spacing: 2) {
                            Image(systemName: weather.symbol)
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 9))
                            Text("\(temperature)°")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                    .buttonStyle(Pressable())
                    .help(weather.detail)
                    .accessibilityLabel("\(temperature) degrees, \(weather.summary)")
                } else {
                    Text(calendar.selectedDay.formatted(.dateTime.year()))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(width: 34, alignment: .leading)

            HStack(spacing: 1) {
                ForEach(calendar.strip, id: \.self) { day in
                    DayCell(day: day)
                }
            }
        }
    }
}

private struct DayCell: View {
    var day: Date
    var calendar = CalendarPeek.shared
    @State private var hovering = false

    private var isToday: Bool { Foundation.Calendar.current.isDateInToday(day) }
    private var isSelected: Bool { calendar.isSelected(day) }

    var body: some View {
        Button {
            withAnimation(Motion.content) { calendar.select(day) }
        } label: {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.secondary : Theme.tertiary)
                ZStack {
                    Circle()
                        .fill(isSelected ? Theme.core : (hovering ? Color.white.opacity(0.1) : .clear))
                    // Today stays marked even when another day is selected, so
                    // you never lose your place in the strip.
                    if isToday, !isSelected {
                        Circle().strokeBorder(Theme.core.opacity(0.55), lineWidth: 1)
                    }
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 10, weight: isSelected || isToday ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.onCore : Theme.secondary)
                        .monospacedDigit()
                }
                .frame(width: 19, height: 19)

                // Dot means that day has something on it.
                Circle()
                    .fill(calendar.hasEvents(on: day) ? Theme.gold : .clear)
                    .frame(width: 3, height: 3)
            }
            .frame(width: 21)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.9))
        .hoverHighlight($hovering)
        .help(day.formatted(.dateTime.weekday(.wide).month().day()))
    }
}

/// The empty state, which doubles as the primary action when there is one.
///
/// A panel whose only control is a small label in the top corner reads as empty
/// rather than as waiting for you. Giving the empty state the action puts the
/// target where the eye already is - the middle of the space it explains - and
/// the whole block becomes the button.
struct EmptyState: View {
    var symbol: String
    var title: String
    var detail: String
    /// Shown as a button inside the block. Without it this stays a plain label.
    var actionTitle: String?
    var busy = false
    var action: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        if let action, let actionTitle {
            Button(action: action) {
                content(actionTitle: actionTitle)
            }
            .buttonStyle(Pressable(scale: 0.99))
            .hoverHighlight($hovering)
            .disabled(busy)
        } else {
            content(actionTitle: nil)
        }
    }

    @ViewBuilder
    private func content(actionTitle: String?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(actionTitle == nil ? Theme.tertiary : Theme.gold.opacity(0.9))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)

            if let actionTitle {
                Text(busy ? "Working…" : actionTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(busy ? Theme.tertiary : Theme.notchBlack)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)
                    .background(Capsule().fill(busy ? Color.white.opacity(0.12) : Theme.gold))
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(hovering && action != nil ? Color.white.opacity(0.05) : .clear)
        )
    }
}

private struct EventRow: View {
    var event: CalendarPeek.Event
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(event.isPast ? Theme.tertiary : Theme.core)
                .frame(width: 2, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(event.isPast ? Theme.secondary : Theme.primary)
                    .strikethrough(event.isPast, color: Theme.tertiary)
                    .lineLimit(1)
                Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
            if let url = event.joinURL {
                TextAction("Join", tint: Theme.core) { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.05) : .clear)
        )
        .hoverHighlight($hovering)
        .contentShape(Rectangle())
        .onTapGesture { CalendarPeek.shared.open(event) }
        .help("Open in Calendar")
    }
}

/// Files you parked, and text you copied - the two things you carry from one
/// place to another, on one tab.
private struct ShelfTab: View {
    @Bindable var state: NotchState
    @Bindable var settings = Settings.shared
    @Namespace private var indicator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.clipboard {
                HStack(spacing: 2) {
                    Segment(title: "Files", selected: settings.shelfMode != "clipboard", indicator: indicator) {
                        withAnimation(Motion.content) { settings.shelfMode = "files" }
                    }
                    Segment(title: "Clipboard", selected: settings.shelfMode == "clipboard", indicator: indicator) {
                        withAnimation(Motion.content) { settings.shelfMode = "clipboard" }
                    }
                }
                .staggered(0)
            }
            // A drag always lands on the files, whichever half is showing.
            if settings.clipboard, settings.shelfMode == "clipboard", !state.dropTargeted {
                ClipboardPane()
            } else {
                FilesPane(state: state, labelled: !settings.clipboard)
            }
        }
    }
}

private struct FilesPane: View {
    @Bindable var state: NotchState
    var labelled: Bool
    var shelf = Shelf.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if labelled { Text("SHELF").sectionLabel() }
                if !shelf.items.isEmpty {
                    Text("\(shelf.items.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.notchBlack)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Theme.gold))
                }
                Spacer()
                if !shelf.items.isEmpty {
                    // The shelf is where several files are already lined up in an
                    // order somebody chose, which is exactly what a PDF of them
                    // needs.
                    let pictures = shelf.items.filter(Convert.isImage)
                    if !pictures.isEmpty {
                        TextAction("\(pictures.count) → PDF", tint: Theme.gold) {
                            Convert.shared.imagesToPDF(pictures)
                        }
                    }
                    TextAction("AirDrop", tint: Theme.core) { shelf.airDrop() }
                    TextAction("Clear", tint: Theme.tertiary) { shelf.clear() }
                }
            }
            .staggered(0)

            if shelf.items.isEmpty {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        state.dropTargeted ? Theme.core : Color.white.opacity(0.15),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(state.dropTargeted ? Theme.core.opacity(0.08) : .clear)
                    )
                    .overlay(
                        EmptyState(
                            symbol: state.dropTargeted ? "arrow.down.circle.fill" : "tray.and.arrow.down",
                            title: state.dropTargeted ? "Release to drop" : "Drop files here",
                            detail: "They stay until you clear them"
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(Motion.content, value: state.dropTargeted)
                    .staggered(1)
            } else {
                // A grid rather than one horizontal strip: files wrap and fill the
                // panel instead of running off the right edge.
                ScrollView(showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                        spacing: 6
                    ) {
                        ForEach(Array(shelf.items.enumerated()), id: \.element) { index, url in
                            ShelfItem(url: url).staggered(index + 1)
                        }
                    }
                }
            }
        }
    }
}

private struct ClipboardPane: View {
    var clipboard = Clipboard.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if clipboard.clips.isEmpty {
                EmptyState(symbol: "doc.on.clipboard",
                           title: "Nothing copied yet",
                           detail: "Copy some text, then switch apps - it lands here")
                    .staggered(1)
            } else {
                HStack {
                    Text("Click to paste into the app in front")
                        .font(TypeScale.caption)
                        .foregroundStyle(Theme.tertiary)
                    Spacer()
                    TextAction("Clear", tint: Theme.tertiary) { clipboard.clear() }
                }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(clipboard.ordered.enumerated()), id: \.element.id) { index, clip in
                            ClipRow(clip: clip).staggered(min(index, 6) + 1)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ClipRow: View {
    var clip: Clipboard.Clip
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            leading.frame(width: 14, height: 14)

            Text(oneLine)
                .font(.system(size: 11))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if clip.pinned, !hovering {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.gold)
            }

            if hovering {
                Button { Clipboard.shared.togglePin(clip) } label: {
                    Image(systemName: clip.pinned ? "pin.slash" : "pin")
                        .font(.system(size: 9.5))
                }
                .buttonStyle(Pressable())
                .foregroundStyle(clip.pinned ? Theme.gold : Theme.secondary)
                .help(clip.pinned ? "Unpin" : "Pin - never cleared, never evicted")
                Button { Clipboard.shared.copy(clip) ; HUD.shared.show(.utility(symbol: "doc.on.doc.fill", title: "Copied", detail: "Ready to paste"), for: 1.4) } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9.5))
                }
                .buttonStyle(Pressable())
                .foregroundStyle(Theme.secondary)
                .help("Copy without pasting")
                Button { Clipboard.shared.remove(clip) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(Pressable())
                .foregroundStyle(Theme.tertiary)
                .help("Remove from history")
            } else {
                Text(clip.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
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
        .onTapGesture { Clipboard.shared.paste(clip) }
        .help(clip.text.count > 400 ? String(clip.text.prefix(400)) + "…" : clip.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(oneLine)
        .accessibilityHint("Pastes into the app in front")
        .accessibilityAddTraits(.isButton)
    }

    /// What the clip *is*, not what app it came from. A row of identical app
    /// icons tells you nothing; a thumbnail, a swatch or a document icon tells
    /// you which row you are looking for.
    @ViewBuilder private var leading: some View {
        switch clip.kind {
        case .image:
            if let image = Clipboard.shared.image(for: clip) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.tertiary)
            }
        case .colour:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(nsColor: Clipboard.colour(for: clip) ?? .gray))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                )
        case .file:
            if let first = clip.files.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first)).resizable()
            } else {
                Image(systemName: "doc").foregroundStyle(Theme.tertiary)
            }
        case .text:
            if let icon = appIcon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "doc.on.clipboard").foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var oneLine: String {
        clip.text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private var appIcon: NSImage? {
        guard let app = clip.app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct ShelfItem: View {
    var url: URL
    var shelf = Shelf.shared
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: shelf.icon(for: url))
                .resizable()
                .frame(width: 38, height: 38)
                .scaleEffect(hovering ? 1.06 : 1)
            Text(url.lastPathComponent)
                .font(.system(size: 9.5))
                .foregroundStyle(hovering ? Theme.secondary : Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 66)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.06) : .clear)
        )
        .hoverHighlight($hovering)
        .onDrag {
            // ponytail: the pasteboard already knows how to carry a file URL.
            NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .onTapGesture { shelf.reveal(url) }
        .help(url.lastPathComponent)
        // The conversions live here as well as in Tools ▸ Convert: a file already
        // on the shelf is the case where you have the thing in front of you, and
        // walking it back through a file picker to convert it is the long way
        // round. Only ever the ones that apply to this file.
        .contextMenu {
            Button("Reveal in Finder") { shelf.reveal(url) }
            if Convert.isEPUB(url) {
                Button("Convert to MOBI") { Convert.shared.epubToMobi(url) }
            }
            if Convert.isMedia(url) {
                Button("Save audio as MP3") { Convert.shared.toMP3(url) }
            }
            if Convert.isArchive(url) {
                Button("Extract here") { Convert.shared.extract(url) }
            }
            if Convert.isImage(url) {
                Menu("Convert image to") {
                    Button("PNG") { Convert.shared.convertImage(url, to: .png) }
                    Button("JPEG") { Convert.shared.convertImage(url, to: .jpeg) }
                    Button("HEIC") { Convert.shared.convertImage(url, to: .heic) }
                    Button("PDF") { Convert.shared.imagesToPDF([url]) }
                }
            }
            Divider()
            Button("Remove") { shelf.remove(url) }
        }
    }
}

// MARK: - Shared

struct TextAction: View {
    var title: String
    var tint: Color
    var action: () -> Void
    @State private var hovering = false

    init(_ title: String, tint: Color, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(hovering ? Theme.primary : tint)
                .padding(.vertical, 3)
                .padding(.horizontal, 7)
                .background(Capsule().fill(hovering ? tint.opacity(0.2) : tint.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.93))
        .hoverHighlight($hovering)
    }
}

extension View {
    /// Rows cascade in rather than all landing at once. Purely decorative, so it
    /// never blocks input and is dropped entirely under reduced motion.
    func staggered(_ index: Int) -> some View {
        modifier(Staggered(index: index))
    }
}

private struct Staggered: ViewModifier {
    var index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || Motion.reduced ? 0 : 5)
            .onAppear {
                withAnimation(Motion.content.delay(Motion.stagger(index))) { shown = true }
            }
    }
}

/// Live frequency bars, low on the left. See `Spectrum`.
///
/// A `Canvas` under a frame clock rather than 24 views bound to state: nothing
/// is invalidated but this one drawing, and the clock stops whenever the
/// listener does, so a paused song or a shut island draws nothing at all.
private struct SoundGraph: View {
    var nowPlaying = NowPlaying.shared
    var audio = AudioMonitor.shared
    var spectrum = Spectrum.shared

    var body: some View {
        // Two branches, not one clock with `paused:` bound to `running`. The
        // clock was made paused - the listener takes a moment to start - and
        // SwiftUI never restarted it when `paused` went false: measured, the
        // bars drew once and froze while the listener heard the song fine. A
        // clock that only exists while running cannot be stuck paused.
        Group {
            if spectrum.running {
                // Twenty a second: what a hardware level meter shows, and a third
                // less work than thirty for a difference nobody can see in bars
                // this size.
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in bars(spectrum.levels.read()) }
            } else {
                bars(spectrum.levels.read())
            }
        }
        .opacity(spectrum.running ? 1 : 0.35)
        .animation(Motion.content, value: spectrum.running)
        // Held only while this is on screen and the music is playing; either
        // ending cancels the task, which lets the listener go. A new output
        // device restarts it, because the listener is built around one.
        .task(id: "\(nowPlaying.playing) \(audio.currentOutput)") {
            guard nowPlaying.playing else { return }
            spectrum.hold()
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            spectrum.release()
        }
        .help("Sound graph - listens only while this is on screen and playing")
        .accessibilityHidden(true)
    }

    /// The levels come in as a value, read once per tick by the clock above.
    /// Read inside the `Canvas` instead, the canvas was the same value every
    /// frame - same closure, same captured object - so SwiftUI skipped every
    /// redraw after the first and the bars sat still while the audio moved.
    ///
    /// Plain capsules, not a `Canvas`. A canvas is re-rasterised every frame,
    /// and drawn thirty times a second it kept about 56 MB of GPU surfaces
    /// alive for as long as the graph ran. A capsule whose height changes is a
    /// layer whose frame changes, which Core Animation does for free.
    private func bars(_ levels: [Float]) -> some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(levels.indices, id: \.self) { index in
                    let level = Double(levels[index])
                    Capsule()
                        // Gold at rest, hotter as it rises.
                        .fill(Theme.gold.mix(with: Theme.core, by: level))
                        // A floor of a dot per bar, so silence still reads as
                        // the graph rather than as nothing.
                        .frame(height: max(2, geo.size.height * level))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }
}

/// The line being sung, and a hint of the next one.
///
/// Driven by `NowPlaying.livePosition`, which is `elapsedTime + timestamp` rather
/// than a tick - so this follows the song with no clock of its own. The
/// `TimelineView` runs only while the island is open *and* something is
/// playing, and stops the moment either stops being true, which is the same
/// rule the scrubber's clock follows.
private struct LyricLine: View {
    var nowPlaying = NowPlaying.shared
    var lyrics = Lyrics.shared

    var body: some View {
        if Settings.shared.lyrics, !lyrics.lines.isEmpty {
            // Paused, the line still shows - where the song stopped - so the
            // island does not shrink and grow with the play button.
            Group {
                if nowPlaying.playing {
                    // Redrawn at the moment each line starts, not on a tick. A
                    // 0.35s tick switched lines up to that late, and woke the
                    // app three times a second to change nothing. A seek or a
                    // pause moves `position`, which rebuilds this schedule.
                    TimelineView(.explicit(lyrics.changes(after: elapsed, rate: nowPlaying.playbackRate))) { _ in
                        pair
                    }
                    // A new clock for a new position or track. A schedule
                    // handed to a clock that already exists is not reliably
                    // picked up - the sound graph froze on exactly that.
                    .id("\(lyrics.track) \(nowPlaying.positionStamp.timeIntervalSince1970)")
                } else {
                    pair
                }
            }
            .frame(height: 29, alignment: .topLeading)
        } else if Settings.shared.lyrics, let plain = lyrics.plain, !plain.isEmpty {
            // LRCLIB has the words but not the timings. Showing the first line
            // as a static label beats showing nothing and beats scrolling
            // something that cannot be kept in time.
            Text(plain.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .frame(height: 29, alignment: .topLeading)
        }
    }

    /// Where the song is, read a fifth of a second ahead. A line has to be on
    /// screen and through its fade before the words are sung, or reading it
    /// always lands after hearing it - the reason every lyric display leads.
    private var elapsed: Double { nowPlaying.livePosition + 0.2 }

    private var pair: some View {
        let pair = lyrics.current(at: elapsed)
        return VStack(alignment: .leading, spacing: 0) {
            Text(pair?.now ?? "")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .contentTransition(.opacity)
            if let next = pair?.next {
                Text(next)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
        }
        .animation(Motion.content, value: pair?.now)
    }
}

/// Every app making sound, not only the one macOS calls "now playing".
///
/// macOS has exactly one Now Playing session. `MRMediaRemoteGetNowPlayingClient`
/// is singular, whichever app claimed it last owns it, and a video in a browser
/// tab usually never claims one at all - so there is no second timeline to
/// show, and anything that looked like one would be invented. What there *is*:
/// CoreAudio knows every process holding an output stream and whether each is
/// pushing samples right now, which `VolumeMixer` already tracks.
///
/// One line of chips rather than a list of rows, because the column has no
/// height to spare. A list was tried and clipped its second row in half against
/// the divider - the panel is 196pt and the player, lyrics and two sliders
/// already want all of it. Levels stay in the Mixer tab, which has the room.
///
/// The list is filled by `NotchState.open`, not by this view: a view cannot
/// populate the list it is deciding whether to exist from, and when it tried,
/// it drew nothing and filled in a frame later.
private struct SourcesStrip: View {
    var mixer = VolumeMixer.shared
    var audio = AudioMonitor.shared
    var nowPlaying = NowPlaying.shared

    var body: some View {
        Group {
            if Settings.shared.mixer, sources.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(sources) { app in
                            SourceChip(app: app, owner: app.key == nowPlaying.bundleID)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(height: 22)
            }
        }
        .onChange(of: audio.outputChangeCount) { mixer.refresh() }
        .onChange(of: audio.processChangeCount) { mixer.refresh() }
    }

    /// What is actually making a noise, plus whatever owns the Now Playing
    /// session even when it is paused - so Spotify paused and a browser tab
    /// playing are both here, which is the case this exists for.
    ///
    /// `VolumeMixer` deliberately lists every app *holding* an audio
    /// connection, because the mixer wants you to set a level in advance. That
    /// is the wrong set here. Measured on this Mac: Claude, Eloquent, Gemini,
    /// Chrome, Safari and Spotify all held one while none had anything to say.
    private var sources: [VolumeMixer.App] {
        mixer.apps.filter { $0.playing || $0.key == nowPlaying.bundleID }
    }
}

/// One source. The dot is the whole point: filled while samples are flowing,
/// hollow while the app holds the output open but is paused - the difference
/// between Spotify paused and a tab playing.
private struct SourceChip: View {
    var app: VolumeMixer.App
    /// The app that owns the Now Playing session, and so the scrubber above.
    var owner: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 11, height: 11)
            } else {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.tertiary)
            }
            Circle()
                .fill(app.playing ? Theme.core : .clear)
                .overlay(Circle().strokeBorder(app.playing ? .clear : Theme.tertiary, lineWidth: 1))
                .frame(width: 4.5, height: 4.5)
            Text(app.name)
                .font(.system(size: 9.5))
                .foregroundStyle(owner ? Theme.primary : Theme.secondary)
                .lineLimit(1)
            if owner {
                Image(systemName: "waveform")
                    .font(.system(size: 7.5))
                    .foregroundStyle(Theme.gold)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0.055))
        )
        .overlay(
            Capsule().strokeBorder(owner ? Theme.gold.opacity(0.45) : .clear, lineWidth: 0.5)
        )
        .contentShape(Capsule())
        .hoverHighlight($hovering)
        .onTapGesture {
            NSRunningApplication(processIdentifier: app.id)?.activate()
        }
        .help(owner
              ? "\(app.name) - the scrubber above controls this"
              : "\(app.name) - \(app.playing ? "playing" : "silent"). Levels are in the Mixer tab.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), \(app.playing ? "playing" : "silent")")
        .accessibilityHint("Brings the app forward")
    }
}

