import Foundation

/// Lyrics under the player, in time with the track.
///
/// From [LRCLIB](https://lrclib.net/docs), which needs no key and no account -
/// the same reason Open-Meteo was chosen for the weather. One request per
/// track, never on a timer, and nothing is sent but the track's own metadata.
///
/// ponytail: the current line is computed from `NowPlaying.livePosition`, which is
/// already derived from `elapsedTime + timestamp` rather than a tick. So the
/// lyric follows the song with no clock of its own - the view re-reads it while
/// the island is open, and nothing runs when it is shut.
@MainActor
@Observable
final class Lyrics {
    static let shared = Lyrics()

    /// Timed lines, ascending. Empty when the track has none.
    private(set) var lines: [(time: Double, text: String)] = []
    /// Set when LRCLIB has only unsynced words.
    private(set) var plain: String?
    private(set) var loading = false
    /// The track these lyrics are for, so a late answer for the previous song
    /// is not shown against the current one.
    private(set) var track = ""

    /// Whether the home tab has a lyric line to draw. The island grows by it,
    /// because the player column has no spare height for one.
    var showing: Bool {
        Settings.shared.lyrics && (!lines.isEmpty || !(plain ?? "").isEmpty)
    }

    /// Tracks LRCLIB had nothing for.
    private var missing: Set<String> = []

    private init() {}

    /// Called when the track changes and when the island opens.
    func refresh() {
        let player = NowPlaying.shared
        guard Settings.shared.lyrics, !player.title.isEmpty else { clear(); return }
        let key = "\(player.artist)\u{1}\(player.title)\u{1}\(Int(player.duration))"
        guard key != track else { return }

        // Cleared first, always. Returning early for a track already asked about
        // left the previous song's words on screen: play A, then B, then A again
        // and B's lyrics ran under A.
        clear()
        track = key
        // A track with no lyrics must not be asked for again every time the
        // island opens. One that had some is asked again - once per track
        // change, which is the budget anyway.
        guard !missing.contains(key) else { return }
        loading = true
        let artist = player.artist, title = player.title
        let album = player.album, duration = player.duration
        Task {
            let found = await Self.fetch(artist: artist, title: title, album: album, duration: duration)
            // The song may have moved on while the request was in flight.
            guard track == key else { return }
            loading = false
            guard let found else {
                missing.insert(key)
                if missing.count > 200 { missing.removeAll() }
                return
            }
            lines = found.synced
            plain = found.synced.isEmpty ? found.plain : nil
        }
    }

    func clear() {
        lines = []
        plain = nil
        loading = false
        track = ""
    }

    /// The line being sung at `elapsed`, and the one after it.
    ///
    /// A binary search rather than a scan: called on every redraw while the
    /// island is open, against a list that can run to several hundred lines.
    func current(at elapsed: Double) -> (now: String, next: String?)? {
        guard !lines.isEmpty else { return nil }
        var low = 0, high = lines.count - 1, found = -1
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].time <= elapsed {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard found >= 0 else { return ("", lines.first?.text) }
        return (lines[found].text, found + 1 < lines.count ? lines[found + 1].text : nil)
    }

    /// When each line still to come starts, from now, at the playing speed -
    /// the redraw schedule for the lyric line.
    func changes(after elapsed: Double, rate: Double) -> [Date] {
        let now = Date()
        let speed = rate > 0 ? rate : 1
        // 20ms past each start: a redraw that fires a hair early would read the
        // previous line and then wait for the next one.
        return lines.map(\.time).filter { $0 > elapsed }.map { now.addingTimeInterval(($0 - elapsed) / speed + 0.02) }
    }

    // MARK: - Network

    private struct Answer: Sendable {
        let synced: [(time: Double, text: String)]
        let plain: String?
    }

    private struct Record: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool?
        let duration: Double?
    }

    nonisolated private static func fetch(
        artist: String, title: String, album: String, duration: Double
    ) async -> Answer? {
        // The exact signature first. LRCLIB matches on duration within a couple
        // of seconds, which is what stops a cover or a live version answering
        // for the studio cut.
        var record: Record? = await call("get", [
            ("artist_name", artist),
            ("track_name", title),
            ("album_name", album.isEmpty ? nil : album),
            ("duration", duration > 0 ? String(Int(duration.rounded())) : nil),
        ])
        // Then a search, because the exact match only answers when the player
        // agrees with LRCLIB about the album and the length - and players often
        // do not. Spotify files Drake's "What's Next" under Scary Hours at 2:53,
        // LRCLIB under a live album at 2:24, and `get` said 404 for a song it
        // has the words to. A length within a few seconds wins, then timed words.
        if record == nil {
            let found: [Record] = await call("search", [("artist_name", artist), ("track_name", title)]) ?? []
            record = found
                .filter { $0.instrumental != true && ($0.syncedLyrics != nil || $0.plainLyrics != nil) }
                .min { rank($0, duration) < rank($1, duration) }
        }
        guard let record, record.instrumental != true else { return nil }
        return Answer(synced: parse(record.syncedLyrics ?? ""), plain: record.plainLyrics)
    }

    /// Lower is better: the same length first, then timed over untimed, then
    /// the closest length.
    nonisolated private static func rank(_ record: Record, _ duration: Double) -> (Int, Int, Double) {
        let gap = abs((record.duration ?? 0) - duration)
        return (duration > 0 && gap <= 3 ? 0 : 1, record.syncedLyrics == nil ? 1 : 0, gap)
    }

    nonisolated private static func call<T: Decodable>(_ endpoint: String, _ query: [(String, String?)]) async -> T? {
        var components = URLComponents(string: "https://lrclib.net/api/\(endpoint)")!
        components.queryItems = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        // LRCLIB asks clients to identify themselves.
        request.setValue("DynamicIsland (https://github.com/)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// `[mm:ss.xx] words`. One line may carry several stamps when a phrase
    /// repeats, which is why the timestamps are read in a loop rather than once.
    nonisolated private static func parse(_ text: String) -> [(time: Double, text: String)] {
        var found: [(Double, String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(line)
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let body = rest[rest.index(after: rest.startIndex)..<close]
                let parts = body.split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                    stamps.append(minutes * 60 + seconds)
                }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for stamp in stamps { found.append((stamp, words)) }
        }
        return found.sorted { $0.0 < $1.0 }.map { (time: $0.0, text: $0.1) }
    }
}
