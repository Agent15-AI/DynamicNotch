import AppKit

/// Text you type often, behind a short name.
///
/// Deliberately *not* an expander. Watching for a trigger as you type needs a
/// keyboard tap running for every keystroke in every app forever, which is the
/// one thing this app refuses to do - see the power rules. A snippet is
/// inserted from the command bar instead, which costs nothing when you are not
/// using it and works in software that eats synthetic keystrokes anyway.
@MainActor
@Observable
final class Snippets {
    static let shared = Snippets()

    struct Snippet: Identifiable, Codable, Equatable {
        var id = UUID()
        /// What you type in the bar.
        var name: String
        var body: String
    }

    private(set) var items: [Snippet] = []
    private var save: DispatchWorkItem?

    nonisolated private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("DynamicIsland", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory())
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("snippets.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let stored = try? JSONDecoder().decode([Snippet].self, from: data) {
            items = stored
        }
    }

    func add(name: String, body: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !body.isEmpty else { return }
        items.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        items.insert(Snippet(name: name, body: body), at: 0)
        persist()
    }

    func remove(_ snippet: Snippet) {
        items.removeAll { $0.id == snippet.id }
        persist()
    }

    func update(_ snippet: Snippet) {
        guard let index = items.firstIndex(where: { $0.id == snippet.id }) else { return }
        items[index] = snippet
        persist()
    }

    /// Fills in the placeholders.
    ///
    /// ponytail: four of them, resolved by substitution. A template language
    /// for a feature whose whole point is pasting a fixed paragraph would be
    /// more syntax than text.
    func expand(_ body: String) -> String {
        let now = Date()
        let date = DateFormatter()
        date.dateStyle = .long
        date.timeStyle = .none
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        return body
            .replacingOccurrences(of: "{clipboard}", with: NSPasteboard.general.string(forType: .string) ?? "")
            .replacingOccurrences(of: "{date}", with: date.string(from: now))
            .replacingOccurrences(of: "{time}", with: time.string(from: now))
            .replacingOccurrences(of: "{uuid}", with: UUID().uuidString)
    }

    static let placeholders = "{clipboard}  {date}  {time}  {uuid}"

    private func persist() {
        save?.cancel()
        let work = Self.writer(items)
        save = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// The pending debounced write, now. Run on quit.
    func flush() {
        save?.perform()
    }

    /// Nonisolated for the reason `Clipboard.writer` gives: a work item closure
    /// made on the main actor traps when a background queue runs it.
    nonisolated private static func writer(_ snapshot: [Snippet]) -> DispatchWorkItem {
        DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: file, options: .atomic)
            // A snippet can hold an address or a licence key.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
