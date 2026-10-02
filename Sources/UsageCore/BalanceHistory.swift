import Foundation

public struct BalanceSample: Codable, Equatable, Sendable {
    public let date: Date
    public let amount: Decimal
    public init(date: Date, amount: Decimal) { self.date = date; self.amount = amount }
}
public struct SpendEstimate: Equatable, Sendable {
    public let perDay: Double
    public let daysLeft: Double
}

// Consumption-only deltas, ported from deepseek-usage-tracker (MIT).
public struct BalanceHistory: Codable, Sendable {
    public var samples: [String: [BalanceSample]] = [:]
    public init() {}
    public mutating func record(_ snapshot: BalanceSnapshot) {
        for info in snapshot.balances {
            var series = (samples[info.currency] ?? []).filter { $0.date >= snapshot.capturedAt.addingTimeInterval(-14 * 86_400) }
            if series.last?.date != snapshot.capturedAt { series.append(BalanceSample(date: snapshot.capturedAt, amount: info.total)) }
            samples[info.currency] = Array(series.suffix(500))
        }
    }
    public func estimate(currency: String) -> SpendEstimate? {
        let series = (samples[currency] ?? []).sorted { $0.date < $1.date }
        guard let first = series.first, let last = series.last, series.count >= 2 else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        guard span >= 1800 else { return nil }
        var spent: Decimal = 0
        for index in 1..<series.count {
            let difference = series[index - 1].amount - series[index].amount
            if difference > 0 { spent += difference }
        }
        let perDay = NSDecimalNumber(decimal: spent).doubleValue / (span / 86_400)
        let balance = NSDecimalNumber(decimal: last.amount).doubleValue
        guard perDay > 0, perDay.isFinite, balance.isFinite else { return nil }
        return SpendEstimate(perDay: perDay, daysLeft: max(0, balance / perDay))
    }
    public static func thresholds(_ input: String) -> [Double]? {
        let parts = input.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }
        let values = parts.compactMap(Double.init)
        guard values.count == parts.count, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return Array(Set(values)).sorted(by: >)
    }
}

public struct BalanceWarnings: Codable, Sendable {
    private var active: [String: Set<String>] = [:]
    public init() {}
    public mutating func check(_ info: BalanceInfo, available: Bool, thresholds: [Double]) -> String? {
        let amount = NSDecimalNumber(decimal: info.total).doubleValue
        let floor = info.currency == "CNY" ? 7.0 : 1.0
        var crossed = Set(thresholds.filter { amount < $0 }.map { "threshold:\($0)" })
        if amount < floor || !available { crossed.insert("floor") }
        if amount <= 0 || !available { crossed.insert("depleted") }
        let new = crossed.subtracting(active[info.currency] ?? [])
        active[info.currency] = crossed
        if new.contains("depleted") { return "DeepSeek 可用余额已耗尽（\(info.money())）。" }
        if new.contains("floor") { return "DeepSeek 余额极低：\(info.money())。" }
        if !new.isEmpty { return "DeepSeek 余额低于提醒阈值：\(info.money())。" }
        return nil
    }
    public mutating func reset() { active = [:] }
}
