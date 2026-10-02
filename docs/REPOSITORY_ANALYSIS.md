# 两个上游仓库的分析与整合

分析日期：2026-10-02。通过 GitHub 获取固定提交的目录树和核心源码，按源代码而非截图梳理行为。当前工作目录原本为空，因此本项目采用原生移植，不保留 VS Code 扩展宿主。

| 上游 | 固定提交 | 重点阅读文件 |
| --- | --- | --- |
| [Ganymede404/vscode-codex-usage](https://github.com/Ganymede404/vscode-codex-usage) | `f312abec0c2545f47ec09d558b39b5aeccd223f5` | `src/codexApi.ts`、`codexAuth.ts`、`codexReader.ts`、`types.ts`、`extension.ts`、`format.ts`、`statusBar.ts`、`package.json`、`LICENSE` |
| [pantsari/deepseek-usage-tracker](https://github.com/pantsari/deepseek-usage-tracker) | `f8f54043a2157feba018f989d36ee3b181e56060` | `extension.js`、`pricing.js`、`test/extension.test.js`、`test/pricing.test.js`、`package.json`、`LICENSE`、项目说明 |

## Codex 项目

项目是 TypeScript VS Code 扩展。宿主层负责定时刷新、状态栏和详情页；数据层已经独立成 API、认证与 rollout 读取模块。运行时依赖基本是 VS Code 与 Node 标准库，适合抽取算法，不适合直接作为脱离编辑器的桌面插件执行。

在线查询读取 `auth.json` 的 OAuth `tokens.access_token`。账户 ID 优先使用 `tokens.account_id`，其次从 JWT claims 的 `chatgpt_account_id` 或 `https://api.openai.com/auth` 解出。JWT 在此只用于提取账户选择信息，不是验签或重新登录。API Key 模式不支持该接口。请求为 `GET /backend-api/wham/usage`，携带 Bearer 和可选 `ChatGPT-Account-Id`；上游不刷新 token，避免破坏 CLI 的 refresh token 状态。

响应归一化探测 `rate_limits`、`rateLimits`、`rate_limit`、`usage.rate_limits` 等容器；窗口探测 `primary/secondary` 与 `primary_window/secondary_window`；时长可能以秒或分钟上报。窗口应按实际时长标注，不能把 primary 永远叫「5 小时」、secondary 永远叫「每周」。积分、代码审查、其他功能额度、工作区 spend control 也是独立信息。

离线读取 UTC 日期目录中的近期 rollout；新旧事件都经由 `token_count` 归一化，忽略 `rate_limits: null`。上游按文件修改时间选文件，逐行扫描至最后事件，捕获时间使用文件修改时间；压缩读取依赖运行时是否带 zstd。

迁移处理：保留字段兼容、数据源选择与回退；相对重置改用事件自身 timestamp，避免后续对话写入把重置时间推后。原生读取用反向分块扫描、有界文件集合与内存缓存，按最新有效事件时间选快照。压缩历史明确标记为不支持，避免引入外部工具。窗口未知时保留「未知」，不推测零用量；离线过了 reset 时提示待刷新，不自动归零。

## DeepSeek 项目

项目主要逻辑位于一个 JavaScript 扩展文件，使用 VS Code SecretStorage、globalState、状态栏与 QuickPick；HTTPS 是 Node 标准库，无第三方运行时依赖。相比 Codex，它查询的是充值账户余额，而非订阅额度或 token 使用计数。

`GET https://api.deepseek.com/user/balance` 返回 `balance_infos`，金额通常是十进制字符串；`is_available` 可能为 false，同时仍返回余额，应继续展示并提示不可用。展示选择匹配币种，否则回退到第一项，不能无依据换算 USD 与 CNY。充值与赠送余额是组成部分，可选字段缺失不应阻断总余额。

上游有共享请求的 single-flight、凭据 generation 和状态操作队列，防止菜单刷新与定时器重入、换 Key 后旧请求污染新状态。错误区分鉴权、欠费、429、服务、超时和格式错误。提醒存储已越过阈值；余额恢复后重新启用，临界和耗尽状态有独立标记。

历史按币种保存，最多 500 条、14 天。日消费把相邻余额减少相加、忽略余额增加，再除以观察时长。少于 30 分钟或没有下降时不显示估算。算法无法从余额净变化中恢复同一间隔内被充值抵消的消费，所以它是估算而非账单。

迁移处理：SecretStorage 换成 Security.framework 钥匙串；globalState 换成有界 UserDefaults；单服务任务去重与 generation 检查保留，Key 更新同步发生在主 actor，不需要再模拟 VS Code 的异步 secrets 队列。金额用 Decimal，拒绝 `parseFloat("1oops")` 这类宽松输入。USD/CNY 分别配置阈值，所有币种分别保留历史。网络错误保留旧数据但明确提示。通知默认关闭，由用户开启并授权，以适应菜单栏工具的使用方式。

`pricing.js` 和价格表是人工维护的时段与金额，无法从余额接口获得。已阅读其时区计算和对应测试，但没有把它们作为当前权威价格嵌入应用，而是提供官方价格入口。

## 原生整合映射

| 上游能力 | UsageBar 对应实现 | 取舍 |
| --- | --- | --- |
| VS Code 状态栏 | `App.swift` 的 NSStatusItem + NSPopover | 脱离编辑器，无 Dock 常驻图标 |
| Codex API / auth | `Providers.swift`、`Parsers.swift` | 只读令牌、固定主机、不跟随跳转 |
| rollout reader | `RolloutReader.swift` | 倒读、有界扫描、按事件时间、mtime+size 缓存 |
| 数据类型 / 格式化 | `Models.swift`、`DashboardView.swift` | 统一展示但保留额度与余额的计量区别 |
| SecretStorage | `KeychainStore.swift` | macOS 本机钥匙串，不进入配置文件 |
| balance query | `DeepSeekProvider` | 共享状态单次请求、结构校验、Decimal 金额 |
| balance history | `BalanceHistory.swift` | 按币种、有界采样、充值不算消费 |
| threshold warnings | `BalanceWarnings`、`AppState.swift` | 去重、恢复后重新启用、原生可选通知 |
| Extension configuration | `SettingsView.swift` | 来源、目录、频率、币种、阈值、登录启动 |
| Marketplace / VSIX | `scripts/build-app.sh` | `.app` / `.zip`，可构建 Universal Binary |

选择 SwiftUI + AppKit 是因为目标只有 macOS、功能主要是文本、进度条与设置；系统自带网络、钥匙串、通知和登录项能力已足够。没有 npm 运行时、WebView 和后台服务。轻量目标落实为零第三方运行时、有界 I/O、长轮询间隔、容错退避与进程休眠；实际内存与 CPU 仍应在目标机器上测量，不能由框架选择直接保证。

## 验证范围

离线自动测试覆盖在线响应多种布局、额外额度与预算、相对重置锚点、缺失/null/畸形字段、十进制余额与币种回退、JWT 账户 ID、API Key 登录拒绝、充值估算、阈值去重与恢复、历史上限、真实临时会话文件的跨块扫描与缓存更新、401 在线回退、离线不联网、402/429/503 错误分类。

应用构建、签名与演示启动需要独立验证；真实账号授权、实网端点、系统通知和登录启动不由离线 fixture 测试保证。发布到其他 Mac 还需要 Developer ID 和公证。
