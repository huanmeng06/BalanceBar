#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-balance-query-probe.XXXXXX")"
probe_binary="$probe_dir/balance-query-probe"
trap 'rm -rf "$probe_dir"' EXIT

{
    printf '%s\n' 'import Foundation'
    cat "$source_dir/Sources/Domain/BalanceQuery.swift"
    cat <<'SWIFT'

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

// Sanitized fixtures only. This probe never touches the real CC Switch database,
// Keychain, network, or any real credential.

func settingsJSON(config: String, auth: [String: String] = [:]) -> String {
    var object: [String: Any] = ["config": config]
    if !auth.isEmpty { object["auth"] = auth }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

func usageMetaJSON(
    enabled: Bool = true,
    interval: Int = 30,
    timeout: Int = 15,
    code: String
) -> String {
    let script: [String: Any] = [
        "enabled": enabled,
        "autoQueryInterval": interval,
        "timeout": timeout,
        "code": code
    ]
    let object: [String: Any] = ["usage_script": script]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

func metaJSON(usageScript: Any? = nil) -> String {
    var object: [String: Any] = [:]
    if let usageScript { object["usage_script"] = usageScript }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

private func resolve(
    settingsText: String,
    metaText: String,
    websiteText: String? = nil,
    appType: String = "codex"
) -> (query: BalanceQuery?, failure: BalanceQueryFailure?) {
    var failure: BalanceQueryFailure?
    let query = BalanceQuery.make(
        settingsText: settingsText,
        metaText: metaText,
        websiteText: websiteText,
        appType: appType,
        onFailure: { failure = $0 }
    )
    return (query, failure)
}

let usageCode = "const u = `url: \"{{baseUrl}}/v1/usage\"`;"

let tokenshopConfig = """
[general]
base_url = "https://tokenshop.example.test"

[experimental]
experimental_bearer_token = "tokenshop-sanitized-bearer"
"""

let tokenlessConfig = """
[general]
base_url = "https://tokenshop.example.test"
"""

// 1. JSON credential keeps priority over the TOML fallback.
private let jsonPriority = BalanceQuery.make(
    settingsText: settingsJSON(
        config: tokenshopConfig,
        auth: ["OPENAI_API_KEY": "json-sanitized-key"]
    ),
    metaText: usageMetaJSON(code: usageCode),
    websiteText: "https://tokenshop.example.test",
    appType: "codex"
)
require(jsonPriority != nil, "JSON credential yields a query")
require(jsonPriority?.apiKey == "json-sanitized-key", "JSON credential wins over TOML")
require(jsonPriority?.url == "https://tokenshop.example.test/v1/usage", "endpoint follows the usage script path")

// 2. TOML experimental_bearer_token fallback (tokenshop shape) yields a query.
private let tomlFallback = BalanceQuery.make(
    settingsText: settingsJSON(config: tokenshopConfig),
    metaText: usageMetaJSON(interval: 45, timeout: 20, code: usageCode),
    websiteText: "https://tokenshop.example.test",
    appType: "codex"
)
require(tomlFallback != nil, "TOML experimental_bearer_token fallback yields a query")
require(tomlFallback?.apiKey == "tokenshop-sanitized-bearer", "TOML bearer token is used as the credential")
require(tomlFallback?.url == "https://tokenshop.example.test/v1/usage", "endpoint is the usage-script-declared path")
require(tomlFallback?.intervalMinutes == 45, "interval is preserved")
require(tomlFallback?.timeoutSeconds == 20, "timeout is preserved")
require(tomlFallback?.websiteURL == URL(string: "https://tokenshop.example.test"), "website URL is preserved")
require(tomlFallback?.isNewAPI == false, "plain usage script keeps isNewAPI false")
require(tomlFallback?.isRightCode == false, "plain usage script keeps isRightCode false")
require(tomlFallback?.additionalHeaders.isEmpty == true, "no extra headers are added")
private let successfulResolution = resolve(
    settingsText: settingsJSON(config: tokenshopConfig),
    metaText: usageMetaJSON(code: usageCode)
)
require(successfulResolution.query != nil, "successful configuration resolves a query")
require(successfulResolution.failure == nil, "successful configuration emits no failure diagnostic")

// 3. No credential anywhere -> no query.
private let noCredential = BalanceQuery.make(
    settingsText: settingsJSON(config: tokenlessConfig),
    metaText: usageMetaJSON(code: usageCode),
    websiteText: nil,
    appType: "codex"
)
require(noCredential == nil, "missing JSON and TOML credentials return no query")

// 4. Empty TOML value -> no query (no empty Authorization request).
private let emptyToml = BalanceQuery.make(
    settingsText: settingsJSON(config: """
[general]
base_url = "https://tokenshop.example.test"

[experimental]
experimental_bearer_token = ""
"""),
    metaText: usageMetaJSON(code: usageCode),
    websiteText: nil,
    appType: "codex"
)
require(emptyToml == nil, "empty TOML bearer token returns no query")

// 5. Unquoted / invalid TOML value -> not recognized as a credential.
private let invalidToml = BalanceQuery.make(
    settingsText: settingsJSON(config: """
[general]
base_url = "https://tokenshop.example.test"

[experimental]
experimental_bearer_token = unquoted-value
"""),
    metaText: usageMetaJSON(code: usageCode),
    websiteText: nil,
    appType: "codex"
)
require(invalidToml == nil, "unquoted TOML bearer token is not recognized as a credential")

// 6. Commented-out and unrelated TOML fields are not credentials.
private let commentOnly = BalanceQuery.make(
    settingsText: settingsJSON(config: """
[general]
base_url = "https://tokenshop.example.test"
# experimental_bearer_token = "fake-token"
other_token = "not-a-credential"
"""),
    metaText: usageMetaJSON(code: usageCode),
    websiteText: nil,
    appType: "codex"
)
require(commentOnly == nil, "commented-out and unrelated TOML fields are ignored")

// 7. Whitespace around the TOML key and value is tolerated.
private let spacedToml = BalanceQuery.make(
    settingsText: settingsJSON(config: """
[general]
base_url   =   "https://tokenshop.example.test"

[experimental]
  experimental_bearer_token   =   "spaced-token"
"""),
    metaText: usageMetaJSON(code: usageCode),
    websiteText: nil,
    appType: "codex"
)
require(spacedToml != nil, "whitespace around the TOML key/value is tolerated")
require(spacedToml?.apiKey == "spaced-token", "whitespace-tolerant TOML token is read")

// 8. Empty JSON credential falls through to the TOML fallback (existing empty-key semantics).
private let emptyJSONKey = BalanceQuery.make(
    settingsText: settingsJSON(
        config: tokenshopConfig,
        auth: ["OPENAI_API_KEY": ""]
    ),
    metaText: usageMetaJSON(code: usageCode),
    websiteText: nil,
    appType: "codex"
)
require(emptyJSONKey != nil, "empty JSON credential falls through to TOML")
require(emptyJSONKey?.apiKey == "tokenshop-sanitized-bearer", "TOML token is used after an empty JSON credential")

// Stable failure categories are produced at the exact parsing stage.
private let invalidSettings = resolve(
    settingsText: "{not-json",
    metaText: usageMetaJSON(code: usageCode)
)
require(invalidSettings.query == nil, "malformed settings JSON returns no query")
require(invalidSettings.failure == .settingsJSONInvalid, "malformed settings JSON has a distinct reason")

private let invalidMeta = resolve(
    settingsText: settingsJSON(config: tokenshopConfig),
    metaText: "[not-a-meta-object]"
)
require(invalidMeta.failure == .metaJSONInvalid, "malformed meta JSON has a distinct reason")

private let missingScript = resolve(
    settingsText: settingsJSON(config: tokenshopConfig),
    metaText: metaJSON()
)
require(missingScript.failure == .usageScriptMissing, "missing usage script has a distinct reason")

private let invalidScript = resolve(
    settingsText: settingsJSON(config: tokenshopConfig),
    metaText: metaJSON(usageScript: "{not-json")
)
require(invalidScript.failure == .usageScriptInvalid, "invalid usage script has a distinct reason")

private let disabledScript = resolve(
    settingsText: settingsJSON(config: tokenshopConfig),
    metaText: usageMetaJSON(enabled: false, code: usageCode)
)
require(disabledScript.failure == .usageScriptDisabled, "disabled usage script has a distinct reason")

private let missingCredential = resolve(
    settingsText: settingsJSON(config: tokenlessConfig),
    metaText: usageMetaJSON(code: usageCode)
)
require(missingCredential.failure == .credentialMissing, "missing credential has a distinct reason")

private let missingBaseURL = resolve(
    settingsText: settingsJSON(config: "", auth: ["OPENAI_API_KEY": "sanitized-key"]),
    metaText: usageMetaJSON(code: usageCode)
)
require(missingBaseURL.failure == .baseURLMissing, "missing base URL has a distinct reason")

private let missingCode = resolve(
    settingsText: settingsJSON(config: tokenshopConfig),
    metaText: metaJSON(usageScript: ["enabled": true])
)
require(missingCode.failure == .requestCodeMissing, "missing request code has a distinct reason")

private let missingEndpoint = resolve(
    settingsText: settingsJSON(config: tokenshopConfig),
    metaText: usageMetaJSON(code: "const value = 1;")
)
require(missingEndpoint.failure == .requestEndpointMissing, "missing endpoint has a distinct reason")

private let unsupportedNativeTemplate = resolve(
    settingsText: settingsJSON(
        config: tokenlessConfig,
        auth: ["OPENAI_API_KEY": "sanitized-key"]
    ),
    metaText: metaJSON(usageScript: [
        "enabled": true,
        "templateType": "balance"
    ])
)
require(unsupportedNativeTemplate.failure == .nativeTemplateUnsupported, "unsupported native template has a distinct reason")

let sensitiveCredential = "SENSITIVE_BEARER_MUST_NOT_APPEAR"
private let missingTemplateField = resolve(
    settingsText: settingsJSON(
        config: tokenlessConfig,
        auth: ["OPENAI_API_KEY": sensitiveCredential]
    ),
    metaText: metaJSON(usageScript: [
        "enabled": true,
        "templateType": "newapi",
        "code": usageCode
    ])
)
require(missingTemplateField.failure == .newAPIUserIDMissing, "missing New API user ID has a template-specific reason")

let diagnostics = [
    invalidSettings,
    invalidMeta,
    missingScript,
    invalidScript,
    disabledScript,
    missingCredential,
    missingBaseURL,
    missingCode,
    missingEndpoint,
    unsupportedNativeTemplate,
    missingTemplateField
].compactMap { $0.failure?.diagnostic }
for diagnostic in diagnostics {
    require(!diagnostic.contains(sensitiveCredential), "diagnostic excludes credential values")
    require(!diagnostic.contains("Bearer"), "diagnostic excludes Bearer values")
    require(!diagnostic.contains("https://"), "diagnostic excludes complete endpoints and configuration URLs")
    require(!diagnostic.contains("\"auth\""), "diagnostic excludes full auth JSON")
    require(!diagnostic.contains("\"config\""), "diagnostic excludes full config JSON")
    require(!diagnostic.contains("\"response\""), "diagnostic excludes response content")
}

private let expectedUserVisibleReasons: [(BalanceQueryFailure, String, String)] = [
    (.settingsJSONInvalid, "CC Switch 配置格式无效", "CC Switch configuration is invalid"),
    (.metaJSONInvalid, "CC Switch 配置格式无效", "CC Switch configuration is invalid"),
    (.usageScriptMissing, "用量脚本缺失", "Usage script is missing"),
    (.usageScriptInvalid, "用量脚本无效", "Usage script is invalid"),
    (.usageScriptDisabled, "用量脚本未启用", "Usage script is not enabled"),
    (.credentialMissing, "缺少访问凭据", "Access credential is missing"),
    (.baseURLMissing, "缺少 API 地址", "API address is missing"),
    (.requestCodeMissing, "用量脚本缺少请求代码", "Usage script request code is missing"),
    (.requestEndpointMissing, "用量脚本缺少请求地址", "Usage script request address is missing"),
    (.nativeTemplateUnsupported, "不支持当前余额模板", "Current balance template is not supported"),
    (.newAPIUserIDMissing, "New API 用户 ID 缺失", "New API user ID is missing"),
    (.unknown, "余额查询配置不完整", "Balance query configuration is incomplete")
]
require(expectedUserVisibleReasons.count == 12, "every stable failure type has a user-visible mapping")
for (failure, simplifiedChinese, english) in expectedUserVisibleReasons {
    let actualChinese = failure.userVisibleReason(usesSimplifiedChinese: true)
    let actualEnglish = failure.userVisibleReason(usesSimplifiedChinese: false)
    require(actualChinese == simplifiedChinese, "Chinese user-visible reason is fixed for \(failure.rawValue)")
    require(actualEnglish == english, "English user-visible reason is fixed for \(failure.rawValue)")
    for message in [actualChinese, actualEnglish] {
        require(!message.contains(failure.rawValue), "user-visible reason excludes internal raw values")
        require(!message.contains("stage="), "user-visible reason excludes diagnostic stages")
        require(!message.contains("reason="), "user-visible reason excludes diagnostic reasons")
        require(!message.contains("SENSITIVE_BEARER_MUST_NOT_APPEAR"), "user-visible reason excludes credentials")
        require(!message.contains("Bearer"), "user-visible reason excludes Bearer values")
        require(!message.contains("https://"), "user-visible reason excludes complete URLs")
        require(!message.contains("\"auth\""), "user-visible reason excludes auth configuration")
        require(!message.contains("\"config\""), "user-visible reason excludes full configuration")
        require(!message.contains("\"response\""), "user-visible reason excludes response content")
    }
}

SWIFT
} | swiftc -framework Foundation -o "$probe_binary" -

"$probe_binary"

ui_render_block="$(sed -n '/func refreshStandardProvider(/,/func prefetchCurrentBalance/p' "$source_dir/Sources/Services/ProviderRefreshCoordinator.swift")"
[[ "$ui_render_block" == *"failure.userVisibleReason"* ]] || {
    echo "balance query probe: FAIL; query-unavailable UI does not use the safe localized mapping" >&2
    exit 1
}
[[ "$ui_render_block" == *"renderBalanceError"* ]] || {
    echo "balance query probe: FAIL; query-unavailable UI bypasses the Provider error helper" >&2
    exit 1
}
[[ "$ui_render_block" == *"providerName: current.name"* && "$ui_render_block" == *"reason: reason"* ]] || {
    echo "balance query probe: FAIL; Provider name and pure reason are not passed separately" >&2
    exit 1
}
if grep -Eq 'rawValue|diagnostic|stage=|reason=|https?://|Bearer|SENSITIVE_BEARER_MUST_NOT_APPEAR' <<<"$ui_render_block"; then
    echo "balance query probe: FAIL; query-unavailable UI exposes a technical or sensitive value" >&2
    exit 1
fi

echo "balance query probe: PASS; success paths; all stable parsing failures; fixed Chinese/English user-visible mappings; diagnostics and UI text exclude sensitive configuration"
