#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-network-error-localization-probe.XXXXXX")"
probe_binary="$probe_dir/network-error-localization-probe"
trap 'rm -rf "$probe_dir"' EXIT

network_error_function="$(awk '
    /^    static func localizedBalanceNetworkErrorReason\(/ { capture = 1 }
    capture {
        print
        opens = gsub(/\{/, "{")
        closes = gsub(/\}/, "}")
        depth += opens - closes
        if (seenOpen && depth <= 0) exit
        if (opens > 0) seenOpen = 1
    }
' "$source_dir/Sources/Services/ProviderRefreshCoordinator.swift")"

[[ "$network_error_function" == *"static func localizedBalanceNetworkErrorReason(_ error: Error, language: AppLanguage)"* ]] || {
    echo "network error localization probe: FAIL; production function signature changed or could not be extracted" >&2
    exit 1
}

{
    printf '%s\n' 'import Foundation' 'import AppKit'
    cat "$source_dir/Sources/AppCore/LocalizationKeys.swift"
    cat "$source_dir/Sources/AppCore/Localization.swift"
    printf '%s\n' 'LocalizationRuntime.configure(resourceRoot: URL(fileURLWithPath: ProcessInfo.processInfo.environment["BALANCEBAR_LOCALIZATION_ROOT"]!))'
    printf '%s\n' 'enum ProbeSubject {'
    printf '%s\n' "$network_error_function"
    cat <<'SWIFT'
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let languages: [AppLanguage] = [.simplifiedChinese, .traditionalChinese, .japanese, .english]

let cases: [(URLError.Code, String, String, String, String)] = [
    (.timedOut, "网络请求超时", "Network request timed out", "網路請求逾時", "ネットワークリクエストがタイムアウトしました"),
    (.notConnectedToInternet, "无网络连接", "No internet connection", "沒有網路連線", "ネットワークに接続されていません"),
    (.networkConnectionLost, "网络连接已中断", "Network connection was lost", "網路連線已中斷", "ネットワーク接続が切断されました"),
    (.cannotFindHost, "找不到主机", "Host could not be found", "找不到主機", "ホストが見つかりません"),
    (.cannotConnectToHost, "无法连接主机", "Could not connect to host", "無法連線主機", "ホストに接続できません"),
    (.secureConnectionFailed, "安全连接失败", "Secure connection failed", "安全連線失敗", "安全な接続に失敗しました")
]

for (code, simplifiedChinese, english, traditionalChinese, japanese) in cases {
    for error in [URLError(code) as Error, NSError(domain: NSURLErrorDomain, code: code.rawValue)] {
        let simplified = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .simplifiedChinese)
        let traditional = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .traditionalChinese)
        let japaneseText = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .japanese)
        let englishText = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .english)
        require(simplified == simplifiedChinese, "error \(code.rawValue) has a fixed Simplified Chinese reason")
        require(englishText == english, "error \(code.rawValue) has a fixed English reason")
        require(traditional == traditionalChinese, "error \(code.rawValue) has a fixed Traditional Chinese reason")
        require(japaneseText == japanese, "error \(code.rawValue) has a fixed Japanese reason")
    }
}

let sensitiveDescription = "secret.example.test/path?token=do-not-display"
let unknownError = NSError(
    domain: "SyntheticProbeDomain",
    code: 59,
    userInfo: [NSLocalizedDescriptionKey: sensitiveDescription]
)
let unknownURLError = NSError(
    domain: NSURLErrorDomain,
    code: -59,
    userInfo: [NSLocalizedDescriptionKey: sensitiveDescription]
)

let unknownExpected: [AppLanguage: String] = [
    .simplifiedChinese: "网络请求失败",
    .traditionalChinese: "網路請求失敗",
    .japanese: "ネットワークリクエストに失敗しました",
    .english: "Network request failed"
]

for error in [unknownError, unknownURLError] {
    for language in languages {
        let message = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: language)
        require(message == unknownExpected[language], "unknown errors use the \(language.rawValue) fallback")
        require(!message.contains(sensitiveDescription), "\(language.rawValue) fallback excludes the original description")
    }
}

print("network error localization probe: PASS; six stable URL error mappings; Simplified/Traditional/Japanese/English; unknown domain/code fallback; original descriptions excluded")
SWIFT
} | swiftc -framework Foundation -framework AppKit -o "$probe_binary" -

BALANCEBAR_LOCALIZATION_ROOT="$source_dir/lang" "$probe_binary"
