import AVFoundation
import AppKit

/// A mirror, for checking how you look before joining a call.
///
/// The session exists only while the window is open. Closing it tears the whole
/// thing down - no retained session, no capture device held, and the green LED
/// beside the camera goes out, which is the only honest way to ship this.
///
/// Idea borrowed from Vorssaint's camera preview; implementation here is this
/// project's own.
@MainActor
final class CameraPreview: NSObject {
    static let shared = CameraPreview()

    private var window: NSWindow?
    private var session: AVCaptureSession?

    private override init() { super.init() }

    var isOpen: Bool { window != nil }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard window == nil else { return }

        // Asking here rather than at launch, and only because the user pressed
        // the tile. Denied is a normal answer, not an error to retry.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            present()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in if granted { self.present() } else { self.refused() } }
            }
        default:
            refused()
        }
    }

    private func refused() {
        HUD.shared.show(
            .utility(symbol: "video.slash.fill",
                     title: "Camera is off",
                     detail: Permissions.detail(for: "Camera")),
            for: 3.0
        )
        Permissions.open("Privacy_Camera")
    }

    private func present() {
        guard window == nil,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { refused(); return }

        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { refused(); return }
        session.addInput(input)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill

        let size = NSSize(width: 320, height: 240)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Mirror"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let host = MirrorView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer = layer
        // Mirrored, because a preview of your own face that is not mirrored
        // reads as someone else's video call.
        host.layer?.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        host.onEscape = { [weak self] in self?.close() }
        panel.contentView = host

        // Near the notch it was opened from rather than screen centre - which
        // means the display the pointer is on, not whichever one is "main".
        if let screen = NSScreen.underPointer {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 12
            ))
        }

        self.session = session
        self.window = panel
        panel.orderFrontRegardless()
        panel.makeKey()

        // Starting the session blocks briefly while the camera warms up.
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func close() {
        session?.stopRunning()
        // Inputs are removed explicitly: a retained session with a live input is
        // how an app ends up holding the camera open after its window is gone.
        if let session {
            for input in session.inputs { session.removeInput(input) }
        }
        session = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }
}

extension CameraPreview: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.close() }
    }
}

/// Escape closes it, the same key that closes the island.
private final class MirrorView: NSView {
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}
