import Foundation
import XCTest
@testable import BalanceBar

final class UsageScriptRequestParserTests: XCTestCase {
    func testExtractsUnquotedKeyWithDoubleQuotedValue() {
        let code = #"({ request: { url: "https://api.example.com/balance" } })"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsUnquotedKeyWithSingleQuotedValue() {
        let code = #"({ request: { url: 'https://api.example.com/balance' } })"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsUnquotedKeyWithBacktickValue() {
        let code = "({ request: { url: `https://api.example.com/balance` } })"
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsDoubleQuotedKeyWithDoubleQuotedValue() {
        let code = #"({ request: { "url": "https://api.example.com/balance" } })"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsSingleQuotedKeyWithSingleQuotedValue() {
        let code = #"({ request: { 'url': 'https://api.example.com/balance' } })"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsDoubleQuotedKeyWithSingleQuotedValue() {
        let code = #"({ request: { "url": 'https://api.example.com/balance' } })"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testExtractsSingleQuotedKeyWithDoubleQuotedValue() {
        let code = #"({ request: { 'url': "https://api.example.com/balance" } })"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "https://api.example.com/balance")
    }

    func testHandlesWhitespaceAroundColon() {
        let code = #"({ request: { url   :   "https://api.example.com/balance" } })"#
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
        let code = "({ request: { method: 'GET', headers: {} } })"
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertNil(result)
    }

    func testReturnsNilForEmptyCode() {
        let result = UsageScriptRequestParser.parseRequest(from: "")
        XCTAssertNil(result)
    }

    func testExtractsURLWithPathParameters() {
        let code = #"({ request: { url: "{{baseUrl}}/api/v1/users/{userId}/balance" } })"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "{{baseUrl}}/api/v1/users/{userId}/balance")
    }

    func testExtractsURLWithQueryParameters() {
        let code = #"({ request: { url: "{{baseUrl}}/balance?format=json&detail=true" } })"#
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.urlTemplate, "{{baseUrl}}/balance?format=json&detail=true")
    }

    func testHandlesMixedQuotingInObject() {
        let code = """
        ({ "request": {
          "url": "https://api.example.com/balance",
          'method': 'POST'
        } })
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

    func testEvaluatesShorthandAndChainedDeclarations() {
        let code = """
        const root = "{{baseUrl}}".replace(/\\/v1$/, "");
        const url = root + "/v1/usage";
        ({ request: { url } })
        """
        let result = UsageScriptRequestParser.parseRequest(
            from: code,
            placeholders: ["baseUrl": "https://api.example.test/v1"]
        )
        XCTAssertEqual(result?.urlTemplate, "https://api.example.test/v1/usage")
    }

    // MARK: - Fail closed (the API key is sent to this URL)

    func testIgnoresURLFromUnrelatedObjectBeforeRequest() {
        let code = """
        const docs = { url: "https://docs.example.com" };
        ({ request: { url: "{{baseUrl}}/usage" } })
        """
        XCTAssertEqual(UsageScriptRequestParser.parseRequest(from: code)?.urlTemplate, "{{baseUrl}}/usage")
        XCTAssertNil(UsageScriptRequestParser.parseRequest(from: #"const docs = { url: "https://docs.example.com" };"#))
        let unevaluable = """
        const docs = { url: "https://docs.example.com" };
        ({ request: { url: readURL() } })
        """
        XCTAssertNil(UsageScriptRequestParser.parseRequest(from: unevaluable))
    }

    func testPreservesLegacyTopLevelURLSyntax() {
        let cases = [
            #"url: "{{baseUrl}}/balance""#,
            #"url: '{{baseUrl}}/balance'"#,
            #""url": "{{baseUrl}}/balance""#,
            #"'url': '{{baseUrl}}/balance'"#
        ]
        for code in cases {
            XCTAssertEqual(
                UsageScriptRequestParser.parseRequest(
                    from: code,
                    placeholders: ["baseUrl": "https://api.example.com"]
                )?.urlTemplate,
                "https://api.example.com/balance",
                code
            )
        }
    }

    func testPreservesLegacyTopLevelComputedURLSyntax() {
        let code = """
        const base = "{{baseUrl}}";
        url: base + "/v1/usage";
        """
        XCTAssertEqual(
            UsageScriptRequestParser.parseRequest(
                from: code,
                placeholders: ["baseUrl": "https://api.example.com"]
            )?.urlTemplate,
            "https://api.example.com/v1/usage"
        )
    }

    func testRequiresStructuredRequestOrTopLevelLegacyURL() {
        XCTAssertNil(UsageScriptRequestParser.parseRequest(from: #"{ "url": "https://api.example.com/balance" }"#))
    }

    func testDoesNotUseCommentedOrStringEmbeddedURLAsFallback() {
        let code = """
        // request: { url: "https://commented.example" }
        const note = "request: { url: 'https://string.example' }";
        const u = `url: "{{baseUrl}}/v1/usage"`;
        ({ extractor: function(response) { return response; } })
        """
        XCTAssertNil(UsageScriptRequestParser.parseRequest(from: code))
    }

    func testFailsInsteadOfTruncatingUnevaluableURL() {
        let concatenated = #"({ request: { url: "{{baseUrl}}/api/user/self?id=" + userId } })"#
        XCTAssertNil(UsageScriptRequestParser.parseRequest(from: concatenated))
        let interpolated = "({ request: { url: `{{baseUrl}}/users/${userId}/balance` } })"
        XCTAssertNil(UsageScriptRequestParser.parseRequest(from: interpolated))
        let fallback = #"({ request: { url: "{{baseUrl}}/a" || other } })"#
        XCTAssertNil(UsageScriptRequestParser.parseRequest(from: fallback))
    }

    func testFailsOnAmbiguousRequestShape() {
        let cases = [
            #"({ request: { url: "{{baseUrl}}/a" } }); ({ request: { url: "https://evil.example" } })"#,
            #"fetch({ url: "https://evil.example" }); ({ request: { url: "{{baseUrl}}/a" } })"#,
            #"({ request: { url: "{{baseUrl}}/a", url: "https://evil.example" } })"#,
            #"({ request: { ...overrides, url: "{{baseUrl}}/a" } })"#,
            #"({ request: { url: "{{baseUrl}}/a" } "#,
            "({ request: (() => { return\n { url: \"{{baseUrl}}/a\" }; })() })"
        ]
        for code in cases {
            XCTAssertNil(UsageScriptRequestParser.parseRequest(from: code), code)
        }
    }

    func testIgnoresDeclarationInsideUnrelatedFunction() {
        let helperOnly = """
        function helper() { const base = "https://wrong.example"; return base; }
        ({ request: { url: base + "/usage" } })
        """
        XCTAssertNil(UsageScriptRequestParser.parseRequest(from: helperOnly))
        let withTopLevel = """
        function helper() { const base = "https://wrong.example"; return base; }
        const base = "{{baseUrl}}";
        ({ request: { url: base + "/usage" } })
        """
        XCTAssertEqual(UsageScriptRequestParser.parseRequest(from: withTopLevel)?.urlTemplate, "{{baseUrl}}/usage")
    }

    func testInnerDeclarationShadowsOuter() {
        let code = """
        const base = "https://outer.example";
        ({ request: (() => { const base = "{{baseUrl}}"; return { url: base + "/u" }; })() })
        """
        XCTAssertEqual(UsageScriptRequestParser.parseRequest(from: code)?.urlTemplate, "{{baseUrl}}/u")
    }

    func testFailsWhenBindingCouldDifferAtRuntime() {
        let cases = [
            "let base = \"{{baseUrl}}\";\nbase = \"https://evil.example\";\n({ request: { url: base } })",
            "let base = \"{{baseUrl}}\";\nbase += \"/evil\";\n({ request: { url: base } })",
            "({ request: { url: base } })\nconst base = \"{{baseUrl}}\";",
            "var base = \"{{baseUrl}}\";\nvar base = \"https://evil.example\";\n({ request: { url: base } })",
            "const base = \"{{baseUrl}}\";\nif (x) { var base = \"https://evil.example\"; }\n({ request: { url: base } })",
            "const base = \"{{baseUrl}}\";\n({ request: ((base) => ({ url: base }))(\"https://evil.example\") })",
            "const base = \"{{baseUrl}}\";\nconst f = base => base;\n({ request: { url: base } })",
            "const base = \"{{baseUrl}}\";\ntry {} catch (base) {}\n({ request: { url: base } })",
            "const base = \"{{baseUrl}}\";\nconst { base: b } = x;\n({ request: { url: base } })",
            "for (let base = \"x\"; ;) {}\n({ request: { url: base } })",
            "const base = \"{{baseUrl}}\" || other;\n({ request: { url: base } })",
            """
            const base = "{{baseUrl}}";
            ({ request: (() => { const u = base + "/u"; const base = "x"; return { url: u }; })() })
            """
        ]
        for code in cases {
            XCTAssertNil(UsageScriptRequestParser.parseRequest(from: code), code)
        }
    }

    func testRegexLiteralsDoNotConfuseStructure() {
        let code = """
        const n = total / 2;
        const base = "{{baseUrl}}".replace(/[{"]/g, "");
        ({ request: { url: base + "/r" } })
        """
        let result = UsageScriptRequestParser.parseRequest(
            from: code,
            placeholders: ["baseUrl": "https://api.example.test"]
        )
        XCTAssertEqual(result?.urlTemplate, "https://api.example.test/r")
    }

    func testExtractsHeadersAndDropsUnevaluableValues() {
        let code = """
        ({ request: {
          url: "{{baseUrl}}/u",
          headers: {
            "Authorization": "Bearer {{apiKey}}",
            "New-Api-User": readUserId(),
            Accept: 'application/json',
          }
        } })
        """
        let result = UsageScriptRequestParser.parseRequest(from: code)
        XCTAssertEqual(result?.headers, [
            "Authorization": "Bearer {{apiKey}}",
            "Accept": "application/json"
        ])
    }

    func testRegexReplaceSupportsJavaScriptReplacementTokens() {
        let code = #"({ request: { url: "{{baseUrl}}".replace(/v1/, "[$&]$$") } })"#
        let result = UsageScriptRequestParser.parseRequest(
            from: code,
            placeholders: ["baseUrl": "https://a.test/v1"]
        )
        XCTAssertEqual(result?.urlTemplate, "https://a.test/[v1]$")
    }
}
