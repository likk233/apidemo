#include "Core.h"
#include <cstdlib>
#include <iostream>
#include <functional>
#include <stdexcept>
using namespace usagebar;
static void check(bool ok) { if (!ok) throw std::runtime_error("assertion failed"); }
template<class F> static void throws(F fn) { bool caught=false; try { fn(); } catch(...) { caught=true; } check(caught); }
int main() {
    std::vector<std::pair<std::string,std::function<void()>>> tests{
        {"live windows and reset", [] { auto c=parseCodex(parseJson(R"({"plan_type":"team","rate_limit":{"primary_window":{"used_percent":26,"limit_window_seconds":18000,"reset_after_seconds":60},"secondary_window":{"used_percent":10,"limit_window_seconds":604800}}})"),100); check(c.plan=="team"&&c.windows.size()==2&&c.windows[0].resets==160&&highestUsed(c)==26); }},
        {"invalid boolean and negative usage", [] { for(auto raw:{R"({"primary":{"used_percent":true}})",R"({"primary":{"used_percent":-1}})","{}"}) throws([&]{parseCodex(parseJson(raw),100);}); }},
        {"camelCase and clamp", [] { auto c=parseCodex(parseJson(R"({"rateLimits":{"primaryWindow":{"usedPercent":150,"windowSeconds":86400,"resetAt":1234},"planType":"plus"}})"),100); check(c.windows[0].used==100&&c.windows[0].resets==1234); }},
        {"credits and additional limits", [] { auto c=parseCodex(parseJson(R"({"credits":{"balance":"12.00"},"additional_rate_limits":[{"limit_name":"Reserve","rate_limit":{"primary":{"used_percent":5}}}]})"),100); check(c.windows.empty()&&c.details.find("Reserve")!=std::string::npos&&c.details.find("12.00")!=std::string::npos); }},
        {"rollout timestamp anchors relative reset", [] { auto c=parseRollout(R"({"timestamp":"2026-10-01T00:00:00.000Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"resets_in_seconds":3600}}}})",9999); check(c&&c->captured==1790812800&&c->windows[0].resets==c->captured+3600&&c->source=="rollout"); check(!parseRollout("partial",100)); }},
        {"exact CNY decimals", [] { auto b=parseBalance(parseJson(R"({"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"100"},{"currency":"CNY","total_balance":"0.01234567","topped_up_balance":"0.01"}]})"),100); check(b.total==1234567&&!b.available&&b.toppedUp==Money(1000000)&&money(b.total)=="¥0.01"); }},
        {"CNY missing never uses USD", [] { throws([]{parseBalance(parseJson(R"({"balance_infos":[{"currency":"USD","total_balance":"100"}]})"),100);}); }},
        {"reject duplicate and malformed amounts", [] { for(auto s:{"NaN","1oops","Infinity","","1e5","-","1."}) check(!parseMoney(Json(s))); check(!parseMoney(Json(true))); throws([]{parseBalance(parseJson(R"({"balance_infos":[{"currency":"CNY","total_balance":"1"},{"currency":"CNY","total_balance":"2"}]})"),100);}); check(!parseMoney(Json("999999999999999999999999999"))); }},
        {"threshold validation", [] { check(parseThresholds("75, 35, 7, 35")==std::vector<double>({75,35,7})); for(auto s:{"","0","-1","nan","5,","1oops","Infinity"}) check(!parseThresholds(s)); }},
        {"old config retains CNY and excludes USD", [] { auto p=parsePreferences(parseJson(R"({"codexHome":"C:/custom","currency":"USD","usdThresholds":[10,5,1],"cnyThresholds":[100,50,7],"deepseekInterval":600,"notifications":true})"),"default"); check(p.home=="C:/custom"&&p.thresholds==std::vector<double>({100,50,7})&&p.deepseekInterval==600&&p.notifications); check(!preferencesJson(p).contains("currency")&&!preferencesJson(p).contains("usdThresholds")); }},
        {"invalid config uses safe defaults", [] { auto p=parsePreferences(parseJson(R"({"codexInterval":-1,"deepseekInterval":99999,"cnyThresholds":[true],"notifications":"true"})"),"home"); check(p.codexInterval==30&&p.deepseekInterval==1800&&!p.notifications&&p.thresholds==std::vector<double>({75,35,7})); }},
        {"recharge excluded from spend", [] { std::vector<Sample> s{{100,100*MoneyScale},{3700,90*MoneyScale},{7300,110*MoneyScale},{10900,105*MoneyScale}}; auto e=estimate(s); check(e&&std::abs(e->perDay-120)<0.001); }},
        {"minimum estimation span", [] { check(!estimate({{100,100*MoneyScale},{1000,90*MoneyScale}})); check(!estimate({{100,100*MoneyScale},{3700,110*MoneyScale}})); }},
        {"history bound and duplicate refresh", [] { std::vector<Sample> s; for(int i=0;i<600;++i) record(s,Balance{100*MoneyScale,{},{},true,10000+i}); check(s.size()==500); record(s,Balance{100*MoneyScale,{},{},true,10599}); check(s.size()==500); record(s,Balance{100*MoneyScale,{},{},true,2000000}); check(s.size()==1); }},
        {"warnings deduplicate and rearm", [] { std::set<std::string> active; Balance b{6*MoneyScale,{},{},true,100}; check(!balanceWarning(b,{75,35,7},active).empty()); check(balanceWarning(b,{75,35,7},active).empty()); b.total=100*MoneyScale; check(balanceWarning(b,{75,35,7},active).empty()); b.total=6*MoneyScale; check(!balanceWarning(b,{75,35,7},active).empty()); auto saved=Json(active).get<std::set<std::string>>(); check(balanceWarning(b,{75,35,7},saved).empty()); }},
        {"depleted and unavailable warnings", [] { std::set<std::string> active; check(balanceWarning(Balance{0,{},{},false,100},{},active).find("耗尽")!=std::string::npos); }},
        {"bounded JSON and malformed JSON", [] { throws([]{parseJson("broken");}); throws([]{parseJson(std::string(3*1024*1024,' '));}); std::string deep(80,'['); deep+=std::string(80,']'); throws([&]{parseJson(deep);}); }}
    };
    int failures=0;
    for(const auto& [name,run]:tests) { try { run(); std::cout<<"PASS "<<name<<'\n'; } catch(const std::exception& e) { ++failures; std::cerr<<"FAIL "<<name<<": "<<e.what()<<'\n'; } }
    std::cout<<tests.size()<<" Windows core checks, "<<failures<<" failures\n"; return failures?1:0;
}
