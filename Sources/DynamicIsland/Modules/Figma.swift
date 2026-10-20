import AppKit

/// Figma files in the command bar.
///
/// Figma's API has no search endpoint, so this is not a search - it is a list
/// fetched once and matched locally. Teams give projects, projects give files;
/// that is the whole API surface available, and it is why a team id has to be
/// pasted in Settings rather than discovered.
///
/// The cost is one burst of requests per bar opening, at most every 30 minutes,
/// and nothing at all at rest - the same gate `Weather` uses. The list is
/// cached to disk so the first opening after a launch has something to show
/// before the network answers.
///
/// ponytail: no provider protocol, no plugin host. This is one integration
/// written concretely at one call site. A second one is not an argument for an
/// abstraction; it is an argument for script commands, where the user's own
/// script carries its own credentials.
@MainActor
@Observable
final class Figma {
    static let shared = Figma()

    struct File: Codable, Identifiable, Sendable, Equatable {
        let key: String
        let name: String
        let thumbnail_url: String?
        let last_modified: Date
        /// The project it lives in, which is what tells two "Untitled" apart.
        var project: String = ""
        var id: String { key }

        var thumbnail: URL? { thumbnail_url.flatMap(URL.init(string:)) }
        var web: URL { URL(string: "https://www.figma.com/design/\(key)/")! }
        /// Opens the desktop app when it is installed.
        var app: URL { URL(string: "figma://file/\(key)")! }
    }

    private(set) var files: [File] = []
    var onChange: (() -> Void)?

    private var fetched: Date?
    private var fetching = false

    private init() { files = Self.cached() }

    var configured: Bool {
        Self.token() != nil && !Settings.shared.figmaTeams.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Called when the bar opens.
    func refreshIfStale() {
        guard Settings.shared.figma, configured, !fetching else { return }
        if let fetched, Date().timeIntervalSince(fetched) < 30 * 60 { return }
        guard let token = Self.token() else { return }
        let teams = Settings.shared.figmaTeams
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map(String.init)
        guard !teams.isEmpty else { return }

        fetching = true
        Task {
            defer { fetching = false }
            let found = await Self.fetch(teams: teams, token: token)
            guard !found.isEmpty else {
                // Offline, a bad token, or a team that is not ours: try again
                // in five minutes rather than on every opening until it works.
                fetched = Date().addingTimeInterval(-25 * 60)
                return
            }
            files = found
            fetched = Date()
            Self.cache(found)
            onChange?()
        }
    }

    /// A new token or team should show at once, not in half an hour.
    func settingsChanged() {
        fetched = nil
        refreshIfStale()
    }

    func open(_ file: File) {
        // The desktop app is the better destination when it is installed, and
        // `open` says whether anything answered the scheme.
        if !NSWorkspace.shared.open(file.app) {
            NSWorkspace.shared.open(file.web)
        }
    }

    // MARK: - Network

    private struct Projects: Decodable { struct Project: Decodable { let id: String; let name: String }
        let projects: [Project] }
    private struct Files: Decodable { let files: [File] }

    nonisolated private static func fetch(teams: [String], token: String) async -> [File] {
        var all: [File] = []
        for team in teams {
            guard let projects: Projects = await get("/v1/teams/\(team)/projects", token: token) else { continue }
            for project in projects.projects {
                guard let listing: Files = await get("/v1/projects/\(project.id)/files", token: token) else { continue }
                all += listing.files.map { file in
                    var named = file
                    named.project = project.name
                    return named
                }
            }
        }
        // Recency is the ranking here for the same reason it is in file search:
        // the file you want is the one you had open this week.
        return all.sorted { $0.last_modified > $1.last_modified }
    }

    nonisolated private static func get<T: Decodable>(_ path: String, token: String) async -> T? {
        guard let url = URL(string: "https://api.figma.com" + path) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    // MARK: - Cache

    nonisolated private static var cacheURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let folder = base.appendingPathComponent("DynamicIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("figma.json")
    }

    nonisolated private static func cached() -> [File] {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([File].self, from: data)) ?? []
    }

    nonisolated private static func cache(_ files: [File]) {
        guard let url = cacheURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(files).write(to: url, options: .atomic)
    }

    // MARK: - Token

    /// The personal access token lives in the Keychain, not in `Settings`.
    ///
    /// `Settings` is UserDefaults, which is a plist in the user's container
    /// readable by any process running as that user. A Figma token grants read
    /// access to every file in every team the account can see, so storing it
    /// there would be leaving a credential in plaintext on disk. This is the
    /// app's first stored secret; the Keychain is where it belongs.
    private static let service = "dev.local.dynamicisland"
    private static let account = "figma-token"

    static func token() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func setToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        // Available without unlocking anything after the first login, and never
        // synced to another machine - a token is per-Mac by nature.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
