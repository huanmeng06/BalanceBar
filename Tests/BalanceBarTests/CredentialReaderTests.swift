import Foundation
import XCTest
@testable import BalanceBar

final class CredentialReaderTests: XCTestCase {
    func testCodexReaderExtractsAccessValueAndRejectsInvalidOrMissingData() {
        XCTAssertEqual(
            CredentialReader.codexAccessToken(from: Data(#"{"tokens":{"access_token":"fixture-access-value"}}"#.utf8)),
            "fixture-access-value"
        )
        XCTAssertNil(CredentialReader.codexAccessToken(from: Data(#"{"tokens":{"access_token":42}}"#.utf8)))
        XCTAssertNil(CredentialReader.codexAccessToken(from: Data("not-json".utf8)))
    }

    func testClaudeReaderPrefersKeychainAndSupportsBothCredentialKeys() {
        let fileReader = FixtureFileReader(dataByPath: [:])
        let processRunner = FixtureProcessRunner(
            result: CredentialProcessResult(
                terminationStatus: 0,
                standardOutput: Data(#"{"claudeAiOauth":{"accessToken":"keychain-value"}}"#.utf8)
            )
        )
        let reader = CredentialReader(
            homeDirectoryURL: URL(fileURLWithPath: "/fixture-home"),
            fileReader: fileReader,
            processRunner: processRunner
        )

        XCTAssertEqual(reader.claudeAccessToken(), "keychain-value")
        XCTAssertTrue(fileReader.readPaths.isEmpty)
        XCTAssertEqual(processRunner.arguments, ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        XCTAssertEqual(
            CredentialReader.claudeAccessToken(from: Data(#"{"claude.ai_oauth":{"accessToken":"file-value"}}"#.utf8)),
            "file-value"
        )
    }

    func testClaudeReaderFallsBackToFileAfterKeychainFailure() {
        let home = URL(fileURLWithPath: "/fixture-home")
        let credentialsURL = home.appendingPathComponent(".claude/.credentials.json")
        let fileReader = FixtureFileReader(dataByPath: [
            credentialsURL.path: Data(#"{"claudeAiOauth":{"accessToken":"file-value"}}"#.utf8)
        ])
        let reader = CredentialReader(
            homeDirectoryURL: home,
            fileReader: fileReader,
            processRunner: FixtureProcessRunner(result: CredentialProcessResult(terminationStatus: 1, standardOutput: Data()))
        )

        XCTAssertEqual(reader.claudeAccessToken(), "file-value")
        XCTAssertEqual(fileReader.readPaths, [credentialsURL])
    }

    func testReadersUseInjectedHomeAndReturnNilForMissingCredentials() {
        let home = URL(fileURLWithPath: "/fixture-home")
        let fileReader = FixtureFileReader(dataByPath: [:])
        let reader = CredentialReader(
            homeDirectoryURL: home,
            fileReader: fileReader,
            processRunner: FixtureProcessRunner(result: CredentialProcessResult(terminationStatus: 1, standardOutput: Data()))
        )

        XCTAssertNil(reader.codexAccessToken())
        XCTAssertNil(reader.claudeAccessToken())
        XCTAssertEqual(fileReader.readPaths.map(\.path), [home.appendingPathComponent(".codex/auth.json").path, home.appendingPathComponent(".claude/.credentials.json").path])
    }

    private final class FixtureFileReader: CredentialFileReading {
        let dataByPath: [String: Data]
        private(set) var readPaths: [URL] = []

        init(dataByPath: [String: Data]) { self.dataByPath = dataByPath }

        func readData(from url: URL) throws -> Data {
            readPaths.append(url)
            guard let data = dataByPath[url.path] else {
                throw CocoaError(.fileNoSuchFile)
            }
            return data
        }
    }

    private final class FixtureProcessRunner: CredentialProcessRunning {
        let result: CredentialProcessResult
        private(set) var arguments: [String] = []

        init(result: CredentialProcessResult) { self.result = result }

        func run(arguments: [String]) throws -> CredentialProcessResult {
            self.arguments = arguments
            return result
        }
    }
}
