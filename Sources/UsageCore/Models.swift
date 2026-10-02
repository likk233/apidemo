import Foundation

public enum CodexSource: String, Codable, CaseIterable, Sendable {
    case auto, api, rollout
    public var title: String {
        switch self {
        case .auto: return "自动（在线优先）"
        case .api: return "在线（失败时回退）"
        case .rollout: return "离线会话"
        }
    }
}

public struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var usedPercent: Double
    public var minutes: Double?
    public var resetsAt: Date?
    public var title: String {
        guard let minutes, minutes > 0 else { return "额度窗口" }
        if minutes >= 1440 {
            return minutes == 10080 ? "每周额度" : "\(Self.number(minutes / 1440)) 天额度"
        }
        if minutes >= 60 { return "\(Self.number(minutes / 60)) 小时额度" }
        return "\(Self.number(minutes)) 分钟额度"
    }
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

public struct FeatureLimit: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var windows: [UsageWindow]
}

public struct CodexCredits: Codable, Equatable, Sendable {
    public var balance: String?
    public var unlimited: Bool
    public var hasCredits: Bool?
    public var overageReached: Bool?
}

public struct SpendControl: Codable, Equatable, Sendable {
    public var limit: String
    public var used: String
    public var remainingPercent: Double
    public var resetsAt: Date?
}

public struct CodexSnapshot: Codable, Equatable, Sendable {
    public var windows: [UsageWindow]
    public var features: [FeatureLimit]
    public var plan: String?
    public var limitName: String?
    public var credits: CodexCredits?
    public var resetCredits: Double?
    public var spendControl: SpendControl?
    public var blockedReason: String?
    public var capturedAt: Date
    public var source: String
    public var origin: String
    public var fallbackReason: String?
    public var highestUsed: Double? { windows.map(\.usedPercent).max() }
}

public struct BalanceInfo: Codable, Equatable, Identifiable, Sendable {
    public var currency: String
    public var total: Decimal
    public var toppedUp: Decimal?
    public var granted: Decimal?
    public var id: String { currency }
    public var symbol: String { currency == "CNY" ? "¥" : (currency == "USD" ? "$" : currency + " ") }
    public init(currency: String, total: Decimal, toppedUp: Decimal? = nil, granted: Decimal? = nil) {
        self.currency = currency; self.total = total; self.toppedUp = toppedUp; self.granted = granted
    }
    public func money(_ amount: Decimal? = nil) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return symbol + (formatter.string(from: NSDecimalNumber(decimal: amount ?? total)) ?? "—")
    }
}

public struct BalanceSnapshot: Codable, Equatable, Sendable {
    public var available: Bool
    public var balances: [BalanceInfo]
    public var capturedAt: Date
    public init(available: Bool, balances: [BalanceInfo], capturedAt: Date) {
        self.available = available; self.balances = balances; self.capturedAt = capturedAt
    }
    public func selected(_ currency: String, fallbackToFirst: Bool = true) -> BalanceInfo? {
        balances.first { $0.currency == currency } ?? (fallbackToFirst ? balances.first : nil)
    }
}

public enum UsageError: Error, LocalizedError, Equatable, Sendable {
    case noLogin, noRollout, invalidResponse, network, timeout, unauthorized, http(Int), keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .noLogin: return "未找到 Codex OAuth 登录。请先运行 codex login；API Key 登录不支持此额度接口。"
        case .noRollout: return "最近 7 天没有可读取的额度事件。请使用一次 Codex，再刷新。压缩的 .zst 会话暂不读取。"
        case .invalidResponse: return "返回数据格式无法识别，请稍后刷新。"
        case .network: return "网络连接失败，请检查连接后重试。"
        case .timeout: return "请求超时，请稍后重试。"
        case .unauthorized: return "登录或 API Key 已失效。Codex 请重新登录；DeepSeek 请更新密钥。"
        case .http(402): return "账户余额不足，请前往 DeepSeek 充值。"
        case .http(429): return "请求过于频繁，已延长刷新间隔。"
        case .http(let status): return "服务返回 HTTP \(status)，请稍后重试。"
        case .keychain(let status): return "钥匙串操作失败（\(status)）。请检查 macOS 钥匙串访问权限。"
        }
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var codexSource: CodexSource = .auto
    public var codexHome: String = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "~/.codex"
    public var codexInterval: Double = 60
    public var deepseekInterval: Double = 300
    public var cnyThresholds: [Double] = [75, 35, 7]
    public var notifications = false
    public var compactMenu = false
    public init() {}
    public var resolvedCodexHome: URL {
        URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath, isDirectory: true)
    }
}
