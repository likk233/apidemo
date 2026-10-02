#pragma once
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include "Core.h"
#include <filesystem>

namespace usagebar {
std::wstring wide(const std::string& text);
std::string utf8(const std::wstring& text);
std::filesystem::path dataDirectory();
std::string defaultCodexHome();
std::filesystem::path resolveHome(const std::string& home);
std::string readBytes(const std::filesystem::path& path, size_t limit = 2 * 1024 * 1024);
void writeAtomic(const std::filesystem::path& path, const std::string& bytes);
std::string readKey(const std::filesystem::path& isolatedPath = {});
void saveKey(const std::string& key, const std::filesystem::path& isolatedPath = {});
void deleteKey(const std::filesystem::path& isolatedPath = {});
std::string httpGet(const std::wstring& host, const std::wstring& path, const std::string& key, const std::string& account = "");
Codex fetchCodex(const Preferences& preferences, int64_t now);
Balance fetchBalance(int64_t now);
std::optional<Codex> latestRollout(const std::filesystem::path& home, int64_t now);
std::string accountFromAuth(const Json& auth);
bool loginEnabled();
void setLogin(bool enabled);
} // namespace usagebar
