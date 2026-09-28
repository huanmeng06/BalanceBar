import Foundation

/// Extracts the request contract from a CC Switch usage script without running JavaScript.
///
/// `request.url` is evaluated with a small JavaScript subset: string and template literals,
/// `+` concatenation, parentheses, `const` / `let` / `var` identifiers, and
/// `.replace` / `.replaceAll` / `.trim*` / case-conversion calls. `{{placeholder}}` tokens in
/// literals are substituted before evaluation, matching CC Switch's own template injection.
/// `method` is read the same way. `headers` and `extractor` are not interpreted:
/// BalanceAPIClient still sends its own Bearer headers and BalanceResponseParser reads the
/// response body.
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
        let evaluator = UsageScriptExpressionEvaluator(
            source: Array(code),
            placeholders: placeholders
        )
        guard let url = evaluator.firstValue(forKey: "url"), !url.isEmpty else { return nil }
        let method = evaluator.firstValue(forKey: "method").map { $0.uppercased() }
        return ParsedRequest(urlTemplate: url, method: method, headers: [:])
    }
}

private struct UsageScriptExpressionEvaluator {
    private enum Argument {
        case string(String)
        case regex(pattern: String, flags: String)
    }

    private static let maxResolutionDepth = 8

    let source: [Character]
    let placeholders: [String: String]
    /// `false` for characters inside comments or string/template literal bodies.
    private let isCode: [Bool]

    init(source: [Character], placeholders: [String: String]) {
        self.source = source
        self.placeholders = placeholders
        self.isCode = Self.codeMask(for: source)
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
            } else {
                index += 1
            }
        }
        return mask
    }

    func firstValue(forKey key: String) -> String? {
        for start in valueStarts(forKey: key) {
            var index = start
            if let value = concatenation(at: &index, depth: 0) { return value }
        }
        return nil
    }

    // MARK: - Locating keys and declarations

    /// Matches `url:`, `"url":` and `'url':`, but not `baseUrl:` or `response.url`.
    private func valueStarts(forKey key: String) -> [Int] {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        return matchEnds(of: "(?<![A-Za-z0-9_$.])([\"']?)\(escaped)\\1\\s*:")
    }

    private func declarationStarts(of name: String) -> [Int] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return matchEnds(of: "(?<![A-Za-z0-9_$.])(?:const|let|var)\\s+\(escaped)\\s*=(?!=)")
    }

    private func matchEnds(of pattern: String) -> [Int] {
        let text = String(source)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            guard start < isCode.count, isCode[start] else { return nil }
            return text.distance(from: text.startIndex, to: range.upperBound)
        }
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
            guard let name = identifier(at: &index),
                  let resolved = resolve(identifier: name, depth: depth) else { return nil }
            value = resolved
        }
        return methodChain(on: value, at: &index)
    }

    private func resolve(identifier name: String, depth: Int) -> String? {
        guard depth < Self.maxResolutionDepth else { return nil }
        for start in declarationStarts(of: name) {
            var cursor = start
            if let value = concatenation(at: &cursor, depth: depth + 1) { return value }
        }
        return nil
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

    private func substitutePlaceholders(in text: String) -> String {
        placeholders.reduce(text) { result, entry in
            result.replacingOccurrences(of: "{{\(entry.key)}}", with: entry.value)
        }
    }
}
