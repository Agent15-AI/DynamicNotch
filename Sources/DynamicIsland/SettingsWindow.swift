import AppKit
import SwiftUI

/// A real settings window.
///
/// The island itself is the live preview - every control here resizes the thing
/// on screen as you drag it, so there is no separate preview to keep in sync.
@MainActor
@Observable
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    /// The open tab, so a menu command can land on a specific one.
    var tab = "general"

    private init() {}

    func show(tab: String? = nil) {
        if let tab { self.tab = tab }
        // A regular app while Settings is open. macOS 27 draws no menu bar at
        // all while an accessory app is active - the bar vanished the moment
        // this window came forward, and the icons Settings rearranges went
        // with it. Back to accessory when the window closes.
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Dynamic Island"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsRoot())
        window.center()
        self.window = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsRoot: View {
    @Bindable private var settings = Settings.shared
    @Bindable private var navigation = SettingsWindow.shared

    var body: some View {
        // 620pt wide: at 480 macOS 27 folds the five tabs into a "Navigation
        // Tab Bar" overflow menu and the Menu Bar tab is two clicks deep.
        TabView(selection: $navigation.tab) {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            SizeSettings(settings: settings)
                .tabItem { Label("Size", systemImage: "arrow.up.left.and.arrow.down.right") }
                .tag("size")
            BehaviourSettings(settings: settings)
                .tabItem { Label("Interaction", systemImage: "hand.point.up.left") }
                .tag("interaction")
            MenuBarSettings(settings: settings)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
                .tag("menubar")
            ModuleSettings(settings: settings)
                .tabItem { Label("Modules", systemImage: "square.grid.2x2") }
                .tag("modules")
        }
        .frame(width: 620, height: 600)
        // Match the island rather than the system accent, so the settings and
        // the thing they configure read as one product.
        .tint(Theme.core)
    }
}

/// Set-once settings, kept away from the ones you tune by feel.
private struct GeneralSettings: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            }

            Section("When idle") {
                Picker("Show", selection: $settings.idleStyle) {
                    ForEach(IdleStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Hidden leaves the notch looking untouched until you point at it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Displays") {
                Picker("Show on", selection: $settings.displayScope) {
                    ForEach(DisplayScope.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Hide while an app is fullscreen", isOn: $settings.hideInFullscreen)
            }

            Section("Keep awake") {
                Toggle("Also keep the display on", isOn: $settings.keepDisplayAwake)
                Toggle("Keep running with the lid closed", isOn: $settings.allowClosedLid)
                Text("Closed-lid mode needs mains power - on battery the lid "
                     + "switch overrides it. A Mac kept running inside a closed "
                     + "bag has nowhere to put its heat, so leave this off unless "
                     + "the machine is somewhere it can breathe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("System sleep and display sleep are separate timers. Holding "
                     + "only the first leaves the screen free to switch off, which "
                     + "looks exactly like the Mac sleeping. Turn this off if you "
                     + "want a long job to run with the screen dark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Hide from screen recordings and screenshots", isOn: $settings.hideFromCapture)
                Text("The island is always hidden while the screen is locked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("⌃⌘N opens the island. Escape closes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Quit Dynamic Island") { NSApplication.shared.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SizeSettings: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section("Closed size — display with a notch") {
                Picker("Height", selection: $settings.notchHeightMode) {
                    ForEach(HeightMode.allCases) { Text($0.title).tag($0) }
                }
                if settings.notchHeightMode == .custom {
                    LabeledSlider(label: "Custom height", value: $settings.notchHeightCustom,
                                  range: 24 ... 80, unit: "pt")
                }
                Picker("Width", selection: $settings.notchWidthMode) {
                    ForEach(WidthMode.allCases) { Text($0.title).tag($0) }
                }
                if settings.notchWidthMode == .custom {
                    LabeledSlider(label: "Custom width", value: $settings.notchWidthCustom,
                                  range: 120 ... 520, unit: "pt")
                }
            }

            Section("Closed size — display without a notch") {
                Toggle("Match menu bar height", isOn: $settings.externalMatchMenuBar)
                if !settings.externalMatchMenuBar {
                    LabeledSlider(label: "Height", value: $settings.externalHeight,
                                  range: 20 ... 80, unit: "pt")
                }
                LabeledSlider(label: "Width", value: $settings.externalWidth,
                              range: 120 ... 520, unit: "pt")
            }

            Section("Open size") {
                LabeledSlider(label: "Width", value: $settings.openWidth, range: 340 ... 900, unit: "pt")
                LabeledSlider(label: "Height", value: $settings.openHeight, range: 130 ... 420, unit: "pt")
                Toggle("Scale corners with size", isOn: $settings.cornerScaling)
            }

            Section {
                Button("Reset to defaults") { settings.resetSize() }
            }
        }
        .formStyle(.grouped)
    }
}

/// What you tune by feel. Idle style, keep-awake, privacy, startup and displays
/// live in General only - they were copied here as well, so the same switches
/// appeared on two tabs.
private struct BehaviourSettings: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section("Hover") {
                Toggle("Open on hover", isOn: $settings.openOnHover)
                if settings.openOnHover {
                    LabeledSlider(label: "Delay", value: $settings.hoverDelay,
                                  range: 0 ... 1, unit: "s", decimals: 2)
                }
                LabeledSlider(label: "Extra depth", value: $settings.hoverHeightPad,
                              range: 0 ... 30, unit: "pt")
                LabeledSlider(label: "Target padding", value: $settings.hoverWidthPad,
                              range: 0 ... 120, unit: "pt")
                Text("The island reacts across the whole closed notch. Target "
                     + "padding widens that. Extra depth applies only to a "
                     + "display with a real notch, where the pointer disappears "
                     + "into the cutout - elsewhere it would reach down into "
                     + "windows you were aiming at.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Haptic feedback", isOn: $settings.haptics)
                Toggle("Scroll on the notch to open and close", isOn: $settings.scrollGesture)
                Toggle("Swipe across the notch to change track", isOn: $settings.swipeGesture)
                Toggle("Reopen on the last tab used", isOn: $settings.rememberTab)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModuleSettings: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section("Modules") {
                Toggle("Now Playing", isOn: $settings.nowPlaying)
                Toggle("File shelf", isOn: $settings.shelf)
                Toggle("Battery", isOn: $settings.battery)
                Toggle("Calendar", isOn: $settings.calendar)
                Toggle("Bluetooth connections", isOn: $settings.bluetooth)
                Toggle("Finished downloads", isOn: $settings.downloads)
                Toggle("Peek when the track changes", isOn: $settings.sneakPeek)
                Toggle("Timer", isOn: $settings.timer)
                Toggle("System stats on the home tab", isOn: $settings.stats)
                Toggle("Microphone in use", isOn: $settings.recording)
                Toggle("Catch new screenshots", isOn: $settings.screenshots)
                Toggle("Install apps from disk images", isOn: $settings.diskImages)
                Toggle("Per-app volume", isOn: $settings.mixer)
                Toggle("Hide menu bar icons", isOn: $settings.menuBar)
                Picker("Upcoming events", selection: $settings.upNextMinutes) {
                    Text("Off").tag(0.0)
                    Text("1 minute before").tag(1.0)
                    Text("5 minutes before").tag(5.0)
                    Text("10 minutes before").tag(10.0)
                    Text("15 minutes before").tag(15.0)
                }
                .disabled(!settings.calendar)
                Toggle("Weather beside the calendar", isOn: $settings.weather)
                if settings.weather {
                    TextField("City", text: $settings.weatherCity, prompt: Text(Weather.defaultCity))
                        .onSubmit { Weather.shared.cityChanged() }
                }
                Toggle("Sound graph beside the track", isOn: $settings.soundGraph)
                    .help("Listens only while the player is on screen and playing")
                Toggle("Lyrics under the player", isOn: $settings.lyrics)
                    .onChange(of: settings.lyrics) { _, on in
                        on ? Lyrics.shared.refresh() : Lyrics.shared.clear()
                    }
                Toggle("Clipboard history", isOn: $settings.clipboard)
                Toggle("Offer verification codes from copied text", isOn: $settings.verificationCodes)
                    .disabled(!settings.clipboard)
                Toggle("Plain-text paste (⌃⌘V)", isOn: $settings.plainPaste)
                Toggle("Calculator on a double-tap of right ⌥", isOn: $settings.calculator)
                Toggle("Brightness for external monitors", isOn: $settings.externalBrightness)
                Toggle("Eye breaks (20-20-20)", isOn: $settings.eyeBreak)
                Picker("Look away every", selection: $settings.eyeBreakMinutes) {
                    Text("10 minutes").tag(10.0)
                    Text("20 minutes").tag(20.0)
                    Text("30 minutes").tag(30.0)
                    Text("45 minutes").tag(45.0)
                    Text("60 minutes").tag(60.0)
                }
                .disabled(!settings.eyeBreak)
                Text("Pick which icons hide in the Menu Bar tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Per-app volume re-renders an app's audio while it is below "
                     + "100%, so it is the one module that is not free while in "
                     + "use. Apps left at 100% cost nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Monitor brightness goes over DDC/CI - the channel a monitor's "
                     + "own buttons use. Monitors that ignore it keep the level the "
                     + "slider was last left at. Nothing is sent until you drag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The calculator opens on two quick taps of the right Option "
                     + "key. That needs Accessibility - the same grant the menu bar "
                     + "module uses - because macOS only tells an app about keys "
                     + "pressed elsewhere once it is trusted. Nothing but modifier "
                     + "keys is watched, and nothing is watched at all while this "
                     + "is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("An eye break pauses while the Mac is locked or asleep, and "
                     + "waits five minutes if the microphone is live - a reminder "
                     + "in the middle of a call is one nobody keeps switched on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Preview live activities") { HUD.shared.preview() }
            }

            Section("Command bar (⌥Space)") {
                Toggle("Files, from Spotlight's index", isOn: $settings.fileSearch)
                Toggle("Commands from the front app's menus", isOn: $settings.menuSearch)
                Text("Searches the menu bar of whatever app you were in - “Export "
                     + "as PDF”, “Merge Cells”. Needs Accessibility, reads the "
                     + "menus only when you type, and keeps nothing between "
                     + "openings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Asks Spotlight when you have typed three letters, and stops "
                     + "asking the moment the bar closes. No index of our own and "
                     + "no folder watching, so it costs nothing while shut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FigmaSettings(settings: settings)
                Text("Sums, times and units answer as you type: “12pm here in "
                     + "london”, “5km in miles”, “180c in f”. ⌘K opens what else "
                     + "the selected result can do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SnippetSettings()
                Button("Forget what I use most") { Frecency.forget() }
                Text("The bar learns which results you pick and ranks them "
                     + "higher, decaying by half every fortnight. It only "
                     + "separates results that already match equally well - it "
                     + "never puts a habit above a better match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Picker("Clear the clipboard after", selection: $settings.clipboardClearMinutes) {
                    Text("Never").tag(0.0)
                    Text("1 minute").tag(1.0)
                    Text("5 minutes").tag(5.0)
                    Text("30 minutes").tag(30.0)
                    Text("2 hours").tag(120.0)
                }
                .disabled(!settings.clipboard)
                Toggle("Also clear it on lock and sleep", isOn: $settings.clipboardClearOnLock)
                    .disabled(!settings.clipboard)
                Text("Clears what the next app can paste, not your history. "
                     + "Pinned entries are never cleared or evicted. Images, "
                     + "files and colours are kept alongside text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Finder") {
                Toggle("⌘X cuts files, F2 renames", isOn: $settings.finderKeys)
                    .onChange(of: settings.finderKeys) { _, _ in FinderKeys.shared.settingChanged() }
                Text("The Finder can already move on paste - that is ⌥⌘V, hidden "
                     + "behind a modifier. ⌘X copies and remembers, ⌘V moves. "
                     + "An image on the clipboard pastes as a PNG file into the "
                     + "folder you are looking at. The keys are claimed only "
                     + "while the Finder is in front, never globally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Bluetooth") {
                    if BluetoothWatch.shared.authorized {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Allow") { BluetoothWatch.shared.requestAccess() }
                    }
                }
                LabeledContent("Calendar") {
                    if CalendarPeek.shared.authorized {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Allow") { CalendarPeek.shared.requestAccess() }
                    }
                }
                LabeledContent("Screen Recording") {
                    if ScreenOCR.shared.authorized {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Allow") { ScreenOCR.shared.capture() }
                    }
                }
                LabeledContent("Downloads folder") {
                    if Downloads.shared.authorized {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Allow") { Downloads.shared.requestAccess() }
                    }
                }
                LabeledContent("Screenshot folder") {
                    if Screenshots.shared.authorized {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Allow") { Screenshots.shared.requestAccess() }
                    }
                }
                Text("Nothing is requested on launch. These ask macOS only when "
                     + "you press Allow, so restarting the app never interrupts you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Now Playing") {
                LabeledContent("Helper") { Text(NowPlaying.shared.health) }
                Text("Now Playing runs through a helper that macOS updates can break. If this stops saying Running or Idle, that is why the island has no track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                LabeledContent("History") {
                    Text("\(Clipboard.shared.clips.count) of 60")
                        .foregroundStyle(.secondary)
                }
                Button("Clear clipboard history") { Clipboard.shared.clear() }
                    .disabled(Clipboard.shared.clips.isEmpty)
                Text("Read when you switch apps or open the island - never on a timer. "
                     + "Two copies in the same app with no switch between keep only the second. "
                     + "Anything a password manager marks as secret is skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Which menu bar icons hide when the capsule is clicked - a switch per icon,
/// Apple's included, in the order they sit in the bar.
private struct MenuBarSettings: View {
    @Bindable var settings: Settings
    var hider = MenuBarHider.shared
    var catalogue = MenuBarItems.shared
    var system = SystemMenuBarItems.shared
    private let layout = MenuBarLayout.shared

    /// What the strips show, so any change to it redraws them.
    private var revision: [String] {
        catalogue.listed.map { "\($0.id)\(hider.hides($0))" } + [hider.arranging ? "moving" : ""]
    }

    var body: some View {
        Form {
            Section {
                Toggle("Hide menu bar icons with the capsule", isOn: $settings.menuBar)
                LabeledContent("Hide or show") { Text("Click the capsule, or ⌘⌃B").foregroundStyle(.secondary) }
                LabeledContent("Settings and Quit") { Text("Right-click the capsule").foregroundStyle(.secondary) }
                Picker("Hide again automatically", selection: $settings.menuBarRehideDelay) {
                    Text("Never").tag(0.0)
                    Text("After 5 seconds").tag(5.0)
                    Text("After 10 seconds").tag(10.0)
                    Text("After 15 seconds").tag(15.0)
                    Text("After 30 seconds").tag(30.0)
                    Text("After 1 minute").tag(60.0)
                }
                .disabled(!settings.menuBar)
                Button(hider.collapsed ? "Show icons now" : "Hide icons now") { hider.toggle() }
                    .disabled(!settings.menuBar)
                if let problem = hider.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.gold)
                }
            } footer: {
                Text("The capsule stays at the right end of the menu bar - only Control Center, "
                     + "Siri and the clock can sit right of it, because macOS pins those.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if catalogue.authorized {
                Section {
                    // Ice's layout bars: the real icons, dragged.
                    LabeledContent("Shown") {
                        LayoutStripView(strip: layout.shownStrip, revision: revision)
                            .frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.55)))
                    }
                    LabeledContent("Hidden") {
                        LayoutStripView(strip: layout.hiddenStrip, revision: revision)
                            .frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.55)))
                    }
                    if hider.arranging {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Moving icons - leave the mouse for a moment")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let problem = hider.arrangeProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.gold)
                    }
                    if !CGPreflightScreenCaptureAccess() {
                        Button("Show the real icons (needs Screen Recording)…") {
                            if !CGRequestScreenCaptureAccess() { Permissions.open("Privacy_ScreenCapture") }
                        }
                    }
                } header: {
                    Text("Layout")
                } footer: {
                    Text("Drag icons to rearrange your menu bar, like Ice. Drag one into Hidden to hide "
                         + "it when you click the capsule, or into Shown to keep it. Control Centre, Siri "
                         + "and the clock stay where macOS pins them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if catalogue.listed.isEmpty {
                        Text("Nothing found yet. Press Rescan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Ice's layout editor: drag a row and the real icon is
                    // ⌘-dragged to match. Control Center, Siri and the clock
                    // stay put - macOS pins them.
                    ForEach(catalogue.listed) { item in
                        IconRow(item: item, hider: hider)
                    }
                    HStack {
                        Button("Rescan") { catalogue.scan() }
                        Spacer()
                        Button("Move capsule to the right end") { hider.placeIfNeeded(manual: true) }
                            .disabled(!settings.menuBar || hider.collapsed)
                    }
                } header: {
                    Text("Your menu bar, left to right")
                } footer: {
                    Text("Switched on means the icon hides when you click the capsule. macOS hides by "
                         + "app, so an app with two icons hides both. New apps hide by default, like Ice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Your menu bar icons") {
                    Text("Listing your icons and keeping the capsule at the right end both need "
                         + "Accessibility.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Allow Accessibility…") {
                        catalogue.requestAccess()
                        catalogue.watchForAccess()
                    }
                    Button("Open Accessibility settings") {
                        catalogue.openSettingsPane()
                        catalogue.watchForAccess()
                    }
                    Text("Tick Dynamic Island in that list. This fills in by itself a second later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                DisclosureGroup("Remove Apple icons from the menu bar entirely") {
                    Text("Different from hiding: these take the icon out of the menu bar for good, "
                         + "the same switches as System Settings → Menu Bar. Control Center restarts "
                         + "to pick the change up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(SystemMenuBarItems.Item.allCases) { item in
                        Toggle(isOn: Binding(
                            get: { system.isVisible(item) },
                            set: { system.setVisible($0, item) }
                        )) {
                            Label(item.title, systemImage: item.symbol)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            catalogue.scan()
            catalogue.watchForAccess()
            Task { await layout.capture() }
        }
        // Fresh pictures once icons have moved or come back into view.
        .onChange(of: hider.arranging) { _, moving in
            if !moving { Task { await layout.capture() } }
        }
        .onChange(of: hider.collapsed) { _, hidden in
            if !hidden { Task { try? await Task.sleep(for: .seconds(1)); await layout.capture() } }
        }
    }
}

/// One icon and its switch. Icons macOS decides for itself get a note instead
/// of a switch that could not do anything.
private struct IconRow: View {
    let item: MenuBarItems.Item
    var hider: MenuBarHider
    var body: some View {
        HStack {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.dashed")
                }
            }
            .frame(width: 16, height: 16)
            Text(item.name)
            Spacer()
            switch item.kind {
            case .app, .system, .standIn:
                Toggle("Hide", isOn: Binding(
                    get: { hider.hides(item) },
                    set: { hider.setHides($0, item) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("On: hides when you click the capsule")
            case .pinned:
                Text("Always shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("macOS keeps this one in the menu bar")
            case .collateral:
                Text("Hides with the rest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("macOS hides this whenever any icon is hidden and offers no way to keep it")
            }
        }
    }
}

/// Slider with its live value beside it - dragging a slider with no readout is
/// guesswork.
private struct LabeledSlider: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unit: String
    var decimals: Int = 0

    var body: some View {
        HStack {
            Text(label)
            Slider(value: $value, in: range)
            Text(String(format: "%.\(decimals)f\(unit)", value))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// Figma's token field.
///
/// The token is read from the Keychain once, when this row appears, and written
/// back on submit. It is never held in `Settings`, so it never reaches the
/// defaults plist - a Figma personal access token reads every file the account
/// can see, and leaving one in plaintext on disk would hand that to anything
/// running as this user.
private struct FigmaSettings: View {
    @Bindable var settings: Settings
    @State private var token = ""
    @State private var saved = false

    var body: some View {
        Toggle("Figma files", isOn: $settings.figma)
        if settings.figma {
            SecureField("Personal access token", text: $token, prompt: Text("figd_…"))
                .onSubmit(store)
            HStack {
                TextField("Team ids", text: $settings.figmaTeams, prompt: Text("1234567890, 987654321"))
                    .onSubmit { Figma.shared.settingsChanged() }
                Button("Save", action: store).disabled(token.isEmpty)
            }
            Text(saved
                 ? "Saved to the Keychain. Files are listed when the bar opens, at "
                   + "most every 30 minutes."
                 : "Make a token at figma.com ▸ Settings ▸ Security ▸ Personal "
                   + "access tokens, with file content read access. The team id is "
                   + "the number in a team URL: figma.com/files/team/<id>/…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func store() {
        Figma.setToken(token)
        // Never keep the value on screen or in memory once it is stored.
        token = ""
        saved = true
        Figma.shared.settingsChanged()
    }
}

/// The snippet list.
///
/// Deliberately small: a name, a body, and the four placeholders. Anything more
/// is a text editor, and there is a good one on every Mac.
private struct SnippetSettings: View {
    var snippets = Snippets.shared
    @State private var name = ""
    @State private var body_ = ""
    @State private var adding = false

    var body: some View {
        DisclosureGroup("Snippets (\(snippets.items.count))", isExpanded: $adding) {
            ForEach(snippets.items) { snippet in
                HStack {
                    Text(snippet.name).bold()
                    Text(snippet.body.split(whereSeparator: \.isNewline).joined(separator: " "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Remove") { snippets.remove(snippet) }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
            }
            Divider()
            TextField("Name", text: $name, prompt: Text("sig"))
            TextField("Text", text: $body_, prompt: Text("Thanks,\nAlex"), axis: .vertical)
                .lineLimit(2...5)
            HStack {
                Text("Placeholders: \(Snippets.placeholders)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add") {
                    snippets.add(name: name, body: body_)
                    name = ""
                    body_ = ""
                }
                .disabled(name.isEmpty || body_.isEmpty)
            }
        }
    }
}
