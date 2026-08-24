import AppKit
import Foundation

struct ReleaseNotesManifestEntry: Decodable, Equatable {
    let files: [String: String]
}

struct ReleaseNotesManifest: Decodable, Equatable {
    let schemaVersion: Int
    let releases: [String: ReleaseNotesManifestEntry]
}

enum ReleaseNotesSource: Equatable {
    case bundled(locale: String)
    case githubRelease
    case unavailable
}

struct ReleaseNotesResolution: Equatable {
    let markdown: String?
    let source: ReleaseNotesSource
}

/// Reads only the checked-in release-notes contract and never treats a notes
/// file as HTML. The manifest is intentionally data-only so adding a locale
/// does not require changing this loader or the Markdown renderer.
final class ReleaseNotesStore {
    private let bundle: Bundle
    private let releaseNotesRootOverride: URL?

    init(bundle: Bundle = .main, releaseNotesRoot: URL? = nil) {
        self.bundle = bundle
        self.releaseNotesRootOverride = releaseNotesRoot
    }

    func resolve(
        version: AppSemanticVersion,
        language: AppLanguage,
        release: GitHubRelease?
    ) -> ReleaseNotesResolution {
        if let root = releaseNotesRoot,
           let manifest = loadManifest(at: root),
           manifest.schemaVersion == 1,
           let entry = manifest.releases[version.description] {
            for locale in localeCandidates(for: language) {
                guard let path = entry.files[locale],
                      let markdown = loadMarkdown(path: path, root: root) else {
                    continue
                }
                return ReleaseNotesResolution(
                    markdown: markdown,
                    source: .bundled(locale: locale)
                )
            }
        }

        if let body = release?.body?.trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty {
            return ReleaseNotesResolution(markdown: body, source: .githubRelease)
        }
        return ReleaseNotesResolution(markdown: nil, source: .unavailable)
    }

    private var releaseNotesRoot: URL? {
        if let releaseNotesRootOverride {
            return releaseNotesRootOverride
        }
        return bundle.url(forResource: "release-notes", withExtension: nil)
    }

    private func loadManifest(at root: URL) -> ReleaseNotesManifest? {
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(ReleaseNotesManifest.self, from: data)
    }

    private func loadMarkdown(path: String, root: URL) -> String? {
        guard let fileURL = safeURL(forRelativePath: path, root: root),
              fileURL.pathExtension.lowercased() == "md",
              let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func safeURL(forRelativePath path: String, root: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { return nil }

        let rootPath = root.standardizedFileURL.path
        let fileURL = root.appendingPathComponent(trimmed).standardizedFileURL
        guard fileURL.path == rootPath || fileURL.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return fileURL
    }

    private func localeCandidates(for language: AppLanguage) -> [String] {
        let resolved = AppLanguage.resolved(for: language, preferredLanguages: Locale.preferredLanguages)
        let locale = resolved.releaseNotesLocaleIdentifier
        let components = locale.split(separator: "-").map(String.init)
        var candidates = [locale]

        if components.count >= 2, components[1].count == 4 {
            candidates.append(components.prefix(2).joined(separator: "-"))
        }
        if let base = components.first {
            candidates.append(base)
        }
        candidates.append("en")

        var unique: [String] = []
        for candidate in candidates where !unique.contains(candidate) {
            unique.append(candidate)
        }
        return unique
    }
}

extension AppLanguage {
    var releaseNotesLocaleIdentifier: String {
        switch self {
        case .system:
            return AppLanguage.resolved.releaseNotesLocaleIdentifier
        case .simplifiedChinese:
            return "zh-Hans"
        case .traditionalChineseTaiwan:
            return "zh-Hant-TW"
        case .traditionalChineseHongKong:
            return "zh-Hant-HK"
        case .english:
            return "en"
        case .japanese:
            return "ja"
        case .korean:
            return "ko"
        case .spanish:
            return "es"
        case .german:
            return "de"
        }
    }
}

/// A deliberately small native Markdown subset for release notes. The
/// renderer builds attributed text directly, so HTML tags, javascript URLs,
/// and scripts are displayed as ordinary text rather than interpreted.
enum ReleaseNotesMarkdownRenderer {
    private struct MarkdownTable {
        let rows: [[String]]
        let alignments: [NSTextAlignment]
        let nextIndex: Int
    }

    static func render(markdown: String) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 14)
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineSpacing = 2
        baseParagraph.paragraphSpacing = 2
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: baseParagraph
        ]
        let output = NSMutableAttributedString()
        var inCodeFence = false

        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeFence.toggle()
                if index < lines.count - 1 {
                    output.append(NSAttributedString(string: "\n", attributes: baseAttributes))
                }
                index += 1
                continue
            }

            if inCodeFence {
                appendLine(
                    rawLine,
                    into: output,
                    attributes: codeAttributes(paragraph: baseParagraph),
                    addNewline: index < lines.count - 1
                )
                index += 1
                continue
            }

            if let table = tableParts(in: lines, startingAt: index) {
                appendTable(table, into: output, baseAttributes: baseAttributes)
                index = table.nextIndex
                continue
            }

            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if isHorizontalRule(rawLine) {
                appendHorizontalRule(into: output, baseAttributes: baseAttributes)
                index += 1
                continue
            }

            if let heading = headingParts(rawLine) {
                let paragraph = headingParagraphStyle(from: baseParagraph)
                let headingFont = NSFont.systemFont(
                    ofSize: max(15, 23 - CGFloat(heading.level * 2)),
                    weight: .semibold
                )
                var attributes = baseAttributes
                attributes[.font] = headingFont
                attributes[.paragraphStyle] = paragraph
                appendLine(
                    heading.content,
                    into: output,
                    attributes: attributes,
                    addNewline: index < lines.count - 1
                )
                index += 1
                continue
            }

            let list = listParts(rawLine)
            let content = list?.content ?? rawLine.trimmingCharacters(in: .whitespaces)
            var attributes = baseAttributes
            if let list {
                let paragraph = paragraphStyle(from: baseParagraph, spacing: 5)
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = 20
                attributes[.paragraphStyle] = paragraph
                appendInline("\(list.marker) ", into: output, attributes: attributes)
            }
            appendInline(content, into: output, attributes: attributes)
            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            index += 1
        }

        return output
    }

    private static func appendTable(
        _ table: MarkdownTable,
        into output: NSMutableAttributedString,
        baseAttributes: [NSAttributedString.Key: Any]
    ) {
        let columnCount = max(1, table.alignments.count)
        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false

        for (rowIndex, row) in table.rows.enumerated() {
            for columnIndex in 0..<columnCount {
                let block = NSTextTableBlock(
                    table: textTable,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setWidth(
                    1,
                    type: .absoluteValueType,
                    for: .border
                )
                block.setWidth(
                    4,
                    type: .absoluteValueType,
                    for: .padding
                )
                block.setBorderColor(NSColor.separatorColor)
                if rowIndex == 0 {
                    block.backgroundColor = NSColor.controlBackgroundColor
                }

                let sourceParagraph = baseAttributes[.paragraphStyle] as? NSParagraphStyle
                    ?? NSParagraphStyle.default
                let paragraph = paragraphStyle(from: sourceParagraph, spacing: 4)
                paragraph.paragraphSpacing = 0
                paragraph.alignment = rowIndex == 0
                    ? .center
                    : table.alignments[columnIndex]
                paragraph.textBlocks = [block]
                var attributes = baseAttributes
                attributes[.paragraphStyle] = paragraph
                if rowIndex == 0,
                   let font = baseAttributes[.font] as? NSFont {
                    attributes[.font] = NSFontManager.shared.convert(
                        font,
                        toHaveTrait: .boldFontMask
                    )
                }

                let cell = columnIndex < row.count ? row[columnIndex] : ""
                appendInline(cell, into: output, attributes: attributes)
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
    }

    private static func appendHorizontalRule(
        into output: NSMutableAttributedString,
        baseAttributes: [NSAttributedString.Key: Any]
    ) {
        let paragraph = paragraphStyle(
            from: baseAttributes[.paragraphStyle] as? NSParagraphStyle
                ?? NSParagraphStyle.default,
            spacing: 8
        )
        paragraph.paragraphSpacingBefore = 4
        paragraph.textBlocks = [bottomBorderTextBlock()]
        var attributes = baseAttributes
        attributes[.paragraphStyle] = paragraph
        output.append(NSAttributedString(string: " \n", attributes: attributes))
    }

    private static func headingParagraphStyle(
        from source: NSParagraphStyle
    ) -> NSMutableParagraphStyle {
        let paragraph = paragraphStyle(from: source, spacing: 8)
        paragraph.paragraphSpacingBefore = 8
        paragraph.textBlocks = [bottomBorderTextBlock()]
        return paragraph
    }

    private static func bottomBorderTextBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setContentWidth(
            100,
            type: .percentageValueType
        )
        block.setWidth(
            1,
            type: .absoluteValueType,
            for: .border
        )
        block.setBorderColor(NSColor.separatorColor, for: .minY)
        block.setWidth(
            8,
            type: .absoluteValueType,
            for: .padding,
            edge: .minY
        )
        return block
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let characters = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace }
        guard characters.count >= 3,
              let first = characters.first,
              ["-", "*", "_"].contains(first) else {
            return false
        }
        return characters.allSatisfy { $0 == first }
    }

    private static func tableParts(
        in lines: [String],
        startingAt index: Int
    ) -> MarkdownTable? {
        guard index + 1 < lines.count,
              let header = tableRowParts(lines[index]),
              let delimiter = tableRowParts(lines[index + 1]),
              !header.isEmpty,
              delimiter.count == header.count else {
            return nil
        }

        let alignments = delimiter.compactMap(tableDelimiterAlignment)
        guard alignments.count == delimiter.count else { return nil }

        let columnCount = header.count
        var rows = [header]
        var nextIndex = index + 2
        while nextIndex < lines.count,
              let row = tableRowParts(lines[nextIndex]),
              !row.isEmpty {
            rows.append(row + Array(repeating: "", count: max(0, columnCount - row.count)))
            nextIndex += 1
        }

        return MarkdownTable(
            rows: rows.map { $0 + Array(repeating: "", count: max(0, columnCount - $0.count)) },
            alignments: alignments,
            nextIndex: nextIndex
        )
    }

    private static func tableRowParts(_ line: String) -> [String]? {
        var cells = [String]()
        var current = ""
        var hasSeparator = false
        var inCodeSpan = false
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                current.append(character)
                continue
            }
            if character == "`" {
                inCodeSpan.toggle()
                current.append(character)
                continue
            }
            if character == "|", !inCodeSpan {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                hasSeparator = true
            } else {
                current.append(character)
            }
        }
        guard hasSeparator else { return nil }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func tableDelimiterAlignment(_ cell: String) -> NSTextAlignment? {
        var value = cell.trimmingCharacters(in: .whitespaces)
        let leftAligned = value.hasPrefix(":")
        let rightAligned = value.hasSuffix(":")
        if leftAligned { value.removeFirst() }
        if rightAligned, !value.isEmpty { value.removeLast() }
        value = value.trimmingCharacters(in: .whitespaces)
        guard value.count >= 3,
              value.allSatisfy({ $0 == "-" }) else {
            return nil
        }
        if leftAligned && rightAligned { return .center }
        if rightAligned { return .right }
        return .left
    }

    private static func appendLine(
        _ text: String,
        into output: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any],
        addNewline: Bool
    ) {
        output.append(NSAttributedString(string: text, attributes: attributes))
        if addNewline {
            output.append(NSAttributedString(string: "\n", attributes: attributes))
        }
    }

    private static func appendInline(
        _ text: String,
        into output: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if let token = matchingDelimitedToken(
                in: text,
                from: cursor,
                delimiter: "**"
            ) ?? matchingDelimitedToken(in: text, from: cursor, delimiter: "__") {
                var boldAttributes = attributes
                if let font = attributes[.font] as? NSFont {
                    boldAttributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                appendInline(token.content, into: output, attributes: boldAttributes)
                cursor = token.end
                continue
            }

            if text[cursor] == "`",
               let end = text.range(of: "`", range: text.index(after: cursor)..<text.endIndex) {
                let content = String(text[text.index(after: cursor)..<end.lowerBound])
                var codeAttributes = attributes
                codeAttributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                codeAttributes[.backgroundColor] = NSColor.controlBackgroundColor
                output.append(NSAttributedString(string: content, attributes: codeAttributes))
                cursor = end.upperBound
                continue
            }

            if text[cursor] == "[",
               let link = validLink(in: text, from: cursor) {
                let start = output.length
                appendInline(link.label, into: output, attributes: attributes)
                let range = NSRange(location: start, length: output.length - start)
                output.addAttributes([
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: link.url
                ], range: range)
                cursor = link.end
                continue
            }

            let next = text.index(after: cursor)
            output.append(NSAttributedString(string: String(text[cursor..<next]), attributes: attributes))
            cursor = next
        }
    }

    private static func matchingDelimitedToken(
        in text: String,
        from start: String.Index,
        delimiter: String
    ) -> (content: String, end: String.Index)? {
        guard text[start...].hasPrefix(delimiter) else { return nil }
        let contentStart = text.index(start, offsetBy: delimiter.count)
        guard contentStart < text.endIndex,
              let closing = text.range(of: delimiter, range: contentStart..<text.endIndex),
              closing.lowerBound > contentStart else { return nil }
        return (
            String(text[contentStart..<closing.lowerBound]),
            closing.upperBound
        )
    }

    private static func validLink(
        in text: String,
        from start: String.Index
    ) -> (label: String, url: URL, end: String.Index)? {
        let labelStart = text.index(after: start)
        guard let labelEnd = text.range(of: "](", range: labelStart..<text.endIndex),
              labelEnd.lowerBound > labelStart,
              let urlEnd = text.range(of: ")", range: labelEnd.upperBound..<text.endIndex)
        else { return nil }

        let rawURL = String(text[labelEnd.upperBound..<urlEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host != nil else { return nil }
        return (
            String(text[labelStart..<labelEnd.lowerBound]),
            url,
            urlEnd.upperBound
        )
    }

    private static func headingParts(_ line: String) -> (level: Int, content: String)? {
        let leadingTrimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        var level = 0
        for character in leadingTrimmed {
            guard character == "#", level < 6 else { break }
            level += 1
        }
        guard level > 0 else { return nil }
        let afterHashes = leadingTrimmed.dropFirst(level)
        guard afterHashes.first == " " || afterHashes.first == "\t" else { return nil }
        let content = afterHashes
            .drop(while: { $0 == " " || $0 == "\t" })
            .trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : (level, content)
    }

    private static func listParts(_ line: String) -> (marker: String, content: String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first else { return nil }
        if ["-", "*", "+"].contains(first) {
            let remainder = trimmed.dropFirst()
            guard remainder.first == " " || remainder.first == "\t" else { return nil }
            return ("•", remainder.drop(while: { $0 == " " || $0 == "\t" }).description)
        }

        var digits = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber {
            digits.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        guard !digits.isEmpty, index < trimmed.endIndex,
              trimmed[index] == "." || trimmed[index] == ")" else { return nil }
        index = trimmed.index(after: index)
        guard index < trimmed.endIndex,
              trimmed[index] == " " || trimmed[index] == "\t" else { return nil }
        let content = trimmed[index...].drop(while: { $0 == " " || $0 == "\t" })
        return ("\(digits).", content.description)
    }

    private static func paragraphStyle(
        from source: NSParagraphStyle,
        spacing: CGFloat
    ) -> NSMutableParagraphStyle {
        let paragraph = source.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraph.paragraphSpacing = spacing
        return paragraph
    }

    private static func codeAttributes(
        paragraph: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        let codeParagraph = paragraph.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        codeParagraph.paragraphSpacing = 4
        return [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.controlBackgroundColor,
            .paragraphStyle: codeParagraph
        ]
    }
}
