import Foundation
import XCTest
@testable import BalanceBar

final class UsageScriptRequestParserTests: XCTestCase {
    func testExtractsUnquotedKeyWithDoubleQuotedValue() {
        let code = #"url: "https://api.example.com/balance""#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsUnquotedKeyWithSingleQuotedValue() {
        let code = #"url: 'https://api.example.com/balance'"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsUnquotedKeyWithBacktickValue() {
        let code = "url: `https://api.example.com/balance`"
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsDoubleQuotedKeyWithDoubleQuotedValue() {
        let code = #""url": "https://api.example.com/balance""#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsSingleQuotedKeyWithSingleQuotedValue() {
        let code = #"'url': 'https://api.example.com/balance'"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsDoubleQuotedKeyWithSingleQuotedValue() {
        let code = #""url": 'https://api.example.com/balance'"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsSingleQuotedKeyWithDoubleQuotedValue() {
        let code = #"'url': "https://api.example.com/balance""#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testHandlesWhitespaceAroundColon() {
        let code = #"url   :   "https://api.example.com/balance""#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testHandlesNewlinesAndIndentation() {
        let code = """
        ({
          request: {
            url: "https://api.example.com/balance",
            method: "GET"
          }
        })
        """
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsFromCCSwitchGenericTemplate() {
        // This is the actual format from CC Switch UI for third-party providers
        let code = """
        ({
          request: {
            url: "{{baseUrl}}/user/balance",
            method: "GET",
            headers: {
              "Authorization": "Bearer {{apiKey}}",
              "User-Agent": "cc-switch/1.0"
            }
          },
          extractor: function(response) {
            return {
              isValid: response.is_active || true,
              remaining: response.balance,
              unit: "USD"
            };
          }
        })
        """
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "{{baseUrl}}/user/balance")
    }

    func testExtractsFromFetchStyle() {
        let code = #"fetch({ url: "{{baseUrl}}/v1/usage" })"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "{{baseUrl}}/v1/usage")
    }

    func testReturnsNilWhenNoURLFound() {
        let code = "{ method: 'GET', headers: {} }"
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertNil(result)
    }

    func testReturnsNilForEmptyCode() {
        let result = UsageScriptRequestParser.parseRequest(from: "")
        XCTAssertNil(result)
    }

    func testExtractsURLWithPathParameters() {
        let code = #"url: "{{baseUrl}}/api/v1/users/{userId}/balance""#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "{{baseUrl}}/api/v1/users/{userId}/balance")
    }

    func testExtractsURLWithQueryParameters() {
        let code = #"url: "{{baseUrl}}/balance?format=json&detail=true""#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "{{baseUrl}}/balance?format=json&detail=true")
    }

    func testHandlesMixedQuotingInObject() {
        let code = """
        {
          "url": "https://api.example.com/balance",
          'method': 'POST'
        }
        """
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    // MARK: - Computed URLs (issue #484 follow-up)

    private let iifeScript = """
    ({
        request: (() => {
          const base = "{{baseUrl}}".replace(/\\/+$/, "").replace(/\\/v1$/i, "");
          return {
            url: base + "/v1/usage",
            method: "GET",
            headers: { "Authorization": "Bearer {{apiKey}}" }
          };
        })(),
        extractor: function(response) {
          const remaining = response?.remaining ?? response?.quota?.remaining ?? response?.balance;
          return { isValid: true, remaining, unit: "USD" };
        }
      })
    """

    func testEvaluatesIIFEWithReplacedBaseVariable() {
        let result = UsageScriptRequestParser.parseRequest(
            from: iifeScript,
            placeholders: ["baseUrl": "https://api.example.test/v1"]
        )
        XCTAssertEqual(result?.urlTemplate, "https://api.example.test/v1/usage")
        XCTAssertEqual(result?.method, "GET")
    }

    func testEvaluatesIIFEWithoutV1Suffix() {
        let result = UsageScriptRequestParser.parseRequest(
            from: iifeScript,
            placeholders: ["baseUrl": "https://api.example.test"]
        )
        XCTAssertEqual(result?.urlTemplate, "https://api.example.test/v1/usage")
    }

    func testEvaluatesTemplateLiteralInterpolation() {
        let code = """
        const base = "{{baseUrl}}";
        ({ request: { url: `${base}/api/usage?unit=${"usd"}` } })
        """
        let result = UsageScriptRequestParser.parseRequest(
            from: code,
            placeholders: ["baseUrl": "https://api.example.test"]
        )
        XCTAssertEqual(result?.urlTemplate, "https://api.example.test/api/usage?unit=usd")
    }

    func testEvaluatesStringReplaceAndParentheses() {
        let code = #"({ request: { url: ("{{baseUrl}}".replace("/api", "") + '/balance').trim() } })"#
        let result = UsageScriptRequestParser.parseRequest(
            from: code,
            placeholders: ["baseUrl": "https://example.test/api"]
        )
        XCTAssertEqual(result?.urlTemplate, "https://example.test/balance")
    }

    func testReturnsNilForUnresolvableIdentifier() {
        let code = #"({ request: { url: unknownBase + "/usage" } })"#
        XCTAssertNil(UsageScriptRequestParser.parseRequest(from: code))
    }

    func testDoesNotTreatBaseUrlKeyAsURL() {
        let code = #"({ request: { baseUrl: "https://wrong.example", url: "{{baseUrl}}/ok" } })"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "{{baseUrl}}/ok")
    }

    func testIgnoresCommentsAroundURL() {
        let code = """
        ({ request: {
          // url: "https://commented.example"
          url: /* inline */ "{{baseUrl}}/balance",
          method: 'post'
        } })
        """
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "{{baseUrl}}/balance")
        XCTAssertEqual(result?.method, "POST")
    }
}
