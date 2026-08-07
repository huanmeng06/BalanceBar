import Foundation

enum NativeBalanceProvider {
    case deepSeek
    case stepFun
    case siliconFlowCN
    case siliconFlowEN
    case openRouter
    case novitaAI

    init?(baseURL: String) {
        let value = baseURL.lowercased()
        if value.contains("api.deepseek.com") {
            self = .deepSeek
        } else if value.contains("api.stepfun.ai")
                    || value.contains("api.stepfun.com") {
            self = .stepFun
        } else if value.contains("api.siliconflow.cn") {
            self = .siliconFlowCN
        } else if value.contains("api.siliconflow.com") {
            self = .siliconFlowEN
        } else if value.contains("openrouter.ai") {
            self = .openRouter
        } else if value.contains("api.novita.ai") {
            self = .novitaAI
        } else {
            return nil
        }
    }

    var endpoint: String {
        switch self {
        case .deepSeek:
            return "https://api.deepseek.com/user/balance"
        case .stepFun:
            return "https://api.stepfun.com/v1/accounts"
        case .siliconFlowCN:
            return "https://api.siliconflow.cn/v1/user/info"
        case .siliconFlowEN:
            return "https://api.siliconflow.com/v1/user/info"
        case .openRouter:
            return "https://openrouter.ai/api/v1/credits"
        case .novitaAI:
            return "https://api.novita.ai/v3/user/balance"
        }
    }
}

enum BalanceQueryFailure: String {
    case settingsJSONInvalid = "settings-json-invalid"
    case metaJSONInvalid = "meta-json-invalid"
    case usageScriptMissing = "usage-script-missing"
    case usageScriptInvalid = "usage-script-invalid"
    case usageScriptDisabled = "usage-script-disabled"
    case credentialMissing = "credential-missing"
    case baseURLMissing = "base-url-missing"
    case requestCodeMissing = "request-code-missing"
    case requestEndpointMissing = "request-endpoint-missing"
    case nativeTemplateUnsupported = "native-template-unsupported"
    case newAPIUserIDMissing = "newapi-user-id-missing"
    case unknown = "unknown"

    func userVisibleReason(usesSimplifiedChinese: Bool) -> String {
        let messages: (simplifiedChinese: String, english: String)
        switch self {
        case .settingsJSONInvalid, .metaJSONInvalid:
            messages = ("CC Switch 配置格式无效", "CC Switch configuration is invalid")
        case .usageScriptMissing:
            messages = ("用量脚本缺失", "Usage script is missing")
        case .usageScriptInvalid:
            messages = ("用量脚本无效", "Usage script is invalid")
        case .usageScriptDisabled:
            messages = ("用量脚本未启用", "Usage script is not enabled")
        case .credentialMissing:
            messages = ("缺少访问凭据", "Access credential is missing")
        case .baseURLMissing:
            messages = ("缺少 API 地址", "API address is missing")
        case .requestCodeMissing:
            messages = ("用量脚本缺少请求代码", "Usage script request code is missing")
        case .requestEndpointMissing:
            messages = ("用量脚本缺少请求地址", "Usage script request address is missing")
        case .nativeTemplateUnsupported:
            messages = ("不支持当前余额模板", "Current balance template is not supported")
        case .newAPIUserIDMissing:
            messages = ("New API 用户 ID 缺失", "New API user ID is missing")
        case .unknown:
            messages = ("余额查询配置不完整", "Balance query configuration is incomplete")
        }
        return usesSimplifiedChinese ? messages.simplifiedChinese : messages.english
    }

    var diagnostic: String {
        switch self {
        case .settingsJSONInvalid: return "stage=settings-json; reason=invalid"
        case .metaJSONInvalid: return "stage=meta-json; reason=invalid"
        case .usageScriptMissing: return "stage=usage-script; reason=missing"
        case .usageScriptInvalid: return "stage=usage-script; reason=invalid"
        case .usageScriptDisabled: return "stage=usage-script; reason=disabled"
        case .credentialMissing: return "stage=credentials; reason=missing"
        case .baseURLMissing: return "stage=base-url; reason=missing"
        case .requestCodeMissing: return "stage=request-code; reason=missing"
        case .requestEndpointMissing: return "stage=request-endpoint; reason=missing"
        case .nativeTemplateUnsupported: return "stage=template; reason=native-provider-unsupported"
        case .newAPIUserIDMissing: return "stage=template; reason=newapi-user-id-missing"
        case .unknown: return "stage=configuration; reason=unknown"
        }
    }
}

struct BalanceQuery {
    let url: String
    let websiteURL: URL?
    let apiKey: String
    let intervalMinutes: Int
    let timeoutSeconds: Int
    let isRightCode: Bool
    let subscriptionPrefix: String
    let nativeBalanceProvider: NativeBalanceProvider?
    let isNewAPI: Bool
    let additionalHeaders: [String: String]

    static func make(
        settingsText: String,
        metaText: String,
        websiteText: String?,
        appType: String,
        onFailure: ((BalanceQueryFailure) -> Void)? = nil
    ) -> BalanceQuery? {
        guard let settings = jsonObject(settingsText) else {
            onFailure?(.settingsJSONInvalid)
            return nil
        }
        guard let meta = jsonObject(metaText) else {
            onFailure?(.metaJSONInvalid)
            return nil
        }
        guard let scriptValue = meta["usage_script"] else {
            onFailure?(.usageScriptMissing)
            return nil
        }
        let script: [String: Any]
        if let dictionary = scriptValue as? [String: Any] {
            script = dictionary
        } else if let scriptText = scriptValue as? String,
                  let dictionary = jsonObject(scriptText) {
            script = dictionary
        } else {
            onFailure?(.usageScriptInvalid)
            return nil
        }
        guard boolValue(script["enabled"]) == true else {
            onFailure?(.usageScriptDisabled)
            return nil
        }

        let apiKey = findString(
            in: script,
            names: ["accessToken", "access_token", "apiKey", "api_key", "key", "token"]
        ) ??
            findString(
                in: settings,
                names: [
                    "OPENAI_API_KEY",
                    "ANTHROPIC_AUTH_TOKEN",
                    "ANTHROPIC_API_KEY",
                    "apiKey",
                    "api_key",
                    "key",
                    "token"
                ]
            ) ??
            tomlBearerToken(in: settings["config"] as? String)
        let baseURL = findString(in: script, names: ["baseUrl", "base_url", "url"]) ??
            findString(
                in: settings,
                names: [
                    "ANTHROPIC_BASE_URL",
                    "OPENAI_BASE_URL",
                    "baseUrl",
                    "base_url",
                    "url"
                ]
            ) ??
            tomlBaseURL(in: settings["config"] as? String)
        guard let apiKey, !apiKey.isEmpty else {
            onFailure?(.credentialMissing)
            return nil
        }
        guard let baseURL, !baseURL.isEmpty else {
            onFailure?(.baseURLMissing)
            return nil
        }

        let interval = (script["autoQueryInterval"] as? NSNumber)?.intValue ?? 30
        let timeout = (script["timeout"] as? NSNumber)?.intValue ?? 15
        let configuredWebsite = websiteText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let websiteURL = configuredWebsite.flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? URL(string: baseURL)
        let templateType = (
            script["templateType"] as? String
                ?? script["template_type"] as? String
                ?? ""
        ).lowercased()
        if templateType == "balance" {
            guard let native = NativeBalanceProvider(baseURL: baseURL) else {
                onFailure?(.nativeTemplateUnsupported)
                return nil
            }
            return BalanceQuery(
                url: native.endpoint,
                websiteURL: websiteURL,
                apiKey: apiKey,
                intervalMinutes: interval,
                timeoutSeconds: timeout,
                isRightCode: false,
                subscriptionPrefix: appType == "claude" ? "/claude" : "/codex",
                nativeBalanceProvider: native,
                isNewAPI: false,
                additionalHeaders: [:]
            )
        }

        guard let code = script["code"] as? String, !code.isEmpty else {
            onFailure?(.requestCodeMissing)
            return nil
        }
        guard let template = capture(
            "url\\s*:\\s*[\\x60\\\"]([^\\x60\\\"]+)",
            in: code
        ) else {
            onFailure?(.requestEndpointMissing)
            return nil
        }
        let url = template.replacingOccurrences(
            of: "{{baseUrl}}",
            with: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        var additionalHeaders: [String: String] = [:]
        if templateType == "newapi" {
            guard let userID = findString(
                in: script,
                names: ["userId", "user_id", "userID"]
            ), !userID.isEmpty else {
                onFailure?(.newAPIUserIDMissing)
                return nil
            }
            additionalHeaders["Content-Type"] = "application/json"
            additionalHeaders["New-Api-User"] = userID
            additionalHeaders["User-Agent"] = "cc-switch/1.0"
        }
        return BalanceQuery(
            url: url,
            websiteURL: websiteURL,
            apiKey: apiKey,
            intervalMinutes: interval,
            timeoutSeconds: timeout,
            isRightCode: url.contains("/account/summary"),
            subscriptionPrefix: appType == "claude" ? "/claude" : "/codex",
            nativeBalanceProvider: nil,
            isNewAPI: templateType == "newapi",
            additionalHeaders: additionalHeaders
        )
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func findString(in value: Any, names: [String]) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if names.contains(key), let string = nested as? String, !string.isEmpty { return string }
            }
            for nested in dictionary.values {
                if let result = findString(in: nested, names: names) { return result }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let result = findString(in: nested, names: names) { return result }
            }
        }
        return nil
    }

    private static func tomlBaseURL(in config: String?) -> String? {
        guard let config else { return nil }
        return capture("base_url\\s*=\\s*\\\"([^\\\"]+)\\\"", in: config)
    }

    private static func tomlBearerToken(in config: String?) -> String? {
        guard let config else { return nil }
        return capture("(?m)^\\s*experimental_bearer_token\\s*=\\s*\\\"([^\\\"]+)\\\"", in: config)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        default: return nil
        }
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
