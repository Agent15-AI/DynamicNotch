import Foundation

/// How often you pick a thing, decayed by how long ago you last picked it.
///
/// Exponential decay with a half-life, not the bucketed multipliers z, autojump
/// and zoxide use (×4 within the hour, ×2 within the day, ÷2 within the week,
/// ÷4 beyond). Buckets are a 16× swing that a single access can trigger by
/// crossing an hour boundary, so one visit to something long dormant re-weights
/// its entire history at the top multiplier and the list lurches. Firefox ran
/// bucketed weights for years and moved off them; `fre` was written specifically
/// to fix that artefact. Decay is smooth, so a revisit moves an item
/// proportionally rather than promoting it a whole category.
///
/// ponytail: one `Double` and one timestamp per item, not a list of visits.
/// Multiplying the stored score by `2^(-age / halfLife)` before adding 1 is
/// arithmetically the same as summing `2^(-age/halfLife)` over every access
/// ever made, because the decay factors compose. The full history is already in
/// the number.
///
/// That identity also removes the maintenance job. zoxide has to sweep the
/// database when the total passes `_ZO_MAXAGE`, dividing every score down and
/// evicting what falls under 1. Here a steady habit converges on its own:
/// against a fortnight's half-life a score settles at `1 / (1 - 2^(-gap/halfLife))`
/// and stops climbing - measured at 3.4 for something opened weekly, 20.7 daily
/// and 485 hourly. Nothing has to run on a timer to keep it bounded, which is
/// the property this app cares about more than most.
@MainActor
enum Frecency {
    /// A fortnight. Something used weekly keeps half its weight; something used
    /// once and abandoned is worth a twentieth of that inside three months.
    private static let halfLife: Double = 14 * 24 * 3600

    private static let key = "frecency"
    /// Enough for every app and command a person actually reaches for. The cap
    /// exists because the keys are unbounded - every file ever opened from the
    /// bar would otherwise be kept for good.
    private static let capacity = 400

    /// `[key: [score, lastUsed]]`. A plain plist type, so `Settings`' own
    /// `UserDefaults` can hold it with no encoder.
    private static var table: [String: [Double]] =
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]]) ?? [:]

    /// What this item is worth right now.
    static func score(_ item: String) -> Double {
        guard let row = table[item], row.count == 2 else { return 0 }
        return decayed(row[0], since: row[1])
    }

    /// Picked it. Decay what was there, then add this one.
    ///
    /// Takes an optional because most callers are handing over a result that
    /// may not be the kind worth learning from, and a `guard` here beats the
    /// same `if let` at every call site.
    static func record(_ item: String?) {
        guard let item else { return }
        let now = Date().timeIntervalSince1970
        table[item] = [score(item) + 1, now]
        prune()
        UserDefaults.standard.set(table, forKey: key)
    }

    /// A multiplier for a match score: 1 for something never picked, rising to
    /// 1.9 for something picked constantly.
    ///
    /// Multiplied rather than added, and this is the part worth getting right.
    /// A flat bonus lets a heavily used item that matches the query *badly*
    /// overtake one that matches it perfectly - type `term` and get a favourite
    /// app that merely contains those letters instead of Terminal. Scaling
    /// keeps the ordering match-first: usage separates results that are already
    /// comparable, and never rescues a poor match. A perfect match is worth
    /// more than a habit.
    ///
    /// Logarithmic, so the hundredth launch of Safari does not bury everything
    /// else for good, and capped, so the boost can never exceed a doubling.
    static func boost(_ item: String?) -> Double {
        guard let item, case let value = score(item), value > 0 else { return 1 }
        return 1 + 0.9 * min(1, log2(1 + value) / 8)
    }

    /// Applies `boost` and the source's own weight to a match score. Negative
    /// scores are left alone - they are already-rejected matches, and scaling
    /// one up makes it worse.
    ///
    /// `weight` says how likely a match in that source is to be the thing meant.
    /// The set of installed applications is small and deliberate; the set of
    /// files on a disk is enormous and mostly incidental, so a file has to
    /// match better than an app to beat it. Without that, `saf` answered
    /// `safe.tcl` before Safari - a short filename scores well on a short query
    /// purely by being short.
    static func rank(_ score: Int, _ item: String?, weight: Double = 1) -> Int {
        score > 0 ? Int(Double(score) * weight * boost(item)) : score
    }

    private static func decayed(_ score: Double, since: Double) -> Double {
        let age = Date().timeIntervalSince1970 - since
        // A clock that went backwards should not inflate anything.
        guard age > 0 else { return score }
        return score * pow(2, -age / halfLife)
    }

    /// Drops what has decayed to nothing, and keeps the table from growing
    /// without end. Not the periodic sweep zoxide needs - decay bounds the
    /// scores by itself; this only bounds the number of keys.
    private static func prune() {
        var live = table.filter { _, row in
            row.count == 2 && decayed(row[0], since: row[1]) > 0.02
        }
        if live.count > capacity {
            let keep = live
                .map { ($0.key, decayed($0.value[0], since: $0.value[1])) }
                .sorted { $0.1 > $1.1 }
                .prefix(capacity)
                .map(\.0)
            live = live.filter { keep.contains($0.key) }
        }
        table = live
    }

    /// Settings ▸ Command bar, for when the ordering has learned something the
    /// user disagrees with.
    static func forget() {
        table = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }
}
