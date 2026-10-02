#include "Platform.h"
#include <winhttp.h>
#include <wincrypt.h>
#include <shlobj.h>
#include <algorithm>
#include <chrono>
#include <fstream>
#include <memory>
#include <stdexcept>

namespace usagebar {
namespace fs = std::filesystem;
std::wstring wide(const std::string& text) {
    if (text.empty()) return {};
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), nullptr, 0);
    if (!length) throw std::runtime_error("文本编码无效。");
    std::wstring result(length, 0);
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), result.data(), length);
    return result;
}
std::string utf8(const std::wstring& text) {
    if (text.empty()) return {};
    int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), int(text.size()), nullptr, 0, nullptr, nullptr);
    if (!length) throw std::runtime_error("文本编码无效。");
    std::string result(length, 0);
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), int(text.size()), result.data(), length, nullptr, nullptr);
    return result;
}
static std::wstring environment(const wchar_t* name) {
    DWORD length = GetEnvironmentVariableW(name, nullptr, 0);
    if (!length) return {};
    std::wstring result(length, 0);
    GetEnvironmentVariableW(name, result.data(), length);
    result.resize(length - 1); return result;
}
fs::path dataDirectory() {
    PWSTR value = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &value))) throw std::runtime_error("无法定位本机应用数据目录。");
    fs::path path = fs::path(value) / L"UsageBar"; CoTaskMemFree(value);
    std::error_code error; fs::create_directories(path, error);
    if (error) throw std::runtime_error("无法创建本机应用数据目录。");
    return path;
}
std::string defaultCodexHome() {
    auto value = environment(L"CODEX_HOME");
    return utf8(value.empty() ? (fs::path(environment(L"USERPROFILE")) / L".codex").wstring() : value);
}
fs::path resolveHome(const std::string& home) {
    auto value = wide(home);
    if (value == L"~") value = environment(L"USERPROFILE");
    else if (value.size() > 1 && value[0] == '~' && (value[1] == '/' || value[1] == '\\')) value = (fs::path(environment(L"USERPROFILE")) / value.substr(2)).wstring();
    DWORD length = ExpandEnvironmentStringsW(value.c_str(), nullptr, 0);
    std::wstring expanded(length, 0);
    if (!length || !ExpandEnvironmentStringsW(value.c_str(), expanded.data(), length)) throw std::runtime_error("目录格式无效。");
    expanded.resize(length - 1);
    fs::path path(expanded);
    if (!path.is_absolute()) throw std::runtime_error("Codex 目录需要绝对路径或以 ~/ 开头。");
    return path;
}
std::string readBytes(const fs::path& path, size_t limit) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("无法读取本地文件。");
    in.seekg(0, std::ios::end); auto size = in.tellg();
    if (size < 0 || uint64_t(size) > limit) throw std::runtime_error("本地文件超过读取上限。");
    std::string bytes(size_t(size), '\0'); in.seekg(0);
    if (!bytes.empty() && !in.read(bytes.data(), std::streamsize(bytes.size()))) throw std::runtime_error("本地文件读取失败。");
    return bytes;
}
void writeAtomic(const fs::path& path, const std::string& bytes) {
    auto temporary = path; temporary += L".tmp";
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("无法写入本地数据。");
    DWORD written = 0;
    bool success = WriteFile(file, bytes.data(), DWORD(bytes.size()), &written, nullptr) && written == bytes.size() && FlushFileBuffers(file);
    CloseHandle(file);
    if (!success || !MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(temporary.c_str()); throw std::runtime_error("本地数据保存失败。");
    }
}
std::string readKey(const fs::path& isolatedPath) {
    auto path = isolatedPath.empty() ? dataDirectory() / L"deepseek-key.dat" : isolatedPath;
    std::error_code error;
    if (!fs::exists(path, error) && !error) return {};
    auto bytes = readBytes(path, 65536);
    DATA_BLOB input{DWORD(bytes.size()), reinterpret_cast<BYTE*>(bytes.data())}, output{};
    if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)) throw std::runtime_error("无法解密密钥，请在原 Windows 用户账户下重新保存密钥。");
    std::string key(reinterpret_cast<char*>(output.pbData), output.cbData);
    SecureZeroMemory(output.pbData, output.cbData); LocalFree(output.pbData);
    return key;
}
void saveKey(const std::string& key, const fs::path& isolatedPath) {
    DATA_BLOB input{DWORD(key.size()), reinterpret_cast<BYTE*>(const_cast<char*>(key.data()))}, output{};
    if (!CryptProtectData(&input, L"UsageBar DeepSeek API Key", nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)) throw std::runtime_error("Windows 密钥加密失败。");
    auto path = isolatedPath.empty() ? dataDirectory() / L"deepseek-key.dat" : isolatedPath;
    try { writeAtomic(path, std::string(reinterpret_cast<char*>(output.pbData), output.cbData)); }
    catch (...) { LocalFree(output.pbData); throw; }
    LocalFree(output.pbData);
}
void deleteKey(const fs::path& isolatedPath) {
    auto path = isolatedPath.empty() ? dataDirectory() / L"deepseek-key.dat" : isolatedPath;
    if (!DeleteFileW(path.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND) throw std::runtime_error("删除密钥失败。");
}
struct HttpHandle {
    HINTERNET value;
    explicit HttpHandle(HINTERNET handle) : value(handle) { if (!value) throw std::runtime_error("网络连接失败。"); }
    ~HttpHandle() { WinHttpCloseHandle(value); }
    operator HINTERNET() const { return value; }
};
static void httpFailure(DWORD code) {
    if (code == ERROR_WINHTTP_TIMEOUT) throw std::runtime_error("请求超时，请稍后刷新。");
    throw std::runtime_error("网络连接失败，请检查连接后重试。");
}
std::string httpGet(const std::wstring& host, const std::wstring& path, const std::string& key, const std::string& account) {
    if (!((host == L"chatgpt.com" && path == L"/backend-api/wham/usage") || (host == L"api.deepseek.com" && path == L"/user/balance"))) throw std::runtime_error("请求地址不被允许。");
    if (key.find_first_of("\r\n") != std::string::npos || account.find_first_of("\r\n") != std::string::npos) throw std::runtime_error("登录凭据格式无效。");
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
    HttpHandle session(WinHttpOpen(L"UsageBar/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
    if (!WinHttpSetTimeouts(session, 5000, 8000, 8000, 12000)) httpFailure(GetLastError());
    HttpHandle connection(WinHttpConnect(session, host.c_str(), INTERNET_DEFAULT_HTTPS_PORT, 0));
    HttpHandle request(WinHttpOpenRequest(connection, L"GET", path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE));
    DWORD redirects = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (!WinHttpSetOption(request, WINHTTP_OPTION_REDIRECT_POLICY, &redirects, sizeof(redirects))) httpFailure(GetLastError());
    DWORD authPolicy = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
    if (!WinHttpSetOption(request, WINHTTP_OPTION_AUTOLOGON_POLICY, &authPolicy, sizeof(authPolicy))) httpFailure(GetLastError());
    std::wstring headers = L"Accept: application/json\r\nAuthorization: Bearer " + wide(key) + L"\r\n";
    if (!account.empty()) headers += L"ChatGPT-Account-Id: " + wide(account) + L"\r\n";
    bool sent = WinHttpSendRequest(request, headers.c_str(), DWORD(headers.size()), WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
    SecureZeroMemory(headers.data(), headers.size() * sizeof(wchar_t));
    if (!sent || !WinHttpReceiveResponse(request, nullptr)) httpFailure(GetLastError());
    DWORD status = 0, length = sizeof(status);
    if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &length, WINHTTP_NO_HEADER_INDEX)) httpFailure(GetLastError());
    if (status == 401 || status == 403) throw std::runtime_error("登录或密钥已失效。Codex 请重新登录；DeepSeek 请更新密钥。");
    if (status == 402) throw std::runtime_error("账户余额不足，请前往 DeepSeek 充值。");
    if (status == 429) throw std::runtime_error("请求过于频繁，已延长刷新间隔。");
    if (status < 200 || status >= 300) throw std::runtime_error("服务返回 HTTP " + std::to_string(status) + "，请稍后重试。");
    std::string response;
    for (;;) {
        if (std::chrono::steady_clock::now() > deadline) throw std::runtime_error("请求超时，请稍后刷新。");
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request, &available)) httpFailure(GetLastError());
        if (!available) break;
        if (response.size() + available > 2 * 1024 * 1024) throw std::runtime_error("返回数据超过读取上限。");
        auto start = response.size(); response.resize(start + available); DWORD read = 0;
        if (!WinHttpReadData(request, response.data() + start, available, &read)) httpFailure(GetLastError());
        response.resize(start + read); if (!read) break;
    }
    return response;
}
static std::string jwtAccount(const std::string& token) {
    try {
        auto a = token.find('.'), b = token.find('.', a == std::string::npos ? a : a + 1);
        if (a == std::string::npos || b == std::string::npos) return {};
        auto encoded = token.substr(a + 1, b - a - 1);
        std::replace(encoded.begin(), encoded.end(), '-', '+'); std::replace(encoded.begin(), encoded.end(), '_', '/');
        while (encoded.size() % 4) encoded += '=';
        DWORD size = 0;
        if (!CryptStringToBinaryA(encoded.c_str(), DWORD(encoded.size()), CRYPT_STRING_BASE64, nullptr, &size, nullptr, nullptr) || size > 65536) return {};
        std::string bytes(size, '\0');
        if (!CryptStringToBinaryA(encoded.c_str(), DWORD(encoded.size()), CRYPT_STRING_BASE64, reinterpret_cast<BYTE*>(bytes.data()), &size, nullptr, nullptr)) return {};
        auto j = parseJson(bytes);
        if (j.contains("chatgpt_account_id") && j["chatgpt_account_id"].is_string()) return j["chatgpt_account_id"].get<std::string>();
        if (j.contains("https://api.openai.com/auth")) {
            auto nested = j["https://api.openai.com/auth"];
            if (nested.is_object() && nested.contains("chatgpt_account_id") && nested["chatgpt_account_id"].is_string()) return nested["chatgpt_account_id"].get<std::string>();
        }
    } catch (...) {}
    return {};
}
std::string accountFromAuth(const Json& auth) {
    if (!auth.is_object() || !auth.contains("tokens") || !auth["tokens"].is_object()) return {};
    const auto& tokens = auth["tokens"];
    if (tokens.contains("account_id") && tokens["account_id"].is_string() && !tokens["account_id"].get<std::string>().empty()) return tokens["account_id"].get<std::string>();
    for (auto name : {"id_token", "access_token"}) if (tokens.contains(name) && tokens[name].is_string()) if (auto account = jwtAccount(tokens[name]); !account.empty()) return account;
    return {};
}
static int64_t fileTime(const fs::path& path) {
    WIN32_FILE_ATTRIBUTE_DATA data{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) return 0;
    ULARGE_INTEGER time{}; time.HighPart = data.ftLastWriteTime.dwHighDateTime; time.LowPart = data.ftLastWriteTime.dwLowDateTime;
    return int64_t(time.QuadPart / 10000000) - 11644473600LL;
}
static std::optional<Codex> tailEvent(const fs::path& path, size_t& budget) {
    std::ifstream in(path, std::ios::binary); if (!in) return {};
    in.seekg(0, std::ios::end); auto size = in.tellg(); if (size <= 0) return {};
    size_t count = std::min({size_t(size), size_t(8 * 1024 * 1024), budget});
    if (!count) return {};
    std::string bytes(count, '\0'); in.seekg(std::streamoff(size) - std::streamoff(count));
    in.read(bytes.data(), std::streamsize(count)); bytes.resize(size_t(in.gcount())); budget -= bytes.size();
    size_t end = bytes.size();
    while (end) {
        auto newline = bytes.rfind('\n', end - 1);
        size_t start = newline == std::string::npos ? 0 : newline + 1;
        if ((start != 0 || count == size_t(size)) && end - start <= 1024 * 1024) if (auto value = parseRollout(bytes.substr(start, end - start), fileTime(path))) return value;
        if (newline == std::string::npos) break;
        end = newline;
    }
    return {};
}
std::optional<Codex> latestRollout(const fs::path& home, int64_t now) {
    struct File { fs::path path; int64_t date; };
    std::vector<File> files;
    for (int day = 0; day < 7; ++day) {
        time_t stamp = now - day * 86400; std::tm date{}; gmtime_s(&date, &stamp);
        wchar_t folder[32]; swprintf_s(folder, L"%04d/%02d/%02d", date.tm_year + 1900, date.tm_mon + 1, date.tm_mday);
        std::error_code error;
        for (auto it = fs::directory_iterator(home / L"sessions" / folder, error); !error && it != fs::directory_iterator(); it.increment(error)) {
            auto name = it->path().filename().wstring();
            if (it->is_regular_file(error) && name.rfind(L"rollout-", 0) == 0 && it->path().extension() == L".jsonl") files.push_back({it->path(), fileTime(it->path())});
        }
    }
    std::sort(files.begin(), files.end(), [](const auto& a, const auto& b) { return a.date > b.date; });
    if (files.size() > 64) files.resize(64);
    size_t budget = 64 * 1024 * 1024; std::optional<Codex> result;
    for (const auto& file : files) {
        if (!budget) break;
        if (auto value = tailEvent(file.path, budget); value && (!result || value->captured > result->captured)) result = value;
    }
    return result;
}
Codex fetchCodex(const Preferences& p, int64_t now) {
    auto home = resolveHome(p.home); std::string fallback;
    if (p.source != "rollout") {
        try {
            auto auth = parseJson(readBytes(home / L"auth.json", 1024 * 1024));
            if (!auth.is_object() || !auth.contains("tokens") || !auth["tokens"].is_object() || !auth["tokens"].contains("access_token") || !auth["tokens"]["access_token"].is_string()) throw std::runtime_error("未找到 Codex OAuth 登录。API Key 登录不支持额度查询。");
            auto token = auth["tokens"]["access_token"].get<std::string>();
            if (token.empty()) throw std::runtime_error("未找到 Codex OAuth 登录。");
            try {
                auto response = httpGet(L"chatgpt.com", L"/backend-api/wham/usage", token, accountFromAuth(auth));
                SecureZeroMemory(token.data(), token.size());
                return parseCodex(parseJson(response), now);
            } catch (...) { SecureZeroMemory(token.data(), token.size()); throw; }
        } catch (const Json::exception&) { fallback = "登录或额度数据格式无法识别，请重新登录后重试。"; }
        catch (const std::exception& e) { fallback = e.what(); }
    }
    if (auto snapshot = latestRollout(home, now)) { snapshot->fallback = fallback; return *snapshot; }
    throw std::runtime_error((fallback.empty() ? "" : fallback + "\n") + "最近 7 天没有可读取的额度事件。压缩的 .zst 会话暂不支持。");
}
Balance fetchBalance(int64_t now) {
    auto key = readKey(); if (key.empty()) throw std::runtime_error("尚未添加 DeepSeek API Key。");
    try { auto response = httpGet(L"api.deepseek.com", L"/user/balance", key); SecureZeroMemory(key.data(), key.size()); return parseBalance(parseJson(response), now); }
    catch (...) { SecureZeroMemory(key.data(), key.size()); throw; }
}
static constexpr auto RunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
bool loginEnabled() {
    HKEY key; if (RegOpenKeyExW(HKEY_CURRENT_USER, RunKey, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) return false;
    DWORD type = 0, size = 0; auto result = RegQueryValueExW(key, L"UsageBar", nullptr, &type, nullptr, &size); RegCloseKey(key);
    return result == ERROR_SUCCESS && type == REG_SZ && size > 2;
}
void setLogin(bool enabled) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, RunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) throw std::runtime_error("无法修改当前用户的登录启动设置。");
    LONG result;
    if (enabled) {
        std::wstring path(32768, 0); DWORD length = GetModuleFileNameW(nullptr, path.data(), DWORD(path.size())); path.resize(length);
        auto command = L"\"" + path + L"\" --background";
        result = RegSetValueExW(key, L"UsageBar", 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()), DWORD((command.size() + 1) * sizeof(wchar_t)));
    } else { result = RegDeleteValueW(key, L"UsageBar"); if (result == ERROR_FILE_NOT_FOUND) result = ERROR_SUCCESS; }
    RegCloseKey(key);
    if (result != ERROR_SUCCESS) throw std::runtime_error("登录启动设置保存失败。");
}
} // namespace usagebar
