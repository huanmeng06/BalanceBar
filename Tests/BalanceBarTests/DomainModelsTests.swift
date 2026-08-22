import Foundation
import XCTest
@testable import BalanceBar

final class DomainModelsTests: XCTestCase {
    func testAssistantClientAndStatusLinkValueModels() throws {
        XCTAssertEqual(AssistantClient.codex.appType, "codex")
        XCTAssertEqual(AssistantClient.codex.displayName, "Codex")
        XCTAssertEqual(AssistantClient.claude.appType, "claude")
        XCTAssertEqual(AssistantClient.claude.displayName, "Claude Code")

        let link = StatusLink(title: "Status", url: "https://status.example")
        XCTAssertEqual(link, StatusLink(title: "Status", url: "https://status.example"))
        let encoded = try JSONEncoder().encode(link)
        XCTAssertEqual(try JSONDecoder().decode(StatusLink.self, from: encoded), link)
    }

    func testOpenAIAccountPresentationUsesOnlyTheCurrentOfficialCodexProvider() {
        let available = OpenAIAccountPresentation.current(
            activeClient: .codex,
            providerIsOfficial: true,
            email: "person@example.com"
        )
        XCTAssertEqual(available?.state, .available("person@example.com"))
        XCTAssertEqual(available?.text(language: .simplifiedChinese), "person@example.com")
        XCTAssertEqual(available?.text(language: .traditionalChinese), "person@example.com")
        XCTAssertEqual(available?.text(language: .japanese), "person@example.com")
        XCTAssertEqual(available?.text(language: .english), "person@example.com")

        let unavailable = OpenAIAccountPresentation.current(
            activeClient: .codex,
            providerIsOfficial: true,
            email: nil
        )
        XCTAssertEqual(unavailable?.state, .unavailable)
        XCTAssertEqual(unavailable?.text(language: .simplifiedChinese), "账号不可用")
        XCTAssertEqual(unavailable?.text(language: .traditionalChinese), "帳號不可用")
        XCTAssertEqual(unavailable?.text(language: .japanese), "アカウントを利用できません")
        XCTAssertEqual(unavailable?.text(language: .english), "Account unavailable")

        XCTAssertNil(
            OpenAIAccountPresentation.current(
                activeClient: .claude,
                providerIsOfficial: true,
                email: "should-not-leak@example.com"
            )
        )
        XCTAssertNil(
            OpenAIAccountPresentation.current(
                activeClient: .codex,
                providerIsOfficial: false,
                email: "should-not-leak@example.com"
            )
        )
    }

    func testPlaceholderAndOfficialSnapshotFormatting() {
        let placeholder = Snapshot.placeholder
        XCTAssertEqual(placeholder.kind, .placeholder)
        XCTAssertEqual(placeholder.menuBarTitle, " …")
        XCTAssertEqual(placeholder.menuBarPrimary, "…")
        XCTAssertEqual(placeholder.menuBarSecondary, "")
        XCTAssertEqual(placeholder.overviewProvider, "CC Switch")
        XCTAssertEqual(placeholder.overviewQuotaTitle, tr("额度状态", "Balance Status", "額度狀態", "残高ステータス"))
        XCTAssertEqual(placeholder.overviewQuotaDetail, tr("等待刷新", "Waiting to Refresh", "等待重新整理", "更新待ち"))
        XCTAssertEqual(placeholder.overviewLargeAmount, "—")
        XCTAssertNil(placeholder.progressPercentage)
        XCTAssertEqual(placeholder.title, tr("正在读取 CC Switch…", "Loading CC Switch…", "正在讀取 CC Switch…", "CC Switch を読み込み中…"))
        XCTAssertEqual(placeholder.compactQuotaTitle, tr("正在读取 CC Switch…", "Loading CC Switch…", "正在讀取 CC Switch…", "CC Switch を読み込み中…"))
        XCTAssertEqual(placeholder.compactResetTitle, "")
        XCTAssertEqual(placeholder.detail, tr("等待 CC Switch 状态", "Waiting for CC Switch Status", "等待 CC Switch 狀態", "CC Switch のステータスを待機中"))

        let official = Snapshot.official(
            "OpenAI",
            87.6,
            "7-Day Quota",
            "2 hours",
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(official.menuBarTitle, " 87%")
        XCTAssertEqual(official.menuBarPrimary, "87%")
        XCTAssertEqual(official.menuBarSecondary, "2 hours")
        XCTAssertEqual(
            official.menuBarToolTip,
            tr(
                "OpenAI 剩余：87%（7-Day Quota） · 重置：2 hours",
                "OpenAI remaining: 87% (7-Day Quota) · Reset: 2 hours",
                "OpenAI 剩餘：87%（7-Day Quota） · 重設：2 hours",
                "OpenAI の残り：87%（7-Day Quota） · リセット：2 hours"
            )
        )
        XCTAssertEqual(official.overviewProvider, "OpenAI")
        XCTAssertEqual(
            official.overviewReset(refreshDate: nil, formatter: DateFormatter()),
            tr("重置：2 hours", "Reset: 2 hours", "重設：2 hours", "リセット：2 hours")
        )
        XCTAssertEqual(official.overviewQuotaTitle, tr("可用额度", "Available Quota", "可用額度", "利用可能なクォータ"))
        XCTAssertEqual(official.overviewQuotaDetail, "7-Day Quota")
        XCTAssertEqual(official.overviewLargeAmount, "87%")
        XCTAssertEqual(official.progressPercentage, 87.6)
        XCTAssertEqual(
            official.compactQuotaTitle,
            tr("7-Day Quota剩余：87%", "7-Day Quota remaining: 87%", "7-Day Quota剩餘：87%", "7-Day Quota の残り：87%")
        )
        XCTAssertEqual(
            official.compactResetTitle,
            tr("重置：2 hours", "Reset: 2 hours", "重設：2 hours", "リセット：2 hours")
        )
        XCTAssertEqual(
            official.detail,
            tr(
                "每分钟更新官方额度 · 重置：2 hours",
                "Official quota updates every minute · Reset: 2 hours",
                "每分鐘更新官方額度 · 重設：2 hours",
                "公式クォータは毎分更新 · リセット：2 hours"
            )
        )
    }

    func testBalanceSnapshotAndCacheKeepProviderClientIsolation() {
        let date = Date(timeIntervalSince1970: 1_700_000_001)
        let balance = Snapshot.balance(
            "Provider One",
            12,
            "USD",
            URL(string: "https://provider.example"),
            date
        )
        XCTAssertEqual(balance.menuBarPrimary, "$12.00")
        XCTAssertEqual(balance.overviewProvider, "Provider One")
        XCTAssertEqual(balance.overviewQuotaTitle, tr("可用余额", "Available Balance", "可用餘額", "利用可能な残高"))
        XCTAssertEqual(balance.overviewQuotaDetail, tr("剩余额度", "Remaining Balance", "剩餘額度", "残りのクォータ"))
        XCTAssertEqual(balance.overviewLargeAmount, "$12.00")
        XCTAssertNil(balance.progressPercentage)

        var cache = ProviderBalanceSnapshotCache()
        cache.store(balance, clientID: "codex", providerID: "provider-one")
        let sameProvider = cache.errorSnapshot(
            clientID: "codex",
            providerID: "provider-one",
            providerName: "Provider One",
            reason: "Request failed"
        )
        XCTAssertEqual(sameProvider.kind, .error)
        XCTAssertEqual(sameProvider.amount, 12)
        XCTAssertEqual(sameProvider.unit, "USD")
        XCTAssertEqual(sameProvider.date, date)
        XCTAssertTrue(sameProvider.hasCachedBalance)
        XCTAssertEqual(sameProvider.message, "Request failed")

        let otherProvider = cache.errorSnapshot(
            clientID: "codex",
            providerID: "provider-two",
            providerName: "Provider Two",
            reason: "No cached balance"
        )
        XCTAssertNil(otherProvider.amount)
        XCTAssertNil(otherProvider.date)
        XCTAssertFalse(otherProvider.hasCachedBalance)

        let otherClient = cache.errorSnapshot(
            clientID: "claude",
            providerID: "provider-one",
            providerName: "Provider One",
            reason: "Different client"
        )
        XCTAssertNil(otherClient.amount)
        XCTAssertNil(otherClient.date)
    }

    func testOpenCodexCardPresentationDoesNotExposeModelIdentity() {
        let date = Date(timeIntervalSince1970: 1_700_000_123)
        let currentOfficial = OpenCodexModelCard(
            selector: "gpt-5.6-luna",
            provider: "openai",
            model: "gpt-5.6-luna",
            isCurrent: true,
            data: .official(
                remaining: 81.7,
                label: "7-Day Quota",
                reset: "2 hours",
                updatedAt: date
            )
        )

        let official = OpenCodexCardPresentation.menuBarSnapshot(
            for: currentOfficial
        )
        XCTAssertEqual(official.menuBarPrimary, "81%")
        XCTAssertEqual(official.menuBarSecondary, "2 hours")
        XCTAssertFalse(official.menuBarTitle.contains("gpt-5.6-luna"))
        XCTAssertFalse(official.menuBarToolTip.contains("gpt-5.6-luna"))

        let currentBalance = OpenCodexModelCard(
            selector: "relay/gpt-5.6-sol",
            provider: "relay",
            model: "gpt-5.6-sol",
            isCurrent: true,
            data: .balance(
                amount: 12.34,
                unit: "USD",
                websiteURL: URL(string: "https://relay.example.test"),
                updatedAt: date
            )
        )
        let balance = OpenCodexCardPresentation.menuBarSnapshot(for: currentBalance)
        XCTAssertEqual(balance.menuBarPrimary, "$12.34")
        XCTAssertEqual(balance.menuBarSecondary, "")
        XCTAssertFalse(balance.menuBarTitle.contains("gpt-5.6-sol"))

        let loading = OpenCodexCardPresentation.menuBarSnapshot(
            for: OpenCodexModelCard(
                selector: "relay/secret-model",
                provider: "relay",
                model: "secret-model",
                isCurrent: true,
                data: .loading(category: .balance)
            )
        )
        XCTAssertEqual(loading.menuBarPrimary, "…")
        XCTAssertFalse(loading.menuBarTitle.contains("secret-model"))

        let unavailable = OpenCodexCardPresentation.menuBarSnapshot(
            for: OpenCodexModelCard(
                selector: "relay/secret-model",
                provider: "relay",
                model: "secret-model",
                isCurrent: true,
                data: .unavailable(
                    category: .balance,
                    reason: "Balance unavailable"
                )
            )
        )
        XCTAssertEqual(unavailable.menuBarPrimary, "!")
        XCTAssertFalse(unavailable.menuBarTitle.contains("secret-model"))
    }

    func testOpenCodexMenuBarAlwaysUsesFirstPreferenceInPublishedOrder() {
        let date = Date(timeIntervalSince1970: 1_700_000_456)
        let baseSnapshot = Snapshot.openCodex(
            "OpenCodex",
            selector: "tokenshop/gpt-5.6-sol",
            status: "Connected",
            date
        )

        let firstLoading = OpenCodexModelCard(
            selector: "openai/gpt-5.6-sol",
            provider: "openai",
            model: "gpt-5.6-sol",
            isCurrent: false,
            data: .loading(category: .quota)
        )
        let laterOfficial = OpenCodexModelCard(
            selector: "openai/gpt-5.6-luna",
            provider: "openai",
            model: "gpt-5.6-luna",
            isCurrent: false,
            data: .official(
                remaining: 77.4,
                label: "7-Day Quota",
                reset: "6d18h",
                updatedAt: date
            )
        )
        let laterBalance = OpenCodexModelCard(
            selector: "tokenshop/gpt-5.6-sol",
            provider: "tokenshop",
            model: "gpt-5.6-sol",
            isCurrent: true,
            data: .balance(
                amount: 1.44,
                unit: "USD",
                websiteURL: URL(string: "https://tokenshop.homes"),
                updatedAt: date
            )
        )
        var publishedCards = [firstLoading, laterOfficial, laterBalance]

        let initialMatch = OpenCodexCardPresentation.menuBarCardMatch(from: publishedCards)
        XCTAssertEqual(initialMatch.diagnosticReason, "first-preference")
        XCTAssertEqual(initialMatch.card?.selector, "openai/gpt-5.6-sol")
        let loading = OpenCodexCardPresentation.menuBarSnapshot(
            for: baseSnapshot,
            cards: publishedCards
        )
        XCTAssertEqual(loading.menuBarPrimary, "…")
        XCTAssertEqual(loading.menuBarSecondary, "")

        publishedCards[0] = OpenCodexModelCard(
            selector: "openai/gpt-5.6-sol",
            provider: "openai",
            model: "gpt-5.6-sol",
            isCurrent: false,
            data: .official(
                remaining: 77.4,
                label: "7-Day Quota",
                reset: "6d18h",
                updatedAt: date
            )
        )
        let official = OpenCodexCardPresentation.menuBarSnapshot(
            for: baseSnapshot,
            cards: publishedCards
        )
        XCTAssertEqual(official.menuBarPrimary, "77%")
        XCTAssertEqual(official.menuBarSecondary, "6d18h")
        XCTAssertFalse(official.menuBarTitle.contains("gpt-5.6-sol"))

        let publishedMatch = OpenCodexCardPresentation.menuBarCardMatch(from: publishedCards)
        XCTAssertEqual(publishedMatch.diagnosticReason, "first-preference")
        XCTAssertEqual(publishedMatch.card?.selector, "openai/gpt-5.6-sol")

        publishedCards[0] = OpenCodexModelCard(
            selector: "openai/gpt-5.6-sol",
            provider: "openai",
            model: "gpt-5.6-sol",
            isCurrent: false,
            data: .unavailable(
                category: .quota,
                reason: "Quota unavailable"
            )
        )
        let unavailable = OpenCodexCardPresentation.menuBarSnapshot(
            for: baseSnapshot,
            cards: publishedCards
        )
        XCTAssertEqual(unavailable.menuBarPrimary, "!")
        XCTAssertFalse(unavailable.menuBarTitle.contains("gpt-5.6-sol"))

        publishedCards = [laterBalance, publishedCards[0], laterOfficial]
        let reordered = OpenCodexCardPresentation.menuBarSnapshot(
            for: baseSnapshot,
            cards: publishedCards
        )
        XCTAssertEqual(reordered.menuBarPrimary, "$1.44")
        XCTAssertEqual(reordered.menuBarSecondary, "")
        XCTAssertFalse(reordered.menuBarTitle.contains("gpt-5.6-sol"))
    }

    func testBalanceQueryPreservesExistingConfigurationRules() {
        let settingsText = #"{"apiKey":"test-token","baseUrl":"https://tokenshop.example.test/"}"#
        let metaText = #"{"usage_script":{"enabled":true,"code":"fetch({ url: \"{{baseUrl}}/v1/usage\" })","autoQueryInterval":12,"timeout":9}}"#
        let query = BalanceQuery.make(
            settingsText: settingsText,
            metaText: metaText,
            websiteText: " https://tokenshop.example.test ",
            appType: "claude"
        )

        XCTAssertEqual(query?.url, "https://tokenshop.example.test/v1/usage")
        XCTAssertEqual(query?.websiteURL, URL(string: "https://tokenshop.example.test"))
        XCTAssertEqual(query?.apiKey, "test-token")
        XCTAssertEqual(query?.intervalMinutes, 12)
        XCTAssertEqual(query?.timeoutSeconds, 9)
        XCTAssertFalse(query?.isRightCode ?? true)
        XCTAssertEqual(query?.subscriptionPrefix, "/claude")
        XCTAssertNil(query?.nativeBalanceProvider)
        XCTAssertFalse(query?.isNewAPI ?? true)
        XCTAssertTrue(query?.additionalHeaders.isEmpty ?? false)
    }

    func testBalanceQueryFailureAndNativeProviderRemainPure() {
        var failure: BalanceQueryFailure?
        let invalid = BalanceQuery.make(
            settingsText: "{}",
            metaText: "{}",
            websiteText: nil,
            appType: "codex",
            onFailure: { failure = $0 }
        )
        XCTAssertNil(invalid)
        XCTAssertEqual(failure?.rawValue, BalanceQueryFailure.usageScriptMissing.rawValue)

        let native = BalanceQuery.make(
            settingsText: #"{"apiKey":"test-token","baseUrl":"https://api.deepseek.com"}"#,
            metaText: #"{"usage_script":{"enabled":true,"templateType":"balance"}}"#,
            websiteText: nil,
            appType: "codex"
        )
        XCTAssertEqual(native?.url, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(native?.nativeBalanceProvider?.endpoint, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(native?.subscriptionPrefix, "/codex")
    }
}
