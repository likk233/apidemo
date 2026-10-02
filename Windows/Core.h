#pragma once
#include "vendor/json.hpp"
#include <cstdint>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace usagebar {
using Json = nlohmann::json;
using Money = int64_t; // Exact units of 0.00000001 CNY; never use float for stored money.
constexpr Money MoneyScale = 100000000;
struct Window { std::string id, title; double used = 0; int64_t resets = 0; };
struct Codex { std::vector<Window> windows; std::string plan, details, source, fallback; int64_t captured = 0; };
struct Balance { Money total = 0; std::optional<Money> toppedUp, granted; bool available = true; int64_t captured = 0; };
struct Sample { int64_t date; Money amount; };
struct Estimate { double perDay, daysLeft; };
struct Preferences {
    std::string home, source = "auto";
    int codexInterval = 60, deepseekInterval = 300;
    std::vector<double> thresholds{75, 35, 7};
    bool notifications = false;
};
Json parseJson(const std::string& text);
std::optional<Money> parseMoney(const Json& value);
std::string money(Money value);
Codex parseCodex(const Json& root, int64_t captured, const std::string& source = "api");
std::optional<Codex> parseRollout(const std::string& line, int64_t fileDate);
Balance parseBalance(const Json& root, int64_t captured);
std::optional<std::vector<double>> parseThresholds(const std::string& text);
Preferences parsePreferences(const Json& root, const std::string& defaultHome);
Json preferencesJson(const Preferences& prefs);
void record(std::vector<Sample>& samples, const Balance& balance);
std::optional<Estimate> estimate(const std::vector<Sample>& samples);
std::string balanceWarning(const Balance& balance, const std::vector<double>& thresholds, std::set<std::string>& active);
double highestUsed(const Codex& codex);
std::string trim(const std::string& text);
int64_t isoTime(const std::string& text);
} // namespace usagebar
