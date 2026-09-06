import AppKit

/// Shared right-edge geometry for 快速切换 attributed titles.
///
/// `NSMenuItem` right-aligned tabs are absolute locations inside the title,
/// not "the current menu's trailing edge". A hardcoded 170pt tab therefore
/// stays put after a long provider name widens the submenu. Compute one tab
/// from the current name/summary widths, and ellipsize only when that tab
/// would exceed `maximumTabLocation`.
struct QuickSwitchTitleLayout: Equatable {
    static let minimumTabLocation: CGFloat = 170
    static let maximumTabLocation: CGFloat = 420
    static let nameSummaryGap: CGFloat = 16
    static let menuChromeWidth: CGFloat = 40

    let tabLocation: CGFloat
    let minimumMenuWidth: CGFloat
    let nameColumnWidth: CGFloat

    static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func make(nameWidths: [CGFloat], summaryWidths: [CGFloat]) -> QuickSwitchTitleLayout {
        let maxNameWidth = max(0, nameWidths.max() ?? 0)
        let maxSummaryWidth = max(0, summaryWidths.max() ?? 0)
        let desiredTab = maxNameWidth + nameSummaryGap + maxSummaryWidth
        let tabLocation = min(
            max(ceil(desiredTab), minimumTabLocation),
            maximumTabLocation
        )
        return QuickSwitchTitleLayout(
            tabLocation: tabLocation,
            minimumMenuWidth: tabLocation + menuChromeWidth,
            nameColumnWidth: max(0, tabLocation - nameSummaryGap - maxSummaryWidth)
        )
    }

    static func make(names: [String], summaries: [String], font: NSFont) -> QuickSwitchTitleLayout {
        make(
            nameWidths: names.map { width(of: $0, font: font) },
            summaryWidths: summaries.map { width(of: $0, font: font) }
        )
    }

    func shouldTruncateName(width: CGFloat) -> Bool {
        width > nameColumnWidth
    }

    static func truncatedName(_ name: String, fitting maxWidth: CGFloat, font: NSFont) -> String {
        if width(of: name, font: font) <= maxWidth {
            return name
        }
        let ellipsis = "…"
        guard width(of: ellipsis, font: font) < maxWidth else {
            return ellipsis
        }
        let characters = Array(name)
        var low = 0
        var high = characters.count
        var best = ellipsis
        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(characters.prefix(mid)) + ellipsis
            if width(of: candidate, font: font) <= maxWidth {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}
