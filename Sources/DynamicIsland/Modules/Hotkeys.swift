import AppKit
import Carbon.HIToolbox

/// Keyboard access to the island.
///
/// Carbon hot keys rather than an event tap or a key monitor: the system
/// delivers only the exact combination registered, so nothing sees the rest of
/// your typing and there is no per-keystroke wakeup.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()

    private var openRef: EventHotKeyRef?
    private var barRef: EventHotKeyRef?
    private var closeRef: EventHotKeyRef?
    private var menuBarRef: EventHotKeyRef?
    private var plainPasteRef: EventHotKeyRef?
    private var installed = false

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            // `FinderKeys` registers on the same target. Claiming its presses
            // here would leave them reaching it only by handler order.
            guard id.signature == OSType(0x44594E49) else { return OSStatus(eventNotHandledErr) }
            let signature = id.id
            Task { @MainActor in Hotkeys.shared.fire(signature) }
            return noErr
        }, 1, &spec, nil, nil)

        // Command-Control-N toggles the island. Deliberately not Command-Shift-I:
        // that is Chrome's DevTools shortcut, and the frontmost app wins it.
        register(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | controlKey), id: 1, into: &openRef)
        // Option-Space opens the command bar. Not Command-Space, which is
        // Spotlight's and would be taken by the system before we ever saw it.
        register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), id: 3, into: &barRef)
        // Command-Control-B shows or hides the menu bar icons. Worth a global
        // key of its own: while they are hidden the divider is blank, so a
        // keyboard route back is the one that cannot be mis-aimed.
        register(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | controlKey), id: 4, into: &menuBarRef)
        setPlainPasteActive(Settings.shared.plainPaste)
        setCalculatorActive(Settings.shared.calculator)
    }

    // MARK: - Double-tap right Option

    /// Two quick taps of the right ⌥ open the calculator.
    ///
    /// The one thing in this app that watches the keyboard rather than being
    /// handed a combination by it. A Carbon hot key cannot express "the same
    /// modifier twice", so this is a `.flagsChanged` monitor - the kind the Caps
    /// Lock indicator was turned down for.
    ///
    /// What makes it affordable is what it does *not* see. Modifier changes only:
    /// no letters, no digits, nothing typed. It fires when you press ⇧ or ⌘, does
    /// four comparisons, and goes back to sleep; at rest it costs nothing at all,
    /// because a keyboard nobody is touching produces no events.
    ///
    /// Needs Accessibility, which the menu bar module already asks for. Without it
    /// macOS delivers nothing and the taps do nothing - so the Settings row says
    /// so rather than leaving you tapping at a dead key.
    private var flagsMonitors: [Any] = []
    /// When the right ⌥ last went down, in event time.
    private var lastTap: TimeInterval = 0
    /// True while it is held, so auto-repeat cannot count as a second tap.
    private var optionDown = false

    /// Long enough to be comfortable, short enough that two separate presses a
    /// second apart are not mistaken for a double tap.
    private static let doubleTapWindow: TimeInterval = 0.4
    /// The right Option key. The left one is 58, and this is deliberately only
    /// the right: ⌥ on the left is half of every shortcut on the Mac.
    private static let rightOptionKey: UInt16 = 61

    func setCalculatorActive(_ active: Bool) {
        guard active != !flagsMonitors.isEmpty else { return }
        if active {
            let handler: @MainActor (NSEvent) -> Void = { [weak self] event in
                self?.modifiersChanged(event)
            }
            // Global sees every other app; local sees our own windows, which the
            // global monitor never does.
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { event in
                MainActor.assumeIsolated { handler(event) }
            }) {
                flagsMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
                MainActor.assumeIsolated { handler(event) }
                return event
            }) {
                flagsMonitors.append(local)
            }
        } else {
            for monitor in flagsMonitors { NSEvent.removeMonitor(monitor) }
            flagsMonitors.removeAll()
            lastTap = 0
            optionDown = false
        }
    }

    private func modifiersChanged(_ event: NSEvent) {
        guard event.keyCode == Self.rightOptionKey else {
            // Any other modifier means this was a chord, not a tap: ⌥⌘ and ⌥⇧
            // must not count towards one.
            lastTap = 0
            return
        }
        let down = event.modifierFlags.contains(.option)
        guard down else {
            optionDown = false
            return
        }
        guard !optionDown else { return }
        optionDown = true

        // Nothing else held down. Tapping ⌥ while holding ⌘ is part of a
        // shortcut somebody else owns.
        guard event.modifierFlags.intersection([.command, .control, .shift]).isEmpty else {
            lastTap = 0
            return
        }

        if lastTap > 0, event.timestamp - lastTap <= Self.doubleTapWindow {
            lastTap = 0
            CalculatorWindow.shared.toggle()
            return
        }
        lastTap = event.timestamp
    }

    /// Escape is only grabbed while the island is open, so it never interferes
    /// with anything else.
    func setEscapeActive(_ active: Bool) {
        if active {
            guard closeRef == nil else { return }
            register(keyCode: UInt32(kVK_Escape), modifiers: 0, id: 2, into: &closeRef)
        } else if let closeRef {
            UnregisterEventHotKey(closeRef)
            self.closeRef = nil
        }
    }

    /// ⌃⌘V pastes without formatting. Registered only while the module is on, so
    /// switching it off hands the combination straight back to whatever else
    /// wants it. Not ⇧⌘V: that is already "Paste and Match Style" in half the apps
    /// on the Mac, and the frontmost app wins its own shortcut.
    func setPlainPasteActive(_ active: Bool) {
        if active {
            guard plainPasteRef == nil else { return }
            register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | controlKey), id: 5,
                     into: &plainPasteRef)
        } else if let plainPasteRef {
            UnregisterEventHotKey(plainPasteRef)
            self.plainPasteRef = nil
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, into ref: inout EventHotKeyRef?) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x44594E49), id: id)   // 'DYNI'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        // A clash with an existing system or app shortcut fails silently
        // otherwise, and the key just appears not to work.
        if status != noErr { NSLog("hotkey \(id) not registered: \(status)") }
    }

    private func fire(_ id: UInt32) {
        switch id {
        case 1: PanelManager.shared.toggleFocusedIsland()
        case 2: PanelManager.shared.collapseAll()
        case 3: CommandBarWindow.shared.toggle()
        case 4: MenuBarHider.shared.toggle()
        case 5: Utilities.shared.pastePlainText()
        default: break
        }
    }
}
