import AppKit
import Foundation

/// Live Claude Code sessions, read straight from `~/.claude/projects`.
///
/// Claude Code appends to `<project-slug>/<session-uuid>.jsonl` as a
/// conversation runs, so the file's modification date *is* the session's last
/// activity. Nothing to install and nothing to keep in sync.
///
/// ponytail: this replaced a watched `~/.dynamicisland/status.json` that any
/// tool could write. Fully general, and in practice permanently empty - the
/// producer was a hook you had to wire yourself, so the tab showed "Nothing
/// running" forever. Reading the state Claude Code already writes needs no
/// setup at all.
@MainActor
@Observable
final class Tasks {
    static let shared = Tasks()

    struct Item: Identifiable, Equatable {
        var id: String
        var text: String
        var state: State
        /// Last activity, which is what the row counts up from.
        var startedAt: Date?
        /// Working directory, opened when the row is clicked.
        var app: String?

        /// Traffic light. Green is working, amber wants an answer, red has
        /// stopped and is waiting on you to notice.
        enum State: String { case running, waiting, stopped }
    }

    private(set) var items: [Item] = []

    var running: Int { items.filter { $0.state == .running }.count }
    var waiting: Int { items.filter { $0.state == .waiting }.count }

    /// Dot shown while collapsed. Amber outranks green: a session that wants an
    /// answer is the one worth interrupting you for, and one that is working is
    /// by definition fine on its own.
    ///
    /// Red is deliberately excluded. `idleVisible` treats a non-nil summary as
    /// reason to paint the island, and a stopped session stays stopped - it
    /// would pin the idle island on for the rest of the day. It is still a red
    /// row in the tab, which is where you go to look.
    var summary: Item.State? {
        if waiting > 0 { return .waiting }
        return running > 0 ? .running : nil
    }

    /// Sessions touched within this window are listed at all.
    private nonisolated static let listWindow: TimeInterval = 24 * 60 * 60
    /// Claude writes continuously while it works, so a file touched this
    /// recently has something running behind it.
    private nonisolated static let liveWindow: TimeInterval = 60
    /// How long a finished turn still counts as waiting on you rather than
    /// abandoned.
    private nonisolated static let attentionWindow: TimeInterval = 30 * 60
    /// Enough to fill the tab; past that the list is scrollback nobody reads.
    private nonisolated static let maximumRows = 12

    private static var projectsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    private init() {}

    /// Called at launch so the collapsed dot is right, and from the tab.
    ///
    /// No watcher and no timer. The session files live one directory deeper than
    /// `projects`, and a `DispatchSource` on a directory reports its own entries
    /// changing - not writes inside its children - so watching would mean one
    /// descriptor per project for a list that is only ever read while the island
    /// is open. Same bargain the mixer makes: refresh on appear, nothing at rest.
    func start() {
        guard Settings.shared.buildStatus else { return }
        refresh()
    }

    func refresh() {
        guard Settings.shared.buildStatus else { items = []; return }
        let manager = FileManager.default
        let now = Date()

        let projects = (try? manager.contentsOfDirectory(
            at: Self.projectsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        var found: [Item] = []
        for project in projects {
            let sessions = (try? manager.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            // One row per project, not per session. A project you have resumed
            // eleven times is one thing you are working on, and eleven rows for
            // it pushes everything else off the tab.
            let latest = sessions
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> (URL, Date)? in
                    guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate else { return nil }
                    return (url, date)
                }
                .max { $0.1 < $1.1 }

            guard let (url, modified) = latest,
                  now.timeIntervalSince(modified) < Self.listWindow
            else { continue }

            let directory = Self.workingDirectory(of: url)
            found.append(Item(
                id: project.lastPathComponent,
                text: directory.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? project.lastPathComponent,
                state: Self.state(of: url, modified: modified, now: now),
                startedAt: modified,
                app: directory
            ))
        }

        items = found
            .sorted {
                $0.state == $1.state
                    ? ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
                    : $0.state == .running
            }
            .prefix(Self.maximumRows)
            .map { $0 }
    }

    /// Green, amber or red for one session.
    ///
    /// Age alone cannot tell "thinking" from "waiting for you" - both look like
    /// a file that stopped changing. The last entry in the transcript can: an
    /// assistant turn that ended is Claude handing the conversation back, which
    /// is the amber case. Anything else recent is work in progress.
    private nonisolated static func state(
        of session: URL, modified: Date, now: Date
    ) -> Item.State {
        let age = now.timeIntervalSince(modified)
        guard age < Self.attentionWindow else { return .stopped }
        // Read once. Asked separately in each branch this opened and scanned the
        // tail of every transcript twice per refresh.
        switch tail(of: session) {
        case .endedTurn:
            // Claude handed the conversation back - an answer, or a question.
            return .waiting
        case .toolUse:
            // A tool call is the last thing in the transcript. While it is
            // actually running the file keeps growing, so a tool call that has
            // gone quiet is one nobody has approved yet: the permission prompt
            // is sitting on screen waiting to be answered.
            return age < Self.liveWindow ? .running : .waiting
        case .other:
            return age < Self.liveWindow ? .running : .stopped
        }
    }

    private enum Turn { case endedTurn, toolUse, other }

    /// What the transcript ends on.
    ///
    /// Read from the tail, not the head: these files reach tens of megabytes and
    /// only the last entry matters. `stop_reason` is what separates a finished
    /// answer from a pause mid-tool-call.
    private nonisolated static func tail(of session: URL) -> Turn {
        guard let handle = try? FileHandle(forReadingFrom: session) else { return .other }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return .other }
        let window: UInt64 = 16 * 1024
        try? handle.seek(toOffset: end > window ? end - window : 0)
        guard let data = try? handle.readToEnd() else { return .other }
        // Decoded leniently. A window that starts inside a multi-byte character
        // - an em dash, an emoji, anything not ASCII - is not valid UTF-8, and
        // the strict decoder threw the whole tail away for that one byte.
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            // Everything else at the tail - hooks, queue operations, mode
            // markers - says nothing about whose turn it is.
            guard type == "assistant" || type == "user" else { continue }
            guard type == "assistant",
                  let message = object["message"] as? [String: Any]
            else { return .other }
            switch message["stop_reason"] as? String {
            case "end_turn", "stop_sequence": return .endedTurn
            case "tool_use": return .toolUse
            default: return .other
            }
        }
        return .other
    }

    /// Opens the project the session is working in.
    func focus(_ item: Item) {
        guard let path = item.app else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// The session's working directory, taken from the transcript itself.
    ///
    /// The directory name cannot be recovered from the project slug: it is the
    /// path with every `/` replaced by `-`, so a folder whose own name contains a
    /// dash is indistinguishable from a path separator. The transcript records
    /// `cwd` verbatim, which is unambiguous.
    ///
    /// Only the head of the file is read. These transcripts reach tens of
    /// megabytes and `cwd` appears within the first few entries; loading the
    /// whole thing to find a value in its first lines would make opening the tab
    /// cost more than everything else in the island put together.
    private static func workingDirectory(of session: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: session) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024) else { return nil }
        // Leniently, for the reason `tail` gives: the cut can land mid-character.
        let text = String(decoding: head, as: UTF8.self)

        for line in text.split(separator: "\n") {
            guard line.contains("\"cwd\""),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = object["cwd"] as? String
            else { continue }
            return cwd
        }
        return nil
    }
}
