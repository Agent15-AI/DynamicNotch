import AppKit

/// Apple's own menu bar icons - Wi-Fi, Bluetooth, Sound, Now Playing and the
/// rest - switched on and off.
///
/// These are the icons the capsule can never cover. It hides by widening a
/// status item so the bar pushes everything left of it off the edge, and Apple's
/// icons are not status items in that sense: they sit to the right of the whole
/// user area, cannot be reordered, and nothing an app does to its own items
/// moves them. Measured - aiming the push past them put the capsule at x=1708
/// and shifted nothing.
///
/// But they do not need pushing, because macOS already has a switch for each
/// one. System Settings → Control Center writes a number per icon into
/// `com.apple.controlcenter`, and Control Center reads it on launch. So this
/// writes the same key and restarts the agent, which is exactly what that
/// settings pane does.
///
/// ponytail: the platform already owns this. No pushing, no accessibility, no
/// private call - one preference and a relaunch. The only thing added over
/// opening System Settings yourself is that the switches sit beside the ones
/// for third-party icons, so the whole menu bar is arranged in one place.
@MainActor
@Observable
final class SystemMenuBarItems {
    static let shared = SystemMenuBarItems()

    /// Apple's menu bar icons.
    ///
    /// Most are Control Center's and share one preference shape. Siri and the
    /// input menu each live in their own domain with their own agent to restart,
    /// which is why `pref` exists rather than one hard-coded domain.
    ///
    /// Spotlight and the clock are absent because neither could be made to
    /// work. Both keys exist and both accept a write - Spotlight's
    /// `NSStatusItem VisibleCC Item-0`, the clock's `NSStatusItem VisibleCC
    /// Clock` in Control Center's user domain - and both icons stayed put
    /// through every combination of Spotlight, Control Center and `MenuBarAgent`
    /// being restarted. Measured through the accessibility count: 18 icons
    /// before, 18 after. Shipping switches for them would mean two controls that
    /// silently do nothing.
    enum Item: String, CaseIterable, Identifiable {
        case wifi = "WiFi"
        case bluetooth = "Bluetooth"
        case airdrop = "AirDrop"
        case focusModes = "FocusModes"
        case stageManager = "StageManager"
        case screenMirroring = "ScreenMirroring"
        case display = "Display"
        case sound = "Sound"
        case nowPlaying = "NowPlaying"
        case hearing = "Hearing"
        case accessibility = "AccessibilityShortcuts"
        case musicRecognition = "MusicRecognition"
        case voiceControl = "VoiceControl"
        case keyboardBrightness = "KeyboardBrightness"
        case userSwitcher = "UserSwitcher"
        case siri = "Siri"
        case inputMenu = "InputMenu"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wifi: "Wi-Fi"
            case .bluetooth: "Bluetooth"
            case .airdrop: "AirDrop"
            case .focusModes: "Focus"
            case .stageManager: "Stage Manager"
            case .screenMirroring: "Screen Mirroring"
            case .display: "Display"
            case .sound: "Sound"
            case .nowPlaying: "Now Playing"
            case .hearing: "Hearing"
            case .accessibility: "Accessibility Shortcuts"
            case .musicRecognition: "Music Recognition"
            case .voiceControl: "Voice Control"
            case .keyboardBrightness: "Keyboard Brightness"
            case .userSwitcher: "Fast User Switching"
            case .siri: "Siri"
            case .inputMenu: "Input Menu"
            }
        }

        var symbol: String {
            switch self {
            case .wifi: "wifi"
            case .bluetooth: "dot.radiowaves.left.and.right"
            case .airdrop: "airplayaudio"
            case .focusModes: "moon.fill"
            case .stageManager: "rectangle.stack"
            case .screenMirroring: "rectangle.on.rectangle"
            case .display: "sun.max.fill"
            case .sound: "speaker.wave.2.fill"
            case .nowPlaying: "play.circle.fill"
            case .hearing: "ear"
            case .accessibility: "figure.wave"
            case .musicRecognition: "shazam.logo"
            case .voiceControl: "mic.circle"
            case .keyboardBrightness: "keyboard"
            case .userSwitcher: "person.crop.circle"
            case .siri: "waveform.circle"
            case .inputMenu: "globe"
            }
        }

        /// Icons macOS only ever shows while they are doing something. Switching
        /// one "on" means when-active rather than always, which is what the
        /// Control Center pane does too - forcing 24 on Now Playing pins a
        /// permanent dead icon.
        var prefersWhenActive: Bool {
            self == .nowPlaying || self == .bluetooth || self == .sound || self == .display
        }

        /// Where this icon's visibility actually lives.
        ///
        /// Control Center keeps its own per-host, as a level. The other four are
        /// plain booleans in their own app's domain, each needing that app
        /// restarted rather than Control Center - which is the whole reason they
        /// were left out of the first version.
        var pref: Pref {
            switch self {
            case .siri:
                // Two Siri processes exist - `com.apple.Siri` and
                // `com.apple.campo`, which is "Siri AI.app" - and the icon may
                // belong to either, so both go, plus the agent that hosts it.
                Pref(domain: "com.apple.Siri", key: "StatusMenuVisible",
                     perHost: false, style: .flag,
                     restart: ["com.apple.Siri", "com.apple.campo", "com.apple.MenuBarAgent"])
            case .inputMenu:
                Pref(domain: "com.apple.TextInputMenu", key: "visible",
                     perHost: false, style: .flag, restart: ["com.apple.TextInputMenuAgent"])
            default:
                Pref(domain: "com.apple.controlcenter", key: rawValue,
                     perHost: true, style: .level, restart: ["com.apple.controlcenter"])
            }
        }
    }

    struct Pref {
        let domain: String
        let key: String
        /// Control Center's values are per-host, which is why `defaults` needs
        /// `-currentHost` to see them at all. The rest are not.
        let perHost: Bool
        let style: Style
        /// Bundle ids to terminate so the change is picked up. They are system
        /// agents and relaunch themselves.
        let restart: [String]

        enum Style { case level, flag }
    }

    /// Control Center's own vocabulary: 8 is never shown, 18 is shown while
    /// active, 24 is always shown.
    private enum Visibility {
        static let hidden = 8
        static let whenActive = 18
        static let always = 24
    }

    private init() {}

    func isVisible(_ item: Item) -> Bool {
        let pref = item.pref
        let raw = CFPreferencesCopyValue(
            pref.key as CFString,
            pref.domain as CFString,
            kCFPreferencesCurrentUser,
            pref.perHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        )
        switch pref.style {
        case .level:
            // Absent means factory setting, which for every Control Center key
            // here is visible in some form.
            guard let number = raw as? Int else { return true }
            return number != Visibility.hidden
        case .flag:
            // Absent means shown, for all four.
            guard let flag = raw as? Bool else { return true }
            return flag
        }
    }

    func setVisible(_ visible: Bool, _ item: Item) {
        let pref = item.pref
        let value: CFPropertyList = switch pref.style {
        case .level:
            (visible
                ? (item.prefersWhenActive ? Visibility.whenActive : Visibility.always)
                : Visibility.hidden) as CFNumber
        case .flag:
            visible as CFBoolean
        }

        let host = pref.perHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        CFPreferencesSetValue(pref.key as CFString, value, pref.domain as CFString, kCFPreferencesCurrentUser, host)
        CFPreferencesSynchronize(pref.domain as CFString, kCFPreferencesCurrentUser, host)

        // These agents read their preference once, at launch, so the change is
        // invisible until they come back. They relaunch themselves immediately;
        // System Settings does exactly this from its own panes.
        for bundleID in pref.restart {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                app.terminate()
            }
        }
    }
}
