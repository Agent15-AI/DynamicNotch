import AppKit
import CoreGraphics
import Foundation

/// Select an area of the screen, get its text on the clipboard.
///
/// Two processes, neither of which is this one. `screencapture` draws the
/// selection - the system's own crosshair, which everyone already knows and
/// which does the capture under its own entitlement rather than ours. Then
/// `di-ocr` reads the file and exits, taking Vision's model memory with it.
///
/// Nothing here runs at rest, and the island's own resident size never moves:
/// measured, the recogniser peaks near 96 MB and the island stays at 19.
///
/// Idea borrowed from Vorssaint's copy-text-from-screen; implementation is this
/// project's own.
@MainActor
@Observable
final class ScreenOCR {
    static let shared = ScreenOCR()

    private(set) var running = false

    private init() {}

    var available: Bool { Bundle.main.path(forResource: "di-ocr", ofType: nil) != nil }

    /// Whether macOS will let us capture. Public API, and it does not prompt -
    /// so the permission can be checked before anything is spawned.
    ///
    /// This is needed: `screencapture` does *not* carry its own entitlement when
    /// spawned by another app. It inherits ours and exits 1 with no file, which
    /// is indistinguishable from the user pressing Escape. Measured, not assumed.
    var authorized: Bool { CGPreflightScreenCaptureAccess() }

    func capture() {
        guard !running, let helper = Bundle.main.path(forResource: "di-ocr", ofType: nil) else { return }

        guard authorized else {
            // Ask once, then point at the pane. macOS only shows its own dialog
            // the first time; after that the switch has to be flipped by hand.
            // Asking is what registers the app in the pane at all, so it goes
            // first even when the answer is already recorded.
            let asked = CGRequestScreenCaptureAccess()
            HUD.shared.show(
                .utility(symbol: "lock.fill",
                         title: asked ? "Screen Recording allowed" : "Screen Recording is off",
                         detail: asked
                             ? "Try again"
                             : Permissions.detail(for: "Dynamic Island")),
                for: 3.4
            )
            if !asked { Permissions.open("Privacy_ScreenCapture") }
            return
        }
        running = true

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("di-ocr-\(UUID().uuidString).png")

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive selection, -x no shutter sound, -o no window shadow.
        capture.arguments = CommandLine.arguments.contains("--ocr-fixed")
            ? ["-x", "-R100,100,900,400", destination.path]
            : ["-i", "-x", "-o", destination.path]
        capture.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.recognise(at: destination, helper: helper, cancelled: process.terminationStatus != 0)
            }
        }

        do { try capture.run() } catch {
            running = false
            HUD.shared.show(
                .utility(symbol: "exclamationmark.triangle.fill",
                         title: "Could not start capture", detail: error.localizedDescription),
                for: 2.6
            )
        }
    }

    private func recognise(at url: URL, helper: String, cancelled: Bool) {
        // Escape during selection leaves no file behind; that is a cancel, not
        // a failure, and deserves no alert.
        guard !cancelled, FileManager.default.fileExists(atPath: url.path) else {
            running = false
            try? FileManager.default.removeItem(at: url)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = [url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            var text = ""
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            try? FileManager.default.removeItem(at: url)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.running = false
                    guard !text.isEmpty else {
                        HUD.shared.show(
                            .utility(symbol: "text.viewfinder", title: "No text found",
                                     detail: "Nothing readable in that area"),
                            for: 2.4
                        )
                        return
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    let lines = text.split(separator: "\n").count
                    HUD.shared.show(
                        .utility(symbol: "text.viewfinder",
                                 title: text.split(separator: "\n").first.map(String.init) ?? "Copied",
                                 detail: lines == 1 ? "Copied" : "\(lines) lines copied"),
                        for: 2.8
                    )
                }
            }
        }
    }
}
