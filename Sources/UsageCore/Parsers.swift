import Foundation
import CoreFoundation

// Ported from the defensive normalisation in vscode-codex-usage (MIT).
public enum CodexParser {
    static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func number(_ values: Any?...) -> Double? {
        for value in values {
            if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite {
                return n.doubleValue
            }
        }
        return nil
    }
    static func string(_ values: Any?...) -> String? {
        values.compactMap { $0 as? String }.first { !$0.isEmpty }
    }
    static func window(_ raw: Any?, id: String, capturedAt: Date) -> UsageWindow? {
        guard let r = object(raw), let percent = number(r["used_percent"], r["usedPercent"], r["pct"], r["percent"]), percent >= 0 else { return nil }
        let minutes = number(r["window_minutes"], r["windowMinutes"], r["limit_window_minutes"])
            ?? number(r["window_seconds"], r["windowSeconds"], r["limit_window_seconds"]).map { $0 / 60 }
        let absolute = number(r["resets_at"], r["resetsAt"], r["reset_at"], r["resetAt"])
        let relative = number(r["resets_in_seconds"], r["resetsInSeconds"], r["reset_after_seconds"], r["resetAfterSeconds"])
        let reset = absolute.map { Date(timeIntervalSince1970: $0) } ?? relative.map { capturedAt.addingTimeInterval($0) }
        return UsageWindow(id: id, usedPercent: min(100, percent), minutes: minutes, resetsAt: reset)
    }
    static func windows(_ r: [String: Any], prefix: String, date: Date) -> [UsageWindow] {
        [window(r["primary"] ?? r["primary_window"] ?? r["primaryWindow"], id: prefix + "-primary", capturedAt: date),
         window(r["secondary"] ?? r["secondary_window"] ?? r["secondaryWindow"], id: prefix + "-secondary", capturedAt: date)].compactMap { $0 }
    }
    public static func parse(data: Data, capturedAt: Date = Date(), source: String = "api", origin: String = "") throws -> CodexSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data), let r = object(json),
              let snapshot = parse(object: r, capturedAt: capturedAt, source: source, origin: origin) else { throw UsageError.invalidResponse }
        return snapshot
    }
    static func parse(object j: [String: Any], capturedAt: Date, source: String, origin: String) -> CodexSnapshot? {
        let r = object(j["rate_limits"]) ?? object(j["rateLimits"]) ?? object(j["rate_limit"])
            ?? object(object(j["usage"])?["rate_limits"]) ?? j
        let windows = windows(r, prefix: "codex", date: capturedAt)
        var credits: CodexCredits?
        if let c = object(r["credits"] ?? j["credits"]) {
            let balance = string(c["balance"], c["balance_display"], c["remaining"])
                ?? number(c["balance"]).map { String($0) }
            if balance != nil || c["has_credits"] is Bool || c["unlimited"] is Bool {
                credits = CodexCredits(balance: balance, unlimited: c["unlimited"] as? Bool ?? false,
                    hasCredits: c["has_credits"] as? Bool ?? c["hasCredits"] as? Bool,
                    overageReached: c["overage_limit_reached"] as? Bool ?? c["overageLimitReached"] as? Bool)
            }
        }
        var features: [FeatureLimit] = []
        for (index, value) in ((j["additional_rate_limits"] ?? j["additionalRateLimits"]) as? [Any] ?? []).enumerated() {
            guard let e = object(value), let name = string(e["limit_name"], e["limitName"]) else { continue }
            let id = "feature-\(index)"
            let raw = object(e["rate_limit"] ?? e["rateLimit"]) ?? e
            var w = self.windows(raw, prefix: id, date: capturedAt)
            if w.isEmpty, let single = window(raw, id: id, capturedAt: capturedAt) { w = [single] }
            if !w.isEmpty { features.append(FeatureLimit(id: id, name: name, windows: w)) }
        }
        if let review = object(j["code_review_rate_limit"] ?? j["codeReviewRateLimit"]) {
            let w = self.windows(review, prefix: "review", date: capturedAt)
            if !w.isEmpty { features.append(FeatureLimit(id: "review", name: "Code review", windows: w)) }
        }
        guard !windows.isEmpty || credits != nil || !features.isEmpty else { return nil }
        let spend = object(j["spend_control"]) ?? object(r["spend_control"])
        var control: SpendControl?
        if let i = object(spend?["individual_limit"] ?? r["individual_limit"] ?? r["individualLimit"]),
           let limit = string(i["limit"], i["limit_display"]), let used = string(i["used"], i["used_display"]),
           let remaining = number(i["remaining_percent"], i["remainingPercent"]) {
            control = SpendControl(limit: limit, used: used, remainingPercent: max(0, min(100, remaining)),
                resetsAt: number(i["resets_at"], i["resetsAt"]).map { Date(timeIntervalSince1970: $0) })
        }
        let reason = j["rate_limit_reached_type"] ?? r["rate_limit_reached_type"] ?? j["rateLimitReachedType"]
        var blocked = string(reason, object(reason)?["type"], object(reason)?["kind"])
        if spend?["reached"] as? Bool == true || r["spend_control_reached"] as? Bool == true { blocked = blocked ?? "预算上限已达到" }
        if r["limit_reached"] as? Bool == true { blocked = blocked ?? "额度已用尽" }
        let resetCredits = object(j["rate_limit_reset_credits"] ?? j["rateLimitResetCredits"])
        return CodexSnapshot(windows: windows, features: features,
            plan: string(r["plan_type"], r["planType"], j["plan_type"], object(j["plan"])?["name"], j["plan"]),
            limitName: string(r["limit_name"], r["limitName"]), credits: credits,
            resetCredits: number(resetCredits?["available_count"], resetCredits?["availableCount"]),
            spendControl: control, blockedReason: blocked, capturedAt: capturedAt, source: source, origin: origin, fallbackReason: nil)
    }
    public static func rollout(line: Data, fileDate: Date, origin: String) -> CodexSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: line), let j = object(json) else { return nil }
        let payload = object(j["payload"]) ?? j
        guard payload["type"] as? String == "token_count", let rate = object(payload["rate_limits"]) else { return nil }
        let date = string(j["timestamp"], payload["timestamp"]).flatMap(parseDate) ?? fileDate
        return parse(object: rate, capturedAt: date, source: "rollout", origin: origin)
    }
    static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

public enum BalanceParser {
    static func decimal(_ value: Any?) -> Decimal? {
        let text: String
        if let s = value as? String { text = s }
        else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { text = n.stringValue }
        else { return nil }
        guard text.range(of: "^-?[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil,
              let d = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !d.isNaN,
              NSDecimalNumber(decimal: d).doubleValue.isFinite else { return nil }
        return d
    }
    public static func parse(data: Data, capturedAt: Date = Date()) throws -> BalanceSnapshot {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = j["balance_infos"] as? [[String: Any]], !entries.isEmpty else { throw UsageError.invalidResponse }
        var currencies = Set<String>()
        let balances = try entries.map { e -> BalanceInfo in
            guard let currency = e["currency"] as? String, !currency.isEmpty,
                  currencies.insert(currency).inserted, let total = decimal(e["total_balance"]) else { throw UsageError.invalidResponse }
            return BalanceInfo(currency: currency, total: total, toppedUp: decimal(e["topped_up_balance"]), granted: decimal(e["granted_balance"]))
        }
        return BalanceSnapshot(available: j["is_available"] as? Bool ?? true, balances: balances, capturedAt: capturedAt)
    }
}
