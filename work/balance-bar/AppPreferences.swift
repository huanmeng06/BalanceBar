import Foundation

enum MenuBarFontSizePreset: String, CaseIterable, Equatable {
    case large
    case medium
    case small

    var primarySize: Double {
        switch self {
        case .large: return 13.0
        case .medium: return 11.7
        case .small: return 10.4
        }
    }

    var secondarySize: Double {
        switch self {
        case .large: return 10.0
        case .medium: return 9.0
        case .small: return 8.0
        }
    }

    var segmentIndex: Int {
        switch self {
        case .large: return 0
        case .medium: return 1
        case .small: return 2
        }
    }

    init?(segmentIndex: Int) {
        switch segmentIndex {
        case 0: self = .large
        case 1: self = .medium
        case 2: self = .small
        default: return nil
        }
    }

    static func nearest(to primarySize: Double) -> Self {
        guard primarySize.isFinite else { return .large }
        return allCases.min {
            abs($0.primarySize - primarySize) < abs($1.primarySize - primarySize)
        } ?? .large
    }
}

final class AppPreferences {
    static let updateChannelKey = "updateChannel"
    static let defaultUpdateChannel: UpdateChannel = .stable
    static let showOpenCodexMenuKey = "showOpenCodexMenu"
    static let openCodexDashboardPortOverrideKey = "openCodexDashboardPortOverride"
    static let openCodexDashboardAutomaticDetectionKey = "openCodexDashboardAutomaticDetection"
    static let balanceDisplayThresholdKey = "balanceDisplayThreshold"
    static let defaultBalanceDisplayThreshold = 0.10
    static let minimumBalanceDisplayThreshold = 0.01
    static let validOpenCodexDashboardPortRange = 1...65535

    private let defaults: UserDefaults
    private let defaultStatusLinksProvider: () -> [StatusLink]

    init(
        defaults: UserDefaults = .standard,
        defaultStatusLinks: [StatusLink]? = nil,
        defaultStatusLinksProvider: (() -> [StatusLink])? = nil
    ) {
        self.defaults = defaults
        self.defaultStatusLinksProvider = defaultStatusLinksProvider ?? { [defaultStatusLinks] in
            defaultStatusLinks ?? Self.makeDefaultStatusLinks()
        }
    }

    static func makeDefaultStatusLinks() -> [StatusLink] {
        [
            StatusLink(title: "OpenAI Status", url: "https://status.openai.com/"),
            StatusLink(title: tr("Tibo 的动态", "Tibo's Updates", "Tibo 的動態", "Tibo の更新"), url: "https://x.com/thsottiaux")
        ]
    }

    var defaultStatusLinks: [StatusLink] { defaultStatusLinksProvider() }

    var showMenuBarReset: Bool { get { bool("showMenuBarReset", default: true) } set { defaults.set(newValue, forKey: "showMenuBarReset") } }
    var showMenuBarIcon: Bool { get { bool("showMenuBarIcon", default: true) } set { defaults.set(newValue, forKey: "showMenuBarIcon") } }
    var showMenuBarAmount: Bool { get { bool("showMenuBarAmount", default: true) } set { defaults.set(newValue, forKey: "showMenuBarAmount") } }
    var animateCodexActivity: Bool { get { bool("animateCodexActivity", default: true) } set { defaults.set(newValue, forKey: "animateCodexActivity") } }
    var activityPollInterval: TimeInterval { get { positiveDouble("activityPollInterval", default: 0.25) } set { defaults.set(newValue, forKey: "activityPollInterval") } }
    var codexUsageRefreshInterval: TimeInterval { get { positiveDouble("codexUsageRefreshInterval", default: 3) } set { defaults.set(newValue, forKey: "codexUsageRefreshInterval") } }
    var postCodexRefreshDuration: TimeInterval {
        get { max(0, (defaults.object(forKey: "postCodexRefreshDuration") as? NSNumber)?.doubleValue ?? 12) }
        set { defaults.set(newValue, forKey: "postCodexRefreshDuration") }
    }
    var showQuickSwitchMenu: Bool { get { bool("showQuickSwitchMenu", default: true) } set { defaults.set(newValue, forKey: "showQuickSwitchMenu") } }
    var showOpenCCSwitchMenu: Bool { get { bool("showOpenCCSwitchMenu", default: true) } set { defaults.set(newValue, forKey: "showOpenCCSwitchMenu") } }
    var showOpenCodexMenu: Bool {
        get { bool(Self.showOpenCodexMenuKey, default: true) }
        set { defaults.set(newValue, forKey: Self.showOpenCodexMenuKey) }
    }
    var showOpenChatGPTMenu: Bool { get { bool("showOpenChatGPTMenu", default: true) } set { defaults.set(newValue, forKey: "showOpenChatGPTMenu") } }
    var showStatusMenu: Bool { get { bool("showStatusMenu", default: true) } set { defaults.set(newValue, forKey: "showStatusMenu") } }
    var keepMenuOpenAfterRefresh: Bool { get { bool("keepMenuOpenAfterRefresh", default: true) } set { defaults.set(newValue, forKey: "keepMenuOpenAfterRefresh") } }
    var updateChannel: UpdateChannel {
        get {
            guard let rawValue = defaults.string(forKey: Self.updateChannelKey),
                  let channel = UpdateChannel(rawValue: rawValue) else {
                return Self.defaultUpdateChannel
            }
            return channel
        }
        set { defaults.set(newValue.rawValue, forKey: Self.updateChannelKey) }
    }
    var balanceDisplayThreshold: Double {
        get {
            Self.normalizedBalanceDisplayThreshold(
                (defaults.object(forKey: Self.balanceDisplayThresholdKey) as? NSNumber)?.doubleValue
                    ?? Self.defaultBalanceDisplayThreshold
            )
        }
        set {
            defaults.set(
                Self.normalizedBalanceDisplayThreshold(newValue),
                forKey: Self.balanceDisplayThresholdKey
            )
        }
    }
    var sortProvidersAlphabetically: Bool { get { defaults.bool(forKey: "sortProvidersAlphabetically") } set { defaults.set(newValue, forKey: "sortProvidersAlphabetically") } }
    var menuBarHorizontalPadding: CGFloat { get { CGFloat(positiveDouble("menuBarHorizontalPadding", default: 10)) } set { defaults.set(Double(newValue), forKey: "menuBarHorizontalPadding") } }

    /// Fine-tune offsets are stored in points with 0.1pt resolution and are
    /// clamped to the safe range on both read and write.
    static let menuBarOffsetRange = -10.0...10.0
    static let menuBarOffsetStep: Double = 0.1
    static let menuBarIconOffsetXKey = "menuBarIconOffsetX"
    static let menuBarIconOffsetYKey = "menuBarIconOffsetY"
    static let menuBarAmountOffsetXKey = "menuBarAmountOffsetX"
    static let menuBarAmountOffsetYKey = "menuBarAmountOffsetY"
    static let menuBarStatusItemWidthAdjustmentKey = "menuBarStatusItemWidthAdjustment"
    /// The persisted menu-bar font-size preset. The numeric key below remains
    /// as a migration source for versions that exposed a continuous slider.
    static let menuBarFontSizePresetKey = "menuBarFontSizePreset"
    static let menuBarFontSizePresetDefault: MenuBarFontSizePreset = .large
    static let menuBarFontSizeKey = "menuBarFontSize"
    /// Legacy keys kept in the migration whitelist. They are read only as a
    /// fallback for installations that used the short-lived independent-row
    /// controls and are removed when the shared preference is written.
    static let menuBarPrimaryFontSizeKey = "menuBarPrimaryFontSize"
    static let menuBarSecondaryFontSizeKey = "menuBarSecondaryFontSize"
    /// These numeric bounds and step are retained only for legacy numeric
    /// preference migration and compatibility helpers. The current UI exposes
    /// the three presets above instead of a continuous slider.
    static let menuBarFontSizeRange = 10.4...16.0
    static let menuBarFontSizeStep: Double = 0.1
    static let menuBarFontSizeDefault: Double = menuBarFontSizePresetDefault.primarySize
    static let menuBarSecondaryToPrimaryFontRatio: Double = 10.0 / 13.0
    /// The width slider is centered on the system-default footprint: negative
    /// values narrow the item and positive values widen it.
    static let menuBarStatusItemWidthAdjustmentRange = -10.0...10.0
    static let menuBarStatusItemWidthAdjustmentStep: Double = menuBarOffsetStep
    static let menuBarStatusItemWidthAdjustmentDefault: Double = 0.0
    /// Retained as the physical mapping hook used by the renderer and preview.
    /// The centered user-facing range maps directly to the status-item width.
    static let menuBarStatusItemWidthBaseline: Double = 0.0

    /// Point offsets for the menu bar Agent icon. Positive X moves right,
    /// positive Y moves up. Values are clamped to `menuBarOffsetRange`.
    var menuBarIconOffsetX: Double {
        get { clampedMenuBarOffset(Self.menuBarIconOffsetXKey) }
        set { defaults.set(roundedMenuBarOffset(newValue), forKey: Self.menuBarIconOffsetXKey) }
    }
    var menuBarIconOffsetY: Double {
        get { clampedMenuBarOffset(Self.menuBarIconOffsetYKey) }
        set { defaults.set(roundedMenuBarOffset(newValue), forKey: Self.menuBarIconOffsetYKey) }
    }

    /// Point offsets for the menu bar amount text block (symbol + digits).
    /// Positive X moves right, positive Y moves up.
    var menuBarAmountOffsetX: Double {
        get { clampedMenuBarOffset(Self.menuBarAmountOffsetXKey) }
        set { defaults.set(roundedMenuBarOffset(newValue), forKey: Self.menuBarAmountOffsetXKey) }
    }
    var menuBarAmountOffsetY: Double {
        get { clampedMenuBarOffset(Self.menuBarAmountOffsetYKey) }
        set { defaults.set(roundedMenuBarOffset(newValue), forKey: Self.menuBarAmountOffsetYKey) }
    }

    /// Additional points applied to the complete menu bar status item width.
    /// Positive values widen the status item; negative values narrow it
    /// without changing the icon/text spacing inside the item.
    var menuBarStatusItemWidthAdjustment: Double {
        get { clampedMenuBarStatusItemWidthAdjustment() }
        set {
            defaults.set(
                roundedMenuBarStatusItemWidthAdjustment(newValue),
                forKey: Self.menuBarStatusItemWidthAdjustmentKey
            )
        }
    }

    /// The selected menu-bar font-size preset drives both official rows and
    /// the single-line third-party balance path.
    var menuBarFontSizePreset: MenuBarFontSizePreset {
        get {
            if let rawValue = defaults.string(forKey: Self.menuBarFontSizePresetKey),
               let preset = MenuBarFontSizePreset(rawValue: rawValue) {
                return preset
            }
            if let stored = storedMenuBarFontSize(for: Self.menuBarFontSizeKey) {
                return MenuBarFontSizePreset.nearest(to: stored)
            }
            // An earlier build briefly exposed independent row controls. Use
            // its primary value as the migration source and restore the
            // nearest supported preset.
            if let legacy = storedMenuBarFontSize(for: Self.menuBarPrimaryFontSizeKey) {
                return MenuBarFontSizePreset.nearest(to: legacy)
            }
            return Self.menuBarFontSizePresetDefault
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.menuBarFontSizePresetKey)
            defaults.removeObject(forKey: Self.menuBarFontSizeKey)
            defaults.removeObject(forKey: Self.menuBarPrimaryFontSizeKey)
            defaults.removeObject(forKey: Self.menuBarSecondaryFontSizeKey)
        }
    }

    /// The selected primary-row size in logical AppKit points.
    var menuBarFontSize: Double {
        get { menuBarFontSizePreset.primarySize }
        set { menuBarFontSizePreset = MenuBarFontSizePreset.nearest(to: newValue) }
    }

    /// The actual primary row size used by the menu-bar renderer.
    var menuBarPrimaryFontSize: Double { menuBarFontSize }

    /// The actual secondary row size used by the official two-line renderer.
    /// It is derived, never independently persisted or adjustable.
    var menuBarSecondaryFontSize: Double {
        menuBarFontSizePreset.secondarySize
    }

    static func secondaryMenuBarFontSize(for primarySize: Double) -> Double {
        let normalizedPrimary = normalizedMenuBarFontSize(
            primarySize,
            range: menuBarFontSizeRange
        )
        return normalizedPrimary * menuBarSecondaryToPrimaryFontRatio
    }

    /// An optional local-only Dashboard port override. The value is deliberately
    /// kept separate from the OpenCodex configuration so it can only affect
    /// BalanceBar's Dashboard launch action.
    var openCodexDashboardPortOverride: Int? {
        get {
            guard let number = defaults.object(
                forKey: Self.openCodexDashboardPortOverrideKey
            ) as? NSNumber else { return nil }
            let value = number.intValue
            guard number.doubleValue == Double(value),
                  Self.validOpenCodexDashboardPortRange.contains(value) else {
                return nil
            }
            return value
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.openCodexDashboardPortOverrideKey)
                return
            }
            guard Self.validOpenCodexDashboardPortRange.contains(newValue) else { return }
            defaults.set(newValue, forKey: Self.openCodexDashboardPortOverrideKey)
        }
    }

    /// Whether BalanceBar should resolve the Dashboard port from the verified
    /// OpenCodex runtime. A pre-existing port override implies manual mode for
    /// preferences written before this explicit mode key was introduced.
    var openCodexDashboardAutomaticDetection: Bool {
        get {
            if let stored = defaults.object(
                forKey: Self.openCodexDashboardAutomaticDetectionKey
            ) as? Bool {
                return stored
            }
            return openCodexDashboardPortOverride == nil
        }
        set {
            defaults.set(newValue, forKey: Self.openCodexDashboardAutomaticDetectionKey)
        }
    }

    var statusLinks: [StatusLink] {
        get {
            guard let data = defaults.data(forKey: "statusLinks"), let links = try? JSONDecoder().decode([StatusLink].self, from: data) else { return defaultStatusLinksProvider() }
            let normalized = links.map { link -> StatusLink in
                var copy = link
                if copy.url == "https://" { copy.url = "" }
                return copy
            }
            if normalized != links, let data = try? JSONEncoder().encode(normalized) { defaults.set(data, forKey: "statusLinks") }
            return normalized
        }
        set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "statusLinks") } }
    }

    static func normalizedBalanceDisplayThreshold(_ value: Double) -> Double {
        guard value.isFinite,
              value >= minimumBalanceDisplayThreshold,
              value <= Double(Int.max) / 100 else {
            return defaultBalanceDisplayThreshold
        }
        let cents = value * 100
        guard cents.isFinite, cents >= 1, cents <= Double(Int.max) else {
            return defaultBalanceDisplayThreshold
        }
        return cents.rounded() / 100
    }

    static func balanceDisplayThresholdCents(defaults: UserDefaults) -> Int {
        let storedValue = (defaults.object(forKey: balanceDisplayThresholdKey) as? NSNumber)?.doubleValue
            ?? defaultBalanceDisplayThreshold
        let normalized = normalizedBalanceDisplayThreshold(storedValue)
        return Int((normalized * 100).rounded())
    }

    private func bool(_ key: String, default fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
    private func positiveDouble(_ key: String, default fallback: Double) -> Double { let value = defaults.double(forKey: key); return value > 0 ? value : fallback }
    private func clampMenuBarOffset(_ value: Double) -> Double {
        min(max(value, Self.menuBarOffsetRange.lowerBound), Self.menuBarOffsetRange.upperBound)
    }
    private func roundedMenuBarOffset(_ value: Double) -> Double {
        (clampMenuBarOffset(value) * 10).rounded() / 10
    }
    private func clampedMenuBarOffset(_ key: String) -> Double {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return 0 }
        return roundedMenuBarOffset(number.doubleValue)
    }

    private func roundedMenuBarStatusItemWidthAdjustment(_ value: Double) -> Double {
        Self.normalizedMenuBarStatusItemWidthAdjustment(value)
    }

    static func normalizedMenuBarStatusItemWidthAdjustment(_ value: Double) -> Double {
        let clamped = min(
            max(value, menuBarStatusItemWidthAdjustmentRange.lowerBound),
            menuBarStatusItemWidthAdjustmentRange.upperBound
        )
        let scale = 1 / menuBarStatusItemWidthAdjustmentStep
        return (clamped * scale).rounded() / scale
    }

    static func normalizedMenuBarFontSize(
        _ value: Double,
        range: ClosedRange<Double>
    ) -> Double {
        let finiteValue = value.isFinite ? value : range.lowerBound
        let clamped = min(max(finiteValue, range.lowerBound), range.upperBound)
        let scale = 1 / menuBarFontSizeStep
        return (clamped * scale).rounded() / scale
    }

    private func clampedMenuBarStatusItemWidthAdjustment() -> Double {
        guard let number = defaults.object(
            forKey: Self.menuBarStatusItemWidthAdjustmentKey
        ) as? NSNumber else { return Self.menuBarStatusItemWidthAdjustmentDefault }
        return roundedMenuBarStatusItemWidthAdjustment(number.doubleValue)
    }

    private func storedMenuBarFontSize(for key: String) -> Double? {
        guard let number = defaults.object(forKey: key) as? NSNumber else {
            return nil
        }
        return Self.normalizedMenuBarFontSize(number.doubleValue, range: Self.menuBarFontSizeRange)
    }
}

/// Holds the in-progress value of the width slider without treating every
/// mouse-tracking event as a persisted preference change.
struct MenuBarStatusItemWidthAdjustmentSession {
    private(set) var transientValue: Double?

    mutating func update(_ value: Double) -> Double {
        let normalized = AppPreferences.normalizedMenuBarStatusItemWidthAdjustment(value)
        transientValue = normalized
        return normalized
    }

    mutating func finish(_ value: Double, persist: (Double) -> Void) -> Double {
        let normalized = AppPreferences.normalizedMenuBarStatusItemWidthAdjustment(value)
        transientValue = nil
        persist(normalized)
        return normalized
    }

    mutating func cancel() {
        transientValue = nil
    }
}

enum AppPreferencesMigration {
    static let marker = "didMigrateToBalanceBarApp.v1"

    static func migrate(defaults: UserDefaults, bundleIdentifier: String, productionDomain: [String: Any], localDomain: [String: Any]) {
        let current = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        guard current[marker] == nil else { return }
        for (key, value) in PreferencesMigrationPlan.selectedValues(target: current, production: productionDomain, local: localDomain) {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: marker)
    }
}
