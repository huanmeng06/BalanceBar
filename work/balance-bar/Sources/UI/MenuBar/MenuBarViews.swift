import AppKit

final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class MenuBarContentView: NSView {
    override var isFlipped: Bool { true }
}

final class MenuBarTextView: NSView {
    override var isFlipped: Bool { true }

    var layoutSize: NSSize = NSSize(width: 32, height: 18) {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize { layoutSize }
}
