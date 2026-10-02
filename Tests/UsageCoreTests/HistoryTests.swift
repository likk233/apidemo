import Foundation
import UsageCore

final class HistoryTests {
    private func snapshot(_ amount: Decimal, at date: Date, currency: String = "USD") -> BalanceSnapshot {
        BalanceSnapshot(available: true, balances: [BalanceInfo(currency: currency, total: amount)], capturedAt: date)
    }
    func testSpendExcludesTopUpsAndKeepsCurrenciesSeparate() throws {
        let now = Date()
        var history = BalanceHistory()
        history.record(snapshot(10, at: now))
        history.record(snapshot(8, at: now.addingTimeInterval(3600)))
        history.record(snapshot(28, at: now.addingTimeInterval(7200)))
        history.record(snapshot(27, at: now.addingTimeInterval(10800)))
        history.record(snapshot(100, at: now, currency: "CNY"))
        let estimate = try require(history.estimate(currency: "USD"))
        expect(abs((estimate.perDay) - (24)) <= 0.001)
        expect(abs((estimate.daysLeft) - (1.125)) <= 0.001)
        expect(history.estimate(currency: "CNY") == nil)
    }
    func testEstimateNeedsThirtyMinutesAndConsumption() {
        let now = Date()
        var history = BalanceHistory()
        history.record(snapshot(10, at: now))
        history.record(snapshot(9, at: now.addingTimeInterval(1799)))
        expect(history.estimate(currency: "USD") == nil)
        var topped = BalanceHistory()
        topped.record(snapshot(10, at: now)); topped.record(snapshot(20, at: now.addingTimeInterval(3600)))
        expect(topped.estimate(currency: "USD") == nil)
    }
    func testHistoryBoundedAndDuplicateRefreshNotRecorded() {
        let now = Date()
        var history = BalanceHistory()
        history.record(snapshot(100, at: now.addingTimeInterval(-15 * 86400)))
        for i in 0..<520 { history.record(snapshot(100, at: now.addingTimeInterval(Double(i) * 60))) }
        expect(history.samples["USD"]?.count == 500)
        let last = snapshot(100, at: now.addingTimeInterval(519 * 60))
        history.record(last)
        expect(history.samples["USD"]?.count == 500)
        expect(history.samples["USD"]!.allSatisfy { $0.date >= now })
    }
    func testThresholdValidation() {
        expect(BalanceHistory.thresholds("5, 10, 1, 5") == [10, 5, 1])
        for input in ["", "0", "-1", "nan", "5,", "1oops", "Infinity"] { expect(BalanceHistory.thresholds(input) == nil) }
    }
    func testWarningsDeduplicateRearmAndPersistAcrossLaunch() throws {
        var warnings = BalanceWarnings()
        let low = BalanceInfo(currency: "USD", total: 4)
        expect(warnings.check(low, available: true, thresholds: [10, 5, 1]) != nil)
        expect(warnings.check(low, available: true, thresholds: [10, 5, 1]) == nil)
        let data = try JSONEncoder().encode(warnings)
        warnings = try JSONDecoder().decode(BalanceWarnings.self, from: data)
        expect(warnings.check(low, available: true, thresholds: [10, 5, 1]) == nil)
        expect(warnings.check(BalanceInfo(currency: "USD", total: 20), available: true, thresholds: [10, 5, 1]) == nil)
        expect(warnings.check(low, available: true, thresholds: [10, 5, 1]) != nil)
        expect(warnings.check(BalanceInfo(currency: "USD", total: Decimal(string: "0.50")!), available: true, thresholds: [])!.contains("极低"))
        expect(warnings.check(low, available: false, thresholds: [])!.contains("耗尽"))
        expect(warnings.check(BalanceInfo(currency: "CNY", total: 6), available: true, thresholds: []) != nil)
    }
}
