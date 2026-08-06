import Foundation

struct StatusLink: Codable, Equatable {
    var title: String
    var url: String
}

final class AppPreferences {
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
            StatusLink(title: tr("Tibo 的动态", "Tibo's Updates"), url: "https://x.com/thsottiaux")
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
    var showOpenChatGPTMenu: Bool { get { bool("showOpenChatGPTMenu", default: true) } set { defaults.set(newValue, forKey: "showOpenChatGPTMenu") } }
    var showStatusMenu: Bool { get { bool("showStatusMenu", default: true) } set { defaults.set(newValue, forKey: "showStatusMenu") } }
    var keepMenuOpenAfterRefresh: Bool { get { bool("keepMenuOpenAfterRefresh", default: true) } set { defaults.set(newValue, forKey: "keepMenuOpenAfterRefresh") } }
    var sortProvidersAlphabetically: Bool { get { defaults.bool(forKey: "sortProvidersAlphabetically") } set { defaults.set(newValue, forKey: "sortProvidersAlphabetically") } }
    var menuBarHorizontalPadding: CGFloat { get { CGFloat(positiveDouble("menuBarHorizontalPadding", default: 10)) } set { defaults.set(Double(newValue), forKey: "menuBarHorizontalPadding") } }

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
