import Foundation

struct StatusLink: Equatable {
    var title: String
    var url: String
    var enabled: Bool

    init(title: String, url: String, enabled: Bool = true) {
        self.title = title
        self.url = url
        self.enabled = enabled
    }
}

extension StatusLink: Codable {
    private enum CodingKeys: String, CodingKey {
        case title
        case url
        case enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        // Links written before the enabled switch existed remain active.
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(enabled, forKey: .enabled)
    }
}

extension StatusLink {
    /// The menu bar is the current status-link consumer. Keep the filtering
    /// rule in the value-model subsystem so every consumer can share it.
    static func enabledLinks(from links: [StatusLink]) -> [StatusLink] {
        links.filter(\.enabled)
    }
}
