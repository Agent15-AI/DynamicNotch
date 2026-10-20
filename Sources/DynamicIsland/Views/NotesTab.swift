import SwiftUI

/// Scratchpad. A list of notes beside the one being edited.
///
/// Two columns rather than a list that swaps to an editor: the panel is wide and
/// short, so putting them side by side costs nothing and removes a navigation
/// step. Same reason the home tab shows the player and the calendar together.
struct NotesTab: View {
    var notes = Notes.shared
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            list
                .frame(width: 176)

            Rectangle()
                .fill(Theme.edge)
                .frame(width: 1)
                .padding(.vertical, 2)

            editor
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("NOTES").sectionLabel()
                Spacer(minLength: 0)
                TextAction("New", tint: Theme.gold) {
                    notes.add()
                    editing = true
                }
            }
            .staggered(0)

            if notes.items.isEmpty {
                EmptyState(symbol: "square.and.pencil",
                           title: "No notes",
                           detail: "New starts one")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .staggered(1)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(Array(notes.items.enumerated()), id: \.element.id) { index, note in
                            NoteRow(note: note, selected: notes.selection == note.id) {
                                notes.selection = note.id
                            }
                            .staggered(index + 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let note = notes.selected {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(note.edited.formatted(date: .abbreviated, time: .shortened))
                        .font(TypeScale.caption)
                        .foregroundStyle(Theme.tertiary)
                    Spacer(minLength: 0)
                    TextAction("Copy", tint: Theme.secondary) { notes.copy(note.id) }
                    TextAction("Delete", tint: Theme.core) { notes.remove(note.id) }
                }

                // Binding straight through the store: the debounce lives there,
                // so typing writes to disk once a sentence rather than once a
                // keystroke.
                TextEditor(text: Binding(
                    get: { notes.selected?.text ?? "" },
                    set: { notes.update(note.id, text: $0) }
                ))
                .focused($editing)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.primary)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(alignment: .topLeading) {
                    if note.text.isEmpty {
                        // Measured against where real text lands, not guessed.
                        // `NSTextView` starts its first glyph one line-fragment
                        // padding in (5pt) with no top inset; the old 9/8 put
                        // the placeholder 4pt right and 8pt below the caret.
                        Text("Type here")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            }
            .staggered(1)
        } else {
            EmptyState(symbol: "text.cursor",
                       title: "Nothing selected",
                       detail: "Pick a note or start a new one")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NoteRow: View {
    var note: Notes.Note
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(note.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Theme.primary : Theme.secondary)
                    .lineLimit(1)
                Text(note.preview)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.10)
                          : hovering ? Color.white.opacity(0.05) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(Pressable(scale: 0.98))
        .hoverHighlight($hovering)
    }
}
