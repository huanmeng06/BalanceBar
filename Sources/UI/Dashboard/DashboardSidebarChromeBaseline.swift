import AppKit

/// Stable source-list top inset for the current window presentation mode.
///
/// Live `contentLayoutRect` includes temporary window titlebar accessories.
/// The baseline used for sidebar navigation must not: it is the system
/// titlebar/toolbar chrome for the current windowed or fullscreen mode.
enum DashboardSidebarChromeBaseline {
    /// Padding below system chrome. Not an accessory height.
    static let sourceListPadding: CGFloat = 14

    struct Measurement: Equatable {
        var isFullScreen: Bool
        var windowFrame: NSRect
        var contentLayoutRect: NSRect
        var liveChromeHeight: CGFloat
        var titlebarAccessoryHeight: CGFloat
        var stableChromeHeight: CGFloat
    }

    /// Remembers the accessory-free chrome for windowed and fullscreen
    /// presentations separately. Temporary page accessories never replace a
    /// captured windowed baseline, so mount/unmount cannot jump navigation.
    struct Store {
        private var windowedStableChromeHeight: CGFloat?
        private var fullscreenStableChromeHeight: CGFloat?

        mutating func resolvedStableChromeHeight(
            isFullScreen: Bool,
            liveChromeHeight: CGFloat,
            titlebarAccessoryHeight: CGFloat
        ) -> CGFloat {
            recordStableChromeHeight(
                isFullScreen: isFullScreen,
                liveChromeHeight: liveChromeHeight,
                titlebarAccessoryHeight: titlebarAccessoryHeight
            )
        }

        mutating func resolvedSourceListTopInset(
            isFullScreen: Bool,
            liveChromeHeight: CGFloat,
            titlebarAccessoryHeight: CGFloat
        ) -> CGFloat {
            sourceListTopInset(
                stableChromeHeight: resolvedStableChromeHeight(
                    isFullScreen: isFullScreen,
                    liveChromeHeight: liveChromeHeight,
                    titlebarAccessoryHeight: titlebarAccessoryHeight
                )
            )
        }

        var windowedStableChromeHeightForTesting: CGFloat? {
            windowedStableChromeHeight
        }

        var fullscreenStableChromeHeightForTesting: CGFloat? {
            fullscreenStableChromeHeight
        }

        private mutating func recordStableChromeHeight(
            isFullScreen: Bool,
            liveChromeHeight: CGFloat,
            titlebarAccessoryHeight: CGFloat
        ) -> CGFloat {
            let accessoryFree = stableChromeHeight(
                liveChromeHeight: liveChromeHeight,
                titlebarAccessoryHeight: titlebarAccessoryHeight
            )
            if isFullScreen {
                // Fullscreen chrome is rebuilt by AppKit on each transition.
                fullscreenStableChromeHeight = accessoryFree
                return accessoryFree
            }
            if windowedStableChromeHeight == nil {
                windowedStableChromeHeight = accessoryFree
            }
            return windowedStableChromeHeight ?? accessoryFree
        }
    }

    static func liveChromeHeight(in window: NSWindow) -> CGFloat {
        max(0, window.frame.height - window.contentLayoutRect.height)
    }

    static func titlebarAccessoryHeight(in window: NSWindow) -> CGFloat {
        window.layoutIfNeeded()
        return window.titlebarAccessoryViewControllers.reduce(0) { partial, accessory in
            guard !accessory.isHidden else { return partial }
            accessory.view.layoutSubtreeIfNeeded()
            return partial + max(0, accessory.view.frame.height)
        }
    }

    static func stableChromeHeight(
        liveChromeHeight: CGFloat,
        titlebarAccessoryHeight: CGFloat
    ) -> CGFloat {
        max(0, liveChromeHeight - max(0, titlebarAccessoryHeight))
    }

    static func sourceListTopInset(stableChromeHeight: CGFloat) -> CGFloat {
        max(0, stableChromeHeight + sourceListPadding)
    }

    static func measurement(in window: NSWindow) -> Measurement {
        let live = liveChromeHeight(in: window)
        let accessory = titlebarAccessoryHeight(in: window)
        return Measurement(
            isFullScreen: window.styleMask.contains(.fullScreen),
            windowFrame: window.frame,
            contentLayoutRect: window.contentLayoutRect,
            liveChromeHeight: live,
            titlebarAccessoryHeight: accessory,
            stableChromeHeight: stableChromeHeight(
                liveChromeHeight: live,
                titlebarAccessoryHeight: accessory
            )
        )
    }
}
