import Foundation

/// A scientific calculator: tokeniser, Pratt parser, evaluator, symbolic
/// differentiation and a solver.
///
/// `NSExpression` was here first and is not enough. It has no constants, no
/// trigonometry worth using, no factorial, integer division that surprises
/// people, and a function syntax nobody types. Foundation offers nothing closer,
/// and this project takes no dependencies.
///
/// The parser builds a tree rather than a number, which is what makes the last
/// two features possible: you cannot differentiate a `Double`, and you cannot
/// look for the roots of one either. Plain sums still come out the far side as a
/// number, so nothing that only wants arithmetic pays for the rest.
///
/// Pure and `nonisolated`: no state, no I/O, so it is trivially testable and safe
/// to call from anywhere.
enum Calculator {
    // MARK: - What a line can come out as

    enum Answer: Equatable {
        /// An ordinary sum.
        case number(Double)
        /// A derivative, printed back as maths: `deriv(sin(x))` is `cos(x)`.
        case expression(String)
        /// The solutions of an equation, in order, and whether there were more
        /// than the list holds.
        case roots([Double], truncated: Bool)
    }

    /// The whole answer to a line, whatever kind it turns out to be.
    static func answer(_ text: String, degrees: Bool, previous: Double?) -> Answer? {
        guard let scanned = tokenise(text), !scanned.tokens.isEmpty else { return nil }
        let (tokens, ranges) = scanned

        // An `=` at the top level makes it an equation rather than a sum.
        if let split = topLevelEquals(in: tokens) {
            let leftTokens = Array(tokens[..<split])
            let rightTokens = Array(tokens[(split + 1)...])
            guard !leftTokens.isEmpty, !rightTokens.isEmpty,
                  let left = parse(leftTokens, Array(ranges[..<split])),
                  let right = parse(rightTokens, Array(ranges[(split + 1)...]))
            else { return nil }
            guard let found = solve(.binary("-", left, right), degrees: degrees, previous: previous)
            else { return nil }
            return .roots(found.roots, truncated: found.truncated)
        }

        guard let tree = parse(tokens, ranges) else { return nil }

        // A derivative written at a point is a number; one written in x stays a
        // function.
        if case .call(let name, let arguments) = tree.kind, name == "deriv" || name == "ddx",
           arguments.count == 1 {
            if let value = derivativeAtPoint(arguments[0], degrees: degrees, previous: previous) {
                return .number(value)
            }
            guard let slope = derivative(of: arguments[0], by: "x", degrees: degrees) else { return nil }
            let tidied = simplify(slope)
            // `deriv(5)` is 0, and 0 is a number rather than a formula.
            if case .number(let value) = tidied.kind { return .number(value) }
            return .expression(describe(tidied))
        }

        guard let value = value(of: tree, degrees: degrees, variables: [:], previous: previous),
              value.isFinite
        else { return nil }
        return .number(value)
    }

    /// Returns nil for anything that is not a complete, valid expression, which
    /// is what a half-typed line always is.
    ///
    /// Kept for the callers that only want a number - the command bar's sums.
    static func evaluate(_ text: String, degrees: Bool, answer: Double?) -> Double? {
        guard case .number(let value)? = Self.answer(text, degrees: degrees, previous: answer) else {
            return nil
        }
        return value
    }

    /// Trimmed to something a human reads: integers stay integers, everything
    /// else keeps ten significant digits with trailing zeros removed.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.10g", value)
        if text.contains("."), !text.contains("e") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// One line of answer, however it turned out.
    static func text(of answer: Answer) -> String {
        switch answer {
        case .number(let value):
            return format(value)
        case .expression(let text):
            return text
        case .roots(let roots, let truncated):
            guard !roots.isEmpty else { return "no real solution" }
            let list = roots.map(format).joined(separator: roots.count > 2 ? ", " : " or ")
            // A periodic equation has as many roots as you care to look for, so
            // the list says when it has been cut short.
            return "x = " + list + (truncated ? " …" : "")
        }
    }

    // MARK: - Tokens

    private enum Token: Equatable {
        case number(Double)
        case name(String)
        case symbol(Character)
    }

    /// The only names with a digit in them. Everything else that looks like
    /// `letters digits` is a function applied to a number.
    private static let digitNames: Set<String> = ["log2", "atan2"]

    /// Tokens, and the characters each one came from.
    ///
    /// Offsets rather than `String.Index`: the caret is a character count, the
    /// ranges have to match it, and a calculator line is never long enough for
    /// the difference to cost anything.
    private static func tokenise(_ text: String) -> (tokens: [Token], ranges: [Range<Int>])? {
        let characters = Array(text)
        var tokens: [Token] = []
        var ranges: [Range<Int>] = []
        var index = 0

        func take(_ token: Token, from start: Int, to end: Int) {
            tokens.append(token)
            ranges.append(start ..< end)
        }

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                index += 1
                continue
            }

            if character.isNumber || character == "." {
                let start = index
                var literal = ""
                while index < characters.count, characters[index].isNumber || characters[index] == "." {
                    literal.append(characters[index])
                    index += 1
                }
                // Scientific notation, but only when the exponent really follows:
                // "2e" alone is an unfinished number, and "2 e" is 2 × e.
                if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                    let after = index + 1
                    if after < characters.count,
                       characters[after].isNumber || ((characters[after] == "-" || characters[after] == "+")
                           && after + 1 < characters.count && characters[after + 1].isNumber) {
                        literal.append("e")
                        index = after
                        if characters[index] == "-" || characters[index] == "+" {
                            literal.append(characters[index])
                            index += 1
                        }
                        while index < characters.count, characters[index].isNumber {
                            literal.append(characters[index])
                            index += 1
                        }
                    }
                }
                guard let value = Double(literal) else { return nil }
                take(.number(value), from: start, to: index)
                continue
            }

            // Before the name branch, because π *is* a letter to Unicode: left
            // after it, "π" tokenised as an unknown name and every sum with the
            // typed symbol in it returned nothing.
            if let named = Self.symbolNames[character] {
                take(.name(named), from: index, to: index + 1)
                index += 1
                continue
            }
            if let operatorCharacter = Self.symbolOperators[character] {
                take(.symbol(operatorCharacter), from: index, to: index + 1)
                index += 1
                continue
            }

            if character.isLetter {
                let start = index
                var name = ""
                while index < characters.count, characters[index].isLetter {
                    name.append(characters[index])
                    index += 1
                }
                // Digits belong to the name only for the two names that have one.
                // Absorbing every digit that followed turned `sin90` into a name
                // nothing knows, when it plainly means sin(90).
                if index < characters.count, characters[index].isNumber {
                    var digits = ""
                    var ahead = index
                    while ahead < characters.count, characters[ahead].isNumber {
                        digits.append(characters[ahead])
                        ahead += 1
                    }
                    if Self.digitNames.contains((name + digits).lowercased()) {
                        name += digits
                        index = ahead
                    }
                }
                let lowered = name.lowercased()
                if Self.functionNames.contains(lowered) || Self.constantNames.contains(lowered)
                    || lowered.count == 1 {
                    take(.name(lowered), from: start, to: index)
                } else {
                    // `sinx` is `sin x`. Each piece carries the range of the
                    // letters it came from, so the caret and the error
                    // underline still point at the right characters.
                    var offset = start
                    for part in Self.split(name: lowered) {
                        take(.name(part), from: offset, to: offset + part.count)
                        offset += part.count
                    }
                }
                continue
            }

            guard "+-*/^%!(),=".contains(character) else { return nil }
            take(.symbol(character), from: index, to: index + 1)
            index += 1
        }
        return balanced(tokens, ranges, end: characters.count)
    }

    /// Forgives brackets that are not closed, and drops ones that close nothing.
    ///
    /// The keypad opens a bracket for you and never closes it - `sin` types
    /// `sin(`, `d/dx` types `deriv(` - so pressing `d/dx`, `sin`, `x`, `)`
    /// leaves `deriv(sin(x)`, one short, and the line would not read at all.
    /// That is why `deriv(sinx)` failed while `derivsinx` worked: the second
    /// needs no brackets and so could not get them wrong. Typing has the same
    /// problem from the other side - `sin(x` is what a line looks like for
    /// every keystroke until the closer arrives, and a calculator that shows
    /// nothing until then is blank for most of the time anyone spends using it.
    ///
    /// The forgiven closers carry a zero-width range at the end of the line, so
    /// no node ever claims characters that were never typed and the caret stops
    /// stay inside the text.
    ///
    /// ponytail: done here rather than by retrying the parse with `)` glued on.
    /// Rewriting the string would put every range out by however many brackets
    /// were added, and the ranges are what the caret and the click targets are
    /// built from.
    private static func balanced(
        _ tokens: [Token], _ ranges: [Range<Int>], end: Int
    ) -> (tokens: [Token], ranges: [Range<Int>]) {
        var kept: [Token] = []
        var keptRanges: [Range<Int>] = []
        var open = 0
        for (token, range) in zip(tokens, ranges) {
            if token == .symbol("(") {
                open += 1
            } else if token == .symbol(")") {
                // A closer with nothing to close is a stray keystroke, not a
                // reason to refuse the whole line.
                guard open > 0 else { continue }
                open -= 1
            }
            kept.append(token)
            keptRanges.append(range)
        }
        for _ in 0 ..< open {
            kept.append(.symbol(")"))
            keptRanges.append(end ..< end)
        }
        return (kept, keptRanges)
    }

    /// Symbols that stand for a name.
    private static let symbolNames: [Character: String] = [
        "π": "pi", "τ": "tau", "φ": "phi", "√": "sqrt", "∛": "cbrt",
        "∫": "integral", "∑": "sigma", "∏": "product",
    ]

    /// Symbols that stand for an operator.
    private static let symbolOperators: [Character: Character] = [
        "×": "*", "÷": "/", "−": "-",
    ]

    /// Where the `=` is, when there is one outside every bracket.
    private static func topLevelEquals(in tokens: [Token]) -> Int? {
        var depth = 0
        for (index, token) in tokens.enumerated() {
            if token == .symbol("(") { depth += 1 }
            if token == .symbol(")") { depth -= 1 }
            if token == .symbol("="), depth == 0 { return index }
        }
        return nil
    }

    // MARK: - The tree

    /// What a line means, before anything is worked out - and where in the typed
    /// line it came from.
    ///
    /// The range is what lets the caret live inside the drawn maths rather than
    /// in a text field underneath it: the editor keeps a character offset, and
    /// every atom on screen knows which offsets it covers.
    ///
    /// Two nodes are the same when they *mean* the same, whatever they were
    /// typed from. Without that, `simplify` could not compare a subtree against
    /// `.number(0)`, because the zero it builds came from nowhere.
    struct Node: Equatable {
        indirect enum Kind: Equatable {
            case number(Double)
            /// A constant (`pi`), the previous answer (`ans`), or a variable (`x`).
            case name(String)
            case negate(Node)
            case binary(Character, Node, Node)
            case call(String, [Node])
            case factorial(Node)
            /// Trailing `%`, which divides by a hundred.
            case percent(Node)
        }

        var kind: Kind
        /// Character offsets in the line this was parsed from. Empty for the
        /// nodes a derivative invents, which were never typed.
        var range: Range<Int> = 0 ..< 0

        static func == (left: Node, right: Node) -> Bool { left.kind == right.kind }

        // Built like the enum cases they replace, so everything that makes a tree
        // reads the same as it did.
        static func number(_ value: Double, _ range: Range<Int> = 0 ..< 0) -> Node {
            Node(kind: .number(value), range: range)
        }

        static func name(_ name: String, _ range: Range<Int> = 0 ..< 0) -> Node {
            Node(kind: .name(name), range: range)
        }

        static func negate(_ inner: Node, _ range: Range<Int>? = nil) -> Node {
            Node(kind: .negate(inner), range: range ?? inner.range)
        }

        static func binary(_ op: Character, _ left: Node, _ right: Node,
                           _ range: Range<Int>? = nil) -> Node {
            Node(kind: .binary(op, left, right), range: range ?? span(left.range, right.range))
        }

        static func call(_ name: String, _ arguments: [Node],
                         _ range: Range<Int>? = nil) -> Node {
            Node(kind: .call(name, arguments),
                 range: range ?? arguments.map(\.range).reduce(0 ..< 0, span))
        }

        static func factorial(_ inner: Node, _ range: Range<Int>? = nil) -> Node {
            Node(kind: .factorial(inner), range: range ?? inner.range)
        }

        static func percent(_ inner: Node, _ range: Range<Int>? = nil) -> Node {
            Node(kind: .percent(inner), range: range ?? inner.range)
        }

        /// The two ranges and everything between them, ignoring the empty ones a
        /// synthetic node carries.
        static func span(_ left: Range<Int>, _ right: Range<Int>) -> Range<Int> {
            if left.isEmpty { return right }
            if right.isEmpty { return left }
            return min(left.lowerBound, right.lowerBound) ..< max(left.upperBound, right.upperBound)
        }
    }

    /// The tree behind a line, for drawing it as maths rather than as text.
    ///
    /// Forgiving in the one way that matters while someone is typing: a line with
    /// brackets still open is closed for it, so `1/(2√(x+1` draws as a fraction
    /// rather than flickering back to plain text on every open bracket. Whether
    /// the line is *finished* is a separate question, and the answer beside it
    /// already tells you.
    static func tree(of text: String) -> Node? {
        guard let scanned = tokenise(text), !scanned.tokens.isEmpty else { return nil }

        // An equation draws whole, both sides of the `=` included. Drawing only
        // the left of it showed `2x - 5` for a line that was typed as
        // `2x - 5 = 4` - the right-hand side was neither visible nor reachable by
        // the caret, which made it impossible to correct.
        if let split = topLevelEquals(in: scanned.tokens) {
            let leftTokens = Array(scanned.tokens[..<split])
            let leftRanges = Array(scanned.ranges[..<split])
            let rightTokens = Array(scanned.tokens[(split + 1)...])
            let rightRanges = Array(scanned.ranges[(split + 1)...])
            guard let left = forgiving(leftTokens, leftRanges) else { return nil }
            let end = scanned.ranges[split].upperBound
            // Nothing typed after the `=` yet: an empty name draws as nothing and
            // gives the caret somewhere to stand.
            let right = rightTokens.isEmpty
                ? Node.name("", end ..< end)
                : forgiving(rightTokens, rightRanges)
            guard let right else { return nil }
            let whole = 0 ..< (scanned.ranges.last?.upperBound ?? text.count)
            return .binary("=", left, right, whole)
        }
        return forgiving(scanned.tokens, scanned.ranges)
    }

    /// Parses for drawing, closing the brackets that have not been typed yet.
    ///
    /// Forgiving in the one way that matters while someone is typing: `1/(2√(x+1`
    /// draws as a fraction rather than flickering back to plain text on every
    /// open bracket. Whether the line is *finished* is a separate question, and
    /// the answer beside it already tells you.
    private static func forgiving(_ tokens: [Token], _ ranges: [Range<Int>]) -> Node? {
        guard !tokens.isEmpty else { return nil }
        let end = ranges.last?.upperBound ?? 0
        for missing in 0 ... 4 {
            let closed = tokens + Array(repeating: Token.symbol(")"), count: missing)
            let closedRanges = ranges + Array(repeating: end ..< end, count: missing)
            if let tree = parse(closed, closedRanges) { return tree }
        }
        return nil
    }

    private static func parse(_ tokens: [Token], _ ranges: [Range<Int>]) -> Node? {
        var parser = Parser(tokens: tokens, ranges: ranges)
        guard let tree = parser.expression(minimum: 0), parser.finished else { return nil }
        return tree
    }

    private struct Parser {
        let tokens: [Token]
        /// Where each token came from, for the caret. Parallel to `tokens`.
        let ranges: [Range<Int>]
        var position = 0

        /// The characters covered by the tokens from `start` up to where the
        /// parser has reached.
        func span(from start: Int) -> Range<Int> {
            guard start < position, start < ranges.count else { return 0 ..< 0 }
            let last = min(position, ranges.count) - 1
            guard last >= start else { return 0 ..< 0 }
            return ranges[start].lowerBound ..< ranges[last].upperBound
        }

        var finished: Bool { position == tokens.count }

        private var current: Token? { position < tokens.count ? tokens[position] : nil }

        /// Precedence climbing. `^` binds tightest and is right-associative;
        /// implicit multiplication binds like an explicit `*`.
        mutating func expression(minimum: Int) -> Node? {
            let start = position
            guard var left = unary() else { return nil }

            while let token = current {
                var op: Character?
                var precedence = 0
                var rightAssociative = false

                switch token {
                case .symbol("+"): op = "+"; precedence = 1
                case .symbol("-"): op = "-"; precedence = 1
                case .symbol("*"): op = "*"; precedence = 2
                case .symbol("/"): op = "/"; precedence = 2
                case .symbol("^"): op = "^"; precedence = 4; rightAssociative = true
                // Implicit multiplication: 2pi, 3(4), 2sin(0).
                case .number, .name, .symbol("("): op = "*"; precedence = 2
                default: op = nil
                }

                guard let op, precedence >= minimum else { break }
                // Only step over a real operator; an implicit one has no token.
                if case .symbol = token, op != "*" || token == .symbol("*") {
                    position += 1
                }

                guard let right = expression(minimum: rightAssociative ? precedence : precedence + 1)
                else { return nil }
                left = .binary(op, left, right, span(from: start))
            }
            return left
        }

        private mutating func unary() -> Node? {
            let start = position
            if current == .symbol("-") {
                position += 1
                // Parsed at `^`'s precedence, so -3^2 is -(3^2) and not (-3)^2.
                // Every maths convention reads it that way; recursing into
                // `unary()` instead gave 9.
                guard let value = expression(minimum: 4) else { return nil }
                return .negate(value, span(from: start))
            }
            if current == .symbol("+") {
                position += 1
                return unary()
            }
            guard let value = primary() else { return nil }
            return postfix(value)
        }

        /// `!` and `%` bind after the value they follow.
        private mutating func postfix(_ node: Node) -> Node? {
            var result = node
            while let token = current {
                if token == .symbol("!") {
                    position += 1
                    result = .factorial(result, Node.span(result.range, lastRange))
                } else if token == .symbol("%") {
                    position += 1
                    result = .percent(result, Node.span(result.range, lastRange))
                } else {
                    break
                }
            }
            return result
        }

        /// One value with its postfixes, for a function written without brackets.
        private mutating func primaryWithPostfix() -> Node? {
            guard let value = primary() else { return nil }
            return postfix(value)
        }

        /// The range of the token just consumed.
        private var lastRange: Range<Int> {
            position > 0 && position <= ranges.count ? ranges[position - 1] : 0 ..< 0
        }

        private mutating func primary() -> Node? {
            let start = position
            switch current {
            case .number(let value):
                position += 1
                return .number(value, lastRange)

            case .symbol("("):
                position += 1
                guard var value = expression(minimum: 0), current == .symbol(")") else { return nil }
                position += 1
                // The brackets belong to what they hold, so a caret just inside
                // one has somewhere to stand.
                value.range = span(from: start)
                return value

            case .name(let name):
                position += 1
                let nameRange = lastRange
                guard current == .symbol("(") else {
                    // A name on its own is a constant or a variable - unless it is
                    // a function, in which case it takes whatever comes next, so
                    // √16 is 4 and sin90 is sin(90). That is what the key on a
                    // calculator does.
                    guard Calculator.isFunction(name) else { return .name(name, nameRange) }
                    guard let argument = primaryWithPostfix() else { return nil }
                    return .call(name, [argument], span(from: start))
                }
                position += 1
                var arguments: [Node] = []
                if current != .symbol(")") {
                    repeat {
                        guard let value = expression(minimum: 0) else { return nil }
                        arguments.append(value)
                        if current == .symbol(",") { position += 1 } else { break }
                    } while true
                }
                guard current == .symbol(")") else { return nil }
                position += 1
                return .call(name, arguments, span(from: start))

            default:
                return nil
            }
        }
    }

    // MARK: - Working it out

    private static func value(
        of node: Node, degrees: Bool, variables: [String: Double], previous: Double?
    ) -> Double? {
        func recurse(_ node: Node) -> Double? {
            value(of: node, degrees: degrees, variables: variables, previous: previous)
        }

        switch node.kind {
        case .number(let value):
            return value

        case .name(let name):
            if let bound = variables[name] { return bound }
            return constant(name, answer: previous)

        case .negate(let inner):
            return recurse(inner).map { -$0 }

        case .binary(let op, let left, let right):
            guard let a = recurse(left), let b = recurse(right) else { return nil }
            switch op {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            case "/": return b == 0 ? nil : a / b
            case "^": return pow(a, b)
            default: return nil
            }

        case .factorial(let inner):
            guard let value = recurse(inner) else { return nil }
            return factorial(value)

        case .percent(let inner):
            return recurse(inner).map { $0 / 100 }

        case .call(let name, let arguments):
            // The derivative is the one call whose first argument is a function
            // rather than a number: it is differentiated, then worked out at the
            // point given.
            if name == "deriv" || name == "ddx" {
                // Written with no point, the derivative is a function of x like
                // any other - so `deriv(x^2) = 6` is an equation worth solving.
                if arguments.count == 1 {
                    if let point = derivativeAtPoint(arguments[0], degrees: degrees,
                                                     previous: previous) {
                        return point
                    }
                    guard let slope = derivative(of: arguments[0], by: "x", degrees: degrees)
                    else { return nil }
                    return value(of: simplify(slope), degrees: degrees,
                                 variables: variables, previous: previous)
                }
                guard arguments.count == 2,
                      let point = recurse(arguments[1])
                else { return nil }
                if let slope = derivative(of: arguments[0], by: "x", degrees: degrees) {
                    var bound = variables
                    bound["x"] = point
                    if let exact = value(of: simplify(slope), degrees: degrees,
                                         variables: bound, previous: previous), exact.isFinite {
                        return exact
                    }
                }
                // Anything the rules do not cover - a factorial, say - still has a
                // slope, and five points around it are a good enough answer.
                return numericDerivative(of: arguments[0], at: point, degrees: degrees,
                                         variables: variables, previous: previous)
            }
            // The forms that run over x: an integral between limits, and a sum
            // or a product over whole numbers. Like the derivative, their first
            // argument is a function rather than a value, so it is held as a tree
            // and worked out many times.
            if name == "integral", arguments.count == 3 {
                guard let from = recurse(arguments[1]), let to = recurse(arguments[2]) else { return nil }
                return integrate(arguments[0], from: from, to: to,
                                 degrees: degrees, variables: variables, previous: previous)
            }
            if name == "sigma" || name == "product", arguments.count == 3 {
                guard let from = recurse(arguments[1]), let to = recurse(arguments[2]),
                      from == from.rounded(), to == to.rounded(), to >= from, to - from <= 100_000
                else { return nil }
                var total = name == "sigma" ? 0.0 : 1.0
                var step = from
                while step <= to {
                    var bound = variables
                    bound["x"] = step
                    guard let term = value(of: arguments[0], degrees: degrees,
                                           variables: bound, previous: previous)
                    else { return nil }
                    if name == "sigma" { total += term } else { total *= term }
                    step += 1
                }
                return total
            }

            var values: [Double] = []
            for argument in arguments {
                guard let value = recurse(argument) else { return nil }
                values.append(value)
            }
            return apply(name, values, degrees: degrees)
        }
    }

    /// `deriv(sin(0))` is 1: the slope of sin where its argument says, not the
    /// slope of the number `sin(0)` - which is zero, and is never what anybody
    /// means by writing that.
    ///
    /// Only for a function of one argument with no `x` in it. `deriv(sin(x))`
    /// still comes back as `cos(x)`, and `deriv(5)` is still 0, because neither
    /// of those is a function written at a point.
    static func derivativeAtPoint(_ argument: Node, degrees: Bool, previous: Double?) -> Double? {
        guard isFree(argument, of: "x"),
              case .call(let name, let inner) = argument.kind, inner.count == 1,
              let point = value(of: inner[0], degrees: degrees, variables: [:], previous: previous),
              let slope = derivative(of: .call(name, [.name("x")]), by: "x", degrees: degrees)
        else { return nil }
        return value(of: simplify(slope), degrees: degrees,
                     variables: ["x": point], previous: previous)
    }

    /// A definite integral, by Simpson's rule on a fine enough mesh.
    ///
    /// ponytail: Simpson rather than an adaptive scheme. A thousand panels is
    /// exact for anything polynomial up to a cubic and close enough everywhere
    /// else that the tenth digit is the only one in doubt - and it costs a
    /// millisecond, which is what a calculator that answers as you type can
    /// afford.
    private static func integrate(
        _ body: Node, from: Double, to: Double, degrees: Bool,
        variables: [String: Double], previous: Double?
    ) -> Double? {
        guard from.isFinite, to.isFinite else { return nil }
        if from == to { return 0 }
        let flipped = to < from
        let (low, high) = flipped ? (to, from) : (from, to)

        let panels = 1000
        let width = (high - low) / Double(panels)
        func f(_ x: Double) -> Double? {
            var bound = variables
            bound["x"] = x
            return value(of: body, degrees: degrees, variables: bound, previous: previous)
        }
        guard let start = f(low), let end = f(high) else { return nil }
        var total = start + end
        for step in 1 ..< panels {
            guard let sample = f(low + Double(step) * width) else { return nil }
            total += sample * (step.isMultiple(of: 2) ? 2 : 4)
        }
        let area = total * width / 3
        guard area.isFinite else { return nil }
        let tidied = (area * 1e9).rounded() / 1e9
        let answer = abs(area - tidied) < 1e-10 ? tidied : area
        return flipped ? -answer : answer
    }

    /// A five-point central difference, for the expressions the symbolic rules
    /// cannot take apart. Two more evaluations than the textbook two-point
    /// version, and about four more decimal places.
    private static func numericDerivative(
        of node: Node, at point: Double, degrees: Bool,
        variables: [String: Double], previous: Double?
    ) -> Double? {
        let h = max(abs(point), 1) * 1e-4
        func at(_ x: Double) -> Double? {
            var bound = variables
            bound["x"] = x
            return value(of: node, degrees: degrees, variables: bound, previous: previous)
        }
        guard let minus2 = at(point - 2 * h), let minus1 = at(point - h),
              let plus1 = at(point + h), let plus2 = at(point + 2 * h)
        else { return nil }
        let slope = (minus2 - 8 * minus1 + 8 * plus1 - plus2) / (12 * h)
        guard slope.isFinite else { return nil }
        // A slope that lands a hair off a round number is the method's error, not
        // the answer: 2.0000000001 should read 2.
        let rounded = (slope * 1e6).rounded() / 1e6
        return abs(slope - rounded) < 1e-7 ? rounded : slope
    }

    // MARK: - Names

    private static func constant(_ name: String, answer: Double?) -> Double? {
        switch name {
        case "pi": .pi
        case "tau": .pi * 2
        case "e": M_E
        case "phi": (1 + 5.0.squareRoot()) / 2
        case "ans": answer
        default: nil
        }
    }

    /// The offsets a caret can sensibly rest at in a line drawn as maths.
    ///
    /// Not every character offset has a place on screen. The caret can stand
    /// inside a number or a name and beside any atom, but there is nowhere to
    /// put it in the middle of the letters of `sqrt` - the drawing shows a root
    /// sign, not four letters. `MathView` has always known this and snapped the
    /// caret to the nearest offset that had a home.
    ///
    /// What it did not do is tell the arrow keys. They moved the real caret one
    /// *character* at a time, so in `derivsinx` - where the only places are 0,
    /// 5, 8 and 9 - four presses in a row all snapped back to the same place
    /// and the caret sat there looking broken. Both now step through this.
    ///
    /// A line that does not parse has no atoms to speak of, so every offset is
    /// a stop and the arrows behave exactly as they would in a text field.
    static func caretStops(in text: String) -> [Int] {
        guard let tree = tree(of: text) else { return Array(0...text.count) }
        var stops = caretStops(in: tree)
        // The ends of the line are always reachable, even when the outermost
        // atom stops short of them - a trailing bracket the parser forgave, say.
        stops.insert(0)
        stops.insert(text.count)
        return stops.sorted()
    }

    static func caretStops(in node: Node) -> Set<Int> {
        var stops: Set<Int> = []
        func walk(_ node: Node) {
            stops.insert(node.range.lowerBound)
            stops.insert(node.range.upperBound)
            switch node.kind {
            case .number, .name:
                // Inside a literal every character boundary works.
                for offset in node.range { stops.insert(offset) }
            case .negate(let inner), .factorial(let inner), .percent(let inner):
                walk(inner)
            case .binary(_, let left, let right):
                walk(left)
                walk(right)
            case .call(_, let arguments):
                arguments.forEach(walk)
            }
        }
        walk(node)
        return stops
    }

    /// Whether a bare name is something that takes an argument.
    ///
    /// This used to be "anything that is not a constant", which made every
    /// unknown word a function waiting for an argument. `deriv(sinx)` failed
    /// on exactly that: `sinx` lexed as one name, counted as a function, and
    /// then found no argument before the closing bracket. A real list also
    /// lets an unknown word be a variable, which is what `solve` wants.
    static func isFunction(_ name: String) -> Bool { functionNames.contains(name) }

    /// Every name that takes an argument. The evaluator handles `deriv`,
    /// `ddx`, `integral`, `sigma` and `product` before `apply` ever sees them,
    /// so they have to be listed here too.
    static let functionNames: Set<String> = [
        "sqrt", "cbrt", "nthroot", "abs", "sign", "exp", "ln", "log", "log2",
        "floor", "ceil", "round", "sin", "cos", "tan", "sec", "csc", "cot",
        "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh",
        "asinh", "acosh", "atanh", "hypot", "mod", "gcd", "lcm", "ncr", "npr",
        "min", "max", "sum", "total", "prod", "mean", "median",
        "stdev", "stdevp", "var", "varp", "mad", "count", "rand", "randint",
        "deriv", "ddx", "integral", "sigma", "product",
    ]

    static let constantNames: Set<String> = ["pi", "tau", "e", "phi", "ans"]

    /// Splits a run of letters that is not itself a name into ones that are.
    ///
    /// `sinx` is `sin x`, `pix` is `pi x`, `xy` is `x y` - what anybody writing
    /// maths by hand means, and what a run of letters has to mean once the
    /// whole run is not a name. Longest match first, so `sinh x` is not read as
    /// `sin h x`, and a letter that starts nothing known stands alone as a
    /// variable.
    ///
    /// ponytail: the parser already turns `sin` followed by a value into a
    /// call - that is what makes `sin90` work. So this only has to produce the
    /// right tokens; nothing downstream changes.
    static func split(name run: String) -> [String] {
        let letters = Array(run)
        var parts: [String] = []
        var index = 0
        while index < letters.count {
            var matched = false
            // Down to two: a single letter is never a function, and trying one
            // would turn `e` into a match before `exp` had a chance.
            var length = letters.count - index
            while length >= 2 {
                let candidate = String(letters[index ..< index + length])
                if functionNames.contains(candidate) || constantNames.contains(candidate) {
                    parts.append(candidate)
                    index += length
                    matched = true
                    break
                }
                length -= 1
            }
            if !matched {
                parts.append(String(letters[index]))
                index += 1
            }
        }
        return parts
    }

    private static func factorial(_ value: Double) -> Double? {
        guard value >= 0, value == value.rounded(), value <= 170 else { return nil }
        return (1 ... max(Int(value), 1)).reduce(1.0) { $0 * Double($1) }
    }

    private static func apply(_ name: String, _ arguments: [Double], degrees: Bool) -> Double? {
        // Trigonometry works in whichever mode is set, which is the whole point of
        // the mode existing - nobody wants to type a conversion by hand.
        func toRadians(_ value: Double) -> Double { degrees ? value * .pi / 180 : value }
        func fromRadians(_ value: Double) -> Double { degrees ? value * 180 / .pi : value }

        func one(_ body: (Double) -> Double) -> Double? {
            arguments.count == 1 ? body(arguments[0]) : nil
        }
        func two(_ body: (Double, Double) -> Double) -> Double? {
            arguments.count == 2 ? body(arguments[0], arguments[1]) : nil
        }

        switch name {
        case "sqrt": return one { $0.squareRoot() }
        case "cbrt": return one { cbrt($0) }
        // nthroot(3, 27) reads "the 3rd root of 27", the order Desmos uses.
        case "nthroot": return two { $1 < 0 && Int($0) % 2 == 1 ? -pow(-$1, 1 / $0) : pow($1, 1 / $0) }
        case "abs": return one { abs($0) }
        case "sign": return one { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
        case "exp": return one { exp($0) }
        case "ln": return one { log($0) }
        case "log":
            if arguments.count == 1 { return log10(arguments[0]) }
            // log(base, value), the order Desmos uses.
            return two { log($1) / log($0) }
        case "log2": return one { log2($0) }
        case "floor": return one { $0.rounded(.down) }
        case "ceil": return one { $0.rounded(.up) }
        case "round": return one { $0.rounded() }
        case "sin": return one { sin(toRadians($0)) }
        case "cos": return one { cos(toRadians($0)) }
        case "tan": return one { tan(toRadians($0)) }
        case "sec": return one { 1 / cos(toRadians($0)) }
        case "csc": return one { 1 / sin(toRadians($0)) }
        case "cot": return one { 1 / tan(toRadians($0)) }
        case "asin": return one { fromRadians(asin($0)) }
        case "acos": return one { fromRadians(acos($0)) }
        case "atan": return one { fromRadians(atan($0)) }
        case "atan2": return two { fromRadians(atan2($0, $1)) }
        case "sinh": return one { sinh($0) }
        case "cosh": return one { cosh($0) }
        case "tanh": return one { tanh($0) }
        case "asinh": return one { asinh($0) }
        case "acosh": return one { acosh($0) }
        case "atanh": return one { atanh($0) }
        case "hypot": return two { (($0 * $0) + ($1 * $1)).squareRoot() }
        case "mod": return two { $0.truncatingRemainder(dividingBy: $1) }
        case "gcd": return two { Double(gcd(Int($0), Int($1))) }
        case "lcm": return two { let g = gcd(Int($0), Int($1)); return g == 0 ? 0 : abs($0 * $1) / Double(g) }
        case "ncr": return two { combinations($0, $1) }
        case "npr": return two { permutations($0, $1) }
        case "min": return arguments.isEmpty ? nil : arguments.min()
        case "max": return arguments.isEmpty ? nil : arguments.max()
        case "sum", "total": return arguments.isEmpty ? nil : arguments.reduce(0, +)
        case "prod": return arguments.isEmpty ? nil : arguments.reduce(1, *)
        case "mean": return arguments.isEmpty ? nil : arguments.reduce(0, +) / Double(arguments.count)
        case "median": return median(arguments)
        case "stdev": return standardDeviation(arguments)
        case "stdevp": return populationDeviation(arguments)
        case "var": return standardDeviation(arguments).map { $0 * $0 }
        case "varp": return populationDeviation(arguments).map { $0 * $0 }
        case "mad": return meanAbsoluteDeviation(arguments)
        case "count": return Double(arguments.count)
        // The only two things here that are not the same every time you ask.
        case "rand": return arguments.isEmpty ? Double.random(in: 0 ..< 1) : nil
        case "randint":
            return two { Double(Int.random(in: Int($0.rounded()) ... max(Int($0.rounded()), Int($1.rounded())))) }
        default: return nil
        }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    private static func combinations(_ n: Double, _ r: Double) -> Double {
        guard let top = factorial(n), let bottom = factorial(r),
              let rest = factorial(n - r), bottom * rest != 0
        else { return .nan }
        return top / (bottom * rest)
    }

    private static func permutations(_ n: Double, _ r: Double) -> Double {
        guard let top = factorial(n), let rest = factorial(n - r), rest != 0 else { return .nan }
        return top / rest
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Sample standard deviation, which is what a calculator's `stdev` means.
    private static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    /// The whole-population version: divided by n rather than n-1, so a single
    /// value has a deviation of zero rather than no answer at all.
    private static func populationDeviation(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    private static func meanAbsoluteDeviation(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + abs($1 - mean) } / Double(values.count)
    }
}

// MARK: - Differentiation

extension Calculator {
    /// The derivative of a tree with respect to a name, as another tree.
    ///
    /// The ordinary rules, written out. Anything not covered - a factorial, a
    /// statistic, a function of two arguments that is not `log` - returns nil, and
    /// the caller falls back to measuring the slope numerically.
    ///
    /// Degrees are not a presentation detail here. `sin` in degree mode is
    /// `sin(x·π/180)`, so its derivative carries that factor, and the inverse
    /// functions carry its reciprocal. Getting this wrong would make every
    /// derivative silently 57 times too big.
    static func derivative(of node: Node, by variable: String, degrees: Bool) -> Node? {
        func d(_ inner: Node) -> Node? { derivative(of: inner, by: variable, degrees: degrees) }
        /// π/180, left unfolded so it prints as itself rather than as 0.01745.
        let perDegree = Node.binary("/", .name("pi"), .number(180))

        switch node.kind {
        case .number:
            return .number(0)

        case .name(let name):
            return .number(name == variable ? 1 : 0)

        case .negate(let inner):
            return d(inner).map { .negate($0) }

        case .binary(let op, let left, let right):
            guard let dl = d(left), let dr = d(right) else { return nil }
            switch op {
            case "+": return .binary("+", dl, dr)
            case "-": return .binary("-", dl, dr)
            // Product rule.
            case "*": return .binary("+", .binary("*", dl, right), .binary("*", left, dr))
            // Quotient rule.
            case "/":
                return .binary("/",
                               .binary("-", .binary("*", dl, right), .binary("*", left, dr)),
                               .binary("^", right, .number(2)))
            case "^":
                // A constant power is the case everybody means: n·u^(n-1)·u'.
                if isFree(right, of: variable) {
                    let lowered = Node.binary("^", left, .binary("-", right, .number(1)))
                    return .binary("*", .binary("*", right, lowered), dl)
                }
                // Otherwise the general rule, which needs the logarithm.
                let logarithm = Node.call("ln", [left])
                let inner = Node.binary("+",
                                        .binary("*", dr, logarithm),
                                        .binary("/", .binary("*", right, dl), left))
                return .binary("*", node, inner)
            default:
                return nil
            }

        case .call(let name, let arguments):
            guard arguments.count == 1 || (name == "log" && arguments.count == 2) else {
                // log(base, u) with a constant base is still differentiable.
                return nil
            }
            let u = arguments.count == 1 ? arguments[0] : arguments[1]
            guard let du = d(u) else { return nil }
            /// chain(f') = f'(u) · u'
            func chain(_ outer: Node) -> Node { .binary("*", outer, du) }

            switch name {
            case "sin":
                let base = Node.call("cos", [u])
                return chain(degrees ? .binary("*", base, perDegree) : base)
            case "cos":
                let base = Node.negate(.call("sin", [u]))
                return chain(degrees ? .binary("*", base, perDegree) : base)
            case "tan":
                let base = Node.binary("/", .number(1), .binary("^", .call("cos", [u]), .number(2)))
                return chain(degrees ? .binary("*", base, perDegree) : base)
            case "asin", "acos":
                let root = Node.call("sqrt", [.binary("-", .number(1), .binary("^", u, .number(2)))])
                let base = Node.binary("/", .number(name == "asin" ? 1 : -1), root)
                return chain(degrees ? .binary("/", base, perDegree) : base)
            case "atan":
                let base = Node.binary("/", .number(1),
                                       .binary("+", .number(1), .binary("^", u, .number(2))))
                return chain(degrees ? .binary("/", base, perDegree) : base)
            case "exp":
                return chain(.call("exp", [u]))
            case "ln":
                return .binary("/", du, u)
            case "log":
                // Base ten unless another was given; either way a constant.
                let base: Node = arguments.count == 2 ? arguments[0] : .number(10)
                guard isFree(base, of: variable) else { return nil }
                return .binary("/", du, .binary("*", u, .call("ln", [base])))
            case "log2":
                return .binary("/", du, .binary("*", u, .call("ln", [.number(2)])))
            case "sqrt":
                return .binary("/", du, .binary("*", .number(2), .call("sqrt", [u])))
            case "cbrt":
                let power = Node.binary("^", .call("cbrt", [u]), .number(2))
                return .binary("/", du, .binary("*", .number(3), power))
            case "sinh": return chain(.call("cosh", [u]))
            case "cosh": return chain(.call("sinh", [u]))
            case "tanh":
                return chain(.binary("-", .number(1), .binary("^", .call("tanh", [u]), .number(2))))
            case "abs":
                return chain(.call("sign", [u]))
            default:
                return nil
            }

        case .factorial, .percent:
            return nil
        }
    }

    /// Whether a subtree holds no mention of the variable, and so counts as a
    /// constant for the rules above.
    static func isFree(_ node: Node, of variable: String) -> Bool {
        switch node.kind {
        case .number: true
        case .name(let name): name != variable
        case .negate(let inner), .factorial(let inner), .percent(let inner):
            isFree(inner, of: variable)
        case .binary(_, let left, let right):
            isFree(left, of: variable) && isFree(right, of: variable)
        case .call(_, let arguments): arguments.allSatisfy { isFree($0, of: variable) }
        }
    }

    // MARK: - Tidying up

    /// Folds the arithmetic and drops the parts that say nothing.
    ///
    /// Without this the product rule alone turns `sin(x)` into
    /// `cos(x)·1 + sin(x)·0`, which is correct, unreadable, and the reason every
    /// symbolic differentiator ships with a simplifier.
    ///
    /// ponytail: this is the short list of identities that clean up the rules
    /// above - not a computer algebra system. `x/x` stays `x/x`, and that is a
    /// deliberate place to stop.
    static func simplify(_ node: Node) -> Node {
        switch node.kind {
        case .number, .name:
            return node

        case .negate(let inner):
            let simplified = simplify(inner)
            if case .number(let value) = simplified.kind { return .number(-value) }
            if case .negate(let twice) = simplified.kind { return twice }
            return .negate(simplified)

        case .factorial(let inner):
            return .factorial(simplify(inner))

        case .percent(let inner):
            return .percent(simplify(inner))

        case .call(let name, let arguments):
            let inner = arguments.map(simplify)
            // ln(e) is 1 and ln(1) is 0 - the two that decide whether the
            // derivative of e^x reads as itself or as `e^x * ln(e)`.
            if name == "ln", inner.count == 1 {
                if inner[0] == .name("e") { return .number(1) }
                if inner[0] == .number(1) { return .number(0) }
            }
            return .call(name, inner)

        case .binary(let op, let left, let right):
            let a = simplify(left)
            let b = simplify(right)

            // Arithmetic on two plain numbers is just arithmetic.
            if case .number(let x) = a.kind, case .number(let y) = b.kind {
                switch op {
                case "+": return .number(x + y)
                case "-": return .number(x - y)
                case "*": return .number(x * y)
                case "/": if y != 0 { return .number(x / y) }
                case "^": return .number(pow(x, y))
                default: break
                }
            }

            switch op {
            case "+":
                if a == .number(0) { return b }
                if b == .number(0) { return a }
                // u + -v reads as u - v.
                if case .negate(let inner) = b.kind { return simplify(.binary("-", a, inner)) }
            case "-":
                if b == .number(0) { return a }
                if a == .number(0) { return simplify(.negate(b)) }
            case "*":
                if a == .number(0) || b == .number(0) { return .number(0) }
                if a == .number(1) { return b }
                if b == .number(1) { return a }
                if a == .number(-1) { return simplify(.negate(b)) }
                if b == .number(-1) { return simplify(.negate(a)) }
                // Numbers travel to the front, so it reads 2x rather than x·2.
                if case .number = b.kind, case .number = a.kind {} else if case .number = b.kind {
                    return .binary("*", b, a)
                }
            case "/":
                if b == .number(1) { return a }
                if a == .number(0) { return .number(0) }
            case "^":
                if b == .number(1) { return a }
                if b == .number(0) { return .number(1) }
                if a == .number(1) { return .number(1) }
            default:
                break
            }
            return .binary(op, a, b)
        }
    }

    // MARK: - Printing it back

    /// The tree as maths, bracketed only where it has to be.
    static func describe(_ node: Node) -> String {
        describe(node, parentPrecedence: 0)
    }

    private static func precedence(_ op: Character) -> Int {
        switch op {
        case "+", "-": 1
        case "*", "/": 2
        case "^": 4
        default: 0
        }
    }

    private static func describe(_ node: Node, parentPrecedence: Int) -> String {
        switch node.kind {
        case .number(let value):
            return format(value)

        case .name(let name):
            return name

        case .negate(let inner):
            let text = "-" + describe(inner, parentPrecedence: 3)
            return parentPrecedence > 1 ? "(" + text + ")" : text

        case .factorial(let inner):
            return describe(inner, parentPrecedence: 5) + "!"

        case .percent(let inner):
            return describe(inner, parentPrecedence: 5) + "%"

        case .call(let name, let arguments):
            return name + "(" + arguments.map { describe($0, parentPrecedence: 0) }.joined(separator: ", ") + ")"

        case .binary(let op, let left, let right):
            let own = precedence(op)
            // `^` is right-associative, so its left side needs the bracket.
            let leftText = describe(left, parentPrecedence: op == "^" ? own + 1 : own)
            let rightText = describe(right, parentPrecedence: own + 1)
            let text: String
            switch op {
            case "*":
                // 2x and 3sin(x) rather than 2*x - and still parseable, because
                // implicit multiplication is in the grammar.
                if case .number = left.kind, isBareName(right) {
                    text = leftText + rightText
                } else {
                    text = leftText + " * " + rightText
                }
            case "^":
                text = leftText + "^" + rightText
            default:
                text = leftText + " " + String(op) + " " + rightText
            }
            return own < parentPrecedence ? "(" + text + ")" : text
        }
    }

    /// Something a number can sit against without an operator between them.
    private static func isBareName(_ node: Node) -> Bool {
        switch node.kind {
        case .name, .call: true
        // A power of one of those too, so it reads 3x^2 rather than 3 * x^2.
        case .binary("^", let base, _): isBareName(base)
        default: false
        }
    }

    // MARK: - Solving

    /// Where a tree crosses zero, in x.
    ///
    /// Two routes. A polynomial of degree one or two is solved with the formula
    /// everyone learns, which is exact and finds a repeated root that no search
    /// would ever see - `x^2 = 0` touches zero without crossing it. Everything
    /// else is swept for sign changes and each one bisected, which finds every
    /// crossing in the range and admits to nothing outside it.
    static func solve(
        _ node: Node, degrees: Bool, previous: Double?
    ) -> (roots: [Double], truncated: Bool)? {
        // Nothing to solve for: `2 + 2 = 4` is a statement, not an equation.
        guard !isFree(node, of: "x") else { return nil }

        if let coefficients = polynomial(node, previous: previous),
           let roots = polynomialRoots(coefficients) {
            return (roots, false)
        }

        func f(_ x: Double) -> Double? {
            value(of: node, degrees: degrees, variables: ["x": x], previous: previous)
        }

        // Swept outward from zero rather than left to right across a fixed range.
        // `sin(x) = 0` has a root every π forever, and the six nearest the origin
        // are the ones anybody means - scanning from -100 upward answered with six
        // roots near -100 and stopped. Sweeping outward also means a periodic
        // equation stops early instead of walking the whole range.
        //
        // ponytail: a sweep, not a solver. The reach is what fits on a school
        // page - a turn and a half of degrees, or about sixteen radians - and it
        // is written down rather than implied.
        let reach = degrees ? 540.0 : 100.0
        let step = degrees ? 0.5 : 0.02

        func sweep(_ direction: Double) -> (roots: [Double], more: Bool) {
            var found: [Double] = []
            var x = 0.0
            var previous = f(0)
            while abs(x) < reach {
                if found.count > Self.mostRoots { return (found, true) }
                let next = x + direction * step
                guard let current = f(next) else {
                    x = next
                    previous = nil
                    continue
                }
                defer { x = next; previous = current }
                if current == 0 {
                    add(tidy(next), to: &found)
                    continue
                }
                guard let before = previous, before != 0, before.sign != current.sign else { continue }
                if let root = bisect(f, from: min(x, next), to: max(x, next)) {
                    add(tidy(root), to: &found)
                }
            }
            return (found, false)
        }

        var roots: [Double] = []
        if let atZero = f(0), atZero == 0 { add(0, to: &roots) }
        let up = sweep(1)
        let down = sweep(-1)
        for root in up.roots + down.roots { add(root, to: &roots) }

        // Capped, and the ones kept are those nearest zero - with the negative
        // one first when a pair is the same distance out, so a symmetric equation
        // answers symmetrically rather than leaning one way.
        let nearest = roots
            .sorted { abs($0) == abs($1) ? $0 < $1 : abs($0) < abs($1) }
            .prefix(Self.mostRoots)
        return (nearest.sorted(), up.more || down.more || roots.count > Self.mostRoots)
    }

    /// How many solutions are worth printing.
    static let mostRoots = 6

    private static func add(_ root: Double, to roots: inout [Double]) {
        guard root.isFinite, !roots.contains(where: { abs($0 - root) < 1e-6 }) else { return }
        roots.append(root)
    }

    /// A root a hair off a whole number is the method's error, not the answer.
    /// Anything else keeps every digit the bisection earned - √2 is not 1.41421356.
    private static func tidy(_ value: Double) -> Double {
        let rounded = value.rounded()
        return abs(value - rounded) < 1e-9 ? rounded : value
    }

    private static func bisect(_ f: (Double) -> Double?, from: Double, to: Double) -> Double? {
        var low = from, high = to
        guard var lowValue = f(low) else { return nil }
        for _ in 0 ..< 200 {
            let middle = (low + high) / 2
            guard let value = f(middle) else { return nil }
            if value == 0 || (high - low) < 1e-13 { return middle }
            if value.sign == lowValue.sign { low = middle; lowValue = value } else { high = middle }
        }
        return (low + high) / 2
    }

    /// Coefficients in x, lowest power first, when the tree is a polynomial with
    /// constant coefficients. nil for anything else - a sine, a logarithm, x in an
    /// exponent.
    private static func polynomial(_ node: Node, previous: Double?) -> [Double]? {
        switch node.kind {
        case .number(let value):
            return [value]

        case .name(let name):
            if name == "x" { return [0, 1] }
            return constant(name, answer: previous).map { [$0] }

        case .negate(let inner):
            return polynomial(inner, previous: previous).map { $0.map(-) }

        case .percent(let inner):
            return polynomial(inner, previous: previous).map { $0.map { $0 / 100 } }

        case .factorial:
            return nil

        case .call:
            // A function of x is not a polynomial; a function of numbers is a
            // number.
            guard isFree(node, of: "x"),
                  let value = value(of: node, degrees: false, variables: [:], previous: previous)
            else { return nil }
            return [value]

        case .binary(let op, let left, let right):
            guard let a = polynomial(left, previous: previous),
                  let b = polynomial(right, previous: previous)
            else { return nil }
            switch op {
            case "+", "-":
                var result = [Double](repeating: 0, count: max(a.count, b.count))
                for (power, coefficient) in a.enumerated() { result[power] += coefficient }
                for (power, coefficient) in b.enumerated() {
                    result[power] += op == "+" ? coefficient : -coefficient
                }
                return result
            case "*":
                var result = [Double](repeating: 0, count: a.count + b.count - 1)
                for (i, left) in a.enumerated() {
                    for (j, right) in b.enumerated() { result[i + j] += left * right }
                }
                return result
            case "/":
                // Dividing by x is not a polynomial; dividing by a number is.
                guard b.count == 1, b[0] != 0 else { return nil }
                return a.map { $0 / b[0] }
            case "^":
                guard b.count == 1, b[0] >= 0, b[0] == b[0].rounded(), b[0] <= 8 else { return nil }
                var result: [Double] = [1]
                for _ in 0 ..< Int(b[0]) {
                    var product = [Double](repeating: 0, count: result.count + a.count - 1)
                    for (i, left) in result.enumerated() {
                        for (j, right) in a.enumerated() { product[i + j] += left * right }
                    }
                    result = product
                }
                return result
            default:
                return nil
            }
        }
    }

    /// Exact roots for the degrees worth having a formula for.
    private static func polynomialRoots(_ coefficients: [Double]) -> [Double]? {
        var trimmed = coefficients
        while let last = trimmed.last, abs(last) < 1e-12, trimmed.count > 1 { trimmed.removeLast() }

        switch trimmed.count {
        case 2:
            let (c, b) = (trimmed[0], trimmed[1])
            return b == 0 ? [] : [tidy(-c / b)]
        case 3:
            let (c, b, a) = (trimmed[0], trimmed[1], trimmed[2])
            let discriminant = b * b - 4 * a * c
            if discriminant < 0 { return [] }
            if discriminant == 0 { return [tidy(-b / (2 * a))] }
            let root = discriminant.squareRoot()
            return [tidy((-b - root) / (2 * a)), tidy((-b + root) / (2 * a))].sorted()
        default:
            // Degree zero is `3 = 0`, which has no solutions; anything higher goes
            // to the sweep.
            return trimmed.count == 1 ? [] : nil
        }
    }
}
