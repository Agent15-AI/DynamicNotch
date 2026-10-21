import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Offscreen pictures of every tab, then exit. See `RenderCheck`.
        if let index = CommandLine.arguments.firstIndex(of: "--render"), index + 1 < CommandLine.arguments.count {
            RenderCheck.run(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-bar"), index + 1 < CommandLine.arguments.count {
            RenderCheck.bar(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        installEditMenu()
        StatusItem.shared.install()
        Updater.shared.start()
        Hotkeys.shared.install()
        FinderKeys.shared.install()
        PanelManager.shared.rebuild()
        PanelManager.shared.watchLockScreen()
        PanelManager.shared.watchPointer()
        PanelManager.shared.watchFullscreen()
        NowPlaying.shared.watchWake()

        AudioMonitor.shared.start()
        Battery.shared.start()
        BluetoothWatch.shared.start()
        Downloads.shared.start()
        Screenshots.shared.start()
        DiskImages.shared.start()
        Sensors.shared.start()
        MenuBarHider.shared.start()
        // Launch at login is on from the first run; the switch in Settings →
        // General still turns it off, and this never overrides that choice.
        if !UserDefaults.standard.bool(forKey: "launchAtLoginDefaulted") {
            Settings.shared.launchAtLogin = true
            UserDefaults.standard.set(true, forKey: "launchAtLoginDefaulted")
        }
        Alarms.shared.start()
        CountdownTimer.shared.restoreState()
        Stopwatch.shared.restoreState()
        CalendarPeek.shared.start()
        DeviceBatteries.shared.start()
        Clipboard.shared.start()
        Clipboard.shared.watchLock()
        EyeBreak.shared.start()
        ExternalBrightness.shared.refresh()

        // `open -a DynamicIsland --args --settings` opens settings without
        // hunting for the menu bar item.
        if CommandLine.arguments.contains("--settings") { SettingsWindow.shared.show() }
        // `open -a DynamicIsland --args --calculator`, for when the keyboard is
        // busy, or Accessibility is not granted.
        if CommandLine.arguments.contains("--calculator") { CalculatorWindow.shared.show() }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                PanelManager.shared.toggleFocusedIsland()
            }
        }
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { HUD.shared.preview() }
        }

        // The idle island is invisible by default, so a first launch otherwise
        // looks like nothing happened at all.
        if !Settings.shared.onboarded {
            Settings.shared.onboarded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                HUD.shared.show(.welcome, for: 7)
            }
        }

        observeAudio()
        observeBattery()
        observeRecording()
        observeSettings()

        // Display layout changes: docking, a lid close, a resolution change.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PanelManager.shared.scheduleRebuild()
                // A monitor plugged in or unplugged changes which DDC channels
                // exist, and the sliders are built from that list.
                ExternalBrightness.shared.refresh()
            }
        }
    }

    /// Standard editing shortcuts.
    ///
    /// An accessory app shows no menu bar, so it is easy to assume it needs no
    /// menu. It does: `NSApp.mainMenu` is what matches ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z,
    /// and with no main menu those keys match nothing at all. Typing in the
    /// notes tab worked and Select All did nothing, which is exactly that.
    ///
    /// ponytail: the menu *is* the platform mechanism. Hand-rolling
    /// `performKeyEquivalent` would reimplement the responder chain that already
    /// routes these to whichever text view is focused.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit

        let menu = NSMenu()
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    /// A tap and its aggregate device outlive the process that made them if they
    /// are not destroyed, and a leaked muted tap leaves an app silent until the
    /// next login. Quitting must take them with it.
    func applicationWillTerminate(_ notification: Notification) {
        VolumeMixer.shared.stopAll()
        // Same rule, and the sharper version of it: the multi-output device *is*
        // the system's default output while it exists, so leaking one leaves a Mac
        // playing into a device that no longer has a process behind it.
        MultiOutput.shared.stopAll()
        CameraPreview.shared.close()
        // A child process outlives its parent. Left running, the helper streamed
        // into a closed pipe until the next launch's `killOrphans`.
        NowPlaying.shared.stop()
        // Their writes wait half a second for typing to stop; quitting inside
        // that window lost the last edit.
        Notes.shared.flush()
        Snippets.shared.flush()
        Clipboard.shared.flush()
    }

    /// `withObservationTracking` fires once per change, so each handler re-arms
    /// itself. Event-driven - nothing polls.
    private func track(_ read: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
        withObservationTracking(read) {
            Task { @MainActor in
                onChange()
                self.track(read, onChange: onChange)
            }
        }
    }

    private func observeAudio() {
        let audio = AudioMonitor.shared
        // withObservationTracking only fires on change, so the initial state has
        // to be pushed explicitly or the helper never starts.
        NowPlaying.shared.nudge()
        track({ _ = audio.outputChangeCount }) {
            NowPlaying.shared.nudge()
        }
    }

    private func observeBattery() {
        let battery = Battery.shared
        track({ _ = battery.lastPlugChange }) {
            // A keep-awake held "while plugged in" has to let go the moment the
            // cable comes out.
            Utilities.shared.reevaluateCondition()
            // No first-event suppression: the launch read happens before this
            // observer exists, so the first change it sees is a real plug.
            guard Settings.shared.battery, battery.lastPlugChange != nil else { return }
            HUD.shared.show(.charging(percent: battery.percent, plugged: battery.pluggedIn), for: 2.2)
        }
    }

    private func observeRecording() {
        let audio = AudioMonitor.shared
        track({ _ = audio.inputChangeCount }) {
            guard Settings.shared.recording else { return }
            HUD.shared.show(
                .recording(app: audio.micApp, started: audio.micActive),
                for: 2.4
            )
        }
    }

    private func observeSettings() {
        let settings = Settings.shared
        track({
            _ = settings.openWidth
            _ = settings.openHeight
            _ = settings.notchHeightMode
            _ = settings.notchHeightCustom
            _ = settings.notchWidthMode
            _ = settings.notchWidthCustom
            _ = settings.externalHeight
            _ = settings.externalMatchMenuBar
            _ = settings.externalWidth
            _ = settings.hoverHeightPad
            _ = settings.hoverWidthPad
        }) {
            PanelManager.shared.resize()
        }
        track({ _ = settings.hideFromCapture }) {
            PanelManager.shared.applyCaptureExclusion()
        }
        track({ _ = settings.displayScope }) {
            PanelManager.shared.rebuild()
        }
        track({ _ = settings.nowPlaying }) {
            NowPlaying.shared.nudge()
        }
        track({ _ = settings.menuBar }) {
            MenuBarHider.shared.reload()
        }
        track({ _ = settings.upNextMinutes }) {
            CalendarPeek.shared.scheduleReminder()
        }
        track({
            _ = settings.eyeBreak
            _ = settings.eyeBreakMinutes
        }) {
            EyeBreak.shared.reload()
        }
        track({ _ = settings.plainPaste }) {
            Hotkeys.shared.setPlainPasteActive(settings.plainPaste)
        }
        track({ _ = settings.calculator }) {
            Hotkeys.shared.setCalculatorActive(settings.calculator)
        }
        track({ _ = settings.externalBrightness }) {
            ExternalBrightness.shared.refresh()
        }
        // Off releases every app the mixer had turned down; see `refresh`.
        track({ _ = settings.mixer }) {
            VolumeMixer.shared.refresh()
        }
        // Both start only if allowed and not already watching, so switching
        // one on no longer waits for the next launch.
        track({
            _ = settings.downloads
            _ = settings.screenshots
        }) {
            Downloads.shared.start()
            Screenshots.shared.start()
        }
        track({
            _ = settings.menuBar
            _ = settings.menuBarChoices
            _ = MenuBarHider.shared.collapsed
            _ = NowPlaying.shared.title
        }) {
            NowPlayingStandIn.shared.update()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
// `killall DynamicIsland` quits like the menu does. Its default action ends the
// process on the spot, skipping applicationWillTerminate - and with it the audio
// devices that must be torn down before the app goes.
signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { app.terminate(nil) }
terminate.resume()
app.run()
