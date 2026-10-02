import AppKit
import Combine
import ServiceManagement
import UserNotifications
import UsageCore

@MainActor
final class AppState: ObservableObject {
    @Published var preferences: Preferences
    @Published var codex: CodexSnapshot?
    @Published var balance: BalanceSnapshot?
    @Published var codexError: String?
    @Published var deepseekError: String?
    @Published var codexLoading = false
    @Published var showCodexDetails = false
    @Published var deepseekLoading = false
    @Published var hasKey = false
    @Published var history: BalanceHistory
    @Published var settingsNotice: String?
    @Published var loginEnabled = false
    let demo: Bool
    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore()
    private let codexProvider = CodexProvider()
    private let deepseekProvider = DeepSeekProvider()
    private var warnings: BalanceWarnings
    private var codexTask: Task<Void, Never>?
    private var deepseekTask: Task<Void, Never>?
    private var timer: Timer?
    private var nextCodex = Date.distantPast
    private var nextDeepseek = Date.distantPast
    private var codexGeneration = 0
    private var keyGeneration = 0
    private var codexFailures = 0
    private var deepseekFailures = 0
    private var codexWarned: Set<String> = []

    init(demo: Bool = false) {
        self.demo = demo
        let storedDefaults = UserDefaults.standard
        func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
            storedDefaults.data(forKey: name).flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        preferences = demo ? Preferences() : (load(Preferences.self, "preferences") ?? Preferences())
        history = demo ? BalanceHistory() : (load(BalanceHistory.self, "history") ?? BalanceHistory())
        warnings = demo ? BalanceWarnings() : (load(BalanceWarnings.self, "warnings") ?? BalanceWarnings())
        preferences.codexInterval = max(30, min(600, preferences.codexInterval))
        preferences.deepseekInterval = max(60, min(1800, preferences.deepseekInterval))
        if demo { seedDemo(); return }
        loginEnabled = SMAppService.mainApp.status == .enabled
        do { hasKey = try keychain.read() != nil }
        catch { deepseekError = error.localizedDescription }
    }
    deinit { timer?.invalidate(); codexTask?.cancel(); deepseekTask?.cancel() }

    var selectedBalance: BalanceInfo? { balance?.selected("CNY", fallbackToFirst: false) }
    var refreshing: Bool { codexLoading || deepseekLoading }
    var menuTitle: String {
        if preferences.compactMenu { return "" }
        let used = codex?.highestUsed.map { String(format: "C %.0f%%", $0) } ?? "C —"
        let stale = codexError != nil || codex?.source == "rollout"
        let money = selectedBalance.map { "D " + (deepseekError != nil ? "~" : "") + $0.money() } ?? "D —"
        return (stale && codex != nil ? "~" : "") + used + "  ·  " + money
    }
    var menuTooltip: String {
        "UsageBar · Codex 已用额度 / DeepSeek 余额\n~ 表示离线或上次成功的数据\n点击查看详情，右键打开菜单"
    }
    func start() {
        guard !demo else { return }
        refreshAll()
        // A coarse timer with tolerance avoids busy polling. Provider intervals stay independent.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 5
    }
    private func tick() {
        if Date() >= nextCodex { refreshCodex() }
        if Date() >= nextDeepseek { refreshDeepseek() }
    }
    func refreshAll() { refreshCodex(); refreshDeepseek() }
    func wake() { nextCodex = .distantPast; nextDeepseek = .distantPast; tick() }
    private func delay(interval: Double, failures: Int) -> Double {
        min(1800, interval * pow(2, Double(min(failures, 5))))
    }
    func refreshCodex() {
        guard !demo, codexTask == nil else { return }
        codexLoading = true
        let generation = codexGeneration
        let home = preferences.resolvedCodexHome
        let source = preferences.codexSource
        codexTask = Task { [weak self, codexProvider] in
            let result: Result<CodexSnapshot, Error>
            do { result = .success(try await codexProvider.fetch(home: home, source: source)) }
            catch { result = .failure(error) }
            guard let self, generation == self.codexGeneration else { return }
            switch result {
            case .success(let snapshot):
                self.codex = snapshot; self.codexError = nil; self.codexFailures = 0
                self.checkCodexWarning(snapshot)
            case .failure(let error):
                self.codexError = error.localizedDescription; self.codexFailures += 1
            }
            self.nextCodex = Date().addingTimeInterval(self.delay(interval: self.preferences.codexInterval, failures: self.codexFailures))
            self.codexLoading = false; self.codexTask = nil
        }
    }
    func refreshDeepseek() {
        guard !demo, deepseekTask == nil else { return }
        let key: String
        do {
            guard let stored = try keychain.read() else { hasKey = false; nextDeepseek = .distantFuture; return }
            key = stored; hasKey = true
        } catch { deepseekError = error.localizedDescription; nextDeepseek = Date().addingTimeInterval(300); return }
        deepseekLoading = true
        let generation = keyGeneration
        deepseekTask = Task { [weak self, deepseekProvider] in
            let result: Result<BalanceSnapshot, Error>
            do { result = .success(try await deepseekProvider.fetch(key: key)) }
            catch { result = .failure(error) }
            guard let self, generation == self.keyGeneration else { return }
            switch result {
            case .success(let snapshot):
                self.balance = snapshot; self.deepseekError = nil; self.deepseekFailures = 0
                let cnySnapshot = BalanceSnapshot(available: snapshot.available, balances: snapshot.balances.filter { $0.currency == "CNY" }, capturedAt: snapshot.capturedAt)
                self.history.record(cnySnapshot); self.persist(self.history, "history")
                self.checkBalanceWarning()
            case .failure(let error):
                self.deepseekError = error.localizedDescription; self.deepseekFailures += 1
            }
            self.nextDeepseek = Date().addingTimeInterval(self.delay(interval: self.preferences.deepseekInterval, failures: self.deepseekFailures))
            self.deepseekLoading = false; self.deepseekTask = nil
        }
    }
    func savePreferences(_ new: Preferences) {
        let old = preferences
        preferences = new
        guard !demo else { return }
        persist(preferences, "preferences")
        if old.codexHome != new.codexHome || old.codexSource != new.codexSource {
            codexGeneration += 1; codexTask?.cancel(); codexTask = nil; codexLoading = false
            codex = nil; codexError = nil; codexWarned = []; codexFailures = 0
            refreshCodex()
        }
        if old.codexInterval != new.codexInterval { nextCodex = Date().addingTimeInterval(new.codexInterval) }
        if old.deepseekInterval != new.deepseekInterval { nextDeepseek = Date().addingTimeInterval(new.deepseekInterval) }
        if old.cnyThresholds != new.cnyThresholds {
            warnings.reset(); persist(warnings, "warnings")
            if deepseekError == nil { checkBalanceWarning() }
        }
        if !old.notifications && new.notifications {
            warnings.reset(); codexWarned = []
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if !granted { self.settingsNotice = "通知权限未开启，可在系统设置 → 通知 → UsageBar 中启用。" }
                    else {
                        if self.deepseekError == nil { self.checkBalanceWarning() }
                        if let snapshot = self.codex { self.checkCodexWarning(snapshot) }
                    }
                }
            }
        }
    }
    func saveKey(_ input: String) -> Bool {
        guard !demo else { settingsNotice = "演示模式不保存凭据。"; return false }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { settingsNotice = "请输入有效的 API Key，不能包含空白字符。"; return false }
        do {
            try keychain.save(key)
            invalidateDeepseek()
            hasKey = true; settingsNotice = "密钥已保存到 macOS 钥匙串。"
            refreshDeepseek(); return true
        } catch { settingsNotice = error.localizedDescription; return false }
    }
    func clearKey() {
        guard !demo else { return }
        do {
            try keychain.delete(); invalidateDeepseek(); hasKey = false
            nextDeepseek = .distantFuture; settingsNotice = "已删除密钥，并清除本地余额历史。"
        } catch { settingsNotice = error.localizedDescription }
    }
    private func invalidateDeepseek() {
        keyGeneration += 1; deepseekTask?.cancel(); deepseekTask = nil; deepseekLoading = false
        balance = nil; deepseekError = nil; deepseekFailures = 0
        history = BalanceHistory(); warnings.reset()
        persist(history, "history"); persist(warnings, "warnings")
    }
    func clearHistory() {
        history = BalanceHistory(); if !demo { persist(history, "history") }
        settingsNotice = "已清除本地余额历史。"
    }
    func setLogin(_ enabled: Bool) {
        guard !demo else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                settingsNotice = "请在系统设置 → 通用 → 登录项中允许 UsageBar。"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { settingsNotice = "登录项设置失败：\(error.localizedDescription)" }
    }
    private func persist<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    private func checkBalanceWarning() {
        guard preferences.notifications, let snapshot = balance, let info = selectedBalance else { return }
        if let message = warnings.check(info, available: snapshot.available, thresholds: preferences.cnyThresholds) {
            notify(title: "DeepSeek 余额提醒", body: message)
        }
        persist(warnings, "warnings")
    }
    private func checkCodexWarning(_ snapshot: CodexSnapshot) {
        guard preferences.notifications, snapshot.source == "api" else { return }
        for window in snapshot.windows where window.usedPercent >= 90 {
            let id = window.id + ":" + (window.resetsAt.map { String($0.timeIntervalSince1970) } ?? "unknown")
            if codexWarned.insert(id).inserted { notify(title: "Codex 额度提醒", body: "\(window.title)已使用 \(Int(window.usedPercent))%。") }
        }
        if codexWarned.count > 100 { codexWarned = [] }
    }
    private func notify(title: String, body: String) {
        guard !demo else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    private func seedDemo() {
        let fixture = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":38,"limit_window_seconds":18000,"reset_after_seconds":8140},"secondary_window":{"used_percent":64,"limit_window_seconds":604800,"reset_after_seconds":226800}},"credits":{"balance":"12.00","has_credits":true,"unlimited":false}}"#
        codex = try? CodexParser.parse(data: Data(fixture.utf8), source: "demo")
        let now = Date()
        balance = BalanceSnapshot(available: true, balances: [BalanceInfo(currency: "CNY", total: Decimal(string: "178.99")!, toppedUp: 158, granted: Decimal(string: "20.99"))], capturedAt: now)
        for i in 0..<24 {
            history.record(BalanceSnapshot(available: true, balances: [BalanceInfo(currency: "CNY", total: Decimal(string: "178.99")! + Decimal(23 - i) * Decimal(string: "1.25")!)], capturedAt: now.addingTimeInterval(Double(i - 23) * 3600)))
        }
        hasKey = true
    }
}
