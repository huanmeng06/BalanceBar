import AppKit

/// Table header cell that draws its title away from the column edge, where the header
/// separator sits. The stock `NSTableHeaderCell` leaves only ~2pt there, which looks cramped.
///
/// `horizontalInset` is the leading constant of the row's text field, so the title lines up
/// with the row text.
final class PaddedTableHeaderCell: NSTableHeaderCell {
    /// A borderless `NSTextField` draws its text 2pt inside its frame (measured against a plain
    /// string draw); the title adds the same so both start at the same x.
    static let textFieldTextPadding: CGFloat = 2

    var horizontalInset: CGFloat = 0

    /// Replaces each column's header cell, keeping its font. Call before setting titles.
    static func install(on columns: [NSTableColumn], horizontalInset: CGFloat) {
        for column in columns {
            let cell = PaddedTableHeaderCell(textCell: "")
            cell.font = column.headerCell.font
            cell.horizontalInset = horizontalInset
            column.headerCell = cell
        }
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: textColor ?? NSColor.headerTextColor,
            .paragraphStyle: paragraph,
        ]
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let inset = horizontalInset + Self.textFieldTextPadding
        let insetRect = rect.insetBy(dx: inset, dy: 0)
        let height = ceil((stringValue as NSString).size(withAttributes: titleAttributes).height)
        return NSRect(x: insetRect.minX, y: rect.midY - height / 2, width: max(0, insetRect.width), height: height)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        (stringValue as NSString).draw(
            with: titleRect(forBounds: cellFrame),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: titleAttributes
        )
    }
}
