import Foundation
import Darwin

enum ClaudeTokenRefreshTrigger: String { case expired, unauthorized, enabled }

enum ClaudeTokenRefreshFailure: Equatable {
    case egress(ClaudeEgressGuardBlock)
    case routeUnsupported
    case settingsEnv(variable: String)
    case claudeNotFound
    case launchFailed
    case commandFailed(exitCode: Int32)
    case timedOut

    var reason: String {
        switch self {
        case let .egress(block): return "egress_\(block.rawValue)"
        case .routeUnsupported: return "route_unsupported"
        case .settingsEnv: return "settings_env"
        case .claudeNotFound: return "claude_not_found"
        case .launchFailed: return "launch_failed"
        case .commandFailed: return "command_failed"
        case .timedOut: return "timed_out"
        }
    }
}

enum ClaudeTokenRefreshState: Equatable {
    case idle, running, paused
    case succeeded(at: Date)
    case failed(ClaudeTokenRefreshFailure, nextTryAt: Date?)
}

enum ClaudeTokenRefreshModAvailability: Equatable { case detecting, available, unavailable, unknown }

protocol ClaudeRefreshCommandRunning {
    /// Blocking, off main. Does not retain credential-bearing command output.
    func run(executablePath: String, arguments: [String], environment: [String: String], timeout: TimeInterval) -> ModCommandResult?
}

struct ProcessClaudeRefreshCommandRunner: ClaudeRefreshCommandRunning {
    func run(executablePath: String, arguments: [String], environment: [String: String], timeout: TimeInterval) -> ModCommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        // The OS drains both streams directly; neither can fill a pipe or leak into our logs.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 2) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            return .init(exitCode: -1, stdout: "", stderr: "timed out")
        }
        return .init(exitCode: process.terminationStatus, stdout: "", stderr: "")
    }
}

final class ClaudeTokenAutoRefresher {
    typealias Credentials = (token: String?, expiresAt: Date?, unreadable: Bool)
    typealias Probe = (URL, CCSwitchProxyConfiguration, @escaping (ClaudeEgressGuard.ProbeResult) -> Void) -> Void
    private struct Outcome {
        var ran = false
        var refreshed = false
    }

    private let queue = DispatchQueue(label: "BalanceBar.ClaudeTokenAutoRefresh", qos: .utility)
    private let lock = NSLock()
    private var waiting: [(Outcome) -> Void] = []
    private var storedState: ClaudeTokenRefreshState
    private var stateCallback: ((ClaudeTokenRefreshState) -> Void)?
    private var nextTryAt: Date?
    private let isEnabled: () -> Bool
    private let egressGuard: ClaudeEgressGuard
    private let route: () -> CCSwitchProxyConfiguration
    private let probe: Probe
    private let settings: () -> [String: Any]?
    private let credentials: () -> Credentials
    private let modAvailability: () -> ClaudeTokenRefreshModAvailability
    private let modOperationInProgress: () -> Bool
    private let locator: ClaudeExecutableLocating
    private let runner: ClaudeRefreshCommandRunning
    private let loadPause: () -> String?
    private let savePause: (String?) -> Void
    private let environment: () -> [String: String]
    private let now: () -> Date
    private let log: (String) -> Void

    init(isEnabled: @escaping () -> Bool, egressGuard: ClaudeEgressGuard,
         route: @escaping () -> CCSwitchProxyConfiguration, probe: @escaping Probe,
         settings: @escaping () -> [String: Any]?, credentials: @escaping () -> Credentials,
         modAvailability: @escaping () -> ClaudeTokenRefreshModAvailability,
         modOperationInProgress: @escaping () -> Bool, locator: ClaudeExecutableLocating,
         runner: ClaudeRefreshCommandRunning, loadPause: @escaping () -> String?,
         savePause: @escaping (String?) -> Void,
         environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
         now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = { SwitchLog.write($0, category: "refresh.token_refresh") }) {
        self.isEnabled = isEnabled
        self.egressGuard = egressGuard
        self.route = route
        self.probe = probe
        self.settings = settings
        self.credentials = credentials
        self.modAvailability = modAvailability
        self.modOperationInProgress = modOperationInProgress
        self.locator = locator
        self.runner = runner
        self.loadPause = loadPause
        self.savePause = savePause
        self.environment = environment
        self.now = now
        self.log = log
        self.storedState = isEnabled() && loadPause() != nil ? .paused : .idle
    }

    var state: ClaudeTokenRefreshState { lock.withLock { storedState } }
    var onStateChange: ((ClaudeTokenRefreshState) -> Void)? {
        get { lock.withLock { stateCallback } }
        set { lock.withLock { stateCallback = newValue } }
    }

    private func setState(_ state: ClaudeTokenRefreshState) {
        let callback = lock.withLock { () -> ((ClaudeTokenRefreshState) -> Void)? in
            guard storedState != state else { return nil }
            storedState = state
            return stateCallback
        }
        if let callback { DispatchQueue.main.async { callback(state) } }
    }

    func preflight(expiresAt: Date?, hasToken: Bool, reason: FetchRequestReason,
                   completion: @escaping (Bool) -> Void) -> Bool {
        guard isEnabled(), state == .paused || (hasToken && expiresAt.map { $0 <= now() } == true) else { return false }
        enqueue(.expired, bypassCooldown: reason == .manual) { completion($0.ran) }
        return true
    }

    func refresh(trigger: ClaudeTokenRefreshTrigger, bypassCooldown: Bool, completion: @escaping (Bool) -> Void) {
        enqueue(trigger, bypassCooldown: bypassCooldown) { completion($0.refreshed) }
    }

    func enabledChanged(_ on: Bool) {
        queue.async { [self] in
            guard on else {
                if !isEnabled() { setState(.idle) }
                return
            }
            guard isEnabled() else { return }
            savePause(nil)
            nextTryAt = nil
            setState(.idle)
            log("token refresh resumed; reason=re_enabled")
            refresh(trigger: .enabled, bypassCooldown: false) { _ in }
        }
    }

    private func enqueue(_ trigger: ClaudeTokenRefreshTrigger, bypassCooldown: Bool, completion: @escaping (Outcome) -> Void) {
        let starts = lock.withLock {
            waiting.append(completion)
            return waiting.count == 1
        }
        guard starts else { return }
        queue.async { [self] in
            let result = attempt(trigger, bypassCooldown: bypassCooldown)
            let callbacks = lock.withLock {
                defer { waiting.removeAll() }
                return waiting
            }
            callbacks.forEach { $0(result) }
        }
    }

    private func attempt(_ trigger: ClaudeTokenRefreshTrigger, bypassCooldown: Bool) -> Outcome {
        func skip(_ reason: String) -> Outcome {
            log("token refresh skipped; trigger=\(trigger.rawValue); reason=\(reason)")
            return Outcome()
        }
        func blocked(_ failure: ClaudeTokenRefreshFailure, cooldown: Bool) -> Outcome {
            if case .egress(.disabled) = failure { return skip("egress_guard_disabled") }
            if case .egress(.noTargets) = failure { return skip("no_targets") }
            let variable: String
            if case let .settingsEnv(name) = failure { variable = "; variable=\(name)" } else { variable = "" }
            log("token refresh blocked; trigger=\(trigger.rawValue); reason=\(failure.reason)\(variable)")
            fail(failure, cooldown: cooldown)
            return Outcome()
        }
        guard isEnabled() else { return Outcome() }
        let before = credentials()
        let version = before.token.flatMap(ClaudeAccountIdentityProvider.credentialVersion(for:))?.value
        if let paused = loadPause(), !before.unreadable, let version,
           version != paused || before.expiresAt.map({ $0 > now() }) == true {
            savePause(nil)
            setState(.idle)
            log("token refresh resumed; reason=new_credential")
        }
        let allowlist = egressGuard.settings()
        guard allowlist.enabled else { return skip("egress_guard_disabled") }
        guard modAvailability() == .available else { return skip("mod_unavailable") }
        guard !EgressIPAddress.sanitizedList(allowlist.allowedIPs).isEmpty else { return skip("no_targets") }
        guard loadPause() == nil else { return skip("paused") }
        guard !before.unreadable else { return skip("keychain_unreadable") }
        guard let version, let expiry = before.expiresAt, expiry <= now() else { return skip("not_expired") }
        guard bypassCooldown || nextTryAt.map({ $0 <= now() }) != false else { return skip("cooldown") }
        guard !modOperationInProgress() else { return skip("mod_busy") }
        guard let path = locator.locate() else { return blocked(.claudeNotFound, cooldown: true) }
        let config = settings()
        if let variable = Self.conflictingSetting(config) { return blocked(.settingsEnv(variable: variable), cooldown: false) }
        let checkedRoute = route()
        guard Self.routeMatchesSettings(checkedRoute, settings: config) else { return blocked(.routeUnsupported, cooldown: false) }
        var traces: [EgressTrace] = []
        for url in [OfficialQuotaClient.claudeEgressTraceURL, OfficialQuotaClient.claudePlatformEgressTraceURL] {
            guard let trace = checkedTrace(url: url, route: checkedRoute), trace.route == checkedRoute else {
                return blocked(.egress(.checkFailed), cooldown: true)
            }
            if case let .blocked(reason) = egressGuard.decision(for: trace) { return blocked(.egress(reason), cooldown: true) }
            traces.append(trace)
        }
        let latest = credentials()
        guard !latest.unreadable else { return skip("keychain_unreadable") }
        guard latest.token.flatMap(ClaudeAccountIdentityProvider.credentialVersion(for:))?.value == version,
              let latestExpiry = latest.expiresAt, latestExpiry <= now() else { return skip("already_refreshed") }
        guard isEnabled() else { return Outcome() }
        guard modAvailability() == .available else { return skip("mod_unavailable") }
        guard !modOperationInProgress() else { return skip("mod_busy") }
        let latestConfig = settings()
        if let variable = Self.conflictingSetting(latestConfig) { return blocked(.settingsEnv(variable: variable), cooldown: false) }
        guard route() == checkedRoute, Self.routeMatchesSettings(checkedRoute, settings: latestConfig) else {
            return blocked(.egress(.checkFailed), cooldown: true)
        }
        for trace in traces {
            if case let .blocked(reason) = egressGuard.decision(for: trace) { return blocked(.egress(reason), cooldown: true) }
        }
        guard isEnabled() else { return Outcome() }
        return run(path: path, route: checkedRoute, trigger: trigger, version: version, expiry: latestExpiry)
    }

    private func checkedTrace(url: URL, route: CCSwitchProxyConfiguration) -> EgressTrace? {
        // The production transport bounds each request to six seconds. The separate service queue
        // can wait without stalling the quota pipeline or the UI.
        let done = DispatchSemaphore(value: 0)
        var result: ClaudeEgressGuard.ProbeResult?
        probe(url, route) { result = $0; done.signal() }
        done.wait()
        return try? result?.get()
    }

    private func fail(_ failure: ClaudeTokenRefreshFailure, cooldown: Bool) {
        nextTryAt = cooldown ? now().addingTimeInterval(30 * 60) : nil
        setState(.failed(failure, nextTryAt: nextTryAt))
    }

    private func run(path: String, route: CCSwitchProxyConfiguration, trigger: ClaudeTokenRefreshTrigger,
                     version: String, expiry: Date) -> Outcome {
        let started = now()
        let beforeMinutes = Self.remainingMinutes(expiry, at: started)
        setState(.running)
        log("token refresh started; trigger=\(trigger.rawValue); remaining_before_min=\(beforeMinutes)")
        let result = runner.run(executablePath: path, arguments: ["plugin", "marketplace", "update", "balancebar-mods"],
                                environment: Self.childEnvironment(environment(), route: route), timeout: 60)
        let after = credentials()
        let finished = now()
        let newVersion = after.token.flatMap(ClaudeAccountIdentityProvider.credentialVersion(for:))?.value
        let changed = newVersion != version
        let refreshed = newVersion != nil && (changed || after.expiresAt.map { $0 > finished } == true)
        let outcome: String
        if refreshed {
            nextTryAt = nil
            setState(.succeeded(at: finished))
            outcome = "refreshed"
        } else if result != nil, !after.unreadable,
                  newVersion == nil || (result?.exitCode == 0 && after.expiresAt.map { $0 <= finished } == true) {
            savePause(newVersion ?? "signed_out")
            nextTryAt = nil
            setState(.paused)
            outcome = "login_invalid"
        } else {
            if let result {
                fail(result.exitCode == -1 ? .timedOut : .commandFailed(exitCode: result.exitCode), cooldown: true)
            } else {
                fail(.launchFailed, cooldown: true)
            }
            outcome = "failed"
        }
        log("token refresh finished; result=\(outcome); exit=\(result.map { String($0.exitCode) } ?? "-"); duration_ms=\(Int(finished.timeIntervalSince(started) * 1_000)); remaining_before_min=\(beforeMinutes); remaining_after_min=\(Self.remainingMinutes(after.expiresAt, at: finished)); credential_changed=\(changed)")
        return Outcome(ran: result != nil, refreshed: refreshed)
    }

    private static func remainingMinutes(_ expiry: Date?, at date: Date) -> String {
        expiry.map { String(Int($0.timeIntervalSince(date) / 60)) } ?? "unknown"
    }

    private static let managedProxyKeys = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
    private static let conflictingEnvKeys = ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR",
                                              "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"]

    /// Display-only: reuses the launch preflight check without changing refresh state.
    func currentSettingsConflict() -> String? {
        Self.conflictingSetting(settings())
    }

    static func conflictingSetting(_ settings: [String: Any]?) -> String? {
        let env = settings?["env"] as? [String: Any] ?? [:]
        for key in conflictingEnvKeys where nonempty(env[key]) { return key }
        for key in ["NO_PROXY", "no_proxy"] {
            guard let value = env[key] as? String else { continue }
            for item in value.split(separator: ",") {
                let entry = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let domain = entry.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                let suffix = String(domain.drop(while: { $0 == "." || $0 == "*" }))
                if entry == "*" || ["claude.ai", "platform.claude.com"].contains(where: { $0 == suffix || $0.hasSuffix(".\(suffix)") }) {
                    return key
                }
            }
        }
        return nonempty(settings?["apiKeyHelper"]) ? "apiKeyHelper" : nil
    }

    private static func nonempty(_ value: Any?) -> Bool {
        if let text = value as? String { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return value != nil && !(value is NSNull)
    }

    static func supportedRoute(_ route: CCSwitchProxyConfiguration) -> Bool {
        guard let proxy = route.httpsProxy ?? route.allProxy else { return true }
        return ["http", "https"].contains(proxy.scheme?.lowercased() ?? "")
            && proxy.host?.isEmpty == false && (proxy.port.map { (1...65535).contains($0) } ?? true)
            && (proxy.path.isEmpty || proxy.path == "/") && proxy.query == nil && proxy.fragment == nil
    }

    private static func routeMatchesSettings(_ route: CCSwitchProxyConfiguration, settings: [String: Any]?) -> Bool {
        guard supportedRoute(route) else { return false }
        let proxy = route.httpsProxy ?? route.allProxy
        let env = settings?["env"] as? [String: Any] ?? [:]
        // Claude can reapply its user settings after launch. An alias that would override our
        // pinned proxy (or add one to a direct route) cannot be assumed to follow the probe.
        return managedProxyKeys.allSatisfy { key in
            guard nonempty(env[key]) else { return true }
            guard let proxy, let text = env[key] as? String else { return false }
            return URL(string: text) == proxy
        }
    }

    static func childEnvironment(_ inherited: [String: String], route: CCSwitchProxyConfiguration) -> [String: String] {
        var result = inherited
        for key in conflictingEnvKeys + managedProxyKeys + ["NO_PROXY", "no_proxy"] { result.removeValue(forKey: key) }
        for key in ["DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_AUTOUPDATER", "DISABLE_BUG_COMMAND"] { result[key] = "1" }
        if let proxy = route.httpsProxy ?? route.allProxy {
            for key in managedProxyKeys { result[key] = proxy.absoluteString }
        }
        return result
    }
}
