import AppKit

/// Table header cell that draws its title away from the column edge, where the header
/// separator sits. The stock `NSTableHeaderCell` leaves only ~2pt there, which looks cramped.
///
/// `horizontalInset` is the leading constant of the row's text field, so the title lines up
/// with the row text. That constant pins the field's alignment rect, which already sits where
/// its text starts (the frame extends 2pt further out and the text is drawn 2pt in), so no
/// extra padding is added here.
final class PaddedTableHeaderCell: NSTableHeaderCell {
    var horizontalInset: CGFloat = 0

    /// How far the column's row cells start inside the column rect. A `.fullWidth` table pads
    /// its first column's cells (6pt on macOS 26) while the header rect starts at the column
    /// edge, so without this the first header title sits left of the row text. Read from the
    /// table while it has rows and kept for when it is empty, so the title doesn't jump.
    private var cellLeadingOffset: CGFloat = 0

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
        var insetRect = rect.insetBy(dx: horizontalInset, dy: 0)
        insetRect.origin.x += cellLeadingOffset
        insetRect.size.width -= cellLeadingOffset
        let height = ceil((stringValue as NSString).size(withAttributes: titleAttributes).height)
        return NSRect(x: insetRect.minX, y: rect.midY - height / 2, width: max(0, insetRect.width), height: height)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        updateCellLeadingOffset(headerFrame: cellFrame, in: controlView)
        (stringValue as NSString).draw(
            with: titleRect(forBounds: cellFrame),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: titleAttributes
        )
    }

    private func updateCellLeadingOffset(headerFrame: NSRect, in controlView: NSView) {
        guard let headerView = controlView as? NSTableHeaderView,
              let tableView = headerView.tableView,
              tableView.numberOfRows > 0 else { return }
        let column = headerView.column(at: NSPoint(x: headerFrame.midX, y: headerFrame.midY))
        guard column >= 0 else { return }
        let cellFrame = tableView.frameOfCell(atColumn: column, row: 0)
        guard !cellFrame.isEmpty else { return }
        cellLeadingOffset = max(0, cellFrame.minX - tableView.rect(ofColumn: column).minX)
    }
}
