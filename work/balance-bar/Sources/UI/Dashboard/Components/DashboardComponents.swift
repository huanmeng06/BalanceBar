import AppKit

var dashboardUsesDarkAppearance: Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

func dashboardAdaptiveColor(light: NSColor, dark: NSColor) -> NSColor {
    dashboardUsesDarkAppearance ? dark : light
}

final class DashboardNavigationRowView: NSView {
    weak var iconView: NSImageView?
    weak var titleLabel: NSTextField?

    var isSelected = false {
        didSet { updateAppearance(animated: true) }
    }

    private var isHovered = false
    private var trackingAreaReference: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance(animated: true)
    }

    func updateAppearance(animated: Bool) {
        let backgroundColor: NSColor
        if isSelected {
            backgroundColor = dashboardAdaptiveColor(
                light: NSColor.systemBlue.withAlphaComponent(0.11),
                dark: NSColor.white.withAlphaComponent(0.12)
            )
        } else if isHovered {
            backgroundColor = dashboardAdaptiveColor(
                light: NSColor.systemBlue.withAlphaComponent(0.055),
                dark: NSColor.white.withAlphaComponent(0.075)
            )
        } else {
            backgroundColor = .clear
        }
        let foregroundColor: NSColor = isSelected
            ? .controlAccentColor
            : (isHovered ? .labelColor : .secondaryLabelColor)

        let changes = {
            self.layer?.backgroundColor = backgroundColor.cgColor
            self.iconView?.contentTintColor = foregroundColor
            self.titleLabel?.textColor = foregroundColor
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                changes()
            }
        } else {
            changes()
        }
    }
}

final class QuotaProgressView: NSView {
    let percentage: Double

    init(percentage: Double) {
        self.percentage = min(100, max(0, percentage))
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        let radius = track.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let width = track.width * CGFloat(percentage / 100)
        guard width > 0 else { return }
        let fill = NSRect(x: track.minX, y: track.minY, width: max(track.height, width), height: track.height)
        Self.progressColor(for: percentage).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    static func progressColor(for percentage: Double) -> NSColor {
        switch percentage {
        case let value where value > 50: return .systemGreen
        case 25...50: return .systemYellow
        case 10..<25: return .systemOrange
        default: return .systemRed
        }
    }
}

final class MenuItemContentView: NSView {
    var onMenuWindowChanged: ((NSWindow?) -> Void)?

    private weak var menuLink: HoverLinkTextField?
    private weak var menuWindow: NSWindow?
    private var menuWindowAcceptedMouseMovedEvents: Bool?
    private var mouseTrackingAreaReference: NSTrackingArea?
    private var mouseEntryTrackingAreaReference: NSTrackingArea?
    private var cursorTrackingAreaReference: NSTrackingArea?

    func installMenuLink(_ link: HoverLinkTextField) {
        removeMenuTrackingAreas()
        menuLink = link
        installMenuTrackingAreas()
        enableMenuWindowMouseMovedEventsIfNeeded()
        window?.invalidateCursorRects(for: self)
    }

    func refreshMenuLinkTrackingArea() {
        guard menuLink != nil else { return }
        removeMenuTrackingAreas()
        installMenuTrackingAreas()
        enableMenuWindowMouseMovedEventsIfNeeded()
        window?.invalidateCursorRects(for: self)
    }

    func prepareForMenuTracking() {
        guard menuLink != nil else { return }
        updateTrackingAreas()
        enableMenuWindowMouseMovedEventsIfNeeded()
        window?.invalidateCursorRects(for: self)
        onMenuWindowChanged?(window)
    }

    func removeMenuLink(_ link: HoverLinkTextField) {
        guard menuLink === link else { return }
        menuLink = nil
        removeMenuTrackingAreas()
        restoreMenuWindowMouseMovedEvents()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        removeMenuTrackingAreas()
        super.updateTrackingAreas()
        installMenuTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        if let menuWindow, menuWindow !== window {
            restoreMenuWindowMouseMovedEvents()
        }
        super.viewDidMoveToWindow()
        if menuLink != nil {
            updateTrackingAreas()
        }
        enableMenuWindowMouseMovedEventsIfNeeded()
        window?.invalidateCursorRects(for: self)
        onMenuWindowChanged?(window)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let menuLink else { return }
        let cursorRect = convert(menuLink.visibleTextHitRect, from: menuLink)
        guard !cursorRect.isEmpty else { return }
        addCursorRect(cursorRect, cursor: .pointingHand)
        if let window {
            let screenPoint = NSEvent.mouseLocation
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            menuLink.handleMenuMouseMoved(at: convert(windowPoint, from: nil), in: self)
        } else {
            menuLink.reassertMenuCursor()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        menuLink?.handleMenuMouseEntered(with: event, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        menuLink?.handleMenuExited()
    }

    override func mouseMoved(with event: NSEvent) {
        menuLink?.handleMenuMouseMoved(with: event, in: self)
    }

    override func cursorUpdate(with event: NSEvent) {
        menuLink?.handleMenuCursorUpdate(with: event, in: self)
    }

    func handlesMenuMouseEvent(_ event: NSEvent) -> Bool {
        guard let window else {
            return self.window == nil && bounds.contains(event.locationInWindow)
        }
        guard event.window == nil || event.window === window else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    func updateMenuCursor(with event: NSEvent) -> Bool {
        guard menuLink != nil else { return false }
        guard handlesMenuMouseEvent(event) else {
            clearMenuCursor()
            return false
        }
        menuLink?.handleMenuMouseMoved(with: event, in: self)
        return true
    }

    func updateMenuCursor(at windowPoint: NSPoint, in menuWindow: NSWindow? = nil) -> Bool {
        guard let menuLink else { return false }
        let hostWindowPoint: NSPoint
        if let menuWindow, let hostWindow = window, hostWindow !== menuWindow {
            let screenPoint = menuWindow.convertPoint(toScreen: windowPoint)
            hostWindowPoint = hostWindow.convertPoint(fromScreen: screenPoint)
        } else {
            hostWindowPoint = windowPoint
        }
        let hostPoint = convert(hostWindowPoint, from: nil)
        guard bounds.contains(hostPoint) else {
            clearMenuCursor()
            return false
        }
        menuLink.handleMenuMouseMoved(at: hostPoint, in: self)
        return true
    }

    func clearMenuCursor() {
        menuLink?.handleMenuExited()
        menuLink?.reassertMenuCursor()
    }

    func finishMenuTracking() {
        menuLink?.handleMenuExited()
        restoreMenuWindowMouseMovedEvents()
        window?.invalidateCursorRects(for: self)
    }

    func clearMenuCursorState() {
        clearMenuCursor()
    }

    func reassertMenuCursor() {
        menuLink?.reassertMenuCursor()
    }

    private func installMenuTrackingAreas() {
        guard let menuLink else { return }
        let trackingRect = convert(menuLink.visibleTextHitRect, from: menuLink)
        guard !trackingRect.isEmpty else { return }
        let mouseArea = NSTrackingArea(
            rect: trackingRect,
            options: [.mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(mouseArea)
        mouseTrackingAreaReference = mouseArea

        let mouseEntryArea = NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(mouseEntryArea)
        mouseEntryTrackingAreaReference = mouseEntryArea

        let cursorArea = NSTrackingArea(
            rect: trackingRect,
            options: [.cursorUpdate, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(cursorArea)
        cursorTrackingAreaReference = cursorArea
    }

    private func removeMenuTrackingAreas() {
        if let mouseTrackingAreaReference {
            removeTrackingArea(mouseTrackingAreaReference)
            self.mouseTrackingAreaReference = nil
        }
        if let mouseEntryTrackingAreaReference {
            removeTrackingArea(mouseEntryTrackingAreaReference)
            self.mouseEntryTrackingAreaReference = nil
        }
        if let cursorTrackingAreaReference {
            removeTrackingArea(cursorTrackingAreaReference)
            self.cursorTrackingAreaReference = nil
        }
    }

    private func enableMenuWindowMouseMovedEventsIfNeeded() {
        guard menuLink != nil, let window else { return }
        if menuWindow !== window {
            restoreMenuWindowMouseMovedEvents()
            menuWindow = window
            menuWindowAcceptedMouseMovedEvents = window.acceptsMouseMovedEvents
        }
        window.acceptsMouseMovedEvents = true
    }

    private func restoreMenuWindowMouseMovedEvents() {
        guard let menuWindow else { return }
        if let menuWindowAcceptedMouseMovedEvents {
            menuWindow.acceptsMouseMovedEvents = menuWindowAcceptedMouseMovedEvents
        }
        self.menuWindow = nil
        menuWindowAcceptedMouseMovedEvents = nil
    }
}

/// NSMenu can keep mouse movement inside its private tracking loop instead of
/// delivering it to an NSMenuItem.view. A tracking area on the actual menu
/// window gives cursor updates a stable AppKit-owned path without observing
/// application events or changing the menu's hit regions.
final class MenuWindowCursorTrackingBridge: NSResponder {
    private weak var menuWindow: NSWindow?
    private weak var contentView: NSView?
    private var mouseTrackingAreaReference: NSTrackingArea?
    private var cursorTrackingAreaReference: NSTrackingArea?
    private var acceptedMouseMovedEvents: Bool?
    private weak var activeHost: MenuItemContentView?
    private let registeredHosts = NSHashTable<MenuItemContentView>.weakObjects()
    private var cursorReassertionGeneration = 0
    private var menuTrackingTimer: Timer?

    func install(on window: NSWindow) {
        guard let contentView = window.contentView else { return }

        if menuWindow !== window || self.contentView !== contentView {
            tearDown()
            menuWindow = window
            self.contentView = contentView
            acceptedMouseMovedEvents = window.acceptsMouseMovedEvents
        }

        installTrackingArea(on: contentView)
        window.acceptsMouseMovedEvents = true
        window.invalidateCursorRects(for: contentView)
    }

    func refresh() {
        guard let menuWindow else { return }
        install(on: menuWindow)
    }

    func register(_ host: MenuItemContentView) {
        registeredHosts.add(host)
    }

    func tearDown() {
        cursorReassertionGeneration += 1
        menuTrackingTimer?.invalidate()
        menuTrackingTimer = nil
        if let contentView {
            if let mouseTrackingAreaReference {
                contentView.removeTrackingArea(mouseTrackingAreaReference)
            }
            if let cursorTrackingAreaReference {
                contentView.removeTrackingArea(cursorTrackingAreaReference)
            }
        }
        mouseTrackingAreaReference = nil
        cursorTrackingAreaReference = nil
        activeHost?.clearMenuCursor()
        activeHost = nil

        if let menuWindow, let acceptedMouseMovedEvents {
            menuWindow.acceptsMouseMovedEvents = acceptedMouseMovedEvents
        }
        if let contentView {
            finishMenuTracking(in: contentView)
        }
        menuWindow = nil
        contentView = nil
        acceptedMouseMovedEvents = nil
        registeredHosts.removeAllObjects()
    }

    /// Keep cursor state synchronized while NSMenu owns its nested event loop.
    /// Some menu windows do not forward mouseMoved to NSMenuItem.view, so the
    /// bridge also samples the real menu-window pointer location in the same
    /// event-tracking run-loop mode.
    func beginMenuTracking() {
        guard menuTrackingTimer == nil else { return }
        let timer = Timer(
            timeInterval: 0.01,
            repeats: true
        ) { [weak self] _ in
            self?.refreshCursorForCurrentMouseLocation()
        }
        menuTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        clearCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    func handleMenuMouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    func refreshMenuCursorState() {
        refreshCursorForCurrentMouseLocation()
    }

    func clearMenuCursorState() {
        clearCursor()
    }

    func reassertMenuCursorState() {
        if let activeHost {
            activeHost.reassertMenuCursor()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func installTrackingArea(on contentView: NSView) {
        if let mouseTrackingAreaReference {
            contentView.removeTrackingArea(mouseTrackingAreaReference)
        }
        if let cursorTrackingAreaReference {
            contentView.removeTrackingArea(cursorTrackingAreaReference)
        }
        let mouseArea = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(mouseArea)
        mouseTrackingAreaReference = mouseArea

        // Menu windows are transient and are not guaranteed to be key windows
        // while NSMenu owns its tracking loop. Keep cursor updates active for
        // the menu window itself, just like the movement tracking area.
        let cursorArea = NSTrackingArea(
            rect: contentView.bounds,
            options: [.cursorUpdate, .activeAlways],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(cursorArea)
        cursorTrackingAreaReference = cursorArea
    }

    private func updateCursor(for event: NSEvent) {
        guard let menuWindow, let contentView,
              event.window == nil || event.window === menuWindow
        else {
            clearCursor()
            return
        }

        updateCursor(at: event.locationInWindow, contentView: contentView)
    }

    private func refreshCursorForCurrentMouseLocation() {
        guard let menuWindow, let contentView else { return }
        let windowPoint = menuWindow.convertPoint(fromScreen: NSEvent.mouseLocation)
        updateCursor(
            at: windowPoint,
            contentView: contentView
        )
        reassertMenuCursorState()
    }

    private func updateCursor(
        at windowPoint: NSPoint,
        contentView: NSView
    ) {
        let nextHost = findMenuHost(
            in: contentView,
            windowPoint: windowPoint
        )
        if activeHost !== nextHost {
            activeHost?.clearMenuCursor()
            activeHost = nextHost
        }

        guard let nextHost, let menuWindow else {
            clearCursor()
            return
        }
        guard nextHost.updateMenuCursor(at: windowPoint, in: menuWindow) else {
            clearCursor()
            return
        }
        reassertCursorAfterMenuEvent()
    }

    private func clearCursor() {
        activeHost?.clearMenuCursor()
        activeHost = nil
        NSCursor.arrow.set()
        reassertCursorAfterMenuEvent()
    }

    /// NSMenu's event-tracking loop can restore its default arrow after a
    /// mouse event has reached the application. Reassert the cursor in that
    /// same run-loop mode after the event finishes, while retaining the exact
    /// glyph hit-test from the menu host.
    private func reassertCursorAfterMenuEvent() {
        cursorReassertionGeneration += 1
        let generation = cursorReassertionGeneration
        let reassertionTimer = Timer(
            timeInterval: 0.001,
            repeats: false
        ) { [weak self] _ in
            guard let self, self.cursorReassertionGeneration == generation else { return }
            self.reassertMenuCursorState()
        }
        RunLoop.main.add(reassertionTimer, forMode: .eventTracking)
    }

    private func finishMenuTracking(in view: NSView) {
        for subview in view.subviews {
            finishMenuTracking(in: subview)
        }
        (view as? MenuItemContentView)?.finishMenuTracking()
    }

    private func findMenuHost(in view: NSView, windowPoint: NSPoint) -> MenuItemContentView? {
        guard let menuWindow else { return nil }
        let screenPoint = menuWindow.convertPoint(toScreen: windowPoint)
        for host in registeredHosts.allObjects.reversed() {
            guard host.window === menuWindow,
                  host.bounds.contains(hostPoint(for: screenPoint, in: host))
            else { continue }
            return host
        }

        for subview in view.subviews.reversed() {
            if let host = findMenuHost(in: subview, screenPoint: screenPoint) {
                return host
            }
        }
        if let host = view as? MenuItemContentView,
           host.window === menuWindow,
           host.bounds.contains(hostPoint(for: screenPoint, in: host)) {
            return host
        }
        return nil
    }

    private func findMenuHost(in view: NSView, screenPoint: NSPoint) -> MenuItemContentView? {
        for subview in view.subviews.reversed() {
            if let host = findMenuHost(in: subview, screenPoint: screenPoint) {
                return host
            }
        }
        guard let menuWindow,
              let host = view as? MenuItemContentView,
              host.window === menuWindow,
              host.bounds.contains(hostPoint(for: screenPoint, in: host))
        else {
            return nil
        }
        return host
    }

    private func hostPoint(for screenPoint: NSPoint, in host: MenuItemContentView) -> NSPoint {
        guard let hostWindow = host.window else {
            return host.convert(screenPoint, from: nil)
        }
        let hostWindowPoint = hostWindow.convertPoint(fromScreen: screenPoint)
        return host.convert(hostWindowPoint, from: nil)
    }
}

final class HoverLinkTextField: NSTextField {
    var onActivate: (() -> Void)?
    private(set) var visibleTextHitRect = NSRect.zero
    private var trackingAreaReference: NSTrackingArea?
    private weak var menuTrackingHost: MenuItemContentView?
    private var isHovered = false
    private var isApplyingStyle = false

    override var stringValue: String {
        didSet {
            guard !isApplyingStyle else { return }
            applyStyle(text: stringValue, underlined: isHovered)
            updateVisibleTextHitRect()
        }
    }

    override var font: NSFont? {
        didSet {
            guard !isApplyingStyle else { return }
            applyStyle(text: stringValue, underlined: isHovered)
            updateVisibleTextHitRect()
        }
    }

    init(text: String) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 12, weight: .medium)
        applyStyle(text: text, underlined: false)
        updateVisibleTextHitRect()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateVisibleTextHitRect()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateVisibleTextHitRect()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        updateVisibleTextHitRect()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateVisibleTextHitRect()
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        updateVisibleTextHitRect()
    }

    override func updateTrackingAreas() {
        removeTrackingAreaReference()
        super.updateTrackingAreas()
        updateVisibleTextHitRect()
        if menuTrackingHost == nil {
            installTrackingArea()
        }
        synchronizeHoverStateWithMouseLocation()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard menuTrackingHost == nil else { return }
        updateVisibleTextHitRect()
        guard !visibleTextHitRect.isEmpty else { return }
        addCursorRect(visibleTextHitRect, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(isPointInsideVisibleText(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        setHovering(isPointInsideVisibleText(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        setHovering(isPointInsideVisibleText(for: event))
    }

    override func mouseDown(with event: NSEvent) {
        guard isPointInsideVisibleText(for: event) else {
            setHovering(false)
            return
        }
        NSCursor.pointingHand.set()
        onActivate?()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            tearDownWindowInteraction()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func removeFromSuperview() {
        tearDownInteraction()
        super.removeFromSuperview()
    }

    /// Menu item views are tracked by NSMenu's modal event loop. Attach a
    /// local tracking area to the item view so mouse movement continues to
    /// update the cursor even when the normal cursor-update path is skipped.
    /// The area is intentionally used only for cursor state; activation still
    /// checks `visibleTextHitRect`.
    func installMenuTrackingArea(in host: NSView) {
        removeMenuTrackingArea()
        guard let host = host as? MenuItemContentView else { return }
        menuTrackingHost = host
        host.installMenuLink(self)
    }

    func handleMenuMouseEntered(with event: NSEvent, in host: NSView) {
        setHovering(isPointInsideVisibleText(for: event, in: host))
    }

    func handleMenuMouseMoved(with event: NSEvent, in host: NSView) {
        setHovering(isPointInsideVisibleText(for: event, in: host))
    }

    func handleMenuMouseMoved(at hostPoint: NSPoint, in host: NSView) {
        setHovering(isPointInsideVisibleText(at: hostPoint, in: host))
    }

    func handleMenuCursorUpdate(with event: NSEvent, in host: NSView) {
        setHovering(isPointInsideVisibleText(for: event, in: host))
    }

    func handleMenuExited() {
        setHovering(false)
    }

    func reassertMenuCursor() {
        (isHovered ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    private func installTrackingArea() {
        guard !visibleTextHitRect.isEmpty else { return }
        let area = NSTrackingArea(
            rect: visibleTextHitRect,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    private func removeMenuTrackingArea() {
        if let menuTrackingHost {
            menuTrackingHost.removeMenuLink(self)
        }
        menuTrackingHost = nil
    }

    private func removeTrackingAreaReference() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
            self.trackingAreaReference = nil
        }
    }

    private func setHovering(_ hovered: Bool) {
        guard isHovered != hovered else {
            if hovered {
                NSCursor.pointingHand.set()
            }
            return
        }
        isHovered = hovered
        applyStyle(text: stringValue, underlined: hovered)
        if hovered {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func synchronizeHoverStateWithMouseLocation() {
        guard let window else {
            if isHovered { setHovering(false) }
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovering(visibleTextHitRect.contains(point))
    }

    private func tearDownInteraction() {
        removeTrackingAreaReference()
        removeMenuTrackingArea()
        clearHoverStyleAndCursor()
    }

    /// A menu item view is detached from its transient popup window when the
    /// menu closes, but the same NSMenuItem.view can be reused on the next
    /// open. Keep the logical menu-link/host relationship alive across that
    /// window-only lifecycle; remove it only when the link leaves its host.
    private func tearDownWindowInteraction() {
        removeTrackingAreaReference()
        clearHoverStyleAndCursor()
    }

    private func clearHoverStyleAndCursor() {
        if isHovered {
            isHovered = false
            applyStyle(text: stringValue, underlined: false)
        }
        NSCursor.arrow.set()
    }

    private func isPointInsideVisibleText(for event: NSEvent, in host: NSView? = nil) -> Bool {
        let point: NSPoint
        if let host {
            let hostPoint: NSPoint
            if host.window != nil {
                hostPoint = host.convert(event.locationInWindow, from: nil)
            } else {
                hostPoint = event.locationInWindow
            }
            point = convert(hostPoint, from: host)
        } else if window != nil {
            point = convert(event.locationInWindow, from: nil)
        } else {
            point = event.locationInWindow
        }
        return visibleTextHitRect.contains(point)
    }

    private func isPointInsideVisibleText(at hostPoint: NSPoint, in host: NSView) -> Bool {
        visibleTextHitRect.contains(convert(hostPoint, from: host))
    }

    private func updateVisibleTextHitRect() {
        let previousRect = visibleTextHitRect
        visibleTextHitRect = calculateVisibleTextHitRect()
        if let menuTrackingHost {
            menuTrackingHost.refreshMenuLinkTrackingArea()
            menuTrackingHost.window?.invalidateCursorRects(for: menuTrackingHost)
        }
        guard previousRect != visibleTextHitRect else {
            return
        }

        window?.invalidateCursorRects(for: self)
        guard trackingAreaReference != nil else { return }
        removeTrackingAreaReference()
        installTrackingArea()
        synchronizeHoverStateWithMouseLocation()
    }

    private func calculateVisibleTextHitRect() -> NSRect {
        guard !bounds.isEmpty,
              let cell,
              !attributedStringValue.string.isEmpty
        else {
            return .zero
        }

        let titleRect = cell.titleRect(forBounds: bounds)
        guard !titleRect.isEmpty else { return .zero }

        let textStorage = NSTextStorage(attributedString: layoutAttributedString())
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: titleRect.size)
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = cell.lineBreakMode
        textContainer.maximumNumberOfLines = 1
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let laidGlyphRange = layoutManager.glyphRange(for: textContainer)
        guard laidGlyphRange.length > 0 else { return .zero }

        let visibleGlyphRange: NSRange
        let truncatedGlyphRange = layoutManager.truncatedGlyphRange(
            inLineFragmentForGlyphAt: laidGlyphRange.location
        )
        if truncatedGlyphRange.location == NSNotFound {
            visibleGlyphRange = laidGlyphRange
        } else {
            visibleGlyphRange = NSRange(
                location: laidGlyphRange.location,
                length: max(0, truncatedGlyphRange.location - laidGlyphRange.location)
            )
        }

        let glyphRect = layoutManager.boundingRect(forGlyphRange: visibleGlyphRange, in: textContainer)
        guard !glyphRect.isEmpty else { return .zero }

        let glyphHitRect = NSRect(
            x: titleRect.minX + glyphRect.minX,
            y: titleRect.minY + glyphRect.minY,
            width: glyphRect.width,
            height: glyphRect.height
        )
        return glyphHitRect
            .insetBy(dx: -2, dy: -2)
            .intersection(bounds)
    }

    private func layoutAttributedString() -> NSAttributedString {
        let attributedString = NSMutableAttributedString(attributedString: attributedStringValue)
        guard attributedString.length > 0 else { return attributedString }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = cell?.alignment ?? alignment
        paragraphStyle.lineBreakMode = cell?.lineBreakMode ?? lineBreakMode
        attributedString.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: attributedString.length)
        )
        return attributedString
    }

    private func applyStyle(text: String, underlined: Bool) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.linkColor
        ]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        isApplyingStyle = true
        attributedStringValue = NSAttributedString(string: text, attributes: attributes)
        isApplyingStyle = false
        updateVisibleTextHitRect()
    }
}

enum DashboardSection: Int, CaseIterable {
    case general
    case menuBar
    case menu
    case advanced
    case about

    var title: String {
        switch self {
        case .general: return tr("通用", "General")
        case .menuBar: return tr("菜单栏", "Menu Bar")
        case .menu: return tr("菜单", "Menu")
        case .advanced: return tr("高级", "Advanced")
        case .about: return tr("关于", "About")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .menuBar: return "menubar.rectangle"
        case .menu: return "filemenu.and.selection"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle.fill"
        }
    }

    var chipColor: NSColor {
        switch self {
        case .general: return .systemGray
        case .menuBar: return .systemBlue
        case .menu: return .systemTeal
        case .advanced: return .systemPurple
        case .about: return .systemGreen
        }
    }
}
