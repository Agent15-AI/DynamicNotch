import Foundation

/// Lines that have an answer: a time somewhere else, a length in another unit,
/// a file size in gigabytes.
///
/// ponytail: Foundation does all of it. `NSDataDetector` reads "12pm" and
/// "next tuesday", `TimeZone.knownTimeZoneIdentifiers` is a city-to-zone map
/// nobody has to ship, and `Measurement` converts every unit with the names
/// already localised. The work here is only deciding which of the two kinds a
/// line is, and saying what was read back clearly enough to catch a misread.
///
/// Currency is deliberately not here. It is the one conversion whose answer
/// changes by the minute and cannot be computed offline, so it needs a rate
/// fetch and a cache, not a lookup table.
@MainActor
enum Interpret {
    /// One answer, shown as a card rather than a row: what you typed on the
    /// left, the answer on the right, a caption under each.
    ///
    /// The captions are the point. "12:00 PM" under the input is how you catch
    /// it reading `12pm` as noon when you meant midnight, and "London · GMT"
    /// under the answer is how you catch it picking the wrong London. A card
    /// with only the answer on it is a card you have to trust blindly.
    struct Card: Equatable {
        var from: String
        var fromCaption: String
        var to: String
        var toCaption: String
        /// What ⏎ puts on the clipboard - the answer alone, never the caption.
        var copy: String
        var symbol: String
        var section: String
    }

    static func card(for text: String) -> Card? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return nil }
        return time(trimmed) ?? measure(trimmed)
    }

    // MARK: - Splitting

    /// Everything here reads `<something> in <something>`, so the whole grammar
    /// is finding that one word.
    ///
    /// The *last* separator wins, and it has to. "10 in to cm" is ten inches in
    /// centimetres: splitting on the first " in " leaves "to cm" on the right
    /// and nothing that parses. Splitting on the last leaves "10 in" and "cm".
    private static func split(_ text: String) -> (left: String, right: String)? {
        let separators = [" in ", " to ", " as ", " into ", " → ", " -> "]
        var best: (Range<String.Index>, Int)?
        for separator in separators {
            guard let range = text.range(of: separator, options: [.backwards, .caseInsensitive]) else { continue }
            let position = text.distance(from: text.startIndex, to: range.lowerBound)
            if best == nil || position > best!.1 { best = (range, position) }
        }
        guard let (range, _) = best else { return nil }
        let left = String(text[text.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let right = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }

    // MARK: - Time

    /// `12pm in london`, `12pm here in london`, `9am london in tokyo`,
    /// `now in tokyo`, `next tuesday 3pm in berlin`.
    private static func time(_ text: String) -> Card? {
        guard let (left, right) = split(text), let target = zone(named: right) else { return nil }

        // "here" is the Mac's own zone, and saying it out loud is how you write
        // the query in the order you think it: the time, where it is, where you
        // want it. Dropping it changes nothing, which is the point.
        var phrase = left
        for filler in ["here", "my time", "local"] where phrase.lowercased().hasSuffix(filler) {
            phrase = String(phrase.dropLast(filler.count)).trimmingCharacters(in: .whitespaces)
        }

        // A city on the left names the zone the time is *in*. Longest match
        // first, so "new york" is not read as "york".
        var source = TimeZone.current
        for count in stride(from: 3, through: 1, by: -1) {
            let words = phrase.split(separator: " ")
            guard words.count > count else { continue }
            let tail = words.suffix(count).joined(separator: " ")
            if let named = zone(named: tail) {
                source = named
                phrase = words.dropLast(count).joined(separator: " ")
                break
            }
        }

        let moment = instant(phrase, in: source)
        guard let moment else { return nil }

        // The date on each side, compared as dates. Comparing each side's
        // midnight compared two instants, and midnights in different zones are
        // always under a day apart - so the marker below never appeared.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = source
        let sourceDay = calendar.dateComponents([.year, .month, .day], from: moment.date)
        calendar.timeZone = target
        let targetDay = calendar.dateComponents([.year, .month, .day], from: moment.date)

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = moment.dated ? "E d MMM, h:mm a" : "h:mm a"

        formatter.timeZone = source
        let fromTime = formatter.string(from: moment.date)
        formatter.timeZone = target
        var toTime = formatter.string(from: moment.date)

        // Crossing the date line is the whole reason people ask, so it cannot
        // be left to be inferred from a time that merely looks early.
        let days = calendar.dateComponents([.day], from: sourceDay, to: targetDay).day ?? 0
        if days != 0, !moment.dated {
            toTime += days > 0 ? "  (+\(days)d)" : "  (\(days)d)"
        }

        return Card(
            from: text,
            fromCaption: "\(fromTime) · \(label(for: source))",
            to: toTime,
            toCaption: label(for: target),
            copy: toTime,
            symbol: "clock",
            section: "Time"
        )
    }

    /// The moment being asked about, read in the zone it was written for.
    ///
    /// `NSDataDetector` hands back a `Date` built in the Mac's own zone, which
    /// is the wrong instant whenever the question named somewhere else - "9am
    /// london" is 9am in London, not 9am here. The wall-clock components are
    /// what the typist meant, so they are pulled out locally and rebuilt in the
    /// source zone.
    private static func instant(_ phrase: String, in zone: TimeZone) -> (date: Date, dated: Bool)? {
        let cleaned = phrase.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned.lowercased() == "now" || cleaned.lowercased() == "time" {
            return (Date(), false)
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let detected = match.date
        else { return nil }

        // The detector will happily read a bare number as a date. "5" is not a
        // time query, and treating it as one puts a clock card above the sum.
        guard cleaned.rangeOfCharacter(from: CharacterSet.letters) != nil || cleaned.contains(":") else {
            return nil
        }

        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let parts = local.dateComponents([.year, .month, .day, .hour, .minute], from: detected)

        var there = Calendar(identifier: .gregorian)
        there.timeZone = zone
        guard let rebuilt = there.date(from: parts) else { return nil }

        // A phrase naming a day ("next tuesday") deserves the date on screen;
        // a bare time does not, and showing today's date beside it is noise.
        let dated = detected.timeIntervalSince(Date()) > 20 * 3600
            || detected.timeIntervalSince(Date()) < -20 * 3600
        return (rebuilt, dated)
    }

    /// A city name to its zone.
    ///
    /// ponytail: `knownTimeZoneIdentifiers` already is the map - `Europe/London`
    /// carries its own city in the last path component. Shipping a city
    /// database beside the one macOS updates with the tzdata would be a second
    /// source of truth that can only ever be more wrong.
    ///
    /// The aliases are the cities that identifier does not name, either because
    /// the zone is named for a different city in the same offset (Mumbai lives
    /// under `Asia/Kolkata`) or because the name changed after the zone was.
    static func zone(named city: String) -> TimeZone? {
        let want = city.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        guard !want.isEmpty, want.count >= 2 else { return nil }

        if let alias = aliases[want] { return TimeZone(identifier: alias) }
        if let exact = TimeZone(abbreviation: city.uppercased()) { return exact }
        if let identifier = TimeZone.knownTimeZoneIdentifiers.first(where: {
            $0.split(separator: "/").last?.lowercased() == want
        }) { return TimeZone(identifier: identifier) }
        return nil
    }

    private static let aliases: [String: String] = [
        "mumbai": "Asia/Kolkata", "bombay": "Asia/Kolkata", "delhi": "Asia/Kolkata",
        "new_delhi": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "bangalore": "Asia/Kolkata",
        "hyderabad": "Asia/Kolkata", "chennai": "Asia/Kolkata", "pune": "Asia/Kolkata",
        "india": "Asia/Kolkata", "uk": "Europe/London", "england": "Europe/London",
        "britain": "Europe/London", "sf": "America/Los_Angeles",
        "san_francisco": "America/Los_Angeles", "la": "America/Los_Angeles",
        "los_angeles": "America/Los_Angeles", "seattle": "America/Los_Angeles",
        "nyc": "America/New_York", "ny": "America/New_York", "boston": "America/New_York",
        "washington": "America/New_York", "dc": "America/New_York", "miami": "America/New_York",
        "austin": "America/Chicago", "texas": "America/Chicago", "dallas": "America/Chicago",
        "japan": "Asia/Tokyo", "china": "Asia/Shanghai", "beijing": "Asia/Shanghai",
        "korea": "Asia/Seoul", "france": "Europe/Paris", "germany": "Europe/Berlin",
        "spain": "Europe/Madrid", "italy": "Europe/Rome", "netherlands": "Europe/Amsterdam",
        "australia": "Australia/Sydney", "brazil": "America/Sao_Paulo",
        "sao_paulo": "America/Sao_Paulo", "utc": "UTC", "gmt": "GMT",
    ]

    /// "London · GMT" - the city as a person says it, and the abbreviation that
    /// makes the offset checkable.
    private static func label(for zone: TimeZone) -> String {
        let city = (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier)
            .replacingOccurrences(of: "_", with: " ")
        let abbreviation = zone.abbreviation() ?? ""
        return abbreviation.isEmpty || abbreviation == city ? city : "\(city) · \(abbreviation)"
    }

    // MARK: - Units

    /// `5km in miles`, `2*3 kg in lb`, `180c in f`, `4.5 gb in mb`.
    private static func measure(_ text: String) -> Card? {
        guard let (left, right) = split(text) else { return nil }
        guard let target = unit(named: right) else { return nil }

        // The number runs until the first character that cannot be part of an
        // expression. "100 km/h" stops at the k; "5km" stops at the k too.
        let expressionCharacters = CharacterSet(charactersIn: "0123456789.,+-*/^() ")
        let boundary = left.firstIndex { !CharacterSet(charactersIn: String($0)).isSubset(of: expressionCharacters) }
        guard let boundary else { return nil }
        let expression = String(left[left.startIndex..<boundary]).trimmingCharacters(in: .whitespaces)
        let symbol = String(left[boundary...]).trimmingCharacters(in: .whitespaces)
        guard !expression.isEmpty, let source = unit(named: symbol) else { return nil }

        // Converting a mass to a length is not a typo to be guessed at, and
        // `converted(to:)` will not refuse it - it runs the arithmetic through
        // whatever base units it is handed and returns a confident wrong
        // number. This is the only thing standing between that and the card.
        //
        // Comparing the two base units rather than the two classes, because a
        // unit built here is not the same dynamic type as one of Foundation's
        // own constants: `3 days in hours` failed that test while converting
        // perfectly well.
        guard type(of: source).baseUnit().symbol == type(of: target).baseUnit().symbol else {
            return nil
        }

        // ponytail: the number can be a sum, because `Calculator` already
        // parses sums. "2*3 kg in lb" costs nothing extra to support.
        guard let value = Calculator.evaluate(
            expression, degrees: Settings.shared.calculatorDegrees, answer: nil)
        else { return nil }

        let original = Measurement(value: value, unit: source)
        let converted = original.converted(to: target)

        // Short on the card, spelled out underneath. The short form is what you
        // read; the long one is what tells you `mi` came back as miles and not
        // as something else that abbreviates the same way.
        let short = MeasurementFormatter()
        short.unitOptions = .providedUnit
        short.unitStyle = .medium
        short.numberFormatter.maximumFractionDigits = 4
        let long = MeasurementFormatter()
        long.unitOptions = .providedUnit
        long.unitStyle = .long
        long.numberFormatter.maximumFractionDigits = 4

        return Card(
            from: text,
            fromCaption: long.string(from: original),
            to: short.string(from: converted),
            toCaption: long.string(from: converted),
            // The number alone: pasting "3.1069 mi" into a spreadsheet is not
            // pasting a number.
            copy: Calculator.format(converted.value),
            symbol: "ruler",
            section: "Convert"
        )
    }

    private static func unit(named text: String) -> Dimension? {
        let key = text.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "°", with: "")
        guard !key.isEmpty else { return nil }
        // Plurals, without a table of them.
        if let exact = units[key] { return exact }
        if key.hasSuffix("s"), let singular = units[String(key.dropLast())] { return singular }
        return nil
    }

    /// Every unit worth typing, by every name it gets typed under.
    ///
    /// ponytail: this is a table, not an abstraction. `Measurement` does the
    /// arithmetic - including the offsets that make °C to °F work - so nothing
    /// here converts anything. Days and weeks are built rather than listed
    /// because `UnitDuration` stops at hours.
    private static let units: [String: Dimension] = {
        let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
        let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))
        var table: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ names: String...) {
            for name in names { table[name] = unit }
        }

        add(UnitLength.millimeters, "mm", "millimetre", "millimeter")
        add(UnitLength.centimeters, "cm", "centimetre", "centimeter")
        add(UnitLength.meters, "m", "metre", "meter")
        add(UnitLength.kilometers, "km", "kilometre", "kilometer")
        add(UnitLength.inches, "in", "inch", "\"")
        add(UnitLength.feet, "ft", "foot", "feet", "'")
        add(UnitLength.yards, "yd", "yard")
        add(UnitLength.miles, "mi", "mile")
        add(UnitLength.nauticalMiles, "nmi", "nautical mile")

        add(UnitMass.milligrams, "mg", "milligram")
        add(UnitMass.grams, "g", "gram")
        add(UnitMass.kilograms, "kg", "kilo", "kilogram")
        add(UnitMass.metricTons, "t", "tonne", "ton")
        add(UnitMass.ounces, "oz", "ounce")
        add(UnitMass.pounds, "lb", "lbs", "pound")
        add(UnitMass.stones, "st", "stone")

        add(UnitTemperature.celsius, "c", "celsius", "centigrade")
        add(UnitTemperature.fahrenheit, "f", "fahrenheit")
        add(UnitTemperature.kelvin, "k", "kelvin")

        add(UnitDuration.seconds, "s", "sec", "second")
        add(UnitDuration.minutes, "min", "minute")
        add(UnitDuration.hours, "h", "hr", "hour")
        add(day, "d", "day")
        add(week, "wk", "week")

        add(UnitInformationStorage.bytes, "b", "byte")
        add(UnitInformationStorage.kilobytes, "kb", "kilobyte")
        add(UnitInformationStorage.megabytes, "mb", "megabyte")
        add(UnitInformationStorage.gigabytes, "gb", "gigabyte")
        add(UnitInformationStorage.terabytes, "tb", "terabyte")
        add(UnitInformationStorage.kibibytes, "kib")
        add(UnitInformationStorage.mebibytes, "mib")
        add(UnitInformationStorage.gibibytes, "gib")

        add(UnitSpeed.kilometersPerHour, "kph", "km/h", "kmh")
        add(UnitSpeed.milesPerHour, "mph", "mi/h")
        add(UnitSpeed.metersPerSecond, "m/s", "mps")
        add(UnitSpeed.knots, "kn", "knot")

        add(UnitVolume.milliliters, "ml", "millilitre", "milliliter")
        add(UnitVolume.liters, "l", "litre", "liter")
        add(UnitVolume.gallons, "gal", "gallon")
        add(UnitVolume.cups, "cup")
        add(UnitVolume.fluidOunces, "floz", "fl oz")

        add(UnitArea.squareMeters, "m2", "sqm", "square metre", "square meter")
        add(UnitArea.squareFeet, "ft2", "sqft", "square foot")
        add(UnitArea.hectares, "ha", "hectare")
        add(UnitArea.acres, "ac", "acre")

        add(UnitAngle.degrees, "deg", "degree")
        add(UnitAngle.radians, "rad", "radian")
        return table
    }()
}
