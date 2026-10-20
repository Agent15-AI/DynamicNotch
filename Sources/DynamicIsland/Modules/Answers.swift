import Foundation

/// Questions typed into the command bar, answered from data the island
/// already holds, because a native card beats text about it: the weather
/// (Open-Meteo, as the island's own weather does) and the calendar (the Mac's
/// calendar store, as the calendar strip does).
///
/// Nothing runs at rest: one lookup per question.
@MainActor
@Observable
final class Answers {
    static let shared = Answers()

    enum Reply: Equatable {
        case text(String)
        case agenda(CalendarAnswers.Agenda)
        case weather(Weather.Report)

        /// One line for the notch, and the whole of it for the clipboard.
        var summary: String {
            switch self {
            case .text(let text): text.components(separatedBy: "\n").first ?? text
            case .agenda(let agenda): agenda.subtitle.isEmpty ? agenda.headline : "\(agenda.headline) · \(agenda.subtitle)"
            case .weather(let report):
                "\(report.day.map { "\($0): " } ?? "")\(report.temperature ?? report.forecast.high)°, \(Weather.summary(code: report.code).lowercased()) in \(report.place)"
            }
        }

        var copy: String {
            switch self {
            case .text(let text): text
            case .agenda(let agenda): agenda.text
            case .weather(let report):
                [summary, "High \(report.forecast.high)°, low \(report.forecast.low)°", report.forecast.rain.map { "\($0)% chance of rain" }]
                    .compactMap { $0 }.joined(separator: "\n")
            }
        }
    }

    enum Phase: Equatable {
        case thinking
        case answered(Reply)
        case failed(String)
    }

    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var phase: Phase = .thinking
        var asked = Date()
    }

    /// Oldest first. Kept across openings of the bar for ten minutes, so an
    /// answer that arrived after the bar was closed is there to read.
    private(set) var exchanges: [Exchange] = []
    /// Whether a question was asked since the bar last opened. Only then does
    /// every typed line count as a follow-up.
    private(set) var askedThisOpening = false
    var onChange: (() -> Void)?

    private var barOpen = false

    private init() {}

    func ask(_ text: String) {
        // The readers match "what's on …" with a straight apostrophe; macOS smart
        // quotes would type a curly one and miss every one of those phrasings.
        let text = text.replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let exchange = Exchange(question: text)
        exchanges.append(exchange)
        if exchanges.count > 20 { exchanges.removeFirst(exchanges.count - 20) }
        askedThisOpening = true
        onChange?()
        // Not cancelled when the bar closes: the answer is still wanted, and is
        // shown under the notch instead. See `finish`.
        Task { await answer(exchange.id, text) }
    }

    func retry(_ id: Exchange.ID) {
        guard let question = exchanges.first(where: { $0.id == id })?.question else { return }
        exchanges.removeAll { $0.id == id }
        ask(question)
    }

    func opened() {
        barOpen = true
        askedThisOpening = false
        if let last = exchanges.last, Date().timeIntervalSince(last.asked) > 10 * 60 { exchanges = [] }
    }

    func closed() {
        barOpen = false
    }

    // MARK: - Answering

    private func answer(_ id: Exchange.ID, _ text: String) async {
        let calendar = CalendarAnswers.answer(text)
        if calendar == nil, Weather.isQuestion(text) {
            // The day comes from the same reader the calendar uses, so
            // "will it rain on friday" is Friday's forecast, not today's.
            guard let when = CalendarAnswers.when(text.lowercased()) else {
                return finish(id, .answered(.text("Which day do you mean? Try “tomorrow” or “Friday”.")))
            }
            let offset = Foundation.Calendar.current.dateComponents(
                [.day], from: Foundation.Calendar.current.startOfDay(for: .now), to: when.start).day ?? 0
            guard (0 ... 6).contains(offset) else {
                return finish(id, .answered(.text("The forecast only reaches a week ahead.")))
            }
            let label = offset == 1 ? "Tomorrow" : when.start.formatted(.dateTime.weekday(.wide))
            let report = await Weather.report(for: text, offset: offset, label: label, city: Weather.shared.city)
            return finish(id, report.map { .answered(.weather($0)) } ?? .failed("The weather service didn't answer. Try again in a moment."))
        }
        switch calendar {
        case .agenda(let agenda): finish(id, .answered(.agenda(agenda)))
        case .clarify(let question): finish(id, .answered(.text(question)))
        case nil where !CalendarAnswers.available:
            finish(id, .answered(.text("Calendar answers need calendar access: Settings → Modules → Permissions → Calendar.")))
        case nil: finish(id, .answered(.text("Ask about your calendar or the weather, like “what's on tomorrow” or “will it rain friday”.")))
        }
    }

    /// Whether `ask` has a real answer for the line: a calendar question the
    /// calendar can read, or a weather question.
    static func canAnswer(_ text: String) -> Bool {
        Weather.isQuestion(text) || CalendarAnswers.answer(text) != nil
    }

    private func update(_ id: Exchange.ID, _ phase: Phase) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        exchanges[index].phase = phase
        onChange?()
    }

    /// Records the answer, and when nobody is looking at the bar any more,
    /// says it under the notch - closing the bar no longer loses it.
    private func finish(_ id: Exchange.ID, _ phase: Phase) {
        update(id, phase)
        guard !barOpen, exchanges.contains(where: { $0.id == id }) else { return }
        switch phase {
        case .answered(let reply):
            HUD.shared.show(.utility(symbol: "text.bubble", title: "Answer", detail: reply.summary), for: 6)
        case .failed(let reason):
            HUD.shared.show(.utility(symbol: "exclamationmark.triangle", title: "Answer", detail: reason), for: 4)
        default:
            break
        }
    }
}
