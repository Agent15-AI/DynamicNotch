import SwiftUI

/// An expression drawn as maths, with the caret inside it.
///
/// `1/(2√(x+1))` is correct and nobody reads it; two over a bar with a root
/// across the `x+1` is read at a glance. Desmos does this, and the thing that
/// makes it an editor rather than a picture is that the insertion point lives in
/// the drawing - so that is what this does too. There is no second copy of the
/// line in a text field underneath.
///
/// How the caret finds its place: every node carries the character range it was
/// parsed from, and the editor keeps a character offset. An atom draws the bar
/// before itself when the offset is its first character, inside itself when the
/// offset falls within a number or a name, and after itself when the offset is
/// its last character and nothing else starts there. That last condition is what
/// stops `2x` drawing two carets between the 2 and the x.
///
/// It draws `Calculator.Node` - the same tree the evaluator walks - so a misread
/// line looks wrong before it answers wrong.
///
/// ponytail: SwiftUI stacks, a rule and one drawn shape. A `Layout` or a Core
/// Text run would be the general answer; a handful of shapes of expression are
/// not a general problem.
struct MathView: View {
    var node: Calculator.Node
    var size: CGFloat = 15
    var color: Color = Theme.primary
    /// Where the insertion point is, in characters of the typed line. nil for
    /// the lines that are read rather than edited.
    var caret: Int?
    /// Where the caret can be put by clicking. nil when the drawing is read-only.
    var moveCaret: ((Int) -> Void)?

    var body: some View {
        let places: (all: Set<Int>, starts: Set<Int>) =
            caret == nil ? ([], []) : Self.places(in: node)
        MathNode(
            node: node,
            size: size,
            bracketed: 0,
            caret: caret.map { Self.snap($0, to: places) },
            starts: places.starts,
            moveCaret: moveCaret
        )
        .foregroundStyle(color)
        .fixedSize()
    }

    /// The offsets the caret can be drawn at, and the subset that begins an atom.
    ///
    /// Not every character offset can be drawn: the caret can stand inside a
    /// number or a name, and beside any atom, but there is nowhere to put it in
    /// the middle of the letters of `sqrt`. An offset with no home is snapped
    /// back to the nearest one that has one, so the caret is always somewhere -
    /// invisible is the one thing an insertion point may never be.
    /// ponytail: the offsets come from `Calculator.caretStops`, which the arrow
    /// keys also step through. Two answers to "where can the caret go" is how
    /// the arrows and the drawing came to disagree in the first place.
    private static func places(in node: Calculator.Node) -> (all: Set<Int>, starts: Set<Int>) {
        (Calculator.caretStops(in: node), starts(of: node))
    }

    private static func snap(_ caret: Int, to places: (all: Set<Int>, starts: Set<Int>)) -> Int {
        if places.all.contains(caret) { return caret }
        let below = places.all.filter { $0 < caret }.max()
        return below ?? places.all.min() ?? caret
    }

    /// Every offset at which some atom begins. An offset that is both the end of
    /// one atom and the start of the next belongs to the next.
    private static func starts(of node: Calculator.Node) -> Set<Int> {
        var found: Set<Int> = []
        func walk(_ node: Calculator.Node) {
            found.insert(node.range.lowerBound)
            switch node.kind {
            case .number, .name: break
            case .negate(let inner), .factorial(let inner), .percent(let inner): walk(inner)
            case .binary(_, let left, let right): walk(left); walk(right)
            case .call(_, let arguments): arguments.forEach(walk)
            }
        }
        walk(node)
        return found
    }
}

/// One node, the precedence of what it sits inside - which decides whether it
/// needs brackets - and the caret, if it falls anywhere within.
private struct MathNode: View {
    var node: Calculator.Node
    var size: CGFloat
    var bracketed: Int
    var caret: Int?
    var starts: Set<Int>
    var moveCaret: ((Int) -> Void)?

    var body: some View {
        switch node.kind {
        case .number(let value):
            leaf(Calculator.format(value))

        case .name(let name):
            // Constants keep their symbol; a one-letter variable is the italic one.
            leaf(name == "pi" ? "π" : name == "tau" ? "τ" : name == "phi" ? "φ" : name,
                 italic: name.count == 1 && name != "e")

        case .negate(let inner):
            brackets(if: bracketed > 1) {
                HStack(spacing: size * 0.06) {
                    caretBefore
                    glyph("−")
                    child(inner, bracketed: 3)
                }
            }

        case .factorial(let inner):
            HStack(spacing: 0) {
                child(inner, bracketed: 5)
                glyph("!")
                caretAfter
            }

        case .percent(let inner):
            HStack(spacing: 0) {
                child(inner, bracketed: 5)
                glyph("%")
                caretAfter
            }

        case .binary("/", let top, let bottom):
            // A fraction needs no brackets around either half: the bar groups
            // them, which is the whole point of drawing it this way.
            Fraction(size: size) {
                child(top, bracketed: 0, size: size * 0.94)
            } denominator: {
                child(bottom, bracketed: 0, size: size * 0.94)
            }

        case .binary("^", let base, let exponent):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                child(base, bracketed: 5)
                child(exponent, bracketed: 5, size: size * 0.68)
                    // Raised by its own share of the line, so a tall exponent
                    // still clears the base it belongs to.
                    .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + size * 0.42 }
            }

        case .binary("*", let left, let right):
            brackets(if: bracketed > 2) {
                HStack(spacing: spacing(left, right)) {
                    child(left, bracketed: 2)
                    // Two numbers need a dot between them; a number and a name
                    // read better with nothing at all.
                    if needsDot(left, right) { glyph("·") }
                    child(right, bracketed: 3)
                }
            }

        case .binary("=", let left, let right):
            // An equation is never bracketed and neither are its sides: the `=`
            // is the whole line, not a term inside one.
            HStack(spacing: size * 0.3) {
                child(left, bracketed: 0)
                glyph("=")
                child(right, bracketed: 0)
            }

        case .binary(let op, let left, let right):
            brackets(if: bracketed > 1) {
                HStack(spacing: size * 0.22) {
                    child(left, bracketed: 1)
                    glyph(op == "-" ? "−" : String(op))
                    child(right, bracketed: 2)
                }
            }

        case .call("sqrt", let arguments) where arguments.count == 1:
            HStack(spacing: 0) {
                caretBefore
                Radical(size: size) { child(arguments[0], bracketed: 0) }
                caretAfter
            }

        case .call("nthroot", let arguments) where arguments.count == 2:
            HStack(spacing: 0) {
                caretBefore
                Radical(size: size,
                        index: AnyView(child(arguments[0], bracketed: 0, size: size * 0.6))) {
                    child(arguments[1], bracketed: 0)
                }
                caretAfter
            }

        case .call("abs", let arguments) where arguments.count == 1:
            HStack(spacing: size * 0.08) {
                caretBefore
                Bar(size: size)
                child(arguments[0], bracketed: 0)
                Bar(size: size)
                caretAfter
            }

        case .call("deriv", let arguments), .call("ddx", let arguments):
            // The notation everybody was taught, rather than the spelling the
            // parser wants: d/dx in front of it, and a bar with the point on it
            // when there is one.
            HStack(alignment: .firstTextBaseline, spacing: size * 0.12) {
                caretBefore
                Fraction(size: size * 0.85) {
                    Text("d").font(.system(size: size * 0.85, design: .serif)).italic()
                } denominator: {
                    Text("dx").font(.system(size: size * 0.85, design: .serif)).italic()
                }
                if let first = arguments.first { child(first, bracketed: 3) }
                if arguments.count == 2 {
                    Bar(size: size * 1.2)
                    HStack(spacing: size * 0.06) {
                        Text("x =").font(.system(size: size * 0.62, design: .serif))
                        child(arguments[1], bracketed: 0, size: size * 0.62)
                    }
                    .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] - size * 0.22 }
                }
                caretAfter
            }

        case .call("integral", let arguments) where arguments.count == 3:
            // ∫ with its limits on the sign and a dx at the end, which is how it
            // is written everywhere outside a programming language.
            HStack(alignment: .firstTextBaseline, spacing: size * 0.1) {
                caretBefore
                Integral(size: size,
                         lower: AnyView(child(arguments[1], bracketed: 0, size: size * 0.6)),
                         upper: AnyView(child(arguments[2], bracketed: 0, size: size * 0.6)))
                child(arguments[0], bracketed: 2)
                Text("dx").font(.system(size: size * 0.85, design: .serif)).italic()
                caretAfter
            }

        case .call(let name, let arguments) where (name == "sigma" || name == "product")
            && arguments.count == 3:
            HStack(alignment: .firstTextBaseline, spacing: size * 0.1) {
                caretBefore
                BigOperator(symbol: name == "sigma" ? "∑" : "∏",
                            size: size,
                            lower: AnyView(HStack(spacing: size * 0.04) {
                                Text("x=").font(.system(size: size * 0.55, design: .serif))
                                child(arguments[1], bracketed: 0, size: size * 0.55)
                            }),
                            upper: AnyView(child(arguments[2], bracketed: 0, size: size * 0.55)))
                child(arguments[0], bracketed: 2)
                caretAfter
            }

        case .call(let name, let arguments):
            HStack(spacing: size * 0.08) {
                caretBefore
                // Function names stand upright; a variable is the italic one.
                glyph(name)
                Bracket(size: size, open: true)
                ForEach(Array(arguments.enumerated()), id: \.offset) { index, argument in
                    if index > 0 { glyph(",").padding(.trailing, size * 0.12) }
                    child(argument, bracketed: 0)
                }
                Bracket(size: size, open: false)
                caretAfter
            }
        }
    }

    // MARK: Pieces

    private func child(_ node: Calculator.Node, bracketed: Int, size: CGFloat? = nil) -> MathNode {
        MathNode(node: node, size: size ?? self.size, bracketed: bracketed,
                 caret: caret, starts: starts, moveCaret: moveCaret)
    }

    private func glyph(_ text: String) -> some View {
        Text(text).font(.system(size: size, design: .serif))
    }

    /// A number or a name: the only places the caret can stand *inside* a piece
    /// of the drawing rather than beside it.
    ///
    /// A click lands at the nearest gap between characters, so clicking between
    /// the 2 and the 5 of `25` puts the caret between them rather than at the
    /// front of the number.
    ///
    /// The glyph widths come from the font itself rather than from a
    /// `GeometryReader`. Measuring the drawn view is a frame late, and a click
    /// that arrived before the measurement had nothing to divide by - which is
    /// exactly the click somebody makes first.
    @ViewBuilder
    private func leaf(_ text: String, italic: Bool = false) -> some View {
        let inside = caret.map { $0 > node.range.lowerBound && $0 < node.range.upperBound }
            ?? false
        HStack(spacing: 0) {
            caretBefore
            if inside, let caret {
                let split = min(max(caret - node.range.lowerBound, 0), text.count)
                Text(String(text.prefix(split)))
                    .font(.system(size: size, design: .serif)).italic(italic)
                Caret(size: size)
                Text(String(text.dropFirst(split)))
                    .font(.system(size: size, design: .serif)).italic(italic)
            } else {
                Text(text).font(.system(size: size, design: .serif)).italic(italic)
            }
            caretAfter
        }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            moveCaret?(boundary(nearest: location.x, in: text, italic: italic))
        }
    }

    /// The gap between characters nearest a click, as a character offset.
    private func boundary(nearest x: CGFloat, in text: String, italic: Bool) -> Int {
        let widths = Self.widths(of: text, size: size, italic: italic)
        // The caret bar itself sits in the row when it is inside this atom, and
        // the click is measured from the left edge of everything.
        var travelled: CGFloat = caret == node.range.lowerBound ? Caret.width(for: size) : 0
        for (index, width) in widths.enumerated() {
            if x < travelled + width / 2 { return node.range.lowerBound + index }
            travelled += width
        }
        return node.range.upperBound
    }

    /// One glyph at a time, from the font the drawing uses.
    private static func widths(of text: String, size: CGFloat, italic: Bool) -> [CGFloat] {
        var descriptor = NSFont.systemFont(ofSize: size).fontDescriptor
            .withDesign(.serif) ?? NSFont.systemFont(ofSize: size).fontDescriptor
        if italic {
            descriptor = descriptor.withSymbolicTraits(.italic)
        }
        let font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        return text.map { String($0).size(withAttributes: [.font: font]).width }
    }

    @ViewBuilder
    private var caretBefore: some View {
        if caret == node.range.lowerBound { Caret(size: size) }
    }

    /// Only when nothing else begins here - otherwise the offset between `2` and
    /// `x` would draw a bar on each side of itself - and only at the innermost
    /// node that ends here.
    ///
    /// Nested nodes routinely share an end offset. While a line is being typed
    /// it is normal for several to: `ddx(sin(x` parses leniently, and then `x`,
    /// `sin(…)` and `ddx(…)` all end at offset 9, so each drew its own bar and
    /// the line showed three carets stacked against each other. A node yields
    /// to any child of its own that ends where it does, which leaves exactly
    /// the deepest one drawing.
    @ViewBuilder
    private var caretAfter: some View {
        if let caret, caret == node.range.upperBound, !starts.contains(caret),
           !Self.children(of: node).contains(where: { $0.range.upperBound == caret }) {
            Caret(size: size)
        }
    }

    /// A node's immediate children. Only used to settle who owns a caret at a
    /// shared offset.
    private static func children(of node: Calculator.Node) -> [Calculator.Node] {
        switch node.kind {
        case .number, .name: []
        case .negate(let inner), .factorial(let inner), .percent(let inner): [inner]
        case .binary(_, let left, let right): [left, right]
        case .call(_, let arguments): arguments
        }
    }

    /// Juxtaposition is tighter than an operator, which is what makes `2x` read
    /// as one thing and `2 + x` as three.
    private func spacing(_ left: Calculator.Node, _ right: Calculator.Node) -> CGFloat {
        needsDot(left, right) ? size * 0.14 : size * 0.06
    }

    private func needsDot(_ left: Calculator.Node, _ right: Calculator.Node) -> Bool {
        if case .number = left.kind, case .number = right.kind { return true }
        if case .number = right.kind { return true }
        return false
    }

    @ViewBuilder
    private func brackets(if needed: Bool, @ViewBuilder content: () -> some View) -> some View {
        if needed {
            HStack(spacing: size * 0.04) {
                Bracket(size: size, open: true)
                content()
                Bracket(size: size, open: false)
            }
        } else {
            content()
        }
    }
}

/// The insertion point, blinking the way every other one on the Mac does.
///
/// Shared with the raw-text line, which needs the same bar when the expression
/// cannot be drawn as maths.
///
/// A `TimelineView` rather than a repeating animation: it stops dead when the
/// window closes, and there is no animation left running behind a shut panel.
struct Caret: View {
    var size: CGFloat

    /// The room the bar takes in a row, which a click has to allow for.
    static func width(for size: CGFloat) -> CGFloat { max(1.5, size * 0.07) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
            Rectangle()
                .fill(Theme.core)
                .frame(width: max(1.5, size * 0.07), height: size * 1.25)
                .opacity(on ? 1 : 0.15)
        }
        .frame(width: max(1.5, size * 0.07))
    }
}

/// Numerator over denominator, with the rule between them as wide as the wider
/// of the two.
private struct Fraction<Top: View, Bottom: View>: View {
    var size: CGFloat
    @ViewBuilder var numerator: () -> Top
    @ViewBuilder var denominator: () -> Bottom

    var body: some View {
        VStack(spacing: size * 0.12) {
            // Both halves take the size they want. Left to negotiate, a stack
            // offers each child the width of the widest one - so `1` over `2√x`
            // proposed the numerator's width to the denominator, and the root
            // drew with nothing under it.
            numerator().fixedSize()
            Rectangle()
                .frame(height: max(1, size * 0.055))
            denominator().fixedSize()
        }
        .padding(.horizontal, size * 0.16)
        // The middle of the bar sits where the rest of the line's text sits,
        // rather than the whole fraction hanging off the baseline.
        .alignmentGuide(.firstTextBaseline) { $0.height / 2 + size * 0.28 }
    }
}

/// A root sign drawn to fit what is under it.
///
/// Drawn rather than typeset: the `√` character is a fixed shape, so stretching
/// it to cover a fraction leaves the arm of the glyph and the bar over the
/// content in different places, joined by nothing. A path has no such problem -
/// the tick, the diagonal and the bar are one stroke, whatever is underneath.
private struct Radical<Content: View>: View {
    var size: CGFloat
    var index: AnyView?
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .fixedSize()
            .padding(.leading, size * 0.65)
            .padding(.trailing, size * 0.12)
            .padding(.top, size * 0.22)
            .padding(.bottom, size * 0.04)
            .overlay {
                Surd(armWidth: size * 0.55, stroke: max(1, size * 0.06))
                    .stroke(style: StrokeStyle(lineWidth: max(1, size * 0.06),
                                               lineCap: .round, lineJoin: .round))
            }
            .overlay(alignment: .topLeading) {
                // The little number on a cube root sits in the crook of the sign.
                if let index { index.offset(x: size * 0.02, y: -size * 0.1) }
            }
    }
}

/// The root sign itself: down into the tick, along the diagonal, then the bar
/// across everything it covers.
private struct Surd: Shape {
    var armWidth: CGFloat
    var stroke: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.minY + stroke / 2
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + armWidth * 0.3, y: rect.minY + rect.height * 0.5))
        path.addLine(to: CGPoint(x: rect.minX + armWidth * 0.62, y: rect.maxY - stroke))
        path.addLine(to: CGPoint(x: rect.minX + armWidth, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        return path
    }
}

/// An integral sign with its limits, as a textbook writes it.
private struct Integral: View {
    var size: CGFloat
    var lower: AnyView
    var upper: AnyView

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.02) {
            Text("∫")
                .font(.system(size: size * 1.9, design: .serif))
            VStack(alignment: .leading, spacing: size * 0.55) {
                upper
                lower
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0.height * 0.62 }
    }
}

/// A sum or a product sign with what it runs over, above and below.
private struct BigOperator: View {
    var symbol: String
    var size: CGFloat
    var lower: AnyView
    var upper: AnyView

    var body: some View {
        VStack(spacing: size * 0.02) {
            upper
            Text(symbol).font(.system(size: size * 1.5))
            lower
        }
        .alignmentGuide(.firstTextBaseline) { $0.height * 0.62 }
    }
}

/// A bracket that grows with what it holds.
private struct Bracket: View {
    var size: CGFloat
    var open: Bool

    var body: some View {
        Text(open ? "(" : ")").font(.system(size: size, design: .serif))
    }
}

/// The upright bar of an absolute value, and the one a derivative is evaluated
/// against.
private struct Bar: View {
    var size: CGFloat

    var body: some View {
        Rectangle().frame(width: max(1, size * 0.055), height: size * 1.1)
    }
}
