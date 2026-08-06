#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-balance-query-probe.XXXXXX")"
probe_binary="$probe_dir/balance-query-probe"
trap 'rm -rf "$probe_dir"' EXIT

{
    printf '%s\n' 'import Foundation'
    awk '
        /^private enum NativeBalanceProvider \{/ { capture = 1 }
        capture { print }
    ' "$source_dir/BalanceBar.swift"
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
    disabledScript,
    missingCredential,
    missingBaseURL,
    missingCode,
    missingEndpoint,
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

print("balance query probe: PASS; two success paths; TOML bearer fallback; stable parsing failure reasons; diagnostics exclude credentials, auth/config JSON, endpoints, and responses")
SWIFT
} | swiftc -framework Foundation -o "$probe_binary" -

"$probe_binary"
