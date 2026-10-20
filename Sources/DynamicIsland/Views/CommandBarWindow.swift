import AppKit
import SwiftUI

/// The floating field the command bar lives in.
///
/// Built when first opened and torn down on close - no window is kept warm, and
/// nothing runs while it is shut.
@MainActor
final class CommandBarWindow: NSObject {
    static let shared = CommandBarWindow()

    private var window: NSPanel?

    private override init() { super.init() }

    var isOpen: Bool { window != nil }

    func toggle() {
        if isOpen { hide() } else { show() }
    }

    func show() {
        guard window == nil else { return }
        CommandBar.shared.prepare()

        // Tall enough for a card and a full list. The content hugs itself and
        // is pinned to the top, so an empty bar still draws as one field - the
        // window is a stage, not a box.
        let size = NSSize(width: 580, height: 520)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CommandBarView())

        // A fifth of the way down the screen the pointer is on, where a
        // spotlight-style field is expected to be.
        if let screen = NSScreen.underPointer {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - frame.height * 0.14
            ))
        }

        window = panel
        // The bar needs the keyboard, so unlike the island this one does
        // activate. Escape and clicking away both give it straight back.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        CommandBar.shared.close()
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }
}

extension CommandBarWindow: NSWindowDelegate {
    /// Clicking elsewhere dismisses it, the way every other launcher behaves.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in self.hide() }
    }
}

/// Internal rather than private so `RenderCheck` can draw it.
struct CommandBarView: View {
    var bar = CommandBar.shared
    @FocusState private var focused: Bool
    @State private var actionSelection = 0
    /// The list's natural height, so the bar hugs its results instead of
    /// always reserving the full 400 points under three rows.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field

            if !bar.results.isEmpty {
                Rectangle().fill(Theme.edge).frame(height: 1)
                list
                Rectangle().fill(Theme.edge).frame(height: 1)
                footer
            }
        }
        // Same treatment as the island: a dark fill *over* the material. The
        // material alone takes its tone from whatever is behind the window, so
        // on a light desktop the bar came out light grey and the white text on
        // it was unreadable.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.shell.opacity(Motion.reducedTransparency ? 1 : 0.82))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.edgeHighlight, lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if bar.showingActions, let result = bar.selected {
                ActionMenu(actions: result.actions, selection: $actionSelection)
                    .padding(.trailing, 10)
                    .padding(.bottom, 40)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        // Tab asks the typed line from any row - no arrowing down to it.
        .onKeyPress(.tab) {
            guard !bar.query.trimmingCharacters(in: .whitespaces).isEmpty else { return .ignored }
            bar.askTyped()
            return .handled
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) {
            // Escape closes the menu before it closes the bar - otherwise
            // opening the menu by accident costs you the query you typed.
            if bar.showingActions {
                withAnimation(Motion.exit) { bar.showingActions = false }
            } else {
                CommandBarWindow.shared.hide()
            }
            return .handled
        }
        // ⌘K is the one shortcut, so it is one handler rather than a monitor.
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.command), press.characters.lowercased() == "k" else {
                return .ignored
            }
            toggleActions()
            return .handled
        }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Theme.tertiary)
            TextField("Search, calculate, or ask", text: Binding(
                get: { bar.query },
                set: { bar.setQuery($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 18))
            .foregroundStyle(Theme.primary)
            .focused($focused)
            .onSubmit { submit() }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: - Results

    /// The earlier exchanges, drawn above the results: all but the latest
    /// when the field is empty (the latest is the selectable result), all of
    /// them while a follow-up is being typed.
    private var history: [Answers.Exchange] {
        let answers = Answers.shared
        if bar.query.isEmpty { return Array(answers.exchanges.dropLast()) }
        return answers.askedThisOpening ? answers.exchanges : []
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if !history.isEmpty {
                        heading("Answers", first: true)
                        // Earlier answers in a line each; the latest is the card.
                        ForEach(history) { exchange in
                            HistoryRow(exchange: exchange)
                        }
                    }
                    ForEach(Array(bar.results.enumerated()), id: \.element.id) { index, result in
                        // Results arrive in section order, so a heading is
                        // simply the point where the section name changes -
                        // and the conversation above already said "Answers".
                        if index == 0 ? !(result.section == "Answers" && !history.isEmpty)
                            : bar.results[index - 1].section != result.section {
                            // Quieter than the island's red monospaced labels:
                            // in a list this dense they outshouted the results.
                            heading(result.section, first: index == 0 && history.isEmpty)
                        }
                        Group {
                            if let id = result.exchange,
                               let exchange = Answers.shared.exchanges.first(where: { $0.id == id }) {
                                ExchangeCard(exchange: exchange, selected: index == bar.selection)
                            } else if let card = result.card {
                                AnswerCard(card: card, selected: index == bar.selection)
                            } else {
                                CommandRow(result: result, selected: index == bar.selection)
                            }
                        }
                        .id(result.id)
                        .onTapGesture { bar.select(index); submit() }
                        .onHover { if $0 { bar.select(index) } }
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, 400))
            .onChange(of: bar.selection) { _, new in
                guard bar.results.indices.contains(new) else { return }
                withAnimation(Motion.content) { proxy.scrollTo(bar.results[new].id, anchor: .center) }
            }
            // With the conversation above, the selected result - the latest
            // answer, or the row ⏎ will run - is kept in view at the bottom:
            // on opening, on each answer, and as a follow-up is typed.
            .onAppear { reveal(proxy) }
            .onChange(of: bar.results.map(\.id)) { _, _ in reveal(proxy) }
            .onChange(of: Answers.shared.exchanges) { _, _ in reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard !history.isEmpty, let selected = bar.selected else { return }
        // After this layout pass, or the row has no position to scroll to yet.
        // Top: a long answer opens at its headline, and a short one still
        // lands at the bottom, as far as the list scrolls.
        DispatchQueue.main.async { proxy.scrollTo(selected.id, anchor: .top) }
    }

    private func heading(_ title: String, first: Bool) -> some View {
        // Quieter than the island's red monospaced labels: in a list this
        // dense they outshouted the results.
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.top, first ? 4 : 12)
            .padding(.bottom, 3)
    }

    /// What ⏎, ⇥ and ⌘K do, said out loud. A bar with hidden second actions is
    /// a bar whose second actions nobody finds.
    private var footer: some View {
        HStack(spacing: 10) {
            if bar.results.contains(where: { $0.section == "Answers" }), bar.selected?.section != "Answers" {
                Text("Ask").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                KeyCap("arrow.right.to.line")
            }
            Spacer(minLength: 0)
            if let primary = bar.selected?.actions.first {
                Text(primary.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                KeyCap("return")
            }
            if (bar.selected?.actions.count ?? 0) > 1 {
                Rectangle().fill(Theme.edge).frame(width: 1, height: 14)
                Text("Actions").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                KeyCap("command")
                KeyCap("k")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    // MARK: - Keys

    private func move(_ delta: Int) {
        if bar.showingActions {
            let count = bar.selected?.actions.count ?? 0
            guard count > 0 else { return }
            actionSelection = min(max(actionSelection + delta, 0), count - 1)
        } else {
            bar.moveSelection(delta)
        }
    }

    private func submit() {
        if bar.showingActions, let actions = bar.selected?.actions,
           actions.indices.contains(actionSelection) {
            bar.run(actions[actionSelection])
        } else {
            bar.runSelected()
        }
    }

    private func toggleActions() {
        guard let result = bar.selected, result.actions.count > 1 else { return }
        actionSelection = 0
        withAnimation(Motion.content) { bar.showingActions.toggle() }
    }
}

/// An answer, not a destination.
///
/// Given the width of a row it would be a sentence to read; given a card it is
/// two numbers to compare. The captions carry what was understood, which is the
/// only way to notice a misreading before acting on it.
private struct AnswerCard: View {
    var card: Interpret.Card
    var selected: Bool

    var body: some View {
        HStack(spacing: 16) {
            side(card.from, caption: card.fromCaption, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            side(card.to, caption: card.toCaption, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(CardBackground(selected: selected))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func side(_ value: String, caption: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

/// The surface the answer cards sit on: barely there until
/// selected, then tinted the island's red.
private struct CardBackground: View {
    var selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? Theme.core.opacity(0.16) : Color.white.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.core.opacity(0.5) : Theme.edge, lineWidth: 1)
            )
    }
}

/// One question and its answer. Read from `Answers.shared` so it moves from
/// thinking to answered on its own.
private struct ExchangeCard: View {
    var exchange: Answers.Exchange
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(exchange.question)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(2)
            switch exchange.phase {
            case .thinking:
                progress("Thinking…")
            case .answered(.text(let answer)):
                Text(answer)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            case .answered(.agenda(let agenda)):
                AgendaView(agenda: agenda)
            case .answered(.weather(let report)):
                WeatherReportView(report: report)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(selected: selected))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
    }
}

/// An earlier question and the gist of its answer, one line each.
private struct HistoryRow: View {
    var exchange: Answers.Exchange

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(exchange.question)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Text(gist)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.03)))
        .padding(.bottom, 4)
    }

    private var gist: String {
        switch exchange.phase {
        case .thinking: "Thinking…"
        case .answered(let reply): reply.summary
        case .failed(let reason): reason
        }
    }
}

/// A calendar answer: a headline, then the events in calendar colours, each
/// one opening itself in Calendar when clicked.
private struct AgendaView: View {
    var agenda: CalendarAnswers.Agenda

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agenda.headline)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                if !agenda.subtitle.isEmpty {
                    Text(agenda.subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            if !agenda.days.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(agenda.days, id: \.date) { day in
                        if agenda.days.count > 1 {
                            Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.tertiary)
                                .padding(.top, day.date == agenda.days.first?.date ? 0 : 8)
                                .padding(.bottom, 2)
                        }
                        ForEach(day.rows) { AgendaRow(row: $0) }
                    }
                }
            }
            if let note = agenda.note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Text(agenda.source)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private struct AgendaRow: View {
    var row: CalendarAnswers.Row
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(row.isFree ? Color.green.opacity(0.7) : row.color)
                .frame(width: 3, height: 18)
            Text(CalendarAnswers.time(row))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 112, alignment: .leading)
            Text(row.title)
                .font(.system(size: 13.5, weight: row.isFree ? .regular : .medium))
                .foregroundStyle(row.isFree ? Color.green.opacity(0.85) : Theme.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !row.isFree {
                Text(row.calendar)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering && !row.isFree ? Color.white.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard !row.isFree else { return }
            CalendarAnswers.open(row)
            CommandBarWindow.shared.hide()
        }
        .help(row.isFree ? "" : "Open in Calendar")
    }
}

/// A weather answer: the sky as a symbol, the temperature large, the rest in
/// a column beside it.
private struct WeatherReportView: View {
    var report: Weather.Report

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: Weather.symbol(code: report.code, isDay: report.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 38))
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(report.temperature ?? report.forecast.high)°")
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.primary)
                Text(report.day.map { "\($0) · \(Weather.summary(code: report.code))" } ?? Weather.summary(code: report.code))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.primary)
                Text(report.place)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 5) {
                detail("thermometer.medium", "H \(report.forecast.high)°  L \(report.forecast.low)°")
                if let rain = report.forecast.rain { detail("drop.fill", "\(rain)% rain") }
                if let feels = report.feels { detail("person.fill", "Feels like \(feels)°") }
            }
        }
    }

    private func detail(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.secondary)
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.tertiary).frame(width: 14)
        }
    }
}

private struct CommandRow: View {
    var result: CommandBar.Result
    var selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Theme.secondary : Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.core.opacity(0.22) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder private var icon: some View {
        if let thumbnail = result.thumbnail {
            // ponytail: `AsyncImage` already loads, caches and cancels. A
            // thumbnail loader here would be all three written again, worse.
            AsyncImage(url: thumbnail) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: result.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(width: 30, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .frame(width: 30, height: 30)
        } else if let image = result.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 24, height: 24)
                .frame(width: 30, height: 30)
        } else {
            Image(systemName: result.symbol)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Theme.primary : Theme.secondary)
                .frame(width: 30, height: 30)
        }
    }
}

/// The ⌘K list. Everything the selected result can do, with the primary first.
private struct ActionMenu: View {
    var actions: [CommandBar.Action]
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Actions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 9) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(index == selection ? Theme.primary : Theme.secondary)
                        .frame(width: 16)
                    Text(action.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(index == selection ? Theme.core.opacity(0.22) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onTapGesture { CommandBar.shared.run(action) }
                .onHover { if $0 { selection = index } }
            }
        }
        .padding(4)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.shell.opacity(Motion.reducedTransparency ? 1 : 0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Theme.edgeHighlight, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        )
    }
}

/// A key on the footer, drawn rather than typed, so ⌘ and ⏎ read as keys.
private struct KeyCap: View {
    var symbol: String
    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Group {
            if symbol.count == 1 {
                Text(symbol.uppercased()).font(.system(size: 9, weight: .semibold))
            } else {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(Theme.secondary)
        .frame(width: 17, height: 15)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.edge, lineWidth: 0.5)
                )
        )
    }
}
