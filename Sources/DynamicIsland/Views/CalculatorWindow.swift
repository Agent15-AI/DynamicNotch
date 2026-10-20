import AppKit
import SwiftUI

/// A scientific calculator on its own hotkey.
///
/// The engine was already here - `Calculator` powers the sums the command bar
/// does - and what was missing is a place to sit and work: a line you can see
/// while you type it, the answer updating beside it, a keypad for the functions
/// nobody remembers the spelling of, and the last lines still on screen.
///
/// Laid out after Desmos's scientific calculator, which is the one everybody has
/// used: two pads rather than three - there is no `abc` here, because there are
/// no variables to name apart from the `x` a derivative binds - the same toolbar
/// of RAD/DEG, undo, redo and clear-all, and the same idea that the keys and the
/// keyboard type into one line.
///
/// Unlike the command bar it does **not** close when you click elsewhere: a
/// calculator is used *while* reading whatever the numbers came from. It closes
/// on the ✕, on Escape, or on the hotkey again.
@MainActor
final class CalculatorWindow: NSObject, NSWindowDelegate {
    static let shared = CalculatorWindow()

    private var window: NSPanel?

    private override init() { super.init() }

    var isOpen: Bool { window != nil }

    func toggle() {
        if isOpen { hide() } else { show() }
    }

    func show() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let size = NSSize(width: 438, height: 470)
        // Borderless with chrome of our own. A hidden titlebar still reserved a
        // strip that swallowed the drag, and its traffic lights sat behind the
        // content where they could not be clicked - so the window could neither
        // be moved nor closed. Own close button, own drag strip, both visible.
        // Not `.nonactivatingPanel`: that flag is what the island's own panels
        // want, and it is exactly wrong here. Measured - the window appeared, the
        // keyboard kept going to whatever was in front, and everything typed
        // landed in that app instead.
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Floating rather than modal: it sits above the window you are reading
        // from without taking over from it.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CalculatorView())

        // Beside the pointer, and back where you left it after that: a window
        // you have just dragged somewhere should reopen there rather than
        // jumping back to the middle. Clamped on both axes, because a pointer
        // near the top of a display would otherwise put the title strip - and
        // with it the close button and the drag handle - off the screen.
        if let screen = NSScreen.underPointer {
            let visible = screen.visibleFrame
            let wanted = lastOrigin ?? NSPoint(
                x: NSEvent.mouseLocation.x - size.width / 2,
                y: NSEvent.mouseLocation.y - size.height + 40
            )
            panel.setFrameOrigin(NSPoint(
                x: min(max(wanted.x, visible.minX + 12), visible.maxX - size.width - 12),
                y: min(max(wanted.y, visible.minY + 12), visible.maxY - size.height - 12)
            ))
        }

        window = panel
        // It needs the keyboard, so it activates - the same call the command bar
        // makes, and Escape gives the focus straight back.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // One more pass after the window server has caught up. Activating an
        // accessory app and making a borderless panel key in the same turn does
        // not always land, and the symptom is a window you have to click once
        // before it will take a keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak panel] in
            guard let panel else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            // And hand the caret to the line. SwiftUI builds its own responder
            // chain inside the hosting view, so the field has to be asked for
            // once the view exists rather than when it was created.
            if let field = panel.contentView.flatMap(Self.firstTextField) {
                panel.makeFirstResponder(field)
            }
        }
    }

    /// Where the window and the pointer were when the current drag started.
    private var dragOrigin: (window: NSPoint, pointer: NSPoint)?

    func beginDrag() {
        guard let window else { return }
        dragOrigin = (window.frame.origin, NSEvent.mouseLocation)
    }

    /// Driven by the pointer's position on screen rather than by the gesture's
    /// own translation.
    ///
    /// The gesture reports movement inside a coordinate space that belongs to
    /// this window - so moving the window moves the space, which changes the
    /// translation, which moves the window again. Measured: a 120pt drag threw
    /// the window 1,200pt across the screen. Screen coordinates do not move when
    /// the window does.
    func drag() {
        guard let dragOrigin, let window else { return }
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: dragOrigin.window.x + (pointer.x - dragOrigin.pointer.x),
            y: dragOrigin.window.y + (pointer.y - dragOrigin.pointer.y)
        ))
    }

    func endDrag() { dragOrigin = nil }

    /// Whenever the window comes to the front, the line takes the caret again.
    ///
    /// Measured without it: the first few characters typed straight after the
    /// hotkey went to the app behind, because activating an accessory app and
    /// giving a borderless panel its first responder do not finish in the same
    /// turn. Anything typed after that landed correctly, which is the worst kind
    /// of bug - it works every time you look at it.
    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        Task { @MainActor in
            guard let window = self.window, let field = window.contentView.flatMap(Self.firstTextField)
            else { return }
            window.makeFirstResponder(field)
        }
    }

    /// The line, wherever SwiftUI put it.
    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for child in view.subviews {
            if let found = firstTextField(in: child) { return found }
        }
        return nil
    }

    /// Where it was last closed, so it reopens there. Memory only.
    private var lastOrigin: NSPoint?

    func hide() {
        lastOrigin = window?.frame.origin
        CalculatorPanel.shared.editor = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }
}

/// A borderless panel will not take the keyboard unless it says it can.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - State

/// What the calculator is holding.
///
/// Outlives the window on purpose: closing it and pressing the hotkey again a
/// minute later should not throw away the working. Memory only - a calculation
/// history is exactly the kind of thing that should not quietly become a file on
/// disk, and `ans` is the only part worth carrying anyway.
@MainActor
@Observable
final class CalculatorPanel {
    static let shared = CalculatorPanel()

    struct Line: Identifiable {
        let id = UUID()
        let expression: String
        let result: String
    }

    enum Pad: String, CaseIterable, Identifiable {
        case main, functions
        var id: String { rawValue }
        var title: String { self == .main ? "main" : "func" }
    }

    /// One edit, applied where the caret is rather than at the end of the line.
    enum Edit {
        case insert(String)
        case left, right, deleteBackward
        /// Straight to a character offset, for a click on the drawn maths.
        case place(Int)
    }

    var input = ""
    /// Where the insertion point is, in characters. The drawing puts the caret
    /// here; the hidden field this is read from is what moves it.
    var caret = 0
    var pad: Pad = .main
    private(set) var lines: [Line] = []
    /// The previous answer, which `ans` reads.
    private(set) var answer: Double?

    /// Set by the field while the window is open. Keys go through it so a press
    /// lands at the caret, which is what makes ← and → mean anything.
    var editor: ((Edit) -> Void)?

    private var past: [String] = []
    private var future: [String] = []

    private static let remembered = 60

    private init() {}

    /// The running answer, shown beside the line as you type. nil while the line
    /// is incomplete, which is most of the time and is not an error.
    ///
    /// A number for a sum, a list for an equation, and a printed expression for a
    /// derivative taken with no point to work it out at.
    var preview: Calculator.Answer? {
        Calculator.answer(input, degrees: Settings.shared.calculatorDegrees, previous: answer)
    }

    // MARK: Editing

    func key(_ edit: Edit) {
        // Only the edits that change something are worth undoing; moving the
        // caret is not an edit.
        switch edit {
        case .insert, .deleteBackward: remember()
        case .left, .right, .place: break
        }
        guard let editor else {
            // No field yet - the window is still opening. Appending keeps the
            // press rather than dropping it.
            switch edit {
            case .insert(let text): input += text; caret = input.count
            case .deleteBackward: if !input.isEmpty { input.removeLast(); caret = input.count }
            case .left, .right, .place: break
            }
            return
        }
        editor(edit)
    }

    func type(_ text: String) { key(.insert(text)) }

    /// Clears the line, then the history - two presses rather than one, because
    /// the history is the working and losing it to a stray press is worse.
    func clear() {
        remember()
        if input.isEmpty { lines.removeAll() } else { input = "" }
    }

    /// The toolbar's "clear all", which means both at once.
    func clearAll() {
        remember()
        input = ""
        lines.removeAll()
    }

    func commit() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        // Return always starts a new line, answer or no answer. Refusing to move
        // on from a line that cannot be worked out - `2x =`, half typed - left
        // the calculator looking frozen, with no way to begin a second one.
        let outcome = preview
        remember()
        lines.append(Line(expression: text, result: outcome.map(Calculator.text(of:)) ?? ""))
        if lines.count > Self.remembered { lines.removeFirst(lines.count - Self.remembered) }
        // `ans` follows a number, and the first solution of an equation. A
        // derivative that came back as a function is not a number and leaves it
        // alone rather than replacing it with something wrong.
        switch outcome {
        case .number(let value): answer = value
        case .roots(let roots, _): answer = roots.first ?? answer
        case .expression, nil: break
        }
        input = ""
    }

    // MARK: Undo

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    private func remember() {
        past.append(input)
        if past.count > Self.remembered { past.removeFirst() }
        future.removeAll()
    }

    func undo() {
        guard let previous = past.popLast() else { return }
        future.append(input)
        input = previous
    }

    func redo() {
        guard let next = future.popLast() else { return }
        past.append(input)
        input = next
    }

    /// Puts the answer on the clipboard - the reason most sums get done at all.
    func copyResult() {
        let text = preview.map(Calculator.text(of:)) ?? answer.map(Calculator.format)
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Clipboard.shared.lastChange = NSPasteboard.general.changeCount
        HUD.shared.show(
            .utility(symbol: "equal.square", title: text, detail: "Copied"),
            for: 1.6
        )
    }
}

// MARK: - View

struct CalculatorView: View {
    @Bindable var panel = CalculatorPanel.shared
    @Bindable var settings = Settings.shared
    /// True for the length of one window drag.
    @State private var dragging = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            history
            entry
            toolbar
            Group {
                switch panel.pad {
                case .main: MainPad()
                case .functions: FunctionPad()
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(width: 438, height: 470)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.shell.opacity(Motion.reducedTransparency ? 1 : 0.92))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.edgeHighlight, lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Close on the left, and the whole strip drags the window - the two things a
    /// window with no titlebar of its own still has to offer.
    private var titleBar: some View {
        ZStack {
            // The whole strip is the handle, including the gaps between the
            // labels. An AppKit drag view behind the content was tried first and
            // never received the press - SwiftUI's hit-testing got there first.
            Color.white.opacity(0.001)
            HStack(spacing: 8) {
                Button { CalculatorWindow.shared.hide() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.notchBlack)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Theme.core))
                }
                .buttonStyle(Pressable())
                .help("Close (Escape)")
                .accessibilityLabel("Close calculator")

                Text("CALCULATOR").sectionLabel()
                Spacer(minLength: 0)
                Text("drag here to move")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary.opacity(0.7))
                TextAction("Copy", tint: Theme.core) { panel.copyResult() }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 34)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in
                    if !dragging {
                        dragging = true
                        CalculatorWindow.shared.beginDrag()
                    }
                    CalculatorWindow.shared.drag()
                }
                .onEnded { _ in
                    dragging = false
                    CalculatorWindow.shared.endDrag()
                }
        )
    }

    /// Everything worked out so far, oldest first, so the newest line sits
    /// against the one being typed.
    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    if panel.lines.isEmpty {
                        Text("Type a sum, or press the keys. ans repeats the last answer.\n"
                 + "x^2 - 5x + 6 = 0 solves · deriv(sin(x)) is cos(x) · deriv(x^2, 3) is 6")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 14)
                    }
                    ForEach(panel.lines) { HistoryRow(line: $0) }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
            }
            .frame(minHeight: 60, maxHeight: .infinity)
            .onChange(of: panel.lines.count) { _, _ in
                withAnimation(Motion.content) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// The line being edited, drawn as maths with the caret inside it.
    ///
    /// There is no text field on screen. One is in the view - a single
    /// transparent point of it - because AppKit's field editor is what knows how
    /// to handle a keyboard: key repeat, dead keys, ⌘V, selection, undo inside
    /// the line. It holds the string and the insertion point; this draws them.
    /// Clicking an atom puts the caret in front of it.
    private var entry: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack(alignment: .leading) {
                // The keyboard lives here, one point wide and invisible.
                CalculatorField(text: $panel.input, caret: $panel.caret)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)

                if let tree = Calculator.tree(of: panel.input), caretHasAPlace {
                    MathView(node: tree, size: 21, caret: panel.caret) { offset in
                        panel.key(.place(offset))
                    }
                } else if panel.input.isEmpty {
                    // Nothing typed: the caret alone, so the line looks ready
                    // rather than missing.
                    EmptyLine(size: 21)
                } else {
                    // Typed, but not readable as maths yet. Still an editable
                    // line: drawn with its caret and clickable, because a line
                    // with no caret in it is a line that looks frozen.
                    //
                    // The same size and face as the drawn maths, deliberately.
                    // Half of typing an expression passes through states that
                    // do not parse - `sin`, `sin(`, `sin(x` - so the line swaps
                    // between these two renderings on almost every keystroke.
                    // At 19pt against the maths' 21 that swap was a visible
                    // jump in size on each letter.
                    RawLine(text: panel.input, caret: panel.caret, size: 21) { offset in
                        panel.key(.place(offset))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .layoutPriority(0)

            if let outcome = panel.preview {
                AnswerView(outcome: outcome, size: 17)
                    .fixedSize()
                    .layoutPriority(1)
                    .transition(.opacity)
            } else if unreadable {
                // Only when the line cannot be read at all. An expression in x -
                // `1/(2√(x+1))` - has no single value and is not an error.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.core.opacity(0.8))
                    .help("Not something that can be read as maths yet")
            }
        }
        .frame(minHeight: 44, alignment: .bottom)
        // Deliberately *not* animated on `input`. A spring across the whole
        // strip meant every keystroke slid the line around, and because the
        // drawing swaps between maths and raw text as an expression passes
        // through states that do not parse, the swap was animated too. Typing
        // should land instantly; only the answer is worth a fade.
        .animation(Motion.content, value: panel.preview == nil)
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 10)
        // The whole strip is a click target for the end of the line, so clicking
        // past the last atom puts the caret there rather than doing nothing.
        .contentShape(Rectangle())
        .onTapGesture { panel.key(.place(panel.input.count)) }
        // Held back until the typing stops. Most of the way through writing an
        // expression it does not parse - `sin`, `sin(`, `sin(x` all fail - so
        // an error mark tied straight to the parse blinks on and off with every
        // letter. It is only worth saying once you have paused.
        //
        // ponytail: `task(id:)` already cancels and restarts on each change,
        // which is the whole of a debounce.
        .task(id: panel.input) {
            guard !panel.input.isEmpty else { unreadable = false; return }
            unreadable = false
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            unreadable = Calculator.tree(of: panel.input) == nil
        }
    }

    /// Whether the line has settled into something that cannot be read. Set by
    /// the debounce above, never read straight from the parser.
    @State private var unreadable = false

    /// Whether the drawn maths has anywhere to put the caret.
    ///
    /// It often does not. `deriv(x)` draws as a `d/dx` beside an `x`, so there
    /// is no position in it that means "between the r and the i". The drawing
    /// used to snap the caret to the nearest offset that *did* have a home,
    /// which put it somewhere the text was not - and, when the arrow keys were
    /// made to step between those homes to match, made offsets 1 to 5 of
    /// `deriv(x)` unreachable altogether. You could not get the caret into the
    /// word to fix a typo in it.
    ///
    /// The text is the source of truth and every offset in it is reachable.
    /// When the caret is somewhere the maths cannot show, the line falls back
    /// to its characters, which can always show it. Same face, same size, so
    /// the change is a quiet one - and it only happens when you deliberately
    /// move into the letters of a name, never while typing at the end.
    private var caretHasAPlace: Bool {
        Calculator.caretStops(in: panel.input).contains(panel.caret)
    }

    /// Desmos's keypad toolbar: which pad, which angle unit, undo, redo, and a
    /// way to wipe the lot.
    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(CalculatorPanel.Pad.allCases) { pad in
                Button { panel.pad = pad } label: {
                    Text(pad.title)
                        .font(.system(size: 11.5, weight: panel.pad == pad ? .semibold : .regular))
                        .foregroundStyle(panel.pad == pad ? Theme.primary : Theme.tertiary)
                        .padding(.bottom, 3)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(panel.pad == pad ? Theme.core : .clear)
                                .frame(height: 1.5)
                        }
                }
                .buttonStyle(Pressable())
            }

            // Radians and degrees, shared with the command bar's sums so the two
            // can never disagree about what sin(90) means.
            HStack(spacing: 0) {
                ForEach([false, true], id: \.self) { degrees in
                    Button { settings.calculatorDegrees = degrees } label: {
                        Text(degrees ? "DEG" : "RAD")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(settings.calculatorDegrees == degrees ? Theme.notchBlack : Theme.tertiary)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(settings.calculatorDegrees == degrees ? Theme.gold : .clear)
                            )
                    }
                    .buttonStyle(Pressable())
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))

            Spacer(minLength: 0)

            Button { panel.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11))
                    .foregroundStyle(panel.canUndo ? Theme.secondary : Theme.tertiary.opacity(0.5))
            }
            .buttonStyle(Pressable())
            .disabled(!panel.canUndo)
            .help("Undo")

            Button { panel.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 11))
                    .foregroundStyle(panel.canRedo ? Theme.secondary : Theme.tertiary.opacity(0.5))
            }
            .buttonStyle(Pressable())
            .disabled(!panel.canRedo)
            .help("Redo")

            TextAction("clear all", tint: Theme.tertiary) { panel.clearAll() }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// The line being typed.
///
/// An `NSTextField` rather than SwiftUI's `TextField`, because the keypad has to
/// insert at the caret and ← → have to move it, and SwiftUI does not report where
/// the caret is. Everything else - selection, double-click, ⌘Z inside the line -
/// comes with the field for free.
private struct CalculatorField: NSViewRepresentable {
    @Binding var text: String
    @Binding var caret: Int

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusedTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .clear
        field.delegate = context.coordinator
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        context.coordinator.field = field
        let coordinator = context.coordinator
        // Arrow keys and clicks inside the field editor move the insertion point
        // without changing the text, and nothing else would tell us.
        coordinator.selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main
        ) { note in
            // The object is read here rather than inside the hop: a notification
            // cannot be carried across isolation, and the offset can.
            guard let view = note.object as? NSTextView else { return }
            let offset = view.selectedRange.location
            let isOurs = view === MainActor.assumeIsolated { coordinator.field?.currentEditor() }
            guard isOurs else { return }
            MainActor.assumeIsolated { coordinator.report(offset) }
        }
        DispatchQueue.main.async {
            CalculatorPanel.shared.editor = { [weak coordinator] edit in
                coordinator?.apply(edit)
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Only when something else changed it - writing on every pass would move
        // the caret to the end while you were typing in the middle of the line.
        if field.stringValue != text {
            field.stringValue = text
            context.coordinator.place(min(caret, text.count))
        }
        // Re-claimed here as well as on the way into the window: a pass can run
        // before the panel is key, and a calculator you have to click before you
        // can type into it is a calculator that ate your first sum.
        if let window = field.window, window.isKeyWindow, window.firstResponder === window {
            window.makeFirstResponder(field)
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        if let observer = coordinator.selectionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, caret: $caret) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        @Binding var caret: Int
        weak var field: NSTextField?
        var selectionObserver: NSObjectProtocol?

        init(text: Binding<String>, caret: Binding<Int>) {
            _text = text
            _caret = caret
        }

        func report(_ offset: Int) {
            guard caret != offset else { return }
            caret = offset
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
            report(field.currentEditor()?.selectedRange.location ?? field.stringValue.count)
        }

        /// Return works the line out; Escape closes. Everything else the field
        /// handles itself, which is the reason it is a field at all.
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                CalculatorPanel.shared.commit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                CalculatorWindow.shared.hide()
                return true
            }
            return false
        }

        func place(_ offset: Int) {
            guard let field else { return }
            let clamped = min(max(offset, 0), field.stringValue.count)
            // Reported first, so a focus change that follows this click reads the
            // new caret rather than the old one.
            report(clamped)
            if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
            guard let editor = field.currentEditor() else { return }
            editor.selectedRange = NSRange(location: clamped, length: 0)
            // And again after AppKit has finished with the click: the field
            // re-selects itself when it takes focus, and that lands after this.
            DispatchQueue.main.async { [weak field] in
                guard let editor = field?.currentEditor() else { return }
                editor.selectedRange = NSRange(location: clamped, length: 0)
            }
        }

        func apply(_ edit: CalculatorPanel.Edit) {
            guard let field else { return }
            // A key press must not need the field to be focused first, but the
            // edit has to go through the field editor to land at the caret.
            if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
            guard let editor = field.currentEditor() as? NSTextView else { return }
            switch edit {
            case .insert(let string): editor.insertText(string, replacementRange: editor.selectedRange())
            case .left: editor.moveLeft(nil)
            case .right: editor.moveRight(nil)
            case .deleteBackward: editor.deleteBackward(nil)
            case .place(let offset): place(offset)
            }
            text = field.stringValue
            report(editor.selectedRange().location)
        }
    }
}

/// A line that cannot be read as maths, drawn as characters with the caret still
/// in it.
///
/// ponytail: a plain `Text` per character rather than anything cleverer. This is
/// the state you are in for a keystroke or two on the way to something valid, and
/// it only has to stay editable.
private struct RawLine: View {
    var text: String
    var caret: Int
    var size: CGFloat
    var moveCaret: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { pair in
                let (offset, character) = pair
                if caret == offset { Caret(size: size) }
                Text(String(character))
                    .font(.system(size: size, design: .serif))
                    .foregroundStyle(Theme.primary)
                    .contentShape(Rectangle())
                    .onTapGesture { moveCaret(offset) }
            }
            if caret >= text.count { Caret(size: size) }
        }
        .contentShape(Rectangle())
        .onTapGesture { moveCaret(text.count) }
    }
}

/// An empty line still has a caret, so it reads as ready rather than as nothing.
///
/// ponytail: this was a second copy of `Caret`'s body, blinking on its own
/// timer. One caret, drawn one way.
private struct EmptyLine: View {
    var size: CGFloat

    var body: some View { Caret(size: size) }
}

/// Takes the keyboard as soon as it is in a window, and again whenever the panel
/// comes back to the front.
///
/// Measured before this existed: the window opened, the caret was nowhere, and
/// everything typed went to the app behind it. `makeFirstResponder` from the
/// representable ran before the field had a window to ask.
private final class FocusedTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // A field selects all of itself when it takes focus, which is wrong for
        // this one: a click on the drawn maths has just said where the caret
        // goes, and select-all would have the next keystroke replace the whole
        // line instead of inserting into it. The caret stays where the panel
        // says it is, or at the end when it has nothing to say.
        guard accepted, let editor = currentEditor() else { return accepted }
        let wanted = min(max(CalculatorPanel.shared.caret, 0), stringValue.count)
        editor.selectedRange = NSRange(location: wanted, length: 0)
        hideNativeMarks(editor)
        return accepted
    }

    /// Hides the field editor's own insertion point and selection.
    ///
    /// `textColor = .clear` hides the letters but not these two, and they are
    /// drawn by the field editor against the *hidden* 13pt line - which has no
    /// relationship to the 21pt maths drawn above it. The result was two
    /// carets: the real one under `MathView`'s control, and a white bar
    /// somewhere else entirely that moved with a layout nobody can see.
    ///
    /// The field editor is shared by every control in the window and is handed
    /// out fresh, so this is set each time focus is taken rather than once.
    private func hideNativeMarks(_ editor: NSText) {
        guard let view = editor as? NSTextView else { return }
        view.insertionPointColor = .clear
        // Same reasoning for the selection: `MathView` draws no selection, so a
        // highlight over invisible text is a grey rectangle sitting on the
        // maths for no stated reason.
        view.selectedTextAttributes = [.backgroundColor: NSColor.clear]
    }
}

private struct HistoryRow: View {
    var line: CalculatorPanel.Line
    @State private var hovering = false

    var body: some View {
        // Clicking puts the answer back on the line, which is what a history is
        // for - the alternative is retyping a number you can see.
        Button {
            // An answer goes back on the line; a line that never had one comes
            // back whole, to be finished.
            CalculatorPanel.shared.type(line.result.isEmpty ? line.expression : line.result)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if let tree = Calculator.tree(of: line.expression) {
                        MathView(node: tree, size: 13, color: Theme.tertiary)
                    } else {
                        Text(line.expression)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .lineLimit(1)
                // The expression yields and is cut off; the answer never is. One
                // wide row - a sum with its limits - otherwise stretched the
                // whole stack past the edge of the panel and took every row's
                // answer with it.
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .layoutPriority(0)
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // "x = 2 or 3" says `=` already; putting one in front of it
                    // reads as `= x = 2 or 3`.
                    if line.result.isEmpty {
                        // Filed without an answer, because it never had one.
                        Text("—").foregroundStyle(Theme.tertiary)
                    } else {
                        if !line.result.hasPrefix("x =") { Text("=") }
                        if let tree = Calculator.tree(of: line.result), !line.result.hasPrefix("x =") {
                            MathView(node: tree, size: 13, color: Theme.secondary)
                        } else {
                            Text(line.result).monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(Theme.secondary)
                .fixedSize()
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.995))
        .hoverHighlight($hovering)
        .help("Use \(line.result)")
    }
}

/// The answer, drawn as maths when it is one.
///
/// A number is a number. A derivative comes back as an expression and gets the
/// same treatment as the line above it - `1/(2√(x+1))` is a fraction with a root
/// in it, not a string of brackets.
private struct AnswerView: View {
    var outcome: Calculator.Answer
    var size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // The solutions of an equation read "x = 5" already; an `=` in front
            // of that says it twice.
            if !leadsWithEquals {
                Text("=")
                    .font(.system(size: size, design: .serif))
                    .foregroundStyle(Theme.gold.opacity(0.7))
            }
            content
        }
        .foregroundStyle(Theme.gold)
    }

    private var leadsWithEquals: Bool {
        if case .roots = outcome { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch outcome {
        case .expression(let text):
            if let tree = Calculator.tree(of: text) {
                MathView(node: tree, size: size, color: Theme.gold)
            } else {
                plain(text)
            }
        case .number, .roots:
            plain(Calculator.text(of: outcome))
        }
    }

    private func plain(_ text: String) -> some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .serif))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 210, alignment: .trailing)
    }
}

// MARK: - Keys

/// What a key does. Every one of them types into the same line the keyboard
/// does, so there is one input and one parser rather than a second calculator
/// hiding behind the buttons.
private struct Key: Identifiable {
    var label: String
    var edit: CalculatorPanel.Edit = .insert("")
    var tint: KeyButton.Tint = .function
    /// Columns this key takes, for the wide ones along the bottom.
    var span: Int = 1
    var help: String?

    var id: String { label }

    static func type(_ label: String, _ text: String, _ tint: KeyButton.Tint = .function,
                     help: String? = nil) -> Key {
        Key(label: label, edit: .insert(text), tint: tint, help: help)
    }
}

/// The everyday pad: digits, operators, and the functions that earn their place
/// beside them. Nine columns, the split Desmos uses - functions, digits, then the
/// two keys that are neither.
private struct MainPad: View {
    private static let rows: [[Key]] = [
        [
            .type("a²", "^2", .function, help: "Squared"),
            .type("aᵇ", "^", .function, help: "To the power of"),
            .type("|a|", "abs(", .function, help: "Absolute value"),
            .type("7", "7", .digit), .type("8", "8", .digit), .type("9", "9", .digit),
            .type("÷", "/", .operation),
            .type("%", "%", .function, help: "Per cent"),
            .type("x", "x", .function, help: "The unknown, for equations and derivatives"),
        ],
        [
            .type("√", "√", .function, help: "Square root - √16 works without brackets"),
            .type("ⁿ√", "nthroot(", .function, help: "nth root: nthroot(3, 27)"),
            .type("π", "π", .function),
            .type("4", "4", .digit), .type("5", "5", .digit), .type("6", "6", .digit),
            .type("×", "*", .operation),
            Key(label: "←", edit: .left, tint: .operation, help: "Move the caret left"),
            Key(label: "→", edit: .right, tint: .operation, help: "Move the caret right"),
        ],
        [
            .type("sin", "sin(", .function), .type("cos", "cos(", .function),
            .type("tan", "tan(", .function),
            .type("1", "1", .digit), .type("2", "2", .digit), .type("3", "3", .digit),
            .type("−", "-", .operation),
            Key(label: "⌫", edit: .deleteBackward, tint: .operation, help: "Delete"),
            .type("=", "=", .operation, help: "Makes it an equation: x^2 - 5x + 6 = 0"),
        ],
        [
            .type("(", "(", .function), .type(")", ")", .function), .type(",", ",", .function),
            .type("0", "0", .digit), .type(".", ".", .digit),
            .type("ans", "ans", .function, help: "The last answer"),
            .type("+", "+", .operation),
            Key(label: "↵", tint: .equals, span: 2, help: "Work it out (Return)"),
        ],
    ]

    var body: some View { KeyRows(rows: Self.rows, columns: 9) }
}

/// The second pad: everything with a name. Desmos's `func` tab, plus the
/// derivative row, which Desmos has no key for.
private struct FunctionPad: View {
    private static let rows: [[Key]] = [
        [
            .type("sin", "sin(", .function), .type("cos", "cos(", .function),
            .type("tan", "tan(", .function),
            .type("aᵇ", "^", .function), .type("√", "√", .function),
            .type("ⁿ√", "nthroot(", .function, help: "nth root: nthroot(3, 27)"),
        ],
        [
            .type("sin⁻¹", "asin(", .function), .type("cos⁻¹", "acos(", .function),
            .type("tan⁻¹", "atan(", .function),
            .type("eˣ", "e^", .function), .type("abs", "abs(", .function),
            .type("round", "round(", .function),
        ],
        [
            .type("mean", "mean(", .function, help: "mean(1, 2, 3)"),
            .type("median", "median(", .function),
            .type("stdev", "stdev(", .function, help: "Sample standard deviation"),
            .type("ln", "ln(", .function), .type("log", "log(", .function, help: "log(8), or log(2, 8) for another base"),
            Key(label: "⌫", edit: .deleteBackward, tint: .operation, help: "Delete"),
        ],
        [
            .type("stdevp", "stdevp(", .function, help: "Population standard deviation"),
            .type("nPr", "npr(", .function), .type("nCr", "ncr(", .function),
            .type("!", "!", .function, help: "Factorial"),
            .type("e", "e", .function), .type("π", "π", .function),
        ],
        [
            .type("d/dx", "deriv(", .function,
                  help: "deriv(sin(x)) is cos(x); deriv(x^2, 3) is 6"),
            .type("∫", "integral(", .function,
                  help: "Between limits: integral(x^2, 0, 3) is 9"),
            .type("Σ", "sigma(", .function,
                  help: "Over whole numbers: sigma(x, 1, 100) is 5050"),
            .type("Π", "product(", .function,
                  help: "Over whole numbers: product(x, 1, 5) is 120"),
            .type("x", "x", .function, help: "The unknown, for equations and derivatives"),
            .type("=", "=", .operation, help: "Makes it an equation: x^2 - 5x + 6 = 0"),
        ],
    ]

    var body: some View { KeyRows(rows: Self.rows, columns: 6) }
}

/// Lays the rows out on a fixed column width, so a key spanning two columns is
/// exactly twice as wide and the two pads line up with each other.
private struct KeyRows: View {
    var rows: [[Key]]
    var columns: Int

    private let spacing: CGFloat = 5
    private let height: CGFloat = 38

    var body: some View {
        GeometryReader { geometry in
            let unit = (geometry.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            VStack(spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: spacing) {
                        ForEach(row) { key in
                            KeyButton(key: key)
                                .frame(width: unit * CGFloat(key.span) + spacing * CGFloat(key.span - 1))
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: CGFloat(rows.count) * height + CGFloat(rows.count - 1) * spacing)
    }
}

private struct KeyButton: View {
    var key: Key

    enum Tint { case function, digit, operation, equals }

    @State private var hovering = false

    var body: some View {
        Button(action: press) {
            Text(key.label)
                .font(.system(size: size, weight: weight, design: .rounded))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(background)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(Pressable(scale: 0.94))
        .hoverHighlight($hovering)
        .help(key.help ?? key.label)
        .accessibilityLabel(key.help ?? key.label)
    }

    private func press() {
        if key.tint == .equals {
            CalculatorPanel.shared.commit()
            return
        }
        CalculatorPanel.shared.key(key.edit)
    }

    private var size: CGFloat { key.tint == .digit ? 16 : 12 }
    private var weight: Font.Weight { key.tint == .digit ? .medium : .semibold }

    private var foreground: Color {
        switch key.tint {
        case .equals: Theme.notchBlack
        case .digit: Theme.primary
        default: Theme.secondary
        }
    }

    private var background: Color {
        switch key.tint {
        case .equals: hovering ? Theme.core.opacity(0.85) : Theme.core
        case .digit: Color.white.opacity(hovering ? 0.16 : 0.10)
        case .operation: Color.white.opacity(hovering ? 0.14 : 0.08)
        default: Color.white.opacity(hovering ? 0.12 : 0.06)
        }
    }
}
