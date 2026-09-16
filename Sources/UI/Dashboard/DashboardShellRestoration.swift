import AppKit

/// Dedicated Dashboard shell geometry identity and the small explicit state
/// AppKit cannot honor on its own: windowed-frame isolation, sidebar clamp,
/// collapse, and off-screen correction.
enum DashboardShellRestoration {
    static let identity = "BalanceBar.Dashboard"
    static let frameAutosaveName = NSWindow.FrameAutosaveName(identity)
    static let userDefaultsKey = "BalanceBar.Dashboard.shellGeometry"
    static let defaultContentSize = NSSize(width: 880, height: 620)
    static let minimumWindowSize = NSSize(width: 800, height: 540)

    static var defaultSidebarWidth: CGFloat {
        DashboardSplitViewController.preferredSidebarThickness
    }

    static var minimumSidebarWidth: CGFloat {
        DashboardSplitViewController.minimumSidebarThickness
    }

    static var maximumSidebarWidth: CGFloat {
        DashboardSplitViewController.maximumSidebarThickness
    }
}

struct DashboardShellRestorationState: Equatable {
    var windowedFrame: NSRect
    var sidebarWidth: CGFloat
    var isSidebarCollapsed: Bool
}

struct DashboardShellRestorationRecord: Equatable {
    var windowedFrame: NSRect?
    var sidebarWidth: CGFloat?
    var isSidebarCollapsed: Bool?
}

/// Window placement is decided from the explicit Dashboard store, never from
/// `NSWindow.setFrameAutosaveName`'s Bool (that value only means the name
/// could be registered).
enum DashboardShellFramePlacement: Equatable {
    case defaultCentered
    case restored(NSRect)
}

protocol DashboardShellRestorationStoring: AnyObject {
    func load() -> DashboardShellRestorationRecord?
    func save(_ state: DashboardShellRestorationState)
}

final class MemoryDashboardShellRestorationStore: DashboardShellRestorationStoring {
    private var record: DashboardShellRestorationRecord?

    init(record: DashboardShellRestorationRecord? = nil) {
        self.record = record
    }

    func load() -> DashboardShellRestorationRecord? {
        record
    }

    func save(_ state: DashboardShellRestorationState) {
        record = DashboardShellRestoration.encode(state)
    }
}

final class UserDefaultsDashboardShellRestorationStore: DashboardShellRestorationStoring {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = DashboardShellRestoration.userDefaultsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> DashboardShellRestorationRecord? {
        DashboardShellRestoration.decode(defaults.object(forKey: key))
    }

    func save(_ state: DashboardShellRestorationState) {
        defaults.set(DashboardShellRestoration.propertyList(from: state), forKey: key)
    }
}

enum DashboardShellRestorationFieldPriority: Int, Comparable {
    case defaultGeometry = 0
    case savedSidebarWidth = 1
    case savedCollapsedState = 2
    case savedWindowedFrame = 3
    case sidebarClamp = 4
    case visibleScreenCorrection = 5
    case fullscreenIsolation = 6

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension DashboardShellRestoration {
    static func makeDefaultStore() -> DashboardShellRestorationStoring {
        if AutomatedTestHost.isRunning {
            return MemoryDashboardShellRestorationStore()
        }
        return UserDefaultsDashboardShellRestorationStore()
    }

    static func encode(_ state: DashboardShellRestorationState) -> DashboardShellRestorationRecord {
        DashboardShellRestorationRecord(
            windowedFrame: state.windowedFrame,
            sidebarWidth: state.sidebarWidth,
            isSidebarCollapsed: state.isSidebarCollapsed
        )
    }

    static func propertyList(from state: DashboardShellRestorationState) -> [String: Any] {
        [
            "windowedFrame": [
                state.windowedFrame.origin.x,
                state.windowedFrame.origin.y,
                state.windowedFrame.size.width,
                state.windowedFrame.size.height
            ],
            "sidebarWidth": state.sidebarWidth,
            "isSidebarCollapsed": state.isSidebarCollapsed
        ]
    }

    static func decode(_ object: Any?) -> DashboardShellRestorationRecord? {
        guard let dictionary = object as? [String: Any] else { return nil }
        let frame = rect(from: dictionary["windowedFrame"])
        let width = cgFloat(from: dictionary["sidebarWidth"])
        let collapsed = dictionary["isSidebarCollapsed"] as? Bool
        if frame == nil, width == nil, collapsed == nil {
            return nil
        }
        return DashboardShellRestorationRecord(
            windowedFrame: frame,
            sidebarWidth: width,
            isSidebarCollapsed: collapsed
        )
    }

    static func clampSidebarWidth(
        _ width: CGFloat,
        minimum: CGFloat = minimumSidebarWidth,
        maximum: CGFloat = maximumSidebarWidth,
        fallback: CGFloat = defaultSidebarWidth
    ) -> CGFloat {
        guard width.isFinite else { return fallback }
        return min(maximum, max(minimum, width))
    }

    /// Fullscreen frames never replace the last windowed frame.
    static func persistedWindowedFrame(
        currentFrame: NSRect,
        isFullScreen: Bool,
        previouslySavedFrame: NSRect?
    ) -> NSRect? {
        if isFullScreen {
            return previouslySavedFrame
        }
        guard isUsableFrame(currentFrame) else {
            return previouslySavedFrame
        }
        return currentFrame
    }

    static func plan(
        saved: DashboardShellRestorationRecord?,
        defaultFrame: NSRect,
        screens: [NSRect],
        minSize: NSSize = minimumWindowSize,
        defaultSidebarWidth: CGFloat = defaultSidebarWidth,
        minimumSidebarWidth: CGFloat = minimumSidebarWidth,
        maximumSidebarWidth: CGFloat = maximumSidebarWidth
    ) -> DashboardShellRestorationState {
        let frame: NSRect
        switch framePlacement(
            saved: saved,
            defaultFrame: defaultFrame,
            screens: screens,
            minSize: minSize
        ) {
        case .restored(let restoredFrame):
            frame = restoredFrame
        case .defaultCentered:
            frame = defaultFrame
        }
        let rawWidth = saved?.sidebarWidth ?? defaultSidebarWidth
        let width = clampSidebarWidth(
            rawWidth,
            minimum: minimumSidebarWidth,
            maximum: maximumSidebarWidth,
            fallback: defaultSidebarWidth
        )
        return DashboardShellRestorationState(
            windowedFrame: frame,
            sidebarWidth: width,
            isSidebarCollapsed: saved?.isSidebarCollapsed ?? false
        )
    }

    /// Decide window placement from the explicit Dashboard store.
    /// An empty store, or a record without a usable windowed frame, keeps the
    /// original first-open centered geometry. AppKit autosave-name
    /// registration is not an input.
    static func framePlacement(
        saved: DashboardShellRestorationRecord?,
        defaultFrame: NSRect,
        screens: [NSRect],
        minSize: NSSize = minimumWindowSize
    ) -> DashboardShellFramePlacement {
        guard let savedFrame = saved?.windowedFrame, isUsableFrame(savedFrame) else {
            return .defaultCentered
        }
        return .restored(
            visibleFrame(savedFrame, screens: screens, minSize: minSize, fallback: defaultFrame)
        )
    }

    static func visibleFrame(
        _ frame: NSRect,
        screens: [NSRect],
        minSize: NSSize,
        fallback: NSRect
    ) -> NSRect {
        let candidate = isUsableFrame(frame) ? frame : fallback
        guard let screen = targetScreen(for: candidate, screens: screens) else {
            var result = candidate
            result.size.width = max(result.width, minSize.width)
            result.size.height = max(result.height, minSize.height)
            return result
        }
        return fit(candidate, onto: screen, minSize: minSize)
    }

    static func isFullyContained(_ frame: NSRect, in screen: NSRect) -> Bool {
        frame.width <= screen.width
            && frame.height <= screen.height
            && frame.minX >= screen.minX
            && frame.maxX <= screen.maxX
            && frame.minY >= screen.minY
            && frame.maxY <= screen.maxY
    }

    static func currentScreens() -> [NSRect] {
        NSScreen.screens.map(\.visibleFrame)
    }

    private static func isUsableFrame(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.size.width.isFinite
            && frame.size.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    /// Size and origin are clamped so the result lies entirely inside `screen`.
    /// `minSize` is honored only when the screen is large enough; a smaller
    /// screen is the hard upper bound.
    private static func fit(_ frame: NSRect, onto screen: NSRect, minSize: NSSize) -> NSRect {
        var result = frame
        let minWidth = min(minSize.width, screen.width)
        let minHeight = min(minSize.height, screen.height)
        result.size.width = min(max(result.width, minWidth), screen.width)
        result.size.height = min(max(result.height, minHeight), screen.height)
        if result.maxX > screen.maxX {
            result.origin.x = screen.maxX - result.width
        }
        if result.minX < screen.minX {
            result.origin.x = screen.minX
        }
        if result.maxY > screen.maxY {
            result.origin.y = screen.maxY - result.height
        }
        if result.minY < screen.minY {
            result.origin.y = screen.minY
        }
        return result
    }

    private static func targetScreen(for frame: NSRect, screens: [NSRect]) -> NSRect? {
        guard !screens.isEmpty else { return nil }
        let ranked = screens.map { screen in
            (screen, area(frame.intersection(screen)))
        }
        if let best = ranked.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return best.0
        }
        return screens.first
    }

    private static func area(_ rect: NSRect) -> CGFloat {
        guard rect.width > 0, rect.height > 0 else { return 0 }
        return rect.width * rect.height
    }

    private static func rect(from object: Any?) -> NSRect? {
        guard let values = object as? [Any], values.count == 4,
              let x = cgFloat(from: values[0]),
              let y = cgFloat(from: values[1]),
              let width = cgFloat(from: values[2]),
              let height = cgFloat(from: values[3])
        else { return nil }
        let frame = NSRect(x: x, y: y, width: width, height: height)
        return isUsableFrame(frame) ? frame : nil
    }

    private static func cgFloat(from object: Any?) -> CGFloat? {
        if let number = object as? NSNumber {
            let value = CGFloat(truncating: number)
            return value.isFinite ? value : nil
        }
        if let value = object as? CGFloat, value.isFinite {
            return value
        }
        if let value = object as? Double, value.isFinite {
            return CGFloat(value)
        }
        if let value = object as? Int {
            return CGFloat(value)
        }
        return nil
    }
}
