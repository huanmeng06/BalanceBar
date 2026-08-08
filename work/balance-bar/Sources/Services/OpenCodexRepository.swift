import Foundation
import Darwin

struct OpenCodexEndpointCandidate: Hashable {
    let baseURL: URL
    let modelProvider: String
    let wireAPI: String

    var managementURL: URL {
        baseURL.deletingLastPathComponent()
    }

    var port: Int {
        baseURL.port ?? (baseURL.scheme?.lowercased() == "https" ? 443 : 80)
    }

    static func parse(settingsConfig: String) -> OpenCodexEndpointCandidate? {
        // CC Switch stores Codex providers as a JSON wrapper whose `config`
        // value contains the actual config.toml text. Keep accepting the
        // direct TOML form used by callers and fixtures, but unwrap this
        // storage format before looking for structured OpenCodex signals.
        let tomlConfig = embeddedConfig(from: settingsConfig) ?? settingsConfig
        var topLevel: [String: String] = [:]
        var providerSections: [String: [String: String]] = [:]
        var currentSection: String?

        for rawLine in tomlConfig.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }

            if let section = quotedSectionName(in: line) {
                currentSection = section
                if section.hasPrefix("model_providers.") {
                    providerSections[String(section.dropFirst("model_providers.".count))] = [:]
                }
                continue
            }

            guard let (key, value) = quotedAssignment(in: line) else { continue }
            if let currentSection,
               currentSection.hasPrefix("model_providers.") {
                let providerName = String(currentSection.dropFirst("model_providers.".count))
                providerSections[providerName, default: [:]][key] = value
            } else {
                topLevel[key] = value
            }
        }

        guard let modelProvider = topLevel["model_provider"],
              let provider = providerSections[modelProvider],
              provider["wire_api"]?.lowercased() == "responses",
              let rawBaseURL = provider["base_url"],
              let url = URL(string: rawBaseURL),
              isSafeLoopbackV1Endpoint(url) else {
            return nil
        }

        return OpenCodexEndpointCandidate(
            baseURL: normalizedV1URL(url),
            modelProvider: modelProvider,
            wireAPI: "responses"
        )
    }

    private static func embeddedConfig(from settingsConfig: String) -> String? {
        guard let data = settingsConfig.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = object["config"] as? String,
              !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return config
    }

    private static func quotedSectionName(in line: String) -> String? {
        guard line.first == "[", line.last == "]" else { return nil }
        let value = line.dropFirst().dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }

    private static func quotedAssignment(in line: String) -> (String, String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = line[line.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              rawValue.count >= 2,
              rawValue.first == "\"",
              rawValue.last == "\"" else { return nil }
        return (
            String(key),
            String(rawValue.dropFirst().dropLast())
        )
    }

    private static func isSafeLoopbackV1Endpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              isLoopbackHost(host),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        return normalizedV1Path(url.path) == "/v1"
    }

    private static func normalizedV1URL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.path = "/v1"
        return components.url ?? url
    }

    private static func normalizedV1Path(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/\(trimmed)"
    }

    fileprivate static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || (host.hasPrefix("127.") && host.split(separator: ".").count == 4)
    }
}

struct OpenCodexPreference: Equatable {
    let selector: String
    let provider: String
    let model: String
    let isCurrent: Bool
}

struct OpenCodexRuntimeState: Equatable {
    let candidate: OpenCodexEndpointCandidate
    let defaultProvider: String
    let providerDefaultModels: [String: String]
    let chosenSelectors: [String]
    let availableSelectors: [String]
    let preferences: [OpenCodexPreference]
    let managementAvailable: Bool
    let preferenceDataAvailable: Bool

    var currentSelector: String? {
        preferences.first(where: \OpenCodexPreference.isCurrent)?.selector
            ?? Self.canonicalSelector(
                provider: defaultProvider,
                model: providerDefaultModels[defaultProvider]
            )
            ?? chosenSelectors.first { selector in
                let parts = selector.split(separator: "/", maxSplits: 1)
                let provider = parts.count == 1 ? "openai" : String(parts[0])
                return provider == defaultProvider
            }.flatMap { selector in
                let parts = selector.split(separator: "/", maxSplits: 1)
                let provider = parts.count == 1 ? "openai" : String(parts[0])
                let model = parts.count == 1 ? String(parts[0]) : String(parts[1])
                return Self.canonicalSelector(provider: provider, model: model)
            }
    }

    var representativeSelector: String? {
        currentSelector ?? preferences.first?.selector
    }

    fileprivate static func canonicalSelector(provider: String, model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        return provider == "openai" ? model : "\(provider)/\(model)"
    }
}

enum OpenCodexReadResult {
    case notRecognized
    case unavailable
    case recognized(OpenCodexRuntimeState)
}

enum OpenCodexRepositoryError: Error, Equatable {
    case managementUnavailable
    case invalidResponse
    case switchFailed
    case verificationFailed
    case rollbackFailed

    var simplifiedChineseMessage: String {
        switch self {
        case .managementUnavailable: return "OpenCodex 管理接口不可用"
        case .invalidResponse: return "OpenCodex 返回的数据无效"
        case .switchFailed: return "OpenCodex 切换未完成"
        case .verificationFailed: return "OpenCodex 切换后校验失败"
        case .rollbackFailed: return "OpenCodex 回滚校验失败，实际状态可能已部分改变"
        }
    }

    var englishMessage: String {
        switch self {
        case .managementUnavailable: return "OpenCodex management API is unavailable"
        case .invalidResponse: return "OpenCodex returned invalid data"
        case .switchFailed: return "OpenCodex switch did not complete"
        case .verificationFailed: return "OpenCodex switch verification failed"
        case .rollbackFailed: return "OpenCodex rollback verification failed; the actual state may be partially changed"
        }
    }
}

struct OpenCodexHTTPResponse {
    let statusCode: Int
    let data: Data
}

protocol OpenCodexHTTPTransport {
    func send(
        _ request: URLRequest,
        completion: @escaping (Result<OpenCodexHTTPResponse, Error>) -> Void
    )
}

final class URLSessionOpenCodexHTTPTransport: OpenCodexHTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        session = URLSession(
            configuration: configuration,
            delegate: NoRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    func send(
        _ request: URLRequest,
        completion: @escaping (Result<OpenCodexHTTPResponse, Error>) -> Void
    ) {
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse,
                  let data else {
                completion(.failure(OpenCodexRepositoryError.invalidResponse))
                return
            }
            completion(.success(OpenCodexHTTPResponse(
                statusCode: response.statusCode,
                data: data
            )))
        }.resume()
    }
}

private final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

protocol OpenCodexAdminTokenProvider {
    func token(for candidate: OpenCodexEndpointCandidate) -> String?
}

final class FileOpenCodexAdminTokenProvider: OpenCodexAdminTokenProvider {
    private let configDirectoryURL: URL
    private let fileManager: FileManager
    private let environment: [String: String]

    init(
        configDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
        if let configDirectoryURL {
            self.configDirectoryURL = configDirectoryURL
        } else if let raw = environment["OPENCODEX_HOME"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = raw.hasPrefix("~/")
                ? (NSHomeDirectory() as NSString).appendingPathComponent(String(raw.dropFirst(2)))
                : raw
            self.configDirectoryURL = URL(fileURLWithPath: expanded)
        } else {
            self.configDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".opencodex", isDirectory: true)
        }
    }

    func token(for candidate: OpenCodexEndpointCandidate) -> String? {
        if let environmentToken = environment["OPENCODEX_ADMIN_AUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentToken.isEmpty {
            return environmentToken
        }

        let tokenURL = configDirectoryURL.appendingPathComponent("admin-api-token")
        guard (try? fileManager.destinationOfSymbolicLink(atPath: tokenURL.path)) == nil,
              let attributes = try? fileManager.attributesOfItem(atPath: tokenURL.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= 512,
              let data = try? Data(contentsOf: tokenURL),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }
}

struct OpenCodexLocalConfigSnapshot {
    let port: Int
    let defaultProvider: String
    let providerDefaultModels: [String: String]
    let chosenSelectors: [String]
}

protocol OpenCodexConfigReader {
    func read(matching candidate: OpenCodexEndpointCandidate) -> OpenCodexLocalConfigSnapshot?
}

final class FileOpenCodexConfigReader: OpenCodexConfigReader {
    private let configDirectoryURL: URL

    init(
        configDirectoryURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let configDirectoryURL {
            self.configDirectoryURL = configDirectoryURL
        } else if let raw = environment["OPENCODEX_HOME"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = raw.hasPrefix("~/")
                ? (NSHomeDirectory() as NSString).appendingPathComponent(String(raw.dropFirst(2)))
                : raw
            self.configDirectoryURL = URL(fileURLWithPath: expanded)
        } else {
            self.configDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".opencodex", isDirectory: true)
        }
    }

    func read(matching candidate: OpenCodexEndpointCandidate) -> OpenCodexLocalConfigSnapshot? {
        let configURL = configDirectoryURL.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isOpenCodexConfig(object),
              let port = integer(object["port"]),
              port == candidate.port,
              let defaultProvider = object["defaultProvider"] as? String,
              let providers = object["providers"] as? [String: Any],
              providerIsConfigured(defaultProvider, in: providers) else {
            return nil
        }

        let providerDefaultModels = providers.reduce(into: [String: String]()) { result, entry in
            guard let provider = entry.value as? [String: Any],
                  let model = provider["defaultModel"] as? String,
                  !model.isEmpty else { return }
            result[entry.key] = model
        }
        let chosenSelectors = (object["subagentModels"] as? [Any] ?? [])
            .compactMap { $0 as? String }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return OpenCodexLocalConfigSnapshot(
            port: port,
            defaultProvider: defaultProvider,
            providerDefaultModels: providerDefaultModels,
            chosenSelectors: chosenSelectors
        )
    }

    private func providerIsConfigured(_ name: String, in providers: [String: Any]) -> Bool {
        guard let provider = providers[name] as? [String: Any],
              provider["adapter"] is String,
              provider["baseUrl"] is String else { return false }
        return true
    }

    private func isOpenCodexConfig(_ object: [String: Any]) -> Bool {
        object["codexAutoStart"] is Bool
            && object["websockets"] is Bool
            && object["subagentModels"] is [Any]
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

final class OpenCodexRepository {
    private static let maxPreferences = 5
    private let transport: OpenCodexHTTPTransport
    private let configReader: OpenCodexConfigReader
    private let tokenProvider: OpenCodexAdminTokenProvider

    init(
        transport: OpenCodexHTTPTransport = URLSessionOpenCodexHTTPTransport(),
        configReader: OpenCodexConfigReader = FileOpenCodexConfigReader(),
        tokenProvider: OpenCodexAdminTokenProvider = FileOpenCodexAdminTokenProvider()
    ) {
        self.transport = transport
        self.configReader = configReader
        self.tokenProvider = tokenProvider
    }

    func readState(
        for candidate: OpenCodexEndpointCandidate,
        completion: @escaping (OpenCodexReadResult) -> Void
    ) {
        guard Self.isValidCandidate(candidate) else {
            completion(.notRecognized)
            return
        }

        let localSnapshot = configReader.read(matching: candidate)
        requestObject(candidate: candidate, path: "/healthz", authenticated: false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let health):
                guard self.isVerifiedHealth(health, candidate: candidate) else {
                    completion(.notRecognized)
                    return
                }
                self.readManagementState(
                    for: candidate,
                    localSnapshot: localSnapshot,
                    completion: completion
                )
            case .failure:
                if let localSnapshot {
                    completion(.recognized(self.makeState(
                        candidate: candidate,
                        defaultProvider: localSnapshot.defaultProvider,
                        providerDefaultModels: localSnapshot.providerDefaultModels,
                        chosenSelectors: localSnapshot.chosenSelectors,
                        availableSelectors: [],
                        managementAvailable: false,
                        preferenceDataAvailable: true
                    )))
                } else {
                    completion(.unavailable)
                }
            }
        }
    }

    private func readManagementState(
        for candidate: OpenCodexEndpointCandidate,
        localSnapshot: OpenCodexLocalConfigSnapshot?,
        completion: @escaping (OpenCodexReadResult) -> Void
    ) {
        let group = DispatchGroup()
        let resultLock = NSLock()
        var configObject: [String: Any]?
        var subagentObject: [String: Any]?

        group.enter()
        requestObject(candidate: candidate, path: "/api/config", authenticated: true) { result in
            if case .success(let object) = result {
                resultLock.lock()
                configObject = object
                resultLock.unlock()
            }
            group.leave()
        }
        group.enter()
        requestObject(candidate: candidate, path: "/api/subagent-models", authenticated: true) { result in
            if case .success(let object) = result {
                resultLock.lock()
                subagentObject = object
                resultLock.unlock()
            }
            group.leave()
        }

        group.notify(queue: DispatchQueue.global(qos: .utility)) { [weak self] in
            guard let self else { return }
            resultLock.lock()
            let resolvedConfig = configObject
            let resolvedSubagent = subagentObject
            resultLock.unlock()
            if let config = self.parseConfig(resolvedConfig, candidate: candidate),
               let subagent = self.parseSubagent(resolvedSubagent) {
                let chosen = subagent.chosen
                let available = subagent.available
                completion(.recognized(self.makeState(
                    candidate: candidate,
                    defaultProvider: config.defaultProvider,
                    providerDefaultModels: config.providerDefaultModels,
                    chosenSelectors: chosen,
                    availableSelectors: available,
                    managementAvailable: true,
                    preferenceDataAvailable: true
                )))
                return
            }

            if let config = self.parseConfig(resolvedConfig, candidate: candidate) {
                completion(.recognized(self.makeState(
                    candidate: candidate,
                    defaultProvider: config.defaultProvider,
                    providerDefaultModels: config.providerDefaultModels,
                    chosenSelectors: localSnapshot?.chosenSelectors ?? [],
                    availableSelectors: [],
                    managementAvailable: false,
                    preferenceDataAvailable: localSnapshot != nil
                )))
                return
            }

            guard let localSnapshot else {
                completion(.recognized(self.makeState(
                    candidate: candidate,
                    defaultProvider: candidate.modelProvider,
                    providerDefaultModels: [:],
                    chosenSelectors: [],
                    availableSelectors: [],
                    managementAvailable: false,
                    preferenceDataAvailable: false
                )))
                return
            }
            completion(.recognized(self.makeState(
                candidate: candidate,
                defaultProvider: localSnapshot.defaultProvider,
                providerDefaultModels: localSnapshot.providerDefaultModels,
                chosenSelectors: localSnapshot.chosenSelectors,
                availableSelectors: [],
                managementAvailable: false,
                preferenceDataAvailable: true
            )))
        }
    }

    func select(
        _ preference: OpenCodexPreference,
        from state: OpenCodexRuntimeState,
        completion: @escaping (Result<OpenCodexRuntimeState, OpenCodexRepositoryError>) -> Void
    ) {
        guard state.managementAvailable,
              state.preferences.contains(where: { canonical($0.selector) == canonical(preference.selector) }) else {
            completion(.failure(.managementUnavailable))
            return
        }

        guard let targetSelector = canonical(preference.selector) else {
            completion(.failure(.invalidResponse))
            return
        }
        let targetProvider = preference.provider
        let targetModel = preference.model
        let oldDefaultProvider = state.defaultProvider
        let oldTargetModel = state.providerDefaultModels[targetProvider]
        // The UI is limited to the first five preferences, but selecting one
        // of those preferences must reorder the complete OpenCodex list. Do
        // not write the display limit back to the service: the tail is user
        // configuration and must remain intact.
        var desiredChosen = state.chosenSelectors
        if let currentIndex = desiredChosen.firstIndex(where: {
            canonical($0) == targetSelector
        }) {
            let selected = desiredChosen.remove(at: currentIndex)
            desiredChosen.insert(selected, at: 0)
        }

        var defaultProviderChanged = false
        var targetModelChanged = false
        var chosenSelectorsChanged = false

        func finishFailure(_ error: OpenCodexRepositoryError) {
            let changed = defaultProviderChanged || targetModelChanged || chosenSelectorsChanged
            guard changed else {
                completion(.failure(error))
                return
            }
            self.rollback(
                candidate: state.candidate,
                oldDefaultProvider: oldDefaultProvider,
                oldTargetProvider: targetProvider,
                oldTargetModel: oldTargetModel,
                oldChosenSelectors: state.chosenSelectors,
                restoreDefaultProvider: defaultProviderChanged,
                restoreTargetModel: targetModelChanged,
                restoreChosenSelectors: chosenSelectorsChanged
            ) { rollbackSucceeded in
                guard rollbackSucceeded else {
                    completion(.failure(.rollbackFailed))
                    return
                }
                self.readState(for: state.candidate) { result in
                    guard case .recognized(let restored) = result,
                          self.matchesRollbackState(
                            restored,
                            defaultProvider: oldDefaultProvider,
                            targetProvider: targetProvider,
                            targetModel: oldTargetModel,
                            chosenSelectors: state.chosenSelectors
                          ) else {
                        completion(.failure(.rollbackFailed))
                        return
                    }
                    completion(.failure(error))
                }
            }
        }

        func verify() {
            self.readState(for: state.candidate) { result in
                guard case .recognized(let verified) = result,
                      verified.managementAvailable,
                      verified.defaultProvider == targetProvider,
                      OpenCodexRuntimeState.canonicalSelector(
                        provider: targetProvider,
                        model: verified.providerDefaultModels[targetProvider]
                      ) == targetSelector else {
                    finishFailure(.verificationFailed)
                    return
                }
                if verified.chosenSelectors.first.flatMap({ self.canonical($0) }) != targetSelector {
                    finishFailure(.verificationFailed)
                    return
                }
                completion(.success(verified))
            }
        }

        func updateChosenSelectors() {
            guard desiredChosen != state.chosenSelectors else {
                verify()
                return
            }
            self.sendWrite(
                candidate: state.candidate,
                path: "/api/subagent-models",
                method: "PUT",
                body: ["models": desiredChosen]
            ) { result in
                guard case .success = result else {
                    finishFailure(.switchFailed)
                    return
                }
                chosenSelectorsChanged = true
                verify()
            }
        }

        func updateDefaultProvider() {
            guard oldDefaultProvider != targetProvider else {
                updateChosenSelectors()
                return
            }
            self.sendWrite(
                candidate: state.candidate,
                path: "/api/providers?name=\(Self.percentEncode(targetProvider))",
                method: "PATCH",
                body: ["setDefault": true]
            ) { result in
                guard case .success = result else {
                    finishFailure(.switchFailed)
                    return
                }
                defaultProviderChanged = true
                updateChosenSelectors()
            }
        }

        func updateTargetModel() {
            guard oldTargetModel != targetModel else {
                updateDefaultProvider()
                return
            }
            self.sendWrite(
                candidate: state.candidate,
                path: "/api/providers?name=\(Self.percentEncode(targetProvider))",
                method: "PATCH",
                body: ["defaultModel": targetModel]
            ) { result in
                guard case .success = result else {
                    finishFailure(.switchFailed)
                    return
                }
                targetModelChanged = true
                updateDefaultProvider()
            }
        }

        updateTargetModel()
    }

    private func rollback(
        candidate: OpenCodexEndpointCandidate,
        oldDefaultProvider: String,
        oldTargetProvider: String,
        oldTargetModel: String?,
        oldChosenSelectors: [String],
        restoreDefaultProvider: Bool,
        restoreTargetModel: Bool,
        restoreChosenSelectors: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        typealias RollbackOperation = (@escaping (Bool) -> Void) -> Void
        var operations: [RollbackOperation] = []
        if restoreChosenSelectors {
            operations.append { next in
                self.sendWrite(
                    candidate: candidate,
                    path: "/api/subagent-models",
                    method: "PUT",
                    body: ["models": oldChosenSelectors]
                ) { result in
                    next(self.writeSucceeded(result))
                }
            }
        }
        if restoreTargetModel {
            operations.append { next in
                self.sendWrite(
                    candidate: candidate,
                    path: "/api/providers?name=\(Self.percentEncode(oldTargetProvider))",
                    method: "PATCH",
                    body: ["defaultModel": oldTargetModel ?? ""]
                ) { result in
                    next(self.writeSucceeded(result))
                }
            }
        }
        if restoreDefaultProvider {
            operations.append { next in
                self.sendWrite(
                    candidate: candidate,
                    path: "/api/providers?name=\(Self.percentEncode(oldDefaultProvider))",
                    method: "PATCH",
                    body: ["setDefault": true]
                ) { result in
                    next(self.writeSucceeded(result))
                }
            }
        }
        runBestEffort(operations, index: 0, succeeded: true, completion: completion)
    }

    private func runBestEffort(
        _ operations: [(@escaping (Bool) -> Void) -> Void],
        index: Int,
        succeeded: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard index < operations.count else {
            completion(succeeded)
            return
        }
        operations[index]({ [weak self] operationSucceeded in
            guard let self else {
                completion(false)
                return
            }
            self.runBestEffort(
                operations,
                index: index + 1,
                succeeded: succeeded && operationSucceeded,
                completion: completion
            )
        })
    }

    private func matchesRollbackState(
        _ state: OpenCodexRuntimeState,
        defaultProvider: String,
        targetProvider: String,
        targetModel: String?,
        chosenSelectors: [String]
    ) -> Bool {
        guard state.managementAvailable,
              state.defaultProvider == defaultProvider,
              state.providerDefaultModels[targetProvider] == targetModel else {
            return false
        }
        return canonicalSelectors(state.chosenSelectors) == canonicalSelectors(chosenSelectors)
    }

    private func canonicalSelectors(_ selectors: [String]) -> [String] {
        selectors.compactMap(canonical)
    }

    private func writeSucceeded(
        _ result: Result<Void, OpenCodexRepositoryError>
    ) -> Bool {
        if case .success = result { return true }
        return false
    }

    private func makeState(
        candidate: OpenCodexEndpointCandidate,
        defaultProvider: String,
        providerDefaultModels: [String: String],
        chosenSelectors: [String],
        availableSelectors: [String],
        managementAvailable: Bool,
        preferenceDataAvailable: Bool
    ) -> OpenCodexRuntimeState {
        let available = normalizedSelectors(availableSelectors)
        let chosen = normalizedSelectors(chosenSelectors)
        let displayChosen: [String]
        if managementAvailable {
            let availableSet = Set(available.compactMap(canonical))
            displayChosen = chosen.filter { availableSet.contains(canonical($0) ?? "") }
        } else {
            displayChosen = chosen
        }
        let current = currentSelector(
            defaultProvider: defaultProvider,
            providerDefaultModels: providerDefaultModels,
            chosenSelectors: chosen
        )
        let preferences = Array(displayChosen.prefix(Self.maxPreferences)).compactMap { selector -> OpenCodexPreference? in
            guard let parsed = parseSelector(selector) else { return nil }
            return OpenCodexPreference(
                selector: selector,
                provider: parsed.provider,
                model: parsed.model,
                isCurrent: canonical(selector) == current
            )
        }
        return OpenCodexRuntimeState(
            candidate: candidate,
            defaultProvider: defaultProvider,
            providerDefaultModels: providerDefaultModels,
            chosenSelectors: chosen,
            availableSelectors: available,
            preferences: preferences,
            managementAvailable: managementAvailable,
            preferenceDataAvailable: preferenceDataAvailable
        )
    }

    private func currentSelector(
        defaultProvider: String,
        providerDefaultModels: [String: String],
        chosenSelectors: [String]
    ) -> String? {
        if let selector = OpenCodexRuntimeState.canonicalSelector(
            provider: defaultProvider,
            model: providerDefaultModels[defaultProvider]
        ) {
            return selector
        }
        return chosenSelectors.first { parseSelector($0)?.provider == defaultProvider }
            .flatMap { self.canonical($0) }
    }

    private func parseConfig(
        _ object: [String: Any]?,
        candidate: OpenCodexEndpointCandidate
    ) -> (defaultProvider: String, providerDefaultModels: [String: String])? {
        guard let object,
              object["codexAutoStart"] is Bool,
              object["websockets"] is Bool,
              integer(object["port"]) == candidate.port,
              let defaultProvider = object["defaultProvider"] as? String,
              let providers = object["providers"] as? [String: Any],
              providerIsConfigured(defaultProvider, in: providers) else {
            return nil
        }
        let providerDefaultModels = providers.reduce(into: [String: String]()) { result, entry in
            guard let provider = entry.value as? [String: Any],
                  let model = provider["defaultModel"] as? String,
                  !model.isEmpty else { return }
            result[entry.key] = model
        }
        return (defaultProvider, providerDefaultModels)
    }

    private func providerIsConfigured(_ name: String, in providers: [String: Any]) -> Bool {
        guard let provider = providers[name] as? [String: Any],
              provider["adapter"] is String,
              provider["baseUrl"] is String else { return false }
        return true
    }

    private func parseSelectors(_ value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return nil }
        return values.compactMap { $0 as? String }
    }

    private func parseSubagent(_ object: [String: Any]?) -> (chosen: [String], available: [String])? {
        guard let object,
              let chosen = parseSelectors(object["chosen"]),
              let available = parseSelectors(object["available"]) else { return nil }
        return (chosen, available)
    }

    private func normalizedSelectors(_ selectors: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for selector in selectors {
            let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let canonical = canonical(trimmed), seen.insert(canonical).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func parseSelector(_ selector: String) -> (provider: String, model: String)? {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let slash = trimmed.firstIndex(of: "/") else {
            return ("openai", trimmed)
        }
        let provider = String(trimmed[..<slash])
        let model = String(trimmed[trimmed.index(after: slash)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return (provider, model)
    }

    private func canonical(_ selector: String) -> String? {
        guard let parsed = parseSelector(selector) else { return nil }
        return OpenCodexRuntimeState.canonicalSelector(provider: parsed.provider, model: parsed.model)
    }

    private func isVerifiedHealth(
        _ object: [String: Any],
        candidate: OpenCodexEndpointCandidate
    ) -> Bool {
        guard let service = object["service"] as? String,
              service.lowercased() == "opencodex",
              let status = object["status"] as? String,
              status.lowercased() == "ok",
              integer(object["port"]) == candidate.port else {
            return false
        }
        return true
    }

    private func requestObject(
        candidate: OpenCodexEndpointCandidate,
        path: String,
        authenticated: Bool,
        completion: @escaping (Result<[String: Any], OpenCodexRepositoryError>) -> Void
    ) {
        send(
            candidate: candidate,
            path: path,
            method: "GET",
            body: nil,
            authenticated: authenticated
        ) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let response):
                guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                    completion(.failure(.invalidResponse))
                    return
                }
                completion(.success(object))
            }
        }
    }

    private func sendWrite(
        candidate: OpenCodexEndpointCandidate,
        path: String,
        method: String,
        body: [String: Any],
        completion: @escaping (Result<Void, OpenCodexRepositoryError>) -> Void
    ) {
        send(candidate: candidate, path: path, method: method, body: body) { result in
            completion(result.map { _ in () })
        }
    }

    private func send(
        candidate: OpenCodexEndpointCandidate,
        path: String,
        method: String,
        body: [String: Any]?,
        authenticated: Bool = true,
        completion: @escaping (Result<OpenCodexHTTPResponse, OpenCodexRepositoryError>) -> Void
    ) {
        guard var components = URLComponents(
            url: candidate.managementURL.appendingPathComponent(path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path),
            resolvingAgainstBaseURL: false
        ) else {
            completion(.failure(.invalidResponse))
            return
        }
        if let question = path.firstIndex(of: "?") {
            let query = String(path[path.index(after: question)...])
            components.percentEncodedQuery = query
        }
        guard let url = components.url else {
            completion(.failure(.invalidResponse))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated, let token = tokenProvider.token(for: candidate) {
            request.setValue(token, forHTTPHeaderField: "X-OpenCodex-API-Key")
        }
        if let body {
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                completion(.failure(.invalidResponse))
                return
            }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        transport.send(request) { result in
            switch result {
            case .failure:
                completion(.failure(.managementUnavailable))
            case .success(let response):
                guard (200..<300).contains(response.statusCode) else {
                    completion(.failure(.managementUnavailable))
                    return
                }
                completion(.success(response))
            }
        }
    }

    private static func isValidCandidate(_ candidate: OpenCodexEndpointCandidate) -> Bool {
        guard let scheme = candidate.baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = candidate.baseURL.host?.lowercased(),
              OpenCodexEndpointCandidate.isLoopbackHost(host),
              candidate.wireAPI.lowercased() == "responses" else {
            return false
        }
        return candidate.baseURL.path == "/v1"
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
