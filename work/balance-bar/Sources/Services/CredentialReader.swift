import Foundation

struct CredentialProcessResult {
    let terminationStatus: Int32
    let standardOutput: Data
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

    func codexAccountID() -> String? {
        let authURL = homeDirectoryURL.appendingPathComponent(".codex/auth.json")
        guard let data = try? fileReader.readData(from: authURL) else { return nil }
        return Self.codexAccountID(from: data)
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

    static func codexAccountID(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accountID = tokens["account_id"] as? String else { return nil }
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
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
