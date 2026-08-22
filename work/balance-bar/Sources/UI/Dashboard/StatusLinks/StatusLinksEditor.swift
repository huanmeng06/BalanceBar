import AppKit
import SwiftUI

enum StatusLinkField: Equatable {
    case title
    case url
}

enum StatusLinksEditorAnimation {
    static let visibilityDuration: TimeInterval = 0.20
    static let visibilityTimingFunctionName = "easeInEaseOut"

    static func configure(_ context: NSAnimationContext) {
        context.duration = visibilityDuration
        context.timingFunction = CAMediaTimingFunction(
            name: CAMediaTimingFunctionName(rawValue: visibilityTimingFunctionName)
        )
        context.allowsImplicitAnimation = true
    }
}

/// An inert AppKit marker gives regression tests the frame of the actual
/// SwiftUI title/header content without adding another hosting view.
private struct StatusLinksGeometryAnchor: NSViewRepresentable {
    let identifier: NSUserInterfaceItemIdentifier

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = identifier
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = identifier
    }
}

/// A native SwiftUI text field kept at its natural single-line height and
/// centered by the fixed-height outer container. The system rounded-border
/// style owns the background, border, focus ring, and appearance adaptation.
struct StatusTextField: View {
    @Binding var text: String
    let placeholder: String
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 0) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 28,
            maxHeight: 28,
            alignment: .center
        )
    }
}

final class StatusLinksEditorModel: ObservableObject {
    @Published var links: [StatusLink]
    @Published var reservesAddedRowSlot = false
    @Published var revealingAddedRowIndex: Int?
    @Published private(set) var isAddInFlight = false
    @Published private(set) var visibilityOpacity = 1.0
    let onChange: (Int, StatusLinkField, String) -> Void
    let onAdd: () -> Void
    let onRemove: (Int) -> Void
    let onReset: () -> Void
    private var revealGeneration = 0

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

    func edit(index: Int, field: StatusLinkField, value: String) {
        guard links.indices.contains(index) else { return }
        switch field {
        case .title:
            links[index].title = value
        case .url:
            links[index].url = value
        }
        onChange(index, field, value)
    }

    func add() {
        guard !isAddInFlight else { return }
        isAddInFlight = true
        onAdd()
    }

    func remove(at index: Int) {
        guard links.indices.contains(index) else { return }
        onRemove(index)
    }

    func reset() {
        onReset()
    }

    func setVisibilityOpacity(_ opacity: Double, animated: Bool) {
        var transaction = Transaction()
        transaction.animation = animated
            ? .easeInOut(duration: StatusLinksEditorAnimation.visibilityDuration)
            : nil
        withTransaction(transaction) {
            visibilityOpacity = opacity
        }
    }

    func reserveAddedRowSlot() {
        reservesAddedRowSlot = true
    }

    func cancelAddInsertion() {
        revealGeneration &+= 1
        isAddInFlight = false
        reservesAddedRowSlot = false
        revealingAddedRowIndex = nil
    }

    func revealAddedRow(_ newLinks: [StatusLink]) {
        revealGeneration &+= 1
        let generation = revealGeneration
        links = newLinks
        reservesAddedRowSlot = false
        revealingAddedRowIndex = newLinks.indices.last
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revealGeneration == generation else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                self.revealingAddedRowIndex = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.revealGeneration == generation else { return }
                self.isAddInFlight = false
            }
        }
    }
}

private struct StatusLinksResetButton: NSViewRepresentable {
    let title: String
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func reset() {
            action()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.reset)
        )
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        configure(button, coordinator: context.coordinator)
    }

    private func configure(_ button: NSButton, coordinator: Coordinator) {
        button.title = title
        button.target = coordinator
        button.action = #selector(Coordinator.reset)
        // Match the native settings action buttons (for example, “立即刷新”)
        // by letting AppKit's automatic bezel choose the appearance for the
        // containing window and theme.
        button.bezelStyle = .automatic
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.identifier = NSUserInterfaceItemIdentifier("statusLinks.reset")
    }
}

struct StatusLinksEditorView: View {
    @ObservedObject var model: StatusLinksEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(tr("状态链接", "Status Links", "狀態連結", "ステータスリンク"))
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 12)
                StatusLinksResetButton(
                    title: tr("恢复默认", "Restore Defaults", "恢復預設", "デフォルトに戻す"),
                    action: model.reset
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 24)
            .background(StatusLinksGeometryAnchor(identifier: NSUserInterfaceItemIdentifier("statusLinks.title.anchor")))

            HStack(spacing: 8) {
                Text(tr("名称", "Name", "名稱", "名前"))
                    .frame(width: 160, alignment: .leading)
                Text(tr("网址", "URL", "網址", "URL"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 24, height: 1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .frame(height: 20, alignment: .center)
            .background(StatusLinksGeometryAnchor(identifier: NSUserInterfaceItemIdentifier("statusLinks.header.anchor")))

            ForEach(model.links.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    StatusTextField(
                        text: $model.links[index].title,
                        placeholder: tr("显示名称", "Display name", "顯示名稱", "表示名"),
                        accessibilityIdentifier: "statusLinks.name.\(index)"
                    )
                    .frame(width: 160)
                    .onChange(of: model.links[index].title) { _, value in
                        model.edit(index: index, field: .title, value: value)
                    }

                    StatusTextField(
                        text: $model.links[index].url,
                        placeholder: "https://",
                        accessibilityIdentifier: "statusLinks.url.\(index)"
                    )
                    .frame(maxWidth: .infinity)
                    .onChange(of: model.links[index].url) { _, value in
                        model.edit(index: index, field: .url, value: value)
                    }

                    Button {
                        model.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 28)
                    .accessibilityIdentifier("statusLinks.remove.\(index)")
                }
                .frame(height: 35)
                .opacity(model.revealingAddedRowIndex == index ? 0 : 1)
                .animation(
                    .easeInOut(duration: 0.16),
                    value: model.revealingAddedRowIndex == index
                )
            }

            if model.reservesAddedRowSlot {
                Color.clear.frame(height: 35)
            }

            Color.clear.frame(height: 8)

            Button(action: model.add) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: .controlAccentColor))
            .frame(width: 32, height: 28, alignment: .leading)
            .disabled(model.isAddInFlight)
            .accessibilityIdentifier("statusLinks.add")

            // Consume only surplus host height below the controls. This pins
            // title, headers, and existing rows to the visual top while the
            // outer AppKit reveal interpolates its height.
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .compositingGroup()
        .opacity(model.visibilityOpacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// AppKit only hosts the SwiftUI editor and controls its stable outer height.
/// No AppKit text field, cell, or field editor is involved in status-link rows.
final class StatusLinksEditorHostingView: NSView {
    private let model: StatusLinksEditorModel
    private let hostingView: NSHostingView<StatusLinksEditorView>
    private var heightConstraint: NSLayoutConstraint?
    private var hostingHeightConstraint: NSLayoutConstraint?
    private var links: [StatusLink]
    private var visibilityGeneration = 0
    private var linkUpdateGeneration = 0
    private(set) var isTornDown = false

    var rowCount: Int { links.count }
    var layoutHeight: CGFloat { 112 + CGFloat(links.count * 35) }
    var visibilityOpacity: Double { model.visibilityOpacity }
    var isVisible: Bool {
        (heightConstraint?.constant ?? 0) > 0 && visibilityOpacity > 0
    }

    var renderedRowCount: Int { model.links.count }
    var hasReservedAddedRowSlot: Bool { model.reservesAddedRowSlot }
    var isAddInFlight: Bool { model.isAddInFlight }
    var hostedContentTopInset: CGFloat {
        bounds.maxY - convert(hostingView.bounds, from: hostingView).maxY
    }

    func viewportAnchorY(
        identifier: NSUserInterfaceItemIdentifier,
        in viewport: NSView
    ) -> CGFloat? {
        guard let anchor = findDescendant(with: identifier, in: hostingView) else {
            return nil
        }
        return anchor.convert(
            NSPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY),
            to: viewport
        ).y
    }

    /// The hosted SwiftUI hierarchy is always bounded by this view before it
    /// becomes visible. This makes the reveal independent of stack layout
    /// interpolation and prevents content from crossing preceding rows.
    var hostedContentIsWithinRevealBounds: Bool {
        let hostedBounds = convert(hostingView.bounds, from: hostingView)
        return bounds.insetBy(dx: -0.5, dy: -0.5).contains(hostedBounds)
    }

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
            rootView: StatusLinksEditorView(model: model)
        )
        // The surrounding constraints own the host size throughout the row
        // reveal. Do not let NSHostingView negotiate an intrinsic size while
        // that height is interpolating, which can recenter the SwiftUI root.
        self.hostingView.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor)
        ])
        let hostingHeightConstraint = hostingView.heightAnchor.constraint(
            equalToConstant: layoutHeight
        )
        hostingHeightConstraint.isActive = true
        self.hostingHeightConstraint = hostingHeightConstraint
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

    private func findDescendant(
        with identifier: NSUserInterfaceItemIdentifier,
        in view: NSView
    ) -> NSView? {
        if view.identifier == identifier { return view }
        for child in view.subviews {
            if let match = findDescendant(with: identifier, in: child) {
                return match
            }
        }
        return nil
    }

    func updateLinks(
        _ newLinks: [StatusLink],
        animated: Bool,
        revealAddedRowsAtCompletion: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard !isTornDown else {
            completion?()
            return
        }
        linkUpdateGeneration &+= 1
        let updateGeneration = linkUpdateGeneration
        let deferAddedRows = revealAddedRowsAtCompletion && newLinks.count > links.count
        links = newLinks
        // Deletion already has the desired motion: the removed row vanishes
        // first and the card then collapses. For an addition, play that same
        // geometry in reverse by expanding an empty 35pt slot first and only
        // revealing the new SwiftUI row once the expansion has settled.
        if deferAddedRows {
            // The outer AppKit editor supplies the expanding 35pt slot. Keep
            // the sole SwiftUI host on its old rows until that expansion has
            // settled so changing its intrinsic content cannot displace the
            // title/header mid-animation.
        } else {
            model.cancelAddInsertion()
            model.links = newLinks
        }
        let targetHeight = layoutHeight
        let applyHeight = {
            guard self.linkUpdateGeneration == updateGeneration else { return }
            self.heightConstraint?.constant = targetHeight
            self.synchronizeAncestorCardHeight(editorHeight: targetHeight)
            // Keep the hosted old rows at their fixed top-aligned height
            // during the empty-slot expansion. Once the outer reveal reaches
            // its final size, grow this sole host and reveal the new row.
            self.hostingHeightConstraint?.constant = targetHeight
            self.needsLayout = true
            self.superview?.needsLayout = true
            if deferAddedRows {
                self.superview?.layoutSubtreeIfNeeded()
                self.model.revealAddedRow(newLinks)
            }
            completion?()
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                StatusLinksEditorAnimation.configure(context)
                self.heightConstraint?.animator().constant = targetHeight
                self.synchronizeAncestorCardHeight(animated: true, editorHeight: targetHeight)
                self.superview?.layoutSubtreeIfNeeded()
            } completionHandler: {
                applyHeight()
            }
        } else {
            applyHeight()
        }
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        guard !isTornDown else { return }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let targetHeight: CGFloat = visible ? layoutHeight : 0
        let applyLayout = { [weak self] in
            guard let self else { return }
            self.alphaValue = 1
            self.model.setVisibilityOpacity(visible ? 1 : 0, animated: false)
            self.heightConstraint?.constant = targetHeight
            self.hostingHeightConstraint?.constant = targetHeight
            self.synchronizeAncestorCardHeight()
            self.needsLayout = true
            self.superview?.needsLayout = true
            self.superview?.layoutSubtreeIfNeeded()
        }
        guard animated else {
            applyLayout()
            return
        }

        let ancestorInfo = ancestorCardInfo(editorHeight: targetHeight)
        model.setVisibilityOpacity(visible ? 1 : 0, animated: true)
        NSAnimationContext.runAnimationGroup { context in
            StatusLinksEditorAnimation.configure(context)
            self.alphaValue = 1
            self.heightConstraint?.animator().constant = targetHeight
            self.hostingHeightConstraint?.animator().constant = targetHeight
            ancestorInfo?.1.animator().constant = ancestorInfo?.2 ?? 0
            self.superview?.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            applyLayout()
        }
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        heightConstraint?.isActive = false
        heightConstraint = nil
        hostingHeightConstraint?.isActive = false
        hostingHeightConstraint = nil
        hostingView.removeFromSuperview()
    }

    func logGeometry(label: String) {
        let card = (superview as? NSStackView)?.superview
        SwitchLog.write(
            "status-link geometry; label=\(label); rows=\(links.count); editor_frame=\(DashboardLogging.rect(frame)); card_frame=\(card.map { DashboardLogging.rect($0.frame) } ?? "none")",
            category: "ui.geometry"
        )
    }

    deinit {
        teardown()
    }

    private func ancestorCardInfo(
        editorHeight: CGFloat? = nil
    ) -> (NSView, NSLayoutConstraint, CGFloat)? {
        guard let rowsStack = superview as? NSStackView,
              let card = rowsStack.superview else { return nil }
        let requiredHeight = max(1, ceil(rowsStack.arrangedSubviews.reduce(CGFloat(0)) { total, row in
            guard !row.isHidden else { return total }
            if row is NSBox {
                return total + 1
            }
            if row === self {
                return total + max(0, editorHeight ?? heightConstraint?.constant ?? layoutHeight)
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

    private func synchronizeAncestorCardHeight(
        animated: Bool = false,
        editorHeight: CGFloat? = nil
    ) {
        guard let info = ancestorCardInfo(editorHeight: editorHeight) else { return }
        if animated {
            info.1.animator().constant = info.2
        } else {
            info.1.constant = info.2
        }
        info.0.needsLayout = true
    }
}
