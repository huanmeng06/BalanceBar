import Foundation

/// Extracts the request contract from a CC Switch usage script without running JavaScript.
///
/// Reads the single structured request object (`request:` or legacy `fetch({ ... })`) or one
/// top-level legacy `url:` property. Nested objects, comments, and strings are never consulted,
/// and anything ambiguous returns `nil`, because BalanceAPIClient sends the provider API key to
/// this URL.
///
/// `url` must evaluate completely with a small JavaScript subset: string and template literals,
/// `+`, parentheses, `const` / `let` / `var` identifiers (lexically scoped, declared before use,
/// never reassigned), and `.replace` / `.replaceAll` / `.trim*` / case-conversion calls.
/// `{{placeholder}}` tokens in literals are substituted first, matching CC Switch's template
/// injection. `method` and `headers` come from the same object; `headers` entries that don't
/// evaluate are dropped. Both are informational: BalanceAPIClient still sends GET with its own
/// Bearer headers. `extractor` is not interpreted; BalanceResponseParser reads the response body.
enum UsageScriptRequestParser {
    struct ParsedRequest: Equatable {
        let urlTemplate: String
        let method: String?
        let headers: [String: String]
    }

    static func parseRequest(
        from code: String,
        placeholders: [String: String] = [:]
    ) -> ParsedRequest? {
        guard let script = UsageScriptSource(source: Array(code), placeholders: placeholders) else {
            return nil
        }
        if let object = script.requestObject(),
           let properties = script.properties(ofObjectAt: object) {
            func single(_ name: String) -> Range<Int>? {
                let matches = properties.filter { $0.name == name }
                return matches.count == 1 ? matches[0].value : nil
            }
            guard let urlValue = single("url"),
                  let url = script.evaluate(urlValue), !url.isEmpty else { return nil }
            let method = single("method").flatMap { script.evaluate($0) }?.uppercased()
            let headers = single("headers").map { script.headers(in: $0) } ?? [:]
            return ParsedRequest(urlTemplate: url, method: method, headers: headers)
        }
        // Preserve the legacy CC Switch form used by existing providers:
        // `url: "…"`, `url: '…'`, or `url: `…`` at script top level.
        guard let urlValue = script.legacyURLValue(),
              let url = script.evaluate(urlValue), !url.isEmpty else { return nil }
        return ParsedRequest(urlTemplate: url, method: nil, headers: [:])
    }
}

private struct UsageScriptSource {
    struct Property {
        let name: String
        /// Source range of the value, up to the `,` or `}`; for shorthand `{ url }`, the key.
        let value: Range<Int>
    }

    private enum Argument {
        case string(String)
        case regex(pattern: String, flags: String)
    }

    private static let maxResolutionDepth = 8
    /// Rejects matches preceded by an identifier character or `.` (`baseUrl`, `response.url`).
    private static let boundary = "(?<![A-Za-z0-9_$.])"

    let source: [Character]
    let placeholders: [String: String]
    private let text: String
    /// `false` for characters inside comments, string/template literal bodies and regex literals.
    private let isCode: [Bool]
    /// Matching bracket positions for `(`, `[`, `{` in code, in both directions.
    private let partner: [Int: Int]

    /// Fails when brackets are unbalanced, since scope and object boundaries would be unreliable.
    init?(source: [Character], placeholders: [String: String]) {
        self.source = source
        self.placeholders = placeholders
        self.text = String(source)
        let mask = Self.codeMask(for: source)
        guard let partner = Self.bracketPartners(in: source, isCode: mask) else { return nil }
        self.isCode = mask
        self.partner = partner
    }

    private static func codeMask(for source: [Character]) -> [Bool] {
        var mask = Array(repeating: true, count: source.count)
        var index = 0
        func blank(_ range: Range<Int>) {
            for position in range where position < mask.count { mask[position] = false }
        }
        while index < source.count {
            let character = source[index]
            let next: Character? = index + 1 < source.count ? source[index + 1] : nil
            if character == "/", next == "/" {
                let start = index
                while index < source.count, !source[index].isNewline { index += 1 }
                blank(start..<index)
            } else if character == "/", next == "*" {
                let start = index
                index += 2
                while index + 1 < source.count, !(source[index] == "*" && source[index + 1] == "/") { index += 1 }
                index = min(index + 2, source.count)
                blank(start..<index)
            } else if character == "\"" || character == "'" || character == "`" {
                let start = index + 1
                index += 1
                while index < source.count, source[index] != character {
                    if source[index] == "\\" { index += 1 }
                    if character != "`", index < source.count, source[index].isNewline { break }
                    index += 1
                }
                blank(start..<index)
                index += 1
            } else if character == "/", regexCanStart(at: index, in: source, mask: mask) {
                let start = index + 1
                index += 1
                var inClass = false
                while index < source.count, !source[index].isNewline {
                    if source[index] == "\\" {
                        index += 2
                        continue
                    }
                    if source[index] == "[" { inClass = true }
                    if source[index] == "]" { inClass = false }
                    if source[index] == "/", !inClass { break }
                    index += 1
                }
                blank(start..<min(index, source.count))
                index += 1
            } else {
                index += 1
            }
        }
        return mask
    }

    /// A `/` starts a regex literal unless it follows a value (identifier, number, `)`, `]`,
    /// `}` or a closing quote), in which case it is division.
    private static func regexCanStart(at index: Int, in source: [Character], mask: [Bool]) -> Bool {
        var cursor = index - 1
        while cursor >= 0, source[cursor].isWhitespace { cursor -= 1 }
        guard cursor >= 0 else { return true }
        let previous = source[cursor]
        guard mask[cursor] else { return false }
        if isIdentifierPart(previous) {
            var start = cursor
            while start > 0, mask[start - 1], isIdentifierPart(source[start - 1]) { start -= 1 }
            let word = String(source[start...cursor])
            return ["return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw", "yield", "await"]
                .contains(word)
        }
        return ![")", "]", "}", "\"", "'", "`"].contains(previous)
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    private static func bracketPartners(in source: [Character], isCode: [Bool]) -> [Int: Int]? {
        let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        var stack: [Int] = []
        var partner: [Int: Int] = [:]
        for index in source.indices where isCode[index] {
            let character = source[index]
            if character == "(" || character == "[" || character == "{" {
                stack.append(index)
            } else if let opener = closers[character] {
                guard let open = stack.popLast(), source[open] == opener else { return nil }
                partner[open] = index
                partner[index] = open
            }
        }
        return stack.isEmpty ? partner : nil
    }

    // MARK: - Locating the request object

    /// Position of the request object's opening brace: the direct request property of the final
    /// configuration object, or the argument of one top-level legacy fetch call.
    func requestObject() -> Int? {
        let requestKeys = codeMatches(of: "\(Self.boundary)([\"']?)request\\1\\s*:")
            .filter { isPreceded(by: ["{", ","], at: $0.lowerBound) }
        let fetchCalls = codeMatches(of: "\(Self.boundary)fetch\\s*\\(")
            .filter { enclosingBrackets(of: $0.lowerBound).isEmpty }
        guard fetchCalls.isEmpty || requestKeys.isEmpty else { return nil }
        if fetchCalls.count == 1 {
            let open = fetchCalls[0].upperBound - 1
            var cursor = open + 1
            skipTrivia(&cursor)
            guard cursor < source.count, source[cursor] == "{", let close = partner[cursor],
                  let next = nextSignificant(from: close + 1), next == ")" || next == "," else { return nil }
            return cursor
        }
        guard fetchCalls.isEmpty else { return nil }
        let configContainers = requestKeys.compactMap { key -> Int? in
            guard let container = enclosingBraces(of: key.lowerBound).first,
                  isParenthesizedObject(at: container) else { return nil }
            return container
        }
        guard configContainers.count == 1 else { return nil }
        let candidates = requestKeys.compactMap { key -> Int? in
            guard let container = enclosingBraces(of: key.lowerBound).first,
                  isFinalConfigObject(at: container),
                  let (object, end) = objectValue(at: key.upperBound),
                  let next = nextSignificant(from: end), next == "," || next == "}" else {
                return nil
            }
            return object
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func isParenthesizedObject(at open: Int) -> Bool {
        var previous = open - 1
        while previous >= 0, !isCode[previous] || source[previous].isWhitespace { previous -= 1 }
        guard previous >= 0, source[previous] == "(", let close = partner[previous],
              let objectClose = partner[open], close == objectClose + 1 else { return false }
        var before = previous - 1
        while before >= 0, !isCode[before] || source[before].isWhitespace { before -= 1 }
        return before < 0 || source[before] == ";" || source[before] == "}"
    }

    /// The CC Switch result is a parenthesized object expression at the end of the script.
    /// Requiring this shape prevents request properties in assigned/helper objects from
    /// becoming the credential-bearing request by accident.
    private func isFinalConfigObject(at open: Int) -> Bool {
        guard let close = partner[open] else { return false }
        guard isParenthesizedObject(at: open) else { return false }
        var cursor = close + 1
        skipTrivia(&cursor)
        if cursor < source.count, source[cursor] == ")" {
            cursor += 1
        } else if cursor < source.count, source[cursor] == ";" {
            cursor += 1
        } else if cursor != source.count {
            return false
        }
        skipTrivia(&cursor)
        if cursor < source.count, source[cursor] == ";" {
            cursor += 1
            skipTrivia(&cursor)
        }
        return cursor == source.count
    }

    /// Finds one legacy top-level `url:` property when no structured request exists.
    /// Nested object properties, comments, and string contents are deliberately excluded.
    func legacyURLValue() -> Range<Int>? {
        let requestKeys = codeMatches(of: "\(Self.boundary)([\"']?)request\\1\\s*:")
        let fetchCalls = codeMatches(of: "\(Self.boundary)fetch\\s*\\(")
        guard requestKeys.isEmpty, fetchCalls.isEmpty else { return nil }
        let urlKeys = codeMatches(of: "\(Self.boundary)([\"']?)url\\1\\s*:")
            .filter { enclosingBrackets(of: $0.lowerBound).isEmpty }
        guard urlKeys.count == 1,
              let end = legacyValueEnd(from: urlKeys[0].upperBound) else { return nil }
        return urlKeys[0].upperBound..<end
    }

    /// Ends a legacy expression at a top-level semicolon, comma, or statement newline.
    private func legacyValueEnd(from start: Int) -> Int? {
        var cursor = start
        var expressionStarted = false
        while cursor < source.count {
            if isCode[cursor] {
                let character = source[cursor]
                if character == ";" || character == "," { return cursor }
                if character.isNewline {
                    if !expressionStarted { cursor += 1; continue }
                    var previous = cursor - 1
                    while previous >= start, source[previous].isWhitespace || !isCode[previous] { previous -= 1 }
                    if previous >= start, ["+", "-", "(", "[", ".", "?", ":", "=", "&", "|"].contains(source[previous]) {
                        cursor += 1
                        continue
                    }
                    return cursor
                }
                if character == "(" || character == "[" || character == "{" {
                    guard let close = partner[cursor] else { return nil }
                    expressionStarted = true
                    cursor = close + 1
                    continue
                }
                if !character.isWhitespace { expressionStarted = true }
            }
            cursor += 1
        }
        return source.count
    }

    /// Reads `{ ... }` or an IIFE returning one: `(() => { ...; return { ... }; })()`,
    /// `(function () { ... })()` or `(() => ({ ... }))()`. Returns the object's `{` and the
    /// index just past the whole value.
    private func objectValue(at start: Int) -> (object: Int, end: Int)? {
        var cursor = start
        skipTrivia(&cursor)
        guard cursor < source.count else { return nil }
        if source[cursor] == "{" {
            guard let close = partner[cursor] else { return nil }
            return (cursor, close + 1)
        }
        if source[cursor] != "(" {
            let reference = cursor
            guard let name = identifier(at: &cursor) else { return nil }
            guard let value = objectBindingValue(named: name, reference: reference) else { return nil }
            return (value.object, cursor)
        }
        guard let groupClose = partner[cursor] else { return nil }

        var head = cursor + 1
        skipTrivia(&head)
        let isFunction = identifier(at: &head) == "function"
        if !isFunction { head = cursor + 1 }
        // Parameters must be empty so no name in the body is shadowed by an argument.
        guard var body = emptyParens(at: head) else { return nil }
        skipTrivia(&body)
        if !isFunction {
            guard body + 1 < source.count, source[body] == "=", source[body + 1] == ">" else { return nil }
            body += 2
            skipTrivia(&body)
        }
        guard body < source.count, let bodyClose = partner[body] else { return nil }

        let object: Int
        if source[body] == "{" {
            guard let returned = returnedObject(inBody: body) else { return nil }
            object = returned
        } else if !isFunction, source[body] == "(" {
            guard let literal = significantIndex(from: body + 1), source[literal] == "{",
                  let literalClose = partner[literal],
                  significantIndex(from: literalClose + 1) == bodyClose else { return nil }
            object = literal
        } else {
            return nil
        }
        guard significantIndex(from: bodyClose + 1) == groupClose,
              let end = emptyParens(at: groupClose + 1) else { return nil }
        return (object, end)
    }

    private func objectBindingValue(named name: String, reference: Int) -> (object: Int, end: Int)? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let declarations = codeMatches(of: "\(Self.boundary)(const|let|var)\\s+\(escaped)\\s*=(?!=)")
            .filter { $0.lowerBound < reference }
        guard declarations.count == 1 else { return nil }
        let assignments = codeMatches(
            of: "\(Self.boundary)\(escaped)\\s*(?:=(?![=>])|[-+*/%&|^]=|\\*\\*=|<<=|>>>?=|&&=|\\|\\|=|\\?\\?=|\\+\\+|--)"
        ) + codeMatches(of: "(?:\\+\\+|--)\\s*\(escaped)(?![A-Za-z0-9_$])")
        guard assignments.count == declarations.count,
              !hasOtherBinding(of: name, declarations: declarations) else { return nil }
        let declaration = declarations[0]
        let declarationBlock = innermostBracket(enclosing: declaration.lowerBound)
        if let declarationBlock {
            guard source[declarationBlock] == "{",
                  enclosingBraces(of: reference).contains(declarationBlock) else { return nil }
        }
        var valueStart = declaration.upperBound
        skipTrivia(&valueStart)
        return objectValue(at: valueStart)
    }

    /// Index just past `()` (whitespace and comments allowed) starting at `start`.
    private func emptyParens(at start: Int) -> Int? {
        guard let open = significantIndex(from: start), source[open] == "(",
              let close = partner[open], significantIndex(from: open + 1) == close else { return nil }
        return close + 1
    }

    /// The `{` of the object in the body's only `return { ... }` statement.
    private func returnedObject(inBody open: Int) -> Int? {
        guard let close = partner[open] else { return nil }
        let returns = codeMatches(of: "\(Self.boundary)return(?![A-Za-z0-9_$])")
            .filter { $0.lowerBound > open && $0.lowerBound < close }
        guard returns.count == 1, innermostBracket(enclosing: returns[0].lowerBound) == open else { return nil }
        // `return` followed by a newline returns undefined (ASI), so the `{` must be on the same line.
        var cursor = returns[0].upperBound
        while cursor < source.count, source[cursor] == " " || source[cursor] == "\t" { cursor += 1 }
        guard cursor < source.count, source[cursor] == "{", let objectClose = partner[cursor],
              let after = significantIndex(from: objectClose + 1),
              source[after] == ";" || after == close else { return nil }
        return cursor
    }

    /// Whether the closest code character before `index` is one of `characters`.
    private func isPreceded(by characters: Set<Character>, at index: Int) -> Bool {
        var cursor = index - 1
        while cursor >= 0, !isCode[cursor] || source[cursor].isWhitespace { cursor -= 1 }
        return cursor >= 0 && characters.contains(source[cursor])
    }

    private func significantIndex(from start: Int) -> Int? {
        var cursor = start
        skipTrivia(&cursor)
        return cursor < source.count ? cursor : nil
    }

    private func nextSignificant(from start: Int) -> Character? {
        significantIndex(from: start).map { source[$0] }
    }

    /// Character ranges of regex matches that start in code.
    private func codeMatches(of pattern: String) -> [Range<Int>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            guard start < isCode.count, isCode[start] else { return nil }
            return start..<end
        }
    }

    private func innermostBracket(enclosing index: Int) -> Int? {
        var best: Int?
        for (open, close) in partner where open < index && close > index && open < close {
            if best.map({ open > $0 }) ?? true { best = open }
        }
        return best
    }

    /// Opening `{` of every brace pair enclosing `index`, innermost first.
    private func enclosingBraces(of index: Int) -> [Int] {
        partner.filter { $0.key < index && $0.value > index && source[$0.key] == "{" }
            .map(\.key)
            .sorted(by: >)
    }

    // MARK: - Objects

    /// Properties of the object literal at `open`. Fails on anything but `key: value` and
    /// shorthand `key` entries (spread, computed keys, methods, getters/setters).
    func properties(ofObjectAt open: Int) -> [Property]? {
        guard let close = partner[open], source[open] == "{" else { return nil }
        var properties: [Property] = []
        var cursor = open + 1
        while true {
            skipTrivia(&cursor)
            guard cursor < close else { return properties }
            let keyStart = cursor
            let name: String?
            let isQuoted = source[cursor] == "\"" || source[cursor] == "'"
            name = isQuoted ? stringLiteral(at: &cursor) : identifier(at: &cursor)
            guard let name, cursor <= close else { return nil }
            skipTrivia(&cursor)
            guard cursor <= close else { return nil }
            if source[cursor] == ":" {
                let valueStart = cursor + 1
                guard let valueEnd = valueEnd(from: valueStart, limit: close) else { return nil }
                properties.append(Property(name: name, value: valueStart..<valueEnd))
                cursor = valueEnd
            } else if !isQuoted, source[cursor] == "," || cursor == close {
                properties.append(Property(name: name, value: keyStart..<cursor))
            } else {
                return nil
            }
            if cursor < close {
                guard source[cursor] == "," else { return nil }
                cursor += 1
            }
        }
    }

    /// Index of the top-level `,` or `limit` that ends a value starting at `start`.
    private func valueEnd(from start: Int, limit: Int) -> Int? {
        var cursor = start
        while cursor < limit {
            if isCode[cursor] {
                if source[cursor] == "," { return cursor }
                if let close = partner[cursor], close > cursor {
                    cursor = close + 1
                    continue
                }
            }
            cursor += 1
        }
        return cursor == limit ? limit : nil
    }

    /// Reads `headers: { name: expr, "name": expr }`, keeping entries whose values evaluate.
    func headers(in range: Range<Int>) -> [String: String] {
        guard let open = significantIndex(from: range.lowerBound), source[open] == "{",
              let close = partner[open], significantIndex(from: close + 1).map({ $0 >= range.upperBound }) ?? true,
              let properties = properties(ofObjectAt: open) else { return [:] }
        var result: [String: String] = [:]
        for property in properties {
            if let value = evaluate(property.value) { result[property.name] = value }
        }
        return result
    }

    /// Fully evaluates the expression in `range`; any unparsed remainder fails.
    func evaluate(_ range: Range<Int>) -> String? {
        var cursor = range.lowerBound
        guard let value = concatenation(at: &cursor, depth: 0) else { return nil }
        skipTrivia(&cursor)
        return cursor == range.upperBound ? value : nil
    }

    // MARK: - Expressions

    private func concatenation(at index: inout Int, depth: Int) -> String? {
        guard var result = term(at: &index, depth: depth) else { return nil }
        while true {
            var lookahead = index
            skipTrivia(&lookahead)
            guard lookahead < source.count, source[lookahead] == "+" else { return result }
            lookahead += 1
            guard let next = term(at: &lookahead, depth: depth) else { return nil }
            result += next
            index = lookahead
        }
    }

    private func term(at index: inout Int, depth: Int) -> String? {
        skipTrivia(&index)
        guard index < source.count else { return nil }
        let value: String
        switch source[index] {
        case "\"", "'":
            guard let literal = stringLiteral(at: &index) else { return nil }
            value = substitutePlaceholders(in: literal)
        case "`":
            guard let literal = templateLiteral(at: &index, depth: depth) else { return nil }
            value = literal
        case "(":
            var cursor = index + 1
            guard let inner = concatenation(at: &cursor, depth: depth) else { return nil }
            skipTrivia(&cursor)
            guard cursor < source.count, source[cursor] == ")" else { return nil }
            index = cursor + 1
            value = inner
        default:
            let reference = index
            guard let name = identifier(at: &index),
                  let resolved = resolve(name, at: reference, depth: depth) else { return nil }
            value = resolved
        }
        return methodChain(on: value, at: &index)
    }

    // MARK: - Scope

    /// Value of the `const` / `let` / `var` declaration that `name` at `reference` refers to.
    ///
    /// A declaration counts only when it precedes the reference and sits directly in the
    /// top level or in a `{}` block enclosing the reference; the innermost one wins. Anything
    /// that could make the binding differ at runtime fails: reassignment, parameters, function
    /// or class names, destructuring, loop headers, redeclaration, or multiple `var`s.
    private func resolve(_ name: String, at reference: Int, depth: Int) -> String? {
        guard depth < Self.maxResolutionDepth else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let declarations = codeMatches(of: "\(Self.boundary)(const|let|var)\\s+\(escaped)\\s*=(?!=)")
        let assignments = codeMatches(
            of: "\(Self.boundary)\(escaped)\\s*(?:=(?![=>])|[-+*/%&|^]=|\\*\\*=|<<=|>>>?=|&&=|\\|\\|=|\\?\\?=|\\+\\+|--)"
        ) + codeMatches(of: "(?:\\+\\+|--)\\s*\(escaped)(?![A-Za-z0-9_$])")
        guard assignments.count == declarations.count,
              !hasOtherBinding(of: name, declarations: declarations) else { return nil }
        let isVar = { (declaration: Range<Int>) in self.source[declaration.lowerBound] == "v" }
        if declarations.contains(where: isVar), declarations.count > 1 { return nil }

        let referenceBlocks = enclosingBraces(of: reference)
        // Scope key: the enclosing `{` position, or -1 for top level. Larger is more inner.
        var visible: [(scope: Int, valueStart: Int)] = []
        for declaration in declarations {
            let block = innermostBracket(enclosing: declaration.lowerBound)
            // Declarations inside `(...)` or `[...]` (for-loop headers, arguments) are not modeled.
            if let block, source[block] != "{" { return nil }
            if let block, !referenceBlocks.contains(block) {
                // `var` hoists out of blocks, so an unrelated block's `var` is still ambiguous.
                if isVar(declaration) { return nil }
                continue
            }
            // A later declaration in scope shadows or redeclares the name (TDZ at runtime).
            guard declaration.upperBound <= reference else { return nil }
            visible.append((block ?? -1, declaration.upperBound))
        }
        guard let innermost = visible.map(\.scope).max(),
              visible.filter({ $0.scope == innermost }).count == 1,
              let chosen = visible.first(where: { $0.scope == innermost }) else { return nil }
        var cursor = chosen.valueStart
        guard let value = concatenation(at: &cursor, depth: depth + 1),
              endsDeclaration(at: cursor) else { return nil }
        return value
    }

    /// Whether `name` is bound anywhere other than the given plain declarations.
    private func hasOtherBinding(of name: String, declarations: [Range<Int>]) -> Bool {
        let declaredNames = Set(declarations.map { declaration -> Int in
            var cursor = declaration.lowerBound
            _ = identifier(at: &cursor)
            while cursor < source.count, source[cursor].isWhitespace { cursor += 1 }
            return cursor
        })
        let escaped = NSRegularExpression.escapedPattern(for: name)
        for occurrence in codeMatches(of: "\(Self.boundary)\(escaped)(?![A-Za-z0-9_$])")
        where !declaredNames.contains(occurrence.lowerBound) {
            if ["function", "class", "const", "let", "var"].contains(previousWord(before: occurrence.lowerBound)) {
                return true
            }
            // Single-parameter arrow function: `name => ...`.
            if let next = significantIndex(from: occurrence.upperBound), next + 1 < source.count,
               source[next] == "=", source[next + 1] == ">" {
                return true
            }
            if enclosingBrackets(of: occurrence.lowerBound).contains(where: isBindingPattern) { return true }
        }
        return false
    }

    /// Brackets whose contents bind names: parameter lists, `catch` / `for` headers and
    /// destructuring patterns.
    private func isBindingPattern(open: Int) -> Bool {
        guard let close = partner[open] else { return false }
        let after = significantIndex(from: close + 1)
        let isFollowedByAssignment = after.map { index in
            index + 1 < source.count && source[index] == "=" && source[index + 1] != "="
        } ?? false
        if source[open] == "(" {
            let keyword = previousWord(before: open)
            if ["if", "while", "switch", "with"].contains(keyword) { return false }
            if ["for", "catch", "function"].contains(keyword) { return true }
            guard let after else { return false }
            // `(a, b) => ...`, `name(a) { ... }`, `function name(a) { ... }`.
            return isFollowedByAssignment && source[after + 1] == ">"
                || source[after] == "{" && !isPreceded(by: ["(", ",", "=", ":", "?", "[", "!", "&", "|"], at: open)
        }
        return isFollowedByAssignment
            || ["const", "let", "var"].contains(previousWord(before: open))
    }

    private func enclosingBrackets(of index: Int) -> [Int] {
        partner.filter { $0.key < index && $0.value > index }.map(\.key)
    }

    private func previousWord(before index: Int) -> String? {
        var end = index - 1
        while end >= 0, !isCode[end] || source[end].isWhitespace { end -= 1 }
        guard end >= 0, Self.isIdentifierPart(source[end]) else { return nil }
        var start = end
        while start > 0, isCode[start - 1], Self.isIdentifierPart(source[start - 1]) { start -= 1 }
        return String(source[start...end])
    }

    /// A declaration's initializer must end at `;`, `,`, `}`, `)`, end of input, or a line
    /// break before the next statement, so e.g. `const base = "x" || other` fails.
    private func endsDeclaration(at start: Int) -> Bool {
        var cursor = start
        var sawNewline = false
        while cursor < source.count, source[cursor].isWhitespace || !isCode[cursor] {
            if source[cursor].isNewline { sawNewline = true }
            cursor += 1
        }
        guard cursor < source.count else { return true }
        let character = source[cursor]
        if [";", ",", "}", ")"].contains(character) { return true }
        return sawNewline && Self.isIdentifierPart(character) && !character.isNumber
    }

    private func methodChain(on initial: String, at index: inout Int) -> String? {
        var value = initial
        while true {
            var lookahead = index
            skipTrivia(&lookahead)
            guard lookahead < source.count, source[lookahead] == "." else { return value }
            lookahead += 1
            skipTrivia(&lookahead)
            guard let method = identifier(at: &lookahead),
                  let arguments = callArguments(at: &lookahead),
                  let next = apply(method, arguments: arguments, to: value) else { return nil }
            value = next
            index = lookahead
        }
    }

    private func apply(_ method: String, arguments: [Argument], to value: String) -> String? {
        switch method {
        case "trim" where arguments.isEmpty:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case "trimEnd" where arguments.isEmpty, "trimRight" where arguments.isEmpty:
            return String(value.reversed().drop(while: \.isWhitespace).reversed())
        case "trimStart" where arguments.isEmpty, "trimLeft" where arguments.isEmpty:
            return String(value.drop(while: \.isWhitespace))
        case "toLowerCase" where arguments.isEmpty:
            return value.lowercased()
        case "toUpperCase" where arguments.isEmpty:
            return value.uppercased()
        case "replace", "replaceAll":
            guard arguments.count == 2, case .string(let replacement) = arguments[1] else { return nil }
            return replace(arguments[0], with: replacement, in: value, all: method == "replaceAll")
        default:
            return nil
        }
    }

    private func replace(
        _ pattern: Argument,
        with replacement: String,
        in value: String,
        all: Bool
    ) -> String? {
        switch pattern {
        case .string(let needle):
            guard !needle.isEmpty else { return nil }
            if all { return value.replacingOccurrences(of: needle, with: replacement) }
            guard let range = value.range(of: needle) else { return value }
            return value.replacingCharacters(in: range, with: replacement)
        case .regex(let body, let flags):
            var options: NSRegularExpression.Options = []
            if flags.contains("i") { options.insert(.caseInsensitive) }
            if flags.contains("m") { options.insert(.anchorsMatchLines) }
            if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
            guard let regex = try? NSRegularExpression(pattern: body, options: options) else { return nil }
            let replacement = Self.nsTemplate(fromJavaScript: replacement)
            let fullRange = NSRange(value.startIndex..., in: value)
            if all || flags.contains("g") {
                return regex.stringByReplacingMatches(in: value, range: fullRange, withTemplate: replacement)
            }
            guard let match = regex.firstMatch(in: value, range: fullRange) else { return value }
            let substitute = regex.replacementString(for: match, in: value, offset: 0, template: replacement)
            return (value as NSString).replacingCharacters(in: match.range, with: substitute)
        }
    }

    // MARK: - Lexing

    /// Skips whitespace plus `//` and `/* */` comments.
    private func skipTrivia(_ index: inout Int) {
        while index < source.count {
            let character = source[index]
            if character.isWhitespace {
                index += 1
            } else if character == "/", index + 1 < source.count, source[index + 1] == "/" {
                while index < source.count, !source[index].isNewline { index += 1 }
            } else if character == "/", index + 1 < source.count, source[index + 1] == "*" {
                index += 2
                while index + 1 < source.count, !(source[index] == "*" && source[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, source.count)
            } else {
                return
            }
        }
    }

    private func stringLiteral(at index: inout Int) -> String? {
        guard index < source.count else { return nil }
        let quote = source[index]
        var cursor = index + 1
        var result = ""
        while cursor < source.count {
            let character = source[cursor]
            if character == quote {
                index = cursor + 1
                return result
            }
            if character.isNewline { return nil }
            if character == "\\" {
                cursor += 1
                guard cursor < source.count else { return nil }
                result.append(unescaped(source[cursor]))
            } else {
                result.append(character)
            }
            cursor += 1
        }
        return nil
    }

    private func templateLiteral(at index: inout Int, depth: Int) -> String? {
        var cursor = index + 1
        var result = ""
        var chunk = ""
        while cursor < source.count {
            let character = source[cursor]
            if character == "`" {
                index = cursor + 1
                return result + substitutePlaceholders(in: chunk)
            }
            if character == "\\" {
                cursor += 1
                guard cursor < source.count else { return nil }
                chunk.append(unescaped(source[cursor]))
                cursor += 1
            } else if character == "$", cursor + 1 < source.count, source[cursor + 1] == "{" {
                result += substitutePlaceholders(in: chunk)
                chunk = ""
                cursor += 2
                guard let value = concatenation(at: &cursor, depth: depth) else { return nil }
                skipTrivia(&cursor)
                guard cursor < source.count, source[cursor] == "}" else { return nil }
                result += value
                cursor += 1
            } else {
                chunk.append(character)
                cursor += 1
            }
        }
        return nil
    }

    private func unescaped(_ character: Character) -> Character {
        switch character {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        default: return character
        }
    }

    private func identifier(at index: inout Int) -> String? {
        func isPart(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }
        guard index < source.count, isPart(source[index]), !source[index].isNumber else { return nil }
        var cursor = index
        while cursor < source.count, isPart(source[cursor]) { cursor += 1 }
        let name = String(source[index..<cursor])
        index = cursor
        return name
    }

    private func callArguments(at index: inout Int) -> [Argument]? {
        var cursor = index
        skipTrivia(&cursor)
        guard cursor < source.count, source[cursor] == "(" else { return nil }
        cursor += 1
        var arguments: [Argument] = []
        skipTrivia(&cursor)
        if cursor < source.count, source[cursor] == ")" {
            index = cursor + 1
            return arguments
        }
        while true {
            skipTrivia(&cursor)
            guard cursor < source.count else { return nil }
            switch source[cursor] {
            case "\"", "'":
                guard let literal = stringLiteral(at: &cursor) else { return nil }
                arguments.append(.string(substitutePlaceholders(in: literal)))
            case "`":
                guard let literal = templateLiteral(at: &cursor, depth: Self.maxResolutionDepth - 1) else { return nil }
                arguments.append(.string(literal))
            case "/":
                guard let regex = regexLiteral(at: &cursor) else { return nil }
                arguments.append(regex)
            default:
                return nil
            }
            skipTrivia(&cursor)
            guard cursor < source.count else { return nil }
            if source[cursor] == "," {
                cursor += 1
            } else if source[cursor] == ")" {
                index = cursor + 1
                return arguments
            } else {
                return nil
            }
        }
    }

    /// Reads `/pattern/flags`, tracking escapes and `[...]` classes so `/` inside them is kept.
    private func regexLiteral(at index: inout Int) -> Argument? {
        var cursor = index + 1
        var body = ""
        var inClass = false
        while cursor < source.count {
            let character = source[cursor]
            if character.isNewline { return nil }
            if character == "\\" {
                guard cursor + 1 < source.count else { return nil }
                body.append(character)
                body.append(source[cursor + 1])
                cursor += 2
                continue
            }
            if character == "[" { inClass = true }
            if character == "]" { inClass = false }
            if character == "/", !inClass { break }
            body.append(character)
            cursor += 1
        }
        guard cursor < source.count, !body.isEmpty else { return nil }
        cursor += 1
        var flags = ""
        while cursor < source.count, source[cursor].isLetter {
            flags.append(source[cursor])
            cursor += 1
        }
        index = cursor
        return .regex(pattern: body, flags: flags)
    }

    /// Maps JS replacement syntax (`$&`, `$$`, literal `\`) onto NSRegularExpression templates.
    private static func nsTemplate(fromJavaScript replacement: String) -> String {
        replacement
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$$", with: "\\$")
            .replacingOccurrences(of: "$&", with: "$0")
    }

    private func substitutePlaceholders(in text: String) -> String {
        placeholders.reduce(text) { result, entry in
            result.replacingOccurrences(of: "{{\(entry.key)}}", with: entry.value)
        }
    }
}
