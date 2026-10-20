import AppKit
import Foundation

/// Short-lived text: meeting notes, numbers, fragments on their way somewhere
/// else.
///
/// Saves as you type, but not on every keystroke - one cancellable work item
/// debounces the write. No timer, nothing running when the island is closed.
///
/// Stored as one JSON file rather than in `UserDefaults`: notes are the only
/// thing here that can grow without bound, and a preferences plist is the wrong
/// place for a few kilobytes of prose.
@MainActor
@Observable
final class Notes {
    static let shared = Notes()

    struct Note: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var text: String = ""
        var edited: Date = .now

        /// First non-empty line, which is what people actually name notes by.
        var title: String {
            let first = text.split(separator: "\n", omittingEmptySubsequences: true).first
                .map(String.init)?.trimmingCharacters(in: .whitespaces)
            guard let first, !first.isEmpty else { return "Empty note" }
            return first.count > 42 ? String(first.prefix(42)) + "…" : first
        }

        var preview: String {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count > 1 else { return "No other text" }
            return String(lines[1]).trimmingCharacters(in: .whitespaces)
        }
    }

    private(set) var items: [Note] = []
    var selection: UUID?

    private var save: DispatchWorkItem?

    nonisolated private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("DynamicIsland", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory())
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("notes.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let stored = try? JSONDecoder().decode([Note].self, from: data) {
            items = stored
        }
        selection = items.first?.id
    }

    var selected: Note? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    func add(text: String = "") {
        let note = Note(text: text)
        items.insert(note, at: 0)
        selection = note.id
        persist()
    }

    func update(_ id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].text = text
        items[index].edited = .now
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        if selection == id { selection = items.first?.id }
        persist()
    }

    func copy(_ id: UUID) {
        guard let note = items.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
        HUD.shared.show(
            .utility(symbol: "doc.on.doc.fill", title: note.title, detail: "Copied"), for: 2.0
        )
    }

    /// Debounced. Typing a sentence writes the file once, not thirty times.
    private func persist() {
        save?.cancel()
        let work = Self.writer(items)
        save = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Built outside the main actor on purpose. A `DispatchWorkItem` closure
    /// written inside a `@MainActor` method inherits that isolation, and
    /// running it on a background queue trips the runtime isolation check -
    /// SIGTRAP, 0.6s after every keystroke. That is what this used to do.
    nonisolated private static func writer(_ snapshot: [Note]) -> DispatchWorkItem {
        DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
