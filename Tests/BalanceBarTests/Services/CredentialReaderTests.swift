import Foundation
import XCTest
@testable import BalanceBar

final class CredentialReaderTests: XCTestCase {
    func testCredentialProcessRunnerTimesOutAndTerminatesChild() throws {
        let runner = DefaultCredentialProcessRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"), timeout: 0.05)
        let result = try runner.run(arguments: ["5"])
        XCTAssertEqual(result.terminationStatus, -1)
    }

    func testDefaultKeychainWaitCoversAnInteractivePrompt() {
        XCTAssertGreaterThanOrEqual(DefaultCredentialProcessRunner().timeout, 30)
    }

    func testAuthorizedKeychainReadDoesNotUseCooldown() {
        let runner = CountingRunner(results: [Self.keychainJSON, Self.keychainJSON])
        let reader = Self.cooldownReader(runner)
        XCTAssertEqual(reader.claudeCredentials().accessToken, "keychain-value")
        XCTAssertEqual(reader.claudeCredentials().accessToken, "keychain-value")
        XCTAssertEqual(runner.calls, 2)
    }

    func testRefusedKeychainSilencesAutomaticReadsUntilCooldownEnds() {
        let clock = MutableClock()
        let runner = CountingRunner(results: [
            CredentialProcessResult(terminationStatus: 128, standardOutput: Data()),
            Self.keychainJSON
        ])
        let reader = Self.cooldownReader(runner, clock: clock)
        XCTAssertTrue(reader.claudeCredentials().keychainUnreadable)
        XCTAssertEqual(runner.calls, 1)
        // Automatic refreshes inside the cooldown must not run `security` (no prompt).
        let during = reader.claudeCredentials()
        XCTAssertTrue(during.keychainUnreadable)
        XCTAssertNil(during.accessToken)
        XCTAssertEqual(runner.calls, 1)
        clock.now = clock.now.addingTimeInterval(KeychainPromptCooldown.defaultDuration + 1)
        XCTAssertEqual(reader.claudeCredentials().accessToken, "keychain-value")
        XCTAssertEqual(runner.calls, 2)
    }

    func testTimeoutStartsCooldownAndManualRefreshBypassesIt() {
        let runner = CountingRunner(results: [
            CredentialProcessResult(terminationStatus: -1, standardOutput: Data()),
            Self.keychainJSON
        ])
        let reader = Self.cooldownReader(runner)
        XCTAssertTrue(reader.claudeCredentials().keychainUnreadable)
        XCTAssertTrue(reader.claudeCredentials().keychainUnreadable)
        XCTAssertEqual(runner.calls, 1)
        reader.allowClaudeKeychainRetry()
        XCTAssertEqual(reader.claudeCredentials().accessToken, "keychain-value")
        XCTAssertEqual(runner.calls, 2)
    }

    func testMissingKeychainItemDoesNotStartCooldown() {
        let runner = CountingRunner(results: [
            CredentialProcessResult(terminationStatus: CredentialReader.keychainItemNotFoundStatus, standardOutput: Data()),
            CredentialProcessResult(terminationStatus: CredentialReader.keychainItemNotFoundStatus, standardOutput: Data())
        ])
        let reader = Self.cooldownReader(runner)
        XCTAssertFalse(reader.claudeCredentials().keychainUnreadable)
        XCTAssertFalse(reader.claudeCredentials().keychainUnreadable)
        XCTAssertEqual(runner.calls, 2)
    }

    private static let keychainJSON = CredentialProcessResult(
        terminationStatus: 0,
        standardOutput: Data(#"{"claudeAiOauth":{"accessToken":"keychain-value"}}"#.utf8))

    private final class MutableClock { var now = Date(timeIntervalSince1970: 1_000_000) }

    private static func cooldownReader(_ runner: CountingRunner, clock: MutableClock = MutableClock()) -> CredentialReader {
        CredentialReader(
            homeDirectoryURL: URL(fileURLWithPath: "/fixture-home"),
            fileReader: FixtureFileReader(dataByPath: [:]),
            processRunner: runner,
            keychainCooldown: KeychainPromptCooldown(now: { clock.now }))
    }

    private final class CountingRunner: CredentialProcessRunning {
        private var results: [CredentialProcessResult]
        private(set) var calls = 0
        init(results: [CredentialProcessResult]) { self.results = results }
        func run(arguments: [String]) throws -> CredentialProcessResult {
            calls += 1
            return results.isEmpty ? CredentialProcessResult(terminationStatus: 1, standardOutput: Data()) : results.removeFirst()
        }
    }

    func testCodexReaderExtractsAccessValueAndRejectsInvalidOrMissingData() {
        XCTAssertEqual(
            CredentialReader.codexAccessToken(from: Data(#"{"tokens":{"access_token":"fixture-access-value"}}"#.utf8)),
            "fixture-access-value"
        )
        XCTAssertNil(CredentialReader.codexAccessToken(from: Data(#"{"tokens":{"access_token":42}}"#.utf8)))
        XCTAssertNil(CredentialReader.codexAccessToken(from: Data("not-json".utf8)))
    }

    func testCodexReaderExtractsEmailFromIDTokenWithoutUsingTokenMaterial() {
        let idToken = Self.makeJWT(payload: #"{"email":"person@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"prolite"}}"#)
        let blankEmailToken = Self.makeJWT(payload: #"{"email":"   "}"#)
        XCTAssertEqual(
            CredentialReader.codexAccountEmail(
                from: Data("{\"tokens\":{\"id_token\":\"\(idToken)\",\"access_token\":\"secret-token\"}}".utf8)
            ),
            "person@example.com"
        )
        XCTAssertEqual(
            CredentialReader.codexAccountEmail(
                from: Data(#"{"tokens":{"id_token":{"email":"person@example.com"}}}"#.utf8)
            ),
            "person@example.com"
        )
        XCTAssertEqual(
            CredentialReader.codexAccountProfile(
                from: Data("{\"tokens\":{\"id_token\":\"\(idToken)\"}}".utf8)
            ),
            CodexAccountProfile(email: "person@example.com", planType: "prolite")
        )
        XCTAssertEqual(
            CredentialReader.codexAccountProfile(
                from: Data(#"{"tokens":{"id_token":{"email":"person@example.com","chatgpt_plan_type":"pro"}}}"#.utf8)
            ),
            CodexAccountProfile(email: "person@example.com", planType: "pro")
        )
        XCTAssertNil(
            CredentialReader.codexAccountEmail(
                from: Data("{\"tokens\":{\"id_token\":\"\(blankEmailToken)\"}}".utf8)
            )
        )
        XCTAssertNil(
            CredentialReader.codexAccountEmail(
                from: Data("{\"tokens\":{\"id_token\":\"not-a-jwt\"}}".utf8)
            )
        )

        let home = URL(fileURLWithPath: "/fixture-home")
        let authURL = home.appendingPathComponent(".codex/auth.json")
        let reader = CredentialReader(
            homeDirectoryURL: home,
            fileReader: FixtureFileReader(
                dataByPath: [
                    authURL.path: Data("{\"tokens\":{\"id_token\":\"\(idToken)\"}}".utf8)
                ]
            ),
            processRunner: FixtureProcessRunner(
                result: CredentialProcessResult(terminationStatus: 1, standardOutput: Data())
            )
        )
        XCTAssertEqual(reader.codexAccountEmail(), "person@example.com")
        XCTAssertEqual(
            reader.codexAccountProfile(),
            CodexAccountProfile(email: "person@example.com", planType: "prolite")
        )
    }

    private static func makeJWT(payload: String) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let encodedPayload = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "\(header).\(encodedPayload).signature"
    }

    func testCodexRequestCredentialsBindTokenAndNormalizedAccountFromOneAuthRead() {
        let home = URL(fileURLWithPath: "/fixture-home")
        let authURL = home.appendingPathComponent(".codex/auth.json")
        let fileReader = FixtureFileReader(dataByPath: [authURL.path: Data(#"{"tokens":{"access_token":"fixture-a","id_token":{"email":" A@Example.com "}}}"#.utf8)])
        let reader = CredentialReader(homeDirectoryURL: home, fileReader: fileReader)
        XCTAssertEqual(reader.codexRequestCredentials(), CodexRequestCredentials(accessToken: "fixture-a", accountKey: "a@example.com"))
        XCTAssertEqual(fileReader.readPaths, [authURL])
        let a = CodexRequestCredentials(accessToken: "fixture-a", accountKey: "a@example.com")
        let b = CodexRequestCredentials(accessToken: "fixture-b", accountKey: "b@example.com")
        XCTAssertNotEqual(a.requestScope, b.requestScope)
        XCTAssertFalse(a.requestScope.contains("fixture-a"))
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

    func testClaudeCredentialsReadPlanFromTheSameKeychainReadAndEmailFromClaudeJSON() {
        let home = URL(fileURLWithPath: "/fixture-home")
        let fileReader = FixtureFileReader(dataByPath: [
            home.appendingPathComponent(".claude.json").path:
                Data(#"{"oauthAccount":{"emailAddress":" person@example.com ","organizationName":"Org"},"projects":{}}"#.utf8)
        ])
        let processRunner = FixtureProcessRunner(result: CredentialProcessResult(terminationStatus: 0, standardOutput: Data(
            #"{"claudeAiOauth":{"accessToken":"keychain-value","subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#.utf8)))
        let reader = CredentialReader(homeDirectoryURL: home, fileReader: fileReader, processRunner: processRunner)

        XCTAssertEqual(reader.claudeCredentials(), ClaudeStoredCredentials(accessToken: "keychain-value", planType: "max_20x"))
        XCTAssertTrue(fileReader.readPaths.isEmpty, "token and plan come from one Keychain read")
        XCTAssertEqual(reader.claudeAccountEmail(), "person@example.com")

        func plan(_ json: String) -> String? { CredentialReader.claudePlanType(from: Data(json.utf8)) }
        XCTAssertEqual(plan(#"{"claudeAiOauth":{"subscriptionType":"pro","rateLimitTier":"default_claude_ai"}}"#), "pro")
        XCTAssertEqual(plan(#"{"claudeAiOauth":{"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#), "max_5x")
        XCTAssertEqual(plan(#"{"claudeAiOauth":{"subscriptionType":"max"}}"#), "max")
        XCTAssertNil(plan(#"{"claudeAiOauth":{"accessToken":"x"}}"#))

        func expiry(_ json: String) -> Date? { CredentialReader.claudeExpiresAt(from: Data(json.utf8)) }
        XCTAssertEqual(expiry(#"{"claudeAiOauth":{"expiresAt":1800000000000}}"#),
                       Date(timeIntervalSince1970: 1_800_000_000), "epoch milliseconds")
        XCTAssertEqual(expiry(#"{"claudeAiOauth":{"expiresAt":1800000000}}"#),
                       Date(timeIntervalSince1970: 1_800_000_000), "seconds are taken as seconds")
        XCTAssertNil(expiry(#"{"claudeAiOauth":{"accessToken":"x"}}"#))
        XCTAssertNil(expiry(#"{"claudeAiOauth":{"expiresAt":"soon"}}"#))
        XCTAssertNil(CredentialReader(homeDirectoryURL: home, fileReader: FixtureFileReader(dataByPath: [:]),
            processRunner: processRunner).claudeAccountEmail())
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

    func testClaudeCredentialsTellSignedOutApartFromUnreadableKeychain() {
        let home = URL(fileURLWithPath: "/fixture-home")
        func credentials(status: Int32, output: String = "", file: String? = nil) -> ClaudeStoredCredentials {
            let credentialsURL = home.appendingPathComponent(".claude/.credentials.json")
            return CredentialReader(
                homeDirectoryURL: home,
                fileReader: FixtureFileReader(dataByPath: file.map { [credentialsURL.path: Data($0.utf8)] } ?? [:]),
                processRunner: FixtureProcessRunner(result: CredentialProcessResult(
                    terminationStatus: status, standardOutput: Data(output.utf8)))
            ).claudeCredentials()
        }
        // Signed out: the item exists with an empty token, or there is no item at all.
        let emptyToken = credentials(status: 0, output: #"{"claudeAiOauth":{"accessToken":""}}"#)
        XCTAssertNil(emptyToken.accessToken)
        XCTAssertFalse(emptyToken.keychainUnreadable)
        XCTAssertFalse(credentials(status: CredentialReader.keychainItemNotFoundStatus).keychainUnreadable)
        // Timeout (-1), denied prompt (51) or locked keychain (36): the token may exist but was not read.
        for status: Int32 in [-1, 51, 36] {
            let unreadable = credentials(status: status)
            XCTAssertNil(unreadable.accessToken)
            XCTAssertTrue(unreadable.keychainUnreadable, "status \(status)")
        }
        // The file fallback still wins when it has a token.
        let fromFile = credentials(status: 51, file: #"{"claudeAiOauth":{"accessToken":"file-value"}}"#)
        XCTAssertEqual(fromFile.accessToken, "file-value")
        XCTAssertFalse(fromFile.keychainUnreadable)
        XCTAssertTrue(fromFile.keychainReadFailed)
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
