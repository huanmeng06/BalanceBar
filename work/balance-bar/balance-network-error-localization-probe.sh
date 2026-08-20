#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-network-error-localization-probe.XXXXXX")"
probe_binary="$probe_dir/network-error-localization-probe"
trap 'rm -rf "$probe_dir"' EXIT

{
    printf '%s\n' 'import Foundation' 'enum ProbeSubject {'
    awk '
        /^    static func localizedBalanceNetworkErrorReason\(/ { capture = 1 }
        capture {
            print
            if (seen) exit
            if (/^        return usesSimplifiedChinese/) seen = 1
        }
    ' "$source_dir/Sources/Services/ProviderRefreshCoordinator.swift"
    cat <<'SWIFT'
    static func reason(_ error: Error, usesSimplifiedChinese: Bool) -> String {
        localizedBalanceNetworkErrorReason(
            error,
            usesSimplifiedChinese: usesSimplifiedChinese
        )
    }
}
SWIFT
    cat <<'SWIFT'

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let cases: [(URLError.Code, String, String)] = [
    (.timedOut, "网络请求超时", "Network request timed out"),
    (.notConnectedToInternet, "无网络连接", "No internet connection"),
    (.networkConnectionLost, "网络连接已中断", "Network connection was lost"),
    (.cannotFindHost, "找不到主机", "Host could not be found"),
    (.cannotConnectToHost, "无法连接主机", "Could not connect to host"),
    (.secureConnectionFailed, "安全连接失败", "Secure connection failed")
]

for (code, simplifiedChinese, english) in cases {
    let urlError = URLError(code)
    require(
        ProbeSubject.reason(
            urlError,
            usesSimplifiedChinese: true
        ) == simplifiedChinese,
        "URLError \(code.rawValue) has a fixed Simplified Chinese reason"
    )
    require(
        ProbeSubject.reason(
            NSError(domain: NSURLErrorDomain, code: code.rawValue),
            usesSimplifiedChinese: false
        ) == english,
        "NSError \(code.rawValue) has a fixed English reason"
    )
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

for error in [unknownError, unknownURLError] {
    let simplifiedChinese = ProbeSubject.reason(
        error,
        usesSimplifiedChinese: true
    )
    let english = ProbeSubject.reason(
        error,
        usesSimplifiedChinese: false
    )
    require(simplifiedChinese == "网络请求失败", "unknown errors use the Chinese fallback")
    require(english == "Network request failed", "unknown errors use the English fallback")
    require(!simplifiedChinese.contains(sensitiveDescription), "Chinese fallback excludes the original description")
    require(!english.contains(sensitiveDescription), "English fallback excludes the original description")
}

print("network error localization probe: PASS; six stable URL error mappings; Simplified Chinese and English; unknown domain/code fallback; original descriptions excluded")
SWIFT
} | swiftc -framework Foundation -o "$probe_binary" -

"$probe_binary"
