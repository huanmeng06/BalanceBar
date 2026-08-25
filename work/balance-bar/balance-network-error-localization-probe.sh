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

let languages: [AppLanguage] = [
    .simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong, .japanese, .english,
    .korean, .spanish, .german, .french
]

let cases: [(URLError.Code, String, String, String, String, String, String, String, String, String)] = [
    (.timedOut, "网络请求超时", "Network request timed out", "網路請求逾時", "網絡請求逾時", "ネットワークリクエストがタイムアウトしました", "네트워크 요청 시간이 초과되었습니다", "La solicitud de red agotó el tiempo de espera", "Zeitüberschreitung bei der Netzwerkanfrage", "La requête réseau a expiré"),
    (.notConnectedToInternet, "无网络连接", "No internet connection", "沒有網路連線", "沒有網絡連線", "ネットワークに接続されていません", "인터넷 연결 없음", "No hay conexión a Internet", "Keine Internetverbindung", "Aucune connexion Internet"),
    (.networkConnectionLost, "网络连接已中断", "Network connection was lost", "網路連線已中斷", "網絡連線已中斷", "ネットワーク接続が切断されました", "네트워크 연결이 끊겼습니다", "Se perdió la conexión de red", "Netzwerkverbindung verloren", "La connexion réseau a été interrompue"),
    (.cannotFindHost, "找不到主机", "Host could not be found", "找不到主機", "找不到主機", "ホストが見つかりません", "호스트를 찾을 수 없습니다", "No se encontró el host", "Host konnte nicht gefunden werden", "Hôte introuvable"),
    (.cannotConnectToHost, "无法连接主机", "Could not connect to host", "無法連線主機", "無法連線主機", "ホストに接続できません", "호스트에 연결할 수 없습니다", "No se pudo conectar al host", "Verbindung zum Host konnte nicht hergestellt werden", "Impossible de se connecter à l’hôte"),
    (.secureConnectionFailed, "安全连接失败", "Secure connection failed", "安全連線失敗", "安全連線失敗", "安全な接続に失敗しました", "보안 연결에 실패했습니다", "La conexión segura falló", "Sichere Verbindung fehlgeschlagen", "Échec de la connexion sécurisée")
]

for (code, simplifiedChinese, english, traditionalChineseTaiwan, traditionalChineseHongKong, japanese, korean, spanish, german, french) in cases {
    for error in [URLError(code) as Error, NSError(domain: NSURLErrorDomain, code: code.rawValue)] {
        let simplified = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .simplifiedChinese)
        let traditionalTaiwan = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .traditionalChineseTaiwan)
        let traditionalHongKong = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .traditionalChineseHongKong)
        let japaneseText = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .japanese)
        let englishText = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .english)
        let koreanText = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .korean)
        let spanishText = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .spanish)
        let germanText = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .german)
        let frenchText = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: .french)
        require(simplified == simplifiedChinese, "error \(code.rawValue) has a fixed Simplified Chinese reason")
        require(englishText == english, "error \(code.rawValue) has a fixed English reason")
        require(traditionalTaiwan == traditionalChineseTaiwan, "error \(code.rawValue) has a fixed Taiwan Traditional Chinese reason")
        require(traditionalHongKong == traditionalChineseHongKong, "error \(code.rawValue) has a fixed Hong Kong Traditional Chinese reason")
        require(japaneseText == japanese, "error \(code.rawValue) has a fixed Japanese reason")
        require(koreanText == korean, "error \(code.rawValue) has a fixed Korean reason")
        require(spanishText == spanish, "error \(code.rawValue) has a fixed Spanish reason")
        require(germanText == german, "error \(code.rawValue) has a fixed German reason")
        require(frenchText == french, "error \(code.rawValue) has a fixed French reason")
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
    .traditionalChineseTaiwan: "網路請求失敗",
    .traditionalChineseHongKong: "網絡請求失敗",
    .japanese: "ネットワークリクエストに失敗しました",
    .english: "Network request failed",
    .korean: "네트워크 요청 실패",
    .spanish: "La solicitud de red falló",
    .german: "Netzwerkanfrage fehlgeschlagen",
    .french: "Échec de la requête réseau"
]

for error in [unknownError, unknownURLError] {
    for language in languages {
        let message = ProbeSubject.localizedBalanceNetworkErrorReason(error, language: language)
        require(message == unknownExpected[language], "unknown errors use the \(language.rawValue) fallback")
        require(!message.contains(sensitiveDescription), "\(language.rawValue) fallback excludes the original description")
    }
}

print("network error localization probe: PASS; six stable URL error mappings; all nine concrete languages; unknown domain/code fallback; original descriptions excluded")
SWIFT
} | swiftc -framework Foundation -framework AppKit -o "$probe_binary" -

BALANCEBAR_LOCALIZATION_ROOT="$source_dir/lang" "$probe_binary"
