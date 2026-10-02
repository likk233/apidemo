# Windows 版验证记录

2026-10-02，在 macOS 上新增原生 C++17 / Win32 托盘版，保留已有 Swift/macOS 版。

## 已完成

| 检查 | 结果 |
| --- | --- |
| 可移植核心回归 | macOS 原生运行，17 项检查全部通过 |
| x64 Release 交叉编译 | 通过；生成 Windows GUI PE32+ EXE |
| ARM64 Release 交叉编译 | 通过；生成 Windows GUI ARM64 PE32+ EXE |
| Windows 平台检查程序 | x64 编译通过；包含隔离 DPAPI、中文路径、OAuth 账户提取、受限请求和离线读取检查 |
| 动态依赖 | 仅导入 Windows 系统 DLL / UCRT API，不需要另附 C++、.NET 或 Node.js 运行库 |
| 应用资源 | 包含图标、版本信息、普通用户权限及 DPI manifest |
| ZIP | x64 与 ARM64 包通过 CRC 检查；仅包含 EXE、使用说明和许可证 |
| 源码准备 | README 本地链接、Shell 语法及 Git diff 空白检查通过 |
| 凭据检查 | 新源码、EXE 和解压后的发布包未发现真实密钥；测试仅使用明确的假数据 |

核心检查覆盖额度窗口、布尔值及负值拒绝、camelCase、积分与额外额度、事件时间戳、精确人民币金额、缺失 CNY、重复币种、阈值、旧配置兼容、消费估算、历史上限、提醒去重和 JSON 大小/嵌套限制。

交叉编译使用官方 LLVM-MinGW `20260826`（LLVM 23.1.0 / UCRT）。下载工具链的 SHA256 与 GitHub 发布资产的 digest 一致：

```text
48bedd161f14ae25a3646cb750b57ee3188e97e34bd3c52240c1810aa74d6a7f
```

JSON 解析使用 nlohmann/json `3.12.0`，源码及 MIT 许可已附带；下载内容的 Git blob SHA 与官方 API 返回一致。LLVM / MinGW 静态运行库许可也随发布 ZIP 附带。

## 尚未执行

开发机器未提供 Windows 或 Wine，因此未在这里运行 EXE、Windows 平台检查程序，或进行托盘及设置的视觉验证。真实账户查询、密钥加密交互、粘贴、系统通知、登录启动和不同 DPI 显示仍需 Windows 实机检查。两个 EXE 均未进行商业代码签名。

[Windows CI](../.github/workflows/windows.yml) 已配置 Windows x64 编译、核心及平台检查和演示启动检查；本次没有推送或触发远端工作流，不能将该配置视为 CI 已通过。ARM64 产物已交叉编译，但尚未在 ARM64 Windows 上运行。

## 发布文件

- `dist/windows-x64/UsageBar.exe`
- `dist/UsageBar-Windows-x64.zip`
- `dist/windows-arm64/UsageBar.exe`
- `dist/UsageBar-Windows-arm64.zip`

建议发布完整 ZIP 并保留其中的许可证文件。Git 的 `.gitignore` 已排除生成的 EXE、ZIP 输出目录及中间文件；将 ZIP 上传到 GitHub Releases，源码通过正常 Git 提交管理。

## 发布前隐私复查

2026-10-02，复查 Windows 源码、构建脚本、相关文档、x64 / ARM64 EXE、输出目录和两个 ZIP 解压成员，共 58 个文件或包内成员。检查密钥前缀、OAuth JWT、GitHub / AWS 凭据、私钥、凭据 URL、个人绝对路径及邮箱；EXE 同时扫描 UTF-8 与 UTF-16 字符串，并人工核对凭据赋值、存储与网络请求代码。

- 未发现真实 API Key、登录令牌、用户本机用户名或项目绝对路径。测试使用明确的假密钥及假账户。
- EXE 中的 `/Users/.../llvm-project/...` 字符串来自第三方预编译运行库；已与 LLVM-MinGW 静态库核对，不属于项目用户的信息。源码及许可证中的邮箱属于第三方版权声明。
- 两个 ZIP 均通过 CRC 检查，且各自仅含 EXE、说明和许可证这 8 个文件，没有登录文件、运行配置、余额历史或密钥文件。
- DeepSeek 密钥在运行时由当前 Windows 用户的 DPAPI 加密，写入 `%LOCALAPPDATA%\UsageBar\deepseek-key.dat`。`state.json` 保存设置、个人 Codex 目录、余额历史和提醒状态，不保存 API Key；这些运行文件不在当前发布包内，仍应作为个人数据保留在本机。
- 查询代码仅允许通过 HTTPS 请求 `chatgpt.com/backend-api/wham/usage` 和 `api.deepseek.com/user/balance`，并禁止重定向；未发现额外的遥测或凭据上传地址。
- `.gitignore` 补充排除 `deepseek-key.dat` 和 `state.json`，避免未来复制运行数据到项目后误提交；现有源码不受影响。

此结论针对当前文件的静态检查与打包内容核对；尚未进行 Windows 实机网络抓包，也未审计 Git 历史。
