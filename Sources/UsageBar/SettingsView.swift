import SwiftUI
import AppKit
import UsageCore

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var form = SettingsForm()

    private func preference<T>(_ path: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { state.preferences[keyPath: path] }, set: {
            var prefs = state.preferences; prefs[keyPath: path] = $0; state.savePreferences(prefs)
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("UsageBar 设置").font(.title2).bold()
                    Text("按你的工作节奏，安静地查看额度。").font(.callout).foregroundStyle(.secondary)
                    if state.demo { Text("演示模式：凭据、通知和登录项不会写入系统。").font(.caption).foregroundStyle(.orange) }
                }
                GroupBox("Codex") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("数据来源", selection: preference(\.codexSource)) {
                            ForEach(CodexSource.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Text("在线模式复用 auth.json 中的 OAuth 登录；不会刷新或改写登录令牌。失败时回退到本地会话。").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("Codex 目录", text: $form.homeInput).textFieldStyle(.roundedBorder)
                            Button("选择…", action: chooseHome)
                            Button("应用") {
                                let home = form.homeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard home.hasPrefix("/") || home == "~" || home.hasPrefix("~/") else { form.formError = "Codex 目录需要绝对路径或 ~/ 开头的路径。"; return }
                                var prefs = state.preferences; prefs.codexHome = home; state.savePreferences(prefs); form.formError = nil
                            }
                        }
                        Picker("刷新间隔", selection: preference(\.codexInterval)) {
                            Text("30 秒").tag(30.0); Text("1 分钟").tag(60.0); Text("2 分钟").tag(120.0); Text("5 分钟").tag(300.0)
                        }
                        Button("在 Finder 中打开会话目录") {
                            NSWorkspace.shared.open(state.preferences.resolvedCodexHome.appendingPathComponent("sessions"))
                        }.buttonStyle(.link)
                    }.padding(8)
                }
                GroupBox("DeepSeek") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: state.hasKey ? "checkmark.shield" : "key.horizontal").foregroundStyle(state.hasKey ? Color.green : Color.secondary)
                            Text(state.hasKey ? "已连接 · 密钥位于 macOS 钥匙串" : "尚未添加 API Key").font(.caption)
                        }
                        HStack {
                            SecureField(state.hasKey ? "输入新 API Key 以替换" : "输入 DeepSeek API Key", text: $form.keyInput)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("deepseek-api-key-input")
                            Button("粘贴", action: pasteKey)
                                .help("将剪贴板中的 API Key 填入输入框")
                        }
                        HStack {
                            Button("保存密钥") { if state.saveKey(form.keyInput) { form.keyInput = "" } }.disabled(form.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.demo)
                            Button("删除密钥", role: .destructive) { state.clearKey(); form.keyInput = "" }.disabled(!state.hasKey || state.demo)
                            Spacer()
                            Link("获取密钥 ↗", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                        }
                        Text("替换或删除密钥会清除旧账户余额历史。密钥仅发送给 api.deepseek.com。").font(.caption).foregroundStyle(.secondary)
                        Picker("刷新间隔", selection: preference(\.deepseekInterval)) {
                            Text("1 分钟").tag(60.0); Text("5 分钟").tag(300.0); Text("10 分钟").tag(600.0); Text("30 分钟").tag(1800.0)
                        }
                        HStack { Text("币种"); Spacer(); Text("人民币 CNY").foregroundStyle(.secondary) }
                        Text("仅显示接口返回的人民币余额，不做汇率换算。").font(.caption).foregroundStyle(.secondary)
                        HStack { Text("CNY 提醒").frame(width: 68, alignment: .leading); TextField("75, 35, 7", text: $form.cnyInput).textFieldStyle(.roundedBorder) }
                        HStack {
                            Button("保存阈值", action: saveThresholds)
                            Spacer()
                            Button("清除余额历史") { state.clearHistory() }
                        }
                    }.padding(8)
                }
                GroupBox("通用") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("菜单栏只显示图标", isOn: preference(\.compactMenu))
                        Toggle("余额和额度通知", isOn: preference(\.notifications)).disabled(state.demo)
                        Text("余额低于阈值时提醒；在线 Codex 额度使用达到 90% 时提醒。默认关闭。").font(.caption).foregroundStyle(.secondary)
                        Toggle("登录时自动启动", isOn: Binding(get: { state.loginEnabled }, set: { state.setLogin($0) })).disabled(state.demo)
                    }.padding(8)
                }
                if let error = form.formError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let notice = state.settingsNotice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("UsageBar 1.0 · macOS 13+").font(.caption).bold()
                    Text("基于两个 MIT 开源项目的逻辑移植，使用系统原生框架，无第三方运行时。Codex 在线接口未公开，可能变化。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Link("Codex 原项目 ↗", destination: URL(string: "https://github.com/Ganymede404/vscode-codex-usage")!)
                        Link("DeepSeek 原项目 ↗", destination: URL(string: "https://github.com/pantsari/deepseek-usage-tracker")!)
                    }.font(.caption)
                    Button("开源许可证") {
                        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") { NSWorkspace.shared.open(url) }
                        else { state.settingsNotice = "请查看项目中的 THIRD_PARTY_NOTICES.txt。" }
                    }.buttonStyle(.link).font(.caption)
                }
            }.padding(24)
        }.frame(width: 480, height: 660).background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            form.homeInput = state.preferences.codexHome
            form.cnyInput = state.preferences.cnyThresholds.map { String(format: "%g", $0) }.joined(separator: ", ")
        }
    }
    private func pasteKey() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            form.formError = "剪贴板中没有可粘贴的文本。"
            return
        }
        form.keyInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        form.formError = nil
    }
    private func chooseHome() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = state.preferences.resolvedCodexHome
        if panel.runModal() == .OK, let url = panel.url { form.homeInput = url.path }
    }
    private func saveThresholds() {
        guard let cny = BalanceHistory.thresholds(form.cnyInput) else {
            form.formError = "阈值需要正数，例如 10, 5, 1。"; return
        }
        var prefs = state.preferences; prefs.cnyThresholds = cny
        state.savePreferences(prefs); form.formError = nil; state.settingsNotice = "提醒阈值已保存。"
    }
}

@MainActor
private final class SettingsForm: ObservableObject {
    @Published var keyInput = ""
    @Published var cnyInput = ""
    @Published var homeInput = ""
    @Published var formError: String?
}
