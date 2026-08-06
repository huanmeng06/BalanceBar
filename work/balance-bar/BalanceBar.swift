import AppKit
import Foundation
import SQLite3
import Darwin
import SwiftUI

private let databasePath = NSString(string: "~/.cc-switch/cc-switch.db").expandingTildeInPath
private let ccSwitchDirectory = NSString(string: "~/.cc-switch").expandingTildeInPath
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func fileIdentity(atPath path: String) -> (size: UInt64, modifiedAt: TimeInterval)? {
    var value = stat()
    guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else { return nil }
    let modifiedAt = TimeInterval(value.st_mtimespec.tv_sec)
        + (TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000)
    return (UInt64(max(0, value.st_size)), modifiedAt)
}

private var dashboardUsesDarkAppearance: Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

private func dashboardAdaptiveColor(light: NSColor, dark: NSColor) -> NSColor {
    dashboardUsesDarkAppearance ? dark : light
}

private enum AppLanguage: String, CaseIterable {
    case system
    case simplifiedChinese
    case english

    static var selected: AppLanguage {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: "appLanguage"),
                  let language = AppLanguage(rawValue: rawValue) else {
                return .system
            }
            return language
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appLanguage")
        }
    }

    static var usesSimplifiedChinese: Bool {
        switch selected {
        case .simplifiedChinese:
            return true
        case .english:
            return false
        case .system:
            let identifier = (Locale.preferredLanguages.first ?? Locale.current.identifier).lowercased()
            return identifier.hasPrefix("zh")
        }
    }

    var localizedTitle: String {
        switch self {
        case .system:
            return tr("跟随系统", "Follow System")
        case .simplifiedChinese:
            return tr("简体中文", "Simplified Chinese")
        case .english:
            return "English"
        }
    }
}

private func tr(_ simplifiedChinese: String, _ english: String) -> String {
    AppLanguage.usesSimplifiedChinese ? simplifiedChinese : english
}

private enum AssistantClient: String {
    case codex
    case claude

    var appType: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

private final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class MenuBarContentView: NSView {
    override var isFlipped: Bool { true }
}

private final class MenuBarTextView: NSView {
    override var isFlipped: Bool { true }

    var layoutSize: NSSize = NSSize(width: 32, height: 18) {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize { layoutSize }
}

private struct MenuBarGeometry {
    let iconWidth: CGFloat
    let gap: CGFloat
    let textWidth: CGFloat
    let primaryHeight: CGFloat
    let secondaryHeight: CGFloat
    let textHeight: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat

    init(
        primarySize: NSSize,
        secondarySize: NSSize,
        showIcon: Bool,
        showAmount: Bool,
        hasSecondary: Bool,
        isBalance: Bool,
        iconSlotWidth: CGFloat,
        iconTextSpacing: CGFloat,
        textRowSpacing: CGFloat,
        textWidthSlack: CGFloat,
        singleLineHeight: CGFloat
    ) {
        iconWidth = showIcon ? iconSlotWidth : 0
        gap = showIcon && showAmount ? iconTextSpacing : 0
        textWidth = showAmount
            ? ceil(max(primarySize.width, secondarySize.width)) + textWidthSlack
            : 0
        primaryHeight = showAmount ? ceil(primarySize.height) : 0
        secondaryHeight = hasSecondary ? ceil(secondarySize.height) : 0
        textHeight = primaryHeight + (hasSecondary ? textRowSpacing + secondaryHeight : 0)
        contentWidth = iconWidth + gap + textWidth
        contentHeight = isBalance && showAmount
            ? singleLineHeight
            : ceil(max(iconWidth, textHeight))
    }

    func iconCenterYInFlippedButton(
        buttonHeight: CGFloat,
        iconViewYOffset: CGFloat
    ) -> CGFloat {
        let contentY = floor((buttonHeight - contentHeight) / 2)
        let slotYFromTop = floor(max(0, (contentHeight - iconWidth) / 2))
        // The status button and content stack are flipped while the icon slot
        // is not. Positive local icon Y therefore decreases button-space Y.
        return contentY + slotYFromTop - iconViewYOffset + (iconWidth / 2)
    }

    func iconViewYOffset(
        alignedTo reference: MenuBarGeometry,
        buttonHeight: CGFloat,
        referenceIconViewYOffset: CGFloat
    ) -> CGFloat {
        iconCenterYInFlippedButton(
            buttonHeight: buttonHeight,
            iconViewYOffset: 0
        ) - reference.iconCenterYInFlippedButton(
            buttonHeight: buttonHeight,
            iconViewYOffset: referenceIconViewYOffset
        )
    }
}

private enum StatusLinkField {
    case title
    case url
}

/// A native SwiftUI text field kept at its natural single-line height and
/// centered by the fixed-height outer container. The system rounded-border
/// style owns the background, border, focus ring, and appearance adaptation.
private struct StatusTextField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 0) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 28,
            maxHeight: 28,
            alignment: .center
        )
    }
}

private final class StatusLinksEditorModel: ObservableObject {
    @Published var links: [StatusLink]
    let onChange: (Int, StatusLinkField, String) -> Void
    let onAdd: () -> Void
    let onRemove: (Int) -> Void
    let onReset: () -> Void

    init(
        links: [StatusLink],
        onChange: @escaping (Int, StatusLinkField, String) -> Void,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (Int) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.links = links
        self.onChange = onChange
        self.onAdd = onAdd
        self.onRemove = onRemove
        self.onReset = onReset
    }
}

private struct StatusLinksEditorSwiftUI: View {
    @ObservedObject var model: StatusLinksEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(tr("状态链接", "Status Links"))
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 12)
                Button(tr("恢复默认", "Restore Defaults"), action: model.onReset)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 12))
            }
            .frame(height: 24)

            HStack(spacing: 8) {
                Text(tr("名称", "Name"))
                    .frame(width: 160, alignment: .leading)
                Text(tr("网址", "URL"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 24, height: 1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(height: 20, alignment: .center)

            ForEach(model.links.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    StatusTextField(
                        text: $model.links[index].title,
                        placeholder: tr("显示名称", "Display name")
                    )
                    .frame(width: 160)
                    .onChange(of: model.links[index].title) { _, value in
                        model.onChange(index, .title, value)
                    }

                    StatusTextField(
                        text: $model.links[index].url,
                        placeholder: "https://"
                    )
                    .frame(maxWidth: .infinity)
                    .onChange(of: model.links[index].url) { _, value in
                        model.onChange(index, .url, value)
                    }

                    Button {
                        model.onRemove(index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 28)
                }
                .frame(height: 35)
            }

            Color.clear.frame(height: 8)

            Button(action: model.onAdd) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: .controlAccentColor))
            .frame(width: 32, height: 28, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // NSHostingView fills the animated AppKit height. Keep the SwiftUI
        // content pinned to the top of that host so its title row does not
        // recenter for a frame while the row count changes.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// AppKit only hosts the SwiftUI editor and controls its stable outer height.
/// No AppKit text field, cell, or field editor is involved in status-link rows.
private final class StatusLinksHostingView: NSView {
    private let model: StatusLinksEditorModel
    private let hostingView: NSHostingView<StatusLinksEditorSwiftUI>
    private var heightConstraint: NSLayoutConstraint?
    private var links: [StatusLink]

    var rowCount: Int { links.count }
    var layoutHeight: CGFloat { 112 + CGFloat(links.count * 35) }

    init(
        links: [StatusLink],
        onChange: @escaping (Int, StatusLinkField, String) -> Void,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (Int) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.links = links
        let model = StatusLinksEditorModel(
            links: links,
            onChange: onChange,
            onAdd: onAdd,
            onRemove: onRemove,
            onReset: onReset
        )
        self.model = model
        self.hostingView = NSHostingView(
            rootView: StatusLinksEditorSwiftUI(model: model)
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let heightConstraint = heightAnchor.constraint(equalToConstant: layoutHeight)
        heightConstraint.isActive = true
        self.heightConstraint = heightConstraint
        SwitchLog.write(
            "status-link editor runtime; implementation=SwiftUI.TextField; rows=\(links.count); host=\(String(reflecting: type(of: hostingView)))",
            level: .debug,
            category: "ui.geometry"
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateLinks(
        _ newLinks: [StatusLink],
        animated: Bool,
        revealAddedRowsAtCompletion: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        let deferAddedRows = revealAddedRowsAtCompletion && newLinks.count > links.count
        links = newLinks
        // Deletion already has the desired motion: the removed row vanishes
        // first and the card then collapses. For an addition, play that same
        // geometry in reverse by expanding an empty 35pt slot first and only
        // revealing the new SwiftUI row once the expansion has settled.
        if !deferAddedRows {
            model.links = newLinks
        }
        let targetHeight = layoutHeight
        let applyHeight = {
            self.heightConstraint?.constant = targetHeight
            self.synchronizeAncestorCardHeight()
            self.needsLayout = true
            self.superview?.needsLayout = true
            if deferAddedRows {
                self.superview?.layoutSubtreeIfNeeded()
                self.model.links = newLinks
            }
            completion?()
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                self.heightConstraint?.animator().constant = targetHeight
                self.synchronizeAncestorCardHeight(animated: true)
                self.superview?.layoutSubtreeIfNeeded()
            } completionHandler: {
                applyHeight()
            }
        } else {
            applyHeight()
        }
    }

    func logGeometry(label: String) {
        let card = (superview as? NSStackView)?.superview
        SwitchLog.write(
            "status-link geometry; label=\(label); rows=\(links.count); editor_frame=\(DashboardLogging.rect(frame)); card_frame=\(card.map { DashboardLogging.rect($0.frame) } ?? "none")",
            category: "ui.geometry"
        )
    }

    private func ancestorCardInfo() -> (NSView, NSLayoutConstraint, CGFloat)? {
        guard let rowsStack = superview as? NSStackView,
              let card = rowsStack.superview else { return nil }
        let requiredHeight = max(1, ceil(rowsStack.arrangedSubviews.reduce(CGFloat(0)) { total, row in
            if row === self {
                return total + layoutHeight
            }
            let explicit = row.constraints.first {
                ($0.firstItem as? NSView) === row &&
                    $0.firstAttribute == .height &&
                    $0.relation == .equal
            }?.constant
            return total + max(1, explicit ?? row.fittingSize.height)
        }))
        let constraint = card.constraints.first {
            ($0.firstItem as? NSView) === card &&
                $0.firstAttribute == .height &&
                $0.relation == .equal
        } ?? card.heightAnchor.constraint(equalToConstant: requiredHeight)
        if !constraint.isActive { constraint.isActive = true }
        return (card, constraint, requiredHeight)
    }

    private func synchronizeAncestorCardHeight(animated: Bool = false) {
        guard let info = ancestorCardInfo() else { return }
        if animated {
            info.1.animator().constant = info.2
        } else {
            info.1.constant = info.2
        }
        info.0.needsLayout = true
    }
}

private final class DashboardNavigationRowView: NSView {
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

private final class RotatingTemplateImageView: PassthroughImageView {
    private static let frameCount = 36
    private static let rotationDuration: TimeInterval = 1.15
    private var sourceImage: NSImage?
    private var rotationFrames: [NSImage] = []
    private var rotationTimer: Timer?
    private var frameIndex = 0
    var onImageChanged: ((NSImage?) -> Void)?

    func setSourceImage(_ image: NSImage) {
        if sourceImage !== image {
            rotationFrames = Self.makeRotationFrames(from: image)
        }
        sourceImage = image
        self.image = image
        onImageChanged?(image)
    }

    func displayImage(_ image: NSImage) {
        self.image = image
        onImageChanged?(image)
    }

    func startRotating() {
        guard rotationTimer == nil, !rotationFrames.isEmpty else { return }
        frameIndex = 0
        let interval = Self.rotationDuration / Double(Self.frameCount)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceRotation()
        }
        timer.tolerance = 0.002
        rotationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopRotating() {
        let wasRotating = rotationTimer != nil
        rotationTimer?.invalidate()
        rotationTimer = nil
        frameIndex = 0
        image = sourceImage
        if wasRotating { onImageChanged?(sourceImage) }
    }

    private func advanceRotation() {
        guard !rotationFrames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % rotationFrames.count
        let frame = rotationFrames[frameIndex]
        image = frame
        onImageChanged?(frame)
    }

    private static func makeRotationFrames(from sourceImage: NSImage) -> [NSImage] {
        (0..<frameCount).map { index in
            let angle = -(2 * .pi * CGFloat(index) / CGFloat(frameCount))
            let frame = NSImage(size: sourceImage.size, flipped: false) { rect in
                NSGraphicsContext.current?.imageInterpolation = .high
                let transform = NSAffineTransform()
                transform.translateX(by: rect.midX, yBy: rect.midY)
                transform.rotate(byRadians: angle)
                transform.translateX(by: -rect.midX, yBy: -rect.midY)
                transform.concat()
                sourceImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            frame.isTemplate = true
            return frame
        }
    }

    deinit {
        rotationTimer?.invalidate()
    }
}

private final class ClaudeThinkingAnimator {
    private weak var imageView: RotatingTemplateImageView?
    private let staticImage: NSImage
    private let frames: [NSImage]
    private let frameDuration: TimeInterval
    private let outputSize: NSSize
    private var timer: Timer?
    private var frameIndex = 0

    init?(
        imageView: RotatingTemplateImageView,
        staticImage: NSImage,
        animatedSVGURL: URL,
        frameDuration: TimeInterval = 0.09,
        outputSize: NSSize = NSSize(width: 16, height: 16)
    ) {
        guard
            let svg = try? String(contentsOf: animatedSVGURL, encoding: .utf8),
            let frames = Self.makeFrames(from: svg),
            frames.count == 9
        else {
            return nil
        }
        self.imageView = imageView
        self.staticImage = staticImage
        self.frames = frames.map { source in
            let output = NSImage(size: outputSize, flipped: false) { rect in
                source.draw(
                    in: rect.insetBy(dx: 0.3, dy: 0.3),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
                return true
            }
            output.isTemplate = true
            output.size = outputSize
            return output
        }
        self.frameDuration = frameDuration
        self.outputSize = outputSize
    }

    func start() {
        guard timer == nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stop()
            return
        }
        frameIndex = 0
        render(frameIndex)
        let timer = Timer(timeInterval: frameDuration, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frames.count
            self.render(self.frameIndex)
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        frameIndex = 0
        imageView?.setSourceImage(staticImage)
    }

    private func render(_ index: Int) {
        imageView?.displayImage(frames[min(max(index, 0), frames.count - 1)])
    }

    private static func makeFrames(from animatedSVG: String) -> [NSImage]? {
        guard
            let animationRegex = try? NSRegularExpression(
                pattern: #"<animateTransform\b[^>]*/>"#
            ),
            let viewBoxRegex = try? NSRegularExpression(
                pattern: #"viewBox="0 0 100 100""#
            )
        else {
            return nil
        }
        let fullRange = NSRange(animatedSVG.startIndex..., in: animatedSVG)
        let staticSVG = animationRegex.stringByReplacingMatches(
            in: animatedSVG,
            range: fullRange,
            withTemplate: ""
        )
        return (0..<9).compactMap { index in
            let range = NSRange(staticSVG.startIndex..., in: staticSVG)
            let frameSVG = viewBoxRegex.stringByReplacingMatches(
                in: staticSVG,
                range: range,
                withTemplate: #"viewBox="0 \#(index * 100) 100 100""#
            )
            guard
                let data = frameSVG.data(using: .utf8),
                let image = NSImage(data: data)
            else {
                return nil
            }
            image.size = NSSize(width: 100, height: 100)
            return image
        }
    }

    deinit {
        timer?.invalidate()
    }
}

private final class QuotaProgressView: NSView {
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
        progressColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    private var progressColor: NSColor {
        switch percentage {
        case let value where value > 50: return .systemGreen
        case 25...50: return .systemYellow
        case 10..<25: return .systemOrange
        default: return .systemRed
        }
    }
}

private final class HoverLinkTextField: NSTextField {
    var onActivate: (() -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var pointingCursorIsPushed = false

    init(text: String) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 12, weight: .medium)
        applyStyle(text: text, underlined: false)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        applyStyle(text: stringValue, underlined: true)
        if !pointingCursorIsPushed {
            NSCursor.pointingHand.push()
            pointingCursorIsPushed = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        applyStyle(text: stringValue, underlined: false)
        if pointingCursorIsPushed {
            NSCursor.pop()
            pointingCursorIsPushed = false
        }
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.pointingHand.set()
        onActivate?()
    }

    deinit {
        if pointingCursorIsPushed { NSCursor.pop() }
    }

    private func applyStyle(text: String, underlined: Bool) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.linkColor
        ]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedStringValue = NSAttributedString(string: text, attributes: attributes)
    }
}

private enum DashboardSection: Int, CaseIterable {
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

private struct StatusLink: Codable, Equatable {
    var title: String
    var url: String
}

private struct DashboardScrollPosition {
    let operation: String
    let visibleDocumentOriginY: CGFloat
    let contentOriginY: CGFloat
    let distanceFromBottom: CGFloat
    let previousMaximumOffset: CGFloat
    let bottomAnchorView: NSView?
    let bottomAnchorViewportY: CGFloat?
}

private enum DashboardLogging {
    static func number(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    static func rect(_ rect: NSRect) -> String {
        "x=\(number(rect.origin.x)),y=\(number(rect.origin.y)),w=\(number(rect.size.width)),h=\(number(rect.size.height))"
    }

    static func state(_ state: NSControl.StateValue) -> String {
        switch state {
        case .on: return "on"
        case .off: return "off"
        case .mixed: return "mixed"
        default: return "raw=\(state.rawValue)"
        }
    }
}

private enum SwitchLog {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    private static let queue = DispatchQueue(label: "local.balancebar.debug-log")
    // Keep at most about 1 MB on disk: one 512 KB active file and one rotated
    // predecessor. Diagnostic logs should never grow with the app's lifetime.
    private static let maximumSize = 512 * 1_024
    private static let viewerMaximumBytes: UInt64 = 160 * 1_024
    private static let viewerMaximumLines = 1_000
    private static var lastWriteDates: [String: Date] = [:]
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let fileURL = URL(fileURLWithPath: NSString(
        string: "~/Library/Logs/BalanceBar/debug.log"
    ).expandingTildeInPath)
    private static let previousFileURL = fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("debug.previous.log")

    static func write(
        _ message: String,
        level: Level = .info,
        category: String = "general",
        throttleKey: String? = nil,
        minimumInterval: TimeInterval = 0
    ) {
        queue.async {
            let now = Date()
            if minimumInterval > 0 {
                let key = throttleKey ?? "\(level.rawValue)|\(category)|\(message)"
                if let previous = lastWriteDates[key],
                   now.timeIntervalSince(previous) < minimumInterval {
                    return
                }
                lastWriteDates[key] = now
                if lastWriteDates.count > 256 {
                    lastWriteDates = lastWriteDates.filter {
                        now.timeIntervalSince($0.value) < 3_600
                    }
                }
            }
            let line = "[\(timestampFormatter.string(from: now))] [\(level.rawValue)] [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                rotateIfNeeded(incomingBytes: data.count)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try data.write(to: fileURL, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                }
            } catch {
                NSLog("BalanceBar debug log error: %@", error.localizedDescription)
            }
        }
    }

    static func recentText() -> String? {
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let handle = try? FileHandle(forReadingFrom: fileURL)
            else { return nil }
            defer { try? handle.close() }
            do {
                let size = try handle.seekToEnd()
                let start = size > viewerMaximumBytes
                    ? size - viewerMaximumBytes
                    : 0
                try handle.seek(toOffset: start)
                guard let data = try handle.readToEnd(),
                      var text = String(data: data, encoding: .utf8)
                else { return nil }
                if start > 0, let newline = text.firstIndex(of: "\n") {
                    text.removeSubrange(...newline)
                }
                let lines = text.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                )
                if lines.count > viewerMaximumLines {
                    text = lines.suffix(viewerMaximumLines)
                        .joined(separator: "\n")
                }
                return text
            } catch {
                return nil
            }
        }
    }

    private static func rotateIfNeeded(incomingBytes: Int) {
        let size = (try? fileURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize) ?? 0
        guard size + incomingBytes > maximumSize else { return }
        try? FileManager.default.removeItem(at: previousFileURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousFileURL)
    }
}

private let productionBundleIdentifier = "com.huanmeng06.BalanceBar.app"
private let devBundleIdentifier = "com.huanmeng06.BalanceBar.dev"
private let legacyProductionBundleIdentifier = "com.huanmeng06.BalanceBar"
private let legacyBundleIdentifier = "local.balancebar"
private let preferencesMigrationMarker = "didMigrateToBalanceBarApp.v1"

struct PreferencesMigrationPlan {
    static let keys = [
        "appLanguage",
        "showMenuBarReset",
        "showMenuBarIcon",
        "showMenuBarAmount",
        "animateCodexActivity",
        "activityPollInterval",
        "codexUsageRefreshInterval",
        "postCodexRefreshDuration",
        "showQuickSwitchMenu",
        "showOpenChatGPTMenu",
        "showOpenCCSwitchMenu",
        "showStatusMenu",
        "statusLinks",
        "keepMenuOpenAfterRefresh",
        "sortProvidersAlphabetically",
        "menuBarHorizontalPadding"
    ]

    static func selectedValues(
        target: [String: Any],
        production: [String: Any],
        local: [String: Any]
    ) -> [String: Any] {
        var selected: [String: Any] = [:]
        for key in keys where target[key] == nil {
            if let value = production[key] {
                selected[key] = value
            } else if let value = local[key] {
                selected[key] = value
            }
        }
        return selected
    }
}

private func migrateLegacyPreferencesIfNeeded() {
    let defaults = UserDefaults.standard
    let currentBundleIdentifier = Bundle.main.bundleIdentifier ?? productionBundleIdentifier
    let currentDomain = defaults.persistentDomain(forName: currentBundleIdentifier) ?? [:]
    guard currentDomain[preferencesMigrationMarker] == nil else { return }

    let productionDomain = defaults.persistentDomain(
        forName: legacyProductionBundleIdentifier
    ) ?? [:]
    let localDomain = defaults.persistentDomain(forName: legacyBundleIdentifier) ?? [:]
    let selectedValues = PreferencesMigrationPlan.selectedValues(
        target: currentDomain,
        production: productionDomain,
        local: localDomain
    )
    var migratedFromProduction: [String] = []
    var migratedFromLocal: [String] = []
    var skippedExisting: [String] = []

    for key in PreferencesMigrationPlan.keys {
        guard let value = selectedValues[key] else {
            if currentDomain[key] != nil { skippedExisting.append(key) }
            continue
        }
        defaults.set(value, forKey: key)
        if productionDomain[key] != nil {
            migratedFromProduction.append(key)
        } else {
            migratedFromLocal.append(key)
        }
    }

    defaults.set(true, forKey: preferencesMigrationMarker)
    let productionSummary = migratedFromProduction.isEmpty
        ? "<none>"
        : migratedFromProduction.joined(separator: "|")
    let localSummary = migratedFromLocal.isEmpty
        ? "<none>"
        : migratedFromLocal.joined(separator: "|")
    let skippedSummary = skippedExisting.isEmpty
        ? "<none>"
        : skippedExisting.joined(separator: "|")
    SwitchLog.write(
        "preferences migration; source_priority=\(legacyProductionBundleIdentifier),\(legacyBundleIdentifier); target=\(currentBundleIdentifier); production_key_count=\(productionDomain.count); local_key_count=\(localDomain.count); migrated_from_production=\(productionSummary); migrated_from_local=\(localSummary); skipped_existing=\(skippedSummary)",
        category: "configuration"
    )
}

private final class CodexActivityMonitor {
    private static let activityWindow = 10 * 60
    private static let terminalTypes: Set<String> = [
        "task_complete", "task_completed", "task_stopped", "task_failed", "task_cancelled",
        "turn_complete", "turn_completed", "turn_aborted", "turn_failed", "turn_cancelled"
    ]
    private struct SessionCache {
        let size: UInt64
        let modifiedAt: TimeInterval
        let running: Bool
    }
    private var sessionCache: [String: SessionCache] = [:]
    private var rolloutPathsCache: (scannedAt: Date, paths: [String]) = (.distantPast, [])

    func isTaskRunning(now: Date = Date()) -> Bool {
        // A rollout task_complete/failure/cancellation event is authoritative.
        // Only use the delayed logs database when rollout files are unavailable.
        if let rolloutState = recentRolloutRunningState(now: now) { return rolloutState }
        return logsDatabaseIsRunning(now: now)
    }

    private func recentRolloutRunningState(now: Date) -> Bool? {
        let paths = recentRolloutPaths()
        var nextCache: [String: SessionCache] = [:]
        var parsedAny = false
        var anyRunning = false
        for path in paths {
            guard let identity = fileIdentity(atPath: path) else { continue }
            parsedAny = true
            let sizeValue = identity.size
            let modifiedValue = identity.modifiedAt
            if let cached = sessionCache[path],
               cached.size == sizeValue,
               cached.modifiedAt == modifiedValue {
                nextCache[path] = cached
                anyRunning = anyRunning || cached.running
                continue
            }
            let running = parseSession(path: path)
            let entry = SessionCache(size: sizeValue, modifiedAt: modifiedValue, running: running)
            nextCache[path] = entry
            anyRunning = anyRunning || running
        }
        sessionCache = nextCache
        return parsedAny ? anyRunning : nil
    }

    private func recentRolloutPaths() -> [String] {
        let now = Date()
        if now.timeIntervalSince(rolloutPathsCache.scannedAt) < 1 {
            return rolloutPathsCache.paths
        }
        guard let databasePath = Self.latestDatabase(prefix: "state_") else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return [] }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 150)
        let sql = "SELECT rollout_path FROM threads WHERE rollout_path <> '' ORDER BY updated_at DESC, updated_at_ms DESC LIMIT 24"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            paths.append(String(cString: text))
        }
        rolloutPathsCache = (now, paths)
        return paths
    }

    private func parseSession(path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let size = try? handle.seekToEnd() else { return false }
        let offset = size > 256 * 1024 ? size - 256 * 1024 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return false }
        let text = String(decoding: data, as: UTF8.self)
        var running = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let topType = object["type"] as? String else { continue }
            if topType == "event_msg", let payload = object["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String {
                if payloadType == "task_started" || payloadType == "user_message" || payloadType == "agent_message" {
                    running = true
                } else if Self.terminalTypes.contains(payloadType) {
                    running = false
                }
            } else if topType == "response_item", let payload = object["payload"] as? [String: Any] {
                let phase = payload["phase"] as? String
                if phase == "final" || phase == "final_answer" {
                    running = false
                } else {
                    running = true
                }
            }
        }
        return running
    }

    private func logsDatabaseIsRunning(now: Date) -> Bool {
        guard let databasePath = Self.latestDatabase(prefix: "logs_") else { return false }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return false }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 150)

        // This follows codex-monitor's activity model: streaming/in-progress
        // events start activity, while task/turn terminal events stop it.
        let normalized = "replace(feedback_log_body, ' ', '')"
        let activity = """
        \(normalized) like '%response.output_item.added%'
        or \(normalized) like '%response.output_text.delta%'
        or \(normalized) like '%\"status\":\"in_progress\"%'
        """
        let terminalTypes = [
            "task_complete", "task_completed", "task_stopped", "task_failed", "task_cancelled",
            "turn_complete", "turn_completed", "turn_aborted", "turn_failed", "turn_cancelled"
        ]
        let completion = ([
            "\(normalized) like '%\"phase\":\"final\"%'",
            "\(normalized) like '%\"phase\":\"final_answer\"%'"
        ] + terminalTypes.map { "\(normalized) like '%\"type\":\"\($0)\"%'" })
            .joined(separator: " or ")
        let sql = """
        select
          max(case when \(activity) then ts else 0 end) as latest_activity,
          max(case when \(completion) then ts else 0 end) as latest_done
        from logs indexed by idx_logs_ts
        where thread_id is not null
          and ts >= ?
          and (\(activity) or \(completion))
        group by thread_id
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        let nowEpoch = Int64(now.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 1, nowEpoch - Int64(Self.activityWindow))

        while sqlite3_step(statement) == SQLITE_ROW {
            let latestActivity = sqlite3_column_int64(statement, 0)
            let latestDone = sqlite3_column_int64(statement, 1)
            if latestActivity > latestDone, nowEpoch - latestActivity < Int64(Self.activityWindow) {
                return true
            }
            // Events can share a one-second timestamp. Keep a short grace
            // period so an active stream does not flicker off at that boundary.
            if latestActivity > 0, latestActivity >= latestDone, nowEpoch - latestActivity < 20 {
                return true
            }
        }
        return false
    }

    private static func latestDatabase(prefix: String) -> String? {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        return files.compactMap { url -> (version: Int, path: String)? in
            guard url.pathExtension == "sqlite" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix), let version = Int(name.dropFirst(prefix.count)) else { return nil }
            return (version, url.path)
        }.max { $0.version < $1.version }?.path
    }
}

private final class ClaudeCodeActivityMonitor {
    private struct SessionCache {
        let scannedAt: Date
        let url: URL?
    }
    private struct TranscriptCache {
        let path: String
        let size: UInt64
        let modifiedAt: TimeInterval
        let checkedAt: Date
        let active: Bool
    }

    private var sessionCache = SessionCache(scannedAt: .distantPast, url: nil)
    private var processCache: (checkedAt: Date, running: Bool) = (.distantPast, false)
    private var transcriptCache: TranscriptCache?

    func status() -> (processRunning: Bool, taskRunning: Bool) {
        let processRunning = isClaudeProcessRunning()
        guard processRunning else { return (false, false) }
        guard let sessionURL = latestMainSessionURL() else {
            return (true, false)
        }
        return (true, transcriptIndicatesActive(sessionURL))
    }

    private func isClaudeProcessRunning() -> Bool {
        let now = Date()
        if now.timeIntervalSince(processCache.checkedAt) < 1 {
            return processCache.running
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty=,comm=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let data: Data
        do {
            try process.run()
            // Drain stdout while `ps` is still running. Waiting first can
            // deadlock when a long process list fills the pipe buffer, which
            // would also block balance rendering on the shared monitor queue.
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            processCache = (now, false)
            return false
        }
        guard process.terminationStatus == 0 else {
            processCache = (now, false)
            return false
        }
        // A single unrelated process may contain non-UTF-8 bytes in its
        // arguments. Decode lossily so that one malformed row does not hide
        // an otherwise valid `Claude` process from detection.
        let output = String(decoding: data, as: UTF8.self)
        let running = output.split(separator: "\n").contains { rawLine in
            let line = rawLine.lowercased()
            guard !line.contains("balancebar"),
                  !line.contains("balancebar.app") else { return false }
            let fields = line.split(
                maxSplits: 4,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count >= 4 else { return false }
            let command = URL(fileURLWithPath: String(fields[3])).lastPathComponent
            let arguments = fields.count >= 5 ? String(fields[4]) : ""
            return command == "claude"
                || arguments.hasPrefix("claude ")
                || arguments.contains("/claude ")
                || arguments.contains("/claude-code/")
                || arguments.contains("@anthropic-ai/claude-code")
        }
        processCache = (now, running)
        return running
    }

    private func latestMainSessionURL() -> URL? {
        let now = Date()
        if now.timeIntervalSince(sessionCache.scannedAt) < 2 {
            return sessionCache.url
        }
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            sessionCache = SessionCache(scannedAt: now, url: nil)
            return nil
        }

        var latest: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  !url.path.contains("/subagents/"),
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            if latest == nil || modified > latest!.date {
                latest = (url, modified)
            }
        }
        sessionCache = SessionCache(scannedAt: now, url: latest?.url)
        return latest?.url
    }

    private func transcriptIndicatesActive(_ url: URL) -> Bool {
        guard let identity = fileIdentity(atPath: url.path) else { return false }
        let sizeValue = identity.size
        let modifiedValue = identity.modifiedAt
        if let cached = transcriptCache,
           cached.path == url.path,
           cached.size == sizeValue,
           cached.modifiedAt == modifiedValue,
           Date().timeIntervalSince(cached.checkedAt) < 0.75 {
            return cached.active
        }
        func cache(_ active: Bool) -> Bool {
            transcriptCache = TranscriptCache(
                path: url.path,
                size: sizeValue,
                modifiedAt: modifiedValue,
                checkedAt: Date(),
                active: active
            )
            return active
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return cache(false) }
        defer { try? handle.close() }

        let tailSize: UInt64 = 192 * 1024
        let fileSize = sizeValue
        let offset = fileSize > tailSize ? fileSize - tailSize : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return cache(false)
        }
        guard
            let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8)
        else {
            return cache(false)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        let recentWrite = Date().timeIntervalSince1970 - modifiedValue < 15

        for line in lines.reversed() {
            guard
                let data = line.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = event["type"] as? String
            else {
                continue
            }

            // Claude Code records Esc / interrupt as a synthetic user event
            // with `interruptedMessageId`. It is terminal for the current turn,
            // even though the Claude process and interactive session remain open.
            if event["interruptedMessageId"] != nil {
                return cache(false)
            }

            if type == "assistant", let message = event["message"] as? [String: Any] {
                let stopReason = message["stop_reason"] as? String
                if stopReason == "end_turn" || stopReason == "stop_sequence" {
                    return cache(false)
                }
                if stopReason == "tool_use" {
                    return cache(true)
                }
                if let content = message["content"] as? [[String: Any]],
                   content.contains(where: {
                       let contentType = $0["type"] as? String
                       return contentType == "thinking" || contentType == "tool_use"
                   }) {
                    return cache(true)
                }
                return cache(recentWrite)
            }

            if type == "user", let message = event["message"] as? [String: Any] {
                if let content = message["content"] as? [[String: Any]],
                   !content.isEmpty,
                   content.allSatisfy({ ($0["type"] as? String) == "tool_result" }) {
                    continue
                }
                return cache(recentWrite)
            }

            if type == "progress" || type == "queue-operation" {
                return cache(recentWrite)
            }
        }
        return cache(recentWrite)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private static let menuBarPrimaryFont = NSFont.monospacedDigitSystemFont(
        ofSize: 13,
        weight: .semibold
    )
    private static let menuBarSecondaryFont = NSFont.monospacedDigitSystemFont(
        ofSize: 10,
        weight: .medium
    )
    private static let menuBarIconSlotWidth: CGFloat = 18
    private static let menuBarIconTextSpacing: CGFloat = 6
    private static let menuBarTextRowSpacing: CGFloat = -2
    private static let menuBarTextWidthSlack: CGFloat = 5
    // Fixed API single-line baseline. Keep these independent from the
    // official two-line layout so provider switches cannot alter the result.
    private static let menuBarSingleLineHeight: CGFloat = 18
    private static let menuBarSingleLineTextYOffset: CGFloat = 0.25
    private static let menuBarSingleLineIconYOffset: CGFloat = 0.25
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var statusItemAttachmentCheckScheduled = false
    private var statusItemReanchorAttempts = 0
    private var isStatusMenuTracking = false
    private var statusMenuNeedsRebuild = false
    private let menuBarIconView = RotatingTemplateImageView()
    private let menuBarIconSlot = PassthroughView()
    private let menuBarTextStack = MenuBarTextView()
    private let menuBarContentStack = MenuBarContentView()
    private let menuBarPrimaryLabel = PassthroughTextField(labelWithString: "…")
    private let menuBarSecondaryLabel = PassthroughTextField(labelWithString: "")
    private var isMenuBarContentStackConfigured = false
    private var lastMenuBarIconFrameDiagnostic: String?
    private let dashboardProviderLabel = NSTextField(labelWithString: tr("正在读取…", "Loading…"))
    private let dashboardAmountLabel = NSTextField(labelWithString: "—")
    private let dashboardQuotaLabel = NSTextField(labelWithString: tr("等待额度信息", "Waiting for quota data"))
    private let dashboardResetLabel = NSTextField(labelWithString: "")
    private let dashboardRefreshLabel = NSTextField(labelWithString: "--:--:--")
    private let dashboardStatusLabel = NSTextField(labelWithString: tr("正在连接 CC Switch", "Connecting to CC Switch"))
    private let dashboardCurrentProviderSubtitle = NSTextField(wrappingLabelWithString: "")
    private let dashboardProvidersStack = NSStackView()
    private let dashboardProgressHost = NSView()
    private let dashboardContentHost = NSView()
    private let dashboardLogView = NSTextView()
    private let dashboardMenuPreviewIcon = PassthroughImageView()
    private let dashboardMenuPreviewIconSlot = NSView()
    private let dashboardMenuPreviewText = MenuBarTextView()
    private let dashboardMenuPreviewPrimary = NSTextField(labelWithString: "…")
    private let dashboardMenuPreviewSecondary = NSTextField(labelWithString: "")
    private let dashboardMenuPreviewCapsule = NSView()
    private weak var dashboardMenuBarIconSwitch: NSSwitch?
    private weak var dashboardMenuBarAmountSwitch: NSSwitch?
    private var dashboardMenuPreviewCapsuleLeadingConstraint: NSLayoutConstraint?
    private var dashboardMenuPreviewCapsuleTrailingConstraint: NSLayoutConstraint?
    private var dashboardMenuPreviewTextWidthConstraint: NSLayoutConstraint?
    private let dashboardMenuPreviewChromeInset: CGFloat = 10
    private let dashboardProviderSearch = NSSearchField()
    private let dashboardProviderList = NSStackView()
    private let dashboardProviderCountLabel = NSTextField(labelWithString: "")
    private let monitorQueue = DispatchQueue(label: "local.balancebar.monitor")
    private let activityMonitorQueue = DispatchQueue(
        label: "local.balancebar.activity-monitor",
        qos: .utility
    )
    private let codexActivityMonitor = CodexActivityMonitor()
    private let claudeActivityMonitor = ClaudeCodeActivityMonitor()
    private var codexIconImage: NSImage?
    private var claudeIconImage: NSImage?
    private var claudeThinkingAnimator: ClaudeThinkingAnimator?
    private var dashboard: NSWindow?
    private var dashboardMouseMonitor: Any?
    private var dashboardNavigationButtons: [DashboardSection: NSButton] = [:]
    private var dashboardNavigationRows: [DashboardSection: DashboardNavigationRowView] = [:]
    private var dashboardProviderButtons: [String: NSButton] = [:]
    private var statusLinksHostingView: StatusLinksHostingView?
    private var dashboardSection: DashboardSection = .general
    private var dashboardSelectedProviderID: String?
    private var timer: Timer?
    private var activityTimer: Timer?
    private var statusLinksScrollAnchorTimer: Timer?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var databaseWatchers: [DispatchSourceFileSystemObject] = []
    private var syncWorkItem: DispatchWorkItem?
    private var lastSuccessfulRefresh: Date?
    private var lastProviderID: String?
    private var lastBalanceFetch: Date?
    private var lastOfficialFetch: Date?
    private var lastQuickSwitchFetch: Date?
    private let quickSwitchSummaryLock = NSLock()
    private var quickSwitchSummaries: [String: String] = [:]
    private let balanceRequestLock = NSLock()
    private var balanceRequestsInFlight: Set<String> = []
    private var clientSnapshots: [
        AssistantClient: (providerID: String, snapshot: Snapshot)
    ] = [:]
    private var snapshot = Snapshot.placeholder
    private var activeProviderWebsite: URL?
    private var activeClient: AssistantClient = .codex
    private var isCodexTaskRunning = false
    private var isClaudeTaskRunning = false
    private var isClaudeProcessAvailable = false
    private var isActivityCheckInFlight = false
    private var lastCodexUsageRefresh: Date?
    private var postCodexRefreshDeadline: Date?

    private var showMenuBarReset: Bool {
        get { UserDefaults.standard.object(forKey: "showMenuBarReset") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showMenuBarReset") }
    }

    private var showMenuBarIcon: Bool {
        get { UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showMenuBarIcon") }
    }

    private var showMenuBarAmount: Bool {
        get { UserDefaults.standard.object(forKey: "showMenuBarAmount") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showMenuBarAmount") }
    }

    private var animateCodexActivity: Bool {
        get { UserDefaults.standard.object(forKey: "animateCodexActivity") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "animateCodexActivity") }
    }

    private let providerPollInterval: TimeInterval = 3

    private var activityPollInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: "activityPollInterval")
            return value > 0 ? value : 0.25
        }
        set { UserDefaults.standard.set(newValue, forKey: "activityPollInterval") }
    }

    private var codexUsageRefreshInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: "codexUsageRefreshInterval")
            return value > 0 ? value : 3
        }
        set { UserDefaults.standard.set(newValue, forKey: "codexUsageRefreshInterval") }
    }

    private var postCodexRefreshDuration: TimeInterval {
        get {
            guard let value = UserDefaults.standard.object(forKey: "postCodexRefreshDuration") as? NSNumber else {
                return 12
            }
            return max(0, value.doubleValue)
        }
        set { UserDefaults.standard.set(newValue, forKey: "postCodexRefreshDuration") }
    }

    private var showQuickSwitchMenu: Bool {
        get { UserDefaults.standard.object(forKey: "showQuickSwitchMenu") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showQuickSwitchMenu") }
    }

    private var showOpenCCSwitchMenu: Bool {
        get { UserDefaults.standard.object(forKey: "showOpenCCSwitchMenu") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showOpenCCSwitchMenu") }
    }

    private var showOpenChatGPTMenu: Bool {
        get { UserDefaults.standard.object(forKey: "showOpenChatGPTMenu") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showOpenChatGPTMenu") }
    }

    private var showStatusMenu: Bool {
        get { UserDefaults.standard.object(forKey: "showStatusMenu") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showStatusMenu") }
    }

    private var defaultStatusLinks: [StatusLink] {
        [
            StatusLink(
                title: "OpenAI Status",
                url: "https://status.openai.com/"
            ),
            StatusLink(
                title: tr("Tibo 的动态", "Tibo's Updates"),
                url: "https://x.com/thsottiaux"
            )
        ]
    }

    private var statusLinks: [StatusLink] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "statusLinks"),
                  let links = try? JSONDecoder().decode([StatusLink].self, from: data) else {
                return defaultStatusLinks
            }
            let normalized = links.map { link in
                var link = link
                if link.url == "https://" {
                    link.url = ""
                }
                return link
            }
            if normalized != links,
               let normalizedData = try? JSONEncoder().encode(normalized) {
                UserDefaults.standard.set(normalizedData, forKey: "statusLinks")
            }
            return normalized
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: "statusLinks")
        }
    }

    private var keepMenuOpenAfterRefresh: Bool {
        get { UserDefaults.standard.object(forKey: "keepMenuOpenAfterRefresh") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepMenuOpenAfterRefresh") }
    }

    private var sortProvidersAlphabetically: Bool {
        get { UserDefaults.standard.bool(forKey: "sortProvidersAlphabetically") }
        set { UserDefaults.standard.set(newValue, forKey: "sortProvidersAlphabetically") }
    }

    private var menuBarHorizontalPadding: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: "menuBarHorizontalPadding")
            return value > 0 ? CGFloat(value) : 10
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "menuBarHorizontalPadding") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "BalanceBar", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        configureApplicationMenu()
        NSApp.appearance = nil
        startAppearanceObserver()
        let regularPolicyApplied = NSApp.setActivationPolicy(.regular)
        showDashboard()
        statusMenu.delegate = self
        installStatusItem()
        startDatabaseWatchers()
        startWorkspaceActivationObserver()
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        SwitchLog.write(
            "session started; version=\(version); os=\(ProcessInfo.processInfo.operatingSystemVersionString); database=\(databasePath)",
            category: "lifecycle"
        )
        SwitchLog.write(
            "status chain startup; activation_policy=\(String(describing: NSApp.activationPolicy())); regular_applied=\(regularPolicyApplied); status_visible=\(statusItem.isVisible); menu_bound=\(statusItem.menu === statusMenu); menu_items=\(statusMenu.items.count)",
            category: "ui.status-item"
        )
        SwitchLog.write(
            "preferences; language=\(AppLanguage.selected.rawValue); provider_poll=\(providerPollInterval)s; activity_poll=\(activityPollInterval)s; active_refresh=\(codexUsageRefreshInterval)s; trailing_refresh=\(postCodexRefreshDuration)s",
            level: .debug,
            category: "configuration"
        )
        SwitchLog.write(
            "database watchers started; count=\(databaseWatchers.count)",
            category: "database"
        )
        refresh(forceBalance: true)
        refreshQuickSwitchSummaries(force: true)
        refreshQuickSwitchSummaries(force: true, for: .claude)
        prefetchCurrentBalance(for: .claude)
        refreshCodexActivity()
        // The file watcher handles normal CC Switch writes. This inexpensive
        // read is a fallback for a missed filesystem notification.
        configureRefreshTimers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SwitchLog.write("session terminating", category: "lifecycle")
        timer?.invalidate()
        activityTimer?.invalidate()
        statusLinksScrollAnchorTimer?.invalidate()
        if let dashboardMouseMonitor {
            NSEvent.removeMonitor(dashboardMouseMonitor)
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
        databaseWatchers.forEach { $0.cancel() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openDashboard() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === dashboard else { return }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            SwitchLog.write(
                "dashboard closed; activation_policy=\(String(describing: NSApp.activationPolicy())); status_visible=\(self.statusItem.isVisible)",
                category: "ui.status-item"
            )
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        isStatusMenuTracking = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        isStatusMenuTracking = false
        guard statusMenuNeedsRebuild else { return }
        statusMenuNeedsRebuild = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStatusMenuTracking else { return }
            let refreshDate = self.lastSuccessfulRefresh ?? self.snapshot.date
            self.rebuildStatusMenu(for: self.snapshot, refreshDate: refreshDate)
        }
    }

    @objc private func manualRefresh() {
        performManualRefresh(source: "menu")

        // A native NSMenu closes after invoking an item's action. Re-open the
        // same status-item menu on the next run-loop turn so manual refresh
        // keeps the balance panel visible while the new data is fetched.
        if keepMenuOpenAfterRefresh {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        }
    }

    @objc private func dashboardManualRefresh() {
        performManualRefresh(source: "dashboard")
    }

    private func performManualRefresh(source: String) {
        SwitchLog.write(
            "manual refresh requested; source=\(source); client=\(activeClient.rawValue)",
            category: "refresh"
        )
        refresh(forceBalance: true)
        refreshQuickSwitchSummaries(force: true)
    }

    @objc private func switchProvider(_ sender: NSMenuItem) {
        guard let providerID = sender.representedObject as? String else { return }
        let appType = activeClient.appType
        // The visible menu title also contains the cached balance. Keep the
        // actual Provider name separate for logs and CC Switch synchronization.
        let providerName = Provider.loadChoices(appType: appType)
            .first(where: { $0.id == providerID })?.name ?? sender.title
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let current = Provider.loadChoices(appType: appType)
                .first(where: { $0.isCurrent })
            SwitchLog.write("switch requested; from=\(current?.name ?? "none"); to=\(providerName); id=\(providerID)")
            if current?.id == providerID {
                SwitchLog.write("switch skipped; target is already current")
                return
            }

            let ccSwitch = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.ccswitch.desktop"
            ).first
            let ccSwitchURL = ccSwitch?.bundleURL ?? NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.ccswitch.desktop"
            )
            if let ccSwitch {
                SwitchLog.write("CC Switch graceful stop requested; pid=\(ccSwitch.processIdentifier)")
                ccSwitch.terminate()
                let deadline = Date().addingTimeInterval(4)
                while !ccSwitch.isTerminated && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard ccSwitch.isTerminated else {
                    SwitchLog.write("switch failed; CC Switch did not terminate within 4s")
                    self.render(.error(tr(
                        "切换失败：CC Switch 未能正常重载",
                        "Switch failed: CC Switch could not reload normally"
                    )))
                    return
                }
                SwitchLog.write("CC Switch stopped cleanly")
            } else {
                SwitchLog.write("CC Switch was not running; switching live configuration directly")
            }

            do {
                try Provider.switchCurrent(to: providerID, appType: appType)
                let confirmed = Provider.loadChoices(appType: appType)
                    .first(where: { $0.isCurrent })
                guard confirmed?.id == providerID else {
                    throw NSError(
                        domain: "BalanceBar.SwitchValidation",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: tr("数据库校验未通过", "Database verification failed")]
                    )
                }
                SwitchLog.write("database and \(appType) live config updated; current=\(confirmed?.name ?? providerName)")

                if ccSwitch != nil, let ccSwitchURL {
                    DispatchQueue.main.async {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        configuration.hides = true
                        configuration.addsToRecentItems = false
                        NSWorkspace.shared.openApplication(at: ccSwitchURL, configuration: configuration) { _, error in
                            if let error {
                                SwitchLog.write("CC Switch background reopen failed; error=\(error.localizedDescription)")
                            } else {
                                SwitchLog.write("CC Switch reopened hidden; target=\(providerName)")
                            }
                        }
                    }
                }
                self.lastProviderID = nil
                self.lastBalanceFetch = nil
                self.lastOfficialFetch = nil
                self.refresh(forceBalance: true)
            } catch {
                SwitchLog.write("switch failed; target=\(providerName); error=\(error.localizedDescription)")
                if ccSwitch != nil, let ccSwitchURL {
                    DispatchQueue.main.async {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        configuration.hides = true
                        NSWorkspace.shared.openApplication(at: ccSwitchURL, configuration: configuration) { _, _ in }
                    }
                }
                self.render(.error(tr(
                    "切换失败：\(error.localizedDescription)",
                    "Switch failed: \(error.localizedDescription)"
                )))
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func dashboardLanguageChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyLanguage(language)
        }
    }

    private func applyLanguage(_ language: AppLanguage) {
        SwitchLog.write(
            "language changed; value=\(language.rawValue)",
            category: "configuration"
        )
        AppLanguage.selected = language
        configureApplicationMenu()
        rebuildDashboardForLanguageChange()
        render(snapshot)
        refresh(forceBalance: true)
        refreshQuickSwitchSummaries(force: true)
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu(title: "BalanceBar")

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "BalanceBar")
        applicationItem.submenu = applicationMenu
        applicationMenu.addItem(
            withTitle: tr("关于 BalanceBar", "About BalanceBar"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: tr("隐藏 BalanceBar", "Hide BalanceBar"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = applicationMenu.addItem(
            withTitle: tr("隐藏其他应用", "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(
            withTitle: tr("全部显示", "Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(
            withTitle: tr("退出 BalanceBar", "Quit BalanceBar"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: tr("编辑", "Edit"))
        editItem.submenu = editMenu
        editMenu.autoenablesItems = true
        editMenu.addItem(
            withTitle: tr("撤销", "Undo"),
            action: #selector(UndoManager.undo),
            keyEquivalent: "z"
        )
        let redoItem = editMenu.addItem(
            withTitle: tr("重做", "Redo"),
            action: #selector(UndoManager.redo),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: tr("剪切", "Cut"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: tr("拷贝", "Copy"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: tr("粘贴", "Paste"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: tr("全选", "Select All"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: tr("窗口", "Window"))
        windowItem.submenu = windowMenu
        let closeItem = windowMenu.addItem(
            withTitle: tr("关闭窗口", "Close Window"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = nil
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
    @objc private func openCCSwitch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ccswitch.desktop") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    @objc private func openChatGPT() {
        let applicationURLs: [URL] = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT Classic.app")
        ].compactMap { $0 }
        guard let url = applicationURLs.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            SwitchLog.write(
                "open ChatGPT failed; reason=application-not-found",
                level: .warning,
                category: "ui.menu"
            )
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                SwitchLog.write(
                    "open ChatGPT failed; path=\(url.path); error=\(error.localizedDescription)",
                    level: .warning,
                    category: "ui.menu"
                )
            } else {
                SwitchLog.write(
                    "ChatGPT opened; path=\(url.path)",
                    category: "ui.menu"
                )
            }
        }
    }

    @objc private func openProviderWebsite() {
        guard let activeProviderWebsite else { return }
        NSWorkspace.shared.open(activeProviderWebsite)
    }

    @objc private func openStatusLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func selectDashboardSection(_ sender: NSButton) {
        guard let section = DashboardSection(rawValue: sender.tag) else { return }
        showDashboardSection(section)
    }

    private func makeDashboardSwitch(identifier: String, isOn: Bool) -> NSSwitch {
        let control = NSSwitch()
        control.identifier = NSUserInterfaceItemIdentifier(identifier)
        control.state = isOn ? .on : .off
        control.target = self
        control.action = #selector(dashboardToggleChanged(_:))
        return control
    }

    @objc private func dashboardToggleChanged(_ sender: NSSwitch) {
        SwitchLog.write(
            "preference changed; key=\(sender.identifier?.rawValue ?? "unknown"); enabled=\(sender.state == .on)",
            category: "configuration"
        )
        switch sender.identifier?.rawValue {
        case "showMenuBarIcon":
            if sender.state == .off && !showMenuBarAmount {
                sender.state = .on
            }
            showMenuBarIcon = sender.state == .on
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showMenuBarAmount":
            if sender.state == .off && !showMenuBarIcon {
                sender.state = .on
            }
            showMenuBarAmount = sender.state == .on
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showMenuBarReset":
            showMenuBarReset = sender.state == .on
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showQuickSwitchMenu":
            showQuickSwitchMenu = sender.state == .on
            render(snapshot)
        case "showOpenCCSwitchMenu":
            showOpenCCSwitchMenu = sender.state == .on
            render(snapshot)
        case "showOpenChatGPTMenu":
            showOpenChatGPTMenu = sender.state == .on
            render(snapshot)
        case "showStatusMenu":
            showStatusMenu = sender.state == .on
            render(snapshot)
            if dashboardSection == .menu {
                // Let NSSwitch finish its native transition before replacing
                // the page. Rebuilding synchronously makes the control look
                // like it jumps instead of sliding smoothly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self, self.dashboardSection == .menu else { return }
                    self.showDashboardSection(.menu)
                }
            }
        case "keepMenuOpenAfterRefresh":
            keepMenuOpenAfterRefresh = sender.state == .on
        case "animateCodexActivity":
            animateCodexActivity = sender.state == .on
            setCodexTaskRunning(isCodexTaskRunning, force: true)
        default:
            break
        }
    }

    private func dashboardStatusLinkChanged(
        index: Int,
        field: StatusLinkField,
        value: String
    ) {
        guard index >= 0, index < statusLinks.count else { return }
        var links = statusLinks
        switch field {
        case .title:
            links[index].title = value
        case .url:
            links[index].url = value
        }
        statusLinks = links
        SwitchLog.write(
            "status link edited; index=\(index); field=\(field == .title ? "title" : "url"); length=\(value.count)",
            category: "configuration"
        )
        // Do not rebuild the dashboard while a native SwiftUI TextField is
        // editing. The binding already contains the new value; rebuilding
        // here would discard focus, selection, and the insertion point.
        if !isStatusMenuTracking {
            rebuildStatusMenu(for: snapshot, refreshDate: lastSuccessfulRefresh ?? snapshot.date)
        } else {
            statusMenuNeedsRebuild = true
        }
    }

    private func addStatusLink() {
        let operation = "add"
        SwitchLog.write(
            "status-link button clicked; action=add; page=\(dashboardSection.title)",
            category: "ui.button"
        )
        if let page = dashboardContentHost.subviews.first,
           let editor = firstStatusLinksEditor(in: page) {
            editor.logGeometry(label: "before add")
        }
        let scrollPosition = dashboardScrollPosition(captureLabel: "before add", operation: operation)
        var links = statusLinks
        links.append(StatusLink(title: "", url: ""))
        statusLinks = links
        SwitchLog.write(
            "status link model updated; action=add; count=\(links.count); page=\(dashboardSection.title)",
            category: "ui.layout"
        )
        SwitchLog.write("status link added; count=\(links.count)", category: "configuration")
        render(snapshot)
        if dashboardSection == .menu {
            if !refreshStatusLinksEditorInPlace(scrollPosition: scrollPosition, operation: operation) {
                SwitchLog.write(
                    "status-link editor unavailable; action=add; fallback=page-rebuild; page=\(dashboardSection.title)",
                    level: .warning,
                    category: "ui.scroll"
                )
                showDashboardSection(.menu, restoringScrollPosition: scrollPosition)
            }
        } else {
            SwitchLog.write(
                "status-link button action ignored outside menu page; action=add; page=\(dashboardSection.title)",
                level: .warning,
                category: "ui.button"
            )
        }
    }

    private func removeStatusLink(at index: Int) {
        let operation = "remove"
        SwitchLog.write(
            "status-link button clicked; action=remove; page=\(dashboardSection.title); index=\(index)",
            category: "ui.button"
        )
        if let page = dashboardContentHost.subviews.first,
           let editor = firstStatusLinksEditor(in: page) {
            editor.logGeometry(label: "before remove")
        }
        let scrollPosition = dashboardScrollPosition(captureLabel: "before remove", operation: operation)
        var links = statusLinks
        guard index >= 0, index < links.count else {
            SwitchLog.write(
                "status-link remove rejected; index=\(index); count=\(links.count)",
                level: .warning,
                category: "ui.button"
            )
            return
        }
        links.remove(at: index)
        statusLinks = links
        SwitchLog.write(
            "status link model updated; action=remove; index=\(index); count=\(links.count); page=\(dashboardSection.title)",
            category: "ui.layout"
        )
        SwitchLog.write("status link removed; index=\(index); count=\(links.count)", category: "configuration")
        render(snapshot)
        if dashboardSection == .menu {
            if !refreshStatusLinksEditorInPlace(scrollPosition: scrollPosition, operation: operation) {
                SwitchLog.write(
                    "status-link editor unavailable; action=remove; fallback=page-rebuild; page=\(dashboardSection.title)",
                    level: .warning,
                    category: "ui.scroll"
                )
                showDashboardSection(.menu, restoringScrollPosition: scrollPosition)
            }
        } else {
            SwitchLog.write(
                "status-link button action ignored outside menu page; action=remove; page=\(dashboardSection.title)",
                level: .warning,
                category: "ui.button"
            )
        }
    }

    private func resetStatusLinks() {
        let operation = "reset"
        SwitchLog.write(
            "status-link button clicked; action=reset; page=\(dashboardSection.title)",
            category: "ui.button"
        )
        guard dashboardSection == .menu else {
            SwitchLog.write(
                "status-link reset ignored outside menu page; page=\(dashboardSection.title)",
                level: .warning,
                category: "ui.button"
            )
            return
        }

        if let page = dashboardContentHost.subviews.first,
           let editor = firstStatusLinksEditor(in: page) {
            editor.logGeometry(label: "before reset")
        }
        let scrollPosition = dashboardScrollPosition(captureLabel: "before reset", operation: operation)
        statusLinks = defaultStatusLinks
        SwitchLog.write(
            "status link model reset; action=reset; count=\(defaultStatusLinks.count); page=\(dashboardSection.title)",
            category: "ui.layout"
        )
        SwitchLog.write(
            "status links restored to defaults; count=\(defaultStatusLinks.count)",
            category: "configuration"
        )
        render(snapshot)
        if !refreshStatusLinksEditorInPlace(scrollPosition: scrollPosition, operation: operation) {
            SwitchLog.write(
                "status-link reset editor unavailable; fallback=page-rebuild; page=\(dashboardSection.title)",
                level: .warning,
                category: "ui.scroll"
            )
            showDashboardSection(.menu, restoringScrollPosition: scrollPosition)
        }
    }

    @objc private func dashboardIntervalChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? NSNumber else { return }
        SwitchLog.write(
            "interval changed; key=\(sender.identifier?.rawValue ?? "unknown"); value=\(value.doubleValue)s",
            category: "configuration"
        )
        var refreshTimers = false
        switch sender.identifier?.rawValue {
        case "activityPollInterval":
            activityPollInterval = value.doubleValue
            refreshTimers = true
        case "codexUsageRefreshInterval":
            codexUsageRefreshInterval = value.doubleValue
        case "postCodexRefreshDuration":
            postCodexRefreshDuration = value.doubleValue
            if !isCodexTaskRunning, postCodexRefreshDeadline != nil {
                postCodexRefreshDeadline = value.doubleValue > 0
                    ? Date().addingTimeInterval(value.doubleValue)
                    : nil
            }
        default: return
        }
        if refreshTimers {
            configureRefreshTimers()
        }
    }

    @objc private func dashboardMenuBarPaddingChanged(_ sender: NSSlider) {
        menuBarHorizontalPadding = CGFloat(sender.doubleValue)
        updateStatusItem(for: snapshot)
    }

    @objc private func dashboardSwitchProvider(_ sender: NSButton) {
        guard let providerID = sender.identifier?.rawValue else { return }
        let item = NSMenuItem(title: sender.toolTip ?? "", action: nil, keyEquivalent: "")
        item.representedObject = providerID
        switchProvider(item)
    }

    @objc private func dashboardProviderSearchChanged(_ sender: NSSearchField) {
        rebuildDashboardProviderList()
    }

    @objc private func dashboardSortProviders(_ sender: NSButton) {
        sortProvidersAlphabetically.toggle()
        sender.contentTintColor = sortProvidersAlphabetically ? .controlAccentColor : .secondaryLabelColor
        rebuildDashboardProviderList()
    }

    @objc private func dashboardSelectProvider(_ sender: NSButton) {
        guard let providerID = sender.identifier?.rawValue else { return }
        showDashboardProvider(providerID)
    }

    @objc private func refreshDashboardLog() {
        let text = SwitchLog.recentText() ?? tr("暂无日志", "No logs yet")
        dashboardLogView.textStorage?.setAttributedString(
            styledDashboardLog(text)
        )
        resizeDashboardLogDocument()
        DispatchQueue.main.async { [weak self] in
            self?.resizeDashboardLogDocument()
        }
        dashboardLogView.scrollToEndOfDocument(nil)
    }

    private func resizeDashboardLogDocument() {
        guard let textContainer = dashboardLogView.textContainer,
              let layoutManager = dashboardLogView.layoutManager
        else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let viewport = dashboardLogView.enclosingScrollView?.contentSize
            ?? .zero
        let inset = dashboardLogView.textContainerInset
        dashboardLogView.setFrameSize(NSSize(
            width: max(
                viewport.width,
                ceil(used.width + (inset.width * 2) + 12)
            ),
            height: max(
                viewport.height,
                ceil(used.height + (inset.height * 2))
            )
        ))
    }

    private func vscodeColor(_ hex: UInt32) -> NSColor {
        let red = CGFloat((hex >> 16) & 0xFF) / CGFloat(255)
        let green = CGFloat((hex >> 8) & 0xFF) / CGFloat(255)
        let blue = CGFloat(hex & 0xFF) / CGFloat(255)
        return NSColor(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: 1
        )
    }

    private func styledDashboardLog(_ text: String) -> NSAttributedString {
        let foreground = vscodeColor(0xD4D4D4)
        let timestamp = vscodeColor(0x9DA5B4)
        let debug = vscodeColor(0xDCDCAA)
        let info = vscodeColor(0x23D18B)
        let warning = vscodeColor(0xF9F1A5)
        let error = vscodeColor(0xF14C4C)
        let number = vscodeColor(0x4FC1FF)
        let baseFont = NSFont.monospacedSystemFont(
            ofSize: 10.5,
            weight: .regular
        )
        let emphasizedFont = NSFont.monospacedSystemFont(
            ofSize: 10.5,
            weight: .semibold
        )
        let output = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: baseFont,
                .foregroundColor: foreground
            ]
        )
        let fullRange = NSRange(location: 0, length: output.length)

        func colorMatches(
            _ pattern: String,
            color: NSColor,
            emphasized: Bool = false
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern)
            else { return }
            expression.enumerateMatches(
                in: text,
                range: fullRange
            ) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound
                else { return }
                output.addAttributes([
                    .foregroundColor: color,
                    .font: emphasized ? emphasizedFont : baseFont
                ], range: range)
            }
        }

        // Highlight semantic values, not every run of digits. This avoids
        // fragmenting versions, UUIDs and mixed build identifiers into many
        // unrelated blue patches.
        colorMatches(#"(?<=[\$¥])-?\d+(?:\.\d+)?"#, color: number)
        colorMatches(#"(?<![\w.])-?\d+(?:\.\d+)?(?=%)"#, color: number)
        colorMatches(
            #"(?<==)-?\d+(?:\.\d+)?(?=(?:%|ms|s|m|h|d)?(?:[;,\s\)]|$))"#,
            color: number
        )
        colorMatches(#"(?m)^\[[^\]\n]+\]"#, color: timestamp)
        colorMatches(#"\[DEBUG\]"#, color: debug, emphasized: true)
        colorMatches(#"\[INFO\]"#, color: info, emphasized: true)
        colorMatches(#"\[WARN\]"#, color: warning, emphasized: true)
        colorMatches(#"\[ERROR\]"#, color: error, emphasized: true)

        if let categoryExpression = try? NSRegularExpression(
            pattern: #"(?m)^\[[^\]\n]+\] \[(?:DEBUG|INFO|WARN|ERROR)\] (\[[^\]\n]+\])"#
        ) {
            categoryExpression.enumerateMatches(
                in: text,
                range: fullRange
            ) { match, _, _ in
                guard let range = match?.range(at: 1),
                      range.location != NSNotFound
                else { return }
                output.addAttribute(
                    .foregroundColor,
                    value: foreground,
                    range: range
                )
            }
        }
        return output
    }

    @objc private func revealDashboardLog() {
        NSWorkspace.shared.activateFileViewerSelecting([SwitchLog.fileURL])
    }

    @objc private func openDashboard() {
        NSApp.setActivationPolicy(.regular)
        if let dashboard {
            dashboard.makeKeyAndOrderFront(nil)
            updateDashboard(for: snapshot, refreshDate: lastSuccessfulRefresh ?? snapshot.date)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        showDashboard()
    }

    private func startAppearanceObserver() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Let AppKit publish the new effective appearance before resolving
            // the small number of CALayer-backed adaptive colors.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dashboard?.appearance = nil
                self.rebuildDashboardForAppearanceChange()
            }
        }
    }

    private func rebuildDashboardForAppearanceChange() {
        guard let window = dashboard else { return }
        let selectedSection = dashboardSection
        let selectedProviderID = dashboardSelectedProviderID
        installDashboardLayout(in: window)
        if let selectedProviderID,
           Provider.loadChoices(appType: activeClient.appType)
               .contains(where: { $0.id == selectedProviderID }) {
            showDashboardProvider(selectedProviderID)
        } else {
            showDashboardSection(selectedSection)
        }
        window.displayIfNeeded()
    }

    private func showDashboard() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = DashboardSection.general.title
        window.minSize = NSSize(width: 800, height: 540)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let dashboardToolbar = NSToolbar(identifier: NSToolbar.Identifier("BalanceBarDashboardToolbar"))
        dashboardToolbar.displayMode = .iconOnly
        dashboardToolbar.allowsUserCustomization = false
        dashboardToolbar.autosavesConfiguration = false
        window.toolbar = dashboardToolbar
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.appearance = nil
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Keep the complete standard titlebar button group enabled so AppKit
        // owns the native colors, hover glyphs, pressed state, and zoom action.
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        installDashboardLayout(in: window)
        dashboard = window
        installDashboardMouseMonitor()
        showDashboardSection(.general)
        window.makeKeyAndOrderFront(nil)
        updateDashboard(for: snapshot, refreshDate: lastSuccessfulRefresh ?? snapshot.date)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installDashboardMouseMonitor() {
        guard dashboardMouseMonitor == nil else { return }
        dashboardMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            self?.finishDashboardEditingIfClickIsOutsideInput(event)
            return event
        }
    }

    private func finishDashboardEditingIfClickIsOutsideInput(_ event: NSEvent) {
        guard let dashboard,
              event.window === dashboard,
              let hitView = dashboard.contentView?.hitTest(event.locationInWindow)
        else { return }

        // Keep the field active when the user clicks inside another editable
        // text control. Clicking labels, cards, buttons, or blank space should
        // commit the current editor before the click is handled normally.
        var view: NSView? = hitView
        while let current = view {
            if let textField = current as? NSTextField, textField.isEditable {
                return
            }
            view = current.superview
        }
        guard dashboard.firstResponder != nil else { return }
        dashboard.makeFirstResponder(nil)
    }

    private func installDashboardLayout(in window: NSWindow) {
        let root = NSVisualEffectView(frame: window.contentView?.bounds ?? .zero)
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.08),
            dark: NSColor.black.withAlphaComponent(0.14)
        ).cgColor

        dashboardContentHost.removeFromSuperview()
        dashboardContentHost.subviews.forEach { $0.removeFromSuperview() }
        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let sidebar = makeDashboardSidebar(titlebarHeight: titlebarHeight)
        let contentSurface = NSView()
        contentSurface.wantsLayer = true
        contentSurface.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor(calibratedWhite: 0.94, alpha: 0.82),
            dark: NSColor.black.withAlphaComponent(0.20)
        ).cgColor
        contentSurface.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        dashboardContentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentSurface)
        root.addSubview(sidebar)
        root.addSubview(dashboardContentHost)
        NSLayoutConstraint.activate([
            contentSurface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentSurface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentSurface.topAnchor.constraint(equalTo: root.topAnchor),
            contentSurface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 216),
            dashboardContentHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            dashboardContentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dashboardContentHost.topAnchor.constraint(equalTo: root.topAnchor),
            dashboardContentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        window.contentView = root
    }

    private func rebuildDashboardForLanguageChange() {
        guard let window = dashboard else { return }
        let selectedSection = dashboardSection
        let selectedProviderID = dashboardSelectedProviderID
        installDashboardLayout(in: window)
        if let selectedProviderID,
           Provider.loadChoices(appType: activeClient.appType)
               .contains(where: { $0.id == selectedProviderID }) {
            showDashboardProvider(selectedProviderID)
        } else {
            showDashboardSection(selectedSection)
        }
    }

    private func makeDashboardSidebar(titlebarHeight: CGFloat) -> NSView {
        let sidebar = NSView()
        let panelShadow = NSView()
        panelShadow.wantsLayer = true
        panelShadow.layer?.cornerRadius = 22
        panelShadow.layer?.shadowColor = NSColor.black.cgColor
        panelShadow.layer?.shadowOpacity = dashboardUsesDarkAppearance ? 0.18 : 0.08
        panelShadow.layer?.shadowRadius = 10
        panelShadow.layer?.shadowOffset = NSSize(width: 0, height: -2)
        panelShadow.layer?.masksToBounds = false
        panelShadow.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(panelShadow)

        let sidebarContent = NSView()
        let panel: NSView
        if #available(macOS 26.0, *) {
            let glassPanel = NSGlassEffectView()
            glassPanel.style = .regular
            glassPanel.cornerRadius = 22
            glassPanel.contentView = sidebarContent
            panel = glassPanel
        } else {
            let visualEffectPanel = NSVisualEffectView()
            visualEffectPanel.material = .sidebar
            visualEffectPanel.blendingMode = .withinWindow
            visualEffectPanel.state = .active
            visualEffectPanel.wantsLayer = true
            visualEffectPanel.layer?.cornerRadius = 22
            visualEffectPanel.layer?.masksToBounds = true
            sidebarContent.translatesAutoresizingMaskIntoConstraints = false
            visualEffectPanel.addSubview(sidebarContent)
            NSLayoutConstraint.activate([
                sidebarContent.topAnchor.constraint(equalTo: visualEffectPanel.topAnchor),
                sidebarContent.leadingAnchor.constraint(equalTo: visualEffectPanel.leadingAnchor),
                sidebarContent.trailingAnchor.constraint(equalTo: visualEffectPanel.trailingAnchor),
                sidebarContent.bottomAnchor.constraint(equalTo: visualEffectPanel.bottomAnchor)
            ])
            panel = visualEffectPanel
        }
        panel.translatesAutoresizingMaskIntoConstraints = false
        panelShadow.addSubview(panel)

        let navigation = NSStackView()
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 2
        dashboardNavigationButtons.removeAll()
        dashboardNavigationRows.removeAll()

        navigation.addArrangedSubview(makeDashboardNavigationRow(for: .general))
        navigation.setCustomSpacing(12, after: navigation.arrangedSubviews.last!)

        let appearanceLabel = makeDashboardSidebarGroupTitle(tr("外观", "Appearance"))
        navigation.addArrangedSubview(appearanceLabel)
        navigation.addArrangedSubview(makeDashboardNavigationRow(for: .menuBar))
        navigation.addArrangedSubview(makeDashboardNavigationRow(for: .menu))
        navigation.setCustomSpacing(12, after: navigation.arrangedSubviews.last!)

        let systemLabel = makeDashboardSidebarGroupTitle(tr("系统", "System"))
        navigation.addArrangedSubview(systemLabel)
        navigation.addArrangedSubview(makeDashboardNavigationRow(for: .advanced))
        navigation.addArrangedSubview(makeDashboardNavigationRow(for: .about))

        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebarContent.addSubview(navigation)
        let panelInset: CGFloat = 8
        let navigationTopInset = max(0, titlebarHeight + 14 - panelInset)
        NSLayoutConstraint.activate([
            panelShadow.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: panelInset),
            panelShadow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: panelInset),
            panelShadow.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -panelInset),
            panelShadow.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -panelInset),
            panel.topAnchor.constraint(equalTo: panelShadow.topAnchor),
            panel.leadingAnchor.constraint(equalTo: panelShadow.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: panelShadow.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: panelShadow.bottomAnchor),
            navigation.topAnchor.constraint(equalTo: sidebarContent.topAnchor, constant: navigationTopInset),
            navigation.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor, constant: 14),
            navigation.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor, constant: -14)
        ])
        return sidebar
    }

    private func makeDashboardSidebarGroupTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return label
    }

    private func makeDashboardNavigationRow(for section: DashboardSection) -> NSView {
        let row = DashboardNavigationRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.backgroundColor = NSColor.clear.cgColor
        row.widthAnchor.constraint(equalToConstant: 168).isActive = true
        row.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let button = NSButton(title: "", target: self, action: #selector(selectDashboardSection(_:)))
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .clear
        button.tag = section.rawValue
        button.focusRingType = .none
        button.toolTip = section.title
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])

        let icon = PassthroughImageView()
        icon.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = PassthroughTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)
        row.addSubview(label)
        row.iconView = icon
        row.titleLabel = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        dashboardNavigationButtons[section] = button
        dashboardNavigationRows[section] = row
        row.updateAppearance(animated: false)
        return row
    }

    private func showDashboardSection(
        _ section: DashboardSection,
        restoringScrollPosition scrollPosition: DashboardScrollPosition? = nil
    ) {
        dashboardSection = section
        dashboardSelectedProviderID = nil
        dashboard?.title = section.title
        dashboardNavigationButtons.forEach {
            let isCurrent = $0.key == section
            $0.value.state = isCurrent ? .on : .off
            $0.value.isBordered = false
            $0.value.contentTintColor = .clear
            dashboardNavigationRows[$0.key]?.isSelected = isCurrent
        }
        rebuildDashboardProviderList()
        statusLinksHostingView = nil
        dashboardContentHost.subviews.forEach { $0.removeFromSuperview() }

        let page: NSView
        switch section {
        case .general: page = makeGeneralDashboardPage()
        case .menuBar: page = makeMenuBarDashboardPage()
        case .menu: page = makeMenuDashboardPage()
        case .advanced: page = makeAdvancedDashboardPage()
        case .about: page = makeAboutDashboardPage()
        }
        page.frame = dashboardContentHost.bounds
            page.autoresizingMask = [.width, .height]
        dashboardContentHost.addSubview(page)
        updateDashboard(for: snapshot, refreshDate: lastSuccessfulRefresh ?? snapshot.date)

        if let scrollPosition {
            // The new document view needs one layout pass before its maximum
            // scroll offset is known. Restore asynchronously so adding a row
            // keeps the user's current viewport instead of jumping to the top.
            restoreDashboardScrollPosition(scrollPosition, attempt: 0)
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews {
            if let scrollView = firstScrollView(in: child) { return scrollView }
        }
        return nil
    }

    private func firstStatusLinksEditor(in view: NSView) -> StatusLinksHostingView? {
        if let editor = view as? StatusLinksHostingView { return editor }
        for child in view.subviews {
            if let editor = firstStatusLinksEditor(in: child) { return editor }
        }
        return nil
    }

    private func statusLinksBottomAnchor(
        in page: NSView,
        scrollView: NSScrollView
    ) -> (view: NSView, viewportY: CGFloat)? {
        guard let editor = firstStatusLinksEditor(in: page),
              let rowsStack = editor.superview as? NSStackView,
              let card = rowsStack.superview else {
            return nil
        }
        let edgeY = card.isFlipped ? card.bounds.maxY : card.bounds.minY
        let point = card.convert(
            NSPoint(x: card.bounds.midX, y: edgeY),
            to: scrollView.contentView
        )
        return (card, point.y)
    }

    private func statusLinksBottomAnchorPoint(in view: NSView) -> NSPoint {
        let edgeY = view.isFlipped ? view.bounds.maxY : view.bounds.minY
        return NSPoint(x: view.bounds.midX, y: edgeY)
    }

    private func refreshStatusLinksEditorInPlace(
        scrollPosition: DashboardScrollPosition?,
        operation: String
    ) -> Bool {
        guard let page = dashboardContentHost.subviews.first,
              let editor = firstStatusLinksEditor(in: page)
        else {
            SwitchLog.write(
                "in-place status-link refresh failed; action=\(operation); reason=editor-not-found; host_subviews=\(dashboardContentHost.subviews.count)",
                level: .warning,
                category: "ui.layout"
            )
            return false
        }
        SwitchLog.write(
            "in-place status-link refresh started; action=\(operation); old_rows=\(editor.rowCount); new_rows=\(statusLinks.count); editor_frame=\(DashboardLogging.rect(editor.frame))",
            category: "ui.layout"
        )
        if let scrollPosition {
            startDashboardScrollAnchorMaintenance(scrollPosition, operation: operation)
        } else {
            stopDashboardScrollAnchorMaintenance()
        }
        editor.updateLinks(
            statusLinks,
            animated: true,
            revealAddedRowsAtCompletion: operation == "add"
        ) { [weak self, weak page, weak editor] in
            guard let self, let page, let editor else { return }
            self.stopDashboardScrollAnchorMaintenance()
            page.layoutSubtreeIfNeeded()
            editor.superview?.layoutSubtreeIfNeeded()
            SwitchLog.write(
                "in-place status-link refresh animation completed; action=\(operation); rows=\(editor.rowCount); editor_frame=\(DashboardLogging.rect(editor.frame)); page_frame=\(DashboardLogging.rect(page.frame))",
                category: "ui.layout"
            )
            editor.logGeometry(label: "after \(operation) animation")
            if let scrollPosition {
                self.restoreDashboardScrollPosition(scrollPosition, attempt: 0)
            } else {
                SwitchLog.write(
                    "in-place status-link refresh has no scroll position; action=\(operation)",
                    level: .warning,
                    category: "ui.scroll"
                )
            }
            self.scheduleDashboardScrollLog(label: "after \(operation) animation")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.logDashboardScrollState(label: "after \(operation) settled")
                editor.logGeometry(label: "after \(operation) settled")
            }
        }
        // The height constraint starts animating synchronously above. Correct
        // the clip view once more before returning to the run loop so the
        // first layout pass cannot expose a one-frame jump before the timer
        // gets its first tick.
        if let scrollPosition {
            maintainDashboardScrollAnchor(scrollPosition)
        }
        // Capture one state during the transition so the log distinguishes a
        // smooth layout animation from a late, discrete jump.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.logDashboardScrollState(label: "during \(operation) animation")
        }
        return true
    }

    private func startDashboardScrollAnchorMaintenance(
        _ position: DashboardScrollPosition,
        operation: String
    ) {
        stopDashboardScrollAnchorMaintenance()
        SwitchLog.write(
            "scroll anchor maintenance started; action=\(operation); interval=0.0167s; distanceFromBottom=\(DashboardLogging.number(position.distanceFromBottom))",
            category: "ui.scroll"
        )
        let anchorTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.maintainDashboardScrollAnchor(position)
        }
        statusLinksScrollAnchorTimer = anchorTimer
        RunLoop.main.add(anchorTimer, forMode: .common)
        // Apply once immediately so the first layout pass does not wait for
        // the first timer tick before the viewport begins following the card.
        maintainDashboardScrollAnchor(position)
    }

    private func stopDashboardScrollAnchorMaintenance() {
        statusLinksScrollAnchorTimer?.invalidate()
        statusLinksScrollAnchorTimer = nil
    }

    private func maintainDashboardScrollAnchor(_ position: DashboardScrollPosition) {
        guard let page = dashboardContentHost.subviews.first,
              let scrollView = firstScrollView(in: page),
              let documentView = scrollView.documentView else {
            return
        }

        dashboard?.displayIfNeeded()
        dashboardContentHost.layoutSubtreeIfNeeded()
        page.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let contentView = scrollView.contentView
        // A removal shrinks the document from the bottom. Restore the clip
        // view in document coordinates so AppKit never receives a positive
        // unflipped bounds origin (which is interpreted as an overscroll and
        // snaps the page to the top).
        if position.operation != "add" {
            let targetContentOriginY = dashboardScrollContentOrigin(
                scrollView: scrollView,
                documentView: documentView,
                distanceFromBottom: position.distanceFromBottom
            )
            var bounds = contentView.bounds
            guard abs(bounds.origin.y - targetContentOriginY) > 0.01 else { return }
            bounds.origin.y = targetContentOriginY
            contentView.bounds = bounds
            scrollView.reflectScrolledClipView(contentView)
            return
        }

        if let anchorView = position.bottomAnchorView,
           let targetViewportY = position.bottomAnchorViewportY,
           anchorView === page || anchorView.isDescendant(of: page) {
            let currentViewportY = anchorView.convert(
                statusLinksBottomAnchorPoint(in: anchorView),
                to: contentView
            ).y
            let correction = currentViewportY - targetViewportY
            guard abs(correction) > 0.01 else { return }
            var bounds = contentView.bounds
            // Changing the clip-view bounds origin translates the document in
            // the viewport. Correct by the exact amount the red card edge
            // moved, so the edge stays visually fixed throughout the height
            // animation instead of letting the blue top edge win by default.
            bounds.origin.y += correction
            contentView.bounds = bounds
            scrollView.reflectScrolledClipView(contentView)
            return
        }

        var bounds = contentView.bounds
        guard abs(bounds.origin.y - position.contentOriginY) > 0.01 else { return }
        bounds.origin.y = position.contentOriginY
        contentView.bounds = bounds
        scrollView.reflectScrolledClipView(contentView)
    }

    private func dashboardScrollContentOrigin(
        scrollView: NSScrollView,
        documentView: NSView,
        distanceFromBottom: CGFloat
    ) -> CGFloat {
        let maximumOffset = dashboardMaximumOffset(
            documentView: documentView,
            viewportHeight: scrollView.contentView.bounds.height
        )
        let targetDocumentOriginY = min(
            maximumOffset,
            max(0, maximumOffset - distanceFromBottom)
        )
        return documentView.convert(
            NSPoint(
                x: documentView.bounds.minX,
                y: documentView.bounds.minY + targetDocumentOriginY
            ),
            to: scrollView.contentView
        ).y
    }

    private func dashboardScrollPosition(
        captureLabel: String,
        operation: String
    ) -> DashboardScrollPosition? {
        guard let page = dashboardContentHost.subviews.first,
              let scrollView = firstScrollView(in: page),
              let documentView = scrollView.documentView
        else {
            SwitchLog.write(
                "scroll position capture failed; label=\(captureLabel); action=\(operation); page=\(dashboardSection.title); reason=scroll-view-not-found",
                level: .warning,
                category: "ui.scroll"
            )
            return nil
        }
        page.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let maximumOffset = dashboardMaximumOffset(
            documentView: documentView,
            viewportHeight: scrollView.contentView.bounds.height
        )
        let visibleDocumentRect = scrollView.contentView.convert(
            scrollView.contentView.bounds,
            to: documentView
        )
        let originY = min(
            maximumOffset,
            max(0, visibleDocumentRect.origin.y)
        )
        let bottomAnchor = statusLinksBottomAnchor(
            in: page,
            scrollView: scrollView
        )
        let bottomAnchorIsVisible = bottomAnchor.map { anchor in
            let bounds = scrollView.contentView.bounds
            return anchor.viewportY >= bounds.minY - 1
                && anchor.viewportY <= bounds.maxY + 1
        } ?? false
        let activeBottomAnchor = bottomAnchorIsVisible ? bottomAnchor : nil
        let position = DashboardScrollPosition(
            operation: operation,
            visibleDocumentOriginY: originY,
            contentOriginY: scrollView.contentView.bounds.origin.y,
            distanceFromBottom: max(0, maximumOffset - originY),
            previousMaximumOffset: maximumOffset,
            bottomAnchorView: activeBottomAnchor?.view,
            bottomAnchorViewportY: activeBottomAnchor?.viewportY
        )
        SwitchLog.write(
            "scroll position captured; label=\(captureLabel); action=\(operation); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView)); visibleDocumentOriginY=\(DashboardLogging.number(originY)); contentOriginY=\(DashboardLogging.number(position.contentOriginY)); distanceFromBottom=\(DashboardLogging.number(position.distanceFromBottom)); previousMaximumOffset=\(DashboardLogging.number(maximumOffset)); bottom_anchor=\(activeBottomAnchor.map { DashboardLogging.number($0.viewportY) } ?? "inactive")",
            category: "ui.scroll"
        )
        return position
    }

    private func restoreDashboardScrollPosition(
        _ position: DashboardScrollPosition,
        attempt: Int
    ) {
        let delay = attempt == 0 ? 0 : 0.06
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.applyDashboardScrollPosition(position, attempt: attempt)
        }
    }

    private func applyDashboardScrollPosition(
        _ position: DashboardScrollPosition,
        attempt: Int
    ) {
        guard let page = dashboardContentHost.subviews.first,
              let scrollView = firstScrollView(in: page),
              let documentView = scrollView.documentView
        else {
            SwitchLog.write(
                "scroll restore aborted; action=\(position.operation); attempt=\(attempt); reason=scroll-view-not-found",
                level: .warning,
                category: "ui.scroll"
            )
            return
        }
        SwitchLog.write(
            "scroll restore begin; action=\(position.operation); attempt=\(attempt); target_visibleDocumentOriginY=\(DashboardLogging.number(position.visibleDocumentOriginY)); captured_contentOriginY=\(DashboardLogging.number(position.contentOriginY)); target_distanceFromBottom=\(DashboardLogging.number(position.distanceFromBottom)); previousMaximumOffset=\(DashboardLogging.number(position.previousMaximumOffset)); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView))",
            category: "ui.scroll"
        )
        dashboard?.displayIfNeeded()
        dashboardContentHost.layoutSubtreeIfNeeded()
        page.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        if position.operation != "add" {
            let targetContentOriginY = dashboardScrollContentOrigin(
                scrollView: scrollView,
                documentView: documentView,
                distanceFromBottom: position.distanceFromBottom
            )
            var bounds = scrollView.contentView.bounds
            let correction = targetContentOriginY - bounds.origin.y
            bounds.origin.y = targetContentOriginY
            scrollView.contentView.bounds = bounds
            scrollView.reflectScrolledClipView(scrollView.contentView)
            SwitchLog.write(
                "scroll restore applied; action=\(position.operation); attempt=\(attempt); anchor=document-distance; target_contentOriginY=\(DashboardLogging.number(targetContentOriginY)); correction=\(DashboardLogging.number(correction)); actual_contentOriginY=\(DashboardLogging.number(scrollView.contentView.bounds.origin.y)); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView))",
                category: "ui.scroll"
            )
            if attempt < 2 {
                restoreDashboardScrollPosition(position, attempt: attempt + 1)
            }
            return
        }

        if let anchorView = position.bottomAnchorView,
           let targetViewportY = position.bottomAnchorViewportY,
           anchorView === page || anchorView.isDescendant(of: page) {
            let currentViewportY = anchorView.convert(
                statusLinksBottomAnchorPoint(in: anchorView),
                to: scrollView.contentView
            ).y
            let correction = currentViewportY - targetViewportY
            if abs(correction) > 0.01 {
                var bounds = scrollView.contentView.bounds
                bounds.origin.y += correction
                scrollView.contentView.bounds = bounds
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            SwitchLog.write(
                "scroll restore applied; action=\(position.operation); attempt=\(attempt); anchor=card-bottom; target_viewportY=\(DashboardLogging.number(targetViewportY)); actual_viewportY=\(DashboardLogging.number(currentViewportY)); correction=\(DashboardLogging.number(correction)); actual_contentOriginY=\(DashboardLogging.number(scrollView.contentView.bounds.origin.y)); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView))",
                category: "ui.scroll"
            )
            if attempt < 2 {
                restoreDashboardScrollPosition(position, attempt: attempt + 1)
            }
            return
        }

        var bounds = scrollView.contentView.bounds
        let correction = position.contentOriginY - bounds.origin.y
        bounds.origin.y = position.contentOriginY
        scrollView.contentView.bounds = bounds
        scrollView.reflectScrolledClipView(scrollView.contentView)
        SwitchLog.write(
            "scroll restore applied; action=\(position.operation); attempt=\(attempt); anchor=content-origin; target_contentOriginY=\(DashboardLogging.number(position.contentOriginY)); correction=\(DashboardLogging.number(correction)); actual_contentOriginY=\(DashboardLogging.number(scrollView.contentView.bounds.origin.y)); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView))",
            category: "ui.scroll"
        )

        // A second pass handles the case where Auto Layout updates the
        // document frame immediately after the first bounds assignment.
        if attempt < 2 {
            restoreDashboardScrollPosition(position, attempt: attempt + 1)
        }
    }

    private func dashboardMaximumOffset(
        documentView: NSView,
        viewportHeight: CGFloat
    ) -> CGFloat {
        max(0, documentView.bounds.height - viewportHeight)
    }

    private func dashboardScrollMetrics(
        scrollView: NSScrollView,
        documentView: NSView
    ) -> String {
        let contentView = scrollView.contentView
        let bounds = contentView.bounds
        let viewportRect = contentView.convert(bounds, to: documentView)
        let boundsMaximum = max(0, documentView.bounds.height - bounds.height)
        let frameMaximum = max(0, documentView.frame.height - bounds.height)
        return "page=\(dashboardSection.title); links=\(statusLinks.count); content_originY=\(DashboardLogging.number(bounds.origin.y)); content_height=\(DashboardLogging.number(bounds.height)); document_frame=\(DashboardLogging.rect(documentView.frame)); document_bounds=\(DashboardLogging.rect(documentView.bounds)); viewport_document=\(DashboardLogging.rect(viewportRect)); maxOffset(bounds)=\(DashboardLogging.number(boundsMaximum)); maxOffset(frame)=\(DashboardLogging.number(frameMaximum))"
    }

    private func logDashboardScrollState(label: String) {
        guard let page = dashboardContentHost.subviews.first,
              let scrollView = firstScrollView(in: page),
              let documentView = scrollView.documentView else {
            SwitchLog.write(
                "scroll state; label=\(label); page=\(dashboardSection.title); reason=scroll-view-not-found",
                level: .warning,
                category: "ui.scroll"
            )
            return
        }
        page.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        SwitchLog.write(
            "scroll state; label=\(label); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView))",
            category: "ui.scroll"
        )
    }

    private func scheduleDashboardScrollLog(label: String) {
        DispatchQueue.main.async { [weak self] in
            self?.logDashboardScrollState(label: label)
        }
    }

    private func rebuildDashboardProviderList() {
        guard dashboard != nil else { return }
        for child in dashboardProviderList.arrangedSubviews {
            dashboardProviderList.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        dashboardProviderButtons.removeAll()

        let query = dashboardProviderSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var choices = Provider.loadChoices(appType: activeClient.appType).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
        if sortProvidersAlphabetically {
            choices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        dashboardProviderCountLabel.stringValue = tr(
            "\(Provider.loadChoices(appType: activeClient.appType).count) 个",
            "\(Provider.loadChoices(appType: activeClient.appType).count)"
        )

        for choice in choices {
            let button = NSButton(title: choice.name, target: self, action: #selector(dashboardSelectProvider(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            let isSelected = dashboardSelectedProviderID == choice.id
            button.isBordered = isSelected
            button.state = isSelected ? .on : .off
            button.alignment = .left
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 13, weight: choice.isCurrent ? .semibold : .regular)
            button.contentTintColor = isSelected ? .controlAccentColor : (choice.isCurrent ? .labelColor : .secondaryLabelColor)
            button.focusRingType = .none
            button.identifier = NSUserInterfaceItemIdentifier(choice.id)
            button.toolTip = choice.isCurrent
                ? tr("当前供应商", "Current Provider")
                : tr("查看 \(choice.name)", "View \(choice.name)")
            if let iconURL = Bundle.main.url(forResource: "CodexIcon", withExtension: "svg"),
               let image = NSImage(contentsOf: iconURL) {
                image.size = NSSize(width: 16, height: 16)
                image.isTemplate = true
                button.image = image
            }
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 228).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            dashboardProviderButtons[choice.id] = button
            dashboardProviderList.addArrangedSubview(button)
        }
    }

    private func showDashboardProvider(_ providerID: String) {
        guard let choice = Provider.loadChoices(appType: activeClient.appType)
            .first(where: { $0.id == providerID }) else { return }
        dashboardSelectedProviderID = providerID
        dashboard?.title = choice.name
        dashboardNavigationButtons.values.forEach {
            $0.state = .off
            $0.isBordered = false
            $0.contentTintColor = .labelColor
        }
        rebuildDashboardProviderList()
        dashboardContentHost.subviews.forEach { $0.removeFromSuperview() }
        let page = makeProviderDashboardPage(choice)
        page.frame = dashboardContentHost.bounds
        page.autoresizingMask = [.width, .height]
        dashboardContentHost.addSubview(page)
        updateDashboard(for: snapshot, refreshDate: lastSuccessfulRefresh ?? snapshot.date)
    }

    private func makeSettingsPage(_ sections: [NSView]) -> NSView {
        let root = NSView()
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // Keep the scrollbar discoverable on dense settings pages. The
        // document is taller than the viewport when the status-link editor is
        // present, so hiding the scroller makes the add control look missing.
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        documentView.addSubview(stack)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 62),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -34),
            // The stack must fit inside the document, but it should keep its
            // natural height when the page is shorter than the viewport.
            // Using an equality here makes AppKit stretch the first card to
            // consume all remaining space.
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -34)
        ])
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return root
    }

    private func makeSettingsSection(_ title: String, rows: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.94),
            dark: NSColor.white.withAlphaComponent(0.065)
        ).cgColor
        card.layer?.borderColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.95),
            dark: NSColor.white.withAlphaComponent(0.075)
        ).cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = dashboardUsesDarkAppearance ? 0.20 : 0.08
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = NSSize(width: 0, height: -3)
        card.layer?.masksToBounds = false

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.distribution = .fill
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.setContentHuggingPriority(.required, for: .vertical)
        // The card has an explicit height that changes when status-link rows
        // are added or removed. Let the stack follow that constraint instead
        // of preserving the previous intrinsic height and leaving an empty
        // gravity area below the editor.
        rowsStack.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        card.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: card.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        for (index, row) in rows.enumerated() {
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if index < rows.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
                rowsStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -32).isActive = true
            }
        }

        // NSView has no intrinsic height. Give the card the exact height of
        // its rows so a short settings page cannot stretch the first row to
        // fill the scroll viewport.
        let rowsHeight = rows.reduce(CGFloat(0)) { partial, row in
            let explicitHeight = row.constraints.first {
                ($0.firstItem as? NSView) === row &&
                    $0.firstAttribute == .height &&
                    $0.relation == .equal
            }?.constant
            let fittingHeight: CGFloat
            if let editor = row as? StatusLinksHostingView {
                fittingHeight = editor.layoutHeight
            } else {
                fittingHeight = row.fittingSize.height
            }
            return partial + max(1, explicitHeight ?? fittingHeight)
        }
        let separatorHeight = CGFloat(max(0, rows.count - 1))
        card.heightAnchor.constraint(
            equalToConstant: max(1, ceil(rowsHeight + separatorHeight))
        ).isActive = true

        let section = NSStackView(views: [heading, card])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 11
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        if let editor = rows.first(where: { $0 is StatusLinksHostingView }) as? StatusLinksHostingView {
            DispatchQueue.main.async { [weak editor] in
                editor?.logGeometry(label: "initial")
            }
        }
        return section
    }

    private func makeSettingsRow(
        _ title: String,
        subtitle: String? = nil,
        subtitleLabel: NSTextField? = nil,
        control: NSView? = nil,
        minimumHeight: CGFloat = 58
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: max(62, minimumHeight)).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.isEditable = false
        label.isSelectable = false
        let labels = NSStackView(views: [label])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        if let subtitle, !subtitle.isEmpty {
            let detail = subtitleLabel ?? NSTextField(wrappingLabelWithString: subtitle)
            detail.stringValue = subtitle
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.isEditable = false
            detail.isSelectable = false
            labels.addArrangedSubview(detail)
        }
        labels.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        var constraints = [
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 11),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -11)
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(control)
            constraints.append(contentsOf: [
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -20)
            ])
        } else {
            constraints.append(labels.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -20))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func makeGeneralDashboardPage() -> NSView {
        let openButton = NSButton(title: tr("打开 CC Switch", "Open CC Switch"), target: self, action: #selector(openCCSwitch))
        let currentName = Provider.loadChoices(appType: activeClient.appType)
            .first(where: { $0.isCurrent })?.name ?? tr("未找到", "Not Found")
        let currentProviderText = tr(
            "当前供应商：\(currentName)",
            "Current Provider: \(currentName)"
        )
        let system = makeSettingsSection(tr("系统", "System"), rows: [
            makeSettingsRow(
                "CC Switch",
                subtitle: currentProviderText,
                subtitleLabel: dashboardCurrentProviderSubtitle,
                control: openButton
            )
        ])

        let activeRefreshPopup = makeIntervalPopup(
            values: [
                (1, tr("每 1 秒", "Every 1 sec")),
                (2, tr("每 2 秒", "Every 2 sec")),
                (3, tr("每 3 秒", "Every 3 sec")),
                (5, tr("每 5 秒", "Every 5 sec")),
                (10, tr("每 10 秒", "Every 10 sec"))
            ],
            selected: codexUsageRefreshInterval,
            identifier: "codexUsageRefreshInterval"
        )
        let trailingRefreshPopup = makeIntervalPopup(
            values: [
                (0, tr("不继续", "Off")),
                (6, tr("持续 6 秒", "For 6 sec")),
                (12, tr("持续 12 秒", "For 12 sec")),
                (30, tr("持续 30 秒", "For 30 sec"))
            ],
            selected: postCodexRefreshDuration,
            identifier: "postCodexRefreshDuration"
        )
        let runningLabel = NSTextField(labelWithString: tr("运行中", "Running"))
        let trailingLabel = NSTextField(labelWithString: tr("结束后", "After"))
        [runningLabel, trailingLabel].forEach {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .right
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        [activeRefreshPopup, trailingRefreshPopup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 108).isActive = true
        }
        let runningControls = NSStackView(views: [
            runningLabel, activeRefreshPopup
        ])
        runningControls.orientation = .horizontal
        runningControls.alignment = .centerY
        runningControls.spacing = 7
        let trailingControls = NSStackView(views: [
            trailingLabel, trailingRefreshPopup
        ])
        trailingControls.orientation = .horizontal
        trailingControls.alignment = .centerY
        trailingControls.spacing = 7
        let activeRefreshControls = NSStackView(views: [
            runningControls, trailingControls
        ])
        activeRefreshControls.orientation = .vertical
        activeRefreshControls.alignment = .trailing
        activeRefreshControls.spacing = 5
        let refreshButton = NSButton(title: tr("立即刷新", "Refresh Now"), target: self, action: #selector(dashboardManualRefresh))
        let refreshing = makeSettingsSection(tr("刷新", "Refresh"), rows: [
            makeSettingsRow(
                tr("任务期间余量更新频率", "Balance Updates During Tasks"),
                subtitle: tr(
                    "Agent 运行时请求当前供应商的余量",
                    "Requests the current Provider's balance while an Agent is running"
                ),
                control: activeRefreshControls,
                minimumHeight: 76
            ),
            makeSettingsRow(tr("余额数据", "Balance Data"), subtitle: tr("立即重新读取当前供应商", "Reload the current Provider now"), control: refreshButton)
        ])

        let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopup.target = self
        languagePopup.action = #selector(dashboardLanguageChanged(_:))
        for (index, language) in AppLanguage.allCases.enumerated() {
            languagePopup.addItem(withTitle: language.localizedTitle)
            languagePopup.item(at: index)?.representedObject = language.rawValue
            if language == AppLanguage.selected {
                languagePopup.selectItem(at: index)
            }
        }
        let app = makeSettingsSection(tr("应用", "Application"), rows: [
            makeSettingsRow(
                tr("语言", "Language"),
                subtitle: tr("更改后立即应用到整个界面", "Changes apply to the entire interface immediately"),
                control: languagePopup
            ),
        ])
        return makeSettingsPage([system, refreshing, app])
    }

    private func makeStatusLinksEditor() -> NSView {
        let editor = StatusLinksHostingView(
            links: statusLinks,
            onChange: { [weak self] index, field, value in
                self?.dashboardStatusLinkChanged(index: index, field: field, value: value)
            },
            onAdd: { [weak self] in
                self?.addStatusLink()
            },
            onRemove: { [weak self] index in
                self?.removeStatusLink(at: index)
            },
            onReset: { [weak self] in
                self?.resetStatusLinks()
            }
        )
        statusLinksHostingView = editor
        return editor
    }

    private func makeMenuDashboardPage() -> NSView {
        let quickSwitch = makeDashboardSwitch(
            identifier: "showQuickSwitchMenu",
            isOn: showQuickSwitchMenu
        )
        let openCC = makeDashboardSwitch(
            identifier: "showOpenCCSwitchMenu",
            isOn: showOpenCCSwitchMenu
        )
        let keepOpen = makeDashboardSwitch(
            identifier: "keepMenuOpenAfterRefresh",
            isOn: keepMenuOpenAfterRefresh
        )

        let items = makeSettingsSection(tr("展开菜单", "Dropdown Menu"), rows: [
            makeSettingsRow(tr("快速切换", "Quick Switch"), subtitle: tr("显示 CC Switch 供应商子菜单", "Show the CC Switch Provider submenu"), control: quickSwitch),
            makeSettingsRow(tr("刷新后保持展开", "Keep Open After Refresh"), subtitle: tr("点击立即刷新后重新打开菜单", "Reopen the menu after Refresh Now"), control: keepOpen)
        ])
        let openMainWindow = makeDashboardSwitch(
            identifier: "showOpenDashboardMenu",
            isOn: true
        )
        openMainWindow.isEnabled = false
        openMainWindow.toolTip = tr(
            "打开主窗口入口始终显示",
            "The Open Main Window item is always shown"
        )

        var projectRows: [NSView] = [
            makeSettingsRow(
                tr("打开主窗口", "Open Main Window"),
                control: openMainWindow
            ),
            makeSettingsRow(
                tr("打开 ChatGPT", "Open ChatGPT"),
                subtitle: tr("显示 ChatGPT 启动项", "Show the ChatGPT launch item"),
                control: makeDashboardSwitch(
                    identifier: "showOpenChatGPTMenu",
                    isOn: showOpenChatGPTMenu
                )
            ),
            makeSettingsRow(
                tr("打开 CC Switch", "Open CC Switch"),
                subtitle: tr("显示 CC Switch 启动项", "Show the CC Switch launch item"),
                control: openCC
            )
        ]
        if showStatusMenu {
            projectRows.append(makeSettingsRow(
                tr("查看状态", "View Status"),
                subtitle: tr("显示可自定义的服务状态链接", "Show customizable service status links"),
                control: makeDashboardSwitch(identifier: "showStatusMenu", isOn: showStatusMenu)
            ))
            projectRows.append(makeStatusLinksEditor())
        } else {
            projectRows.append(makeSettingsRow(
                tr("查看状态", "View Status"),
                subtitle: tr("在菜单栏中显示状态链接", "Show status links in the menu bar"),
                control: makeDashboardSwitch(identifier: "showStatusMenu", isOn: showStatusMenu)
            ))
        }
        let projects = makeSettingsSection(tr("打开项目", "Open Project"), rows: projectRows)
        return makeSettingsPage([items, projects])
    }

    private func makeDashboardLogViewer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 190).isActive = true

        dashboardLogView.isEditable = false
        dashboardLogView.isSelectable = true
        dashboardLogView.isRichText = true
        dashboardLogView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let vscodeForeground = vscodeColor(0xD4D4D4)
        let vscodeBackground = vscodeColor(0x1E1E1E)
        let vscodeSelection = vscodeColor(0x264F78)
        dashboardLogView.textColor = vscodeForeground
        dashboardLogView.backgroundColor = vscodeBackground
        dashboardLogView.drawsBackground = true
        let selectionAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .backgroundColor: vscodeSelection
        ]
        dashboardLogView.selectedTextAttributes = selectionAttributes
        dashboardLogView.isVerticallyResizable = true
        dashboardLogView.isHorizontallyResizable = true
        dashboardLogView.autoresizingMask = []
        dashboardLogView.minSize = .zero
        dashboardLogView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        dashboardLogView.textContainerInset = NSSize(width: 8, height: 8)
        dashboardLogView.textContainer?.widthTracksTextView = false
        dashboardLogView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scroll = NSScrollView()
        scroll.documentView = dashboardLogView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = dashboardLogView.backgroundColor
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        refreshDashboardLog()
        return container
    }

    private func makeAdvancedDashboardPage() -> NSView {
        let animation = makeDashboardSwitch(
            identifier: "animateCodexActivity",
            isOn: animateCodexActivity
        )
        let activity = makeSettingsSection(tr("任务状态", "Task Status"), rows: [
            makeSettingsRow(
                tr("任务运行时播放图标动画", "Animate Icon While a Task Is Running"),
                control: animation
            )
        ])

        let refreshLog = NSButton(title: tr("重新载入", "Reload"), target: self, action: #selector(refreshDashboardLog))
        let revealLog = NSButton(title: tr("在 Finder 中显示", "Show in Finder"), target: self, action: #selector(revealDashboardLog))
        let logButtons = NSStackView(views: [refreshLog, revealLog])
        logButtons.orientation = .horizontal
        logButtons.spacing = 8
        let logs = makeSettingsSection(tr("诊断", "Diagnostics"), rows: [
            makeSettingsRow(
                tr("调试日志", "Debug Log"),
                subtitle: tr(
                    "记录运行状态与错误",
                    "Records runtime status and errors"
                ),
                control: logButtons
            ),
            makeDashboardLogViewer()
        ])
        return makeSettingsPage([activity, logs])
    }

    private func makeAboutDashboardPage() -> NSView {
        let root = NSView()
        let icon = NSImageView()
        if let iconURL = Bundle.main.url(forResource: "BalanceBar", withExtension: "icns") {
            icon.image = NSImage(contentsOf: iconURL)
        }
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let name = NSTextField(labelWithString: "BalanceBar")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.10.5"
        let isDevBuild = Bundle.main.bundleIdentifier == devBundleIdentifier
        let version = NSTextField(labelWithString: tr(
            "版本 \(appVersion)",
            "Version \(appVersion)"
        ) + (isDevBuild ? " · Dev" : ""))
        version.textColor = .secondaryLabelColor
        let detail = NSTextField(labelWithString: tr(
            "基于 CC Switch 的菜单栏余量查看工具",
            "A CC Switch-based menu bar balance viewer"
        ))
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, name, version, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 92)
        ])
        return root
    }

    private func makeProviderDashboardPage(_ choice: ProviderChoice) -> NSView {
        dashboardProviderLabel.stringValue = choice.name
        dashboardProviderLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        let status = NSTextField(labelWithString: choice.isCurrent
            ? tr("当前供应商", "Current Provider")
            : tr("可用供应商", "Available Provider"))
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = choice.isCurrent ? .systemGreen : .secondaryLabelColor
        let heading = NSStackView(views: [dashboardProviderLabel, status])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        quickSwitchSummaryLock.lock()
        let cachedSummary = quickSwitchSummaries[choice.id]
        quickSwitchSummaryLock.unlock()
        dashboardAmountLabel.stringValue = choice.isCurrent ? snapshot.overviewLargeAmount : (cachedSummary ?? tr("正在读取…", "Loading…"))
        dashboardAmountLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        dashboardQuotaLabel.stringValue = tr("剩余额度", "Remaining Balance")
        dashboardResetLabel.stringValue = choice.isCurrent
            ? snapshot.overviewReset(refreshDate: lastSuccessfulRefresh, formatter: Self.timeFormatter)
            : tr("选择为当前供应商后显示详细重置时间", "Select this Provider to display detailed reset information")
        let usage = makeSettingsSection(tr("用量", "Usage"), rows: [
            makeSettingsRow(tr("剩余额度", "Remaining Balance"), subtitle: dashboardResetLabel.stringValue, control: dashboardAmountLabel, minimumHeight: 76)
        ])

        let action: NSButton
        if choice.isCurrent {
            action = NSButton(title: tr("立即刷新", "Refresh Now"), target: self, action: #selector(dashboardManualRefresh))
        } else {
            action = NSButton(title: tr("切换到此供应商", "Switch to This Provider"), target: self, action: #selector(dashboardSwitchProvider(_:)))
            action.identifier = NSUserInterfaceItemIdentifier(choice.id)
            action.toolTip = choice.name
        }
        let connection = makeSettingsSection("CC Switch", rows: [
            makeSettingsRow(tr("同步状态", "Sync Status"), subtitle: choice.isCurrent
                ? tr("正在跟随此供应商", "Following this Provider")
                : tr("当前未使用此供应商", "This Provider is not currently active"), control: action)
        ])
        return makeSettingsPage([heading, usage, connection])
    }

    private func makePageHeader(_ title: String, subtitle: String) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func makeOverviewDashboardPage() -> NSView {
        let root = NSView()
        let header = makePageHeader(tr("概览", "Overview"), subtitle: tr("当前余额、同步状态和 Codex 供应商", "Current balance, sync status, and Codex Provider"))

        dashboardProviderLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        dashboardProviderLabel.lineBreakMode = .byTruncatingTail
        dashboardRefreshLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dashboardRefreshLabel.textColor = .secondaryLabelColor
        dashboardRefreshLabel.alignment = .right
        let providerSpacer = NSView()
        let providerRow = NSStackView(views: [dashboardProviderLabel, providerSpacer, dashboardRefreshLabel])
        providerRow.orientation = .horizontal
        providerRow.alignment = .centerY

        dashboardQuotaLabel.font = .systemFont(ofSize: 13, weight: .medium)
        dashboardResetLabel.font = .systemFont(ofSize: 13)
        dashboardResetLabel.textColor = .secondaryLabelColor
        let quotaStack = NSStackView(views: [dashboardQuotaLabel, dashboardResetLabel])
        quotaStack.orientation = .vertical
        quotaStack.alignment = .leading
        quotaStack.spacing = 5

        dashboardAmountLabel.font = .monospacedDigitSystemFont(ofSize: 42, weight: .semibold)
        dashboardAmountLabel.alignment = .right
        let quotaSpacer = NSView()
        let quotaRow = NSStackView(views: [quotaStack, quotaSpacer, dashboardAmountLabel])
        quotaRow.orientation = .horizontal
        quotaRow.alignment = .centerY

        dashboardProgressHost.translatesAutoresizingMaskIntoConstraints = false
        dashboardProgressHost.heightAnchor.constraint(equalToConstant: 6).isActive = true
        dashboardStatusLabel.font = .systemFont(ofSize: 12)
        dashboardStatusLabel.textColor = .secondaryLabelColor

        let separator = NSBox()
        separator.boxType = .separator
        let providersTitle = NSTextField(labelWithString: tr("供应商", "Providers"))
        providersTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        dashboardProvidersStack.orientation = .vertical
        dashboardProvidersStack.alignment = .leading
        dashboardProvidersStack.spacing = 0

        let stack = NSStackView(views: [
            header, providerRow, quotaRow, dashboardProgressHost,
            dashboardStatusLabel, separator, providersTitle, dashboardProvidersStack
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(24, after: header)
        stack.setCustomSpacing(7, after: dashboardProgressHost)
        stack.setCustomSpacing(18, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            providerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            quotaRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dashboardProgressHost.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dashboardProvidersStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }

    private func makeMenuBarDashboardPage() -> NSView {
        let previewContent = NSView()
        let preview: NSView
        if #available(macOS 26.0, *) {
            let glassPreview = NSGlassEffectView()
            glassPreview.style = .regular
            glassPreview.cornerRadius = 7
            glassPreview.contentView = previewContent
            preview = glassPreview
        } else {
            let visualEffectPreview = NSVisualEffectView()
            visualEffectPreview.material = .menu
            visualEffectPreview.state = .active
            visualEffectPreview.wantsLayer = true
            visualEffectPreview.layer?.cornerRadius = 7
            visualEffectPreview.layer?.backgroundColor = dashboardAdaptiveColor(
                light: NSColor.white.withAlphaComponent(0.64),
                dark: NSColor.black.withAlphaComponent(0.18)
            ).cgColor
            visualEffectPreview.layer?.borderColor = dashboardAdaptiveColor(
                light: NSColor.white.withAlphaComponent(0.72),
                dark: NSColor.white.withAlphaComponent(0.08)
            ).cgColor
            visualEffectPreview.layer?.borderWidth = 0.5
            previewContent.translatesAutoresizingMaskIntoConstraints = false
            visualEffectPreview.addSubview(previewContent)
            NSLayoutConstraint.activate([
                previewContent.topAnchor.constraint(equalTo: visualEffectPreview.topAnchor),
                previewContent.leadingAnchor.constraint(equalTo: visualEffectPreview.leadingAnchor),
                previewContent.trailingAnchor.constraint(equalTo: visualEffectPreview.trailingAnchor),
                previewContent.bottomAnchor.constraint(equalTo: visualEffectPreview.bottomAnchor)
            ])
            preview = visualEffectPreview
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 190).isActive = true
        dashboardMenuPreviewIcon.imageScaling = .scaleProportionallyDown
        dashboardMenuPreviewIcon.translatesAutoresizingMaskIntoConstraints = false
        dashboardMenuPreviewIcon.wantsLayer = true
        dashboardMenuPreviewIcon.widthAnchor.constraint(equalToConstant: Self.menuBarIconSlotWidth).isActive = true
        dashboardMenuPreviewIcon.heightAnchor.constraint(equalToConstant: Self.menuBarIconSlotWidth).isActive = true
        dashboardMenuPreviewPrimary.font = Self.menuBarPrimaryFont
        dashboardMenuPreviewPrimary.textColor = .labelColor
        dashboardMenuPreviewSecondary.font = Self.menuBarSecondaryFont
        dashboardMenuPreviewSecondary.textColor = .labelColor
        let previewText = dashboardMenuPreviewText
        previewText.addSubview(dashboardMenuPreviewPrimary)
        previewText.addSubview(dashboardMenuPreviewSecondary)
        previewText.wantsLayer = true
        previewText.layer?.setAffineTransform(.identity)
        let previewTextWidth = previewText.widthAnchor.constraint(equalToConstant: 32)
        previewTextWidth.priority = .defaultHigh
        previewTextWidth.isActive = true
        dashboardMenuPreviewTextWidthConstraint = previewTextWidth
        let previewIconSlot = dashboardMenuPreviewIconSlot
        previewIconSlot.translatesAutoresizingMaskIntoConstraints = false
        previewIconSlot.widthAnchor.constraint(equalToConstant: Self.menuBarIconSlotWidth).isActive = true
        previewIconSlot.heightAnchor.constraint(equalToConstant: Self.menuBarIconSlotWidth).isActive = true
        previewIconSlot.addSubview(dashboardMenuPreviewIcon)
        NSLayoutConstraint.activate([
            dashboardMenuPreviewIcon.centerXAnchor.constraint(equalTo: previewIconSlot.centerXAnchor),
            dashboardMenuPreviewIcon.centerYAnchor.constraint(equalTo: previewIconSlot.centerYAnchor)
        ])
        let previewRow = NSStackView(views: [previewIconSlot, previewText])
        previewRow.orientation = .horizontal
        previewRow.alignment = .centerY
        previewRow.spacing = Self.menuBarIconTextSpacing
        previewRow.translatesAutoresizingMaskIntoConstraints = false
        dashboardMenuPreviewCapsule.wantsLayer = true
        dashboardMenuPreviewCapsule.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.black.withAlphaComponent(0.08),
            dark: NSColor.white.withAlphaComponent(0.12)
        ).cgColor
        dashboardMenuPreviewCapsule.layer?.borderColor = dashboardAdaptiveColor(
            light: NSColor.black.withAlphaComponent(0.10),
            dark: NSColor.white.withAlphaComponent(0.08)
        ).cgColor
        dashboardMenuPreviewCapsule.layer?.borderWidth = 0.5
        dashboardMenuPreviewCapsule.layer?.cornerRadius = 12
        dashboardMenuPreviewCapsule.layer?.masksToBounds = true
        dashboardMenuPreviewCapsule.isHidden = true
        dashboardMenuPreviewCapsule.translatesAutoresizingMaskIntoConstraints = false
        previewContent.addSubview(dashboardMenuPreviewCapsule)
        previewContent.addSubview(previewRow)
        let capsuleLeading = dashboardMenuPreviewCapsule.leadingAnchor.constraint(
            equalTo: previewRow.leadingAnchor,
            constant: -(menuBarHorizontalPadding + dashboardMenuPreviewChromeInset)
        )
        let capsuleTrailing = dashboardMenuPreviewCapsule.trailingAnchor.constraint(
            equalTo: previewRow.trailingAnchor,
            constant: menuBarHorizontalPadding + dashboardMenuPreviewChromeInset
        )
        dashboardMenuPreviewCapsuleLeadingConstraint = capsuleLeading
        dashboardMenuPreviewCapsuleTrailingConstraint = capsuleTrailing
        NSLayoutConstraint.activate([
            previewRow.centerXAnchor.constraint(equalTo: previewContent.centerXAnchor),
            previewRow.centerYAnchor.constraint(equalTo: previewContent.centerYAnchor),
            previewRow.leadingAnchor.constraint(greaterThanOrEqualTo: previewContent.leadingAnchor, constant: 14),
            previewRow.trailingAnchor.constraint(lessThanOrEqualTo: previewContent.trailingAnchor, constant: -14),
            capsuleLeading,
            capsuleTrailing,
            dashboardMenuPreviewCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: previewContent.leadingAnchor, constant: 6),
            dashboardMenuPreviewCapsule.trailingAnchor.constraint(lessThanOrEqualTo: previewContent.trailingAnchor, constant: -6),
            dashboardMenuPreviewCapsule.topAnchor.constraint(equalTo: previewRow.topAnchor, constant: -3),
            dashboardMenuPreviewCapsule.bottomAnchor.constraint(equalTo: previewRow.bottomAnchor, constant: 3),
            preview.heightAnchor.constraint(equalToConstant: 42)
        ])
        let iconToggle = makeDashboardSwitch(
            identifier: "showMenuBarIcon",
            isOn: showMenuBarIcon
        )
        let amountToggle = makeDashboardSwitch(
            identifier: "showMenuBarAmount",
            isOn: showMenuBarAmount
        )
        let resetToggle = makeDashboardSwitch(
            identifier: "showMenuBarReset",
            isOn: showMenuBarReset
        )
        dashboardMenuBarIconSwitch = iconToggle
        dashboardMenuBarAmountSwitch = amountToggle
        let previewSection = makeSettingsSection(tr("预览", "Preview"), rows: [
            makeSettingsRow(
                tr("当前布局", "Current Layout"),
                subtitle: tr(
                    "菜单栏会随供应商数据实时更新",
                    "The menu bar updates with Provider data in real time"
                ),
                control: preview,
                minimumHeight: 66
            )
        ])
        let displaySection = makeSettingsSection(tr("显示项目", "Display Items"), rows: [
            makeSettingsRow(tr("Agent 图标", "Agent Icon"), subtitle: tr("显示当前任务运行状态", "Shows the current task status"), control: iconToggle),
            makeSettingsRow(tr("额度数字", "Balance Amount"), subtitle: tr("显示百分比或 API 余额", "Shows a percentage or API balance"), control: amountToggle),
            makeSettingsRow(tr("重置倒计时", "Reset Countdown"), subtitle: tr("仅在官方额度可用时显示", "Only shown when official quota data is available"), control: resetToggle)
        ])
        refreshDashboardMenuBarPage()
        return makeSettingsPage([previewSection, displaySection])
    }

    private func refreshDashboardMenuBarPage() {
        guard dashboard?.isVisible == true, dashboardSection == .menuBar else { return }
        dashboardMenuPreviewIconSlot.isHidden = !showMenuBarIcon
        dashboardMenuPreviewText.isHidden = !showMenuBarAmount
        // Keep at least one visible status-item component. Disabling the last
        // active switch avoids instantly reversing an NSSwitch animation,
        // which can otherwise leave overlapping on/off layers on vibrancy.
        dashboardMenuBarIconSwitch?.isEnabled = showMenuBarAmount
        dashboardMenuBarAmountSwitch?.isEnabled = showMenuBarIcon
        dashboardMenuPreviewPrimary.stringValue = showMenuBarAmount ? snapshot.menuBarPrimary : ""
        dashboardMenuPreviewSecondary.stringValue = snapshot.kind == .official
            ? snapshot.menuBarSecondary
            : ""
        let hasSecondary = showMenuBarAmount
            && showMenuBarReset
            && snapshot.kind == .official
            && !dashboardMenuPreviewSecondary.stringValue.isEmpty
        let geometry = MenuBarGeometry(
            primarySize: dashboardMenuPreviewPrimary.intrinsicContentSize,
            secondarySize: dashboardMenuPreviewSecondary.intrinsicContentSize,
            showIcon: showMenuBarIcon,
            showAmount: showMenuBarAmount,
            hasSecondary: hasSecondary,
            isBalance: snapshot.kind == .balance,
            iconSlotWidth: Self.menuBarIconSlotWidth,
            iconTextSpacing: Self.menuBarIconTextSpacing,
            textRowSpacing: Self.menuBarTextRowSpacing,
            textWidthSlack: Self.menuBarTextWidthSlack,
            singleLineHeight: Self.menuBarSingleLineHeight
        )
        applyMenuBarTextLayout(
            container: dashboardMenuPreviewText,
            primary: dashboardMenuPreviewPrimary,
            secondary: dashboardMenuPreviewSecondary,
            geometry: geometry,
            showAmount: showMenuBarAmount,
            hasSecondary: hasSecondary
        )
        dashboardMenuPreviewTextWidthConstraint?.constant = geometry.textWidth
        dashboardMenuPreviewCapsuleLeadingConstraint?.constant = -(
            menuBarHorizontalPadding + dashboardMenuPreviewChromeInset
        )
        dashboardMenuPreviewCapsuleTrailingConstraint?.constant =
            menuBarHorizontalPadding + dashboardMenuPreviewChromeInset
        dashboardMenuPreviewIcon.image = menuBarIconView.image
        dashboardMenuPreviewIcon.contentTintColor = .labelColor
        dashboardMenuPreviewIcon.layer?.setAffineTransform(.identity)
        dashboardMenuPreviewText.layer?.setAffineTransform(.identity)
        if snapshot.kind == .balance, showMenuBarIcon, showMenuBarAmount {
            dashboardMenuPreviewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: 0,
                y: -Self.menuBarSingleLineIconYOffset
            ))
            dashboardMenuPreviewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: 0,
                y: -Self.menuBarSingleLineTextYOffset
            ))
        }
    }

    private func makeRefreshDashboardPage() -> NSView {
        let root = NSView()
        let header = makePageHeader(tr("刷新设置", "Refresh Settings"), subtitle: tr("文件监听始终开启，轮询用于防止遗漏系统事件", "File monitoring is always active; polling prevents missed system events"))
        let pollingTitle = NSTextField(labelWithString: tr("CC Switch 轮询兜底", "CC Switch Fallback Polling"))
        pollingTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let pollingPopup = makeIntervalPopup(
            values: [(1, tr("每 1 秒", "Every 1 sec")), (3, tr("每 3 秒", "Every 3 sec")), (5, tr("每 5 秒", "Every 5 sec")), (10, tr("每 10 秒", "Every 10 sec"))],
            selected: providerPollInterval,
            identifier: "providerPollInterval"
        )
        let pollingSpacer = NSView()
        let pollingRow = NSStackView(views: [pollingTitle, pollingSpacer, pollingPopup])
        pollingRow.orientation = .horizontal
        pollingRow.alignment = .centerY

        let activityTitle = NSTextField(labelWithString: tr("Codex 任务状态检测", "Codex Task Status Detection"))
        activityTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let activityPopup = makeIntervalPopup(
            values: [(0.25, tr("0.25 秒", "0.25 sec")), (0.5, tr("0.5 秒", "0.5 sec")), (1, tr("1 秒", "1 sec"))],
            selected: activityPollInterval,
            identifier: "activityPollInterval"
        )
        let activitySpacer = NSView()
        let activityRow = NSStackView(views: [activityTitle, activitySpacer, activityPopup])
        activityRow.orientation = .horizontal
        activityRow.alignment = .centerY

        let animationToggle = makeDashboardSwitch(
            identifier: "animateCodexActivity",
            isOn: animateCodexActivity
        )
        let animationTitle = NSTextField(labelWithString: tr(
            "Codex 有任务运行时旋转菜单栏图标",
            "Rotate the menu bar icon while a Codex task is running"
        ))
        let animationSpacer = NSView()
        let animationRow = NSStackView(views: [
            animationTitle, animationSpacer, animationToggle
        ])
        animationRow.orientation = .horizontal
        animationRow.alignment = .centerY
        let note = NSTextField(wrappingLabelWithString: tr(
            "供应商变化仍由 CC Switch 数据库事件即时触发；这里的秒数只是没有收到事件时的后备检查频率。",
            "Provider changes are still triggered immediately by CC Switch database events; this interval is only the fallback check frequency."
        ))
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header, pollingRow, activityRow, animationRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(30, after: header)
        stack.setCustomSpacing(24, after: activityRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            pollingRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }

    private func makeIntervalPopup(
        values: [(Double, String)],
        selected: TimeInterval,
        identifier: String
    ) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.identifier = NSUserInterfaceItemIdentifier(identifier)
        popup.target = self
        popup.action = #selector(dashboardIntervalChanged(_:))
        for (index, value) in values.enumerated() {
            popup.addItem(withTitle: value.1)
            popup.item(at: index)?.representedObject = NSNumber(value: value.0)
            if abs(value.0 - selected) < 0.001 { popup.selectItem(at: index) }
        }
        return popup
    }

    private func makeLogsDashboardPage() -> NSView {
        let root = NSView()
        let header = makePageHeader(tr("日志", "Logs"), subtitle: tr("供应商切换、同步和失败原因", "Provider switching, synchronization, and failure details"))
        let refreshButton = NSButton(title: tr("刷新", "Refresh"), target: self, action: #selector(refreshDashboardLog))
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: tr("刷新", "Refresh"))
        let revealButton = NSButton(title: tr("在 Finder 中显示", "Show in Finder"), target: self, action: #selector(revealDashboardLog))
        revealButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: tr("在 Finder 中显示", "Show in Finder"))
        let buttonSpacer = NSView()
        let buttons = NSStackView(views: [refreshButton, revealButton, buttonSpacer])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        dashboardLogView.isEditable = false
        dashboardLogView.isSelectable = true
        dashboardLogView.isVerticallyResizable = true
        dashboardLogView.isHorizontallyResizable = false
        dashboardLogView.autoresizingMask = [.width]
        dashboardLogView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        dashboardLogView.textContainerInset = NSSize(width: 10, height: 10)
        dashboardLogView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = dashboardLogView

        [header, buttons, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            buttons.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            buttons.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28)
        ])
        return root
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        statusItem.isVisible = true
        statusItem.length = 56
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = nil
        button.toolTip = "BalanceBar"

        if let iconURL = Bundle.main.url(forResource: "CodexIcon", withExtension: "svg"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 16, height: 16)
            icon.isTemplate = true
            codexIconImage = icon
            menuBarIconView.setSourceImage(icon)
        }
        if let iconURL = Bundle.main.url(forResource: "Claude", withExtension: "svg"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 16, height: 16)
            icon.isTemplate = true
            claudeIconImage = icon
            if let thinkingURL = Bundle.main.url(
                forResource: "ClaudeThinking",
                withExtension: "svg"
            ) {
                claudeThinkingAnimator = ClaudeThinkingAnimator(
                    imageView: menuBarIconView,
                    staticImage: icon,
                    animatedSVGURL: thinkingURL
                )
            }
        }
        menuBarIconView.onImageChanged = { [weak self] image in
            guard let self else { return }
            self.menuBarIconView.image = image
            self.layoutStatusItem(for: self.snapshot)
            if self.dashboard?.isVisible == true, self.dashboardSection == .menuBar {
                self.dashboardMenuPreviewIcon.image = image
                self.dashboardMenuPreviewIcon.contentTintColor = .labelColor
            }
        }
        dashboardMenuPreviewIcon.image = menuBarIconView.image
        dashboardMenuPreviewIcon.contentTintColor = .labelColor
        menuBarIconView.imageScaling = .scaleProportionallyDown
        menuBarIconView.contentTintColor = .labelColor
        menuBarPrimaryLabel.font = Self.menuBarPrimaryFont
        menuBarPrimaryLabel.textColor = .labelColor
        menuBarPrimaryLabel.lineBreakMode = .byClipping
        menuBarSecondaryLabel.font = Self.menuBarSecondaryFont
        menuBarSecondaryLabel.textColor = .labelColor
        menuBarSecondaryLabel.lineBreakMode = .byClipping
        configureMenuBarContentStackIfNeeded()
        button.addSubview(menuBarContentStack)
        layoutStatusItem(for: snapshot)
        SwitchLog.write(
            "status item configured; visible=\(statusItem.isVisible); length=\(statusItem.length)",
            category: "ui.status-item"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            let statusWindow = button.window
            let windowFrame = statusWindow.map { DashboardLogging.rect($0.frame) } ?? "none"
            let screenFrame = statusWindow?.screen.map { DashboardLogging.rect($0.frame) } ?? "none"
            SwitchLog.write(
                "status item presentation; visible=\(self.statusItem.isVisible); window_visible=\(statusWindow?.isVisible ?? false); button_window=\(statusWindow != nil); button_hidden=\(button.isHidden); image=\(button.image != nil); title=\(button.title); attributed_title=\(button.attributedTitle.string); frame=\(DashboardLogging.rect(button.frame)); window_frame=\(windowFrame); screen_frame=\(screenFrame)",
                category: "ui.status-item"
            )
        }
        scheduleStatusItemAttachmentCheck(reason: "initial registration")
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        statusItem.menu = statusMenu
        configureStatusItem()
    }

    private func scheduleStatusItemAttachmentCheck(reason: String) {
        guard !statusItemAttachmentCheckScheduled else { return }
        statusItemAttachmentCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.statusItemAttachmentCheckScheduled = false
            self.verifyStatusItemAttachment(reason: reason)
        }
    }

    private func verifyStatusItemAttachment(reason: String) {
        guard let item = statusItem, let button = item.button else {
            SwitchLog.write(
                "status item attachment failed; reason=missing item or button",
                level: .error,
                category: "ui.status-item"
            )
            return
        }

        let window = button.window
        let windowFrame = window.map { DashboardLogging.rect($0.frame) } ?? "none"
        let screen = window?.screen
        let screenFrame = screen.map { DashboardLogging.rect($0.frame) } ?? "none"
        let attached = window.map { window in
            guard let screen else { return false }
            let frame = window.frame
            let screenFrame = screen.frame
            return window.isVisible
                && frame.minX >= screenFrame.minX
                && frame.maxX <= screenFrame.maxX
                && frame.maxY >= screenFrame.maxY - 4
                && frame.minY >= screenFrame.maxY - 48
        } ?? false

        SwitchLog.write(
            "status item attachment checked; reason=\(reason); attached=\(attached); visible=\(item.isVisible); window_visible=\(window?.isVisible ?? false); window_frame=\(windowFrame); screen_frame=\(screenFrame); length=\(item.length)",
            level: attached ? .debug : .warning,
            category: "ui.status-item",
            throttleKey: "status-item-attachment-\(reason)",
            minimumInterval: 0.5
        )

        guard !attached else {
            statusItemReanchorAttempts = 0
            return
        }
        guard statusItemReanchorAttempts < 3 else {
            SwitchLog.write(
                "status item attachment unresolved after retries; reason=\(reason); window_frame=\(windowFrame); screen_frame=\(screenFrame)",
                level: .error,
                category: "ui.status-item"
            )
            return
        }

        statusItemReanchorAttempts += 1
        let desiredLength = max(CGFloat(30), item.length)
        NSStatusBar.system.removeStatusItem(item)
        statusItem = NSStatusBar.system.statusItem(withLength: desiredLength)
        statusItem.menu = statusMenu
        configureStatusItem()
        scheduleStatusItemAttachmentCheck(reason: "re-registered-\(statusItemReanchorAttempts)-\(reason)")
    }

    private func configureRefreshTimers() {
        timer?.invalidate()
        activityTimer?.invalidate()

        let providerTimer = Timer(timeInterval: providerPollInterval, repeats: true) { [weak self] _ in
            self?.refresh(forceBalance: false)
            self?.refreshQuickSwitchSummaries(force: false)
        }
        timer = providerTimer
        RunLoop.main.add(providerTimer, forMode: .common)

        let taskTimer = Timer(timeInterval: activityPollInterval, repeats: true) { [weak self] _ in
            self?.refreshCodexActivity()
        }
        activityTimer = taskTimer
        RunLoop.main.add(taskTimer, forMode: .common)
    }

    private func startWorkspaceActivationObserver() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleFrontmostApplicationChange()
        }
    }

    private func handleFrontmostApplicationChange() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if Self.isCodexApplication(frontmost) {
            setActiveClient(.codex)
        } else if Self.isTerminalApplication(frontmost) {
            if isClaudeProcessAvailable {
                setActiveClient(.claude)
            } else {
                refreshCodexActivity()
            }
        }
    }

    private func refreshCodexActivity() {
        // Focus switching is latency-sensitive and does not need to wait for
        // transcript scanning. Use the last process result immediately.
        handleFrontmostApplicationChangeWithoutRefresh()
        guard !isActivityCheckInFlight else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostIsCodex = Self.isCodexApplication(frontmost)
        let frontmostIsTerminal = Self.isTerminalApplication(frontmost)
        let clientBeforeCheck = activeClient
        isActivityCheckInFlight = true
        activityMonitorQueue.async { [weak self] in
            guard let self else { return }
            var codexRunning: Bool?
            var claudeStatus: (processRunning: Bool, taskRunning: Bool)?
            if frontmostIsCodex {
                codexRunning = self.codexActivityMonitor.isTaskRunning()
            } else if frontmostIsTerminal {
                let status = self.claudeActivityMonitor.status()
                claudeStatus = status
                if !status.processRunning {
                    codexRunning = self.codexActivityMonitor.isTaskRunning()
                }
            } else if clientBeforeCheck == .codex {
                codexRunning = self.codexActivityMonitor.isTaskRunning()
            } else {
                claudeStatus = self.claudeActivityMonitor.status()
            }
            DispatchQueue.main.async {
                self.isActivityCheckInFlight = false
                if let claudeStatus {
                    if self.isClaudeProcessAvailable != claudeStatus.processRunning {
                        self.isClaudeProcessAvailable = claudeStatus.processRunning
                        SwitchLog.write(
                            "claude process availability changed; running=\(claudeStatus.processRunning)"
                        )
                    }
                }

                // Re-read the current application after the background check;
                // the user may have changed focus while it was running.
                let frontmost = NSWorkspace.shared.frontmostApplication
                if Self.isCodexApplication(frontmost) {
                    self.setActiveClient(.codex)
                } else if Self.isTerminalApplication(frontmost),
                          claudeStatus?.processRunning == true {
                    self.setActiveClient(.claude)
                }
                if let codexRunning {
                    self.setCodexTaskRunning(codexRunning)
                }
                if let claudeStatus {
                    self.setClaudeTaskRunning(claudeStatus.taskRunning)
                }
            }
        }
    }

    private func handleFrontmostApplicationChangeWithoutRefresh() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if Self.isCodexApplication(frontmost) {
            setActiveClient(.codex)
        } else if Self.isTerminalApplication(frontmost),
                  isClaudeProcessAvailable {
            setActiveClient(.claude)
        }
    }

    private func setCodexTaskRunning(_ running: Bool, force: Bool = false) {
        let wasRunning = isCodexTaskRunning
        let stateChanged = running != wasRunning
        isCodexTaskRunning = running
        if stateChanged {
            SwitchLog.write("task state changed; client=codex; running=\(running)")
        }
        if activeClient == .codex {
            updateActiveUsageRefresh(running: running, wasRunning: wasRunning)
        }
        guard force || stateChanged else { return }
        updateActivityIcon()
    }

    private func setClaudeTaskRunning(_ running: Bool, force: Bool = false) {
        let wasRunning = isClaudeTaskRunning
        let stateChanged = running != wasRunning
        isClaudeTaskRunning = running
        if stateChanged {
            SwitchLog.write("task state changed; client=claude; running=\(running)")
        }
        if activeClient == .claude {
            updateActiveUsageRefresh(running: running, wasRunning: wasRunning)
        }
        guard force || stateChanged else { return }
        updateActivityIcon()
    }

    private func updateActiveUsageRefresh(running: Bool, wasRunning: Bool) {
        let now = Date()
        let stateChanged = running != wasRunning

        if running {
            postCodexRefreshDeadline = nil
        } else if stateChanged && wasRunning {
            // Third-party relays may post usage a few seconds after Codex has
            // finished. Keep a short trailing refresh window so the final
            // balance appears without requiring a manual refresh.
            postCodexRefreshDeadline = now.addingTimeInterval(postCodexRefreshDuration)
        }

        let inTrailingWindow = postCodexRefreshDeadline.map { now < $0 } ?? false
        let shouldRefreshUsage = running || inTrailingWindow || stateChanged
        let refreshIsDue = lastCodexUsageRefresh.map {
            now.timeIntervalSince($0) >= codexUsageRefreshInterval
        } ?? true
        if shouldRefreshUsage && (stateChanged || refreshIsDue) {
            lastCodexUsageRefresh = now
            refresh(forceBalance: true)
        } else if !shouldRefreshUsage {
            lastCodexUsageRefresh = nil
            postCodexRefreshDeadline = nil
        }
    }

    private func setActiveClient(_ client: AssistantClient) {
        guard client != activeClient else { return }
        activeClient = client
        SwitchLog.write("active client changed; client=\(client.rawValue)")
        lastProviderID = nil
        lastBalanceFetch = nil
        lastOfficialFetch = nil
        lastQuickSwitchFetch = nil
        lastCodexUsageRefresh = nil
        postCodexRefreshDeadline = nil
        updateActivityIcon()
        // Never flash the generic ellipsis during a focus switch. Reuse the
        // last successful snapshot for this client while the live refresh runs.
        // Startup prefetch normally makes this available before the first switch.
        if let cached = clientSnapshots[client],
           Provider.loadCurrent(appType: client.appType)?.id == cached.providerID {
            lastProviderID = cached.providerID
            render(cached.snapshot)
        }
        refresh(forceBalance: true)
        refreshQuickSwitchSummaries(force: true)
        if dashboard != nil {
            showDashboardSection(dashboardSection)
        }
    }

    private func updateActivityIcon() {
        switch activeClient {
        case .codex:
            claudeThinkingAnimator?.stop()
            if let codexIconImage {
                menuBarIconView.setSourceImage(codexIconImage)
            }
            if isCodexTaskRunning && animateCodexActivity {
                menuBarIconView.startRotating()
            } else {
                menuBarIconView.stopRotating()
            }
        case .claude:
            menuBarIconView.stopRotating()
            if let claudeIconImage {
                menuBarIconView.setSourceImage(claudeIconImage)
            }
            if isClaudeTaskRunning && animateCodexActivity {
                claudeThinkingAnimator?.start()
            } else {
                claudeThinkingAnimator?.stop()
            }
        }
    }

    private static func isCodexApplication(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }
        let identifier = (application.bundleIdentifier ?? "").lowercased()
        let name = (application.localizedName ?? "").lowercased()
        if name == "codex" { return true }
        return identifier == "com.openai.codex"
            || (identifier.contains("codex") && !identifier.contains("codexbar"))
    }

    private static func isTerminalApplication(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }
        let identifier = (application.bundleIdentifier ?? "").lowercased()
        let name = (application.localizedName ?? "").lowercased()
        let knownIdentifiers = [
            "com.apple.terminal",
            "com.googlecode.iterm2",
            "dev.warp.warp-stable",
            "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty",
            "org.alacritty",
            "com.github.wez.wezterm",
            "co.zeit.hyper"
        ]
        if knownIdentifiers.contains(identifier) { return true }
        return ["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm"]
            .contains(where: { name.contains($0) })
    }

    private func applyMenuBarTextLayout(
        container: MenuBarTextView,
        primary: NSTextField,
        secondary: NSTextField,
        geometry: MenuBarGeometry,
        showAmount: Bool,
        hasSecondary: Bool
    ) {
        container.layoutSize = NSSize(
            width: geometry.textWidth,
            height: geometry.textHeight
        )
        primary.isHidden = !showAmount
        primary.frame = NSRect(
            x: 0,
            y: 0,
            width: geometry.textWidth,
            height: geometry.primaryHeight
        )
        secondary.isHidden = !hasSecondary
        secondary.frame = hasSecondary
            ? NSRect(
                x: 0,
                y: geometry.primaryHeight + Self.menuBarTextRowSpacing,
                width: geometry.textWidth,
                height: geometry.secondaryHeight
            )
            : .zero
    }

    private func configureMenuBarContentStackIfNeeded() {
        guard !isMenuBarContentStackConfigured else { return }
        isMenuBarContentStackConfigured = true

        menuBarIconView.translatesAutoresizingMaskIntoConstraints = true

        menuBarIconSlot.translatesAutoresizingMaskIntoConstraints = true
        menuBarIconSlot.addSubview(menuBarIconView)
        menuBarTextStack.addSubview(menuBarPrimaryLabel)
        menuBarTextStack.addSubview(menuBarSecondaryLabel)
        menuBarTextStack.wantsLayer = true
        menuBarTextStack.layer?.setAffineTransform(.identity)
        menuBarContentStack.addSubview(menuBarIconSlot)
        menuBarContentStack.addSubview(menuBarTextStack)
        menuBarContentStack.translatesAutoresizingMaskIntoConstraints = true
    }

    private func logMenuBarIconFrames(
        snapshot: Snapshot,
        button: NSStatusBarButton,
        hasSecondary: Bool,
        iconYOffset: CGFloat
    ) {
        guard showMenuBarIcon else { return }
        let kind: String
        switch snapshot.kind {
        case .placeholder: kind = "placeholder"
        case .official: kind = "official"
        case .balance: kind = "balance"
        case .error: kind = "error"
        }
        let stackInButton = menuBarContentStack.convert(menuBarContentStack.bounds, to: button)
        let slotInButton = menuBarIconSlot.convert(menuBarIconSlot.bounds, to: button)
        let iconInButton = menuBarIconView.convert(menuBarIconView.bounds, to: button)
        let iconInWindow = menuBarIconView.convert(menuBarIconView.bounds, to: nil)
        let iconInScreen = button.window?.convertToScreen(iconInWindow)
        let diagnostic = "menu bar icon frames; kind=\(kind); show_amount=\(showMenuBarAmount); has_secondary=\(hasSecondary); offset=\(DashboardLogging.number(iconYOffset)); flipped=button:\(button.isFlipped),stack:\(menuBarContentStack.isFlipped),slot:\(menuBarIconSlot.isFlipped),icon:\(menuBarIconView.isFlipped); button=\(DashboardLogging.rect(button.bounds)); stack_local=\(DashboardLogging.rect(menuBarContentStack.frame)); stack_button=\(DashboardLogging.rect(stackInButton)); slot_local=\(DashboardLogging.rect(menuBarIconSlot.frame)); slot_button=\(DashboardLogging.rect(slotInButton)); icon_local=\(DashboardLogging.rect(menuBarIconView.frame)); icon_button=\(DashboardLogging.rect(iconInButton)); icon_window=\(DashboardLogging.rect(iconInWindow)); icon_screen=\(iconInScreen.map { DashboardLogging.rect($0) } ?? "none"); center_button=\(DashboardLogging.number(iconInButton.midY)); center_window=\(DashboardLogging.number(iconInWindow.midY))"
        guard diagnostic != lastMenuBarIconFrameDiagnostic else { return }
        lastMenuBarIconFrameDiagnostic = diagnostic
        SwitchLog.write(diagnostic, level: .debug, category: "ui.geometry")
    }

    private func layoutStatusItem(for snapshot: Snapshot) {
        guard let button = statusItem.button else { return }
        let reservedSecondary = showMenuBarAmount && snapshot.kind == .official
            ? snapshot.menuBarSecondary
            : ""
        let hasSecondary = showMenuBarAmount
            && showMenuBarReset
            && !reservedSecondary.isEmpty

        menuBarPrimaryLabel.stringValue = showMenuBarAmount ? snapshot.menuBarPrimary : ""
        menuBarSecondaryLabel.stringValue = reservedSecondary
        menuBarIconSlot.isHidden = !showMenuBarIcon
        menuBarTextStack.isHidden = !showMenuBarAmount
        let geometry = MenuBarGeometry(
            primarySize: menuBarPrimaryLabel.intrinsicContentSize,
            secondarySize: menuBarSecondaryLabel.intrinsicContentSize,
            showIcon: showMenuBarIcon,
            showAmount: showMenuBarAmount,
            hasSecondary: hasSecondary,
            isBalance: snapshot.kind == .balance,
            iconSlotWidth: Self.menuBarIconSlotWidth,
            iconTextSpacing: Self.menuBarIconTextSpacing,
            textRowSpacing: Self.menuBarTextRowSpacing,
            textWidthSlack: Self.menuBarTextWidthSlack,
            singleLineHeight: Self.menuBarSingleLineHeight
        )
        applyMenuBarTextLayout(
            container: menuBarTextStack,
            primary: menuBarPrimaryLabel,
            secondary: menuBarSecondaryLabel,
            geometry: geometry,
            showAmount: showMenuBarAmount,
            hasSecondary: hasSecondary
        )

        statusItem.length = max(
            30,
            ceil(geometry.contentWidth + (menuBarHorizontalPadding * 2))
        )
        button.layoutSubtreeIfNeeded()

        let buttonWidth = button.bounds.width
        let buttonHeight = button.bounds.height
        menuBarContentStack.frame = NSRect(
            x: floor(max(0, (buttonWidth - geometry.contentWidth) / 2)),
            y: floor((buttonHeight - geometry.contentHeight) / 2),
            width: geometry.contentWidth,
            height: geometry.contentHeight
        )

        menuBarIconSlot.frame = NSRect(
            x: 0,
            y: floor(max(0, (geometry.contentHeight - geometry.iconWidth) / 2)),
            width: geometry.iconWidth,
            height: geometry.iconWidth
        )
        let apiIconYOffset = showMenuBarIcon && showMenuBarAmount
            ? Self.menuBarSingleLineIconYOffset
            : 0
        let iconYOffset: CGFloat
        if snapshot.kind == .official, showMenuBarIcon {
            let apiGeometry = MenuBarGeometry(
                primarySize: menuBarPrimaryLabel.intrinsicContentSize,
                secondarySize: menuBarSecondaryLabel.intrinsicContentSize,
                showIcon: showMenuBarIcon,
                showAmount: showMenuBarAmount,
                hasSecondary: false,
                isBalance: true,
                iconSlotWidth: Self.menuBarIconSlotWidth,
                iconTextSpacing: Self.menuBarIconTextSpacing,
                textRowSpacing: Self.menuBarTextRowSpacing,
                textWidthSlack: Self.menuBarTextWidthSlack,
                singleLineHeight: Self.menuBarSingleLineHeight
            )
            // Keep the API frame fixed and solve only the official icon's
            // local Y from the complete stack -> slot -> view coordinate path.
            iconYOffset = geometry.iconViewYOffset(
                alignedTo: apiGeometry,
                buttonHeight: buttonHeight,
                referenceIconViewYOffset: apiIconYOffset
            )
        } else if snapshot.kind == .balance {
            iconYOffset = apiIconYOffset
        } else {
            iconYOffset = 0
        }
        menuBarIconView.frame = NSRect(
            x: 0,
            y: iconYOffset,
            width: menuBarIconSlot.bounds.width,
            height: menuBarIconSlot.bounds.height
        )
        menuBarTextStack.frame = NSRect(
            x: geometry.iconWidth + geometry.gap,
            y: floor(max(0, (geometry.contentHeight - geometry.textHeight) / 2)),
            width: geometry.textWidth,
            height: geometry.textHeight
        )

        // The optical adjustment is always applied from a clean transform
        // after the current snapshot's frames have been assigned.
        menuBarTextStack.layer?.setAffineTransform(.identity)
        if snapshot.kind == .balance, showMenuBarIcon, showMenuBarAmount {
            menuBarTextStack.layer?.setAffineTransform(CGAffineTransform(
                translationX: 0,
                y: -Self.menuBarSingleLineTextYOffset
            ))
        }
        logMenuBarIconFrames(
            snapshot: snapshot,
            button: button,
            hasSecondary: hasSecondary,
            iconYOffset: iconYOffset
        )
        button.toolTip = snapshot.menuBarToolTip
        button.isHidden = false
        button.isEnabled = true
        statusItem.isVisible = true
    }

    private func updateStatusItem(for snapshot: Snapshot) {
        layoutStatusItem(for: snapshot)
        scheduleStatusItemAttachmentCheck(reason: "snapshot layout")
        refreshDashboardMenuBarPage()
    }

    private func updateDashboard(for snapshot: Snapshot, refreshDate: Date?) {
        guard dashboard?.isVisible == true else { return }
        if let currentName = Provider.loadChoices(appType: activeClient.appType)
            .first(where: { $0.isCurrent })?.name {
            updateDashboardCurrentProvider(currentName)
        }
        if let selectedID = dashboardSelectedProviderID,
           let choice = Provider.loadChoices(appType: activeClient.appType)
               .first(where: { $0.id == selectedID }) {
            dashboardProviderLabel.stringValue = choice.name
            if choice.isCurrent {
                dashboardAmountLabel.stringValue = snapshot.overviewLargeAmount
                dashboardResetLabel.stringValue = snapshot.overviewReset(
                    refreshDate: refreshDate,
                    formatter: Self.timeFormatter
                )
            } else {
                quickSwitchSummaryLock.lock()
                let cached = quickSwitchSummaries[selectedID]
                quickSwitchSummaryLock.unlock()
                dashboardAmountLabel.stringValue = cached ?? tr("正在读取…", "Loading…")
                dashboardResetLabel.stringValue = tr(
                    "选择为当前供应商后显示详细重置时间",
                    "Select this Provider to display detailed reset information"
                )
            }
        }
        rebuildDashboardProviderList()
        refreshDashboardMenuBarPage()
    }

    private func updateDashboardCurrentProvider(_ name: String) {
        dashboardCurrentProviderSubtitle.stringValue = tr(
            "当前供应商：\(name)",
            "Current Provider: \(name)"
        )
    }

    private func refreshDashboardProviderRows() {
        guard dashboard != nil else { return }
        for child in dashboardProvidersStack.arrangedSubviews {
            dashboardProvidersStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }

        let choices = Provider.loadChoices(appType: activeClient.appType)
        if choices.isEmpty {
            let empty = NSTextField(labelWithString: tr("未找到 Codex 供应商", "No Codex Provider Found"))
            empty.textColor = .secondaryLabelColor
            dashboardProvidersStack.addArrangedSubview(empty)
            return
        }

        quickSwitchSummaryLock.lock()
        let summaries = quickSwitchSummaries
        quickSwitchSummaryLock.unlock()
        for (index, choice) in choices.enumerated() {
            let name = NSTextField(labelWithString: choice.name)
            name.font = .systemFont(ofSize: 13, weight: choice.isCurrent ? .semibold : .regular)
            name.lineBreakMode = .byTruncatingTail
            let summary = NSTextField(labelWithString: summaries[choice.id] ?? tr("正在读取…", "Loading…"))
            summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            summary.textColor = .secondaryLabelColor
            summary.alignment = .right
            summary.translatesAutoresizingMaskIntoConstraints = false
            summary.widthAnchor.constraint(equalToConstant: 112).isActive = true
            let spacer = NSView()
            let action = NSButton(
                title: choice.isCurrent ? tr("当前", "Current") : tr("切换", "Switch"),
                target: self,
                action: #selector(dashboardSwitchProvider(_:))
            )
            action.bezelStyle = .roundRect
            action.controlSize = .small
            action.isEnabled = !choice.isCurrent
            action.identifier = NSUserInterfaceItemIdentifier(choice.id)
            action.toolTip = choice.name
            action.translatesAutoresizingMaskIntoConstraints = false
            action.widthAnchor.constraint(equalToConstant: 58).isActive = true
            let row = NSStackView(views: [name, spacer, summary, action])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 34).isActive = true
            dashboardProvidersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: dashboardProvidersStack.widthAnchor).isActive = true

            if index < choices.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.widthAnchor.constraint(equalTo: dashboardProvidersStack.widthAnchor).isActive = true
                dashboardProvidersStack.addArrangedSubview(separator)
            }
        }
    }

    private func refresh(forceBalance: Bool) {
        let client = activeClient
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let current = Provider.loadCurrent(appType: client.appType)
            guard let current else {
                SwitchLog.write(
                    "refresh failed; client=\(client.rawValue); current provider not found",
                    level: .error,
                    category: "provider"
                )
                self.render(.error(tr(
                    "未找到 CC Switch 当前 \(client.displayName) 供应商",
                    "The current CC Switch \(client.displayName) Provider was not found"
                )))
                return
            }

            // The Provider name is local CC Switch state, so reflect it in the
            // dashboard immediately instead of waiting for the remote balance
            // request to finish.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeClient == client else { return }
                self.updateDashboardCurrentProvider(current.name)
            }

            let switched = current.id != self.lastProviderID
            if switched {
                SwitchLog.write("provider observed; app=\(client.appType); id=\(current.id); name=\(current.name); source=database watcher/poll")
            }
            self.lastProviderID = current.id
            guard let query = current.query else {
                guard current.isOfficial else {
                    let failure = current.queryFailure ?? .unknown
                    SwitchLog.write(
                        "balance query unavailable; client=\(client.rawValue); provider_id=\(current.id); provider=\(current.name); \(failure.diagnostic)",
                        level: .warning,
                        category: "network",
                        throttleKey: "balance-query-unavailable-\(client.rawValue)-\(current.id)-\(failure.rawValue)",
                        minimumInterval: 60
                    )
                    self.render(.error(tr(
                        "\(current.name)：未启用 CC Switch 余额查询",
                        "\(current.name): CC Switch balance query is not enabled"
                    )))
                    return
                }
                let due = self.lastOfficialFetch.map { Date().timeIntervalSince($0) >= 60 } ?? true
                guard forceBalance || switched || due else { return }
                self.lastOfficialFetch = Date()
                SwitchLog.write(
                    "quota fetch started; client=\(client.rawValue); provider=\(current.name)",
                    level: .debug,
                    category: "network",
                    throttleKey: "quota-fetch-\(client.rawValue)-\(current.id)",
                    minimumInterval: 10
                )
                self.fetchOfficialQuota(
                    providerID: current.id,
                    providerName: current.name,
                    client: client
                )
                return
            }

            let interval = TimeInterval(max(query.intervalMinutes, 1) * 60)
            let due = self.lastBalanceFetch.map { Date().timeIntervalSince($0) >= interval } ?? true
            guard forceBalance || switched || due else { return }
            self.lastBalanceFetch = Date()
            SwitchLog.write(
                "balance fetch started; client=\(client.rawValue); provider=\(current.name)",
                level: .debug,
                category: "network",
                throttleKey: "balance-fetch-\(client.rawValue)-\(current.id)",
                minimumInterval: 10
            )
            self.fetchBalance(
                providerID: current.id,
                providerName: current.name,
                query: query,
                client: client
            )
        }
    }

    private func prefetchCurrentBalance(for client: AssistantClient) {
        monitorQueue.async { [weak self] in
            guard let self,
                  let current = Provider.loadCurrent(appType: client.appType)
            else { return }

            if let query = current.query {
                SwitchLog.write(
                    "balance prefetch started; client=\(client.rawValue); provider=\(current.name)",
                    level: .debug,
                    category: "network",
                    throttleKey: "balance-prefetch-\(client.rawValue)-\(current.id)",
                    minimumInterval: 10
                )
                self.fetchBalance(
                    providerID: current.id,
                    providerName: current.name,
                    query: query,
                    client: client
                )
            } else if current.isOfficial, client != .claude {
                SwitchLog.write(
                    "quota prefetch started; client=\(client.rawValue); provider=\(current.name)",
                    level: .debug,
                    category: "network",
                    throttleKey: "quota-prefetch-\(client.rawValue)-\(current.id)",
                    minimumInterval: 10
                )
                self.fetchOfficialQuota(
                    providerID: current.id,
                    providerName: current.name,
                    client: client
                )
            }
        }
    }

    private func startDatabaseWatchers() {
        // SQLite commits usually update the WAL file; watching both the main DB
        // and its WAL gives near-instant provider-switch detection.
        let paths = [databasePath, "\(databasePath)-wal", ccSwitchDirectory]
        databaseWatchers = paths.compactMap { makeWatcher(for: $0) }
    }

    private func makeWatcher(for path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: monitorQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleImmediateSync()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleImmediateSync() {
        syncWorkItem?.cancel()
        SwitchLog.write(
            "CC Switch database change observed; coalescing refresh",
            level: .debug,
            category: "database",
            throttleKey: "database-change",
            minimumInterval: 2
        )
        let workItem = DispatchWorkItem { [weak self] in
            // A CC Switch database write may represent either a Provider
            // switch or a credential/configuration update. Bypass the normal
            // provider interval so the menu follows it immediately.
            self?.refresh(forceBalance: true)
            self?.refreshQuickSwitchSummaries(force: true)
        }
        syncWorkItem = workItem
        // CC Switch commits several SQLite/WAL writes per action. Coalesce
        // them, while keeping the post-switch refresh visually immediate.
        monitorQueue.asyncAfter(deadline: .now() + .milliseconds(80), execute: workItem)
    }

    private func refreshQuickSwitchSummaries(
        force: Bool,
        for requestedClient: AssistantClient? = nil
    ) {
        let client = requestedClient ?? activeClient
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let due = self.lastQuickSwitchFetch.map { Date().timeIntervalSince($0) >= 60 } ?? true
            guard force || due else { return }
            self.lastQuickSwitchFetch = Date()

            for source in Provider.loadSummarySources(appType: client.appType) {
                if source.isOfficial {
                    // Avoid querying the macOS Keychain merely to decorate the
                    // quick-switch list. Official Claude quota is still loaded
                    // when it is the current Provider.
                    if client == .claude { continue }
                    guard let request = Self.makeOfficialQuotaRequest(
                        client: client,
                        storedAccessToken: source.officialAccessToken
                    ) else { continue }
                    URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
                        guard let self,
                              let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode),
                              let data,
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let quota = Self.extractOfficialQuota(from: object, client: client)
                        else { return }
                        self.updateQuickSwitchSummary(
                            providerID: source.id,
                            text: "\(Int(quota.remaining))% / \(quota.daysText)"
                        )
                    }.resume()
                    continue
                }

                guard let query = source.query,
                      let url = URL(string: query.url),
                      url.scheme?.lowercased() == "https" else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = TimeInterval(query.timeoutSeconds)
                Self.applyBalanceHeaders(query, to: &request)
                URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
                    guard let self,
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          let data,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let result = Self.extractBalanceResult(
                              from: object,
                              query: query
                          )
                    else { return }
                    self.updateQuickSwitchSummary(
                        providerID: source.id,
                        text: Self.formatBalanceSummary(result.amount, unit: result.unit)
                    )
                }.resume()
            }
        }
    }

    private func updateQuickSwitchSummary(providerID: String, text: String) {
        quickSwitchSummaryLock.lock()
        let previous = quickSwitchSummaries[providerID]
        guard previous != text else {
            quickSwitchSummaryLock.unlock()
            return
        }
        quickSwitchSummaries[providerID] = text
        quickSwitchSummaryLock.unlock()
        SwitchLog.write(
            "quick-switch balance changed; provider_id=\(providerID); value=\(text)",
            category: "balance"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let names = Dictionary(uniqueKeysWithValues: Provider.loadChoices(
                appType: self.activeClient.appType
            ).map { ($0.id, $0.name) })
            if self.isStatusMenuTracking {
                self.statusMenuNeedsRebuild = true
            } else if let submenu = self.statusMenu.items.first(where: {
                $0.title == tr("快速切换", "Quick Switch")
            })?.submenu {
                for item in submenu.items {
                    guard let id = item.representedObject as? String, let name = names[id] else { continue }
                    self.applyQuickSwitchTitle(to: item, providerID: id, providerName: name)
                }
            }
            self.rebuildDashboardProviderList()
            self.updateDashboard(for: self.snapshot, refreshDate: self.lastSuccessfulRefresh ?? self.snapshot.date)
        }
    }

    private func quickSwitchTitle(providerID: String, providerName: String) -> String {
        quickSwitchSummaryLock.lock()
        let summary = quickSwitchSummaries[providerID]
        quickSwitchSummaryLock.unlock()
        return "\(providerName)\t\(summary ?? "…")"
    }

    private func applyQuickSwitchTitle(to item: NSMenuItem, providerID: String, providerName: String) {
        let title = quickSwitchTitle(providerID: providerID, providerName: providerName)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 170)]
        paragraph.defaultTabInterval = 170
        item.title = title
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .paragraphStyle: paragraph
            ]
        )
    }

    private static func formatBalanceSummary(_ amount: Double, unit: String) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(2)))
        switch unit.uppercased() {
        case "USD":
            return "$\(number)"
        case "CNY", "CNH", "RMB":
            return "¥\(number)"
        default:
            return "\(number) \(unit)"
        }
    }

    private func beginBalanceRequest(_ key: String) -> Bool {
        balanceRequestLock.lock()
        defer { balanceRequestLock.unlock() }
        return balanceRequestsInFlight.insert(key).inserted
    }

    private func endBalanceRequest(_ key: String) {
        balanceRequestLock.lock()
        balanceRequestsInFlight.remove(key)
        balanceRequestLock.unlock()
    }

    private static func localizedBalanceNetworkErrorReason(
        _ error: Error,
        usesSimplifiedChinese: Bool
    ) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return usesSimplifiedChinese ? "网络请求失败" : "Network request failed"
        }

        let messages: (simplifiedChinese: String, english: String)
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut:
            messages = ("网络请求超时", "Network request timed out")
        case .notConnectedToInternet:
            messages = ("无网络连接", "No internet connection")
        case .networkConnectionLost:
            messages = ("网络连接已中断", "Network connection was lost")
        case .cannotFindHost:
            messages = ("找不到主机", "Host could not be found")
        case .cannotConnectToHost:
            messages = ("无法连接主机", "Could not connect to host")
        case .secureConnectionFailed:
            messages = ("安全连接失败", "Secure connection failed")
        default:
            messages = ("网络请求失败", "Network request failed")
        }
        return usesSimplifiedChinese ? messages.simplifiedChinese : messages.english
    }

    private func fetchBalance(
        providerID: String,
        providerName: String,
        query: BalanceQuery,
        client: AssistantClient
    ) {
        guard let url = URL(string: query.url), url.scheme?.lowercased() == "https" else {
            SwitchLog.write(
                "balance request rejected; client=\(client.rawValue); provider=\(providerName); reason=non-HTTPS endpoint",
                level: .error,
                category: "network"
            )
            renderForCurrentProvider(.error(tr(
                "\(providerName)：余额接口不是 HTTPS",
                "\(providerName): The balance endpoint is not HTTPS"
            )), providerID: providerID, client: client)
            return
        }
        let requestKey = "balance:\(client.rawValue):\(providerID)"
        guard beginBalanceRequest(requestKey) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(query.timeoutSeconds)
        Self.applyBalanceHeaders(query, to: &request)
        let requestStartedAt = Date()

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.endBalanceRequest(requestKey) }
            let duration = Date().timeIntervalSince(requestStartedAt)
            if let error {
                SwitchLog.write(
                    "balance request failed; client=\(client.rawValue); provider=\(providerName); duration=\(String(format: "%.3f", duration))s; error=\(error.localizedDescription)",
                    level: .error,
                    category: "network"
                )
                let reason = Self.localizedBalanceNetworkErrorReason(
                    error,
                    usesSimplifiedChinese: AppLanguage.usesSimplifiedChinese
                )
                self.renderForCurrentProvider(
                    .error(tr("\(providerName)：\(reason)", "\(providerName): \(reason)")),
                    providerID: providerID,
                    client: client
                )
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                SwitchLog.write(
                    "balance request failed; client=\(client.rawValue); provider=\(providerName); status=\(status); duration=\(String(format: "%.3f", duration))s",
                    level: .error,
                    category: "network"
                )
                self.renderForCurrentProvider(.error(tr(
                    "\(providerName)：余额接口返回异常",
                    "\(providerName): The balance endpoint returned an error"
                )), providerID: providerID, client: client)
                return
            }
            do {
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                guard let result = Self.extractBalanceResult(
                    from: object,
                    query: query
                ) else {
                    SwitchLog.write(
                        "balance parse failed; client=\(client.rawValue); provider=\(providerName); bytes=\(data.count); duration=\(String(format: "%.3f", duration))s",
                        level: .error,
                        category: "parsing"
                    )
                    self.renderForCurrentProvider(.error(tr(
                        "\(providerName)：未识别余额格式",
                        "\(providerName): Unrecognized balance format"
                    )), providerID: providerID, client: client)
                    return
                }
                SwitchLog.write(
                    "balance request succeeded; client=\(client.rawValue); provider=\(providerName); amount=\(result.amount); unit=\(result.unit); bytes=\(data.count); duration=\(String(format: "%.3f", duration))s",
                    level: .debug,
                    category: "network",
                    throttleKey: "balance-success-\(client.rawValue)-\(providerID)",
                    minimumInterval: 10
                )
                self.updateQuickSwitchSummary(
                    providerID: providerID,
                    text: Self.formatBalanceSummary(result.amount, unit: result.unit)
                )
                self.renderForCurrentProvider(
                    .balance(
                        providerName,
                        result.amount,
                        result.unit,
                        query.websiteURL,
                        Date()
                    ),
                    providerID: providerID,
                    client: client
                )
            } catch {
                SwitchLog.write(
                    "balance JSON decode failed; client=\(client.rawValue); provider=\(providerName); bytes=\(data.count); duration=\(String(format: "%.3f", duration))s; error=\(error.localizedDescription)",
                    level: .error,
                    category: "parsing"
                )
                self.renderForCurrentProvider(.error(tr(
                    "\(providerName)：余额响应无法解析",
                    "\(providerName): The balance response could not be parsed"
                )), providerID: providerID, client: client)
            }
        }.resume()
    }

    private static func applyBalanceHeaders(_ query: BalanceQuery, to request: inout URLRequest) {
        request.setValue("Bearer \(query.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in query.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func fetchOfficialQuota(
        providerID: String,
        providerName: String,
        client: AssistantClient
    ) {
        guard let request = Self.makeOfficialQuotaRequest(
            client: client,
            storedAccessToken: nil
        ) else {
            SwitchLog.write(
                "official quota request unavailable; client=\(client.rawValue); provider=\(providerName); reason=missing local credentials",
                level: .error,
                category: "authentication"
            )
            renderForCurrentProvider(.error(tr(
                "\(client.displayName) 官方账号：未找到本机登录态",
                "Official \(client.displayName): Local sign-in credentials were not found"
            )), providerID: providerID, client: client)
            return
        }
        let requestKey = "official:\(client.rawValue):\(providerID)"
        guard beginBalanceRequest(requestKey) else { return }
        let requestStartedAt = Date()
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.endBalanceRequest(requestKey) }
            let duration = Date().timeIntervalSince(requestStartedAt)
            if let error {
                SwitchLog.write(
                    "official quota request failed; client=\(client.rawValue); provider=\(providerName); duration=\(String(format: "%.3f", duration))s; error=\(error.localizedDescription)",
                    level: .error,
                    category: "network"
                )
                self.renderForCurrentProvider(.error(tr(
                    "\(client.displayName) 官方账号：\(error.localizedDescription)",
                    "Official \(client.displayName): \(error.localizedDescription)"
                )), providerID: providerID, client: client)
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                SwitchLog.write(
                    "official quota request failed; client=\(client.rawValue); provider=\(providerName); status=\(status); bytes=\(data?.count ?? 0); duration=\(String(format: "%.3f", duration))s",
                    level: .error,
                    category: "network"
                )
                self.renderForCurrentProvider(.error(tr(
                    "\(client.displayName) 官方账号：额度接口返回异常",
                    "Official \(client.displayName): The quota endpoint returned an error"
                )), providerID: providerID, client: client)
                return
            }
            guard let quota = Self.extractOfficialQuota(from: object, client: client) else {
                SwitchLog.write(
                    "official quota parse failed; client=\(client.rawValue); provider=\(providerName); bytes=\(data.count); duration=\(String(format: "%.3f", duration))s",
                    level: .error,
                    category: "parsing"
                )
                self.renderForCurrentProvider(.error(tr(
                    "\(client.displayName) 官方账号：未识别额度格式",
                    "Official \(client.displayName): Unrecognized quota format"
                )), providerID: providerID, client: client)
                return
            }
            SwitchLog.write(
                "official quota request succeeded; client=\(client.rawValue); provider=\(providerName); remaining=\(quota.remaining); label=\(quota.label); duration=\(String(format: "%.3f", duration))s",
                level: .debug,
                category: "network",
                throttleKey: "quota-success-\(client.rawValue)-\(providerID)",
                minimumInterval: 10
            )
            self.updateQuickSwitchSummary(providerID: providerID, text: "\(Int(quota.remaining))% / \(quota.daysText)")
            self.renderForCurrentProvider(
                .official(providerName, quota.remaining, quota.label, quota.reset, Date()),
                providerID: providerID,
                client: client
            )
        }.resume()
    }

    private func renderForCurrentProvider(
        _ next: Snapshot,
        providerID: String,
        client: AssistantClient
    ) {
        monitorQueue.async { [weak self] in
            guard let self,
                  Provider.loadCurrent(appType: client.appType)?.id == providerID
            else { return }
            DispatchQueue.main.async {
                switch next.kind {
                case .official, .balance:
                    self.clientSnapshots[client] = (providerID, next)
                case .placeholder, .error:
                    break
                }
                guard self.activeClient == client,
                      self.lastProviderID == providerID else { return }
                SwitchLog.write(
                    "balance render completed; client=\(client.rawValue); provider_id=\(providerID); kind=\(next.kind)",
                    level: .debug,
                    category: "render",
                    throttleKey: "render-\(client.rawValue)-\(providerID)-\(next.kind)",
                    minimumInterval: 10
                )
                self.render(next)
            }
        }
    }

    private static func extractBalance(
        from object: [String: Any],
        rightCode: Bool,
        subscriptionPrefix: String
    ) -> Double? {
        if rightCode {
            let cash = numberValue(object["balance"]) ?? 0
            let subscriptions = object["subscriptions"] as? [[String: Any]] ?? []
            let subscriptionBalance = subscriptions.reduce(0.0) { total, subscription in
                let prefixes = subscription["available_prefixes"] as? [String] ?? []
                guard prefixes.contains(subscriptionPrefix) else { return total }
                let remaining = numberValue(subscription["remaining_quota"]) ?? 0
                let limit = numberValue(subscription["total_quota"]) ?? 0
                let resetsToday = (subscription["reset_today"] as? Bool) ?? false
                return total + (resetsToday ? remaining : remaining + limit)
            }
            return cash + subscriptionBalance
        }
        if let direct = numberValue(object["remaining"]) ?? numberValue(object["balance"]) { return direct }
        if let quota = object["quota"] as? [String: Any] { return numberValue(quota["remaining"]) }
        return nil
    }

    private static func extractBalanceResult(
        from object: [String: Any],
        query: BalanceQuery
    ) -> (amount: Double, unit: String)? {
        if query.isNewAPI {
            guard
                (object["success"] as? Bool) != false,
                let data = object["data"] as? [String: Any],
                let quota = numberValue(data["quota"])
            else { return nil }
            return (quota / 500_000, "USD")
        }

        if let native = query.nativeBalanceProvider {
            switch native {
            case .deepSeek:
                let balances = object["balance_infos"] as? [[String: Any]] ?? []
                for balance in balances {
                    if let amount = numberValue(balance["total_balance"]) {
                        return (
                            amount,
                            stringValue(balance["currency"]) ?? "CNY"
                        )
                    }
                }
                return nil
            case .stepFun:
                guard let amount = numberValue(object["balance"]) else { return nil }
                return (amount, "CNY")
            case .siliconFlowCN, .siliconFlowEN:
                guard
                    let data = object["data"] as? [String: Any],
                    let amount = numberValue(data["totalBalance"])
                else { return nil }
                return (
                    amount,
                    native == .siliconFlowCN ? "CNY" : "USD"
                )
            case .openRouter:
                let data = (object["data"] as? [String: Any]) ?? object
                guard let total = numberValue(data["total_credits"]) else { return nil }
                let used = numberValue(data["total_usage"]) ?? 0
                return (total - used, "USD")
            case .novitaAI:
                guard let raw = numberValue(object["availableBalance"]) else { return nil }
                return (raw / 10_000, "USD")
            }
        }

        guard let amount = extractBalance(
            from: object,
            rightCode: query.isRightCode,
            subscriptionPrefix: query.subscriptionPrefix
        ) else { return nil }
        let unit = stringValue(object["unit"])
            ?? stringValue((object["quota"] as? [String: Any])?["unit"])
            ?? "USD"
        return (amount, unit)
    }

    private static func makeOfficialQuotaRequest(
        client: AssistantClient,
        storedAccessToken: String?
    ) -> URLRequest? {
        let accessToken: String?
        let url: URL?
        switch client {
        case .codex:
            accessToken = storedAccessToken ?? codexAccessToken()
            url = URL(string: "https://chatgpt.com/backend-api/wham/usage")
        case .claude:
            accessToken = claudeAccessToken()
            url = URL(string: "https://api.anthropic.com/api/oauth/usage")
        }
        guard let accessToken, !accessToken.isEmpty, let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if client == .claude {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }

    private static func codexAccessToken() -> String? {
        let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
            let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = auth["tokens"] as? [String: Any]
        else { return nil }
        return tokens["access_token"] as? String
    }

    private static func claudeAccessToken() -> String? {
        if let keychainJSON = claudeCredentialsFromKeychain(),
           let token = claudeAccessToken(from: keychainJSON) {
            return token
        }
        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: credentialsURL) else { return nil }
        return claudeAccessToken(from: data)
    }

    private static func claudeCredentialsFromKeychain() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-w"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let data: Data
        do {
            try process.run()
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return data.isEmpty ? nil : data
    }

    private static func claudeAccessToken(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let oauth = (object["claudeAiOauth"] as? [String: Any])
            ?? (object["claude.ai_oauth"] as? [String: Any])
        return oauth?["accessToken"] as? String
    }

    private static func extractOfficialQuota(
        from object: [String: Any],
        client: AssistantClient
    ) -> (remaining: Double, label: String, daysText: String, reset: String?)? {
        if client == .claude {
            let tierNames = [
                ("seven_day", tr("7 日额度", "7-Day Quota"), tr("7 天", "7 Days")),
                ("five_hour", tr("5 小时额度", "5-Hour Quota"), tr("5 小时", "5 Hours")),
                ("seven_day_sonnet", tr("Sonnet 7 日额度", "Sonnet 7-Day Quota"), tr("7 天", "7 Days")),
                ("seven_day_opus", tr("Opus 7 日额度", "Opus 7-Day Quota"), tr("7 天", "7 Days"))
            ]
            for (name, label, daysText) in tierNames {
                guard let window = object[name] as? [String: Any],
                      let utilization = numberValue(window["utilization"]) else { continue }
                return (
                    max(0, min(100, 100 - utilization)),
                    label,
                    daysText,
                    resetDescription(window["resets_at"])
                )
            }
            return nil
        }

        let limits = (object["rate_limit"] as? [String: Any]) ?? object
        let primary = limits["primary_window"] as? [String: Any]
        let secondary = limits["secondary_window"] as? [String: Any]
        // Select the longest actual window; CC Switch may expose weekly quota
        // in either primary_window or secondary_window.
        let windows = [primary, secondary].compactMap { $0 }
        guard let chosen = windows.max(by: {
            (numberValue($0["limit_window_seconds"]) ?? 0) <
            (numberValue($1["limit_window_seconds"]) ?? 0)
        }), let used = numberValue(chosen["used_percent"]) else { return nil }
        let remaining = max(0, min(100, 100 - used))
        let duration = numberValue(chosen["limit_window_seconds"]) ?? 0
        let isWeekly = duration >= 6 * 86_400
        let reset = resetDescription(chosen["reset_after_seconds"])
            ?? resetDescription(chosen["reset_at"])
            ?? (chosen["reset_description"] as? String)
        return (
            remaining,
            isWeekly ? tr("7 日额度", "7-Day Quota") : tr("额度", "Quota"),
            isWeekly ? tr("7 天", "7 Days") : tr("额度", "Quota"),
            reset
        )
    }

    private static func numberValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func resetDescription(_ value: Any?) -> String? {
        if let number = numberValue(value) {
            let timestamp = number > 10_000_000_000 ? number / 1_000 : number
            let date = timestamp > 1_000_000_000
                ? Date(timeIntervalSince1970: timestamp)
                : Date().addingTimeInterval(timestamp)
            return remainingTime(until: date)
        }
        guard let text = stringValue(value), !text.isEmpty else { return nil }
        if let number = Double(text) { return resetDescription(number) }
        if let date = ISO8601DateFormatter().date(from: text) { return remainingTime(until: date) }
        return text
    }

    private static func remainingTime(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded(.down)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }

    private func render(_ next: Snapshot) {
        DispatchQueue.main.async {
            self.snapshot = next
            self.activeProviderWebsite = next.websiteURL
            self.updateStatusItem(for: next)
            if next.kind != .error, next.kind != .placeholder { self.lastSuccessfulRefresh = next.date }
            let refreshDate = self.lastSuccessfulRefresh ?? next.date
            self.updateDashboard(for: next, refreshDate: refreshDate)
            if self.isStatusMenuTracking {
                self.statusMenuNeedsRebuild = true
            } else {
                self.rebuildStatusMenu(for: next, refreshDate: refreshDate)
            }
        }
    }

    private func rebuildStatusMenu(for snapshot: Snapshot, refreshDate: Date?) {
        statusMenu.removeAllItems()
        statusMenu.addItem(makeOverviewMenuItem(for: snapshot, refreshDate: refreshDate))
        statusMenu.addItem(.separator())
        if showQuickSwitchMenu {
            statusMenu.addItem(makeQuickSwitchMenuItem())
        }
        statusMenu.addItem(
            withTitle: tr("立即刷新", "Refresh Now"),
            action: #selector(manualRefresh),
            keyEquivalent: "r"
        ).target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: tr("打开主窗口", "Open Main Window"),
            action: #selector(openDashboard),
            keyEquivalent: ""
        ).target = self
        if showOpenChatGPTMenu {
            statusMenu.addItem(
                withTitle: tr("打开 ChatGPT", "Open ChatGPT"),
                action: #selector(openChatGPT),
                keyEquivalent: ""
            ).target = self
        }
        if showOpenCCSwitchMenu {
            statusMenu.addItem(
                withTitle: tr("打开 CC Switch", "Open CC Switch"),
                action: #selector(openCCSwitch),
                keyEquivalent: ""
            ).target = self
        }
        if showStatusMenu {
            statusMenu.addItem(makeStatusLinksMenuItem())
        }
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: tr("退出 BalanceBar", "Quit BalanceBar"),
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self
        let menuTitles = statusMenu.items.map { item in
            item.title.isEmpty ? "<custom>" : item.title
        }.joined(separator: "|")
        let statusWindow = statusItem.button?.window
        let windowFrame = statusWindow.map { DashboardLogging.rect($0.frame) } ?? "none"
        let screenFrame = statusWindow?.screen.map { DashboardLogging.rect($0.frame) } ?? "none"
        let buttonTitle = statusItem.button?.title ?? ""
        SwitchLog.write(
            "status menu rendered; item_count=\(statusMenu.items.count); items=\(menuTitles); status_visible=\(statusItem.isVisible); button_window=\(statusWindow != nil); window_visible=\(statusWindow?.isVisible ?? false); image=\(statusItem.button?.image != nil); title=\(buttonTitle); window_frame=\(windowFrame); screen_frame=\(screenFrame)",
            level: .debug,
            category: "ui.status-menu",
            throttleKey: "status-menu-render",
            minimumInterval: 1
        )
    }

    private func makeStatusLinksMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: tr("查看状态", "View Status"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: tr("查看状态", "View Status"))
        for link in statusLinks {
            let title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let url = URL(string: address),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else { continue }
            let item = NSMenuItem(
                title: title,
                action: #selector(openStatusLink(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            let empty = NSMenuItem(
                title: tr("尚未添加状态链接", "No status links configured"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        parent.submenu = submenu
        return parent
    }

    private func makeQuickSwitchMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: tr("快速切换", "Quick Switch"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: tr("快速切换", "Quick Switch"))
        submenu.minimumWidth = 210
        let choices = Provider.loadChoices(appType: activeClient.appType)
        let choiceSummary = choices.map {
            "id=\($0.id),name=\($0.name),current=\($0.isCurrent)"
        }.joined(separator: "|")
        if choices.isEmpty {
            let empty = NSMenuItem(title: tr("未找到 Codex 供应商", "No Codex Provider Found"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for choice in choices {
                let item = NSMenuItem(
                    title: "",
                    action: #selector(switchProvider(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = choice.id
                item.state = choice.isCurrent ? .on : .off
                applyQuickSwitchTitle(to: item, providerID: choice.id, providerName: choice.name)
                submenu.addItem(item)
            }
        }
        SwitchLog.write(
            "quick-switch menu built; app_type=\(activeClient.appType); choice_count=\(choices.count); submenu_item_count=\(submenu.items.count); choices=\(choiceSummary.isEmpty ? "<empty>" : choiceSummary); empty_state=\(choices.isEmpty)",
            level: .debug,
            category: "provider.menu",
            throttleKey: "quick-switch-menu-\(activeClient.appType)",
            minimumInterval: 1
        )
        parent.submenu = submenu
        return parent
    }

    private func makeOverviewMenuItem(for snapshot: Snapshot, refreshDate: Date?) -> NSMenuItem {
        if snapshot.kind == .error {
            // The error card has its own layout: the full message wraps below
            // the title row and the card height grows to fit it. The top-right
            // refresh time is preserved in the same format as the other cards.
            return makeOverviewErrorMenuItem(for: snapshot, refreshDate: refreshDate)
        }
        let item = NSMenuItem()
        // The overview is deliberately a static card, not a selectable menu
        // command. Custom labels keep it bright while the item stays disabled.
        item.isEnabled = snapshot.kind == .balance && snapshot.websiteURL != nil
        let isBalance = snapshot.kind == .balance
        let viewHeight: CGFloat = isBalance ? 86 : 102
        let viewWidth: CGFloat = 304
        let horizontalInset: CGFloat = 14
        let contentWidth = viewWidth - (horizontalInset * 2)
        let amountWidth: CGFloat = 141
        let amountX = viewWidth - horizontalInset - amountWidth
        let view = NSView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight))

        let provider = makeOverviewLabel(snapshot.overviewProvider, font: .systemFont(ofSize: 15, weight: .semibold))
        provider.frame = NSRect(x: horizontalInset, y: isBalance ? 58 : 75, width: 189, height: 20)

        if snapshot.kind == .official || snapshot.kind == .balance {
            let timeText = refreshDate.map { Self.timeFormatter.string(from: $0) } ?? "--:--:--"
            let refreshTime = makeOverviewLabel(timeText, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
            refreshTime.textColor = .secondaryLabelColor
            refreshTime.alignment = .right
            refreshTime.frame = NSRect(x: 209, y: isBalance ? 59 : 76, width: 81, height: 17)
            view.addSubview(refreshTime)
        }

        if let percentage = snapshot.progressPercentage {
            let progress = QuotaProgressView(percentage: percentage)
            // Keep the header clean. The progress bar belongs below the two
            // quota-detail rows, in the otherwise empty space above actions.
            progress.frame = NSRect(x: horizontalInset, y: 8, width: contentWidth, height: 5)
            view.addSubview(progress)
        }

        let quotaDetail = makeOverviewLabel(snapshot.overviewQuotaDetail, font: .systemFont(ofSize: 13, weight: .medium))
        let amount = makeOverviewLabel(snapshot.overviewLargeAmount, font: .monospacedDigitSystemFont(ofSize: 31, weight: .semibold))
        amount.alignment = .right

        if isBalance {
            // A third-party balance has no percentage for a progress bar.
            // Align the number with these two compact text rows instead.
            // Preserve the previous spacing above these rows. Only the empty
            // space below the link is reduced by the shorter card height.
            quotaDetail.frame = NSRect(x: horizontalInset, y: 31, width: 128, height: 18)
            amount.frame = NSRect(x: amountX, y: 5, width: amountWidth, height: 48)

            // Center the shared link row between the balance row and divider.
            let linkRowY: CGFloat = 7

            let linkPrefix = makeOverviewLabel(tr("官方链接：", "Official Link:"), font: .systemFont(ofSize: 12, weight: .regular))
            linkPrefix.textColor = .secondaryLabelColor
            linkPrefix.frame = NSRect(x: 14, y: linkRowY, width: AppLanguage.usesSimplifiedChinese ? 62 : 72, height: 17)
            view.addSubview(linkPrefix)

            if snapshot.websiteURL != nil {
                let link = HoverLinkTextField(text: snapshot.provider)
                link.onActivate = { [weak self] in self?.openProviderWebsite() }
                // Match the prefix label's exact baseline and line box.
                link.frame = NSRect(
                    x: AppLanguage.usesSimplifiedChinese ? 75 : 87,
                    y: linkRowY,
                    width: AppLanguage.usesSimplifiedChinese ? 148 : 136,
                    height: 17
                )
                view.addSubview(link)
            }
        } else {
            // The following two rows form the left half of the quota display;
            // the amount spans both on right.
            quotaDetail.frame = NSRect(x: horizontalInset, y: 47, width: 128, height: 18)
            let reset = makeOverviewLabel(snapshot.overviewReset(refreshDate: refreshDate, formatter: Self.timeFormatter), font: .systemFont(ofSize: 13, weight: .regular))
            reset.textColor = .secondaryLabelColor
            reset.frame = NSRect(x: horizontalInset, y: 28, width: 128, height: 17)
            // Visually center the large percentage across the combined height
            // of the two left-hand rows (equivalent to merged-cell centering).
            amount.frame = NSRect(x: amountX, y: 18, width: amountWidth, height: 48)
            view.addSubview(reset)
        }

        [provider, quotaDetail, amount].forEach(view.addSubview)
        item.view = view
        return item
    }

    private func makeOverviewErrorMenuItem(for snapshot: Snapshot, refreshDate: Date?) -> NSMenuItem {
        let item = NSMenuItem()
        // Error cards are informational and stay non-interactive.
        item.isEnabled = false
        let message = snapshot.overviewReset(refreshDate: nil, formatter: Self.timeFormatter)
        let frames = ErrorCardLayout.errorFrames(for: message)
        let view = NSView(frame: NSRect(origin: .zero, size: frames.cardSize))

        let provider = makeOverviewLabel(snapshot.overviewProvider, font: ErrorCardLayout.titleFont)
        provider.frame = frames.title
        view.addSubview(provider)

        // Keep the standard top-right refresh time (same format and position
        // as the official/balance cards) so the error card still shows when
        // it was last refreshed.
        let timeText = refreshDate.map { Self.timeFormatter.string(from: $0) } ?? "--:--:--"
        let refreshTime = makeOverviewLabel(timeText, font: ErrorCardLayout.refreshTimeFont)
        refreshTime.textColor = .secondaryLabelColor
        refreshTime.alignment = .right
        refreshTime.frame = frames.refreshTime
        view.addSubview(refreshTime)

        let quotaDetail = makeOverviewLabel(snapshot.overviewQuotaDetail, font: ErrorCardLayout.quotaFont)
        quotaDetail.frame = frames.quotaDetail
        view.addSubview(quotaDetail)

        let amount = makeOverviewLabel(snapshot.overviewLargeAmount, font: ErrorCardLayout.amountFont)
        amount.alignment = .right
        amount.frame = frames.amount
        view.addSubview(amount)

        let detail = ErrorCardLayout.makeDetailLabel(frames.detailText)
        detail.frame = frames.detail
        view.addSubview(detail)

        item.view = view
        return item
    }

    private func makeOverviewLabel(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

@main
enum BalanceBarMain {
    static func main() {
        migrateLegacyPreferencesIfNeeded()
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? productionBundleIdentifier
        let duplicate = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).contains { $0.processIdentifier != currentPID }
        if duplicate {
            NSLog("BalanceBar: refusing duplicate instance; pid=%d", currentPID)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

// Layout rules for the balance error overview card. The error detail must be
// readable in full without truncation. Normal English words stay whole (word
// wrapping); only over-wide unbreakable tokens such as URLs or continuous
// error codes get character-level break opportunities so they cannot overflow.
// The detail occupies the balance card's left column so the amount placeholder
// can remain in the right column without overlap. Kept as a small pure helper
// so the probe can verify wrapping and overlap headlessly.
private enum ErrorCardLayout {
    static let cardWidth: CGFloat = 304
    static let horizontalInset: CGFloat = 14
    static let contentWidth: CGFloat = cardWidth - horizontalInset * 2
    static let detailWidth: CGFloat = 128
    static let amountWidth: CGFloat = 141
    static let amountX: CGFloat = cardWidth - horizontalInset - amountWidth
    static let refreshTimeWidth: CGFloat = 81
    static let refreshTimeX: CGFloat = cardWidth - horizontalInset - refreshTimeWidth

    // Match the compact third-party balance card for a single-line error.
    static let minimumCardHeight: CGFloat = 86
    static let singleLineDetailHeight: CGFloat = 17

    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let quotaFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let detailFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let amountFont = NSFont.monospacedDigitSystemFont(ofSize: 31, weight: .semibold)
    static let refreshTimeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    struct ErrorFrames {
        let cardSize: NSSize
        let title: NSRect
        let refreshTime: NSRect
        let quotaDetail: NSRect
        let amount: NSRect
        let detail: NSRect
        let detailText: String
    }

    /// Prepares the detail text for word wrapping. Whitespace-delimited tokens
    /// that fit on one line are left untouched, so normal English words stay
    /// whole. Tokens wider than `width` (URLs, continuous error codes, long
    /// unbroken runs) get a zero-width space between every character so they
    /// always have safe break points and can never overflow or be truncated.
    static func detailText(for message: String, width: CGFloat) -> String {
        guard !message.isEmpty else { return message }
        var result = ""
        var token = ""
        for character in message {
            if character.isWhitespace {
                result += wrapIfNeeded(token, width: width)
                result.append(character)
                token = ""
            } else {
                token.append(character)
            }
        }
        result += wrapIfNeeded(token, width: width)
        return result
    }

    private static func wrapIfNeeded(_ token: String, width: CGFloat) -> String {
        guard !token.isEmpty else { return token }
        let tokenWidth = (token as NSString).size(withAttributes: [.font: detailFont]).width
        guard tokenWidth > width else { return token }
        return token.map(String.init).joined(separator: "\u{200B}")
    }

    /// Minimum height that renders the full `message` at `width` using word
    /// wrapping on the break-opportunity text from `detailText(for:width:)`.
    /// Empty and short text keep the compact single-line height.
    static func detailHeight(for message: String, width: CGFloat) -> CGFloat {
        return measuredHeight(of: detailText(for: message, width: width), width: width)
    }

    private static func measuredHeight(of text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return singleLineDetailHeight }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: detailFont, .paragraphStyle: paragraph]
        )
        let measured = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(singleLineDetailHeight, ceil(measured.height) + 1)
    }

    /// Frames for the error card. A single-line detail follows the same three
    /// row rhythm as the compact balance card; additional detail lines shift
    /// the rows above upward by only the extra measured height.
    static func errorFrames(for message: String) -> ErrorFrames {
        let text = detailText(for: message, width: detailWidth)
        let detailH = measuredHeight(of: text, width: detailWidth)
        let extraDetailHeight = max(0, detailH - singleLineDetailHeight)
        let cardHeight = minimumCardHeight + extraDetailHeight
        // The compact one-line amount center is 1pt above the geometric center
        // of the left status/detail region. As that region grows, move the
        // amount by half the extra height to preserve the same optical center.
        let amountY = 5 + extraDetailHeight / 2
        return ErrorFrames(
            cardSize: NSSize(width: cardWidth, height: cardHeight),
            title: NSRect(x: horizontalInset, y: 58 + extraDetailHeight, width: 127, height: 20),
            refreshTime: NSRect(x: refreshTimeX, y: 59 + extraDetailHeight, width: refreshTimeWidth, height: 17),
            quotaDetail: NSRect(x: horizontalInset, y: 31 + extraDetailHeight, width: 128, height: 18),
            amount: NSRect(x: amountX, y: amountY, width: amountWidth, height: 48),
            detail: NSRect(x: horizontalInset, y: 7, width: detailWidth, height: detailH),
            detailText: text
        )
    }

    /// Wrapping label for the error detail. Uses word wrapping on text prepared
    /// by `detailText(for:width:)`, so normal English words stay whole while
    /// over-wide tokens still have safe character-level break points. Never
    /// truncates.
    static func makeDetailLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = detailFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }
}

private struct Snapshot {
    enum Kind { case placeholder, official, balance, error }
    let kind: Kind
    let provider: String
    let amount: Double?
    let unit: String?
    let date: Date?
    let message: String?
    let websiteURL: URL?

    static let placeholder = Snapshot(kind: .placeholder, provider: "", amount: nil, unit: nil, date: nil, message: nil, websiteURL: nil)
    static func official(_ provider: String, _ remaining: Double, _ lane: String, _ reset: String?, _ date: Date) -> Snapshot { Snapshot(kind: .official, provider: provider, amount: remaining, unit: lane, date: date, message: reset, websiteURL: nil) }
    static func balance(_ provider: String, _ amount: Double, _ unit: String, _ websiteURL: URL?, _ date: Date) -> Snapshot { Snapshot(kind: .balance, provider: provider, amount: amount, unit: unit, date: date, message: nil, websiteURL: websiteURL) }
    static func error(_ message: String) -> Snapshot { Snapshot(kind: .error, provider: "", amount: nil, unit: nil, date: nil, message: message, websiteURL: nil) }

    var menuBarTitle: String {
        switch kind {
        case .placeholder: return " …"
        case .official: return " \(Int(amount ?? 0))%"
        case .balance: return " \(format(amount ?? 0, unit ?? "USD"))"
        case .error: return " !"
        }
    }

    var menuBarPrimary: String {
        switch kind {
        case .placeholder: return "…"
        case .official: return "\(Int(amount ?? 0))%"
        case .balance: return format(amount ?? 0, unit ?? "USD")
        case .error: return "!"
        }
    }

    var menuBarSecondary: String {
        kind == .official ? (message ?? "—") : ""
    }

    var menuBarToolTip: String {
        guard kind == .official else { return title }
        return tr(
            "\(title) · 重置：\(message ?? "未知")",
            "\(title) · Reset: \(message ?? "Unknown")"
        )
    }

    var overviewProvider: String {
        switch kind {
        case .placeholder: return "CC Switch"
        case .official, .balance: return provider
        case .error: return "CC Switch"
        }
    }

    func overviewReset(refreshDate: Date?, formatter: DateFormatter) -> String {
        switch kind {
        case .official:
            return tr("重置：\(message ?? "未知")", "Reset: \(message ?? "Unknown")")
        case .balance:
            return tr(
                "最后刷新：\(formatter.string(from: refreshDate ?? date ?? Date()))",
                "Last refreshed: \(formatter.string(from: refreshDate ?? date ?? Date()))"
            )
        case .placeholder:
            return tr("正在读取当前供应商…", "Loading the current Provider…")
        case .error:
            return message ?? tr("余额读取失败", "Failed to load balance")
        }
    }

    var overviewQuotaTitle: String {
        switch kind {
        case .official: return tr("可用额度", "Available Quota")
        case .balance: return tr("可用余额", "Available Balance")
        case .placeholder, .error: return tr("额度状态", "Balance Status")
        }
    }

    var overviewQuotaDetail: String {
        switch kind {
        case .official: return unit ?? tr("7 日额度", "7-Day Quota")
        case .balance: return tr("剩余额度", "Remaining Balance")
        case .placeholder: return tr("等待刷新", "Waiting to Refresh")
        case .error: return tr("读取失败", "Load Failed")
        }
    }

    var overviewLargeAmount: String {
        switch kind {
        case .official: return "\(Int(amount ?? 0))%"
        case .balance: return format(amount ?? 0, unit ?? "USD")
        case .placeholder: return "—"
        case .error: return "—"
        }
    }

    var progressPercentage: Double? {
        kind == .official ? amount : nil
    }

    var title: String {
        switch kind {
        case .placeholder:
            return tr("正在读取 CC Switch…", "Loading CC Switch…")
        case .official:
            return tr(
                "\(provider) 剩余：\(Int(amount ?? 0))%（\(unit ?? "额度")）",
                "\(provider) remaining: \(Int(amount ?? 0))% (\(unit ?? "Quota"))"
            )
        case .balance:
            return tr(
                "\(provider) 剩余：\(format(amount ?? 0, unit ?? "USD"))",
                "\(provider) remaining: \(format(amount ?? 0, unit ?? "USD"))"
            )
        case .error:
            return tr("余额读取失败", "Failed to Load Balance")
        }
    }

    var compactQuotaTitle: String {
        switch kind {
        case .official:
            return tr(
                "\(unit ?? "额度")剩余：\(Int(amount ?? 0))%",
                "\(unit ?? "Quota") remaining: \(Int(amount ?? 0))%"
            )
        default:
            return title
        }
    }

    var compactResetTitle: String {
        switch kind {
        case .official:
            return tr(
                "重置：\(message ?? "等待额度信息")",
                "Reset: \(message ?? "Waiting for quota data")"
            )
        default:
            return ""
        }
    }

    var detail: String {
        switch kind {
        case .balance:
            return tr(
                "更新：\(date?.formatted(date: .omitted, time: .shortened) ?? "刚刚") · 随 CC Switch 自动切换",
                "Updated: \(date?.formatted(date: .omitted, time: .shortened) ?? "Just now") · Follows CC Switch automatically"
            )
        case .official:
            let resetText = message.map {
                tr(" · 重置：\($0)", " · Reset: \($0)")
            } ?? ""
            return tr("每分钟更新官方额度\(resetText)", "Official quota updates every minute\(resetText)")
        case .error: return message ?? tr("未知错误", "Unknown Error")
        case .placeholder: return tr("等待 CC Switch 状态", "Waiting for CC Switch Status")
        }
    }

    private func format(_ amount: Double, _ unit: String) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(2)))
        switch unit.uppercased() {
        case "USD":
            return "$\(number)"
        case "CNY", "CNH", "RMB":
            return "¥\(number)"
        default:
            return "\(number) \(unit)"
        }
    }
}

private struct ProviderChoice {
    let id: String
    let name: String
    let isCurrent: Bool
}

private struct ProviderSummarySource {
    let id: String
    let isOfficial: Bool
    let query: BalanceQuery?
    let officialAccessToken: String?
}

private struct Provider {
    let id: String
    let name: String
    let isOfficial: Bool
    let query: BalanceQuery?
    let queryFailure: BalanceQueryFailure?

    static func loadCurrent(appType: String) -> Provider? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { return nil }
        defer { sqlite3_close(database) }
        let sql = "SELECT id, name, settings_config, meta, category, website_url FROM providers WHERE app_type = ? AND is_current = 1 LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, appType, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
              let configText = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
              let metaText = sqlite3_column_text(statement, 3).map({ String(cString: $0) }) else { return nil }
        let category = sqlite3_column_text(statement, 4).map({ String(cString: $0) })
        let websiteText = sqlite3_column_text(statement, 5).map({ String(cString: $0) })
        guard category != "official" else {
            return Provider(id: id, name: name, isOfficial: true, query: nil, queryFailure: nil)
        }
        var queryFailure: BalanceQueryFailure?
        let query = BalanceQuery.make(
            settingsText: configText,
            metaText: metaText,
            websiteText: websiteText,
            appType: appType,
            onFailure: { queryFailure = $0 }
        )
        return Provider(
            id: id,
            name: name,
            isOfficial: false,
            query: query,
            queryFailure: queryFailure
        )
    }

    static func loadChoices(appType: String) -> [ProviderChoice] {
        let fileManager = FileManager.default
        let databaseExists = fileManager.fileExists(atPath: databasePath)
        let databaseReadable = fileManager.isReadableFile(atPath: databasePath)
        let attributes = try? fileManager.attributesOfItem(atPath: databasePath)
        let databaseSize = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        SwitchLog.write(
            "provider choices read started; app_type=\(appType); database_path=\(databasePath); exists=\(databaseExists); readable=\(databaseReadable); size=\(databaseSize)",
            level: .debug,
            category: "provider.read",
            throttleKey: "provider-read-start-\(appType)",
            minimumInterval: 1
        )

        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let database else {
            let error = database.map { String(cString: sqlite3_errmsg($0)) } ?? "no sqlite handle"
            if let database { sqlite3_close(database) }
            SwitchLog.write(
                "provider choices read failed; app_type=\(appType); stage=open; sqlite_code=\(openCode); error=\(error)",
                level: .error,
                category: "provider.read"
            )
            return []
        }
        defer { sqlite3_close(database) }
        let sql = "SELECT id, name, is_current FROM providers WHERE app_type = ? ORDER BY COALESCE(sort_index, 999999), created_at, id"
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            SwitchLog.write(
                "provider choices read failed; app_type=\(appType); stage=prepare; sqlite_code=\(prepareCode); error=\(String(cString: sqlite3_errmsg(database)))",
                level: .error,
                category: "provider.read"
            )
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, appType, -1, sqliteTransient)
        var result: [ProviderChoice] = []
        var rowCount = 0
        var skippedRowCount = 0
        while true {
            let stepCode = sqlite3_step(statement)
            if stepCode == SQLITE_DONE { break }
            guard stepCode == SQLITE_ROW else {
                SwitchLog.write(
                    "provider choices read failed; app_type=\(appType); stage=step; sqlite_code=\(stepCode); error=\(String(cString: sqlite3_errmsg(database)))",
                    level: .error,
                    category: "provider.read"
                )
                break
            }
            rowCount += 1
            guard let idText = sqlite3_column_text(statement, 0),
                  let nameText = sqlite3_column_text(statement, 1) else {
                skippedRowCount += 1
                SwitchLog.write(
                    "provider row skipped; app_type=\(appType); row=\(rowCount); reason=missing id or name",
                    level: .warning,
                    category: "provider.read"
                )
                continue
            }
            result.append(ProviderChoice(
                id: String(cString: idText),
                name: String(cString: nameText),
                isCurrent: sqlite3_column_int(statement, 2) != 0
            ))
        }
        let choiceSummary = result.map {
            "id=\($0.id),name=\($0.name),current=\($0.isCurrent)"
        }.joined(separator: "|")
        SwitchLog.write(
            "provider choices read completed; app_type=\(appType); row_count=\(rowCount); result_count=\(result.count); skipped_rows=\(skippedRowCount); choices=\(choiceSummary.isEmpty ? "<empty>" : choiceSummary)",
            category: "provider.read",
            throttleKey: "provider-read-complete-\(appType)",
            minimumInterval: 1
        )
        return result
    }

    static func loadSummarySources(appType: String) -> [ProviderSummarySource] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return [] }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3_000)

        let sql = "SELECT id, settings_config, meta, category, website_url FROM providers WHERE app_type = ? ORDER BY COALESCE(sort_index, 999999), created_at, id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, appType, -1, sqliteTransient)

        var result: [ProviderSummarySource] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            let settingsText = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "{}"
            let metaText = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "{}"
            let category = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let websiteText = sqlite3_column_text(statement, 4).map { String(cString: $0) }

            if category == "official" {
                let stored = settingsText.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let auth = stored?["auth"] as? [String: Any]
                let tokens = auth?["tokens"] as? [String: Any]
                let accessToken = tokens?["access_token"] as? String
                result.append(ProviderSummarySource(
                    id: id,
                    isOfficial: true,
                    query: nil,
                    officialAccessToken: accessToken
                ))
            } else {
                result.append(ProviderSummarySource(
                    id: id,
                    isOfficial: false,
                    query: BalanceQuery.make(
                        settingsText: settingsText,
                        metaText: metaText,
                        websiteText: websiteText,
                        appType: appType
                    ),
                    officialAccessToken: nil
                ))
            }
        }
        return result
    }

    static func switchCurrent(to providerID: String, appType: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            throw switchError(tr("无法打开 CC Switch 数据库", "Unable to open the CC Switch database"))
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3_000)

        guard let target = loadSwitchTarget(providerID, appType: appType, database: database) else {
            throw switchError(tr("供应商不存在", "Provider does not exist"))
        }

        let settingsURL = URL(fileURLWithPath: NSString(string: "~/.cc-switch/settings.json").expandingTildeInPath)
        var appSettings = (try? Data(contentsOf: settingsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let preserveOfficialAuth = appSettings["preserveCodexOfficialAuthOnSwitch"] as? Bool ?? false
        let unifyHistory = appSettings["unifyCodexSessionHistory"] as? Bool ?? true

        if !proxyTakeoverIsActive(appType: appType, database: database) {
            if appType == "claude" {
                guard
                    let object = try? JSONSerialization.jsonObject(
                        with: Data(target.settingsConfig.utf8)
                    ) as? [String: Any]
                else {
                    throw switchError(tr(
                        "供应商的 Claude 配置不完整",
                        "The Provider's Claude configuration is incomplete"
                    ))
                }
                let settingsURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/settings.json")
                try FileManager.default.createDirectory(
                    at: settingsURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let settingsData = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try settingsData.write(to: settingsURL, options: .atomic)
            } else {
            guard let stored = try? JSONSerialization.jsonObject(with: Data(target.settingsConfig.utf8)) as? [String: Any],
                  let auth = stored["auth"],
                  var config = stored["config"] as? String else {
                throw switchError(tr("供应商的 Codex 配置不完整", "The Provider's Codex configuration is incomplete"))
            }

            let codexDirectory = URL(fileURLWithPath: NSString(string: "~/.codex").expandingTildeInPath, isDirectory: true)
            let authURL = codexDirectory.appendingPathComponent("auth.json")
            let configURL = codexDirectory.appendingPathComponent("config.toml")
            try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)

            // CC Switch syncs MCP entries separately after a provider switch.
            // Preserve the currently enabled live MCP sections here as well.
            let liveConfig = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            config = replacingMCPSections(in: config, with: mcpSections(from: liveConfig))

            if target.category == "official", unifyHistory {
                config = injectingUnifiedOfficialRoute(into: config)
            }

            if target.category != "official", preserveOfficialAuth {
                if let authObject = auth as? [String: Any],
                   let token = authObject["OPENAI_API_KEY"] as? String, !token.isEmpty {
                    config = injectingBearerToken(token, into: config)
                }
            } else {
                let authData = try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys])
                try authData.write(to: authURL, options: .atomic)
            }
            try Data(config.utf8).write(to: configURL, options: .atomic)
            }
        }

        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw switchError(tr("CC Switch 数据库正忙", "The CC Switch database is busy"))
        }
        var committed = false
        defer { if !committed { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) } }
        try execute(
            database,
            sql: "UPDATE providers SET is_current = 0 WHERE app_type = ?",
            bindings: [appType]
        )
        try execute(
            database,
            sql: "UPDATE providers SET is_current = 1 WHERE id = ? AND app_type = ?",
            bindings: [providerID, appType]
        )
        guard sqlite3_changes(database) == 1 else {
            throw switchError(tr("未能选中供应商", "Unable to select the Provider"))
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw switchError(tr("无法保存供应商切换", "Unable to save the Provider switch"))
        }
        committed = true

        appSettings[appType == "claude" ? "currentProviderClaude" : "currentProviderCodex"] = providerID
        let settingsData = try JSONSerialization.data(withJSONObject: appSettings, options: [.prettyPrinted, .sortedKeys])
        try settingsData.write(to: settingsURL, options: .atomic)
    }

    private struct SwitchTarget {
        let settingsConfig: String
        let category: String?
    }

    private static func loadSwitchTarget(
        _ id: String,
        appType: String,
        database: OpaquePointer
    ) -> SwitchTarget? {
        var statement: OpaquePointer?
        let sql = "SELECT settings_config, category FROM providers WHERE id = ? AND app_type = ? LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, appType, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let settingsText = sqlite3_column_text(statement, 0) else { return nil }
        return SwitchTarget(
            settingsConfig: String(cString: settingsText),
            category: sqlite3_column_text(statement, 1).map { String(cString: $0) }
        )
    }

    private static func proxyTakeoverIsActive(
        appType: String,
        database: OpaquePointer
    ) -> Bool {
        let sql = "SELECT EXISTS(SELECT 1 FROM proxy_config WHERE app_type = ? AND (live_takeover_active = 1 OR enabled = 1)) OR EXISTS(SELECT 1 FROM proxy_live_backup WHERE app_type = ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, appType, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, appType, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) != 0
    }

    private static func execute(
        _ database: OpaquePointer,
        sql: String,
        bindings: [String] = []
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw switchError(tr("数据库写入准备失败", "Failed to prepare the database write"))
        }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), binding, -1, sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw switchError(tr("数据库写入失败", "Database write failed"))
        }
    }

    private static func mcpSections(from config: String) -> String {
        var collecting = false
        var lines: [String] = []
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                collecting = trimmed == "[mcp_servers]" || trimmed.hasPrefix("[mcp_servers.")
            }
            if collecting { lines.append(line) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingMCPSections(in config: String, with replacement: String) -> String {
        var skipping = false
        var lines: [String] = []
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                skipping = trimmed == "[mcp_servers]" || trimmed.hasPrefix("[mcp_servers.")
            }
            if !skipping { lines.append(line) }
        }
        var result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !replacement.isEmpty { result += "\n\n" + replacement }
        return result + "\n"
    }

    private static func injectingUnifiedOfficialRoute(into config: String) -> String {
        if config.range(of: #"(?m)^\s*model_provider\s*="# , options: .regularExpression) != nil { return config }
        if config.contains("[model_providers.custom]") { return config }
        return "model_provider = \"custom\"\n" + config.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" +
            "[model_providers.custom]\nname = \"OpenAI\"\nrequires_openai_auth = true\nsupports_websockets = true\nwire_api = \"responses\"\n"
    }

    private static func injectingBearerToken(_ token: String, into config: String) -> String {
        let escaped = token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let line = "experimental_bearer_token = \"\(escaped)\""
        if config.range(of: #"(?m)^\s*experimental_bearer_token\s*="# , options: .regularExpression) != nil {
            return config.replacingOccurrences(of: #"(?m)^\s*experimental_bearer_token\s*=.*$"#, with: line, options: .regularExpression)
        }
        guard let header = config.range(of: #"(?m)^\[model_providers\.[^\]]+\]\s*$"#, options: .regularExpression) else {
            return config + "\n" + line + "\n"
        }
        return config[..<header.upperBound] + "\n" + line + config[header.upperBound...]
    }

    private static func switchError(_ message: String) -> NSError {
        NSError(domain: "BalanceBar.ProviderSwitch", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private enum NativeBalanceProvider {
    case deepSeek
    case stepFun
    case siliconFlowCN
    case siliconFlowEN
    case openRouter
    case novitaAI

    init?(baseURL: String) {
        let value = baseURL.lowercased()
        if value.contains("api.deepseek.com") {
            self = .deepSeek
        } else if value.contains("api.stepfun.ai")
                    || value.contains("api.stepfun.com") {
            self = .stepFun
        } else if value.contains("api.siliconflow.cn") {
            self = .siliconFlowCN
        } else if value.contains("api.siliconflow.com") {
            self = .siliconFlowEN
        } else if value.contains("openrouter.ai") {
            self = .openRouter
        } else if value.contains("api.novita.ai") {
            self = .novitaAI
        } else {
            return nil
        }
    }

    var endpoint: String {
        switch self {
        case .deepSeek:
            return "https://api.deepseek.com/user/balance"
        case .stepFun:
            return "https://api.stepfun.com/v1/accounts"
        case .siliconFlowCN:
            return "https://api.siliconflow.cn/v1/user/info"
        case .siliconFlowEN:
            return "https://api.siliconflow.com/v1/user/info"
        case .openRouter:
            return "https://openrouter.ai/api/v1/credits"
        case .novitaAI:
            return "https://api.novita.ai/v3/user/balance"
        }
    }
}

private enum BalanceQueryFailure: String {
    case settingsJSONInvalid = "settings-json-invalid"
    case metaJSONInvalid = "meta-json-invalid"
    case usageScriptMissing = "usage-script-missing"
    case usageScriptInvalid = "usage-script-invalid"
    case usageScriptDisabled = "usage-script-disabled"
    case credentialMissing = "credential-missing"
    case baseURLMissing = "base-url-missing"
    case requestCodeMissing = "request-code-missing"
    case requestEndpointMissing = "request-endpoint-missing"
    case nativeTemplateUnsupported = "native-template-unsupported"
    case newAPIUserIDMissing = "newapi-user-id-missing"
    case unknown = "unknown"

    var diagnostic: String {
        switch self {
        case .settingsJSONInvalid: return "stage=settings-json; reason=invalid"
        case .metaJSONInvalid: return "stage=meta-json; reason=invalid"
        case .usageScriptMissing: return "stage=usage-script; reason=missing"
        case .usageScriptInvalid: return "stage=usage-script; reason=invalid"
        case .usageScriptDisabled: return "stage=usage-script; reason=disabled"
        case .credentialMissing: return "stage=credentials; reason=missing"
        case .baseURLMissing: return "stage=base-url; reason=missing"
        case .requestCodeMissing: return "stage=request-code; reason=missing"
        case .requestEndpointMissing: return "stage=request-endpoint; reason=missing"
        case .nativeTemplateUnsupported: return "stage=template; reason=native-provider-unsupported"
        case .newAPIUserIDMissing: return "stage=template; reason=newapi-user-id-missing"
        case .unknown: return "stage=configuration; reason=unknown"
        }
    }
}

private struct BalanceQuery {
    let url: String
    let websiteURL: URL?
    let apiKey: String
    let intervalMinutes: Int
    let timeoutSeconds: Int
    let isRightCode: Bool
    let subscriptionPrefix: String
    let nativeBalanceProvider: NativeBalanceProvider?
    let isNewAPI: Bool
    let additionalHeaders: [String: String]

    static func make(
        settingsText: String,
        metaText: String,
        websiteText: String?,
        appType: String,
        onFailure: ((BalanceQueryFailure) -> Void)? = nil
    ) -> BalanceQuery? {
        guard let settings = jsonObject(settingsText) else {
            onFailure?(.settingsJSONInvalid)
            return nil
        }
        guard let meta = jsonObject(metaText) else {
            onFailure?(.metaJSONInvalid)
            return nil
        }
        guard let scriptValue = meta["usage_script"] else {
            onFailure?(.usageScriptMissing)
            return nil
        }
        let script: [String: Any]
        if let dictionary = scriptValue as? [String: Any] {
            script = dictionary
        } else if let scriptText = scriptValue as? String,
                  let dictionary = jsonObject(scriptText) {
            script = dictionary
        } else {
            onFailure?(.usageScriptInvalid)
            return nil
        }
        guard boolValue(script["enabled"]) == true else {
            onFailure?(.usageScriptDisabled)
            return nil
        }

        let apiKey = findString(
            in: script,
            names: ["accessToken", "access_token", "apiKey", "api_key", "key", "token"]
        ) ??
            findString(
                in: settings,
                names: [
                    "OPENAI_API_KEY",
                    "ANTHROPIC_AUTH_TOKEN",
                    "ANTHROPIC_API_KEY",
                    "apiKey",
                    "api_key",
                    "key",
                    "token"
                ]
            ) ??
            tomlBearerToken(in: settings["config"] as? String)
        let baseURL = findString(in: script, names: ["baseUrl", "base_url", "url"]) ??
            findString(
                in: settings,
                names: [
                    "ANTHROPIC_BASE_URL",
                    "OPENAI_BASE_URL",
                    "baseUrl",
                    "base_url",
                    "url"
                ]
            ) ??
            tomlBaseURL(in: settings["config"] as? String)
        guard let apiKey, !apiKey.isEmpty else {
            onFailure?(.credentialMissing)
            return nil
        }
        guard let baseURL, !baseURL.isEmpty else {
            onFailure?(.baseURLMissing)
            return nil
        }

        let interval = (script["autoQueryInterval"] as? NSNumber)?.intValue ?? 30
        let timeout = (script["timeout"] as? NSNumber)?.intValue ?? 15
        let configuredWebsite = websiteText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let websiteURL = configuredWebsite.flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? URL(string: baseURL)
        let templateType = (
            script["templateType"] as? String
                ?? script["template_type"] as? String
                ?? ""
        ).lowercased()
        if templateType == "balance" {
            guard let native = NativeBalanceProvider(baseURL: baseURL) else {
                onFailure?(.nativeTemplateUnsupported)
                return nil
            }
            return BalanceQuery(
                url: native.endpoint,
                websiteURL: websiteURL,
                apiKey: apiKey,
                intervalMinutes: interval,
                timeoutSeconds: timeout,
                isRightCode: false,
                subscriptionPrefix: appType == "claude" ? "/claude" : "/codex",
                nativeBalanceProvider: native,
                isNewAPI: false,
                additionalHeaders: [:]
            )
        }

        guard let code = script["code"] as? String, !code.isEmpty else {
            onFailure?(.requestCodeMissing)
            return nil
        }
        guard let template = capture(
            "url\\s*:\\s*[`\\\"]([^`\\\"]+)",
            in: code
        ) else {
            onFailure?(.requestEndpointMissing)
            return nil
        }
        let url = template.replacingOccurrences(
            of: "{{baseUrl}}",
            with: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        var additionalHeaders: [String: String] = [:]
        if templateType == "newapi" {
            guard let userID = findString(
                in: script,
                names: ["userId", "user_id", "userID"]
            ), !userID.isEmpty else {
                onFailure?(.newAPIUserIDMissing)
                return nil
            }
            additionalHeaders["Content-Type"] = "application/json"
            additionalHeaders["New-Api-User"] = userID
            additionalHeaders["User-Agent"] = "cc-switch/1.0"
        }
        return BalanceQuery(
            url: url,
            websiteURL: websiteURL,
            apiKey: apiKey,
            intervalMinutes: interval,
            timeoutSeconds: timeout,
            isRightCode: url.contains("/account/summary"),
            subscriptionPrefix: appType == "claude" ? "/claude" : "/codex",
            nativeBalanceProvider: nil,
            isNewAPI: templateType == "newapi",
            additionalHeaders: additionalHeaders
        )
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func findString(in value: Any, names: [String]) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if names.contains(key), let string = nested as? String, !string.isEmpty { return string }
            }
            for nested in dictionary.values {
                if let result = findString(in: nested, names: names) { return result }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let result = findString(in: nested, names: names) { return result }
            }
        }
        return nil
    }

    private static func tomlBaseURL(in config: String?) -> String? {
        guard let config else { return nil }
        return capture("base_url\\s*=\\s*\\\"([^\\\"]+)\\\"", in: config)
    }

    private static func tomlBearerToken(in config: String?) -> String? {
        guard let config else { return nil }
        return capture("(?m)^\\s*experimental_bearer_token\\s*=\\s*\\\"([^\\\"]+)\\\"", in: config)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        default: return nil
        }
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
