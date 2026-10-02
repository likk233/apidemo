#include "Platform.h"
#include <shellapi.h>
#include <commctrl.h>
#include <shobjidl.h>
#include <uxtheme.h>
#include <chrono>
#include <atomic>
#include <cmath>
#include <memory>
#include <sstream>
#include <thread>

using namespace usagebar;
namespace fs = std::filesystem;
constexpr UINT TrayMessage = WM_APP + 1, ResultMessage = WM_APP + 2;
constexpr int Refresh = 101, Settings = 102, Quit = 103, Details = 104, Usage = 105, TopUp = 106;
constexpr int Home = 201, Source = 202, CodexInterval = 203, Key = 204, Paste = 205, SaveKey = 206, DeleteKey = 207,
              Thresholds = 208, DeepInterval = 209, Notifications = 210, Login = 211, SaveSettings = 212, ClearHistory = 213, Browse = 214, GetKey = 215, KeyStatus = 216;
static int64_t now() { return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count(); }
struct Result { bool codex; int generation; std::optional<Codex> quota; std::optional<Balance> balance; std::string error; };
struct Worker { std::thread thread; std::shared_ptr<std::atomic<bool>> done; };
struct Application {
    HWND window = nullptr, settings = nullptr; HINSTANCE instance = nullptr;
    Preferences prefs; std::vector<Sample> history; std::set<std::string> balanceWarnings, codexWarnings;
    std::optional<Codex> codex; std::optional<Balance> balance;
    std::string codexError, deepseekError, settingsNotice;
    bool demo = false, hasKey = false, loadingCodex = false, loadingBalance = false, shuttingDown = false, trayAdded = false;
    int codexGeneration = 0, keyGeneration = 0, codexFailures = 0, balanceFailures = 0, dpi = 96;
    int64_t nextCodex = 0, nextBalance = 0;
    HFONT normal = nullptr, title = nullptr, metric = nullptr, small = nullptr, settingsFont = nullptr;
    HICON icon = nullptr; UINT taskbarCreated = 0;
    std::vector<Worker> workers;
    int settingsDpi = 96, settingsScroll = 0, settingsHeight = 650;
} app;
static int px(int value) { return MulDiv(value, app.dpi, 96); }
// Fit the complete dashboard into the available monitor height, including high DPI.
static int py(int value) {
    RECT bounds{}; if (app.window) GetClientRect(app.window,&bounds);
    return bounds.bottom > 0 ? MulDiv(value,bounds.bottom,700) : px(value);
}
static int spx(int value) { return MulDiv(value, app.settingsDpi, 96); }
static void openLink(const wchar_t* url) { ShellExecuteW(app.window, L"open", url, nullptr, nullptr, SW_SHOWNORMAL); }
static void showError(HWND owner, const std::string& error) { MessageBoxW(owner, wide(error).c_str(), L"UsageBar", MB_OK | MB_ICONINFORMATION); }
static void saveState() {
    if (app.demo) return;
    Json samples = Json::array();
    for (const auto& s : app.history) samples.push_back(Json{{"date", s.date}, {"amount", s.amount}});
    writeAtomic(dataDirectory() / L"state.json", Json{{"preferences", preferencesJson(app.prefs)}, {"samples", samples}, {"balanceWarnings", app.balanceWarnings}, {"codexWarnings", app.codexWarnings}}.dump(2));
}
static void saveStateQuietly() {
    try { saveState(); } catch (const std::exception& e) { app.settingsNotice = e.what(); }
}
static void loadState() {
    app.prefs.home = defaultCodexHome();
    if (app.demo) return;
    auto path = dataDirectory() / L"state.json";
    std::error_code error;
    if (fs::exists(path, error)) {
        try {
            auto j = parseJson(readBytes(path));
            if (j.contains("preferences")) app.prefs = parsePreferences(j["preferences"], app.prefs.home);
            if (j.contains("samples") && j["samples"].is_array()) for (const auto& s : j["samples"]) {
                if (s.is_object() && s.contains("date") && s["date"].is_number_integer() && s.contains("amount") && s["amount"].is_number_integer()) {
                    int64_t date = s["date"].get<int64_t>();
                    if (date >= now() - 14 * 86400 && date <= now()) app.history.push_back({date, s["amount"].get<Money>()});
                }
            }
            std::sort(app.history.begin(), app.history.end(), [](const auto& a, const auto& b) { return a.date < b.date; });
            if (app.history.size() > 500) app.history.erase(app.history.begin(), app.history.end() - 500);
            if (j.contains("balanceWarnings") && j["balanceWarnings"].is_array()) for (const auto& value : j["balanceWarnings"]) if (value.is_string()) app.balanceWarnings.insert(value.get<std::string>());
            if (j.contains("codexWarnings") && j["codexWarnings"].is_array()) for (const auto& value : j["codexWarnings"]) if (value.is_string()) app.codexWarnings.insert(value.get<std::string>());
        } catch (...) { app.settingsNotice = "本地配置无法读取，已使用默认设置。"; }
    }
    try { auto key = readKey(); app.hasKey = !key.empty(); SecureZeroMemory(key.data(), key.size()); }
    catch (const std::exception& e) { app.deepseekError = e.what(); }
}
static void seedDemo() {
    int64_t time = now();
    app.codex = parseCodex(parseJson(R"({"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":38,"limit_window_seconds":18000,"reset_after_seconds":8140},"secondary_window":{"used_percent":64,"limit_window_seconds":604800,"reset_after_seconds":226800}},"credits":{"balance":"12.00","has_credits":true}})"), time, "demo");
    app.balance = Balance{17899000000, Money(15800000000), Money(2099000000), true, time}; app.hasKey = true;
    for (int i = 0; i < 24; ++i) app.history.push_back({time + (i - 23) * 3600, app.balance->total + (23 - i) * Money(125000000)});
}
static std::wstring summary() {
    std::ostringstream text;
    if (app.codex && !app.codex->windows.empty()) text << ((app.codex->source == "rollout" || !app.codexError.empty()) ? "~" : "") << "C " << std::lround(highestUsed(*app.codex)) << '%';
    else text << "C —";
    text << "  ·  D " << (app.balance ? (!app.deepseekError.empty() ? "~" : "") + money(app.balance->total) : "—");
    return wide(text.str());
}
static NOTIFYICONDATAW trayData() {
    NOTIFYICONDATAW data{}; data.cbSize = sizeof(data); data.hWnd = app.window; data.uID = 1;
    data.uCallbackMessage = TrayMessage; data.hIcon = app.icon;
    return data;
}
static void updateTray(bool add = false) {
    add = add || !app.trayAdded;
    auto data = trayData(); data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
    auto tip = L"UsageBar · " + summary() + L"\n点击查看详情，右键打开菜单";
    wcsncpy_s(data.szTip, tip.c_str(), _TRUNCATE);
    app.trayAdded = Shell_NotifyIconW(add ? NIM_ADD : NIM_MODIFY, &data) != FALSE;
    if (add) { data.uVersion = NOTIFYICON_VERSION_4; Shell_NotifyIconW(NIM_SETVERSION, &data); }
}
static void notify(const std::string& title, const std::string& text) {
    if (app.demo || !app.prefs.notifications) return;
    auto data = trayData(); data.uFlags = NIF_INFO; data.dwInfoFlags = NIIF_INFO | NIIF_RESPECT_QUIET_TIME;
    auto t = wide(title), body = wide(text);
    wcsncpy_s(data.szInfoTitle, t.c_str(), _TRUNCATE); wcsncpy_s(data.szInfo, body.c_str(), _TRUNCATE);
    Shell_NotifyIconW(NIM_MODIFY, &data);
}
static void checkWarnings() {
    if (!app.prefs.notifications || app.demo) return;
    if (app.balance && app.deepseekError.empty()) {
        auto message = balanceWarning(*app.balance, app.prefs.thresholds, app.balanceWarnings);
        if (!message.empty()) notify("DeepSeek 余额提醒", message);
    }
    if (app.codex && app.codexError.empty() && app.codex->source == "api") {
        for (const auto& w : app.codex->windows) if (w.used >= 90) {
            auto id = w.id + ':' + std::to_string(w.resets);
            if (app.codexWarnings.insert(id).second) notify("Codex 额度提醒", w.title + "已使用 " + std::to_string(int(w.used)) + "% 。");
        }
        if (app.codexWarnings.size() > 100) app.codexWarnings.clear();
    }
}
static void refresh(bool codex) {
    if (app.demo || app.shuttingDown || (codex ? app.loadingCodex : app.loadingBalance)) return;
    if (!codex && !app.hasKey) return;
    (codex ? app.loadingCodex : app.loadingBalance) = true;
    int generation = codex ? app.codexGeneration : app.keyGeneration;
    auto preferences = app.prefs; HWND target = app.window;
    for (auto it=app.workers.begin(); it!=app.workers.end();) {
        if (it->done->load()) { it->thread.join(); it=app.workers.erase(it); } else ++it;
    }
    auto done=std::make_shared<std::atomic<bool>>(false);
    app.workers.push_back(Worker{std::thread([codex, generation, preferences, target, done] {
        auto result = std::make_unique<Result>(); result->codex = codex; result->generation = generation;
        try { if (codex) result->quota = fetchCodex(preferences, now()); else result->balance = fetchBalance(now()); }
        catch (const std::exception& e) {
            // JSON exception text can contain response fragments; never surface those fragments.
            result->error = dynamic_cast<const Json::exception*>(&e) ? "返回数据格式无法识别。" : e.what();
        }
        if (PostMessageW(target, ResultMessage, 0, reinterpret_cast<LPARAM>(result.get()))) result.release();
        done->store(true);
    }),done});
    InvalidateRect(app.window, nullptr, FALSE);
}
static void refreshAll() { refresh(true); refresh(false); }
static int64_t delay(int interval, int failures) { return std::min<int64_t>(1800, int64_t(interval) << std::min(5, failures)); }
static void receiveResult(std::unique_ptr<Result> result) {
    if (result->generation != (result->codex ? app.codexGeneration : app.keyGeneration)) return;
    if (result->codex) {
        app.loadingCodex = false; app.codexError = result->error;
        if (result->quota) { app.codex = std::move(result->quota); app.codexFailures = 0; } else ++app.codexFailures;
        app.nextCodex = now() + delay(app.prefs.codexInterval, app.codexFailures);
    } else {
        app.loadingBalance = false; app.deepseekError = result->error;
        if (result->balance) { app.balance = result->balance; record(app.history, *app.balance); app.balanceFailures = 0; } else ++app.balanceFailures;
        app.nextBalance = now() + delay(app.prefs.deepseekInterval, app.balanceFailures);
    }
    checkWarnings(); saveStateQuietly(); updateTray(); InvalidateRect(app.window, nullptr, FALSE);
}
static void clearAccountState() {
    ++app.keyGeneration; app.loadingBalance = false; app.balance.reset(); app.history.clear(); app.balanceWarnings.clear();
    app.deepseekError.clear(); app.balanceFailures = 0; app.nextBalance = 0; saveState(); updateTray(); InvalidateRect(app.window, nullptr, FALSE);
}
static void makeFonts() {
    for (HFONT font : {app.normal, app.title, app.metric, app.small}) if (font) DeleteObject(font);
    auto create = [](int size, int weight) { return CreateFontW(-px(size), 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI"); };
    app.normal = create(13, FW_NORMAL); app.small = create(11, FW_NORMAL); app.title = create(18, FW_SEMIBOLD); app.metric = create(29, FW_SEMIBOLD);
}
static void text(HDC dc, const std::wstring& value, int x, int y, int w, int h, HFONT font, COLORREF color = RGB(232,232,232), UINT flags = DT_LEFT | DT_WORDBREAK | DT_NOPREFIX) {
    auto old = SelectObject(dc, font); SetBkMode(dc, TRANSPARENT); SetTextColor(dc, color);
    RECT rect{px(x), py(y), px(x + w), py(y + h)}; DrawTextW(dc, value.c_str(), int(value.size()), &rect, flags); SelectObject(dc, old);
}
static void box(HDC dc, int x, int y, int w, int h, COLORREF color, int radius = 10) {
    auto brush = CreateSolidBrush(color); auto oldBrush = SelectObject(dc, brush); auto oldPen = SelectObject(dc, GetStockObject(NULL_PEN));
    RoundRect(dc, px(x), py(y), px(x+w), py(y+h), px(radius), px(radius));
    SelectObject(dc, oldBrush); SelectObject(dc, oldPen); DeleteObject(brush);
}
static std::wstring resetText(int64_t date) {
    if (!date) return L"未报告重置时间";
    if (date <= now()) return L"等待服务更新额度";
    int64_t minutes = (date - now() + 59) / 60;
    std::wostringstream out;
    if (minutes >= 1440) out << minutes / 1440 << L" 天 ";
    out << minutes / 60 % 24 << L" 小时 " << minutes % 60 << L" 分后重置"; return out.str();
}
static std::wstring timestamp(int64_t stamp) {
    time_t time = stamp; std::tm date{}; localtime_s(&date, &time); wchar_t buffer[32];
    wcsftime(buffer, 32, L"%m-%d %H:%M", &date); return buffer;
}
static void paintDashboard(HWND window) {
    PAINTSTRUCT ps; HDC original = BeginPaint(window, &ps); RECT bounds; GetClientRect(window, &bounds);
    HDC dc = CreateCompatibleDC(original); HBITMAP bitmap = CreateCompatibleBitmap(original, bounds.right, bounds.bottom); auto oldBitmap = SelectObject(dc, bitmap);
    HBRUSH background = CreateSolidBrush(RGB(29,29,29)); FillRect(dc, &bounds, background); DeleteObject(background);
    int width = MulDiv(bounds.right, 96, app.dpi);
    text(dc, L"UsageBar", 22, 15, width - 150, 26, app.title);
    text(dc, app.demo ? L"演示数据 · 不读取真实凭据" : L"AI 额度与余额，一眼掌握", 22, 43, width - 44, 20, app.small, RGB(150,150,150));
    box(dc, 14, 76, width - 28, 230, RGB(39,39,39));
    text(dc, L"Codex", 30, 90, 200, 26, app.title);
    text(dc, app.loadingCodex ? L"正在刷新…" : app.codex ? wide(app.codex->plan + (app.codex->source == "rollout" ? " · 离线快照" : app.demo ? " · 演示" : " · 在线")) : L"账户额度", 30, 119, width - 60, 20, app.small, RGB(150,150,150));
    if (app.codex) {
        if (app.codex->windows.empty()) text(dc,L"接口未报告额度窗口，可查看更多账户信息。",30,153,width-60,70,app.normal,RGB(150,150,150));
        for (size_t i = 0; i < std::min<size_t>(2, app.codex->windows.size()); ++i) {
            const auto& w = app.codex->windows[i]; int y = 149 + int(i) * 67;
            text(dc, wide(w.title), 30, y, 180, 22, app.normal);
            text(dc, std::to_wstring(int(std::lround(w.used))) + L"% 已用", width - 133, y, 100, 22, app.normal, RGB(238,238,238), DT_RIGHT | DT_SINGLELINE);
            box(dc, 30, y + 25, width - 60, 5, RGB(53,68,65), 4);
            int remaining = int((width - 60) * (100 - w.used) / 100);
            if (remaining > 0) box(dc, 30, y + 25, remaining, 5, RGB(32,161,137), 4);
            text(dc, L"剩余 " + std::to_wstring(int(std::lround(100-w.used))) + L"%", 30, y + 35, 110, 19, app.small, RGB(150,150,150));
            text(dc, resetText(w.resets), 135, y + 35, width - 165, 19, app.small, RGB(150,150,150), DT_RIGHT | DT_SINGLELINE);
        }
        auto status = !app.codexError.empty() ? L"刷新失败，显示上次数据" : !app.codex->fallback.empty() ? L"在线不可用，已回退离线" : L"更新 " + timestamp(app.codex->captured);
        text(dc, status, 30, 282, width - 60, 18, app.small, RGB(150,150,150));
    } else text(dc, wide(app.codexError.empty() ? "等待 Codex 数据…" : app.codexError), 30, 152, width - 60, 132, app.normal, RGB(193,179,145));
    box(dc, 14, 318, width - 28, 250, RGB(39,39,39));
    text(dc, L"DeepSeek", 30, 332, 200, 26, app.title);
    text(dc, L"CNY", width - 75, 337, 45, 20, app.small, RGB(150,150,150), DT_RIGHT | DT_SINGLELINE);
    if (app.balance) {
        const auto& b = *app.balance;
        text(dc, wide(money(b.total)), 30, 369, width - 60, 44, app.metric);
        text(dc, L"充值 " + (b.toppedUp ? wide(money(*b.toppedUp)) : L"—") + L"    赠送 " + (b.granted ? wide(money(*b.granted)) : L"—"), 30, 414, width - 60, 24, app.small, RGB(178,178,178));
        if (app.history.size() >= 2) {
            auto [low, high] = std::minmax_element(app.history.begin(), app.history.end(), [](const auto& a, const auto& b) { return a.amount < b.amount; });
            long double range = std::max<long double>(1, static_cast<long double>(high->amount) - low->amount);
            auto pen = CreatePen(PS_SOLID, px(2), RGB(79,133,219)); auto old = SelectObject(dc, pen);
            for (size_t i = 0; i < app.history.size(); ++i) {
                int x = 30 + int(i * (width - 60) / (app.history.size() - 1));
                int y = 473 - int((static_cast<long double>(app.history[i].amount) - low->amount) / range * 27);
                if (!i) MoveToEx(dc, px(x), py(y), nullptr); else LineTo(dc, px(x), py(y));
            }
            SelectObject(dc, old); DeleteObject(pen);
        }
        if (auto value = estimate(app.history)) {
            text(dc, L"估算日消费 " + wide(money(Money(std::min(value->perDay, 90000000000.0) * MoneyScale))) + L" / 天", 30, 485, width - 60, 23, app.normal);
            auto days = value->daysLeft < 1 ? L"不足 1 天" : value->daysLeft > 365 ? L"超过 365 天" : L"约 " + std::to_wstring(int(std::round(value->daysLeft))) + L" 天";
            text(dc, L"按当前消费速度：" + std::wstring(days), 30, 510, width - 60, 20, app.small, RGB(150,150,150));
        } else text(dc, L"记录满 30 分钟且有余额下降后显示消费估算", 30, 485, width - 60, 43, app.small, RGB(150,150,150));
        text(dc, !app.deepseekError.empty() ? L"刷新失败，显示上次余额" : !b.available || b.total <= 0 ? L"账户没有可用额度，请充值" : app.loadingBalance ? L"正在刷新人民币余额…" : L"更新 " + timestamp(b.captured), 30, 543, width - 60, 18, app.small, RGB(150,150,150));
    } else {
        text(dc, wide(!app.deepseekError.empty() ? app.deepseekError : app.hasKey ? "正在查询人民币余额…" : "连接 DeepSeek，随时查看人民币余额"), 30, 377, width - 60, 88, app.normal, RGB(193,179,145));
        text(dc, L"在设置中添加 API Key；密钥由 Windows 加密保存。", 30, 491, width - 60, 48, app.small, RGB(150,150,150));
    }
    text(dc, L"凭据留在本机 · 无遥测 · 只读查询", 23, 627, width - 46, 20, app.small, RGB(150,150,150), DT_CENTER | DT_SINGLELINE);
    BitBlt(original, 0, 0, bounds.right, bounds.bottom, dc, 0, 0, SRCCOPY);
    SelectObject(dc, oldBitmap); DeleteObject(bitmap); DeleteDC(dc); EndPaint(window, &ps);
}
static HWND control(HWND parent, const wchar_t* klass, const wchar_t* label, DWORD style, int x, int y, int width, int height, int id = 0, bool setting = false) {
    auto scale = setting ? spx : px;
    HWND handle = CreateWindowExW((wcscmp(klass, L"EDIT") == 0) ? WS_EX_CLIENTEDGE : 0, klass, label, WS_CHILD | WS_VISIBLE | style,
        scale(x), setting ? scale(y) : py(y), scale(width), setting ? scale(height) : py(y+height)-py(y), parent, reinterpret_cast<HMENU>(INT_PTR(id)), app.instance, nullptr);
    SendMessageW(handle, WM_SETFONT, reinterpret_cast<WPARAM>(setting ? app.settingsFont : app.normal), TRUE); return handle;
}
static void dashboardButtons() {
    RECT bounds; GetClientRect(app.window, &bounds); int width = MulDiv(bounds.right, 96, app.dpi);
    for (int id : {Refresh, Settings, Quit, Details, Usage, TopUp}) if (auto h = GetDlgItem(app.window, id)) DestroyWindow(h);
    control(app.window, L"BUTTON", L"设置", BS_PUSHBUTTON | WS_TABSTOP, width - 91, 22, 66, 29, Settings);
    control(app.window, L"BUTTON", L"更多账户信息", BS_PUSHBUTTON | WS_TABSTOP, 23, 582, 110, 27, Details);
    control(app.window, L"BUTTON", L"用量面板", BS_PUSHBUTTON | WS_TABSTOP, 147, 582, 100, 27, Usage);
    control(app.window, L"BUTTON", L"充值", BS_PUSHBUTTON | WS_TABSTOP, width - 102, 582, 79, 27, TopUp);
    control(app.window, L"BUTTON", L"刷新全部", BS_PUSHBUTTON | WS_TABSTOP, 23, 656, 96, 29, Refresh);
    control(app.window, L"BUTTON", L"退出", BS_PUSHBUTTON | WS_TABSTOP, width - 102, 656, 79, 29, Quit);
    EnableWindow(GetDlgItem(app.window, Refresh), !app.demo);
}
static void fitWindow(HWND window, int width, int height, int dpi, bool trayPosition) {
    RECT area; SystemParametersInfoW(SPI_GETWORKAREA, 0, &area, 0);
    RECT rect{0,0,MulDiv(width,dpi,96),MulDiv(height,dpi,96)};
    AdjustWindowRectExForDpi(&rect, DWORD(GetWindowLongPtrW(window,GWL_STYLE)), FALSE, DWORD(GetWindowLongPtrW(window,GWL_EXSTYLE)), dpi);
    int w=int(rect.right-rect.left), h=std::min(int(rect.bottom-rect.top), int(area.bottom-area.top));
    POINT mouse; GetCursorPos(&mouse); HMONITOR monitor=MonitorFromPoint(mouse,MONITOR_DEFAULTTONEAREST); MONITORINFO info{sizeof(info)};
    if (GetMonitorInfoW(monitor,&info)) { area=info.rcWork; h=std::min(h,int(area.bottom-area.top)); }
    int x=trayPosition ? area.right-w-12 : area.left+(area.right-area.left-w)/2;
    int y=trayPosition ? area.bottom-h-12 : area.top+(area.bottom-area.top-h)/2;
    SetWindowPos(window,nullptr,std::max(int(area.left),x),std::max(int(area.top),y),w,h,SWP_NOZORDER);
}
static std::wstring value(HWND owner, int id) {
    HWND handle=GetDlgItem(owner,id); int length=GetWindowTextLengthW(handle);
    std::wstring text(length+1,0); GetWindowTextW(handle,text.data(),length+1); text.resize(length); return text;
}
static void setValue(HWND owner, int id, const std::wstring& text) { SetWindowTextW(GetDlgItem(owner,id),text.c_str()); }
static int selection(HWND owner, int id) { return int(SendDlgItemMessageW(owner,id,CB_GETCURSEL,0,0)); }
static void combo(HWND parent, const wchar_t* label, int y, int id, const std::vector<std::wstring>& values, int selected) {
    control(parent,L"STATIC",label,0,24,y+5,105,24,0,true);
    auto h=control(parent,L"COMBOBOX",L"",CBS_DROPDOWNLIST|WS_VSCROLL|WS_TABSTOP,132,y,330,220,id,true);
    for(const auto& text:values) SendMessageW(h,CB_ADDSTRING,0,reinterpret_cast<LPARAM>(text.c_str()));
    SendMessageW(h,CB_SETCURSEL,selected,0);
}
static void settingsControls(HWND window) {
    auto label=[&](const wchar_t* s,int y,int h=24) { control(window,L"STATIC",s,0,24,y,490,h,0,true); };
    label(L"Codex",16); combo(window,L"数据来源",47,Source,{L"自动（在线优先）",L"在线（失败时回退）",L"离线会话"}, app.prefs.source=="rollout"?2:app.prefs.source=="api"?1:0);
    label(L"Codex 目录",89);
    control(window,L"EDIT",wide(app.prefs.home).c_str(),ES_AUTOHSCROLL|WS_TABSTOP,24,116,410,29,Home,true);
    control(window,L"BUTTON",L"选择…",BS_PUSHBUTTON|WS_TABSTOP,443,116,73,29,Browse,true);
    combo(window,L"刷新间隔",158,CodexInterval,{L"30 秒",L"1 分钟",L"2 分钟",L"5 分钟"}, app.prefs.codexInterval==30?0:app.prefs.codexInterval==120?2:app.prefs.codexInterval==300?3:1);
    label(L"DeepSeek · 人民币 CNY",209);
    control(window,L"STATIC",app.hasKey?L"已连接 · 密钥由 Windows 加密保存":L"尚未添加 API Key",0,24,239,490,24,KeyStatus,true);
    control(window,L"EDIT",L"",ES_PASSWORD|ES_AUTOHSCROLL|WS_TABSTOP,24,271,410,29,Key,true);
    SendDlgItemMessageW(window,Key,EM_SETCUEBANNER,TRUE,reinterpret_cast<LPARAM>(L"输入 DeepSeek API Key"));
    SendDlgItemMessageW(window,Key,EM_SETLIMITTEXT,4096,0);
    control(window,L"BUTTON",L"粘贴",BS_PUSHBUTTON|WS_TABSTOP,443,271,73,29,Paste,true);
    control(window,L"BUTTON",L"保存密钥",BS_PUSHBUTTON|WS_TABSTOP,24,311,99,29,SaveKey,true);
    control(window,L"BUTTON",L"删除密钥",BS_PUSHBUTTON|WS_TABSTOP,135,311,99,29,DeleteKey,true);
    control(window,L"BUTTON",L"获取密钥",BS_PUSHBUTTON|WS_TABSTOP,410,311,106,29,GetKey,true);
    combo(window,L"刷新间隔",355,DeepInterval,{L"1 分钟",L"5 分钟",L"10 分钟",L"30 分钟"},app.prefs.deepseekInterval==60?0:app.prefs.deepseekInterval==600?2:app.prefs.deepseekInterval==1800?3:1);
    label(L"CNY 提醒",399);
    std::ostringstream thresholds; for(auto n:app.prefs.thresholds) { if(thresholds.tellp()>0) thresholds<<", "; thresholds<<n; }
    control(window,L"EDIT",wide(thresholds.str()).c_str(),ES_AUTOHSCROLL|WS_TABSTOP,132,394,384,29,Thresholds,true);
    control(window,L"BUTTON",L"清除余额历史",BS_PUSHBUTTON|WS_TABSTOP,385,437,131,29,ClearHistory,true);
    control(window,L"BUTTON",L"余额和额度通知",BS_AUTOCHECKBOX|WS_TABSTOP,24,487,290,26,Notifications,true);
    SendDlgItemMessageW(window,Notifications,BM_SETCHECK,app.prefs.notifications?BST_CHECKED:BST_UNCHECKED,0);
    control(window,L"BUTTON",L"登录时自动启动",BS_AUTOCHECKBOX|WS_TABSTOP,24,523,290,26,Login,true);
    SendDlgItemMessageW(window,Login,BM_SETCHECK,!app.demo&&loginEnabled()?BST_CHECKED:BST_UNCHECKED,0);
    control(window,L"BUTTON",L"保存设置和阈值",BS_DEFPUSHBUTTON|WS_TABSTOP,24,568,170,32,SaveSettings,true);
    label(app.demo?L"演示模式：账户查询、凭据、通知和登录项不会写入系统。":L"凭据留在本机 · 无遥测 · 只读查询",615,35);
    if(app.demo) for(int id:{SaveKey,DeleteKey,SaveSettings,ClearHistory,Notifications,Login}) EnableWindow(GetDlgItem(window,id),FALSE);
}
static void scrollSettings(HWND window, int target) {
    RECT bounds; GetClientRect(window,&bounds); int full=spx(app.settingsHeight);
    int maximum=std::max(0,full-int(bounds.bottom)); target=std::clamp(target,0,maximum);
    ScrollWindowEx(window,0,app.settingsScroll-target,nullptr,nullptr,nullptr,nullptr,SW_SCROLLCHILDREN|SW_INVALIDATE|SW_ERASE);
    app.settingsScroll=target;
    SCROLLINFO info{sizeof(info),SIF_RANGE|SIF_PAGE|SIF_POS,0,full-1,UINT(bounds.bottom),target,0}; SetScrollInfo(window,SB_VERT,&info,TRUE);
}
static void chooseHome(HWND owner) {
    IFileOpenDialog* dialog=nullptr;
    if(FAILED(CoCreateInstance(CLSID_FileOpenDialog,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&dialog)))) return;
    DWORD options=0; dialog->GetOptions(&options); dialog->SetOptions(options|FOS_PICKFOLDERS|FOS_FORCEFILESYSTEM);
    if(SUCCEEDED(dialog->Show(owner))) {
        IShellItem* item=nullptr;
        if(SUCCEEDED(dialog->GetResult(&item))) { PWSTR path=nullptr; if(SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH,&path))) { setValue(owner,Home,path); CoTaskMemFree(path); } item->Release(); }
    }
    dialog->Release();
}
static void settingsCommand(HWND owner,int id) {
    try {
        if(id==Paste) { SetFocus(GetDlgItem(owner,Key)); SendDlgItemMessageW(owner,Key,WM_PASTE,0,0); }
        else if(id==Browse) chooseHome(owner);
        else if(id==GetKey) openLink(L"https://platform.deepseek.com/api_keys");
        else if(id==SaveKey && !app.demo) {
            auto key=trim(utf8(value(owner,Key)));
            if(key.empty()||key.find_first_of(" \t\r\n")!=std::string::npos) { SecureZeroMemory(key.data(),key.size()); throw std::runtime_error("请输入有效的 API Key，不能包含空白字符。"); }
            try { saveKey(key); } catch(...) { SecureZeroMemory(key.data(),key.size()); throw; }
            SecureZeroMemory(key.data(),key.size()); setValue(owner,Key,L""); app.hasKey=true; setValue(owner,KeyStatus,L"已连接 · 密钥由 Windows 加密保存"); clearAccountState(); refresh(false); showError(owner,"密钥已加密保存。");
        } else if(id==DeleteKey && !app.demo) {
            deleteKey(); app.hasKey=false; setValue(owner,KeyStatus,L"尚未添加 API Key"); clearAccountState(); setValue(owner,Key,L""); showError(owner,"已删除本机密钥，并清除旧账户余额历史。");
        } else if(id==ClearHistory && !app.demo) { app.history.clear(); saveState(); InvalidateRect(app.window,nullptr,FALSE); showError(owner,"本地余额历史已清除，消费估算会重新积累。"); }
        else if(id==SaveSettings && !app.demo) {
            auto p=app.prefs; p.home=trim(utf8(value(owner,Home))); resolveHome(p.home);
            p.source=selection(owner,Source)==2?"rollout":selection(owner,Source)==1?"api":"auto";
            const int c[]{30,60,120,300}, d[]{60,300,600,1800};
            p.codexInterval=c[std::clamp(selection(owner,CodexInterval),0,3)]; p.deepseekInterval=d[std::clamp(selection(owner,DeepInterval),0,3)];
            auto thresholds=parseThresholds(utf8(value(owner,Thresholds))); if(!thresholds) throw std::runtime_error("阈值需要正数，用英文逗号分隔，例如 75, 35, 7。");
            p.thresholds=*thresholds; p.notifications=SendDlgItemMessageW(owner,Notifications,BM_GETCHECK,0,0)==BST_CHECKED;
            bool login=SendDlgItemMessageW(owner,Login,BM_GETCHECK,0,0)==BST_CHECKED;
            setLogin(login);
            if(p.home!=app.prefs.home||p.source!=app.prefs.source) { ++app.codexGeneration; app.loadingCodex=false; app.codex.reset(); app.codexError.clear(); app.codexFailures=0; app.nextCodex=0; }
            if(p.thresholds!=app.prefs.thresholds||(!app.prefs.notifications&&p.notifications)) app.balanceWarnings.clear();
            if(!app.prefs.notifications&&p.notifications) app.codexWarnings.clear();
            app.prefs=p; app.nextCodex=0; app.nextBalance=0; checkWarnings(); saveState(); refreshAll(); showError(owner,"设置和 CNY 阈值已保存。");
        }
    } catch(const std::exception& e) { showError(owner,e.what()); }
}
static LRESULT CALLBACK SettingsProc(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    switch(message) {
    case WM_CREATE:
        app.settingsDpi=int(GetDpiForWindow(window)); app.settingsScroll=0;
        app.settingsFont=CreateFontW(-spx(13),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
        settingsControls(window); return 0;
    case WM_SIZE: scrollSettings(window,app.settingsScroll); return 0;
    case WM_VSCROLL: {
        SCROLLINFO info{sizeof(info),SIF_ALL}; GetScrollInfo(window,SB_VERT,&info); int target=app.settingsScroll;
        switch(LOWORD(wp)) { case SB_LINEUP: target-=spx(24); break; case SB_LINEDOWN: target+=spx(24); break; case SB_PAGEUP: target-=info.nPage; break; case SB_PAGEDOWN: target+=info.nPage; break; case SB_THUMBTRACK: target=info.nTrackPos; break; }
        scrollSettings(window,target); return 0;
    }
    case WM_MOUSEWHEEL: scrollSettings(window,app.settingsScroll-GET_WHEEL_DELTA_WPARAM(wp)/WHEEL_DELTA*spx(48)); return 0;
    case WM_COMMAND: if(HIWORD(wp)==BN_CLICKED) settingsCommand(window,LOWORD(wp)); return 0;
    case WM_CLOSE: ShowWindow(window,SW_HIDE); return 0;
    case WM_DPICHANGED: {
        int oldDpi=app.settingsDpi, newDpi=HIWORD(wp), oldScroll=app.settingsScroll;
        HFONT oldFont=app.settingsFont;
        app.settingsDpi=newDpi; app.settingsScroll=MulDiv(oldScroll,newDpi,oldDpi);
        app.settingsFont=CreateFontW(-spx(13),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
        for(HWND child=GetWindow(window,GW_CHILD);child;child=GetWindow(child,GW_HWNDNEXT)) {
            RECT r; GetWindowRect(child,&r); MapWindowPoints(nullptr,window,reinterpret_cast<POINT*>(&r),2);
            SetWindowPos(child,nullptr,MulDiv(r.left,newDpi,oldDpi),MulDiv(r.top+oldScroll,newDpi,oldDpi)-app.settingsScroll,MulDiv(r.right-r.left,newDpi,oldDpi),MulDiv(r.bottom-r.top,newDpi,oldDpi),SWP_NOZORDER|SWP_NOACTIVATE);
            SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(app.settingsFont),TRUE);
        }
        if(oldFont) DeleteObject(oldFont);
        auto r=reinterpret_cast<RECT*>(lp); SetWindowPos(window,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER|SWP_NOACTIVATE); scrollSettings(window,app.settingsScroll); return 0;
    }
    case WM_DESTROY: app.settings=nullptr; if(app.settingsFont) { DeleteObject(app.settingsFont); app.settingsFont=nullptr; } return 0;
    }
    return DefWindowProcW(window,message,wp,lp);
}
static void showSettings() {
    if(!app.settings) app.settings=CreateWindowExW(WS_EX_APPWINDOW,L"UsageBarSettings",app.demo?L"UsageBar 设置 · 演示":L"UsageBar 设置",WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_VSCROLL,0,0,550,690,app.window,nullptr,app.instance,nullptr);
    fitWindow(app.settings,548,650,app.settingsDpi,false); ShowWindow(app.settings,SW_SHOW); SetForegroundWindow(app.settings);
    scrollSettings(app.settings,app.settingsScroll);
}
static void showDashboard() { fitWindow(app.window,430,700,app.dpi,true); ShowWindow(app.window,SW_SHOW); SetForegroundWindow(app.window); }
static void details() {
    if(!app.codex) { showError(app.window,app.codexError.empty()?"尚无账户数据。":app.codexError); return; }
    std::string value=app.codex->details;
    for(const auto& w:app.codex->windows) value+=w.title+"："+std::to_string(int(w.used))+"% 已用\n";
    if(!app.codex->fallback.empty()) value+="\n在线查询失败："+app.codex->fallback;
    if(!app.codexError.empty()) value+="\n刷新失败："+app.codexError;
    showError(app.window,value.empty()?"接口未报告附加账户信息。":value);
}
static void trayMenu() {
    HMENU menu=CreatePopupMenu(); auto title=summary();
    AppendMenuW(menu,MF_STRING|MF_GRAYED,0,title.c_str()); AppendMenuW(menu,MF_SEPARATOR,0,nullptr);
    AppendMenuW(menu,MF_STRING,Refresh,L"刷新全部"); AppendMenuW(menu,MF_STRING,Settings,L"设置…"); AppendMenuW(menu,MF_STRING,Quit,L"退出 UsageBar");
    POINT p; GetCursorPos(&p); SetForegroundWindow(app.window);
    UINT command=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_RIGHTBUTTON,p.x,p.y,0,app.window,nullptr); DestroyMenu(menu);
    if(command) SendMessageW(app.window,WM_COMMAND,command,0); PostMessageW(app.window,WM_NULL,0,0);
}
static LRESULT CALLBACK MainProc(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    if(app.taskbarCreated&&message==app.taskbarCreated) { updateTray(true); return 0; }
    switch(message) {
    case WM_CREATE: app.window=window; app.dpi=int(GetDpiForWindow(window)); makeFonts(); dashboardButtons(); SetTimer(window,1,15000,nullptr); return 0;
    case WM_PAINT: paintDashboard(window); return 0;
    case WM_ERASEBKGND: return 1;
    case WM_SIZE: if(wp!=SIZE_MINIMIZED) { dashboardButtons(); InvalidateRect(window,nullptr,FALSE); } return 0;
    case WM_DPICHANGED: {
        app.dpi=HIWORD(wp); makeFonts(); auto rect=reinterpret_cast<RECT*>(lp); SetWindowPos(window,nullptr,rect->left,rect->top,rect->right-rect->left,rect->bottom-rect->top,SWP_NOZORDER|SWP_NOACTIVATE); dashboardButtons(); return 0;
    }
    case TrayMessage: {
        auto event=LOWORD(lp);
        if(event==NIN_SELECT||event==NIN_KEYSELECT||event==WM_LBUTTONUP) { if(IsWindowVisible(window)) ShowWindow(window,SW_HIDE); else showDashboard(); }
        else if(event==WM_CONTEXTMENU||event==WM_RBUTTONUP) trayMenu(); return 0;
    }
    case WM_COMMAND:
        switch(LOWORD(wp)) { case Refresh: refreshAll(); break; case Settings: showSettings(); break; case Quit: DestroyWindow(window); break; case Details: details(); break; case Usage: openLink(L"https://platform.deepseek.com/usage"); break; case TopUp: openLink(L"https://platform.deepseek.com/top_up"); break; }
        return 0;
    case ResultMessage: receiveResult(std::unique_ptr<Result>(reinterpret_cast<Result*>(lp))); return 0;
    case WM_TIMER: if(wp==99) { DestroyWindow(window); return 0; } if(!app.trayAdded) updateTray(true); if(now()>=app.nextCodex) refresh(true); if(now()>=app.nextBalance) refresh(false); if(IsWindowVisible(window)) InvalidateRect(window,nullptr,FALSE); return 0;
    case WM_POWERBROADCAST: if(wp==PBT_APMRESUMEAUTOMATIC) { app.nextCodex=0; app.nextBalance=0; refreshAll(); } return TRUE;
    case WM_CLOSE: ShowWindow(window,SW_HIDE); return 0;
    case WM_DESTROY: {
        app.shuttingDown=true; KillTimer(window,1); KillTimer(window,99); auto data=trayData(); Shell_NotifyIconW(NIM_DELETE,&data); if(app.settings) DestroyWindow(app.settings); PostQuitMessage(0); return 0;
    }
    }
    return DefWindowProcW(window,message,wp,lp);
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,PWSTR,int) {
    app.instance=instance;
    int count=0; auto argv=CommandLineToArgvW(GetCommandLineW(),&count); bool background=false,showSettingsFlag=false,smoke=false;
    for(int i=1;i<count;++i) { std::wstring flag=argv[i]; if(flag==L"--demo") app.demo=true; if(flag==L"--background") background=true; if(flag==L"--show-settings") showSettingsFlag=true; if(flag==L"--smoke-test") smoke=true; }
    if(argv) LocalFree(argv);
    // A demo instance is separate from the real account process.
    HANDLE mutex=CreateMutexW(nullptr,FALSE,app.demo?L"Local\\UsageBarDemoInstance":L"Local\\UsageBarInstance");
    if(GetLastError()==ERROR_ALREADY_EXISTS) { auto window=FindWindowW(L"UsageBarMain",app.demo?L"UsageBar · 演示":L"UsageBar"); if(window) { ShowWindow(window,SW_SHOW); SetForegroundWindow(window); } if(mutex) CloseHandle(mutex); return 0; }
    if(!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE);
    HRESULT com=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    INITCOMMONCONTROLSEX controls{sizeof(controls),ICC_STANDARD_CLASSES}; InitCommonControlsEx(&controls);
    int exitCode=0;
    try {
        loadState(); if(app.demo) seedDemo();
        app.icon=static_cast<HICON>(LoadImageW(instance,MAKEINTRESOURCEW(101),IMAGE_ICON,0,0,LR_DEFAULTSIZE));
        WNDCLASSEXW klass{sizeof(klass)}; klass.lpfnWndProc=MainProc; klass.hInstance=instance; klass.hIcon=app.icon; klass.hIconSm=app.icon; klass.hCursor=LoadCursorW(nullptr,IDC_ARROW); klass.lpszClassName=L"UsageBarMain";
        if(!RegisterClassExW(&klass)) throw std::runtime_error("无法创建额度面板。");
        klass.lpfnWndProc=SettingsProc; klass.hbrBackground=reinterpret_cast<HBRUSH>(COLOR_WINDOW+1); klass.lpszClassName=L"UsageBarSettings";
        if(!RegisterClassExW(&klass)) throw std::runtime_error("无法创建设置窗口。");
        app.window=CreateWindowExW(WS_EX_TOOLWINDOW,L"UsageBarMain",app.demo?L"UsageBar · 演示":L"UsageBar",WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_CLIPCHILDREN,0,0,430,740,nullptr,nullptr,instance,nullptr);
        if(!app.window) throw std::runtime_error("无法创建应用窗口。");
        app.taskbarCreated=RegisterWindowMessageW(L"TaskbarCreated"); updateTray(true); refreshAll();
        if(!background) showDashboard(); if(showSettingsFlag) showSettings(); if(smoke) SetTimer(app.window,99,2000,nullptr);
        MSG message{};
        while(GetMessageW(&message,nullptr,0,0)>0) {
            if(app.settings&&IsWindowVisible(app.settings)&&IsDialogMessageW(app.settings,&message)) continue;
            if(IsWindowVisible(app.window)&&IsDialogMessageW(app.window,&message)) continue;
            TranslateMessage(&message); DispatchMessageW(&message);
        }
    } catch(const std::exception& e) { showError(nullptr,e.what()); exitCode=1; if(app.window&&IsWindow(app.window)) DestroyWindow(app.window); }
    // Join finite, timeout-bounded requests before releasing application state.
    for(auto& worker:app.workers) if(worker.thread.joinable()) worker.thread.join();
    MSG pending{}; while(PeekMessageW(&pending,nullptr,ResultMessage,ResultMessage,PM_REMOVE)) delete reinterpret_cast<Result*>(pending.lParam);
    for(auto font:{app.normal,app.title,app.metric,app.small}) if(font) DeleteObject(font);
    if(app.icon) DestroyIcon(app.icon); if(SUCCEEDED(com)) CoUninitialize(); if(mutex) CloseHandle(mutex);
    return exitCode;
}
