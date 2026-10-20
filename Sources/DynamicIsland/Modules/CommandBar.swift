import AppKit
import Foundation

/// One field over whatever you are doing: launch an app, run an action, find a
/// file, work out a sum, or read a sentence that has an answer.
///
/// Nothing runs at rest. The app list is built when the bar opens and thrown
/// away when it closes, the file query is stopped on the way out, and the Figma
/// list is one fetch per opening at most every half hour. No index, no watcher.
///
/// Idea borrowed from Vorssaint's command bar; implementation here is this
/// project's own.
@MainActor
@Observable
final class CommandBar {
    static let shared = CommandBar()

    /// What ⏎ does, and what ⌘K offers.
    ///
    /// Every result carries a list rather than a single closure, because the
    /// first thing you want from a file is to open it and the second is to
    /// reveal it - and a bar that can only ever do the first sends you to the
    /// Finder to do the second.
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let run: @MainActor () -> Void
    }

    struct Result: Identifiable {
        let id = UUID()
        var title: String
        var subtitle: String
        var symbol: String
        /// Heading this result sits under. Results are already in section
        /// order, so the view starts a new heading whenever this changes.
        var section: String
        /// A real file or app icon, where one beats a glyph.
        var icon: NSImage?
        /// Remote artwork - Figma's own thumbnail of the file.
        var thumbnail: URL?
        /// Set on the one result that is an answer rather than a destination.
        var card: Interpret.Card?
        /// Set on a result that is one of the bar's replies, which the view draws
        /// from `Answers.shared` as it moves from thinking to answered.
        var exchange: Answers.Exchange.ID?
        /// Match score after usage has been folded in. Orders results inside a
        /// section, and orders the sections against each other.
        var rank: Int = 0
        /// What `Frecency` counts this result as. Nil for results that should
        /// not be learned from - an answer, a web fallback.
        var frecencyKey: String?
        var actions: [Action]

        /// ⏎ runs the first action. A result with none is not offered.
        @MainActor func run() { actions.first?.run() }
    }

    private(set) var query = "" {
        didSet { rebuild() }
    }
    private(set) var results: [Result] = []
    private(set) var selection = 0
    /// Whether the ⌘K list is up. Held here rather than in the view so that
    /// arrow keys can be routed to whichever list is in front.
    var showingActions = false

    /// Applications on disk, gathered when the bar opens.
    private var applications: [URL] = []

    private init() {
        FileSearch.shared.onChange = { [weak self] in self?.rebuild() }
        Figma.shared.onChange = { [weak self] in self?.rebuild() }
        Answers.shared.onChange = { [weak self] in self?.rebuild() }
    }

    func setQuery(_ text: String) {
        query = text
    }

    // MARK: - Opening

    func prepare() {
        Answers.shared.opened()
        Clipboard.shared.capture()
        // Before the window activates - see `MenuSearch.prepare`.
        MenuSearch.shared.prepare()
        applications = Self.installedApplications()
        FileSearch.shared.reset()
        Figma.shared.refreshIfStale()
        query = ""
        showingActions = false
        rebuild()
    }

    func close() {
        // The one line that keeps this free at rest: a gathered query keeps
        // posting updates as the disk changes for as long as it is alive.
        FileSearch.shared.reset()
        MenuSearch.shared.close()
        // Not forgotten: an answer still on its way is shown under the notch,
        // and the conversation is there again on the next opening.
        Answers.shared.closed()
        applications = []
        results = []
        query = ""
        selection = 0
        showingActions = false
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selection = index
    }

    var selected: Result? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func runSelected() {
        // Recorded before running, because running usually closes the bar and
        // `close()` clears the selection.
        Frecency.record(selected?.frecencyKey)
        selected?.run()
    }

    /// Any action on a result counts as having wanted that result - copying a
    /// file's path is as much a choice as opening it.
    func run(_ action: Action) {
        showingActions = false
        Frecency.record(selected?.frecencyKey)
        action.run()
    }

    // MARK: - Building results

    private func rebuild() {
        let text = query.trimmingCharacters(in: .whitespaces)
        FileSearch.shared.search(text)
        // An empty field after a question shows the latest reply, not nothing.
        // The earlier ones are drawn above it as the conversation.
        guard !text.isEmpty else {
            results = Answers.shared.exchanges.last.map { [reply($0)] } ?? []
            selection = 0; showingActions = false; return
        }
        // An answer is pinned to the top. It is not competing with the list -
        // it is what the line you typed evaluates to.
        var found: [Result] = []
        if let card = Interpret.card(for: text) { found.append(answer(card)) }
        if let sum = evaluate(text) { found.append(sum) }

        // Everything else is grouped, and the groups are ordered by their best
        // member rather than by a fixed list. Fixed order is what stops usage
        // from ever reaching the top: with Commands always above Applications,
        // the app you open twenty times a day still loses to a command that
        // merely matches, however much the ranking has learned.
        var groups: [(section: String, results: [Result])] = []
        func add(_ section: String, _ results: [Result]) {
            guard !results.isEmpty else { return }
            groups.append((section, results))
        }
        // The verbs are explicit - `note …` and `timer …` mean exactly that -
        // so they lead the commands they share a heading with.
        add("Commands", verbs(text) + actions(matching: text))
        add("Snippets", snippets(matching: text))
        add("Applications", apps(matching: text))
        add(MenuSearch.shared.appName.isEmpty ? "Menu" : "\(MenuSearch.shared.appName) menu",
            menus(matching: text))
        // A line that evaluated is a sum or a conversion, not a file name:
        // "4-4" matched olbers_v44.mp4 and a screenshot taken at 3:01:44.
        add("Files", found.isEmpty ? files() : [])
        add("Figma", figma(matching: text))
        add("Clipboard", clips(matching: text))

        groups.sort { left, right in
            (left.results.map(\.rank).max() ?? 0) > (right.results.map(\.rank).max() ?? 0)
        }
        var listed: [Result] = []
        for group in groups { listed += group.results }
        if found.isEmpty, listed.isEmpty { listed = fallbacks(for: text) }

        // A calendar or weather question goes straight under the answer
        // cards, so ⏎ asks. Any other line is not offered as a question.
        let asking = Answers.canAnswer(text) ? [ask(text)] : []
        results = Array((found + asking + listed).prefix(10))
        // Results arrive asynchronously, so the selection has to survive a
        // rebuild it did not ask for - otherwise a file landing half a second
        // after you stopped typing silently moves what ⏎ will run.
        selection = min(selection, max(results.count - 1, 0))
        if showingActions, selected == nil { showingActions = false }
    }

    /// Last result, so `ans` means what it does on a calculator.
    private(set) var answer: Double?

    // MARK: - Cards

    private func answer(_ card: Interpret.Card) -> Result {
        Result(
            title: card.to,
            subtitle: card.toCaption,
            symbol: card.symbol,
            section: card.section,
            card: card,
            actions: [
                Action(title: "Copy answer", symbol: "doc.on.doc") { Self.put(card.copy) },
                Action(title: "Paste into the app behind", symbol: "arrow.down.doc") {
                    Self.put(card.copy, paste: true)
                },
            ]
        )
    }

    /// Sums, powers, trigonometry, logs, combinatorics and stats.
    ///
    /// ponytail: the parsing lives in `Calculator`, which is pure and tested.
    /// This is only the bit that decides whether a line looks like maths at all.
    private func evaluate(_ text: String) -> Result? {
        // A bare word is an app search, not a broken expression - so require
        // something arithmetic before trying. A lone number is not a sum either.
        let hasDigit = text.rangeOfCharacter(from: .decimalDigits) != nil
        let hasOperator = text.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^%!√×÷")) != nil
        let hasCall = text.contains("(")
        let hasLetters = text.contains(where: { $0.isLetter })
        // A bare `e` or `pi` is a valid expression but almost never meant as
        // one - it is someone typing the start of an app name. Require an
        // operator, a call, or digits mixed with letters like `2pi`.
        guard hasOperator || hasCall || (hasDigit && hasLetters) else { return nil }

        let degrees = Settings.shared.calculatorDegrees
        guard let value = Calculator.evaluate(text, degrees: degrees, answer: answer) else { return nil }
        let formatted = Calculator.format(value)

        // The angle unit is worth a caption only where there is an angle - on
        // `4-4` it read as a label nobody could account for.
        let trig = text.range(of: #"(?<![a-z])(a?(sin|cos|tan)|sec|csc|cot)(?!h)"#,
                              options: [.regularExpression, .caseInsensitive]) != nil
        let card = Interpret.Card(
            from: Self.typeset(text),
            fromCaption: trig ? (degrees ? "Degrees" : "Radians") : "",
            to: formatted,
            toCaption: Self.spelledOut(value),
            copy: formatted,
            symbol: "equal.square",
            section: "Calculator"
        )
        return Result(
            title: formatted,
            subtitle: text,
            symbol: "equal.square",
            section: "Calculator",
            card: card,
            actions: [
                Action(title: "Copy answer", symbol: "doc.on.doc") { [weak self] in
                    self?.answer = value
                    Self.put(formatted)
                },
                Action(title: "Paste into the app behind", symbol: "arrow.down.doc") { [weak self] in
                    self?.answer = value
                    Self.put(formatted, paste: true)
                },
                Action(title: "Open the calculator", symbol: "plusminus") {
                    CalculatorWindow.shared.show()
                    CommandBarWindow.shared.hide()
                },
            ]
        )
    }

    // MARK: - Answers

    private func ask(_ question: String) -> Result {
        Result(
            title: question, subtitle: "Ask", symbol: "text.bubble", section: "Answers",
            actions: [Action(title: "Ask", symbol: "text.bubble") { [weak self] in
                Answers.shared.ask(question)
                // Cleared so the reply has the bar, and the next line typed is
                // the follow-up.
                self?.query = ""
            }]
        )
    }

    /// Tab: whatever is typed is asked, from any row.
    func askTyped() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Answers.shared.ask(text)
        query = ""
    }

    private func reply(_ exchange: Answers.Exchange) -> Result {
        let actions: [Action]
        switch exchange.phase {
        case .answered(let reply):
            var list: [Action] = []
            switch reply {
            case .agenda(let agenda):
                let first = agenda.days.first?.rows.first { !$0.isFree }
                list.append(Action(title: "Open in Calendar", symbol: "calendar") {
                    CalendarPeek.open(externalID: first?.externalID)
                    CommandBarWindow.shared.hide()
                })
            case .weather:
                list.append(Action(title: "Open Weather", symbol: "cloud.sun") {
                    Weather.shared.openApp()
                    CommandBarWindow.shared.hide()
                })
            case .text:
                break
            }
            list.append(Action(title: "Copy answer", symbol: "doc.on.doc") { Self.put(reply.copy) })
            list.append(Action(title: "Paste into the app behind", symbol: "arrow.down.doc") {
                Self.put(reply.copy, paste: true)
            })
            actions = list
        case .failed:
            let id = exchange.id
            actions = [Action(title: "Try again", symbol: "arrow.clockwise") { Answers.shared.retry(id) }]
        case .thinking:
            actions = []
        }
        return Result(
            title: exchange.question, subtitle: "Answer", symbol: "text.bubble", section: "Answers",
            exchange: exchange.id, actions: actions
        )
    }

    /// `4-4` → `4 − 4`, `6*7` → `6 × 7`: the operators a printed sum uses,
    /// spaced. A sign stays a sign - `-4`, `2*-3`, and the `e-5` of `2e-5`.
    private static func typeset(_ text: String) -> String {
        let operators: [Character: String] = ["+": "+", "-": "−", "*": "×", "×": "×", "/": "÷", "÷": "÷"]
        var out = ""
        var previous: Character?
        var beforePrevious: Character?
        for character in text where !character.isWhitespace {
            let exponent = (previous == "e" || previous == "E") && (beforePrevious?.isNumber ?? false)
            if let symbol = operators[character], let left = previous,
               left.isNumber || left.isLetter || ")%!π".contains(left), !exponent {
                out += " \(symbol) "
            } else {
                out.append(character == "-" ? "−" : character)
            }
            beforePrevious = previous
            previous = character
        }
        return out
    }

    /// "Zero", "One thousand two hundred thirty-four" - the way a calculator
    /// app confirms a result in words. Whole numbers only, and only while the
    /// words still fit under the number.
    private static func spelledOut(_ value: Double) -> String {
        guard value == value.rounded(), abs(value) < 1e9 else { return "" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        guard let words = formatter.string(from: NSNumber(value: value)), words.count <= 44 else { return "" }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Above anything a match score can reach. A line beginning with the verb
    /// is not a guess about what was meant.
    private let verbRank = 10_000

    /// How much a match in each source is worth against a match in another.
    /// Applications lead because they are few and chosen; files trail because
    /// a disk holds hundreds of thousands of them and a short one scores well
    /// on a short query by accident. See `Frecency.rank`.
    private static let commandWeight = 1.2
    private static let appWeight = 1.3
    private static let fileWeight = 0.7
    /// A snippet is summoned by a name you chose, so a match is deliberate.
    private static let snippetWeight = 1.3
    /// The menus of the app you were just in: relevant by definition, but they
    /// are long sentences and there are hundreds of them.
    private static let menuWeight = 1.1

    /// Two things worth typing rather than clicking: `note buy milk` files a
    /// note, `timer 10` (or `10m`) starts a timer. Checked first, because a line
    /// that starts with the verb means exactly that.
    private func verbs(_ text: String) -> [Result] {
        let lower = text.lowercased()
        if let draft = CalendarAnswers.draft(text) {
            return [Result(
                title: "Add “\(draft.title)” to Calendar", subtitle: draft.summary, symbol: "calendar.badge.plus",
                section: "Commands", rank: verbRank,
                actions: [Action(title: "Add to Calendar", symbol: "calendar.badge.plus") {
                    let saved = CalendarAnswers.save(draft)
                    CommandBarWindow.shared.hide()
                    HUD.shared.show(.utility(symbol: saved ? "calendar.badge.checkmark" : "exclamationmark.triangle",
                                             title: saved ? "Added to Calendar" : "Couldn't add it",
                                             detail: saved ? "\(draft.title) · \(draft.summary)" : "Calendar refused the event"),
                                    for: 2.4)
                }]
            )]
        }
        if lower.hasPrefix("note "), case let body = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces), !body.isEmpty {
            return [Result(
                title: "Add note: \(body)", subtitle: "Notes", symbol: "square.and.pencil",
                section: "Commands", rank: verbRank,
                actions: [Action(title: "Add note", symbol: "square.and.pencil") {
                    Notes.shared.add(text: body)
                    CommandBarWindow.shared.hide()
                    HUD.shared.show(.utility(symbol: "square.and.pencil", title: "Note added", detail: body), for: 1.8)
                }]
            )]
        }
        let spoken = lower.replacingOccurrences(of: "timer", with: "")
            .replacingOccurrences(of: "minutes", with: "").replacingOccurrences(of: "min", with: "")
            .replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces)
        if lower.contains("timer") || lower.hasSuffix("m") || lower.hasSuffix("min"),
           let minutes = Double(spoken), minutes > 0, minutes <= 24 * 60 {
            let label = minutes == minutes.rounded() ? "\(Int(minutes))" : String(format: "%.1f", minutes)
            return [Result(
                title: "Start a \(label)-minute timer", subtitle: "Clock", symbol: "timer",
                section: "Commands", rank: verbRank,
                actions: [Action(title: "Start timer", symbol: "timer") {
                    CountdownTimer.shared.start(minutes: minutes)
                    CommandBarWindow.shared.hide()
                    HUD.shared.show(.utility(symbol: "timer", title: "Timer started", detail: "\(label) min"), for: 1.8)
                }]
            )]
        }
        return []
    }

    /// The app's own one-press actions, reachable by name.
    private func actions(matching text: String) -> [Result] {
        let utilities = Utilities.shared
        let all: [(String, String, @MainActor () -> Void)] = [
            ("Mute microphone", "mic.slash.fill", { utilities.toggleMicMute() }),
            ("Lock screen", "lock.fill", { utilities.lockScreen() }),
            ("Sleep display", "moon.fill", { utilities.sleepDisplays() }),
            ("Eject disks", "eject.fill", { utilities.ejectAll() }),
            ("Show hidden files", "eye.fill", { utilities.toggleHiddenFiles() }),
            ("Hide desktop icons", "menubar.dock.rectangle", { utilities.toggleDesktopIcons() }),
            ("Clean link", "link", { utilities.cleanClipboardURL() }),
            ("Pick colour", "eyedropper", { utilities.pickColour() }),
            ("Restart Finder", "arrow.clockwise", { utilities.restartFinder() }),
            ("Copy IP address", "wifi", { utilities.copyLocalIP() }),
            ("Toggle dark mode", "circle.lefthalf.filled", { utilities.toggleDarkMode() }),
            ("Keep awake", "cup.and.saucer.fill", { utilities.keepAwake(minutes: 60) }),
            ("Camera mirror", "video.fill", { CameraPreview.shared.toggle() }),
            ("Copy text from screen", "text.viewfinder", { ScreenOCR.shared.capture() }),
            ("Paste without formatting", "textformat", { utilities.pastePlainText() }),
            ("Calculator", "equal.square", { CalculatorWindow.shared.show() }),
            ("Eye breaks on or off", "eye", { Settings.shared.eyeBreak.toggle() }),
            ("Play to several outputs", "square.stack.3d.up", {
                PanelManager.shared.focusIsland(tab: .home)
            }),
            ("Convert a file", "arrow.triangle.2.circlepath", {
                // Before opening: the Tools tab reads its pane once, as it appears.
                Settings.shared.toolsMode = "convert"
                PanelManager.shared.focusIsland(tab: .tools)
            }),
            ("Degrees for trigonometry", "angle", { Settings.shared.calculatorDegrees = true }),
            ("Radians for trigonometry", "angle", { Settings.shared.calculatorDegrees = false }),
        ]
        return all
            .compactMap { title, symbol, action -> (Int, Result)? in
                guard let score = Self.score(title, query: text, tight: true) else { return nil }
                let key = "command:\(title)"
                let rank = Frecency.rank(score, key, weight: Self.commandWeight)
                return (rank, Result(
                    title: title, subtitle: "Action", symbol: symbol, section: "Commands",
                    rank: rank, frecencyKey: key,
                    actions: [Action(title: "Run", symbol: symbol) {
                        action()
                        CommandBarWindow.shared.hide()
                    }]
                ))
            }
            .sorted { $0.0 > $1.0 }
            .prefix(4)
            .map(\.1)
    }

    private func apps(matching text: String) -> [Result] {
        applications
            .compactMap { url -> (Int, Result)? in
                let name = url.deletingPathExtension().lastPathComponent
                guard let score = Self.score(name, query: text) else { return nil }
                // Keyed by path, not by name: two copies of an app in different
                // folders are two different things to launch.
                let key = "app:\(url.path)"
                let rank = Frecency.rank(score, key, weight: Self.appWeight)
                return (rank, Result(
                    title: name,
                    subtitle: "Application",
                    symbol: "app.fill",
                    section: "Applications",
                    icon: NSWorkspace.shared.icon(forFile: url.path),
                    rank: rank,
                    frecencyKey: key,
                    actions: [
                        Action(title: "Open", symbol: "arrow.up.forward.app") {
                            NSWorkspace.shared.open(url)
                            CommandBarWindow.shared.hide()
                        },
                        Action(title: "Reveal in Finder", symbol: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                            CommandBarWindow.shared.hide()
                        },
                        Action(title: "Copy path", symbol: "doc.on.doc") { Self.put(url.path) },
                    ]
                ))
            }
            .sorted { $0.0 > $1.0 }
            .prefix(4)
            .map(\.1)
    }

    /// Spotlight has already ordered these by when they were last used, which
    /// is a better signal than a name match alone. That order is kept as a
    /// tiebreaker on top of the same match score everything else is ranked by,
    /// so a file can be compared against an app rather than sitting in a
    /// section that is always above or always below one.
    private func files() -> [Result] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return FileSearch.shared.results.enumerated().map { index, url in
            let name = url.lastPathComponent
            let key = "file:\(url.path)"
            let base = (Self.score(name, query: text) ?? 0) + max(0, 18 - index * 3)
            let rank = Frecency.rank(base, key, weight: Self.fileWeight)
            return Result(
                title: name,
                subtitle: FileSearch.folder(of: url),
                symbol: "doc",
                section: "Files",
                icon: FileSearch.icon(for: url),
                rank: rank,
                frecencyKey: key,
                actions: [
                    Action(title: "Open", symbol: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(url)
                        CommandBarWindow.shared.hide()
                    },
                    Action(title: "Reveal in Finder", symbol: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        CommandBarWindow.shared.hide()
                    },
                    Action(title: "Park on the shelf", symbol: "tray.and.arrow.down") {
                        Shelf.shared.add([url])
                        CommandBarWindow.shared.hide()
                        HUD.shared.show(
                            .utility(symbol: "tray.and.arrow.down.fill", title: "On the shelf",
                                     detail: url.lastPathComponent), for: 1.8)
                    },
                    Action(title: "Copy path", symbol: "doc.on.doc") { Self.put(url.path) },
                ]
            )
        }
        .sorted { $0.rank > $1.rank }
        .prefix(4)
        .map { $0 }
    }

    private func figma(matching text: String) -> [Result] {
        guard Settings.shared.figma else { return [] }
        return Figma.shared.files
            .compactMap { file -> (Int, Figma.File)? in
                guard let score = Self.score(file.name, query: text) else { return nil }
                return (Frecency.rank(score, "figma:\(file.key)"), file)
            }
            .sorted { $0.0 > $1.0 }
            .prefix(3)
            .map { rank, file in
                Result(
                    title: file.name,
                    subtitle: file.project.isEmpty ? "Figma" : file.project,
                    symbol: "square.on.square.dashed",
                    section: "Figma",
                    thumbnail: file.thumbnail,
                    rank: rank,
                    frecencyKey: "figma:\(file.key)",
                    actions: [
                        Action(title: "Open in Figma", symbol: "arrow.up.forward.app") {
                            Figma.shared.open(file)
                            CommandBarWindow.shared.hide()
                        },
                        Action(title: "Open in the browser", symbol: "safari") {
                            NSWorkspace.shared.open(file.web)
                            CommandBarWindow.shared.hide()
                        },
                        Action(title: "Copy link", symbol: "link") { Self.put(file.web.absoluteString) },
                    ]
                )
            }
    }

    /// Text you keep retyping, by the name you gave it.
    private func snippets(matching text: String) -> [Result] {
        Snippets.shared.items
            .compactMap { snippet -> (Int, Result)? in
                guard let score = Self.score(snippet.name, query: text) else { return nil }
                let key = "snippet:\(snippet.id)"
                let rank = Frecency.rank(score, key, weight: Self.snippetWeight)
                // Expanded when it is used, not when it is listed: a snippet
                // holding {clipboard} would otherwise show whatever was copied
                // when you opened the bar, and go stale as you type.
                let preview = snippet.body.split(whereSeparator: \.isNewline)
                    .joined(separator: " ").trimmingCharacters(in: .whitespaces)
                return (rank, Result(
                    title: snippet.name,
                    subtitle: preview,
                    symbol: "text.append",
                    section: "Snippets",
                    rank: rank,
                    frecencyKey: key,
                    actions: [
                        Action(title: "Paste into the app behind", symbol: "arrow.down.doc") {
                            Self.put(Snippets.shared.expand(snippet.body), paste: true)
                        },
                        Action(title: "Copy", symbol: "doc.on.doc") {
                            Self.put(Snippets.shared.expand(snippet.body))
                        },
                    ]
                ))
            }
            .sorted { $0.0 > $1.0 }
            .prefix(3)
            .map(\.1)
    }

    /// Commands from the menus of the app that was in front.
    private func menus(matching text: String) -> [Result] {
        MenuSearch.shared.search(text)
            .map { (Frecency.rank($0.0, key(for: $0.1), weight: Self.menuWeight), $0.1) }
            .sorted { $0.0 > $1.0 }
            .prefix(4)
            .map { rank, item in
                Result(
                    title: item.title,
                    // The path is what tells two "Export…" apart, and the
                    // shortcut is how you stop needing the bar for it.
                    subtitle: item.shortcut.isEmpty ? item.path : "\(item.path)   \(item.shortcut)",
                    symbol: "filemenu.and.selection",
                    section: MenuSearch.shared.appName.isEmpty ? "Menu" : "\(MenuSearch.shared.appName) menu",
                    rank: rank,
                    frecencyKey: key(for: item),
                    actions: [Action(title: "Run", symbol: "filemenu.and.selection") {
                        CommandBarWindow.shared.hide()
                        MenuSearch.shared.press(item)
                    }]
                )
            }
    }

    private func key(for item: MenuSearch.Item) -> String {
        "menu:\(MenuSearch.shared.appName):\(item.title)"
    }

    /// Clipboard history, left at rank 0 so it sorts below everything else.
    /// Typing a name should find the app first; a clip that happens to contain
    /// the same word is what you meant only when nothing else matched.
    private func clips(matching text: String) -> [Result] {
        guard text.count >= 2 else { return [] }
        return Clipboard.shared.ordered
            .filter { $0.text.localizedCaseInsensitiveContains(text) }
            .prefix(2)
            .map { clip in
                let flattened = clip.text.split(whereSeparator: \.isNewline)
                    .joined(separator: " ").trimmingCharacters(in: .whitespaces)
                return Result(
                    title: flattened,
                    subtitle: "Copied earlier",
                    symbol: "doc.on.clipboard",
                    section: "Clipboard",
                    actions: [
                        Action(title: "Copy", symbol: "doc.on.doc") {
                            Clipboard.shared.copy(clip)
                            CommandBarWindow.shared.hide()
                            HUD.shared.show(.utility(symbol: "doc.on.clipboard.fill", title: "Copied",
                                                     detail: "From clipboard history"), for: 1.6)
                        },
                    ] + (clip.isText
                         ? [Action(title: "Paste into the app behind", symbol: "arrow.down.doc") {
                                Self.put(clip.text, paste: true)
                            }]
                         // An image or a file copy has no text to type; its
                         // title is a label, and pasting that would be wrong.
                         : [])
                )
            }
    }

    /// What to offer when nothing matched.
    ///
    /// An empty panel under a typed query reads as broken - the bar looks like
    /// it failed rather than like the words were not a thing on this Mac. These
    /// are the four places that text could still mean something, and each is a
    /// single URL.
    private func fallbacks(for text: String) -> [Result] {
        let section = "Use “\(text)” with…"
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let word = text.split(separator: " ").first.map(String.init) ?? text
        let places: [(String, String, String, String)] = [
            ("Define word", "Dictionary", "character.book.closed",
             "dict://\(word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word)"),
            ("Search Google", "Browser", "magnifyingglass", "https://www.google.com/search?q=\(encoded)"),
            ("Search DuckDuckGo", "Browser", "magnifyingglass", "https://duckduckgo.com/?q=\(encoded)"),
            ("Search GitHub", "Browser", "chevron.left.forwardslash.chevron.right",
             "https://github.com/search?q=\(encoded)"),
        ]
        return places.compactMap { title, subtitle, symbol, string in
            guard let url = URL(string: string) else { return nil }
            return Result(
                title: title, subtitle: subtitle, symbol: symbol, section: section,
                actions: [Action(title: "Open", symbol: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(url)
                    CommandBarWindow.shared.hide()
                }]
            )
        }
    }

    // MARK: - Matching

    /// How well `text` answers what was typed, or nil if it does not.
    ///
    /// A substring test cannot find "Visual Studio Code" from `vsc`, which is
    /// how everybody types it. This is a subsequence match instead, scored so
    /// that letters starting a word and letters found next to each other beat
    /// letters scattered through the middle - the difference between `saf`
    /// putting Safari first and putting Sound Safety Monitor first.
    ///
    /// `tight` additionally demands that every letter either continues the
    /// previous one or starts a word. Command titles are sentences, and across
    /// a sentence a plain subsequence match means almost nothing: `term` found
    /// "Toggle dark mode" and, because commands are listed above applications,
    /// put it over Terminal. Application names are short enough not to need it,
    /// and demanding it there would stop `tunes` finding iTunes.
    static func score(_ text: String, query: String, tight: Bool = false) -> Int? {
        let haystack = Array(text.lowercased())
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }

        var score = 0
        var cursor = 0
        var previous = -2
        for character in needle {
            // Taking the first occurrence and testing it afterwards is what a
            // naive matcher does, and under `tight` it is wrong: `colour` found
            // the c in "Pi(c)k colour", failed the word-start test on it, and
            // gave up while the real match sat three letters later. So the
            // search itself skips to a position that qualifies.
            var found: Int?
            var index = cursor
            while index < haystack.count {
                if haystack[index] == character {
                    let runs = index == previous + 1
                    let starts = index == 0 || " -_/.".contains(haystack[index - 1])
                    if !tight || runs || starts { found = index; break }
                }
                index += 1
            }
            guard let hit = found else { return nil }
            let runs = hit == previous + 1
            let starts = hit == 0 || " -_/.".contains(haystack[hit - 1])
            if runs { score += 10 }
            if starts { score += 14 }
            // Gaps cost, but a long name should not be disqualified by one.
            score -= min(hit - previous - 1, 6)
            previous = hit
            cursor = hit + 1
        }
        if haystack.starts(with: needle) { score += 35 }
        // Shorter names win ties: "Mail" over "Mailbox Assistant".
        score += max(0, 24 - haystack.count / 2)
        return score
    }

    // MARK: - Clipboard

    /// Copy, and optionally put it where the cursor was.
    ///
    /// Pasting needs Accessibility, which this app asks for nowhere and works
    /// without everywhere. Without it the text is still on the clipboard and
    /// the HUD says to press ⌘V, which is the same outcome one keystroke later.
    private static func put(_ string: String, paste: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        Clipboard.shared.lastChange = NSPasteboard.general.changeCount
        CommandBarWindow.shared.hide()

        guard paste, AXIsProcessTrusted() else {
            HUD.shared.show(.utility(symbol: "doc.on.clipboard.fill", title: "Copied",
                                     detail: paste ? "Press ⌘V" : string), for: 1.6)
            return
        }
        // A beat, for the same reason the clipboard rows wait: the keystroke has
        // to land after the bar has given the focus back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Clipboard.pressCommandV()
        }
    }

    /// One shallow pass over the usual folders. No recursion into bundles, no
    /// index kept between openings.
    private static func installedApplications() -> [URL] {
        let manager = FileManager.default
        let folders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
            // Safari and friends moved into the cryptex; without this the one
            // app people search for most is the one that never appears.
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"),
        ]
        return folders.flatMap { folder in
            (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
        }
        .filter { $0.pathExtension == "app" }
    }
}
