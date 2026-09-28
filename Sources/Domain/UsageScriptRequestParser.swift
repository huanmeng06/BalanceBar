import Foundation

/// Parses CC Switch Usage Script request configuration
struct UsageScriptRequestParser {
    struct ParsedRequest {
        let urlTemplate: String
        let method: String?
        let headers: [String: String]

        init(urlTemplate: String, method: String? = nil, headers: [String: String] = [:]) {
            self.urlTemplate = urlTemplate
            self.method = method
            self.headers = headers
        }
    }

    /// Extract request URL from CC Switch usage script code
    ///
    /// Supports multiple formats:
    /// - `url: "..."`
    /// - `url: '...'`
    /// - `url: `...``
    /// - `"url": "..."`
    /// - `'url': '...'`
    /// - fetch({ url: "..." })
    ///
    /// Returns nil if no URL pattern is found
    static func parseRequest(from code: String) -> ParsedRequest? {
        guard let urlTemplate = extractURL(from: code) else {
            return nil
        }
        return ParsedRequest(urlTemplate: urlTemplate)
    }

    private static func extractURL(from code: String) -> String? {
        // Try multiple patterns in order of specificity
        let patterns = [
            // Quoted key with double-quote value: "url": "..."
            #"["\']url["\']\s*:\s*"([^"]+)""#,
            // Quoted key with single-quote value: "url": '...'
            #"["\']url["\']\s*:\s*'([^']+)'"#,
            // Quoted key with backtick value: "url": `...`
            #"["\']url["\']\s*:\s*`([^`]+)`"#,
            // Unquoted key with double-quote value: url: "..."
            #"url\s*:\s*"([^"]+)""#,
            // Unquoted key with single-quote value: url: '...'
            #"url\s*:\s*'([^']+)'"#,
            // Unquoted key with backtick value: url: `...`
            #"url\s*:\s*`([^`]+)`"#,
        ]

        for pattern in patterns {
            if let match = capture(pattern, in: code) {
                return match
            }
        }

        return nil
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
