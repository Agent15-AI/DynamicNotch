import AppKit
import ServiceManagement
import SwiftUI

/// How the closed island is sized on a given display.
///
/// Presets first, custom last - a raw multiplier makes the user do arithmetic to
/// get back to something sensible. Pattern borrowed from boring.notch, which
/// gets this right.
enum HeightMode: String, CaseIterable, Identifiable {
    case matchNotch, matchMenuBar, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .matchNotch: "Match notch"
        case .matchMenuBar: "Match menu bar"
        case .custom: "Custom"
        }
    }
}

enum WidthMode: String, CaseIterable, Identifiable {
    case matchNotch, custom
    var id: String { rawValue }
    var title: String { self == .matchNotch ? "Match notch" : "Custom" }
}

/// What the island shows when nothing is happening.
enum IdleStyle: String, CaseIterable, Identifiable {
    case hidden, whenActive, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hidden: "Hidden"
        case .whenActive: "Only when something is playing"
        case .always: "Always visible"
        }
    }
}

enum DisplayScope: String, CaseIterable, Identifiable {
    case all, builtIn
    var id: String { rawValue }
    var title: String { self == .all ? "All displays" : "Built-in only" }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    // Closed size - notched displays
    var notchHeightMode: HeightMode { didSet { save(notchHeightMode.rawValue, "notchHeightMode") } }
    var notchHeightCustom: Double { didSet { save(notchHeightCustom, "notchHeightCustom") } }
    var notchWidthMode: WidthMode { didSet { save(notchWidthMode.rawValue, "notchWidthMode") } }
    var notchWidthCustom: Double { didSet { save(notchWidthCustom, "notchWidthCustom") } }

    // Closed size - displays without a notch
    var externalHeight: Double { didSet { save(externalHeight, "externalHeight") } }
    var externalMatchMenuBar: Bool { didSet { save(externalMatchMenuBar, "externalMatchMenuBar") } }
    var externalWidth: Double { didSet { save(externalWidth, "externalWidth") } }

    // Open size
    var openWidth: Double { didSet { save(openWidth, "openWidth") } }
    var openHeight: Double { didSet { save(openHeight, "openHeight") } }
    var cornerScaling: Bool { didSet { save(cornerScaling, "cornerScaling") } }

    // Behaviour
    var idleStyle: IdleStyle { didSet { save(idleStyle.rawValue, "idleStyle") } }
    var displayScope: DisplayScope { didSet { save(displayScope.rawValue, "displayScope") } }
    var openOnHover: Bool { didSet { save(openOnHover, "openOnHover") } }
    var hoverDelay: Double { didSet { save(hoverDelay, "hoverDelay") } }
    /// Extra depth below the closed island that still counts as hovering it.
    ///
    /// Non-zero by default, and it has to be. The notch is a physical hole with
    /// no pixels behind it, so the pointer is invisible while over it - aiming at
    /// the notch alone means aiming blind, and only its visible edges are
    /// reachable. This spills the target into screen you can actually see.
    var hoverHeightPad: Double { didSet { save(hoverHeightPad, "hoverHeightPad") } }
    /// Extra width either side of the closed island, in points.
    var hoverWidthPad: Double { didSet { save(hoverWidthPad, "hoverWidthPad") } }
    var haptics: Bool { didSet { save(haptics, "haptics") } }
    /// Whether keep-awake also holds the display on.
    ///
    /// On by default, which is what Amphetamine and Vorssaint do and what people
    /// mean by "keep my Mac awake". Idle *system* sleep alone leaves the display
    /// free to switch off on its own timer, and a black screen is what a sleeping
    /// Mac looks like - so the feature read as broken while working exactly as
    /// written. Off is still worth having: a long export should not have to burn
    /// the backlight for an hour.
    var keepDisplayAwake: Bool { didSet { save(keepDisplayAwake, "keepDisplayAwake") } }
    /// Whether keep-awake also holds the Mac up with the lid closed.
    ///
    /// Off by default, unlike the display option. A Mac told to keep running
    /// with its lid shut will do exactly that inside a bag, and the assertion
    /// this adds only works on mains power anyway - so it is opt-in, the same
    /// call Amphetamine makes for closed-display mode.
    var allowClosedLid: Bool { didSet { save(allowClosedLid, "allowClosedLid") } }

    // Modules
    var nowPlaying: Bool { didSet { save(nowPlaying, "nowPlaying") } }
    var shelf: Bool { didSet { save(shelf, "shelf") } }
    var battery: Bool { didSet { save(battery, "battery") } }
    var calendar: Bool { didSet { save(calendar, "calendar") } }
    var buildStatus: Bool { didSet { save(buildStatus, "buildStatus") } }
    var bluetooth: Bool { didSet { save(bluetooth, "bluetooth") } }
    var downloads: Bool { didSet { save(downloads, "downloads") } }
    var focus: Bool { didSet { save(focus, "focus") } }
    var timer: Bool { didSet { save(timer, "timer") } }
    /// CPU, GPU, memory, disk and network on the home tab. Sampled only while open.
    var stats: Bool { didSet { save(stats, "stats") } }
    /// Microphone in use, with the app that opened it. No camera equivalent -
    /// see the note in `AudioMonitor.inputtingPIDs`.
    var recording: Bool { didSet { save(recording, "recording") } }
    /// Catch a new screenshot and offer it for dragging straight back out.
    var screenshots: Bool { didSet { save(screenshots, "screenshots") } }
    /// Offer to install an app from a mounted disk image.
    var diskImages: Bool { didSet { save(diskImages, "diskImages") } }
    /// Per-app volume. The one module that is not free while it is in use -
    /// see `VolumeMixer`.
    var mixer: Bool { didSet { save(mixer, "mixer") } }
    /// Hiding menu bar icons with the capsule, like Ice.
    var menuBar: Bool { didSet { save(menuBar, "menuBar") } }
    /// Clipboard history, read on app switch rather than polled. See `Clipboard`.
    var clipboard: Bool { didSet { save(clipboard, "clipboard") } }
    /// Temperature beside the calendar, fetched when the island opens.
    var weather: Bool { didSet { save(weather, "weather") } }
    /// City for the weather. Empty means the city in the Mac's time zone.
    var weatherCity: String { didSet { save(weatherCity, "weatherCity") } }
    /// Minutes before a calendar event to show it in the island. 0 is off.
    var upNextMinutes: Double { didSet { save(upNextMinutes, "upNextMinutes") } }
    /// Files or Clipboard, on the shelf tab.
    var shelfMode: String { didSet { save(shelfMode, "shelfMode") } }
    /// Per icon, whether it hides when the capsule is clicked. Keyed by bundle
    /// id, or `system.<n>` for Apple's modules. Absent means the default:
    /// apps hide, Apple's modules stay.
    var menuBarChoices: [String: Bool] { didSet { save(menuBarChoices, "menuBarChoices") } }
    /// Seconds before revealed icons hide again by themselves. 0 is never.
    var menuBarRehideDelay: Double { didSet { save(menuBarRehideDelay, "menuBarRehideDelay") } }
    /// Whether the icons are hidden right now. Persisted so a relaunch comes
    /// back to the menu bar you left, not to every icon reappearing at login.
    var menuBarCollapsed: Bool { didSet { save(menuBarCollapsed, "menuBarCollapsed") } }
    /// Extra time zones shown in the clock tab, alongside local.
    var worldClocks: [String] { didSet { save(worldClocks, "worldClocks") } }
    /// False until the first launch has introduced itself.
    var onboarded: Bool { didSet { save(onboarded, "onboarded") } }
    /// Hide while an app is fullscreen on that display.
    var hideInFullscreen: Bool { didSet { save(hideInFullscreen, "hideInFullscreen") } }
    /// Brightness sliders for external monitors, over DDC. See `ExternalBrightness`.
    var externalBrightness: Bool { didSet { save(externalBrightness, "externalBrightness") } }
    /// Pull a verification code out of copied text. See `Clipboard.code(in:)`.
    var verificationCodes: Bool { didSet { save(verificationCodes, "verificationCodes") } }
    /// ⌃⌘V pastes the clipboard with its formatting stripped.
    var plainPaste: Bool { didSet { save(plainPaste, "plainPaste") } }
    /// 20-20-20 eye breaks. Off by default - it interrupts you.
    var eyeBreak: Bool { didSet { save(eyeBreak, "eyeBreak") } }
    /// Minutes of work between eye breaks.
    var eyeBreakMinutes: Double { didSet { save(eyeBreakMinutes, "eyeBreakMinutes") } }

    /// Reads the real registration rather than a stored flag, so the toggle can
    /// never disagree with what the system is actually doing.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("launch at login: \(error.localizedDescription)")
            }
        }
    }
    /// Brief peek in the closed island when the track changes - the point of it
    /// is that you see what started without the island opening.
    var sneakPeek: Bool { didSet { save(sneakPeek, "sneakPeek") } }
    /// Scroll down on the notch to open, up to close.
    var scrollGesture: Bool { didSet { save(scrollGesture, "scrollGesture") } }
    /// Swipe sideways on the closed notch to change track.
    var swipeGesture: Bool { didSet { save(swipeGesture, "swipeGesture") } }
    /// Excludes the island from screen recordings and screenshots.
    var hideFromCapture: Bool { didSet { save(hideFromCapture, "hideFromCapture") } }
    /// Reopen on whichever tab was last used.
    var rememberTab: Bool { didSet { save(rememberTab, "rememberTab") } }
    var lastTab: String { didSet { save(lastTab, "lastTab") } }
    /// Which sub-tab of Tools was last open. Held here rather than in the view:
    /// choosing an app opens a panel, which closes the island, which throws the
    /// view away - and with it any `@State`. Returning from "Choose app…" landed
    /// back on Actions with the inspected app nowhere in sight.
    var toolsMode: String { didSet { save(toolsMode, "toolsMode") } }
    /// Two taps of the right ⌥ open the scientific calculator. See `Hotkeys`.
    var calculator: Bool { didSet { save(calculator, "calculator") } }
    /// Command-bar calculator works in degrees rather than radians.
    var calculatorDegrees: Bool { didSet { save(calculatorDegrees, "calculatorDegrees") } }
    /// Files in the command bar, from Spotlight's index. See `FileSearch`.
    var fileSearch: Bool { didSet { save(fileSearch, "fileSearch") } }
    /// Figma files in the command bar. Off until a token and a team are set -
    /// there is nothing to show without them.
    var figma: Bool { didSet { save(figma, "figma") } }
    /// Figma team ids, comma separated. The id is the number in a team URL:
    /// `figma.com/files/team/<id>/…`. Figma's API has no endpoint that lists
    /// the teams an account belongs to, so it has to be pasted.
    ///
    /// The token itself is *not* here - it lives in the Keychain. See `Figma`.
    var figmaTeams: String { didSet { save(figmaTeams, "figmaTeams") } }
    /// Search the menus of whatever app was in front. See `MenuSearch`.
    var menuSearch: Bool { didSet { save(menuSearch, "menuSearch") } }
    /// Minutes before the system clipboard is wiped. 0 is never. History is
    /// kept either way - this clears what the next app can paste.
    var clipboardClearMinutes: Double { didSet { save(clipboardClearMinutes, "clipboardClearMinutes") } }
    /// Also wipe it when the Mac sleeps or the screen locks.
    var clipboardClearOnLock: Bool { didSet { save(clipboardClearOnLock, "clipboardClearOnLock") } }
    /// ⌘X then ⌘V moves files in Finder. See `FinderKeys`.
    var finderKeys: Bool { didSet { save(finderKeys, "finderKeys") } }
    /// Lyrics under the player, fetched from LRCLIB on track change.
    var lyrics: Bool { didSet { save(lyrics, "lyrics") } }
    /// Live frequency bars beside the track, while the player is on screen and
    /// playing. See `Spectrum`.
    var soundGraph: Bool { didSet { save(soundGraph, "soundGraph") } }

    private init() {
        let d = UserDefaults.standard
        func num(_ k: String, _ f: Double) -> Double { d.object(forKey: k) as? Double ?? f }
        func flag(_ k: String, _ f: Bool) -> Bool { d.object(forKey: k) as? Bool ?? f }
        func mode<T: RawRepresentable>(_ k: String, _ f: T) -> T where T.RawValue == String {
            (d.string(forKey: k).flatMap(T.init(rawValue:))) ?? f
        }

        notchHeightMode = mode("notchHeightMode", HeightMode.matchNotch)
        notchHeightCustom = num("notchHeightCustom", 34)
        notchWidthMode = mode("notchWidthMode", WidthMode.matchNotch)
        notchWidthCustom = num("notchWidthCustom", 200)

        externalHeight = num("externalHeight", 32)
        externalMatchMenuBar = flag("externalMatchMenuBar", true)
        externalWidth = num("externalWidth", 200)

        openWidth = num("openWidth", 640)
        openHeight = num("openHeight", 196)
        cornerScaling = flag("cornerScaling", true)

        idleStyle = mode("idleStyle", IdleStyle.hidden)
        displayScope = mode("displayScope", DisplayScope.all)
        openOnHover = flag("openOnHover", true)
        hoverDelay = num("hoverDelay", 0.09)
        hoverHeightPad = num("hoverHeightPad", 26)
        hoverWidthPad = num("hoverWidthPad", 18)
        haptics = flag("haptics", true)
        keepDisplayAwake = flag("keepDisplayAwake", true)
        allowClosedLid = flag("allowClosedLid", false)

        nowPlaying = flag("nowPlaying", true)
        shelf = flag("shelf", true)
        battery = flag("battery", true)
        calendar = flag("calendar", true)
        buildStatus = flag("buildStatus", true)
        bluetooth = flag("bluetooth", true)
        downloads = flag("downloads", true)
        focus = flag("focus", true)
        timer = flag("timer", true)
        stats = flag("stats", true)
        recording = flag("recording", true)
        screenshots = flag("screenshots", true)
        diskImages = flag("diskImages", true)
        mixer = flag("mixer", true)
        menuBar = flag("menuBar", true)
        clipboard = flag("clipboard", true)
        upNextMinutes = num("upNextMinutes", 5)
        weather = flag("weather", true)
        weatherCity = d.string(forKey: "weatherCity") ?? ""
        shelfMode = d.string(forKey: "shelfMode") ?? "files"
        menuBarCollapsed = flag("menuBarCollapsed", false)
        menuBarChoices = (d.dictionary(forKey: "menuBarChoices") as? [String: Bool]) ?? [:]
        menuBarRehideDelay = num("menuBarRehideDelay", 15)
        worldClocks = (d.array(forKey: "worldClocks") as? [String]) ?? ["Asia/Kolkata"]
        onboarded = flag("onboarded", false)
        hideInFullscreen = flag("hideInFullscreen", true)
        externalBrightness = flag("externalBrightness", true)
        verificationCodes = flag("verificationCodes", true)
        plainPaste = flag("plainPaste", true)
        eyeBreak = flag("eyeBreak", false)
        eyeBreakMinutes = num("eyeBreakMinutes", 20)
        sneakPeek = flag("sneakPeek", true)
        scrollGesture = flag("scrollGesture", true)
        swipeGesture = flag("swipeGesture", true)
        hideFromCapture = flag("hideFromCapture", false)
        rememberTab = flag("rememberTab", true)
        lastTab = d.string(forKey: "lastTab") ?? "home"
        toolsMode = d.string(forKey: "toolsMode") ?? "actions"
        calculator = flag("calculator", true)
        calculatorDegrees = flag("calculatorDegrees", true)
        fileSearch = flag("fileSearch", true)
        figma = flag("figma", false)
        figmaTeams = d.string(forKey: "figmaTeams") ?? ""
        menuSearch = flag("menuSearch", true)
        clipboardClearMinutes = num("clipboardClearMinutes", 0)
        clipboardClearOnLock = flag("clipboardClearOnLock", false)
        finderKeys = flag("finderKeys", false)
        lyrics = flag("lyrics", false)
        soundGraph = flag("soundGraph", true)
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    func resetSize() {
        notchHeightMode = .matchNotch
        notchHeightCustom = 34
        notchWidthMode = .matchNotch
        notchWidthCustom = 200
        externalHeight = 32
        externalMatchMenuBar = true
        externalWidth = 200
        openWidth = 640
        openHeight = 196
    }
}
