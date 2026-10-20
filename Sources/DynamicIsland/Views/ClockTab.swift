import SwiftUI

/// Timer, stopwatch, alarms and world clocks.
///
/// macOS ships Clock.app but exposes no URL scheme and no AppleScript
/// dictionary for it, so there is nothing to hand off to - this is built here
/// instead.
struct ClockTab: View {
    enum Mode: String, CaseIterable, Identifiable {
        case timer, stopwatch, alarm, world
        var id: String { rawValue }
        var title: String {
            switch self {
            case .timer: "Timer"
            case .stopwatch: "Stopwatch"
            case .alarm: "Alarms"
            case .world: "World"
            }
        }
    }

    @State private var mode: Mode = .timer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SegmentedRow(mode: $mode).staggered(0)

            Group {
                switch mode {
                case .timer: TimerPane()
                case .stopwatch: StopwatchPane()
                case .alarm: AlarmPane()
                case .world: WorldPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .staggered(1)
        }
    }
}

private struct SegmentedRow: View {
    @Binding var mode: ClockTab.Mode
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ClockTab.Mode.allCases) { item in
                Segment(title: item.title, selected: mode == item, indicator: indicator) {
                    withAnimation(Motion.content) { mode = item }
                }
            }
        }
    }
}

struct Segment: View {
    var title: String
    var selected: Bool
    var indicator: Namespace.ID
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selected ? Theme.primary : Theme.tertiary)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background {
                    if selected {
                        Capsule().fill(Color.white.opacity(0.12))
                            .matchedGeometryEffect(id: "segment", in: indicator)
                    } else if hovering {
                        Capsule().fill(Color.white.opacity(0.05))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .hoverHighlight($hovering)
    }
}

// MARK: - Shared chrome

/// Neutral chip. The old presets were tinted fills of the accent, which on black
/// read as dark red blobs rather than buttons.
private struct Chip: View {
    var title: String
    var prominent = false
    var wide = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(prominent ? Theme.notchBlack : (hovering ? Theme.gold : Theme.secondary))
                .frame(maxWidth: wide ? .infinity : nil)
                .padding(.vertical, 6)
                .padding(.horizontal, wide ? 6 : 13)
                .background(
                    Capsule().fill(prominent ? AnyShapeStyle(Theme.gold) : AnyShapeStyle(Color.white.opacity(0.05)))
                )
                .overlay(
                    // Gold hairline: reads as part of the reactor rather than a
                    // grey system button dropped on black.
                    Capsule().strokeBorder(
                        prominent ? .clear : Theme.gold.opacity(hovering ? 0.75 : 0.32),
                        lineWidth: 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.94))
        .hoverHighlight($hovering)
    }
}

/// The big readout every pane shares.
private struct Readout: View {
    var text: String
    var dim: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 34, weight: .light, design: .rounded))
            .foregroundStyle(dim ? Theme.tertiary : Theme.primary)
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}

/// Permission notice that does something.
///
/// The old ones were grey sentences telling you to go to System Settings - true,
/// but a dead end. These open the exact pane.
struct PermissionNotice: View {
    var message: String
    var action: String
    var url: String
    var onTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.gold)
            Text(message)
                .font(TypeScale.caption)
                .foregroundStyle(Theme.secondary)
            Button(action: open) {
                Text(action)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notchBlack)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 9)
                    .background(Capsule().fill(Theme.gold))
            }
            .buttonStyle(Pressable(scale: 0.93))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.gold.opacity(0.08))
        )
    }

    private func open() {
        if let onTap { onTap(); return }
        if let link = URL(string: url) { NSWorkspace.shared.open(link) }
    }
}

// MARK: - Timer

private struct TimerPane: View {
    var timer = CountdownTimer.shared

    /// Enough steps that any everyday duration is one tap, and the row still
    /// fills the panel rather than leaving half of it empty.
    private let presets: [Double] = [1, 3, 5, 10, 15, 25, 45]

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            // Ticks only while counting; a paused or idle dial redraws on change.
            TimelineView(.periodic(from: .now, by: timer.running && !timer.paused ? 1 : 3600)) { _ in
                TimerDial(progress: timer.progress,
                          text: timer.running || timer.paused ? timer.text : "0:00",
                          caption: caption,
                          live: timer.running && !timer.paused,
                          dim: !(timer.running || timer.paused))
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { minutes in
                        Chip(title: "\(Int(minutes))", wide: true) {
                            withAnimation(Motion.content) { timer.start(minutes: minutes) }
                        }
                    }
                }

                HStack(spacing: 7) {
                    if timer.running || timer.paused {
                        Chip(title: timer.paused ? "Resume" : "Pause", prominent: true) {
                            withAnimation(Motion.content) { timer.paused ? timer.resume() : timer.pause() }
                        }
                        Chip(title: "+1") { timer.extend(minutes: 1) }
                        Chip(title: "+5") { timer.extend(minutes: 5) }
                        Chip(title: "Cancel") { withAnimation(Motion.content) { timer.cancel() } }
                    } else {
                        Text("Minutes - runs on after you quit")
                            .font(TypeScale.caption)
                            .foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var caption: String {
        if timer.paused { return "paused" }
        if timer.running { return "remaining" }
        return "pick a length"
    }
}

/// Arc reactor as the dial: gold housing, red charge, glowing core.
private struct TimerDial: View {
    var progress: Double
    var text: String
    var caption: String
    var live: Bool
    var dim: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Theme.core.opacity(dim ? 0.05 : 0.20), .clear],
                    center: .center, startRadius: 2, endRadius: 62
                ))

            Circle()
                .stroke(Theme.gold.opacity(dim ? 0.22 : 0.4), lineWidth: 1)
                .padding(2)

            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 6)
                .padding(8)

            // No floor on the trim: a rounded cap on a zero-length arc drew a
            // stray dot at the top of an idle dial.
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [Theme.gold, Theme.core, Theme.gold]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(8)
                .shadow(color: Theme.core.opacity(live ? 0.5 : 0), radius: 5)
                .animation(Motion.content, value: progress)

            VStack(spacing: -1) {
                Text(text)
                    .font(.system(size: 27, weight: .medium, design: .rounded))
                    .foregroundStyle(dim ? Theme.tertiary : Theme.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(dim ? Theme.tertiary : Theme.gold)
                    .tracking(1)
            }
        }
        .frame(width: 124, height: 124)
    }
}

// MARK: - Stopwatch

private struct StopwatchPane: View {
    var watch = Stopwatch.shared

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                TimelineView(.periodic(from: .now, by: watch.running ? 0.05 : 3600)) { _ in
                    Text(Stopwatch.text(watch.elapsed))
                        .font(.system(size: 40, weight: .light, design: .rounded))
                        .foregroundStyle(watch.running ? Theme.primary : Theme.secondary)
                        .monospacedDigit()
                        // Digits are fixed width, so the readout never jitters as
                        // hundredths roll over.
                        .contentTransition(.numericText())
                }
                HStack(spacing: 7) {
                    Chip(title: watch.running ? "Stop" : "Start", prominent: true) {
                        withAnimation(Motion.content) { watch.toggle() }
                    }
                    Chip(title: "Lap") { withAnimation(Motion.content) { watch.lap() } }
                    Chip(title: "Reset") { withAnimation(Motion.content) { watch.reset() } }
                }
            }
            .frame(width: 240, alignment: .leading)

            if watch.laps.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.gold.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .overlay(
                        Text("Laps appear here")
                            .font(TypeScale.body)
                            .foregroundStyle(Theme.tertiary)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    // Two columns so laps fill the panel rather than running down
                    // a 110pt strip with the rest empty.
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 3) {
                        ForEach(Array(watch.laps.enumerated()), id: \.offset) { index, lap in
                            HStack(spacing: 8) {
                                Text("\(watch.laps.count - index)")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.gold)
                                    .frame(width: 18, alignment: .trailing)
                                Text(Stopwatch.text(lap))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(index == 0 ? Theme.primary : Theme.secondary)
                                    .monospacedDigit()
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(index == 0 ? 0.07 : 0.03))
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Alarms

private struct AlarmPane: View {
    var alarms = Alarms.shared
    @State private var draft = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now) ?? .now

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                TimeStepper(date: $draft)
                Chip(title: "Add", prominent: true) {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: draft)
                    withAnimation(Motion.content) {
                        alarms.add(hour: parts.hour ?? 7, minute: parts.minute ?? 0)
                    }
                }
                Spacer(minLength: 0)
                if let next = alarms.next, next.enabled {
                    VStack(alignment: .trailing, spacing: -1) {
                        Text("NEXT").font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.tertiary).tracking(1)
                        Text(next.time)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.core)
                            .monospacedDigit()
                    }
                }
            }

            if !alarms.authorized {
                PermissionNotice(
                    message: "Alarms need notification permission",
                    action: "Allow",
                    url: "",
                    onTap: { alarms.requestAccess() }
                )
            }

            if alarms.items.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.gold.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .overlay(
                        Text("No alarms yet - pick a time and add one")
                            .font(TypeScale.body)
                            .foregroundStyle(Theme.tertiary)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Two columns, so a handful of alarms fills the width instead of
                // stacking down one edge.
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 5) {
                        ForEach(alarms.items) { AlarmRow(alarm: $0) }
                    }
                }
            }
        }
    }
}

/// Themed hour/minute stepper. The system `DatePicker` field is a grey box that
/// reads as someone else's control dropped into the island.
private struct TimeStepper: View {
    @Binding var date: Date

    private var parts: (hour: Int, minute: Int) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0, c.minute ?? 0)
    }

    var body: some View {
        HStack(spacing: 3) {
            field(String(format: "%02d", parts.hour), up: { shift(hours: 1) }, down: { shift(hours: -1) })
            Text(":").font(.system(size: 17, weight: .medium, design: .rounded)).foregroundStyle(Theme.tertiary)
            field(String(format: "%02d", parts.minute), up: { shift(minutes: 5) }, down: { shift(minutes: -5) })
        }
    }

    private func field(_ text: String, up: @escaping () -> Void, down: @escaping () -> Void) -> some View {
        VStack(spacing: 1) {
            arrow("chevron.up", up)
            Text(text)
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
            arrow("chevron.down", down)
        }
        .frame(width: 40)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.gold.opacity(0.28), lineWidth: 1)
                )
        )
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.gold)
                .frame(width: 34, height: 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.9))
    }

    private func shift(hours: Int = 0, minutes: Int = 0) {
        let calendar = Calendar.current
        if hours != 0 { date = calendar.date(byAdding: .hour, value: hours, to: date) ?? date }
        if minutes != 0 { date = calendar.date(byAdding: .minute, value: minutes, to: date) ?? date }
    }
}

private struct AlarmRow: View {
    var alarm: Alarms.Alarm
    var alarms = Alarms.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(alarm.time)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(alarm.enabled ? Theme.primary : Theme.tertiary)
                .monospacedDigit()
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { alarm.enabled }, set: { _ in alarms.toggle(alarm) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.core)
            Button { withAnimation(Motion.content) { alarms.remove(alarm) } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovering ? Theme.core : Theme.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.07 : 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(alarm.enabled ? Theme.gold.opacity(0.22) : .clear, lineWidth: 1)
                )
        )
        .hoverHighlight($hovering)
    }
}

// MARK: - World

private struct WorldPane: View {
    private var zones: [TimeZone] {
        // Local is always first, so a saved clock for the zone you are in would
        // be a second card with the same id.
        [TimeZone.current] + Settings.shared.worldClocks.compactMap(TimeZone.init(identifier:))
            .filter { $0.identifier != TimeZone.current.identifier }
    }

    var body: some View {
        // One tick every 30s is plenty for wall clocks.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 10) {
                ForEach(zones, id: \.identifier) { zone in
                    ZoneCard(zone: zone, now: context.date)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct ZoneCard: View {
    var zone: TimeZone
    var now: Date

    private var isLocal: Bool { zone.identifier == TimeZone.current.identifier }

    private var offsetText: String {
        let delta = (zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 60
        if delta == 0 { return "Local time" }
        let sign = delta > 0 ? "+" : "-"
        let magnitude = abs(delta)
        let value = magnitude % 60 == 0
            ? "\(magnitude / 60)h"
            : String(format: "%d:%02dh", magnitude / 60, magnitude % 60)
        return "\(sign)\(value) from you"
    }

    private var hour: Int {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return calendar.component(.hour, from: now)
    }

    /// Daylight at a glance, so a time abroad reads without arithmetic.
    private var isNight: Bool { hour < 6 || hour >= 19 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: isNight ? "moon.stars.fill" : "sun.max.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isNight ? Theme.secondary : Theme.gold)
                Text(city)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
            }
            Text(now.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))
                .font(.system(size: 26, weight: .light, design: .rounded))
                .foregroundStyle(Theme.primary)
                .monospacedDigit()
            Text(offsetText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(isLocal ? Theme.tertiary : Theme.gold)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(minWidth: 128, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(isLocal ? Theme.gold.opacity(0.3) : Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }

    private var city: String {
        zone.identifier.split(separator: "/").last
            .map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
    }
}
