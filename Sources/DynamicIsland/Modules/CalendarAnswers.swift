import AppKit
import EventKit
import SwiftUI

/// Calendar questions typed into the command bar, answered from the Mac's own
/// calendar store - every calendar the Calendar app has, read the same way the
/// island's calendar strip reads them, so there are no feed links to keep up
/// and nothing to wait on.
///
/// Understands a day ("tomorrow", "next tuesday", "2 weeks from now", "the
/// 19th"), a range ("this week", "this weekend", "next 3 days"), a time ("at
/// 4pm"), a part of the day ("tomorrow afternoon"), free time ("am I free
/// friday"), a filter ("any exams this week") and a search ("when is my chem
/// quiz"). A line that names a day it cannot read is asked about, not answered
/// for today.
@MainActor
enum CalendarAnswers {
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let calendar: String
        let color: Color
        /// Identifier Calendar.app opens. Nil on a free slot.
        let externalID: String?
        /// A gap in the day rather than an event.
        var isFree = false
    }

    struct Day: Equatable {
        let date: Date
        let rows: [Row]
    }

    struct Agenda: Equatable {
        let headline: String
        let subtitle: String
        let days: [Day]
        /// One line under the rows: the all-day events behind "free at 4".
        let note: String?
        /// Where the answer came from, so a calendar missing from the Mac is
        /// noticed rather than silently absent.
        let source: String

        /// Plain text, for copying and for the notch.
        var text: String {
            var lines = [subtitle.isEmpty ? headline : "\(headline) - \(subtitle)"]
            for day in days {
                if days.count > 1 { lines.append(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())) }
                lines += day.rows.map { "\(CalendarAnswers.time($0))  \($0.title)" }
            }
            if let note { lines.append(note) }
            return lines.joined(separator: "\n")
        }
    }

    enum Outcome {
        case agenda(Agenda)
        /// The question named a day this could not read.
        case clarify(String)
    }

    private static let store = EKEventStore()
    nonisolated private static var cal: Foundation.Calendar { .current }

    static var available: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    // MARK: - Answering

    /// Nil when the line is not a calendar question, or the calendar cannot be
    /// read.
    static func answer(_ question: String) -> Outcome? {
        guard available else { return nil }
        let q = normalize(question)
        let search = group(#"^(?:when(?:'s| is| are) (?:my|our)|what time(?:'s| is) (?:my|our)|when do i have(?: my)?) (?:next )?(.+)$"#, in: q)
        let isCalendar = has(nouns, q) || has(phrases, q) || search != nil
        guard isCalendar else { return nil }

        if let term = search { return .agenda(find(term)) }

        guard let when = when(q) else {
            return .clarify("Which day do you mean? Try “tomorrow”, “Friday” or “Oct 19”.")
        }
        // "what's on netflix" is not a calendar question; "what's on" alone,
        // or with a day, is.
        if !has(nouns, q), !has(#"\b(free|busy|available|what do i have|anything|plans)\b"#, q),
           !when.named, !rest(q).isEmpty {
            return nil
        }

        if let at = when.at { return .agenda(atTime(at, when)) }
        if has(#"\b(free|busy|available|availability)\b"#, q) { return .agenda(free(when)) }
        let filter = rest(q)
        // "do I have any exams" with no day means the next ones, not today's.
        if !filter.isEmpty, !when.named { return .agenda(find(filter)) }
        return .agenda(listing(when, filter: filter))
    }

    /// "what do I have tomorrow": the window's events, all-day first.
    private static func listing(_ when: When, filter: String) -> Agenda {
        let all = rows(from: when.start, to: when.end)
        let shown = filter.isEmpty ? all : all.filter { matches($0, filter) }
        let headline = !filter.isEmpty && shown.isEmpty ? "No “\(filter)”" : when.label
        let subtitle = shown.isEmpty
            ? (filter.isEmpty ? "Nothing scheduled" : "\(when.label) · \(when.subtitle)")
            : "\(when.subtitle) · \(shown.count) \(shown.count == 1 ? "event" : "events")"
        return Agenda(headline: headline, subtitle: subtitle, days: group(shown, from: when.start),
                      note: nil, source: source(shown))
    }

    /// "what's on at 4pm": what covers that moment, and the all-day events.
    private static func atTime(_ at: Date, _ when: When) -> Agenda {
        let day = cal.startOfDay(for: at)
        let all = rows(from: day, to: cal.date(byAdding: .day, value: 1, to: day)!)
        let covering = all.filter { !$0.isAllDay && $0.start <= at && at < $0.end }
        let allDay = Array(NSOrderedSet(array: all.filter(\.isAllDay).map(\.title))) as? [String] ?? []
        let clock = clock(at)
        return Agenda(
            headline: covering.isEmpty ? "Free at \(clock)" : "Busy at \(clock)",
            subtitle: when.label,
            days: covering.isEmpty ? [] : [Day(date: day, rows: covering)],
            note: allDay.isEmpty ? nil : "All day: " + allDay.joined(separator: ", "),
            source: source(all))
    }

    /// "am I free tomorrow afternoon": the events with the gaps between them.
    /// Gaps under 15 minutes are not free time anyone would plan into.
    private static func free(_ when: When) -> Agenda {
        var days: [Day] = []
        var total: TimeInterval = 0
        var day = when.start
        while day < when.end {
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            // A day is planned from 8 to 10, unless the question narrowed it.
            let from = max(when.partStart(on: day) ?? cal.date(bySettingHour: 8, minute: 0, second: 0, of: day)!, day)
            let to = min(when.partEnd(on: day) ?? cal.date(bySettingHour: 22, minute: 0, second: 0, of: day)!, next)
            let busy = rows(from: from, to: to).filter { !$0.isAllDay }
            var cursor = max(from, cal.isDateInToday(day) ? .now : from)
            var timeline: [Row] = []
            for event in busy.sorted(by: { $0.start < $1.start }) {
                if event.start.timeIntervalSince(cursor) >= 15 * 60 {
                    timeline.append(gap(cursor, event.start))
                    total += event.start.timeIntervalSince(cursor)
                }
                timeline.append(event)
                cursor = max(cursor, event.end)
            }
            if to.timeIntervalSince(cursor) >= 15 * 60 {
                timeline.append(gap(cursor, to))
                total += to.timeIntervalSince(cursor)
            }
            if !timeline.isEmpty { days.append(Day(date: day, rows: timeline)) }
            day = next
        }
        let hours = (total / 3600).rounded(.down)
        let minutes = Int(total.truncatingRemainder(dividingBy: 3600) / 60)
        let amount = hours > 0 ? "\(Int(hours)) h" + (minutes > 0 ? " \(minutes) min" : "") : "\(minutes) min"
        return Agenda(
            headline: total == 0 ? "No free time" : "\(amount) free",
            subtitle: when.label, days: days, note: nil,
            source: source(days.flatMap(\.rows).filter { !$0.isFree }))
    }

    /// "when is my chem quiz": the next few events that match, from now.
    private static func find(_ term: String) -> Agenda {
        let term = term.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
        let now = Date()
        let found = rows(from: cal.startOfDay(for: now), to: cal.date(byAdding: .month, value: 4, to: now)!)
            .filter { $0.end > now && matches($0, term) }
            .prefix(3)
        guard let first = found.first else {
            return Agenda(headline: "Nothing called “\(term)”", subtitle: "In the next four months",
                          days: [], note: nil, source: source([]))
        }
        let away = first.start.formatted(.relative(presentation: .named))
        return Agenda(
            headline: first.title,
            subtitle: "\(first.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) · \(time(first)) · \(away)",
            days: group(Array(found), from: cal.startOfDay(for: now)), note: nil, source: source(Array(found)))
    }

    // MARK: - Adding

    struct Draft: Equatable {
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let calendar: String

        var summary: String {
            let date = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            let span = isAllDay ? "All day" : CalendarAnswers.time(Row(
                id: "", title: "", start: start, end: end, isAllDay: false, calendar: "", color: .clear, externalID: nil))
            return "\(date), \(span) · \(calendar)"
        }
    }

    /// `add gym tomorrow 5pm`, `add Dentist friday at 2:30pm for 45 minutes`.
    /// Nil unless the line starts with "add" and names a day or a time.
    static func draft(_ text: String) -> Draft? {
        let q = normalize(text)
        guard q.hasPrefix("add "), q.count > 4, available,
              let calendar = store.defaultCalendarForNewEvents
        else { return nil }
        var body = String(q.dropFirst(4))
            .replacingOccurrences(of: #"\b(to|in|on) (my )?calendar\b"#, with: " ", options: .regularExpression)

        var duration: TimeInterval = 3600
        if let match = body.range(of: #"\bfor \d+(\.\d+)? ?(minutes?|mins?|m|hours?|hrs?|h)\b"#, options: .regularExpression) {
            let words = body[match].dropFirst(4)
            if let number = Double(words.prefix(while: { $0.isNumber || $0 == "." })) {
                duration = words.contains("h") ? number * 3600 : number * 60
            }
            body.replaceSubrange(match, with: " ")
        }

        var day: Date?
        var spans: [Range<String.Index>] = []
        if let (date, range) = relativeOffset(body) { day = date; spans.append(range) }
        else if let (date, range) = ordinal(body) { day = date; spans.append(range) }
        else if let match = detected(body) { day = cal.startOfDay(for: match.date); spans.append(match.range) }
        let clockMatch = clock(body)
        if let clockMatch { spans.append(clockMatch.range) }
        guard let first = spans.map(\.lowerBound).min(), let last = spans.map(\.upperBound).max() else { return nil }

        // What comes before the date is the title ("call mom tomorrow"), or
        // what comes after it when the date leads ("tomorrow 5pm gym").
        let connectors = #"^((on|at|from|for|this|next|by) )+|( (on|at|from|for|this|next|by))+$"#
        func clean(_ part: Substring) -> String {
            String(part).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: connectors, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var title = clean(body[..<first])
        if title.isEmpty { title = clean(body[last...]) }
        guard !title.isEmpty else { return nil }
        // In the case it was typed: "Dr Lee", not "dr lee".
        if let typed = text.range(of: title, options: .caseInsensitive) { title = String(text[typed]) }

        let base = day ?? cal.startOfDay(for: .now)
        let start = clockMatch.flatMap { cal.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: base) } ?? base
        let allDay = clockMatch == nil
        return Draft(
            title: title.prefix(1).uppercased() + title.dropFirst(),
            start: start,
            end: allDay ? cal.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(duration),
            isAllDay: allDay,
            calendar: calendar.title)
    }

    static func save(_ draft: Draft) -> Bool {
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.calendar = store.defaultCalendarForNewEvents
        return (try? store.save(event, span: .thisEvent, commit: true)) != nil
    }

    /// Opens the event in Calendar, the way the calendar strip does.
    static func open(_ row: Row) { CalendarPeek.open(externalID: row.externalID) }

    // MARK: - Reading the question

    private static let nouns = #"\b(calendar|schedule|agenda|events?|plans|class(es)?|lessons?|lectures?|meetings?|appointments?|exams?|tests?|quiz(zes)?|assignments?|homework|deadlines?)\b"#
    private static let phrases = #"\b(what do i have|what have i got|what's on|whats on|what is on|am i (free|busy|available)|do i have (anything|any)|anything on|is there anything)\b"#

    struct When {
        var start: Date
        var end: Date
        var label: String
        var subtitle: String
        var at: Date?
        /// The question named a day or a range, rather than defaulting to today.
        var named: Bool
        var part: (Int, Int)?

        func partStart(on day: Date) -> Date? {
            part.flatMap { Foundation.Calendar.current.date(bySettingHour: $0.0, minute: 0, second: 0, of: day) }
        }
        func partEnd(on day: Date) -> Date? {
            part.flatMap { $0.1 >= 24 ? Foundation.Calendar.current.date(byAdding: .day, value: 1, to: day)
                : Foundation.Calendar.current.date(bySettingHour: $0.1, minute: 0, second: 0, of: day) }
        }
    }

    /// The window a question is about. Nil when it names a day this cannot
    /// read - better to ask than to answer for today.
    static func when(_ q: String) -> When? {
        let today = cal.startOfDay(for: .now)
        var day: Date?

        // Ranges first: "this week" has no single day.
        if let range = range(q, today: today) { return range }
        if let (date, _) = relativeOffset(q) { day = date }
        else if let (date, _) = ordinal(q) { day = date }
        else if let match = detected(q) { day = cal.startOfDay(for: match.date) }

        let clockMatch = clock(q)
        if day == nil, dateish(q, clock: clockMatch?.range) { return nil }
        let target = day ?? today

        let parts: [(String, (Int, Int), String)] = [
            ("morning", (6, 12), "morning"), ("afternoon", (12, 17), "afternoon"),
            ("evening", (17, 22), "evening"), ("tonight", (18, 24), "night"), ("night", (18, 24), "night"),
        ]
        let part = parts.first { has("\\b\($0.0)\\b", q) }
        var when = window(for: target, today: today, named: day != nil || part != nil)
        if let part {
            when.part = part.1
            when.label = target == today && part.0 == "tonight" ? "Tonight" : "\(when.label) \(part.2)"
            when.start = when.partStart(on: target)!
            when.end = when.partEnd(on: target)!
        }
        if let clockMatch {
            when.at = cal.date(bySettingHour: clockMatch.hour, minute: clockMatch.minute, second: 0, of: target)
        }
        return when
    }

    private static func window(for day: Date, today: Date, named: Bool) -> When {
        let days = cal.dateComponents([.day], from: today, to: day).day ?? 0
        let full = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let label = switch days {
        case 0: "Today"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        default: full
        }
        let subtitle = abs(days) <= 1 ? full : (days > 0 ? "In \(days) days" : "\(-days) days ago")
        return When(start: day, end: cal.date(byAdding: .day, value: 1, to: day)!,
                    label: label, subtitle: subtitle, named: named)
    }

    private static func range(_ q: String, today: Date) -> When? {
        func span(_ start: Date, _ end: Date, _ label: String) -> When {
            let last = cal.date(byAdding: .day, value: -1, to: end)!
            let subtitle = "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
            return When(start: start, end: end, label: label, subtitle: subtitle, named: true)
        }
        // A school or work week runs Monday to Sunday, whatever the locale's
        // first weekday - Singapore's is Sunday, which cut "this week" short.
        var weeks = cal
        weeks.firstWeekday = 2
        if has(#"\bnext week\b"#, q), let week = weeks.dateInterval(of: .weekOfYear, for: today),
           let next = weeks.dateInterval(of: .weekOfYear, for: week.end) {
            return span(next.start, next.end, "Next week")
        }
        if has(#"\b(this|the) week\b|\brest of the week\b"#, q), let week = weeks.dateInterval(of: .weekOfYear, for: today) {
            return span(today, week.end, "This week")
        }
        if has(#"\bweekend\b"#, q) {
            // The coming Saturday, or this one when it is already the weekend.
            var saturday = cal.nextDate(after: today, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime)!
            if cal.component(.weekday, from: today) == 7 { saturday = today }
            if cal.component(.weekday, from: today) == 1 { saturday = cal.date(byAdding: .day, value: -1, to: today)! }
            if has(#"\bnext weekend\b"#, q) { saturday = cal.date(byAdding: .day, value: 7, to: saturday)! }
            let start = max(saturday, today)
            return span(start, cal.date(byAdding: .day, value: 2, to: saturday)!,
                        has(#"\bnext weekend\b"#, q) ? "Next weekend" : "This weekend")
        }
        if let n = group(#"\bnext (\d{1,2}|two|three|four|five|six|seven|few) days\b"#, in: q) {
            let count = Int(n) ?? numbers[n] ?? 3
            return span(today, cal.date(byAdding: .day, value: count, to: today)!, "Next \(count) days")
        }
        if has(#"\b(this|the rest of the) month\b"#, q), let month = cal.dateInterval(of: .month, for: today) {
            return span(today, month.end, "This month")
        }
        return nil
    }

    private static let numbers = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                                  "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "few": 3]

    /// "2 weeks from now", "in three days", "a month from today" - one day.
    private static func relativeOffset(_ q: String) -> (Date, Range<String.Index>)? {
        let n = #"(\d{1,3}|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"#
        let pattern = "\\b(?:in \(n) (day|week|month)s?|\(n) (day|week|month)s? from (?:now|today))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let range = Range(match.range, in: q)
        else { return nil }
        func text(_ i: Int) -> String? { Range(match.range(at: i), in: q).map { String(q[$0]) } }
        guard let count = (text(1) ?? text(3)).flatMap({ Int($0) ?? numbers[$0] }),
              let unit = text(2) ?? text(4)
        else { return nil }
        let component: Foundation.Calendar.Component = unit == "month" ? .month : .day
        let amount = unit == "week" ? count * 7 : count
        guard let date = cal.date(byAdding: component, value: amount, to: cal.startOfDay(for: .now)) else { return nil }
        return (date, range)
    }

    /// "the 19th": this month's, or next month's once this one's has passed.
    private static func ordinal(_ q: String) -> (Date, Range<String.Index>)? {
        guard let range = q.range(of: #"\b(?:the )?\d{1,2}(?:st|nd|rd|th)\b"#, options: .regularExpression),
              let number = Int(q[range].filter(\.isNumber))
        else { return nil }
        let today = cal.startOfDay(for: .now)
        var parts = cal.dateComponents([.year, .month], from: today)
        parts.day = number
        guard var date = cal.date(from: parts), cal.component(.day, from: date) == number else { return nil }
        if date < today { date = cal.date(byAdding: .month, value: 1, to: date)! }
        return (date, range)
    }

    /// The first day the system's own date reader finds - "next tuesday",
    /// "10/19", "tomorrow" - skipping a match that is only a time of day.
    private static func detected(_ q: String) -> (date: Date, range: Range<String.Index>)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        for match in detector.matches(in: q, range: NSRange(q.startIndex..., in: q)) {
            guard let date = match.date, let range = Range(match.range, in: q) else { continue }
            let text = q[range].replacingOccurrences(of: clockPattern, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\s*at\b|\bat\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if text.isEmpty || ["tonight", "morning", "afternoon", "evening", "night"].contains(text) {
                continue
            }
            return (date, range)
        }
        return nil
    }

    private static let clockPattern = #"\b(?:at )?(?:\d{1,2}(?::\d{2})? ?(?:am|pm)|\d{1,2}:\d{2}|noon|midnight)\b"#

    /// "4pm", "4:30 pm", "16:00", "noon" - and a bare "at 4", read as the
    /// hour a person means: 1 to 7 is afternoon, 8 to 11 morning.
    private static func clock(_ q: String) -> (hour: Int, minute: Int, range: Range<String.Index>)? {
        if let range = q.range(of: clockPattern, options: .regularExpression) {
            let text = q[range].replacingOccurrences(of: "at ", with: "")
            if text == "noon" { return (12, 0, range) }
            if text == "midnight" { return (0, 0, range) }
            let digits = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard var hour = digits.first, hour <= 23 else { return nil }
            let minute = digits.count > 1 ? digits[1] : 0
            if text.hasSuffix("pm"), hour < 12 { hour += 12 }
            if text.hasSuffix("am"), hour == 12 { hour = 0 }
            return (hour, min(minute, 59), range)
        }
        if let range = q.range(of: #"\bat \d{1,2}\b"#, options: .regularExpression),
           let hour = Int(q[range].filter(\.isNumber)), (1 ... 12).contains(hour) {
            return (hour <= 7 ? hour + 12 : hour, 0, range)
        }
        return nil
    }

    /// Words that name a day this did not manage to read.
    private static func dateish(_ q: String, clock: Range<String.Index>?) -> Bool {
        var text = q
        if let clock { text.removeSubrange(clock) }
        return has(#"\d|\b(january|february|march|april|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec|monday|tuesday|wednesday|thursday|friday|saturday|sunday|week|weekend|month|fortnight|year)\b|\bday after\b"#, text)
    }

    /// What is left of the question once the asking and the dates are taken
    /// out: "any exams this week" leaves "exams", which filters the rows.
    private static func rest(_ q: String) -> String {
        let stop: Set<String> = [
            "what", "whats", "what's", "is", "are", "do", "does", "did", "i", "have", "has", "got", "on", "my", "the",
            "a", "an", "any", "anything", "there", "in", "at", "for", "of", "me", "show", "tell", "list", "all", "events",
            "event", "things", "thing", "plans", "plan", "schedule", "calendar", "agenda", "day", "today", "tomorrow",
            "tonight", "this", "next", "week", "weekend", "month", "morning", "afternoon", "evening", "night", "free",
            "busy", "available", "availability", "am", "from", "now", "days", "weeks", "months", "and", "or", "to",
            "coming", "upcoming", "left", "else", "going", "happening", "planned", "scheduled", "meeting", "meetings",
            "appointment", "appointments", "how", "many", "much", "be", "will", "should", "can", "could", "would",
            "after", "before", "until", "rest", "few", "yesterday", "up", "get", "see", "check", "about", "like",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "january",
            "february", "march", "april", "june", "july", "august", "september", "october", "november", "december",
        ]
        let words = q.replacingOccurrences(of: clockPattern, with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty && !stop.contains($0) && !$0.allSatisfy(\.isNumber)
                && $0.range(of: #"^\d+(st|nd|rd|th)$"#, options: .regularExpression) == nil
                && numbers[$0] == nil }
        return words.joined(separator: " ")
    }

    /// A row matches when its title or its calendar holds every word, singular
    /// or plural: "exams" finds "Quarter 1 Exam", "classes" the Daily Classes
    /// calendar.
    /// Asking for exams means any of them, whatever the teacher called it.
    private static let assessments = ["exam", "test", "quiz", "assessment", "summative", "midterm", "final"]

    private static func matches(_ row: Row, _ filter: String) -> Bool {
        let haystack = "\(row.title) \(row.calendar)".lowercased()
        return filter.split(separator: " ").allSatisfy { word in
            let word = String(word)
            if assessments.contains(where: { word.hasPrefix($0) }) {
                return assessments.contains { haystack.contains($0) }
            }
            var forms = [word]
            if word.hasSuffix("zes") { forms.append(String(word.dropLast(3))) }
            if word.hasSuffix("es") { forms.append(String(word.dropLast(2))) }
            if word.hasSuffix("s") { forms.append(String(word.dropLast())) }
            return forms.contains { $0.count >= 3 && haystack.contains($0) }
        }
    }

    // MARK: - Reading the calendar

    private static func rows(from: Date, to: Date) -> [Row] {
        guard to > from else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        var seen = Set<String>()
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .compactMap { event -> Row? in
                let title = event.title ?? "Untitled"
                // The same event in two calendars - a shared one and a copy.
                guard seen.insert("\(title)|\(event.startDate.timeIntervalSince1970)|\(event.endDate.timeIntervalSince1970)").inserted
                else { return nil }
                return Row(
                    id: "\(event.eventIdentifier ?? UUID().uuidString)@\(event.startDate.timeIntervalSince1970)",
                    title: title, start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                    calendar: event.calendar.title, color: Color(nsColor: event.calendar.color),
                    externalID: event.calendarItemExternalIdentifier)
            }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    private static func group(_ rows: [Row], from start: Date) -> [Day] {
        guard !rows.isEmpty else { return [] }
        let byDay = Dictionary(grouping: rows) { max(cal.startOfDay(for: $0.start), start) }
        return byDay.keys.sorted().map { Day(date: $0, rows: byDay[$0]!) }
    }

    private static func gap(_ from: Date, _ to: Date) -> Row {
        Row(id: "free@\(from.timeIntervalSince1970)", title: "Free", start: from, end: to, isAllDay: false,
            calendar: "", color: .green, externalID: nil, isFree: true)
    }

    private static func source(_ rows: [Row]) -> String {
        let names = Array(NSOrderedSet(array: rows.filter { !$0.isFree }.map(\.calendar))) as? [String] ?? []
        if names.isEmpty {
            return "Searched \(store.calendars(for: .event).count) calendars on this Mac"
        }
        return "From " + names.joined(separator: ", ")
    }

    /// "4 PM", "4:30 PM" - the rows' style, not "4:00 PM".
    nonisolated static func clock(_ date: Date) -> String {
        let hour = cal.component(.hour, from: date), minute = cal.component(.minute, from: date)
        return "\(hour % 12 == 0 ? 12 : hour % 12)" + (minute > 0 ? String(format: ":%02d", minute) : "")
            + (hour < 12 ? " AM" : " PM")
    }

    /// "3–4 PM", "11 AM–12:30 PM", "All day".
    nonisolated static func time(_ row: Row) -> String {
        if row.isAllDay { return "All day" }
        func part(_ date: Date) -> (String, String) {
            let hour = cal.component(.hour, from: date), minute = cal.component(.minute, from: date)
            return ("\(hour % 12 == 0 ? 12 : hour % 12)" + (minute > 0 ? String(format: ":%02d", minute) : ""),
                    hour < 12 ? "AM" : "PM")
        }
        let (s, sp) = part(row.start), (e, ep) = part(row.end)
        if row.end <= row.start { return "\(s) \(sp)" }
        return sp == ep ? "\(s)–\(e) \(ep)" : "\(s) \(sp)–\(e) \(ep)"
    }

    // MARK: - Helpers

    private static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?!."))
    }

    private static func has(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func group(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
