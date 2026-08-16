import AppKit
import SwiftUI

enum StatusLinkField: Equatable {
    case title
    case url
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

struct StatusLinksEditorView: View {
    @ObservedObject var model: StatusLinksEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(tr("状态链接", "Status Links"))
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 12)
                Button(tr("恢复默认", "Restore Defaults"), action: model.reset)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("statusLinks.reset")
            }
            .frame(height: 24)
            .background(StatusLinksGeometryAnchor(identifier: NSUserInterfaceItemIdentifier("statusLinks.title.anchor")))

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
            .background(StatusLinksGeometryAnchor(identifier: NSUserInterfaceItemIdentifier("statusLinks.header.anchor")))

            ForEach(model.links.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    StatusTextField(
                        text: $model.links[index].title,
                        placeholder: tr("显示名称", "Display name"),
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
    var isVisible: Bool {
        (heightConstraint?.constant ?? 0) > 0 && alphaValue > 0
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
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = true
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
        var didApplyHeight = false
        let applyHeight = {
            guard self.linkUpdateGeneration == updateGeneration,
                  !didApplyHeight
            else { return }
            didApplyHeight = true
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
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                // Update model geometry immediately so the scroll document
                // knows its final bottom from the first animation frame;
                // AppKit animates the resulting layout presentation.
                self.heightConstraint?.constant = targetHeight
                self.synchronizeAncestorCardHeight(editorHeight: targetHeight)
                self.superview?.layoutSubtreeIfNeeded()
            } completionHandler: {
                applyHeight()
            }
            // AppKit can defer a constraint-animation completion when a
            // window is mid-layout. Keep one generation-scoped fallback so
            // the local row reveal and scroll-follow settle on schedule.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) {
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
            self.heightConstraint?.constant = targetHeight
            self.hostingHeightConstraint?.constant = targetHeight
            self.synchronizeAncestorCardHeight()
            self.needsLayout = true
            self.superview?.needsLayout = true
            self.superview?.layoutSubtreeIfNeeded()
        }
        guard animated else {
            alphaValue = visible ? 1 : 0
            applyLayout()
            return
        }

        if visible {
            // Establish the final frame first. Only opacity is animated, so
            // the editor never travels through the rows above it.
            alphaValue = 0
            applyLayout()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = 1
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            self.alphaValue = 0
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
