import Foundation
import UsageCore

final class ParserTests {
    func testLiveWindowsAdditionalLimitsAndBudget() throws {
        let data = Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":32,"limit_window_seconds":18000,"reset_at":2000000000},"secondary_window":{"used_percent":66,"limit_window_seconds":604800}},"code_review_rate_limit":{"primary_window":{"used_percent":11,"window_minutes":10080}},"additional_rate_limits":[{"limit_name":"Reserve","rate_limit":{"primary":{"used_percent":5}}}],"credits":{"has_credits":true,"balance":"12.00"},"rate_limit_reset_credits":{"available_count":2},"spend_control":{"reached":true,"individual_limit":{"limit":"$50","used":"$40","remaining_percent":20,"resets_at":2000000000}}}"#.utf8)
        let snapshot = try CodexParser.parse(data: data)
        expect(snapshot.windows.count == 2)
        expect(snapshot.windows[0].title == "5 小时额度")
        expect(snapshot.windows[1].title == "每周额度")
        expect(snapshot.plan == "plus")
        expect(snapshot.features.map(\.name) == ["Reserve", "Code review"])
        expect(snapshot.spendControl?.remainingPercent == 20)
        expect(snapshot.credits?.balance == "12.00")
        expect(snapshot.resetCredits == 2)
        expect(snapshot.blockedReason != nil)
    }
    func testLegacyRelativeResetAnchoredToEventNotRefresh() throws {
        let fileDate = Date(timeIntervalSince1970: 9999)
        let data = Data(#"{"timestamp":"2026-10-01T00:00:00.000Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_in_seconds":3600}}}}"#.utf8)
        let snapshot = try require(CodexParser.rollout(line: data, fileDate: fileDate, origin: "fixture"))
        expect(snapshot.windows[0].resetsAt?.timeIntervalSince(snapshot.capturedAt) == 3600)
        expect(snapshot.capturedAt != fileDate)
        expect(snapshot.source == "rollout")
    }
    func testCamelCaseAndCreditOnlyResponses() throws {
        let response = Data(#"{"rateLimits":{"primaryWindow":{"usedPercent":120,"windowSeconds":86400,"resetsInSeconds":10},"planType":"team"}}"#.utf8)
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = try CodexParser.parse(data: response, capturedAt: now)
        expect(snapshot.windows[0].usedPercent == 100)
        expect(snapshot.windows[0].title == "1 天额度")
        expect(snapshot.windows[0].resetsAt == now.addingTimeInterval(10))
        let credits = try CodexParser.parse(data: Data(#"{"credits":{"unlimited":true}}"#.utf8))
        expect(credits.windows.isEmpty)
        expect(credits.credits?.unlimited == true)
    }
    func testMissingMalformedAndBooleanPercentAreNotZeroUsage() {
        for raw in [#"{}"#, #"{"rate_limit":{"primary_window":{"used_percent":true}}}"#, #"{"rate_limits":{"primary":{"used_percent":-4}}}"#, "broken"] {
            expectThrows { _ = try CodexParser.parse(data: Data(raw.utf8)) }
        }
        expect(CodexParser.rollout(line: Data(#"{"payload":{"type":"token_count","rate_limits":null}}"#.utf8), fileDate: Date(), origin: "fixture") == nil)
    }
    func testDeepSeekCurrenciesAndDecimalPrecision() throws {
        let response = Data(#"{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"0.01234567","topped_up_balance":"0.01","granted_balance":"0.00234567"},{"currency":"CNY","total_balance":"0.10"}]}"#.utf8)
        let snapshot = try BalanceParser.parse(data: response)
        expect(!(snapshot.available))
        expect(snapshot.selected("USD")?.total == Decimal(string: "0.01234567"))
        expect(snapshot.selected("CNY")?.currency == "CNY")
        expect(snapshot.selected("EUR")?.currency == "USD")
        expect(snapshot.selected("CNY")?.money() == "¥0.10")
        expect(snapshot.selected("CNY")?.granted == nil)
    }
    func testCNYSelectionDoesNotFallBackToUSD() throws {
        let usdOnly = try BalanceParser.parse(data: Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"10"}]}"#.utf8))
        expect(usdOnly.selected("CNY", fallbackToFirst: false) == nil)
        let mixed = try BalanceParser.parse(data: Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"10"},{"currency":"CNY","total_balance":"75"}]}"#.utf8))
        expect(mixed.selected("CNY", fallbackToFirst: false)?.money() == "¥75.00")
    }
    func testLegacyPreferencesKeepCNYThresholds() throws {
        let legacy = Data(#"{"codexSource":"auto","codexHome":"~/custom-codex","codexInterval":120,"deepseekInterval":600,"currency":"USD","usdThresholds":[10,5,1],"cnyThresholds":[100,50,7],"notifications":true,"compactMenu":true}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: legacy)
        expect(preferences.cnyThresholds == [100, 50, 7])
        expect(preferences.deepseekInterval == 600)
        expect(preferences.codexHome == "~/custom-codex")
        expect(preferences.notifications && preferences.compactMenu)
        let saved = try require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        expect(saved["currency"] == nil && saved["usdThresholds"] == nil)
    }
    func testDeepSeekRejectsPartialNumbersAndDuplicateCurrency() {
        for value in ["NaN", "1oops", "", "Infinity"] {
            let response = "{\"balance_infos\":[{\"currency\":\"USD\",\"total_balance\":\"\(value)\"}]}"
            expectThrows { _ = try BalanceParser.parse(data: Data(response.utf8)) }
        }
        expectThrows { _ = try BalanceParser.parse(data: Data(#"{"balance_infos":[{"currency":"USD","total_balance":"1"},{"currency":"USD","total_balance":"2"}]}"#.utf8)) }
        expectThrows { _ = try BalanceParser.parse(data: Data(#"{"balance_infos":[]}"#.utf8)) }
    }
    func testAuthJWTAccountFallbackAndAPIKeyOnlyLogin() throws {
        let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"account-fixture"}}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let raw = "{\"tokens\":{\"access_token\":\"header.\(payload).signature\"}}"
        let auth = try CodexAuth.parse(data: Data(raw.utf8))
        expect(auth.accountID == "account-fixture")
        expectThrows { _ = try CodexAuth.parse(data: Data(#"{"OPENAI_API_KEY":"fixture"}"#.utf8)) }
        expect(try CodexAuth.parse(data: Data(#"{"tokens":{"access_token":"fixture","account_id":"direct"}}"#.utf8)).accountID == "direct")
    }
}
