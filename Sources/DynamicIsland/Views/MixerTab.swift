import SwiftUI

/// Per-app volume.
///
/// One row per app that holds an audio connection, whether or not it is making a
/// sound right now - an app that goes quiet for a second must not vanish from
/// under the pointer mid-drag.
///
/// The slider is the system's own. It is keyboard-operable and accessible for
/// free, which a hand-drawn bar is not, and this is a control people will drag
/// precisely rather than glance at.
struct MixerTab: View {
    var mixer = VolumeMixer.shared
    var audio = AudioMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("APP VOLUME").sectionLabel()
                Spacer(minLength: 0)
                if mixer.isRouting {
                    // Naming the cost where the cost is incurred.
                    Text("Re-routing audio")
                        .font(TypeScale.caption)
                        .foregroundStyle(Theme.gold)
                }
            }
            .staggered(0)

            if !VolumeMixer.isSupported {
                EmptyState(symbol: "speaker.slash",
                           title: "Needs macOS 14.4",
                           detail: "Process taps arrived in that release")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !Settings.shared.mixer {
                EmptyState(symbol: "speaker.slash",
                           title: "Turned off",
                           detail: "Switch it on in Settings ▸ Modules")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mixer.apps.isEmpty {
                EmptyState(symbol: "speaker.wave.2",
                           title: "Nothing playing",
                           detail: "Apps appear once they open audio")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(mixer.apps.enumerated()), id: \.element.id) { index, app in
                            MixerRow(app: app).staggered(min(index + 1, 6))
                        }
                    }
                }
            }
        }
        // Rebuilt when the tab appears and whenever the set of audio processes
        // changes - never on a timer.
        .onAppear { mixer.refresh() }
        .onChange(of: audio.outputChangeCount) { mixer.refresh() }
        .onChange(of: audio.processChangeCount) { mixer.refresh() }
    }
}

private struct MixerRow: View {
    var app: VolumeMixer.App
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 22, height: 22)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.shell)
                        .frame(width: 22, height: 22)
                }
                // A quiet app still gets a row, so the dot is what says which
                // one you are actually hearing.
                if app.playing {
                    Circle()
                        .fill(Theme.core)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Theme.notchBlack, lineWidth: 1.2))
                        .offset(x: 2, y: 2)
                }
            }

            Text(app.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .frame(width: 116, alignment: .leading)

            Slider(
                value: Binding(
                    get: { app.volume },
                    set: { VolumeMixer.shared.setVolume($0, for: app) }
                ),
                in: 0 ... VolumeMixer.maximumGain
            )
            .controlSize(.mini)
            // Gold past unity: the range above 100% is a different thing from
            // the range below it, and the colour is what says so mid-drag.
            .tint(app.volume > 1.001 ? Theme.gold : Theme.core)

            Text("\(Int((app.volume * 100).rounded()))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(level)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)

            RouteButton(app: app)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.05) : .clear)
        )
        .hoverHighlight($hovering)
        .help(help)
    }

    private var level: Color {
        if app.volume > 1.001 { return Theme.gold }
        return app.volume < 0.999 ? Theme.primary : Theme.tertiary
    }

    private var help: String {
        if let route = app.route,
           let name = VolumeMixer.shared.outputs.first(where: { $0.uid == route })?.name {
            return "\(app.name) → \(name)"
        }
        return app.volume < 0.999 || app.volume > 1.001
            ? "\(app.name) is being re-routed" : app.name
    }
}

/// Sends one app to a chosen output.
///
/// A menu rather than a picker: the row is already dense, and the device list is
/// short enough that a popup is faster than a control that has to display the
/// current value inline.
private struct RouteButton: View {
    var app: VolumeMixer.App
    @State private var hovering = false

    var body: some View {
        Button(action: present) {
            Image(systemName: app.route == nil ? "hifispeaker" : "hifispeaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(app.route == nil
                    ? (hovering ? Theme.primary : Theme.tertiary)
                    : Theme.gold)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .hoverHighlight($hovering)
        .help("Send to a specific output")
    }

    private func present() {
        let menu = NSMenu()
        let system = NSMenuItem(title: "System output", action: nil, keyEquivalent: "")
        system.state = app.route == nil ? .on : .off
        system.target = RouteMenuTarget.shared
        system.action = #selector(RouteMenuTarget.pick(_:))
        system.representedObject = RouteMenuTarget.Choice(app: app, uid: nil)
        menu.addItem(system)
        menu.addItem(.separator())

        for output in VolumeMixer.shared.outputs {
            let item = NSMenuItem(title: output.name, action: nil, keyEquivalent: "")
            item.state = app.route == output.uid ? .on : .off
            item.target = RouteMenuTarget.shared
            item.action = #selector(RouteMenuTarget.pick(_:))
            item.representedObject = RouteMenuTarget.Choice(app: app, uid: output.uid)
            menu.addItem(item)
        }
        // Screen coordinates: the panel is not key, so there is no reliable view
        // to anchor to.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

@MainActor
private final class RouteMenuTarget: NSObject {
    static let shared = RouteMenuTarget()

    final class Choice: NSObject {
        let app: VolumeMixer.App
        let uid: String?
        init(app: VolumeMixer.App, uid: String?) { self.app = app; self.uid = uid }
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        VolumeMixer.shared.setRoute(choice.uid, for: choice.app)
    }
}
