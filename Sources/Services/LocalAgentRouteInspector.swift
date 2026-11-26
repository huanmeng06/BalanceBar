import Foundation

enum LocalAgentRoute: Equatable { case official, thirdParty, undetermined }

struct LocalAgentRouteInspector {
    let homeDirectoryURL: URL

    func route(for client: AssistantClient) -> LocalAgentRoute {
        guard client != .grok else { return .undetermined }
        if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true {
            switch ProcessInfo.processInfo.environment["BALANCEBAR_SIM_LOCAL_ROUTE"] {
            case "official": return .official
            case "thirdparty": return .thirdParty
            case "undetermined": return .undetermined
            default: break
            }
        }
        let path = client == .claude ? ".claude/settings.json" : ".codex/config.toml"
        let data: Data
        do { data = try Data(contentsOf: homeDirectoryURL.appendingPathComponent(path)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .official }
        catch { return .undetermined }
        guard let text = String(data: data, encoding: .utf8) else { return .undetermined }
        if text.contains("PROXY_MANAGED") { return .thirdParty }
        if client == .codex {
            if text.contains("cc-switch-official") { return .thirdParty }
            if let route = Self.codexRoute(text) { return route.isEmpty ? .official : .thirdParty }
            if let provider = Self.topLevelCodexProvider(in: text), provider != "openai" { return .thirdParty }
            return .undetermined
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .undetermined }
        if object["apiKeyHelper"] != nil { return .thirdParty }
        guard object["env"] == nil || object["env"] is [String: String] else { return .undetermined }
        let env = object["env"] as? [String: String] ?? [:]
        return Self.managedClaudeEnvironment(env).isEmpty ? .official : .thirdParty
    }

    /// The provider card owns the routing and credential selectors. Proxy,
    /// telemetry, TLS and other user-owned environment keys do not establish
    /// whether CC Switch's direct route is still intact.
    static func managedClaudeEnvironment(_ env: [String: String]) -> [String: String] {
        var managed = env.filter { key, _ in
            switch key {
            case "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                 "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
                 "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                 "AWS_REGION", "AWS_PROFILE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                 "GOOGLE_CLOUD_PROJECT", "GOOGLE_APPLICATION_CREDENTIALS", "CLOUD_ML_REGION":
                return true
            default:
                let uppercased = key.uppercased()
                if key.hasPrefix("ANTHROPIC_") {
                    return uppercased.contains("TOKEN") || uppercased.contains("API_KEY")
                        || uppercased.contains("MODEL") || uppercased.contains("BEDROCK")
                        || uppercased.contains("VERTEX") || uppercased.contains("FOUNDRY")
                }
                return key.hasPrefix("CLAUDE_CODE_USE_")
                    || (key.hasPrefix("CLAUDE_CODE_") && uppercased.contains("MODEL"))
            }
        }
        if let baseURL = managed["ANTHROPIC_BASE_URL"], isOfficialClaudeBaseURL(baseURL) {
            managed.removeValue(forKey: "ANTHROPIC_BASE_URL")
        }
        return managed
    }

    private static func isOfficialClaudeBaseURL(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.anthropic.com",
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    private static func topLevelCodexProvider(in config: String) -> String? {
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            if line.hasPrefix("#") { continue }
            if let match = line.wholeMatch(of: #/(?:model_provider|"model_provider"|'model_provider')[ \t]*=[ \t]*("(?:[^"\\]|\\.)*"|'[^']*')[ \t]*(?:#.*)?/#) {
                let value = match.output.1
                if value.hasPrefix("'") { return String(value.dropFirst().dropLast()) }
                return (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) as? String
            }
            // Do not mistake assignments inside an unsupported multiline string for TOML keys.
            if line.contains("\"\"\"") || line.contains("'''") { break }
        }
        return nil
    }

    /// Strict single-line routing subset. Unsupported/ambiguous routing syntax fails closed.
    static func codexRoute(_ config: String) -> [String: String]? {
        var section = ""
        var values: [String: [String: String]] = [:]
        let relevant: Set<String> = ["model_provider", "base_url", "openai_base_url", "env_key", "experimental_bearer_token", "wire_api"]
        for raw in config.components(separatedBy: .newlines) {
            // Multiline strings require a full TOML parser; never infer a route from their contents.
            guard !raw.contains("\"\"\""), !raw.contains("'" + "''") else { return nil }
            var quoted: Character?
            var escaped = false
            var line = ""
            for char in raw {
                if char == "#" && quoted == nil { break }
                line.append(char)
                if escaped { escaped = false; continue }
                if char == "\\" && quoted == "\"" { escaped = true; continue }
                if let quote = quoted { if char == quote { quoted = nil } }
                else if char == "\"" || char == "'" { quoted = char }
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { return nil }
                if line.hasPrefix("[[") {
                    guard !line.contains("model_providers") else { return nil }
                    section = "ignored-array"
                    continue
                }
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard section.isEmpty || section.hasPrefix("model_providers.") else { continue }
            guard let equal = line.firstIndex(of: "=") else { return nil }
            let rawKey = line[..<equal].trimmingCharacters(in: .whitespaces)
            let key: String
            if rawKey.hasPrefix("\"") {
                guard let parsed = try? JSONSerialization.jsonObject(with: Data(rawKey.utf8), options: .fragmentsAllowed) as? String else { return nil }
                key = parsed
            } else if rawKey.hasPrefix("'") && rawKey.hasSuffix("'") { key = String(rawKey.dropFirst().dropLast()) }
            else { key = rawKey }
            if section.isEmpty && (key == "profile" || key == "model_providers" || key.hasPrefix("model_providers.")) { return nil }
            guard relevant.contains(key) else { continue }
            let literal = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            let value: String
            if literal.hasPrefix("\""), let parsed = try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed) as? String { value = parsed }
            else if literal.hasPrefix("'"), literal.hasSuffix("'"), literal.count >= 2 { value = String(literal.dropFirst().dropLast()) }
            else { return nil }
            guard values[section]?[key] == nil else { return nil }
            values[section, default: [:]][key] = value
        }
        let top = values[""] ?? [:]
        let selector = top["model_provider"] ?? "openai"
        guard selector.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        var route = values["model_providers." + selector] ?? [:]
        if route.isEmpty && selector != "openai" { return nil }
        if let url = top["openai_base_url"] ?? top["base_url"], route["base_url"] == nil { route["base_url"] = url }
        route.removeValue(forKey: "model_provider")
        if route["wire_api"] == "responses" { route.removeValue(forKey: "wire_api") }
        return route
    }

}
