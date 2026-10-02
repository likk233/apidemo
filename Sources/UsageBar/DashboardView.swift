import SwiftUI
import AppKit
import UsageCore

private let teal = Color(red: 0.12, green: 0.64, blue: 0.55)
private let blue = Color(red: 0.27, green: 0.48, blue: 0.88)

struct DashboardView: View {
    @ObservedObject var state: AppState
    let openSettings: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.title2).foregroundStyle(teal)
                    .frame(width: 32, height: 32).background(teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("UsageBar").font(.system(size: 18, weight: .semibold))
                    Text(state.demo ? "演示数据 · 不读取真实凭据" : "AI 额度与余额，一眼掌握").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 15)) }
                    .buttonStyle(.plain).help("设置").accessibilityLabel("设置")
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            VStack(spacing: 10) {
                codexCard
                deepseekCard
            }.padding(12)
            Divider()
            HStack {
                Button { state.refreshAll() } label: {
                    Label(state.refreshing ? "刷新中…" : "刷新全部", systemImage: "arrow.clockwise")
                }.buttonStyle(.plain).disabled(state.refreshing || state.demo)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield")
                    Text("凭据留在本机 · 无遥测 · 只读查询")
                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).help("退出 UsageBar").accessibilityLabel("退出 UsageBar")
            }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 10)
        }.frame(width: 400).fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private var codexCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("Codex", subtitle: state.codex?.plan.map { $0.capitalized + " · 额度窗口" } ?? "账户额度", symbol: "terminal", color: teal, loading: state.codexLoading) {
                if let snapshot = state.codex {
                    pill(snapshot.source == "api" ? "实时" : snapshot.source == "demo" ? "演示" : "离线快照", color: snapshot.source == "rollout" ? .orange : teal)
                }
            }
            if let snapshot = state.codex {
                if let name = snapshot.limitName { Text(name).font(.caption).foregroundStyle(.secondary) }
                ForEach(snapshot.windows) { window in WindowRow(window: window, color: teal) }
                if snapshot.windows.isEmpty { Text("未报告额度窗口").font(.caption).foregroundStyle(.secondary) }
                if !snapshot.features.isEmpty || snapshot.credits != nil || snapshot.spendControl != nil || snapshot.resetCredits != nil {
                    DisclosureGroup("更多账户信息", isExpanded: $state.showCodexDetails) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(snapshot.features) { feature in
                                Text(feature.name).font(.caption).bold()
                                ForEach(feature.windows) { WindowRow(window: $0, color: blue) }
                            }
                            if let credits = snapshot.credits {
                                detail("额外积分", value: credits.unlimited ? "不限量" : credits.balance ?? (credits.hasCredits == true ? "可用" : "无可用积分"))
                                if credits.overageReached == true { notice("额外用量预算已达到上限", color: .orange) }
                            }
                            if let count = snapshot.resetCredits { detail("可用重置次数", value: String(format: "%.0f", count)) }
                            if let spend = snapshot.spendControl {
                                detail("预算已用 / 上限", value: "\(spend.used) / \(spend.limit)")
                                detail("预算剩余", value: String(format: "%.0f%%", spend.remainingPercent))
                                if let date = spend.resetsAt { detail("预算重置", value: date.formatted(date: .abbreviated, time: .shortened)) }
                            }
                        }.padding(.top, 8)
                    }.font(.caption).tint(.secondary)
                }
                if let reason = snapshot.blockedReason { notice(reason, color: .orange) }
                if let fallback = snapshot.fallbackReason { notice("在线不可用，已回退到离线数据。\n" + fallback, color: .orange) }
                if let error = state.codexError { notice("刷新失败，显示上次成功数据。\n" + error, color: .orange) }
                timestamp(snapshot.capturedAt, prefix: snapshot.source == "rollout" ? "快照" : "更新")
            } else {
                emptyState(symbol: "terminal", message: state.codexError ?? (state.codexLoading ? "正在读取 Codex 额度…" : "等待 Codex 数据"))
                Button("查看数据源设置", action: openSettings).buttonStyle(.link).font(.caption)
            }
        }.card()
    }
    private var deepseekCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("DeepSeek", subtitle: "API 账户余额", symbol: "waveform.path", color: blue, loading: state.deepseekLoading) {
                Text("CNY").font(.caption).bold().foregroundStyle(.secondary)
            }
            if let info = state.selectedBalance, let snapshot = state.balance {
                HStack(alignment: .firstTextBaseline) {
                    Text(info.money()).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(snapshot.available && info.total > 0 ? Color.primary : Color.orange)
                    Spacer()
                    Text(snapshot.available && info.total > 0 ? "可用余额" : "不可用").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    balanceDetail("充值余额", amount: info.toppedUp, info: info)
                    balanceDetail("赠送余额", amount: info.granted, info: info)
                    Spacer(minLength: 0)
                }
                let samples = state.history.samples[info.currency] ?? []
                if samples.count >= 2 {
                    Sparkline(samples: samples, color: blue).frame(height: 28)
                        .accessibilityLabel("本地余额变化，最近 \(samples.count) 次记录")
                }
                if let estimate = state.history.estimate(currency: info.currency) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("估算日消费").font(.caption2).foregroundStyle(.secondary)
                            Text(info.money(Decimal(estimate.perDay)) + " / 天").font(.system(size: 12, weight: .medium))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("按当前消费速度").font(.caption2).foregroundStyle(.secondary)
                            Text(estimate.daysLeft < 1 ? "不足 1 天" : estimate.daysLeft > 365 ? "超过 365 天" : "约 \(Int(estimate.daysLeft.rounded())) 天").font(.system(size: 12, weight: .medium))
                        }
                    }
                    Text("根据本机余额记录估算，充值不计为消费。").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    Text("记录满 30 分钟且有余额下降后，显示消费估算。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if !snapshot.available || info.total <= 0 { notice("账户没有可用额度，请前往充值。", color: .orange) }
                else if NSDecimalNumber(decimal: info.total).doubleValue < (state.preferences.cnyThresholds.max() ?? 0) { notice("余额已低于提醒阈值。", color: .orange) }
                if let error = state.deepseekError { notice("刷新失败，显示上次成功余额。\n" + error, color: .orange) }
                HStack {
                    timestamp(snapshot.capturedAt, prefix: "更新")
                    Spacer()
                    Link("充值 ↗", destination: URL(string: "https://platform.deepseek.com/top_up")!).font(.caption).tint(blue)
                }
            } else {
                emptyState(symbol: "key.horizontal", message: state.deepseekError ?? (state.balance != nil ? "接口未返回人民币余额。" : (state.hasKey ? "正在查询人民币余额…" : "连接 DeepSeek，随时查看人民币余额")))
                Button(state.hasKey ? "管理密钥" : "添加 API Key", action: openSettings)
                    .buttonStyle(.borderedProminent).tint(blue).controlSize(.small)
                Text("密钥保存在 macOS 钥匙串中。").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Link("用量面板 ↗", destination: URL(string: "https://platform.deepseek.com/usage")!)
                Spacer()
                Link("官方价格 ↗", destination: URL(string: "https://api-docs.deepseek.com/quick_start/pricing")!)
            }.font(.caption).tint(.secondary)
        }.card()
    }
    private func cardHeader<Content: View>(_ name: String, subtitle: String, symbol: String, color: Color, loading: Bool, @ViewBuilder accessory: () -> Content) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(color)
                .frame(width: 30, height: 30).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 14, height: 14) }
            accessory()
        }
    }
    private func balanceDetail(_ title: String, amount: Decimal?, info: BalanceInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(amount.map { info.money($0) } ?? "未报告").font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }
    private func detail(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).textSelection(.enabled) }.font(.caption)
    }
    private func pill(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.1), in: Capsule())
    }
    private func notice(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.font(.system(size: 11)).foregroundStyle(color)
    }
    private func emptyState(symbol: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tertiary)
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 5)
    }
    private func timestamp(_ date: Date, prefix: String) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 4) {
                Circle().fill(context.date.timeIntervalSince(date) > 900 ? Color.orange : teal).frame(width: 5, height: 5)
                Text(prefix + " " + date.formatted(date: .omitted, time: .shortened))
                if context.date.timeIntervalSince(date) > 900 { Text("· 较旧数据") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.help(date.formatted(date: .complete, time: .standard))
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(String(format: "%.0f%%", window.usedPercent)).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("已用").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.10))
                    Capsule().fill(window.usedPercent >= 90 ? Color.orange : color)
                        .frame(width: max(0, proxy.size.width * window.usedPercent / 100))
                }
            }.frame(height: 5).accessibilityLabel("已使用 \(Int(window.usedPercent))%，剩余 \(Int(window.remainingPercent))%")
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack {
                    Text(String(format: "剩余 %.0f%%", window.remainingPercent))
                    Spacer()
                    Text(resetLabel(now: context.date))
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }.help(window.resetsAt.map { "重置：" + $0.formatted(date: .complete, time: .standard) } ?? "接口未报告重置时间")
        }
    }
    private func resetLabel(now: Date) -> String {
        guard let reset = window.resetsAt else { return "重置时间未知" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "重置时间已过 · 待刷新" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 { return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后重置" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分后重置" }
        return "\(minutes) 分钟后重置"
    }
}

private struct Sparkline: View {
    let samples: [BalanceSample]
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            let values = samples.map { NSDecimalNumber(decimal: $0.amount).doubleValue }
            let minValue = values.min() ?? 0
            let range = max(0.01, (values.max() ?? 0) - minValue)
            let firstTime = samples.first?.date.timeIntervalSince1970 ?? 0
            let timeRange = max(1, (samples.last?.date.timeIntervalSince1970 ?? 0) - firstTime)
            let points = zip(samples, values).map { sample, amount in
                CGPoint(x: geometry.size.width * (sample.date.timeIntervalSince1970 - firstTime) / timeRange,
                        y: 4 + (geometry.size.height - 8) * (1 - (amount - minValue) / range))
            }
            Path { path in
                guard let first = points.first, let last = points.last else { return }
                path.move(to: CGPoint(x: first.x, y: geometry.size.height))
                points.forEach { path.addLine(to: $0) }
                path.addLine(to: CGPoint(x: last.x, y: geometry.size.height)); path.closeSubpath()
            }.fill(LinearGradient(colors: [color.opacity(0.14), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }
            }.stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
    }
}

private extension View {
    func card() -> some View {
        self.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.055), lineWidth: 1))
    }
}
