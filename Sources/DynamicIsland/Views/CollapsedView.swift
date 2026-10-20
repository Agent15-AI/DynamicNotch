import SwiftUI

/// Idle content. Sits inside the physical cutout, so it must stay quiet: no
/// borders, no glow, nothing that draws a rectangle against true black.
struct CollapsedView: View {
    var state: NotchState
    var morph: Namespace.ID

    var nowPlaying = NowPlaying.shared
    var battery = Battery.shared
    var hud = HUD.shared
    var audio = AudioMonitor.shared

    var body: some View {
        HStack(spacing: 0) {
            leading
            // Reserves the cutout rather than letting the two sides meet in the
            // middle of it. Without a floor here the trailing label grows
            // leftward into the hole, and the part that crosses the bezel is
            // simply not there - no ellipsis, no clipping, just missing text.
            Spacer(minLength: state.hasPhysicalNotch ? state.notchGap : 0)
            trailing
        }
        .padding(.horizontal, max(7, state.collapsedSize.height * 0.24))
        // `state.size`, not `collapsedSize` - the two are equal while idle and
        // differ for exactly the case this view exists to show. A live activity
        // widens the closed island by 132pt so its glyph and label have somewhere
        // to sit; pinned to `collapsedSize` the content stayed notch-width and on
        // a notched Mac that is the cutout itself, so every peek rendered behind
        // the bezel and was never seen. A display with no notch has no bezel to
        // hide it, which is why skipping a track appeared to work on an external
        // monitor and nowhere else.
        .frame(width: state.size.width, height: state.size.height)
    }

    @ViewBuilder
    private var leading: some View {
        switch hud.current {
        case .charging(let percent, let plugged):
            ChargingActivity(percent: percent, plugged: plugged, size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .bluetooth(_, let symbol, let connected, _):
            BluetoothActivity(symbol: symbol, connected: connected, size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .download(_, let icon):
            DownloadActivity(icon: icon, size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .timer:
            TimerDoneActivity(size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .alarm:
            TimerDoneActivity(size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .welcome:
            ArcReactor(size: glyph * 1.85, intensity: 1)
                .transition(Self.fromLeading)
        case .recording(_, let started):
            RecordingActivity(started: started, size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .screenshot(_, let image, _):
            ScreenshotActivity(image: image, size: glyph * 2.1)
                .transition(Self.fromLeading)
        case .color(_, let swatch):
            ColorSwatchActivity(swatch: swatch, size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .utility(let symbol, _, _):
            UtilityActivity(symbol: symbol, size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .install(_, let icon):
            DownloadActivity(icon: icon, size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .update:
            UtilityActivity(symbol: "arrow.down.circle.fill", size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .upcoming(_, _, let url):
            UtilityActivity(symbol: url == nil ? "calendar" : "video.fill", size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .verification:
            UtilityActivity(symbol: "number", size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .eyeBreak:
            UtilityActivity(symbol: "eye.fill", size: glyph * 1.85)
                .transition(Self.fromLeading)
        case .track(_, _, let art):
            Group {
                if let art {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.shell)
                }
            }
            .frame(width: glyph * 1.7, height: glyph * 1.7)
            .clipShape(RoundedRectangle(cornerRadius: glyph * 0.34, style: .continuous))
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        case nil:
            // The microphone no longer takes the island over. That rule was
            // written when the indicator was a full glyph and crowded anything
            // beside it; a dot sits next to artwork without competing, and
            // blanking the leading side hid what was playing for as long as
            // anything held the mic.
            if let art = nowPlaying.artwork, nowPlaying.hasTrack {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: glyph * 1.7, height: glyph * 1.7)
                    .clipShape(RoundedRectangle(cornerRadius: glyph * 0.34, style: .continuous))
                    // The art is the same object in both states, so it travels
                    // rather than cross-fading. This is the move that makes the
                    // island read as one thing opening.
                    .matchedGeometryEffect(id: "art", in: morph)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch hud.current {
        case .charging(let percent, let plugged):
            HStack(spacing: glyph * 0.4) {
                BatteryGauge(percent: percent, charging: plugged, low: percent <= 20 && !plugged,
                             width: glyph * 1.5)
                ActivityLabel(text: "\(percent)%", detail: plugged ? "Charging" : "On battery", size: glyph)
            }
            .transition(Self.fromTrailing)
        case .bluetooth(let name, _, let connected, let battery):
            ActivityLabel(text: name,
                          detail: connected ? (battery.map { "Connected · \($0)%" } ?? "Connected") : "Disconnected",
                          size: glyph)
                .transition(Self.fromTrailing)
        case .download(let name, _):
            ActivityLabel(text: name, detail: "Downloaded", size: glyph)
                .transition(Self.fromTrailing)
        case .timer:
            ActivityLabel(text: "Time's up", detail: "Timer finished", size: glyph)
                .transition(Self.fromTrailing)
        case .alarm(let label):
            ActivityLabel(text: label, detail: "Alarm", size: glyph)
                .transition(Self.fromTrailing)
        case .welcome:
            ActivityLabel(text: "Ready", detail: "⌃⌘N or point at the notch", size: glyph)
                .transition(Self.fromTrailing)
        case .recording(let app, let started):
            // With no app to name, the title *is* "Microphone" - and a detail
            // reading "Microphone on" under it said the word twice in two lines.
            ActivityLabel(
                text: app ?? "Microphone",
                detail: app == nil
                    ? (started ? "In use" : "Released")
                    : (started ? "Using the microphone" : "Stopped listening"),
                size: glyph
            )
            .transition(Self.fromTrailing)
        case .screenshot(let name, _, _):
            ActivityLabel(text: name, detail: "Drag it out", size: glyph)
                .transition(Self.fromTrailing)
        case .color(let hex, _):
            ActivityLabel(text: hex, detail: "Copied", size: glyph)
                .transition(Self.fromTrailing)
        case .utility(_, let title, let detail):
            ActivityLabel(text: title, detail: detail, size: glyph)
                .transition(Self.fromTrailing)
        case .install(let name, _):
            ActivityLabel(text: name, detail: "Click to install", size: glyph)
                .transition(Self.fromTrailing)
        case .update(let version):
            ActivityLabel(text: "DynamicNotch \(version)", detail: "Click to update", size: glyph)
                .transition(Self.fromTrailing)
        case .upcoming(let title, let detail, _):
            ActivityLabel(text: title, detail: detail, size: glyph)
                .transition(Self.fromTrailing)
        case .verification(let code):
            ActivityLabel(text: code, detail: "Click for the code alone", size: glyph)
                .transition(Self.fromTrailing)
        case .eyeBreak(let until):
            // The one countdown in the closed island. It runs for twenty seconds,
            // while the activity is up and being looked at - or rather, while it
            // is being deliberately not looked at.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ActivityLabel(
                    text: "Look away · \(max(0, Int(until.timeIntervalSinceNow.rounded())))s",
                    detail: "20 feet, 20 seconds",
                    size: glyph
                )
            }
            .transition(Self.fromTrailing)
        case .track(let title, let subtitle, _):
            ActivityLabel(text: title, detail: subtitle, size: glyph)
                .transition(Self.fromTrailing)
        case nil:
            Group {
                if audio.micActive {
                    MicIndicator(size: glyph * 0.5)
                } else if nowPlaying.playing {
                    Waveform(tint: Theme.core)
                        .frame(width: glyph * 1.15, height: glyph * 0.85)
                } else {
                    ArcReactor(size: glyph * 1.2, intensity: 0)
                }
            }
            .animation(Motion.content, value: audio.micActive)
        }
    }

    private var glyph: CGFloat { state.collapsedSize.height * 0.46 }

    /// Enter from the edge the content sits on, so the island reads as opening
    /// outward rather than two things fading on top of each other. Exit is the
    /// same path reversed - asymmetric exits look like a glitch.
    private static var fromLeading: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private static var fromTrailing: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }
}

/// Two-line caption used by the live activities. Kept narrow so it never pushes
/// the collapsed island wider than the notch it lives in.
struct ActivityLabel: View {
    var text: String
    var detail: String
    var size: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: -1) {
            Text(text)
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(.system(size: size * 0.5))
                .foregroundStyle(Theme.tertiary)
        }
        // Wide enough to use the room the island now makes for it. At 6x this
        // truncated titles that had space to spare on both kinds of display; the
        // stack it sits in is what actually bounds it, and this is only the
        // ceiling that stops one long title swallowing the whole island.
        .frame(maxWidth: size * 10, alignment: .trailing)
    }
}

/// Standing indicator for a live microphone.
///
/// A microphone, not an abstract dot. A coloured circle in the corner of the
/// notch says only "something is on" and leaves you to guess what - the glyph
/// says which sense is being used, in the shape everyone already reads as a
/// microphone.
///
/// Orange rather than the app's own palette: orange already means exactly this
/// everywhere else on the Mac, and a themed indicator would be a worse signal
/// for being more consistent with the island.
/// A dot, not a glyph.
///
/// `mic.fill` at glyph size was the loudest thing in the closed island and it is
/// up whenever anything holds the microphone - which for some people is all day.
/// The dot carries the same one bit of state in a fraction of the space, and
/// matches the amber dot macOS puts in the menu bar for the same reason.
struct MicIndicator: View {
    var size: CGFloat

    var body: some View {
        Circle()
            .fill(Color(red: 1.0, green: 0.58, blue: 0.0))
            .frame(width: size, height: size)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
            .help("Microphone in use")
    }
}

struct LevelBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.core.opacity(0.18))
                Capsule().fill(Theme.core).frame(width: geo.size.width * fraction)
            }
        }
        .animation(Motion.content, value: fraction)
    }
}

/// Static bars. Deliberately not animated - an always-on visualiser is the single
/// biggest power cost in every other notch app.
struct Waveform: View {
    var tint: Color
    private let heights: [CGFloat] = [0.42, 0.86, 0.58, 1.0, 0.5]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: geo.size.width * 0.09) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, factor in
                    Capsule()
                        .fill(tint)
                        .frame(height: geo.size.height * factor)
                }
            }
            .frame(height: geo.size.height, alignment: .center)
        }
    }
}
