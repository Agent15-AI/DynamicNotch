import AppKit

/// The temperature and sky, beside the calendar.
///
/// This was on the "not built" list as network polling, and polling is still
/// what it does not do. It is fetched when the island opens, at most once every
/// 30 minutes - an island nobody opens sends nothing - from Open-Meteo, which
/// needs no key and no account.
///
/// The place is a city name, not a location fix: no Location Services prompt,
/// and nothing more exact than a city leaves the Mac. It defaults to the city in
/// the Mac's time zone (`Asia/Singapore` → Singapore) and can be changed in
/// Settings ▸ Modules.
@MainActor
@Observable
final class Weather {
    static let shared = Weather()

    private(set) var temperature: Int?
    private(set) var high: Int?
    private(set) var low: Int?
    private(set) var code: Int?
    private(set) var isDay = true
    private(set) var place: String?

    private var fetched: Date?
    private var fetching = false

    private init() {}

    /// The city in the Mac's time zone, which is right for most people and
    /// needs no permission to know.
    nonisolated static var defaultCity: String {
        let id = TimeZone.current.identifier
        return (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }

    var city: String {
        let set = Settings.shared.weatherCity.trimmingCharacters(in: .whitespaces)
        return set.isEmpty ? Self.defaultCity : set
    }

    /// Called when the island opens. Fetches only when the last reading is old.
    func refreshIfStale() {
        guard Settings.shared.weather, !fetching else { return }
        if let fetched, Date().timeIntervalSince(fetched) < 30 * 60, place == city { return }
        fetching = true
        let city = city
        let fahrenheit = Locale.current.measurementSystem == .us
        Task {
            defer { fetching = false }
            guard let reading = await Self.fetch(city: city, fahrenheit: fahrenheit) else {
                // Offline or refused: try again on an open 5 minutes from now,
                // not on every open until it works.
                fetched = Date().addingTimeInterval(-25 * 60)
                place = city
                return
            }
            temperature = reading.temperature
            high = reading.high
            low = reading.low
            code = reading.code
            isDay = reading.isDay
            place = city
            fetched = Date()
        }
    }

    /// A new city in Settings should show at once, not in half an hour.
    func cityChanged() {
        fetched = nil
        temperature = nil
        refreshIfStale()
    }

    // MARK: - Presentation

    var symbol: String { Self.symbol(code: code ?? -1, isDay: isDay) }
    var summary: String { Self.summary(code: code ?? -1) }

    /// SF Symbol for a WMO weather code.
    nonisolated static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "thermometer.medium"
        }
    }

    nonisolated static func summary(code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67: "Rain"
        case 71...77: "Snow"
        case 80...82: "Showers"
        case 85, 86: "Snow showers"
        case 95...99: "Thunderstorm"
        default: "Weather"
        }
    }

    var detail: String {
        var parts = [place ?? city, summary]
        if let high, let low { parts.append("H \(high)°  L \(low)°") }
        return parts.joined(separator: " · ")
    }

    func openApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Weather.app"))
    }

    // MARK: - Questions

    /// A day of forecast: today's or tomorrow's.
    struct Day: Sendable, Equatable {
        let code: Int
        let high: Int
        let low: Int
        /// Highest chance of rain in the day, in percent.
        let rain: Int?
    }

    /// The answer to a weather question typed into the command bar.
    struct Report: Sendable, Equatable {
        let place: String
        /// "Tomorrow", "Friday" - nil for today.
        let day: String?
        /// The sky now for today, the day's for any other.
        let code: Int
        /// Now, for today; nil for another day.
        let temperature: Int?
        let feels: Int?
        let isDay: Bool
        let forecast: Day
    }

    /// "weather", "will it rain", "how hot is it in Tokyo".
    nonisolated static func isQuestion(_ text: String) -> Bool {
        text.lowercased().range(
            of: #"\b(weather|forecast|temperature|rain|raining|rainy|umbrella|sunny|humid|humidity|how (hot|cold|warm))\b"#,
            options: .regularExpression) != nil
    }

    /// The weather `offset` days from today (0 to 6), for the city the
    /// question names or the island's own. Nil when the service cannot be
    /// reached.
    nonisolated static func report(for question: String, offset: Int, label: String?, city fallback: String) async -> Report? {
        let lower = question.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ?!."))
        // "in Tokyo", "in New York tomorrow" - but not "in the afternoon".
        var city = fallback
        if let match = lower.range(of: #"\bin ([a-z][a-z .'-]{1,30}?)(?: (?:today|tomorrow|now|tonight|right now))?$"#,
                                   options: .regularExpression) {
            let name = lower[match].dropFirst(3)
                .replacingOccurrences(of: #" (today|tomorrow|now|tonight|right now)$"#, with: "", options: .regularExpression)
            if !name.hasPrefix("the "), !["morning", "afternoon", "evening"].contains(name) {
                city = name.capitalized
            }
        }
        let fahrenheit = Locale.current.measurementSystem == .us
        guard let reading = await fetch(city: city, fahrenheit: fahrenheit),
              reading.days.indices.contains(offset)
        else { return nil }
        let today = offset == 0
        return Report(
            place: city, day: today ? nil : label,
            code: today ? reading.code : reading.days[offset].code,
            temperature: today ? reading.temperature : nil,
            feels: today ? reading.feels : nil,
            isDay: today ? reading.isDay : true,
            forecast: reading.days[offset]
        )
    }

    // MARK: - Network

    private struct Reading: Sendable {
        let temperature: Int
        let high: Int?
        let low: Int?
        let code: Int
        let isDay: Bool
        let feels: Int?
        /// Today, then tomorrow.
        let days: [Day]
    }

    private struct Geocoding: Decodable {
        struct Place: Decodable { let latitude: Double; let longitude: Double }
        let results: [Place]?
    }

    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double?
            let weather_code: Int
            let is_day: Int
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let weather_code: [Int]?
            let precipitation_probability_max: [Int?]?
        }
        let current: Current
        let daily: Daily?
    }

    /// Coordinates are cached per city, so after the first lookup each refresh
    /// is one request.
    nonisolated private static func fetch(city: String, fahrenheit: Bool) async -> Reading? {
        let cacheKey = "weatherPlace.\(city.lowercased())"
        var coordinates = UserDefaults.standard.array(forKey: cacheKey) as? [Double]
        if coordinates?.count != 2 {
            var search = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            search.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
            guard let url = search.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let place = try? JSONDecoder().decode(Geocoding.self, from: data).results?.first
            else { return nil }
            coordinates = [place.latitude, place.longitude]
            UserDefaults.standard.set(coordinates, forKey: cacheKey)
        }
        guard let coordinates, coordinates.count == 2 else { return nil }
        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [
            .init(name: "latitude", value: String(coordinates[0])),
            .init(name: "longitude", value: String(coordinates[1])),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max"),
            .init(name: "forecast_days", value: "7"),
            .init(name: "timezone", value: "auto"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        guard let url = forecast.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let reading = try? JSONDecoder().decode(Forecast.self, from: data)
        else { return nil }
        let days: [Day] = reading.daily.map { daily in
            zip(daily.temperature_2m_max, daily.temperature_2m_min).enumerated().map { i, pair in
                Day(code: daily.weather_code?[safe: i] ?? reading.current.weather_code,
                    high: Int(pair.0.rounded()), low: Int(pair.1.rounded()),
                    rain: daily.precipitation_probability_max?[safe: i] ?? nil)
            }
        } ?? []
        return Reading(
            temperature: Int(reading.current.temperature_2m.rounded()),
            high: days.first?.high,
            low: days.first?.low,
            code: reading.current.weather_code,
            isDay: reading.current.is_day == 1,
            feels: reading.current.apparent_temperature.map { Int($0.rounded()) },
            days: days
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
