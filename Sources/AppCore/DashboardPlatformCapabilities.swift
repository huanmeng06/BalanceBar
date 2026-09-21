import Foundation

/// Dashboard chrome ownership for one OS family.
///
/// Callers ask whether the running system should use native AppKit
/// ownership. They do not ask whether the major version equals 26, 27, or
/// 28. Version numbers belong only in `resolve(for:)`.
///
/// These flags choose behavior. They do not replace `#available` at the
/// public API sites that the Swift compiler still requires
/// (`automaticallyAdjustsSafeAreaInsets`,
/// `NSSplitViewItemAccessoryViewController`).
struct DashboardPlatformCapabilities: Equatable, Sendable {
    /// Opaque system window surface instead of the pre-Tahoe translucent shell.
    var usesNativeWindowSurface: Bool
    /// Page `NSScrollView` overlaps chrome and lets AppKit write content insets.
    var usesAutomaticPageContentInsets: Bool
    /// Sidebar source-list `NSScrollView` overlaps chrome the same way.
    var usesAutomaticSidebarContentInsets: Bool
    /// Adjacent content split item publishes sidebar overlap through safe area.
    var adjustsAdjacentContentSafeArea: Bool
    /// Content pane may host `NSSplitViewItemAccessoryViewController`.
    var supportsSplitItemAccessories: Bool
    /// Pre-Tahoe non-scrolling titlebar clearance (page 52pt, sidebar titlebar+14).
    var usesLegacyTitlebarClearance: Bool

    /// macOS 26+ native AppKit ownership. Future majors inherit this family
    /// until a public API changes semantics.
    static let nativeAppKitOwnership = DashboardPlatformCapabilities(
        usesNativeWindowSurface: true,
        usesAutomaticPageContentInsets: true,
        usesAutomaticSidebarContentInsets: true,
        adjustsAdjacentContentSafeArea: true,
        supportsSplitItemAccessories: true,
        usesLegacyTitlebarClearance: false
    )

    /// macOS 14/15 compatibility family. Transparent titlebar plus fixed
    /// clearance; no split-item accessory overlay.
    static let legacyCompatibility = DashboardPlatformCapabilities(
        usesNativeWindowSurface: false,
        usesAutomaticPageContentInsets: false,
        usesAutomaticSidebarContentInsets: false,
        adjustsAdjacentContentSafeArea: false,
        supportsSplitItemAccessories: false,
        usesLegacyTitlebarClearance: true
    )

    static var current: DashboardPlatformCapabilities {
        resolve(for: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func resolve(
        for version: OperatingSystemVersion
    ) -> DashboardPlatformCapabilities {
        version.majorVersion >= 26 ? nativeAppKitOwnership : legacyCompatibility
    }
}
