import AppKit
import SwiftUI

enum StatusLinkField: Equatable {
    case title
    case url
}

enum StatusLinksAnimationPolicy {
    static let normalDuration: TimeInterval = 0.20
    static let reducedMotionDuration: TimeInterval = 0

    static func shouldAnimate(requested: Bool, reduceMotion: Bool) -> Bool {
        requested && !reduceMotion
    }

    static func duration(requested: Bool, reduceMotion: Bool) -> TimeInterval {
        shouldAnimate(requested: requested, reduceMotion: reduceMotion)
            ? normalDuration
            : reducedMotionDuration
    }
}

/// A native SwiftUI text field kept at its natural single-line height and
/// centered by the fixed-height outer container. The system rounded-border
/// style owns the background, border, focus ring, and appearance adaptation.
struct StatusTextField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: .infinity,
                minHeight: 28,
                maxHeight: 28,
                alignment: .center
            )
    }
}

final class StatusLinksEditorModel: ObservableObject {
    static let minimumRowCount = 0

    @Published var links: [StatusLink]
    @Published private(set) var selectedIndex: Int?

    let onChange: (Int, StatusLinkField, String) -> Void
    let onEnabledChange: (Int, Bool) -> Void
    let onAdd: () -> Void
    let onRemove: (Int) -> Void
    let onReset: () -> Void

    var rowNumbers: [Int] {
        links.indices.map { $0 + 1 }
    }

    var canRemoveSelected: Bool {
        guard let selectedIndex,
              links.indices.contains(selectedIndex) else {
            return false
        }
        return links.count > Self.minimumRowCount
    }

    init(
        links: [StatusLink],
        onChange: @escaping (Int, StatusLinkField, String) -> Void,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (Int) -> Void,
        onEnabledChange: @escaping (Int, Bool) -> Void = { _, _ in },
        onReset: @escaping () -> Void
    ) {
        self.links = links
        self.selectedIndex = nil
        self.onChange = onChange
        self.onEnabledChange = onEnabledChange
        self.onAdd = onAdd
        self.onRemove = onRemove
        self.onReset = onReset
    }

    func select(index: Int?) {
        guard let index else {
            selectedIndex = nil
            return
        }
        guard links.indices.contains(index) else { return }
        selectedIndex = index
    }

    func edit(index: Int, field: StatusLinkField, value: String) {
        guard links.indices.contains(index) else { return }
        selectedIndex = index
        switch field {
        case .title:
            links[index].title = value
        case .url:
            links[index].url = value
        }
        onChange(index, field, value)
    }

    func setEnabled(index: Int, enabled: Bool) {
        guard links.indices.contains(index) else { return }
        selectedIndex = index
        links[index].enabled = enabled
        onEnabledChange(index, enabled)
    }

    func add() {
        // The callback mutates the source of truth and refreshes this model.
        // Selecting the future last row gives the new row native toolbar
        // semantics without forcing focus away from an existing text field.
        selectedIndex = links.count
        onAdd()
    }

    func removeSelected() {
        guard canRemoveSelected, let selectedIndex else { return }
        onRemove(selectedIndex)
        let resultingCount = max(0, links.count - 1)
        self.selectedIndex = Self.selectionAfterRemoving(
            index: selectedIndex,
            resultingCount: resultingCount
        )
    }

    /// Compatibility entry point for callers that still remove a row by
    /// index. The toolbar uses `removeSelected()` so the view has one clear
    /// selected-row deletion path.
    func remove(at index: Int) {
        guard links.indices.contains(index) else { return }
        select(index: index)
        removeSelected()
    }

    func reset() {
        onReset()
    }

    func updateLinks(_ newLinks: [StatusLink]) {
        links = newLinks
        guard let selectedIndex else { return }
        if newLinks.indices.contains(selectedIndex) {
            self.selectedIndex = selectedIndex
        } else {
            self.selectedIndex = newLinks.indices.last
        }
    }

    static func selectionAfterRemoving(index: Int, resultingCount: Int) -> Int? {
        guard resultingCount > minimumRowCount else { return nil }
        return min(index, resultingCount - 1)
    }
}

struct StatusLinksEditorView: View {
    @ObservedObject var model: StatusLinksEditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text(tr("状态链接", "Status Links"))
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 12)
            }
            .frame(height: 24)

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(model.links.indices, id: \.self) { index in
                        statusLinkRow(index: index)
                        if index < model.links.count - 1 {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: StatusLinksAnimationPolicy.normalDuration),
                    value: model.links
                )

                Divider()

                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Button(action: model.add) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(tr("添加状态链接", "Add status link"))

                        Button(action: model.removeSelected) {
                            Image(systemName: "minus")
                        }
                        .accessibilityLabel(tr("删除选中状态链接", "Remove selected status link"))
                        .disabled(!model.canRemoveSelected)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer(minLength: 12)

                    Button(tr("恢复默认", "Restore Defaults"), action: model.reset)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 12))
                }
                .frame(height: 40)
                .padding(.horizontal, 10)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
            }
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: StatusLinksAnimationPolicy.normalDuration),
                value: model.links
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // NSHostingView fills the animated AppKit height. Keep the SwiftUI
        // content pinned to the top of that host so its title row does not
        // recenter for a frame while the row count changes.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func statusLinkRow(index: Int) -> some View {
        let isSelected = model.selectedIndex == index
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 22, alignment: .center)
                .accessibilityLabel(
                    tr("第 \(index + 1) 个状态链接", "Status link \(index + 1)")
                )

            StatusTextField(
                text: Binding(
                    get: { model.links[index].title },
                    set: { model.edit(index: index, field: .title, value: $0) }
                ),
                placeholder: tr("显示名称", "Display name")
            )
            .onTapGesture { model.select(index: index) }
            .accessibilityLabel(tr("名称", "Name"))

            StatusTextField(
                text: Binding(
                    get: { model.links[index].url },
                    set: { model.edit(index: index, field: .url, value: $0) }
                ),
                placeholder: "https://"
            )
            .onTapGesture { model.select(index: index) }
            .accessibilityLabel(tr("网址", "URL"))

            Toggle(
                isOn: Binding(
                    get: { model.links[index].enabled },
                    set: { model.setEnabled(index: index, enabled: $0) }
                )
            ) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(
                tr("启用第 \(index + 1) 个状态链接", "Enable status link \(index + 1)")
            )
            .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? Color(nsColor: .controlAccentColor).opacity(0.12)
                        : .clear
                )
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(index: index) }
        .accessibilityElement(children: .contain)
    }
}

/// AppKit only hosts the SwiftUI editor and controls its stable outer height.
/// No AppKit text field, cell, or field editor is involved in status-link rows.
final class StatusLinksEditorHostingView: NSView {
    private static let titleHeight: CGFloat = 24
    private static let sectionSpacing: CGFloat = 8
    private static let rowHeight: CGFloat = 42
    private static let toolbarHeight: CGFloat = 40
    private static let dividerHeight: CGFloat = 1
    private static let verticalPadding: CGFloat = 24

    private let model: StatusLinksEditorModel
    private let hostingView: NSHostingView<StatusLinksEditorView>
    private var heightConstraint: NSLayoutConstraint?
    private var links: [StatusLink]
    private(set) var isTornDown = false

    var rowCount: Int { links.count }
    var layoutHeight: CGFloat {
        Self.verticalPadding
            + Self.titleHeight
            + Self.sectionSpacing
            + CGFloat(links.count) * Self.rowHeight
            + Self.dividerHeight
            + Self.toolbarHeight
    }

    init(
        links: [StatusLink],
        onChange: @escaping (Int, StatusLinkField, String) -> Void,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (Int) -> Void,
        onEnabledChange: @escaping (Int, Bool) -> Void = { _, _ in },
        onReset: @escaping () -> Void
    ) {
        self.links = links
        let model = StatusLinksEditorModel(
            links: links,
            onChange: onChange,
            onAdd: onAdd,
            onRemove: onRemove,
            onEnabledChange: onEnabledChange,
            onReset: onReset
        )
        self.model = model
        self.hostingView = NSHostingView(
            rootView: StatusLinksEditorView(model: model)
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
        guard !isTornDown else {
            completion?()
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let effectiveAnimated = StatusLinksAnimationPolicy.shouldAnimate(
            requested: animated,
            reduceMotion: reduceMotion
        )
        let deferAddedRows = revealAddedRowsAtCompletion
            && newLinks.count > links.count
            && effectiveAnimated
        links = newLinks
        // Deletion already has the desired motion: the removed row vanishes
        // first and the card then collapses. For an addition, play that same
        // geometry in reverse by expanding an empty slot first and only
        // revealing the new SwiftUI row once the expansion has settled.
        if !deferAddedRows {
            model.updateLinks(newLinks)
        }
        let targetHeight = layoutHeight
        let applyHeight = {
            self.heightConstraint?.constant = targetHeight
            self.synchronizeAncestorCardHeight()
            self.needsLayout = true
            self.superview?.needsLayout = true
            if deferAddedRows {
                self.superview?.layoutSubtreeIfNeeded()
                self.model.updateLinks(newLinks)
            }
            completion?()
        }
        if effectiveAnimated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = StatusLinksAnimationPolicy.duration(
                    requested: animated,
                    reduceMotion: reduceMotion
                )
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

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        heightConstraint?.isActive = false
        heightConstraint = nil
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
