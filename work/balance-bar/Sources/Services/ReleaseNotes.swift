import AppKit
import Foundation

enum ReleaseNotesSource: Equatable {
    case githubRelease
    case unavailable
}

struct ReleaseNotesResolution: Equatable {
    let markdown: String?
    let source: ReleaseNotesSource
}

/// Resolves the complete bilingual Markdown body returned by GitHub. Release
/// notes are deliberately not bundled with the app: the GitHub Release body
/// is the single source of truth for the update notes window.
final class ReleaseNotesStore {
    func resolve(release: GitHubRelease?) -> ReleaseNotesResolution {
        if let body = release?.body?.trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty {
            return ReleaseNotesResolution(markdown: body, source: .githubRelease)
        }
        return ReleaseNotesResolution(markdown: nil, source: .unavailable)
    }
}

func releaseNotesPixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    (value * scale).rounded() / scale
}

func releaseNotesPixelAlignedRect(_ rect: NSRect, scale: CGFloat) -> NSRect {
    let minX = releaseNotesPixelAligned(rect.minX, scale: scale)
    let minY = releaseNotesPixelAligned(rect.minY, scale: scale)
    let maxX = releaseNotesPixelAligned(rect.maxX, scale: scale)
    let maxY = releaseNotesPixelAligned(rect.maxY, scale: scale)
    return NSRect(
        x: minX,
        y: minY,
        width: max(0, maxX - minX),
        height: max(0, maxY - minY)
    )
}

private func releaseNotesBackingScale(for view: NSView) -> CGFloat {
    max(1, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
}

let releaseNotesBlockSpacing: CGFloat = 20

struct ReleaseNotesAppearanceColors {
    let tableGrid: NSColor

    static func resolved(for appearance: NSAppearance) -> ReleaseNotesAppearanceColors {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return ReleaseNotesAppearanceColors(
                tableGrid: NSColor.white.withAlphaComponent(0.32)
            )
        }
        return ReleaseNotesAppearanceColors(
            tableGrid: NSColor.black.withAlphaComponent(0.30)
        )
    }
}

final class ReleaseNotesTableCellBlock: NSTextTableBlock {
    let rowIndex: Int
    let columnIndex: Int
    let rowCount: Int
    let columnCount: Int
    let isHeader: Bool

    var drawsOuterLeftEdge: Bool { columnIndex == 0 }
    var drawsOuterRightEdge: Bool { columnIndex == columnCount - 1 }
    var drawsOuterTopEdge: Bool { rowIndex == 0 }
    var drawsOuterBottomEdge: Bool { rowIndex == rowCount - 1 }
    var drawsInternalRightEdge: Bool { columnIndex < columnCount - 1 }
    var drawsInternalBottomEdge: Bool { rowIndex < rowCount - 1 }

    init(
        table: NSTextTable,
        rowIndex: Int,
        columnIndex: Int,
        rowCount: Int,
        columnCount: Int,
        isHeader: Bool
    ) {
        self.rowIndex = rowIndex
        self.columnIndex = columnIndex
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.isHeader = isHeader
        super.init(
            table: table,
            startingRow: rowIndex,
            rowSpan: 1,
            startingColumn: columnIndex,
            columnSpan: 1
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawBackground(
        withFrame frameRect: NSRect,
        in controlView: NSView,
        characterRange: NSRange,
        layoutManager: NSLayoutManager
    ) {
        let scale = releaseNotesBackingScale(for: controlView)
        let lineWidth = 1 / scale
        let snappedFrame = releaseNotesPixelAlignedRect(frameRect, scale: scale)
        let left = snappedFrame.minX
        let right = snappedFrame.maxX
        let bottom = snappedFrame.minY
        let top = snappedFrame.maxY
        let width = max(lineWidth, right - left)
        let height = max(lineWidth, top - bottom)
        let colors = ReleaseNotesAppearanceColors.resolved(for: controlView.effectiveAppearance)

        if isHeader {
            NSColor.controlBackgroundColor.withAlphaComponent(0.72).setFill()
            NSRect(
                x: left + lineWidth,
                y: bottom + lineWidth,
                width: max(lineWidth, width - lineWidth * 2),
                height: max(lineWidth, height - lineWidth * 2)
            ).fill()
        }

        colors.tableGrid.setFill()

        func horizontal(_ y: CGFloat) {
            NSRect(x: left, y: y, width: width, height: lineWidth).fill()
        }

        func vertical(_ x: CGFloat) {
            NSRect(x: x, y: bottom, width: lineWidth, height: height).fill()
        }

        horizontal(bottom)
        if drawsInternalBottomEdge || drawsOuterBottomEdge {
            horizontal(top - lineWidth)
        }
        vertical(right - lineWidth)
        if drawsOuterLeftEdge {
            vertical(left)
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
                let closesCodeFence = index + 1 < lines.count &&
                    lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("```")
                let codeSpacing = closesCodeFence && headingFollows(
                    in: lines,
                    startingAt: index + 2
                ) ? releaseNotesBlockSpacing : 4
                appendLine(
                    rawLine,
                    into: output,
                    attributes: codeAttributes(paragraph: baseParagraph, spacing: codeSpacing),
                    addNewline: index < lines.count - 1
                )
                index += 1
                continue
            }

            if let table = tableParts(in: lines, startingAt: index) {
                appendTable(
                    table,
                    into: output,
                    baseAttributes: baseAttributes,
                    addsFollowingBlockSpacing: hasFollowingBlock(in: lines, startingAt: table.nextIndex)
                )
                index = table.nextIndex
                continue
            }

            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if isHorizontalRule(rawLine) {
                index += 1
                continue
            }

            if let heading = headingParts(rawLine) {
                let paragraph = paragraphStyle(
                    from: baseParagraph,
                    spacing: headingFollows(in: lines, startingAt: index + 1)
                        ? releaseNotesBlockSpacing
                        : 10
                )
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
                let nextBlockLine = nextBlockLine(in: lines, startingAt: index + 1)
                let closesListBeforeBlock = nextBlockLine.map { listParts($0) == nil } ?? false
                let paragraph = paragraphStyle(
                    from: baseParagraph,
                    spacing: closesListBeforeBlock ? releaseNotesBlockSpacing : 5
                )
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = 20
                attributes[.paragraphStyle] = paragraph
                appendInline("\(list.marker) ", into: output, attributes: attributes)
            } else {
                attributes[.paragraphStyle] = paragraphStyle(
                    from: baseParagraph,
                    spacing: headingFollows(in: lines, startingAt: index + 1)
                        ? releaseNotesBlockSpacing
                        : 2
                )
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
        baseAttributes: [NSAttributedString.Key: Any],
        addsFollowingBlockSpacing: Bool
    ) {
        let columnCount = max(1, table.alignments.count)
        let rowCount = max(1, table.rows.count)
        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.setContentWidth(100, type: .percentageValueType)
        textTable.setValue(100, type: .percentageValueType, for: .maximumWidth)
        textTable.collapsesBorders = false
        textTable.hidesEmptyCells = false

        for (rowIndex, row) in table.rows.enumerated() {
            for columnIndex in 0..<columnCount {
                let block = ReleaseNotesTableCellBlock(
                    table: textTable,
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    rowCount: rowCount,
                    columnCount: columnCount,
                    isHeader: rowIndex == 0
                )
                block.setWidth(
                    4,
                    type: .absoluteValueType,
                    for: .padding
                )
                block.setWidth(0, type: .absoluteValueType, for: .border)
                block.setWidth(0, type: .absoluteValueType, for: .margin)

                let sourceParagraph = baseAttributes[.paragraphStyle] as? NSParagraphStyle
                    ?? NSParagraphStyle.default
                let paragraph = paragraphStyle(from: sourceParagraph, spacing: 4)
                paragraph.paragraphSpacing = rowIndex == rowCount - 1 && addsFollowingBlockSpacing
                    ? releaseNotesBlockSpacing
                    : 0
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

    private static func hasFollowingBlock(in lines: [String], startingAt index: Int) -> Bool {
        nextBlockLine(in: lines, startingAt: index) != nil
    }

    private static func headingFollows(in lines: [String], startingAt index: Int) -> Bool {
        guard let nextLine = nextBlockLine(in: lines, startingAt: index) else { return false }
        return headingParts(nextLine) != nil
    }

    private static func nextBlockLine(in lines: [String], startingAt index: Int) -> String? {
        guard index < lines.count else { return nil }
        for line in lines[index...] {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if isHorizontalRule(line) {
                continue
            }
            return line
        }
        return nil
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
        paragraph: NSParagraphStyle,
        spacing: CGFloat = 4
    ) -> [NSAttributedString.Key: Any] {
        let codeParagraph = paragraph.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        codeParagraph.paragraphSpacing = spacing
        return [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.controlBackgroundColor,
            .paragraphStyle: codeParagraph
        ]
    }
}
