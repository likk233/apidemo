#include "Core.h"
#include <algorithm>
#include <cmath>
#include <ctime>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>

namespace usagebar {
static const Json empty;
static const Json& get(const Json& j, std::initializer_list<const char*> names) {
    if (j.is_object()) for (auto name : names) if (j.contains(name) && !j[name].is_null()) return j[name];
    return empty;
}
static std::string str(const Json& j) { return j.is_string() ? j.get<std::string>() : ""; }
static std::optional<double> number(const Json& j) {
    if (!j.is_number()) return {};
    double value = j.get<double>();
    return std::isfinite(value) ? std::optional<double>(value) : std::nullopt;
}
static bool boolean(const Json& j, bool fallback = false) { return j.is_boolean() ? j.get<bool>() : fallback; }
Json parseJson(const std::string& text) {
    if (text.size() > 2 * 1024 * 1024) throw std::runtime_error("数据超过读取上限。");
    return Json::parse(text, [](int depth, Json::parse_event_t, Json&) {
        if (depth > 64) throw std::runtime_error("数据嵌套过深。");
        return true;
    });
}
std::string trim(const std::string& text) {
    auto start = text.find_first_not_of(" \t\r\n");
    return start == std::string::npos ? "" : text.substr(start, text.find_last_not_of(" \t\r\n") - start + 1);
}
std::optional<Money> parseMoney(const Json& j) {
    std::string text = j.is_string() ? j.get<std::string>() : j.is_number() ? j.dump() : "";
    if (text.empty()) return {};
    size_t p = text[0] == '-' ? 1 : 0;
    bool negative = p == 1;
    size_t digits = 0;
    uint64_t whole = 0, fraction = 0;
    const uint64_t limit = uint64_t(std::numeric_limits<Money>::max());
    while (p < text.size() && text[p] >= '0' && text[p] <= '9') {
        auto digit = unsigned(text[p++] - '0');
        if (whole > (limit / MoneyScale - digit) / 10) return {};
        whole = whole * 10 + digit; ++digits;
    }
    if (!digits) return {};
    if (p < text.size() && text[p] == '.') {
        ++p; size_t count = 0;
        while (p < text.size() && text[p] >= '0' && text[p] <= '9') {
            if (count >= 8 && text[p] != '0') return {};
            if (count < 8) fraction = fraction * 10 + unsigned(text[p] - '0');
            ++p; ++count;
        }
        if (!count) return {};
        while (count++ < 8) fraction *= 10;
    }
    if (p != text.size() || whole > (limit - fraction) / MoneyScale) return {};
    Money value = Money(whole * MoneyScale + fraction);
    return negative ? -value : value;
}
std::string money(Money value) {
    uint64_t absolute = value < 0 ? uint64_t(-(value + 1)) + 1 : uint64_t(value);
    uint64_t cents = absolute / 1000000 + (absolute % 1000000 >= 500000);
    std::ostringstream out;
    out << (value < 0 ? "-¥" : "¥") << cents / 100 << '.' << std::setw(2) << std::setfill('0') << cents % 100;
    return out.str();
}
int64_t isoTime(const std::string& text) {
    std::tm date{}; std::istringstream in(text);
    in >> std::get_time(&date, "%Y-%m-%dT%H:%M:%S");
    if (in.fail()) return 0;
    if (in.peek() == '.') { in.get(); while (std::isdigit(in.peek())) in.get(); }
    int offset = 0;
    if (in.peek() == '+' || in.peek() == '-') {
        char sign; int h, m; in >> sign >> std::setw(2) >> h;
        if (in.get() != ':') return 0;
        in >> std::setw(2) >> m;
        if (in.fail() || h > 23 || m > 59) return 0;
        offset = (h * 3600 + m * 60) * (sign == '+' ? 1 : -1);
    } else if (in.get() != 'Z') return 0;
#ifdef _WIN32
    return _mkgmtime(&date) - offset;
#else
    return timegm(&date) - offset;
#endif
}
static std::optional<Window> parseWindow(const Json& j, const std::string& id, int64_t captured) {
    auto used = number(get(j, {"used_percent", "usedPercent", "pct", "percent"}));
    if (!used || *used < 0) return {};
    double minutes = number(get(j, {"window_minutes", "windowMinutes", "limit_window_minutes"})).value_or(0);
    if (!minutes) minutes = number(get(j, {"window_seconds", "windowSeconds", "limit_window_seconds"})).value_or(0) / 60;
    std::ostringstream title;
    if (minutes == 10080) title << "每周额度";
    else if (minutes >= 1440) title << minutes / 1440 << " 天额度";
    else if (minutes >= 60) title << minutes / 60 << " 小时额度";
    else if (minutes > 0) title << minutes << " 分钟额度";
    else title << "额度窗口";
    auto reset = number(get(j, {"resets_at", "resetsAt", "reset_at", "resetAt"}));
    auto relative = number(get(j, {"resets_in_seconds", "resetsInSeconds", "reset_after_seconds", "resetAfterSeconds"}));
    double date = reset.value_or(relative ? double(captured) + *relative : 0);
    if (date < 0 || date > 253402300799.0) date = 0;
    return Window{id, title.str(), std::min(100.0, *used), int64_t(date)};
}
static std::vector<Window> windows(const Json& j, const std::string& prefix, int64_t date) {
    std::vector<Window> result;
    if (auto w = parseWindow(get(j, {"primary", "primary_window", "primaryWindow"}), prefix + "-primary", date)) result.push_back(*w);
    if (auto w = parseWindow(get(j, {"secondary", "secondary_window", "secondaryWindow"}), prefix + "-secondary", date)) result.push_back(*w);
    return result;
}
Codex parseCodex(const Json& j, int64_t captured, const std::string& source) {
    if (!j.is_object()) throw std::runtime_error("额度数据格式无法识别。");
    const Json* rate = &get(j, {"rate_limits", "rateLimits", "rate_limit"});
    if (!rate->is_object()) rate = &get(get(j, {"usage"}), {"rate_limits"});
    if (!rate->is_object()) rate = &j;
    Codex result;
    result.windows = windows(*rate, "codex", captured); result.captured = captured; result.source = source;
    result.plan = str(get(*rate, {"plan_type", "planType"}));
    if (result.plan.empty()) result.plan = str(get(j, {"plan_type", "plan"}));
    if (result.plan.empty()) result.plan = str(get(get(j, {"plan"}), {"name"}));
    std::ostringstream details;
    bool extra = false;
    auto add = [&](const std::string& name, const Json& raw) {
        auto list = windows(raw, name, captured);
        if (list.empty()) if (auto one = parseWindow(raw, name, captured)) list.push_back(*one);
        if (list.empty()) return;
        extra = true; details << name << "\n";
        for (const auto& w : list) details << "  " << w.title << "：" << w.used << "% 已用\n";
    };
    auto additional = get(j, {"additional_rate_limits", "additionalRateLimits"});
    if (additional.is_array()) for (const auto& item : additional) {
        std::string name = str(get(item, {"limit_name", "limitName"}));
        const auto& raw = get(item, {"rate_limit", "rateLimit"});
        if (!name.empty()) add(name, raw.is_object() ? raw : item);
    }
    add("Code review", get(j, {"code_review_rate_limit", "codeReviewRateLimit"}));
    const Json* credits = &get(*rate, {"credits"});
    if (!credits->is_object()) credits = &get(j, {"credits"});
    if (credits->is_object() && (credits->contains("balance") || credits->contains("unlimited") || credits->contains("has_credits"))) {
        extra = true;
        auto balance = get(*credits, {"balance", "balance_display", "remaining"});
        details << "额外积分：" << (boolean(get(*credits, {"unlimited"})) ? "不限量" : balance.is_string() ? balance.get<std::string>() : balance.is_number() ? balance.dump() : "未报告") << "\n";
    }
    auto resetCredits = number(get(get(j, {"rate_limit_reset_credits", "rateLimitResetCredits"}), {"available_count", "availableCount"}));
    if (resetCredits) details << "可用重置次数：" << *resetCredits << "\n";
    const Json* spend = &get(j, {"spend_control"});
    if (!spend->is_object()) spend = &get(*rate, {"spend_control"});
    const Json* budget = &get(*spend, {"individual_limit"});
    if (!budget->is_object()) budget = &get(*rate, {"individual_limit", "individualLimit"});
    if (budget->is_object()) details << "预算已用 / 上限：" << str(get(*budget, {"used", "used_display"})) << " / " << str(get(*budget, {"limit", "limit_display"})) << "\n";
    if (boolean(get(*rate, {"limit_reached"})) || boolean(get(*spend, {"reached"}))) details << "额度或预算上限已达到。\n";
    result.details = details.str();
    if (result.windows.empty() && !extra) throw std::runtime_error("额度数据格式无法识别。");
    return result;
}
std::optional<Codex> parseRollout(const std::string& line, int64_t fileDate) {
    try {
        auto j = parseJson(line); const auto& payload = get(j, {"payload"});
        const auto& p = payload.is_object() ? payload : j;
        if (str(get(p, {"type"})) != "token_count") return {};
        auto time = isoTime(str(get(j, {"timestamp"})));
        if (!time) time = isoTime(str(get(p, {"timestamp"})));
        return parseCodex(get(p, {"rate_limits"}), time ? time : fileDate, "rollout");
    } catch (...) { return {}; }
}
Balance parseBalance(const Json& j, int64_t captured) {
    const auto& entries = get(j, {"balance_infos"});
    if (!entries.is_array() || entries.empty()) throw std::runtime_error("余额数据格式无法识别。");
    std::set<std::string> currencies; std::optional<Balance> result;
    for (const auto& item : entries) {
        auto currency = str(get(item, {"currency"})); auto amount = parseMoney(get(item, {"total_balance"}));
        if (currency.empty() || !amount || !currencies.insert(currency).second) throw std::runtime_error("余额数据格式无法识别。");
        if (currency == "CNY") result = Balance{*amount, parseMoney(get(item, {"topped_up_balance"})), parseMoney(get(item, {"granted_balance"})), boolean(get(j, {"is_available"}), true), captured};
    }
    if (!result) throw std::runtime_error("接口未返回人民币余额。");
    return *result;
}
std::optional<std::vector<double>> parseThresholds(const std::string& text) {
    std::vector<double> values; size_t start = 0;
    do {
        auto end = text.find(',', start); auto part = trim(text.substr(start, end - start));
        if (part.empty()) return {};
        try { size_t n; double v = std::stod(part, &n); if (n != part.size() || !std::isfinite(v) || v <= 0 || v > 90000000000.0) return {}; values.push_back(v); } catch (...) { return {}; }
        if (end == std::string::npos) break;
        start = end + 1;
    } while (true);
    std::sort(values.begin(), values.end(), std::greater<double>());
    values.erase(std::unique(values.begin(), values.end()), values.end());
    return values;
}
Preferences parsePreferences(const Json& j, const std::string& defaultHome) {
    Preferences p; p.home = defaultHome;
    if (auto value = str(get(j, {"codexHome"})); !value.empty()) p.home = value;
    if (auto value = str(get(j, {"codexSource"})); value == "auto" || value == "api" || value == "rollout") p.source = value;
    p.codexInterval = int(std::clamp(number(get(j, {"codexInterval"})).value_or(60), 30.0, 600.0));
    p.deepseekInterval = int(std::clamp(number(get(j, {"deepseekInterval"})).value_or(300), 60.0, 1800.0));
    p.notifications = boolean(get(j, {"notifications"}));
    const auto& thresholds = get(j, {"cnyThresholds"});
    if (thresholds.is_array()) {
        std::ostringstream text; bool valid = !thresholds.empty();
        for (const auto& value : thresholds) { if (!number(value)) { valid = false; break; } if (text.tellp() > 0) text << ','; text << value.dump(); }
        if (valid) if (auto parsed = parseThresholds(text.str())) p.thresholds = *parsed;
    }
    return p;
}
Json preferencesJson(const Preferences& p) { return Json{{"codexHome", p.home}, {"codexSource", p.source}, {"codexInterval", p.codexInterval}, {"deepseekInterval", p.deepseekInterval}, {"cnyThresholds", p.thresholds}, {"notifications", p.notifications}}; }
void record(std::vector<Sample>& samples, const Balance& balance) {
    samples.erase(std::remove_if(samples.begin(), samples.end(), [&](const auto& s) { return s.date < balance.captured - 14 * 86400 || s.date > balance.captured; }), samples.end());
    if (samples.empty() || samples.back().date != balance.captured) samples.push_back({balance.captured, balance.total});
    if (samples.size() > 500) samples.erase(samples.begin(), samples.end() - 500);
}
std::optional<Estimate> estimate(const std::vector<Sample>& samples) {
    if (samples.size() < 2 || samples.back().date - samples.front().date < 1800) return {};
    long double spent = 0;
    for (size_t i = 1; i < samples.size(); ++i) if (samples[i - 1].amount > samples[i].amount) spent += (static_cast<long double>(samples[i - 1].amount) - samples[i].amount) / MoneyScale;
    double perDay = double(spent / ((samples.back().date - samples.front().date) / 86400.0));
    if (!std::isfinite(perDay) || perDay <= 0) return {};
    return Estimate{perDay, std::max(0.0, double(samples.back().amount) / MoneyScale / perDay)};
}
std::string balanceWarning(const Balance& b, const std::vector<double>& thresholds, std::set<std::string>& active) {
    std::set<std::string> crossed;
    for (auto threshold : thresholds) if (double(b.total) / MoneyScale < threshold) crossed.insert("threshold:" + std::to_string(threshold));
    if (b.total < 7 * MoneyScale || !b.available) crossed.insert("floor");
    if (b.total <= 0 || !b.available) crossed.insert("depleted");
    std::vector<std::string> fresh;
    std::set_difference(crossed.begin(), crossed.end(), active.begin(), active.end(), std::back_inserter(fresh));
    active = crossed;
    if (std::find(fresh.begin(), fresh.end(), "depleted") != fresh.end()) return "DeepSeek 可用余额已耗尽（" + money(b.total) + "）。";
    if (std::find(fresh.begin(), fresh.end(), "floor") != fresh.end()) return "DeepSeek 余额极低：" + money(b.total) + "。";
    return fresh.empty() ? "" : "DeepSeek 余额低于提醒阈值：" + money(b.total) + "。";
}
double highestUsed(const Codex& codex) { double result = 0; for (const auto& w : codex.windows) result = std::max(result, w.used); return result; }
} // namespace usagebar
