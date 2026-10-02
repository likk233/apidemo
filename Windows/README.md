# UsageBar Windows

适用于 Windows 10 1607 及以上 / Windows 11 的原生托盘工具。解压后运行 `UsageBar.exe`，无需安装 .NET、Node.js 或额外的 VC++ 运行库，不需要管理员权限。

普通 Intel / AMD 电脑选择 `UsageBar-Windows-x64.zip`；Windows ARM 设备可选择 `UsageBar-Windows-arm64.zip`。两种包中的程序都叫 `UsageBar.exe`，应分别解压到不同目录。

首次运行显示额度面板；关闭面板会继续在系统托盘运行。任务栏右下角可能将图标收入「隐藏的图标」中。左键点击图标打开或隐藏面板，右键可刷新、打开设置和退出。

Windows 托盘显示图标，悬停提示和右键菜单显示 `C 12% · D ¥16.34`；不会像 macOS 菜单栏那样常驻展示整段文字。

## 配置

- Codex 默认目录为 `%USERPROFILE%\.codex`，设置了 `CODEX_HOME` 时优先使用该值。可在设置中选择目录；支持中文路径、`~/` 和 Windows 环境变量展开。
- 在线查询只读取已有 OAuth 登录的 `auth.json`，不刷新或改写令牌。失败时读取最近 7 天的本地 `rollout-*.jsonl`；仅 API Key 登录和 `.jsonl.zst` 暂不支持。
- WSL 内的 Codex 数据不会自动定位；可通过目录选择器选择 Windows 能访问的对应文件夹。
- DeepSeek 仅显示人民币 CNY。粘贴 API Key 后点击「保存密钥」；接口没有返回 CNY 时会显示提示，不使用 USD 代替。
- 默认 CNY 提醒为 `75, 35, 7`；修改后点击「保存设置和阈值」。通知默认关闭，可勾选「余额和额度通知」。Windows 勿扰模式或通知设置可能影响显示。
- 默认刷新间隔为 Codex 60 秒、DeepSeek 300 秒。请求失败会延长重试间隔。
- 本地余额历史保留最多 14 天、500 条。至少记录 30 分钟并出现余额下降后，显示消费估算；余额上涨不计为消费。
- 勾选登录启动并保存后，会在当前用户的 Run 注册表项中登记 EXE 的完整路径。开启后请保留 EXE 所在目录；移动程序后重新保存登录启动设置。

## 数据与隐私

DeepSeek 密钥使用 Windows DPAPI 的当前用户模式加密，存入 `%LOCALAPPDATA%\UsageBar\deepseek-key.dat`；配置、历史和提醒状态位于同目录的 `state.json`。密钥不会写入状态 JSON 或安装包。解密通常需要原 Windows 用户和设备，不要将本地数据目录放进公开仓库。

在线请求仅发送给 `chatgpt.com` 或 `api.deepseek.com`，禁用 HTTP 重定向并使用系统 TLS 校验。没有遥测、第三方代理或对话正文持久化。替换或删除本地密钥会清除旧账户余额历史；不会修改平台上的密钥。

## 命令

```powershell
# 正常启动
.\UsageBar.exe

# 仅启动托盘
.\UsageBar.exe --background

# 打开设置
.\UsageBar.exe --show-settings

# 使用样例，不读取真实凭据、发送请求或保存配置
.\UsageBar.exe --demo
```

需要完全退出时，从托盘右键菜单选择「退出 UsageBar」。演示实例和正式实例独立，每种模式只允许一个实例。

## 开发

源码位于 `Windows/`，采用 C++17、Win32、WinHTTP 和 DPAPI。JSON 解析库 nlohmann/json 3.12.0 已附带源码及 MIT 许可证，构建时无需下载依赖。

Windows 上安装 Visual Studio 2022 的「使用 C++ 的桌面开发」及 CMake 后，在项目根目录运行：

```powershell
./scripts/build-windows.ps1 -Architecture x64
```

macOS / Linux 可以使用 [LLVM-MinGW](https://github.com/mstorsjo/llvm-mingw/releases) 交叉编译：

```bash
USAGEBAR_WINDOWS_TOOLCHAIN=/path/to/llvm-mingw scripts/build-windows.sh x64
# 可选 Windows ARM64 构建
USAGEBAR_WINDOWS_TOOLCHAIN=/path/to/llvm-mingw scripts/build-windows.sh arm64
```

跨平台核心测试：

```bash
scripts/test-windows-core.sh
```

GitHub Windows 工作流会构建 x64 程序、运行核心测试与演示启动检查，并提供 `UsageBar-Windows-x64.zip` 附件，不会自动发布 Release。

## 发布与验证

发布 ZIP 时保留其中的 `LICENSE`、`THIRD_PARTY_NOTICES.txt`、`JSON-LICENSE.txt` 及 `licenses/`。`licenses/` 包含 LLVM-MinGW 静态运行库的许可声明。默认 EXE 未进行商业代码签名；正式公开发布可使用自己的代码签名证书。

当前开发环境是 macOS，交叉编译检查不能代替 Windows 实机运行验证。托盘交互、DPAPI、中文输入和粘贴、网络连接、系统通知及登录启动应在目标 Windows 设备上验证。CI 工作流中的 Windows 检查只在上传后运行，不能把尚未执行的工作流当作已通过。

本次已完成 17 项可移植核心回归、x64 / ARM64 交叉编译和包内容检查；详细记录见源码中的 `docs/WINDOWS_VERIFICATION.md`。
