import AppKit
import CoreAudio
import Foundation
import IOKit.pwr_mgt

/// One-press system actions.
///
/// Every one of these is a thing you would otherwise open System Settings, a
/// terminal or a third-party utility for. None of them needs a permission, none
/// of them runs anything at rest: an assertion is a flag held by the power
/// management daemon, and the rest are single calls made when you press them.
///
/// Idea borrowed from Vorssaint's quick toggles; the implementations here are
/// this project's own, so none of its GPL code is carried in.
@MainActor
@Observable
final class Utilities {
    static let shared = Utilities()

    private init() {
        micMuted = Self.readInputMute()
        hiddenFilesShown = Self.finderFlag("AppleShowAllFiles")
        // CreateDesktop defaults to true when the key has never been written.
        desktopIconsShown = UserDefaults(suiteName: "com.apple.finder")?
            .object(forKey: "CreateDesktop") as? Bool ?? true
        refreshVolumes()
        refreshTrash()
        watchVolumes()
    }

    /// Re-reads what the tiles disable themselves on. Called when the island
    /// opens: the Trash changes while the island is shut and is not worth a
    /// watcher, and one directory listing costs nothing.
    func refresh() {
        refreshTrash()
    }

    // MARK: - Microphone

    /// Mute state of the default input device.
    ///
    /// The pair to the microphone indicator: seeing that something is listening
    /// is only half a feature if the answer to it is buried in System Settings.
    private(set) var micMuted = false

    func toggleMicMute() {
        setInputMute(!micMuted)
    }

    private func setInputMute(_ muted: Bool) {
        guard let device = Self.defaultInputDevice() else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value) == noErr {
            micMuted = muted
            return
        }
        // Plenty of inputs - most USB and Bluetooth microphones - expose no mute
        // control at all. Dropping the input gain to zero is the same outcome
        // through the one control they do have.
        var volumeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var gain: Float32 = muted ? 0 : 1
        let gainSize = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectSetPropertyData(device, &volumeAddr, 0, nil, gainSize, &gain) == noErr {
            micMuted = muted
            return
        }
        // Neither control exists on this input. Saying so beats a tile that
        // keeps its old label and looks like it ignored the press.
        HUD.shared.show(
            .utility(symbol: "mic.slash", title: "No mute control",
                     detail: "This input has none"),
            for: 2.4
        )
    }

    private static func readInputMute() -> Bool {
        guard let device = defaultInputDevice() else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        )
        return status == noErr && id != 0 ? id : nil
    }

    // MARK: - Display brightness

    /// Brightness of the built-in display.
    ///
    /// There is no public API for this. `DisplayServices` is the framework the
    /// brightness keys themselves go through, so it is resolved at runtime and
    /// the row hides itself if the symbols ever move - the same treatment the
    /// temperature sensors get.
    ///
    /// Read on demand, never polled: the value is fetched when the row appears
    /// and after every drag, so a closed island costs nothing.
    private(set) var brightness: Float = 0
    private(set) var brightnessAvailable = false

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let displayServices: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
    )
    private static let brightnessGetter: GetBrightness? = displayServices
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetBrightness.self) }
    private static let brightnessSetter: SetBrightness? = displayServices
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetBrightness.self) }

    func readBrightness() {
        var value: Float = 0
        guard let get = Self.brightnessGetter, Self.brightnessSetter != nil,
              get(CGMainDisplayID(), &value) == 0
        else {
            brightnessAvailable = false
            return
        }
        brightness = min(max(value, 0), 1)
        brightnessAvailable = true
    }

    func setBrightness(_ value: Float) {
        guard let set = Self.brightnessSetter else { return }
        let level = min(max(value, 0), 1)
        guard set(CGMainDisplayID(), level) == 0 else { return }
        brightness = level
    }

    // MARK: - Keep awake

    /// Non-nil while the Mac is being held awake. The date is when it lapses,
    /// or nil for "until I say stop".
    private(set) var awakeUntil: Date?
    private(set) var keepingAwake = false

    private var assertion: IOPMAssertionID = 0
    /// Second assertion, held alongside the first. See `Settings.keepDisplayAwake`.
    private var displayAssertion: IOPMAssertionID = 0
    /// Third assertion, for running with the lid shut. See `Settings.allowClosedLid`.
    private var lidAssertion: IOPMAssertionID = 0
    private var lapse: DispatchWorkItem?

    /// What is holding the Mac awake, when it is not a clock.
    enum Condition: String, CaseIterable, Identifiable {
        case whilePluggedIn, whileExternalDisplay
        var id: String { rawValue }
        var title: String {
            switch self {
            case .whilePluggedIn: "While plugged in"
            case .whileExternalDisplay: "With a display"
            }
        }
    }

    private(set) var condition: Condition?

    /// Holds the Mac awake for as long as a condition is true, then lets go.
    ///
    /// Both conditions are event-driven - IOKit already tells `Battery` about
    /// power changes, and AppKit posts screen changes - so nothing polls to keep
    /// this honest.
    func keepAwake(while condition: Condition) {
        keepAwake(minutes: nil)
        guard keepingAwake else { return }
        self.condition = condition
        awakeUntil = nil
        watchCondition()
        reevaluateCondition()
    }

    private var conditionObserver: NSObjectProtocol?

    private func watchCondition() {
        guard conditionObserver == nil else { return }
        conditionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluateCondition() }
        }
    }

    /// Called from the app delegate when power state changes, and on screen
    /// changes. Lets go the moment the condition stops holding.
    func reevaluateCondition() {
        guard let condition, keepingAwake else { return }
        let holds: Bool
        switch condition {
        case .whilePluggedIn: holds = Battery.shared.pluggedIn
        case .whileExternalDisplay: holds = NSScreen.screens.count > 1
        }
        guard !holds else { return }
        stopKeepingAwake()
        HUD.shared.show(
            .utility(symbol: "cup.and.saucer", title: "Sleeping normally",
                     detail: condition == .whilePluggedIn ? "Unplugged" : "Display disconnected"),
            for: 2.4
        )
    }

    /// Minutes, or nil for indefinite.
    func keepAwake(minutes: Int?) {
        releaseAssertion()
        condition = nil

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Dynamic Island keep awake" as CFString,
            &id
        )
        // Left true on failure the machine would be sleeping while the tile read
        // "Staying awake", which is the one state this must never show.
        guard result == kIOReturnSuccess else { keepingAwake = false; return }
        assertion = id

        // The display gets its own assertion, because system sleep and display
        // sleep run on separate timers - this Mac is set to sleep after 1 minute
        // and blank the screen after 30, and holding only the first still ends
        // with a dark screen that everyone reads as a sleeping Mac.
        if Settings.shared.keepDisplayAwake {
            var display: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Dynamic Island keep display awake" as CFString,
                &display
            ) == kIOReturnSuccess {
                displayAssertion = display
            }
        }
        // `PreventSystemSleep` rather than the idle variants: those two are only
        // consulted when nothing is happening, and closing the lid is an event,
        // not idleness. This is the assertion `caffeinate -s` takes and the one
        // Amphetamine's closed-display mode rests on.
        //
        // macOS honours it on mains power only. On battery the lid switch wins
        // whatever is asserted, which is why this cannot be the whole answer.
        if Settings.shared.allowClosedLid {
            var lid: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Dynamic Island keep awake with lid closed" as CFString,
                &lid
            ) == kIOReturnSuccess {
                lidAssertion = lid
            }
        }
        keepingAwake = true

        guard let minutes else { awakeUntil = nil; return }
        awakeUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        // One work item at the end, not a countdown - the remaining time is
        // derived from the date whenever something draws it.
        let work = DispatchWorkItem { [weak self] in self?.stopKeepingAwake() }
        lapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(minutes * 60), execute: work)
    }

    func stopKeepingAwake() {
        releaseAssertion()
        keepingAwake = false
        awakeUntil = nil
        condition = nil
        // Dropped with the assertion. Left registered it kept waking the app on
        // every display change for a condition that no longer existed.
        if let conditionObserver {
            NotificationCenter.default.removeObserver(conditionObserver)
            self.conditionObserver = nil
        }
    }

    private func releaseAssertion() {
        lapse?.cancel()
        lapse = nil
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
        if lidAssertion != 0 {
            IOPMAssertionRelease(lidAssertion)
            lidAssertion = 0
        }
    }

    /// Remaining time, derived rather than counted.
    var awakeRemaining: String? {
        guard let awakeUntil else { return nil }
        let seconds = max(0, Int(awakeUntil.timeIntervalSinceNow))
        return seconds >= 3600
            ? String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Finder toggles

    private(set) var hiddenFilesShown = false
    private(set) var desktopIconsShown = true

    func toggleHiddenFiles() {
        hiddenFilesShown.toggle()
        Self.setFinderFlag("AppleShowAllFiles", hiddenFilesShown)
    }

    func toggleDesktopIcons() {
        desktopIconsShown.toggle()
        Self.setFinderFlag("CreateDesktop", desktopIconsShown)
    }

    private static func finderFlag(_ key: String) -> Bool {
        UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: key) ?? false
    }

    /// Finder reads these at startup, so it has to be restarted to notice.
    /// ponytail: `defaults` and `killall` are the documented way to do this;
    /// there is no API for either flag.
    private static func setFinderFlag(_ key: String, _ value: Bool) {
        UserDefaults(suiteName: "com.apple.finder")?.set(value, forKey: key)
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        run("/usr/bin/killall", ["Finder"])
    }

    // MARK: - Appearance

    /// Flips the system between light and dark.
    ///
    /// The only route is System Events, so this raises the Automation prompt the
    /// first time and does nothing until it is allowed. There is no public API
    /// and no defaults key that takes effect live.
    func toggleDarkMode() {
        let script = """
        tell application "System Events" to tell appearance preferences \
        to set dark mode to not dark mode
        """
        Self.osascript(script) { ok in
            HUD.shared.show(
                .utility(symbol: ok ? "circle.lefthalf.filled" : "lock.slash",
                         title: ok ? "Appearance switched" : "Automation is off",
                         detail: ok ? "Light and dark" : Permissions.detail(for: "System Events")),
                for: ok ? 2.4 : 3.4
            )
            if !ok { Permissions.open("Privacy_Automation") }
        }
    }

    // Keyboard backlight is deliberately absent. `CoreBrightness` exposes no
    // keyboard symbols on macOS 26 - probed, every candidate missing - and the
    // IORegistry shows only a `KeyboardBacklight` resource flag with nothing
    // writable behind it. A slider that cannot move is worse than no slider.

    // MARK: - Screen

    /// Locks the screen the way ⌃⌘Q does.
    ///
    /// ponytail: one symbol resolved at runtime, the same treatment brightness
    /// gets. The old route ran `Menu Extras/User.menu/.../CGSession -suspend`,
    /// and that binary no longer ships - checked on 26.5, `User.menu` is not in
    /// `Menu Extras` at all. `Process.run` threw into a `try?`, so the tile
    /// launched nothing and said nothing: the exact shape of a dead button.
    private typealias LockScreenImmediate = @convention(c) () -> Int32

    private static let loginFramework: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY
    )
    private static let screenLock: LockScreenImmediate? = loginFramework
        .flatMap { dlsym($0, "SACLockScreenImmediate") }
        .map { unsafeBitCast($0, to: LockScreenImmediate.self) }

    func lockScreen() {
        guard let lock = Self.screenLock, lock() == 0 else {
            HUD.shared.show(
                .utility(symbol: "lock.slash", title: "Could not lock", detail: "Press ⌃⌘Q"),
                for: 2.6
            )
            return
        }
    }

    func sleepDisplays() {
        guard Self.run("/usr/bin/pmset", ["displaysleepnow"]) else {
            HUD.shared.show(
                .utility(symbol: "moon.slash", title: "Could not sleep", detail: "pmset is missing"),
                for: 2.4
            )
            return
        }
    }

    // MARK: - Disks

    /// Ejectable volumes, so the button can say how many and disable itself when
    /// there are none.
    ///
    /// Stored, not computed. `@Observable` can only track a property it sees
    /// being read, and a computed one that asks `FileManager` reads nothing
    /// observable - so the tile was evaluated once and never again. Plug a disk
    /// in with the island open and the button stayed greyed out.
    private(set) var ejectableVolumes: [URL] = []

    /// Workspace posts mount and unmount; nothing polls for them.
    private func watchVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            }
        }
    }

    func refreshVolumes() {
        ejectableVolumes = (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey],
            options: [.skipHiddenVolumes]
        ) ?? []).filter { url in
            let values = try? url.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey])
            return (values?.volumeIsEjectable ?? false) || (values?.volumeIsRemovable ?? false)
        }
    }

    /// Unmounts every ejectable volume. Reports what happened rather than
    /// failing quietly - a disk that refuses to eject is usually a disk with a
    /// file still open on it, and that is worth saying.
    func ejectAll() {
        let volumes = ejectableVolumes
        guard !volumes.isEmpty else { return }
        var ejected = 0
        var failed: String?
        for url in volumes {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                ejected += 1
            } catch {
                failed = url.lastPathComponent
            }
        }
        refreshVolumes()
        let message = failed.map { "\($0) is in use" }
            ?? (ejected == 1 ? "1 disk ejected" : "\(ejected) disks ejected")
        HUD.shared.show(
            .utility(symbol: failed == nil ? "eject.fill" : "exclamationmark.triangle.fill",
                     title: message,
                     detail: failed == nil ? "Safe to unplug" : "Close it and try again"),
            for: 2.4
        )
    }

    // MARK: - Clipboard

    /// Strips tracking parameters from a copied link.
    ///
    /// On demand only. The alternative - watching the clipboard - means polling
    /// `changeCount` several times a second forever, which is the one cost this
    /// whole app exists to avoid.
    private static let trackingKeys: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "utm_name", "utm_reader", "utm_social", "utm_brand", "gclid", "dclid", "fbclid",
        "msclkid", "mc_cid", "mc_eid", "igshid", "igsh", "ref_src", "ref_url", "spm",
        "si", "s_kwcid", "ttclid", "twclid", "yclid", "wt_zmc", "_hsenc", "_hsmi",
        "vero_id", "vero_conv", "oly_anon_id", "oly_enc_id", "trk", "trkCampaign",
        "cmpid", "campaign_id", "ncid", "sr_share", "share_id",
    ]

    func cleanClipboardURL() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            var components = URLComponents(string: text),
            components.scheme?.hasPrefix("http") == true
        else {
            HUD.shared.show(
                .utility(symbol: "link.badge.plus", title: "No link copied", detail: "Copy a URL first"),
                for: 2.0
            )
            return
        }

        let before = components.queryItems?.count ?? 0
        let kept = (components.queryItems ?? []).filter {
            !Self.trackingKeys.contains($0.name.lowercased())
        }
        components.queryItems = kept.isEmpty ? nil : kept
        // A trailing "?" left behind by removing every parameter is untidy.
        guard let cleaned = components.url?.absoluteString else { return }

        let removed = before - kept.count
        pasteboard.clearContents()
        pasteboard.setString(cleaned, forType: .string)
        HUD.shared.show(
            .utility(
                symbol: "link",
                title: removed == 0 ? "Already clean" : "\(removed) removed",
                detail: components.host ?? "Copied"
            ),
            for: 2.2
        )
    }

    /// Pastes what is on the clipboard with its formatting stripped.
    ///
    /// ⌃⌘V, beside the ⌘V it stands in for. Pasting into a document and then
    /// hunting for "Paste and Match Style" - which half the apps on the Mac spell
    /// differently and some do not have at all - is the chore this removes.
    ///
    /// The plain text is put back on the clipboard rather than pasted from a
    /// private buffer: an app that ignores ⌘V and wants a menu item still gets the
    /// stripped version, and what you paste next is what you saw happen.
    func pastePlainText() {
        let pasteboard = NSPasteboard.general
        // The string flavour is there next to the rich one almost always. RTF is
        // the fallback for the apps that only write that.
        let plain = pasteboard.string(forType: .string)
            ?? pasteboard.data(forType: .rtf)
                .flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
        guard let plain, !plain.isEmpty else {
            HUD.shared.show(
                .utility(symbol: "doc.on.clipboard", title: "Nothing to paste", detail: "No text copied"),
                for: 2.0
            )
            return
        }

        pasteboard.clearContents()
        pasteboard.setString(plain, forType: .string)
        // Our own write, not a copy the user made.
        Clipboard.shared.lastChange = pasteboard.changeCount

        guard AXIsProcessTrusted() else {
            HUD.shared.show(
                .utility(symbol: "textformat", title: "Formatting stripped", detail: "Press ⌘V"),
                for: 2.2
            )
            return
        }
        // A beat, for the same reason the clipboard rows wait: the keystroke has
        // to land after whatever had the pointer has let go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Clipboard.pressCommandV()
        }
    }

    // MARK: - Colour

    /// Picks a colour from anywhere on screen and copies the hex.
    ///
    /// ponytail: `NSColorSampler` is the system's own loupe - magnifier, pixel
    /// grid, escape-to-cancel and multi-display handling all already written.
    func pickColour() {
        NSColorSampler().show { picked in
            // Cancelled with Escape.
            guard let picked else { return }
            // sRGB first: the sampler hands back whatever space the screen is
            // in, and a hex read off a P3 value is not the hex anyone wanted.
            let color = picked.usingColorSpace(.sRGB) ?? picked
            let hex = String(
                format: "#%02X%02X%02X",
                Int(round(color.redComponent * 255)),
                Int(round(color.greenComponent * 255)),
                Int(round(color.blueComponent * 255))
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            // The activity is the receipt: it names exactly what went to the
            // clipboard, so the copy is not a silent action.
            HUD.shared.show(.color(hex: hex, swatch: color), for: 2.6)
        }
    }

    // MARK: - Odds and ends

    func restartFinder() {
        Self.run("/usr/bin/killall", ["Finder"])
        HUD.shared.show(
            .utility(symbol: "arrow.clockwise", title: "Finder restarted", detail: "Relaunching"),
            for: 2.0
        )
    }

    /// Copies this Mac's address on the local network - the thing you actually
    /// want when someone says "what's your IP", rather than the public one.
    func copyLocalIP() {
        var address: String?
        var pointer: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&pointer) == 0, let first = pointer {
            for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let interface = entry.pointee
                guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
                let name = String(cString: interface.ifa_name)
                // en0/en1 are the built-in Wi-Fi and Ethernet; everything else
                // here is a bridge, a VPN or a virtual machine.
                guard name == "en0" || name == "en1" else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                    break
                }
            }
            freeifaddrs(pointer)
        }
        guard let address else {
            HUD.shared.show(
                .utility(symbol: "wifi.slash", title: "No address", detail: "Not on a network"),
                for: 2.0
            )
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        HUD.shared.show(.utility(symbol: "wifi", title: address, detail: "Copied"), for: 2.4)
    }

    // MARK: - Trash

    /// Items sitting in the Trash, or nil when it cannot be counted.
    ///
    /// Reading `~/.Trash` needs Full Disk Access, which this app does not ask
    /// for - measured, `contentsOfDirectory` fails there with "Operation not
    /// permitted". The old code swallowed that into `?? []`, so the count was
    /// always 0 and the tile greyed itself out permanently on a Trash that was
    /// not empty. nil means "unknown", and unknown must stay pressable:
    /// emptying goes through Finder, which needs no such grant.
    private(set) var trashCount: Int?

    func refreshTrash() {
        let trash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        trashCount = (try? FileManager.default.contentsOfDirectory(atPath: trash.path))?
            .filter { !$0.hasPrefix(".") }.count
    }

    /// Deliberately two presses. Emptying the Trash cannot be undone, so the
    /// tile arms first and only empties on a second press - a confirmation the
    /// user cannot click through by accident, without a modal dialog in a panel
    /// this size.
    private(set) var trashArmed = false
    private var disarm: DispatchWorkItem?

    func emptyTrash() {
        guard trashArmed else {
            trashArmed = true
            disarm?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.trashArmed = false }
            disarm = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            return
        }
        disarm?.cancel()
        trashArmed = false

        // Finder owns the Trash and can empty it under its own authority, so
        // this needs Automation - one prompt, one click - rather than Full Disk
        // Access, which has no prompt at all and has to be switched on by hand
        // in System Settings. Deleting the files ourselves needed the second.
        let before = trashCount
        Self.osascript("tell application \"Finder\" to empty the trash") { [weak self] ok in
            guard let self else { return }
            refreshTrash()
            guard ok else {
                HUD.shared.show(
                    .utility(symbol: "lock.slash",
                             title: "Automation is off",
                             detail: Permissions.detail(for: "Finder")),
                    for: 3.4
                )
                Permissions.open("Privacy_Automation")
                return
            }
            let removed = before.map { $0 == 1 ? "1 item removed" : "\($0) items removed" }
            HUD.shared.show(
                .utility(symbol: "trash.fill",
                         title: removed ?? "Trash emptied",
                         detail: removed == nil ? "Finder emptied it" : "Trash emptied"),
                for: 2.4
            )
        }
    }

    // MARK: - Shell

    /// ponytail: these actions have no API. A launched process that is never
    /// waited on is the whole implementation.
    ///
    /// Returns whether it actually launched. The old version dropped that into
    /// a `try?` and told no one, which is how a tile pointed at a binary that
    /// had been removed from macOS went on looking fine for a whole release.
    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        return (try? process.run()) != nil
    }

    /// Runs one AppleScript off the main thread and reports whether it worked.
    ///
    /// Two callers - Finder and the appearance setting - asking the same
    /// question: did Automation allow it? A non-zero exit is almost always the
    /// user having never been asked, or having said no, and that is worth
    /// saying out loud rather than looking like nothing happened.
    private static func osascript(
        _ source: String,
        then finish: @escaping @MainActor (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            // `waitUntilExit` on a process that never launched returns a status
            // of 0, so a launch failure would read as success.
            guard (try? process.run()) != nil else {
                DispatchQueue.main.async { MainActor.assumeIsolated { finish(false) } }
                return
            }
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(ok) } }
        }
    }
}
