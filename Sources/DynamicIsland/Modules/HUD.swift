import AppKit
import Foundation
import UniformTypeIdentifiers

/// Transient overlays shown in the collapsed island - volume, mute, plug/unplug.
///
/// Each show schedules one cancellable dismiss. No repeating timer.
@MainActor
@Observable
final class HUD {
    static let shared = HUD()

    enum Kind: Equatable {
        case charging(percent: Int, plugged: Bool)
        /// `battery` when the accessory reports one - see `DeviceBatteries`.
        case bluetooth(name: String, symbol: String, connected: Bool, battery: Int? = nil)
        case download(name: String, icon: NSImage)
        case track(title: String, subtitle: String, art: NSImage?)
        case timer
        case alarm(label: String)
        case welcome
        case recording(app: String?, started: Bool)
        case screenshot(name: String, image: NSImage, url: URL)
        case color(hex: String, swatch: NSColor)
        /// Receipt for a one-press action, so nothing the user triggers is silent.
        case utility(symbol: String, title: String, detail: String)
        /// A mounted disk image holding exactly one app, offered for install.
        case install(name: String, icon: NSImage)
        /// A calendar event about to start. Clicking joins the call, if it has one.
        case upcoming(title: String, detail: String, joinURL: URL?)
        /// A one-time code found in copied text. Clicking copies the digits alone.
        case verification(code: String)
        /// Look away until this date. See `EyeBreak`.
        case eyeBreak(until: Date)
    }

    /// What clicking the closed island does while this activity is up, for the
    /// activities that are offers rather than news. The screenshot is handled
    /// separately, because it is dragged rather than clicked.
    var clickAction: (@MainActor () -> Void)? {
        switch current {
        case .install: { DiskImages.shared.install() }
        case .upcoming(_, _, let url):
            { NSWorkspace.shared.open(url ?? URL(string: "ical://")!) }
        case .verification(let code):
            {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                // Our own write must not come back round as a new clip, or the
                // code is announced again the next time the pasteboard is read.
                Clipboard.shared.lastChange = NSPasteboard.general.changeCount
                HUD.shared.show(.utility(symbol: "number", title: code, detail: "Copied"), for: 1.6)
            }
        // Clicking ends the break early - a reminder you cannot dismiss is a
        // reminder people switch off.
        case .eyeBreak: { EyeBreak.shared.skip() }
        default: nil
        }
    }

    /// The screenshot activity is the one kind that is worth grabbing rather than
    /// just reading, so the container view has to know when it is up.
    var screenshotURL: URL? {
        if case .screenshot(_, _, let url) = current { return url }
        return nil
    }

    private(set) var current: Kind?

    private var dismiss: DispatchWorkItem?

    private init() {}

    func show(_ kind: Kind, for seconds: TimeInterval = 1.4) {
        current = kind
        dismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.current = nil }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Plays each live activity in turn. Cheap way to see them without waiting
    /// for a cable, a device, or a download.
    func preview() {
        show(.charging(percent: 82, plugged: true), for: 2.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            self.show(
                .bluetooth(name: "AirPods Pro", symbol: "headphones", connected: true, battery: 85),
                for: 2.4
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
            let icon = NSWorkspace.shared.icon(for: .pdf)
            self.show(.download(name: "Report.pdf", icon: icon), for: 2.6)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            self.show(.recording(app: "FaceTime", started: true), for: 2.4)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.6) {
            let shot = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)
                ?? NSWorkspace.shared.icon(for: .png)
            self.show(.screenshot(name: "Screenshot.png", image: shot, url: URL(fileURLWithPath: "/")), for: 2.8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13.6) {
            self.show(.color(hex: "#E03429", swatch: .systemRed), for: 2.6)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 21.6) {
            self.show(.upcoming(title: "Design review", detail: "In 5 min · 10:00 AM · Join", joinURL: nil), for: 2.6)
        }
    }
}
