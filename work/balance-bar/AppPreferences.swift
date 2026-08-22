import Foundation

final class AppPreferences {
    static let showOpenCodexMenuKey = "showOpenCodexMenu"
    static let openCodexDashboardPortOverrideKey = "openCodexDashboardPortOverride"
    static let openCodexDashboardAutomaticDetectionKey = "openCodexDashboardAutomaticDetection"
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
    static let menuBarStatusItemWidthAdjustmentDefault: Double = -10.0

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
    /// Positive values widen the status item symmetrically; negative values
    /// narrow it without changing the icon/text spacing inside the item.
    var menuBarStatusItemWidthAdjustment: Double {
        get {
            clampedMenuBarOffset(
                Self.menuBarStatusItemWidthAdjustmentKey,
                default: Self.menuBarStatusItemWidthAdjustmentDefault
            )
        }
        set {
            defaults.set(
                roundedMenuBarOffset(newValue),
                forKey: Self.menuBarStatusItemWidthAdjustmentKey
            )
        }
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

    private func bool(_ key: String, default fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
    private func positiveDouble(_ key: String, default fallback: Double) -> Double { let value = defaults.double(forKey: key); return value > 0 ? value : fallback }
    private func clampMenuBarOffset(_ value: Double) -> Double {
        min(max(value, Self.menuBarOffsetRange.lowerBound), Self.menuBarOffsetRange.upperBound)
    }
    private func roundedMenuBarOffset(_ value: Double) -> Double {
        (clampMenuBarOffset(value) * 10).rounded() / 10
    }
    private func clampedMenuBarOffset(_ key: String, default fallback: Double = 0) -> Double {
        guard let number = defaults.object(forKey: key) as? NSNumber else {
            return roundedMenuBarOffset(fallback)
        }
        return roundedMenuBarOffset(number.doubleValue)
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
