import SwiftUI

/// Transient live activities for the closed island.
///
/// All three run once through a `KeyframeAnimator` timeline and stop - no
/// `repeatForever`, nothing left spinning after the HUD clears. They animate
/// only `scale`, `opacity`, `rotation` and `trim`, so nothing triggers layout.
///
/// Under reduced motion each collapses to its settled frame: the information
/// still lands, the movement does not.

// MARK: - Charging

/// Arc reactor spinning up: the gold ring charges round, the core ignites.
struct ChargingActivity: View {
    var percent: Int
    var plugged: Bool
    var size: CGFloat

    private struct Frame {
        var ring = 0.0
        var core = 0.0
        var glow = 0.0
        var bolt = 0.0
    }

    @State private var play = false

    var body: some View {
        KeyframeAnimator(initialValue: Frame(), trigger: play) { f in
            ZStack {
                // Outer ring: the charge sweeping round.
                Circle()
                    .trim(from: 0, to: Motion.reduced ? 1 : f.ring)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: Theme.gold, location: 0.0),
                                .init(color: Theme.core, location: 0.35),
                                .init(color: Theme.gold, location: 0.7),
                                .init(color: Theme.gold, location: 1.0),
                            ]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                // Housing.
                Circle()
                    .stroke(Theme.gold.opacity(0.35), lineWidth: size * 0.045)
                    .padding(size * 0.16)

                // Core ignition.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white, Theme.core, Theme.core.opacity(0.4)],
                            center: .center, startRadius: 0, endRadius: size * 0.3
                        )
                    )
                    .padding(size * 0.3)
                    .scaleEffect(Motion.reduced ? 1 : f.core)
                    .shadow(color: Theme.core.opacity(f.glow), radius: size * 0.28)

                Image(systemName: plugged ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: size * 0.3, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(Motion.reduced ? 1 : f.bolt)
            }
            .frame(width: size, height: size)
            .onAppear { play = true }
        } keyframes: { _ in
            KeyframeTrack(\.ring) {
                // Strong ease-out: the sweep is fastest the instant it starts.
                CubicKeyframe(1, duration: 0.72, startVelocity: 3, endVelocity: 0)
            }
            KeyframeTrack(\.core) {
                LinearKeyframe(0.2, duration: 0.18)
                SpringKeyframe(1.12, duration: 0.34, spring: .bouncy)
                SpringKeyframe(1.0, duration: 0.3, spring: .snappy)
            }
            KeyframeTrack(\.glow) {
                LinearKeyframe(0.0, duration: 0.16)
                CubicKeyframe(0.85, duration: 0.4)
                CubicKeyframe(0.5, duration: 0.5)
            }
            KeyframeTrack(\.bolt) {
                LinearKeyframe(0, duration: 0.26)
                CubicKeyframe(1, duration: 0.24)
            }
        }
    }
}

// MARK: - Download

/// The file materialises behind a descending scan line, the way the suit HUD
/// renders something into existence.
struct DownloadActivity: View {
    var icon: NSImage
    var size: CGFloat

    private struct Frame {
        var reveal = 0.0
        var scan = 0.0
        var scanOpacity = 0.0
        var settle = 0.92
        var ring = 0.0
    }

    @State private var play = false

    var body: some View {
        KeyframeAnimator(initialValue: Frame(), trigger: play) { f in
            ZStack {
                Circle()
                    .trim(from: 0, to: Motion.reduced ? 1 : f.ring)
                    .stroke(Theme.gold.opacity(0.7), style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 0.66, height: size * 0.66)
                    // Scale the mask rather than its frame: a transform, so no
                    // layout pass per frame.
                    .mask(
                        Rectangle()
                            .scaleEffect(y: Motion.reduced ? 1 : f.reveal, anchor: .top)
                    )
                    .scaleEffect(Motion.reduced ? 1 : f.settle)

                // The scan line itself, riding down the icon.
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Theme.gold, .white, Theme.gold, .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: size * 0.72, height: max(1, size * 0.045))
                    .offset(y: -size * 0.33 + size * 0.66 * f.scan)
                    .opacity(Motion.reduced ? 0 : f.scanOpacity)
                    .blendMode(.plusLighter)
            }
            .frame(width: size, height: size)
            .onAppear { play = true }
        } keyframes: { _ in
            KeyframeTrack(\.reveal) {
                LinearKeyframe(0, duration: 0.06)
                CubicKeyframe(1, duration: 0.46, startVelocity: 2)
            }
            KeyframeTrack(\.scan) {
                LinearKeyframe(0, duration: 0.06)
                CubicKeyframe(1, duration: 0.46, startVelocity: 2)
            }
            KeyframeTrack(\.scanOpacity) {
                LinearKeyframe(1, duration: 0.08)
                LinearKeyframe(1, duration: 0.36)
                CubicKeyframe(0, duration: 0.16)
            }
            KeyframeTrack(\.settle) {
                LinearKeyframe(0.92, duration: 0.5)
                SpringKeyframe(1.0, duration: 0.36, spring: .bouncy)
            }
            KeyframeTrack(\.ring) {
                CubicKeyframe(1, duration: 0.62, startVelocity: 2)
            }
        }
    }
}

// MARK: - Bluetooth

/// Repulsor link: rings pulse outward on connect, collapse inward on
/// disconnect. Direction carries the meaning, so the two read differently at a
/// glance without needing the label.
struct BluetoothActivity: View {
    var symbol: String
    var connected: Bool
    var size: CGFloat

    private static let stagger = 0.22

    private struct Frame {
        var wave = 0.0
        var glyph = 0.78
        var glow = 0.0
    }

    @State private var play = false

    var body: some View {
        KeyframeAnimator(initialValue: Frame(), trigger: play) { f in
            ZStack {
                if !Motion.reduced {
                    ForEach(0 ..< 3, id: \.self) { index in
                        let stagger = Double(index) * Self.stagger
                        let local = min(max(f.wave - stagger, 0), 1)
                        let scale = connected
                            ? 0.5 + local * 1.15          // outward on connect
                            : 1.65 - local * 1.15         // inward on disconnect
                        Circle()
                            .stroke(
                                connected ? Theme.core : Theme.gold.opacity(0.8),
                                lineWidth: size * 0.05
                            )
                            .scaleEffect(scale)
                            .opacity(local <= 0 ? 0 : (1 - local) * 0.75)
                    }
                }

                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(connected ? Theme.primary : Theme.tertiary)
                    .scaleEffect(Motion.reduced ? 1 : f.glyph)
                    .shadow(color: Theme.core.opacity(f.glow), radius: size * 0.22)
            }
            .frame(width: size, height: size)
            .onAppear { play = true }
        } keyframes: { _ in
            KeyframeTrack(\.wave) {
                // Runs to 1 + the last wave's stagger so every ring completes its
                // fade instead of freezing mid-way.
                CubicKeyframe(1.0 + Self.stagger * 2, duration: 1.05, startVelocity: 1.4, endVelocity: 0)
            }
            KeyframeTrack(\.glyph) {
                SpringKeyframe(1.06, duration: 0.3, spring: .bouncy)
                SpringKeyframe(1.0, duration: 0.28, spring: .snappy)
            }
            KeyframeTrack(\.glow) {
                CubicKeyframe(0.8, duration: 0.3)
                CubicKeyframe(0.0, duration: 0.65)
            }
        }
    }
}

// MARK: - Battery gauge

/// Battery with a fill that actually tracks the level.
///
/// Drawn rather than an SF Symbol: `battery.75` and friends quantise to four
/// steps, so the header icon looked identical from 97% down to 76%. The fill is
/// proportional and the colour carries the state - gold charging, red low, bone
/// otherwise.
struct BatteryGauge: View {
    var percent: Int
    var charging: Bool
    var low: Bool
    var width: CGFloat = 26

    private var height: CGFloat { width * 0.5 }
    private var fill: Color {
        if low { return Theme.core }
        if charging { return Theme.gold }
        return Color.white.opacity(0.85)
    }

    var body: some View {
        HStack(spacing: width * 0.06) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.32, style: .continuous)
                    .stroke(Theme.gold.opacity(0.5), lineWidth: max(1, width * 0.04))

                RoundedRectangle(cornerRadius: height * 0.2, style: .continuous)
                    .fill(fill)
                    .frame(width: max(0, (width - height * 0.36) * CGFloat(percent) / 100))
                    .padding(height * 0.16)

                if charging {
                    // White with a dark rim: a black bolt vanished against the
                    // empty cell at low charge, and a white one would wash out
                    // against a full gold cell without the rim.
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.58, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: height * 0.1)
                        .shadow(color: .black.opacity(0.6), radius: height * 0.22)
                        .frame(width: width, alignment: .center)
                }
            }
            .frame(width: width, height: height)

            // Terminal nub.
            RoundedRectangle(cornerRadius: height * 0.12, style: .continuous)
                .fill(Theme.gold.opacity(0.5))
                .frame(width: width * 0.05, height: height * 0.34)
        }
        // The level moves in single steps; spring it so it never jumps.
        .animation(Motion.content, value: percent)
        .animation(Motion.content, value: charging)
    }
}

// MARK: - Marquee

/// Scrolls text that does not fit, and stays still when it does.
///
/// Only ever mounted inside the expanded island, so the scroll runs while the
/// user is looking at it and stops the moment the island closes.
struct MarqueeText: View {
    var text: String
    var font: Font
    var color: Color

    @State private var textWidth: CGFloat = 0
    /// Measured, not assumed. This was a hard-coded 17pt, which is under the
    /// line height of the 14pt semibold title - so tall glyphs and digits were
    /// sliced off at the top by the `clipped()` below. A marquee has to clip
    /// horizontally; it must never clip vertically.
    @State private var textHeight: CGFloat = 17
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflows: Bool { textWidth > containerWidth + 1 }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 26) {
                label
                if overflows, !Motion.reduced { label }
            }
            .offset(x: offset)
            .onAppear {
                containerWidth = geo.size.width
                restart()
            }
        }
        .frame(height: textHeight)
        .clipped()
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear {
                        textWidth = proxy.size.width
                        textHeight = proxy.size.height
                    }
                }
            )
    }

    private func restart() {
        guard overflows, !Motion.reduced else { offset = 0; return }
        // Constant speed, so long titles are not faster than short ones.
        let distance = textWidth + 26
        let duration = Double(distance) / 32
        offset = 0
        withAnimation(.linear(duration: duration).delay(1.2).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }
}

/// Timer completion: the reactor pulses out once, like a discharge.
struct TimerDoneActivity: View {
    var size: CGFloat

    private struct Frame {
        var ring = 0.4
        var ringOpacity = 0.0
        var glyph = 0.7
    }

    @State private var play = false

    var body: some View {
        KeyframeAnimator(initialValue: Frame(), trigger: play) { f in
            ZStack {
                Circle()
                    .stroke(Theme.gold, lineWidth: size * 0.06)
                    .scaleEffect(Motion.reduced ? 1 : f.ring)
                    .opacity(Motion.reduced ? 0.4 : f.ringOpacity)
                Image(systemName: "timer")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Theme.core)
                    .scaleEffect(Motion.reduced ? 1 : f.glyph)
            }
            .frame(width: size, height: size)
            .onAppear { play = true }
        } keyframes: { _ in
            KeyframeTrack(\.ring) { CubicKeyframe(1.7, duration: 0.85, startVelocity: 2) }
            KeyframeTrack(\.ringOpacity) {
                LinearKeyframe(0.9, duration: 0.1)
                CubicKeyframe(0.0, duration: 0.75)
            }
            KeyframeTrack(\.glyph) {
                SpringKeyframe(1.12, duration: 0.3, spring: .bouncy)
                SpringKeyframe(1.0, duration: 0.3, spring: .snappy)
            }
        }
    }
}

// MARK: - Stats

// MARK: - Recording

/// The microphone going live, or letting go.
///
/// One glyph, one move. This used to draw a ring closing around an igniting dot
/// behind the microphone - three things animating to say one thing, which read
/// as decoration rather than as a state. Starting scales the microphone up and
/// settles it; stopping shrinks it away with a slash across it, so the direction
/// is legible without reading the label.
struct RecordingActivity: View {
    var started: Bool
    var size: CGFloat

    private let tint = Color(red: 1.0, green: 0.58, blue: 0.0)

    @State private var play = false

    var body: some View {
        KeyframeAnimator(initialValue: 0.6, trigger: play) { scale in
            Image(systemName: started ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(started ? tint : Theme.tertiary)
                .scaleEffect(Motion.reduced ? 1 : scale)
                .frame(width: size, height: size)
                .onAppear { play = true }
        } keyframes: { _ in
            if started {
                SpringKeyframe(1.12, duration: 0.26, spring: .bouncy)
                SpringKeyframe(1.0, duration: 0.28, spring: .snappy)
            } else {
                CubicKeyframe(1.0, duration: 0.18)
                CubicKeyframe(0.88, duration: 0.3)
            }
        }
    }
}

// MARK: - Screenshot

/// A shutter: the shot lands slightly large behind a white flash that clears off
/// it. One pass, no loop - the frame it settles on is the thumbnail.
struct ScreenshotActivity: View {
    var image: NSImage
    var size: CGFloat

    private struct Frame {
        var scale = 1.14
        var flash = 0.0
        var corner = 0.0
    }

    @State private var play = false

    var body: some View {
        KeyframeAnimator(initialValue: Frame(), trigger: play) { f in
            let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size * 0.72)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Theme.gold.opacity(0.5), lineWidth: 0.8))
                    .overlay(shape.fill(.white).opacity(Motion.reduced ? 0 : f.flash))
                    .scaleEffect(Motion.reduced ? 1 : f.scale)
            }
            .frame(width: size, height: size)
            .onAppear { play = true }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.0, duration: 0.42, spring: .bouncy)
            }
            KeyframeTrack(\.flash) {
                LinearKeyframe(0.85, duration: 0.06)
                CubicKeyframe(0.0, duration: 0.34)
            }
        }
    }
}

// MARK: - Utility

/// Receipt for a one-press action. Deliberately the plainest activity here: it
/// confirms something you just did on purpose, so it needs to be readable, not
/// impressive.
struct UtilityActivity: View {
    var symbol: String
    var size: CGFloat

    @State private var play = false

    var body: some View {
        KeyframeAnimator(initialValue: 0.7, trigger: play) { scale in
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(Theme.gold)
                .scaleEffect(Motion.reduced ? 1 : scale)
                .frame(width: size, height: size)
                .onAppear { play = true }
        } keyframes: { _ in
            SpringKeyframe(1.08, duration: 0.24, spring: .bouncy)
            SpringKeyframe(1.0, duration: 0.26, spring: .snappy)
        }
    }
}

// MARK: - Colour

/// The sampled colour, held in a ring that closes around it. Confirmation that
/// something specific went to the clipboard - the hex sits beside it.
struct ColorSwatchActivity: View {
    var swatch: NSColor
    var size: CGFloat

    @State private var play = false

    var body: some View {
        KeyframeAnimator(initialValue: 0.0, trigger: play) { ring in
            ZStack {
                Circle()
                    .fill(Color(nsColor: swatch))
                    .padding(size * 0.2)
                Circle()
                    .trim(from: 0, to: Motion.reduced ? 1 : ring)
                    .stroke(Theme.gold.opacity(0.8), style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
            .onAppear { play = true }
        } keyframes: { _ in
            CubicKeyframe(1, duration: 0.46, startVelocity: 2.5, endVelocity: 0)
        }
    }
}

/// A magnitude tile: label, thin meter, value.
///
/// Not a chart. Four numbers in a 40pt strip is the case where a stat tile beats
/// any plot - there is no trend to read, only a level.
///
/// The meter is sequential (one hue, magnitude) and switches to the status colour
/// only past the pressure threshold. Identity comes from the written label, never
/// from hue, so the row stays readable in any colour vision.
struct StatTile: View {
    var label: String
    var fraction: Double
    var value: String
    /// Above this the meter reads as pressure rather than level.
    var threshold: Double = 0.8

    private var meterColor: Color { fraction >= threshold ? Theme.core : Theme.gold }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .tracking(0.8)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                Text(value)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .monospacedDigit()
                    // No rolling digits: these change every second, and the roll
                    // re-rasterised the text on the CPU each time - measured, it
                    // was most of the open island's 20%.
                    // A stat that wraps takes its meter down half a line with it
                    // and breaks the one thing this row has going for it, which
                    // is that six of them scan as a single ruled band.
                    .lineLimit(1)
                    .fixedSize()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(meterColor)
                        .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 3)
        }
        .animation(Motion.content, value: fraction)
    }
}

/// Throughput reads as two directly-labelled numbers rather than a meter - there
/// is no ceiling to measure a network rate against.
struct ThroughputTile: View {
    var down: Double
    var up: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("NET")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .tracking(0.8)
            HStack(spacing: 9) {
                rate("arrow.down", SystemStats.rate(down))
                rate("arrow.up", SystemStats.rate(up))
                Spacer(minLength: 0)
            }
        }
    }

    private func rate(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Theme.gold)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.primary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct StatsStrip: View {
    var stats = SystemStats.shared
    var sensors = Sensors.shared

    var body: some View {
        // Tighter than it was, and throughput takes priority when the row runs
        // out of room: two rates side by side need real width, and a wrapped
        // "6.1 KB/s" reads as broken where a narrower meter just reads narrower.
        HStack(alignment: .top, spacing: 9) {
            StatTile(label: "CPU", fraction: stats.cpu, value: "\(Int(stats.cpu * 100))%")
            if let gpu = stats.gpu {
                StatTile(label: "GPU", fraction: gpu, value: "\(Int(gpu * 100))%")
            }
            StatTile(label: "RAM", fraction: stats.memory, value: stats.memoryUsed)
            // Higher threshold than the others: a disk at 80% is fine, a disk at
            // 90% is the one that starts costing you.
            // No layout priority. It is the widest value in the row and the
            // temptation is to hand it the slack, but priority does not mean
            // "enough" - it means "all of it", and this tile answered with a
            // meter five times longer than its neighbours. The `fixedSize` text
            // inside already sets a floor the stack has to honour, so it takes
            // what it needs and the row stays evenly ruled.
            StatTile(label: "DISK GB", fraction: stats.disk, value: stats.diskUsed, threshold: 0.9)
            // Degrees when the sensors answer, the system's own thermal state
            // when they do not - that fallback is public API and always right.
            StatTile(label: "TEMP", fraction: sensors.fraction, value: sensors.text, threshold: 0.75)
            // Fixed, not flexible: this tile holds two labelled rates side by
            // side and has no meter to shrink. Left to negotiate it either wraps
            // "6.1 KB/s" onto two lines or - given priority - swallows the whole
            // row, because the spacer inside it will take any width offered.
            ThroughputTile(down: stats.down, up: stats.up)
                .frame(width: 132, alignment: .leading)
        }
    }
}
