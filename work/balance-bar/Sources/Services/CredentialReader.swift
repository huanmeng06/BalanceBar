import Foundation

struct CredentialProcessResult {
    let terminationStatus: Int32
    let standardOutput: Data
}

struct CodexAccountProfile: Equatable {
    let email: String?
    let planType: String?
}

protocol CredentialFileReading {
    func readData(from url: URL) throws -> Data
}

protocol CredentialProcessRunning {
    func run(arguments: [String]) throws -> CredentialProcessResult
}

struct DefaultCredentialFileReader: CredentialFileReading {
    func readData(from url: URL) throws -> Data { try Data(contentsOf: url) }
}

struct DefaultCredentialProcessRunner: CredentialProcessRunning {
    let executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/security")) {
        self.executableURL = executableURL
    }

    func run(arguments: [String]) throws -> CredentialProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CredentialProcessResult(terminationStatus: process.terminationStatus, standardOutput: data)
    }
}

struct CredentialReader {
    private let homeDirectoryURL: URL
    private let fileReader: CredentialFileReading
    private let processRunner: CredentialProcessRunning

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileReader: CredentialFileReading = DefaultCredentialFileReader(),
        processRunner: CredentialProcessRunning = DefaultCredentialProcessRunner()
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.fileReader = fileReader
        self.processRunner = processRunner
    }

    func codexAccessToken() -> String? {
        let authURL = homeDirectoryURL.appendingPathComponent(".codex/auth.json")
        guard let data = try? fileReader.readData(from: authURL) else { return nil }
        return Self.codexAccessToken(from: data)
    }

    func codexAccountEmail() -> String? {
        codexAccountProfile()?.email
    }

    func codexAccountProfile() -> CodexAccountProfile? {
        let authURL = homeDirectoryURL.appendingPathComponent(".codex/auth.json")
        guard let data = try? fileReader.readData(from: authURL) else { return nil }
        return Self.codexAccountProfile(from: data)
    }

    func claudeAccessToken() -> String? {
        if let result = try? processRunner.run(arguments: [
            "find-generic-password", "-s", "Claude Code-credentials", "-w"
        ]), result.terminationStatus == 0,
           let token = Self.claudeAccessToken(from: result.standardOutput) {
            return token
        }

        let credentialsURL = homeDirectoryURL.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? fileReader.readData(from: credentialsURL) else { return nil }
        return Self.claudeAccessToken(from: data)
    }

    static func codexAccessToken(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else { return nil }
        return token
    }

    static func codexAccountEmail(from data: Data) -> String? {
        codexAccountProfile(from: data)?.email
    }

    static func codexAccountProfile(from data: Data) -> CodexAccountProfile? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any] else { return nil }
        let claims: [String: Any]?
        if let idToken = tokens["id_token"] as? String {
            claims = Self.jwtPayload(fromIDToken: idToken)
        } else {
            claims = tokens["id_token"] as? [String: Any]
        }
        guard let claims else { return nil }
        let email = (claims["email"] as? String).flatMap(Self.normalizedEmail)
        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any]
        let planType = (
            claims["chatgpt_plan_type"] as? String
                ?? authClaims?["chatgpt_plan_type"] as? String
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexAccountProfile(
            email: email,
            planType: planType?.isEmpty == true ? nil : planType
        )
    }

    static func codexAccountEmail(fromIDToken idToken: String) -> String? {
        guard let claims = Self.jwtPayload(fromIDToken: idToken),
              let email = claims["email"] as? String else { return nil }
        return Self.normalizedEmail(email)
    }

    private static func jwtPayload(fromIDToken idToken: String) -> [String: Any]? {
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }

        var encodedPayload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encodedPayload.count % 4) % 4
        encodedPayload += String(repeating: "=", count: padding)

        guard let payloadData = Data(base64Encoded: encodedPayload) else { return nil }
        return try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
    }

    private static func normalizedEmail(_ email: String) -> String? {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.contains("@"),
              !normalized.contains(where: { $0.isWhitespace }) else { return nil }
        return normalized
    }

    static func claudeAccessToken(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let oauth = (object["claudeAiOauth"] as? [String: Any])
            ?? (object["claude.ai_oauth"] as? [String: Any])
        guard let token = oauth?["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}
