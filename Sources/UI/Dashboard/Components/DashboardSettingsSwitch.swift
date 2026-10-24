import AppKit

/// Settings toggle whose appearance is painted by the app instead of the
/// stock SwiftUI-hosted switch content.
///
/// macOS 26 hosts every NSSwitch's pixels inside an
/// `_NSCoreHostingView<AppKitSwitch>` subview. Once such a switch has flipped
/// state in place, that hosted layer can stop painting its knob, leaving a
/// solid accent capsule with no knob — measured on macOS 26.5 where the knob
/// layer still exists with a sane frame but paints nothing. Layout, mouse
/// tracking, target/action, accessibility and keyboard behaviour stay native
/// `NSSwitch` behavior; only the pixels are ours, so the knob is guaranteed on
/// every macOS release and appearance.
final class DashboardSettingsSwitch: NSSwitch {
    /// Stock 54×24 control: knob is 32×20 with a 2pt inset (measured from the
    /// hosted layer geometry). Scaled by height so smaller control sizes keep
    /// the same proportions.
    private static let knobWidthToHeight: CGFloat = 32.0 / 20.0
    private static let knobInsetToHeight: CGFloat = 2.0 / 24.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hideStockAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        hideStockAppearance()
    }

    /// The hosted switch content may be (re)attached at any time; every
    /// subview of this control is stock rendering, so keep it hidden.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        subview.isHidden = true
    }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        hideStockAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func hideStockAppearance() {
        for subview in subviews {
            subview.isHidden = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        guard bounds.width >= 8, bounds.height >= 8 else { return }

        let isOn = state == .on
        let fillAlpha: CGFloat = isEnabled ? 1 : 0.45

        let track = NSBezierPath(
            roundedRect: bounds,
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        trackColor(isOn: isOn).withAlphaComponent(fillAlpha).setFill()
        track.fill()
        trackBorderColor(isOn: isOn).withAlphaComponent(fillAlpha).setStroke()
        track.lineWidth = 1
        track.stroke()

        let inset = max(1, round(bounds.height * Self.knobInsetToHeight))
        let knobHeight = bounds.height - inset * 2
        let knobWidth = round(knobHeight * Self.knobWidthToHeight)
        let knobOriginX = isOn
            ? bounds.maxX - inset - knobWidth
            : bounds.minX + inset
        let knobRect = NSRect(
            x: knobOriginX,
            y: bounds.midY - knobHeight / 2,
            width: knobWidth,
            height: knobHeight
        )
        let knob = NSBezierPath(
            roundedRect: knobRect,
            xRadius: knobHeight / 2,
            yRadius: knobHeight / 2
        )

        let knobShadow = NSShadow()
        knobShadow.shadowOffset = NSSize(width: 0, height: -1)
        knobShadow.shadowBlurRadius = 1.5
        knobShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        knobShadow.set()
        knobColor().withAlphaComponent(fillAlpha).setFill()
        knob.fill()
        NSShadow().set()

        knobBorderColor().withAlphaComponent(fillAlpha).setStroke()
        knob.lineWidth = 1
        knob.stroke()
    }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds,
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    private func trackColor(isOn: Bool) -> NSColor {
        isOn
            ? .controlAccentColor
            : dashboardAdaptiveColor(
                light: NSColor(calibratedWhite: 225 / 255, alpha: 1),
                dark: NSColor(calibratedRed: 84 / 255, green: 84 / 255, blue: 88 / 255, alpha: 1)
            )
    }

    private func trackBorderColor(isOn: Bool) -> NSColor {
        isOn
            ? NSColor.black.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.1)
    }

    private func knobColor() -> NSColor {
        NSColor.white
    }

    private func knobBorderColor() -> NSColor {
        dashboardAdaptiveColor(
            light: NSColor.black.withAlphaComponent(0.12),
            dark: NSColor.black.withAlphaComponent(0.3)
        )
    }
}
