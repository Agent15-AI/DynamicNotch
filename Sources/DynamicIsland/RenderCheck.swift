import AppKit
import SwiftUI

/// `DynamicIsland --render <folder>`: draws every tab of the open island, and
/// the live activities, to PNGs without putting anything on screen.
///
/// `Tools/check-notch.sh` photographs the real island, which needs an unlocked
/// screen and a pointer nobody else is using. This needs neither, so a change
/// to a view can be looked at from a script - or overnight, with the Mac
/// locked. It is a picture of the layout, not of the material: the translucent
/// background comes out flat.
///
/// Runs as its own short-lived process. Nothing that touches the menu bar, the
/// hotkeys or the notch panels is started, so it can run beside the real app.
/// Expressions drawn on their own, for checking the maths layout.
struct MathSampler: View {
    private static let lines = [
        "2x - 5 = 4", "x^2 - 5x + 6 = 0", "1/(2sqrt(x))", "integral(x^2, 0, 3)",
        "sigma(x, 1, 100)", "deriv(sin(x), 0)", "2/3 + 1/(x+1)",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.lines, id: \.self) { line in
                HStack(spacing: 20) {
                    if let tree = Calculator.tree(of: line) {
                        MathView(node: tree, size: 13, color: Theme.tertiary)
                        MathView(node: tree, size: 20, color: Theme.primary)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 420, alignment: .topLeading)
        .background(Color(white: 0.1))
    }
}

@MainActor
enum RenderCheck {
    static func run(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Battery.shared.start()
        CalendarPeek.shared.start()
        DeviceBatteries.shared.refresh()
        Clipboard.shared.start()
        Weather.shared.refreshIfStale()
        // The sources strip decides whether to exist from this list, so it has
        // to be filled before anything is drawn - the same reason the island's
        // own open does it rather than the view.
        VolumeMixer.shared.refresh()
        // Take whatever is on the clipboard now, so the Clipboard pane has a row.
        Clipboard.shared.lastChange = -1
        let settings = Settings.shared
        let saved = (settings.lastTab, settings.toolsMode, settings.shelfMode)
        Task {
            try? await Task.sleep(for: .seconds(2))
            // Every tab, plus each pane of the two tabs that have several.
            var pages: [(NotchState.Tab, String?)] = NotchState.Tab.allCases.map { ($0, nil) }
            pages += ToolsTab.Mode.allCases.map { (.tools, $0.rawValue) }
            pages += ["files", "clipboard"].map { (.shelf, $0) }
            for (tab, pane) in pages {
                if let pane { if tab == .tools { settings.toolsMode = pane } else { settings.shelfMode = pane } }
                let state = makeState()
                state.open(on: tab)
                await render(state, to: folder.appendingPathComponent("tab-\(tab.rawValue)\(pane.map { "-\($0)" } ?? "").png"))
                state.collapse()
            }
            (settings.lastTab, settings.toolsMode, settings.shelfMode) = saved
            let activities: [(String, HUD.Kind)] = [
                ("bluetooth", .bluetooth(name: "Magic Keyboard", symbol: "keyboard", connected: true, battery: 10)),
                ("low-battery", .utility(symbol: "battery.25percent", title: "Magic Keyboard 10%", detail: "Charge it soon")),
                ("charging", .charging(percent: 64, plugged: true)),
                ("upcoming", .upcoming(title: "AP Physics C", detail: "In 5 min · 8:00 AM · Join", joinURL: URL(string: "https://meet.google.com/x"))),
                ("verification", .verification(code: "483920")),
                ("eye-break", .eyeBreak(until: Date().addingTimeInterval(20))),
            ]
            // The calculator is its own window rather than a tab, so it is drawn
            // here directly - same offscreen host, same reason.
            // Something to look at: a fraction, an equation and a root, so the
            // maths layout is in the picture rather than an empty panel.
            let calculator = CalculatorPanel.shared
            calculator.clearAll()
            for line in ["3/5", "2x - 5 = 4", "deriv(sqrt(x))", "integral(x^2, 0, 3)"] {
                calculator.input = line
                calculator.commit()
            }
            calculator.input = "3x + 7 = 2x + 12"
            calculator.caret = 6
            for pad in CalculatorPanel.Pad.allCases {
                CalculatorPanel.shared.pad = pad
                await renderView(CalculatorView(), size: CGSize(width: 438, height: 650),
                                 to: folder.appendingPathComponent("calculator-\(pad.rawValue).png"))
            }
            CalculatorPanel.shared.pad = .main
            calculator.clearAll()
            // A sheet of maths on its own, away from any row layout, so a
            // clipped fraction can be told from a clipped row.
            await renderView(MathSampler(), size: CGSize(width: 520, height: 420),
                             to: folder.appendingPathComponent("math-sampler.png"))
            for (name, kind) in activities {
                HUD.shared.show(kind, for: 30)
                await render(makeState(), to: folder.appendingPathComponent("activity-\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// `DynamicIsland --render-bar <folder>`: the command bar answering
    /// calendar and weather questions from this Mac's own data, drawn as the
    /// bar draws them - one conversation, so the later pictures show the
    /// earlier answers above. Launch it with `open -n` so it reads the
    /// calendar with the app's own permission.
    static func bar(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shots: [(name: String, line: String, ask: Bool)] = [
            ("sum", "4-4", false),
            ("add", "add Gym tomorrow 5pm", false),
            ("tomorrow", "what do i have tomorrow", true),
            ("at-time", "what's on my calendar 2 weeks from now at 4pm", true),
            ("free", "am i free tomorrow afternoon", true),
            ("exams", "do i have any exams this week", true),
            ("next-week", "what do i have next week", true),
            ("weather", "whats the weather tomorrow", true),
            ("weather-friday", "will it rain on friday", true),
            ("clarify", "whats on the day after next", true),
        ]
        Task {
            for shot in shots {
                CommandBar.shared.prepare()
                if shot.ask {
                    Answers.shared.ask(shot.line)
                    try? await Task.sleep(for: .seconds(3))
                } else {
                    CommandBar.shared.setQuery(shot.line)
                }
                await renderView(CommandBarView().background(Color(white: 0.16)), size: CGSize(width: 580, height: 520),
                                 to: folder.appendingPathComponent("bar-\(shot.name).png"))
                CommandBar.shared.close()
            }
            // A follow-up being typed, with the conversation above it.
            CommandBar.shared.prepare()
            Answers.shared.ask("whats the weather")
            try? await Task.sleep(for: .seconds(3))
            CommandBar.shared.setQuery("will it rain on friday")
            await renderView(CommandBarView().background(Color(white: 0.16)), size: CGSize(width: 580, height: 520),
                             to: folder.appendingPathComponent("bar-follow-up.png"))
            NSApp.terminate(nil)
        }
    }

    private static func makeState() -> NotchState {
        let state = NotchState()
        let screen = NSScreen.screens.first { $0.notchSize != nil } ?? NSScreen.main
        state.physicalNotch = screen?.notchSize
        state.menuBarHeight = max(screen?.menubarHeight ?? 24, 24)
        return state
    }

    /// Draws any view offscreen, for the pieces that are not tabs.
    private static func renderView(_ view: some View, size: CGSize, to url: URL) async {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(900))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }

    private static func render(_ state: NotchState, to url: URL) async {
        let size = CGSize(width: Settings.shared.openWidth + 60, height: 380)
        let host = NSHostingView(rootView: NotchView(state: state).background(Color(white: 0.16)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        // Long enough for the open spring and the row stagger to settle.
        try? await Task.sleep(for: .milliseconds(1200))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }
}
