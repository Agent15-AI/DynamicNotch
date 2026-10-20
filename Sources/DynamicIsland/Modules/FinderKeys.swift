import AppKit
import Carbon.HIToolbox

/// ⌘X to cut files in the Finder, F2 to rename, and an image on the clipboard
/// pasted as a PNG file.
///
/// ponytail: the Finder can already move on paste - that is what ⌥⌘V, "Move
/// Item Here", does. Nothing here moves a file. ⌘X presses ⌘C and remembers,
/// ⌘V presses ⌥⌘V, and the whole feature is a remap of two keys onto a command
/// Apple shipped but hid behind a modifier nobody finds. Apple's objection to a
/// real cut is that a file in the cut state is a file that can be lost if you
/// never paste; this inherits the copy semantics and so inherits the answer -
/// forget to paste and nothing happened.
///
/// **The keys are registered only while the Finder is in front**, on
/// `didActivateApplication`, and unregistered when it leaves. A global ⌘X and
/// ⌘V would take those keys from every other app on the Mac. That is also why
/// this needs no event tap: the one thing that would make it cost a wakeup per
/// keystroke is the one thing it does not do.
@MainActor
final class FinderKeys {
    static let shared = FinderKeys()

    private static let finder = "com.apple.finder"

    private var cutRef: EventHotKeyRef?
    private var pasteRef: EventHotKeyRef?
    private var renameRef: EventHotKeyRef?
    private var installed = false
    private var active = false
    /// Set by ⌘X, cleared by the paste that consumes it or by leaving the Finder.
    private var cutPending = false

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true

        // A handler of our own rather than a branch in `Hotkeys`: these keys
        // come and go with the frontmost app, and the ids are ours alone.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let signature = id.id
            guard (60...62).contains(signature) else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in FinderKeys.shared.fire(signature) }
            return noErr
        }, 1, &spec, nil, nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { FinderKeys.shared.frontChanged(to: app) }
        }
        frontChanged(to: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func settingChanged() {
        frontChanged(to: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func frontChanged(to bundleID: String?) {
        let wanted = Settings.shared.finderKeys && bundleID == Self.finder
        guard wanted != active else { return }
        active = wanted
        if wanted {
            register(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey), id: 60, into: &cutRef)
            register(keyCode: UInt32(kVK_F2), modifiers: 0, id: 62, into: &renameRef)
            // Only claimed when it has something to do - see `armPaste`.
            armPaste()
        } else {
            cutPending = false
            unregister(&cutRef)
            unregister(&renameRef)
            unregister(&pasteRef)
        }
    }

    /// ⌘V is taken over only when a cut is waiting, or when the clipboard holds
    /// an image that the Finder would otherwise refuse to paste.
    ///
    /// This is the whole reason there is no keystroke loop here. A registered
    /// ⌘V that re-posts ⌘V would catch its own synthetic keystroke forever;
    /// neither path does that. The cut path unregisters before it posts ⌥⌘V,
    /// and the image path writes a file and posts nothing at all.
    private func armPaste() {
        guard active else { return }
        if cutPending || pastableImage() != nil {
            register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey), id: 61, into: &pasteRef)
        } else {
            unregister(&pasteRef)
        }
    }

    private func fire(_ signature: UInt32) {
        switch signature {
        case 60: cut()
        case 61: paste()
        case 62: press(CGKeyCode(kVK_Return), flags: [])   // the Finder renames on Return
        default: break
        }
    }

    private func cut() {
        press(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        cutPending = true
        armPaste()
        HUD.shared.show(.utility(symbol: "scissors", title: "Cut", detail: "⌘V moves it"), for: 1.4)
        // A cut left unpasted should not turn the next ordinary paste into a
        // move ten minutes later.
        let work = DispatchWorkItem { MainActor.assumeIsolated { FinderKeys.shared.expireCut() } }
        cutExpiry?.cancel()
        cutExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
    }

    private var cutExpiry: DispatchWorkItem?

    private func expireCut() {
        cutPending = false
        armPaste()
    }

    private func paste() {
        if cutPending {
            cutPending = false
            cutExpiry?.cancel()
            // Unregistered *before* posting, so the synthetic ⌥⌘V is not caught
            // by this same handler.
            unregister(&pasteRef)
            press(CGKeyCode(kVK_ANSI_V), flags: [.maskCommand, .maskAlternate])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.armPaste() }
            return
        }
        guard let image = pastableImage() else {
            // Nothing for us to do; hand the keystroke back.
            unregister(&pasteRef)
            press(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.armPaste() }
            return
        }
        writePNG(image)
    }

    /// An image on the clipboard that is not already a file. Copying a PNG in
    /// the Finder puts both a file URL and image data on the pasteboard, and in
    /// that case the Finder's own paste is the right one.
    private func pastableImage() -> NSImage? {
        let pasteboard = NSPasteboard.general
        let files = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard files?.isEmpty != false else { return nil }
        return NSImage(pasteboard: pasteboard)
    }

    /// Writes the clipboard image into the folder the Finder is showing.
    ///
    /// The folder comes from the Finder itself, which needs the Apple Events
    /// permission macOS asks for the first time this runs. Refused, the file
    /// goes to the Desktop and the receipt says where - better than a keystroke
    /// that silently does nothing.
    private func writePNG(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }

        let folder = finderFolder() ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard let folder else { return }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var url = folder.appendingPathComponent("Pasted \(stamp.string(from: .now)).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Pasted \(stamp.string(from: .now)) \(counter).png")
            counter += 1
        }
        guard (try? png.write(to: url, options: .atomic)) != nil else {
            HUD.shared.show(.utility(symbol: "exclamationmark.triangle.fill", title: "Could not write",
                                     detail: folder.lastPathComponent), for: 2.2)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        HUD.shared.show(.utility(symbol: "photo.on.rectangle", title: "Pasted as PNG",
                                 detail: url.lastPathComponent), for: 1.8)
    }

    private func finderFolder() -> URL? {
        let script = """
        tell application "Finder"
            if (count of windows) is 0 then return POSIX path of (path to desktop)
            return POSIX path of (target of front window as alias)
        end tell
        """
        var error: NSDictionary?
        guard let path = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
              error == nil
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Keys

    private func press(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, into ref: inout EventHotKeyRef?) {
        guard ref == nil else { return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4449464B), id: id)   // 'DIFK'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregister(_ ref: inout EventHotKeyRef?) {
        guard let existing = ref else { return }
        UnregisterEventHotKey(existing)
        ref = nil
    }
}
