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
    interval: Int = 30,
    timeout: Int = 15,
    code: String
) -> String {
    let script: [String: Any] = [
        "enabled": true,
        "autoQueryInterval": interval,
        "timeout": timeout,
        "code": code
    ]
    let object: [String: Any] = ["usage_script": script]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
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

print("balance query probe: PASS; JSON priority; TOML experimental_bearer_token fallback; endpoint from usage script; interval/timeout/website preserved; missing/empty/invalid/commented/unrelated TOML values safe")
SWIFT
} | swiftc -framework Foundation -o "$probe_binary" -

"$probe_binary"
