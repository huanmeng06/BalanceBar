import Foundation

enum LocalOfficialProvider {
    static let configurationRevision = "local-official-v1"

    static func id(for client: AssistantClient) -> String {
        "balancebar.local-official.\(client.rawValue)"
    }

    static func isLocalOfficialID(_ id: String) -> Bool {
        id == Self.id(for: .claude) || id == Self.id(for: .codex)
    }

    static func make(for client: AssistantClient) -> CCSwitchProvider {
        CCSwitchProvider(id: id(for: client),
                         name: tr(.keyOfficialModeProviderName, arguments: [client == .claude ? "Claude" : "Codex"]),
                         isOfficial: true, query: nil, queryFailure: nil,
                         configurationRevision: configurationRevision)
    }
}

enum CurrentProviderResolution: Equatable {
    case ccSwitch(CCSwitchProvider)
    case localOfficial(CCSwitchProvider)
    case localThirdParty
    case noCurrentProvider
    case databaseAbsent

    var provider: CCSwitchProvider? {
        switch self {
        case .ccSwitch(let provider), .localOfficial(let provider): return provider
        default: return nil
        }
    }

    var source: String {
        switch self {
        case .ccSwitch: return "cc_switch"
        case .localOfficial: return "local_official"
        case .localThirdParty: return "local_third_party"
        case .noCurrentProvider: return "no_current_provider"
        case .databaseAbsent: return "database_absent"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.provider?.id == rhs.provider?.id
    }
}

final class CurrentProviderResolver {
    private let repository: CCSwitchRepository
    private let routeInspector: LocalAgentRouteInspector
    private let databaseExists: () -> Bool

    init(repository: CCSwitchRepository, routeInspector: LocalAgentRouteInspector? = nil,
         databaseExists: (() -> Bool)? = nil) {
        self.repository = repository
        self.routeInspector = routeInspector ?? LocalAgentRouteInspector(homeDirectoryURL: repository.homeDirectoryURL)
        self.databaseExists = databaseExists ?? {
            if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true {
                switch ProcessInfo.processInfo.environment["BALANCEBAR_SIM_CCSWITCH"] {
                case "absent": return false
                case "missing", "broken", "busy", "nocurrent": return true
                default: break
                }
            }
            var entry = stat()
            // Only ENOENT proves absence. Inaccessible parents and invalid
            // paths must go through the repository's normal read-error path.
            return lstat(repository.databaseURL.path, &entry) == 0 || errno != ENOENT
        }
    }

    var isDatabasePresent: Bool { databaseExists() }

    func resolveChecked(_ client: AssistantClient) throws -> CurrentProviderResolution {
        let present = isDatabasePresent
        if present, let provider = try repository.loadCurrentChecked(appType: client.appType) {
            return .ccSwitch(provider)
        }
        guard client != .grok else { return present ? .noCurrentProvider : .databaseAbsent }
        if routeInspector.route(for: client) == .thirdParty {
            return present ? .noCurrentProvider : .localThirdParty
        }
        return .localOfficial(LocalOfficialProvider.make(for: client))
    }

    func resolve(_ client: AssistantClient) -> CurrentProviderResolution? {
        try? resolveChecked(client)
    }

    func currentProvider(_ client: AssistantClient) -> CCSwitchProvider? {
        resolve(client)?.provider
    }

    func configurationRevision(_ client: AssistantClient, providerID: String) -> String? {
        if LocalOfficialProvider.isLocalOfficialID(providerID) {
            guard case .localOfficial(let provider) = resolve(client), provider.id == providerID else { return nil }
            return provider.configurationRevision
        }
        return repository.configurationRevision(appType: client.appType, providerID: providerID)
    }
}
