#include "Platform.h"
#include <wincrypt.h>
#include <algorithm>
#include <ctime>
#include <fstream>
#include <iostream>
#include <stdexcept>
using namespace usagebar;
namespace fs = std::filesystem;
static void check(bool ok) { if (!ok) throw std::runtime_error("assertion failed"); }
template<class F> static void throws(F fn) { bool caught=false; try { fn(); } catch(...) { caught=true; } check(caught); }
int main() {
    wchar_t temp[32768];
    if (!GetTempPathW(32768,temp)) return 1;
    auto sandbox=fs::path(temp)/(L"UsageBarChecks-"+std::to_wstring(GetCurrentProcessId()))/L"中文测试";
    try {
        fs::create_directories(sandbox);
        auto path=sandbox/L"test-key.dat";
        check(readKey(path).empty());
        saveKey("usagebar-offline-test",path);
        check(readKey(path)=="usagebar-offline-test");
        check(readBytes(path).find("usagebar-offline-test")==std::string::npos);
        saveKey("replacement-offline-test",path); check(readKey(path)=="replacement-offline-test");
        deleteKey(path); check(readKey(path).empty());
        writeAtomic(path,"invalid encrypted data"); throws([&]{readKey(path);}); deleteKey(path);
        std::cout<<"PASS isolated DPAPI save, replace, delete and corruption\n";
        check(utf8(wide("中文路径/账户"))=="中文路径/账户");
        auto file=sandbox/L"配置.json"; writeAtomic(file,"old"); writeAtomic(file,"new"); check(readBytes(file)=="new");
        throws([&]{readBytes(file,1);});
        std::cout<<"PASS Unicode paths and bounded atomic persistence\n";
        auto auth=parseJson(R"({"tokens":{"account_id":"direct-fixture","access_token":"not-a-token"}})");
        check(accountFromAuth(auth)=="direct-fixture");
        std::string payload=R"({"https://api.openai.com/auth":{"chatgpt_account_id":"jwt-fixture"}})";
        DWORD size=0; CryptBinaryToStringA(reinterpret_cast<const BYTE*>(payload.data()),DWORD(payload.size()),CRYPT_STRING_BASE64|CRYPT_STRING_NOCRLF,nullptr,&size);
        std::string encoded(size,'\0'); CryptBinaryToStringA(reinterpret_cast<const BYTE*>(payload.data()),DWORD(payload.size()),CRYPT_STRING_BASE64|CRYPT_STRING_NOCRLF,encoded.data(),&size); encoded.resize(size);
        while(!encoded.empty()&&(encoded.back()=='='||encoded.back()=='\0')) encoded.pop_back();
        std::replace(encoded.begin(),encoded.end(),'+','-'); std::replace(encoded.begin(),encoded.end(),'/','_');
        check(accountFromAuth(Json{{"tokens",{{"access_token","header."+encoded+".signature"}}}})=="jwt-fixture");
        throws([]{httpGet(L"example.com",L"/", "fake-test");});
        throws([]{httpGet(L"api.deepseek.com",L"/user/balance","header\r\ninjection");});
        std::cout<<"PASS OAuth account fallback and rejected unsafe requests (no network)\n";
        time_t time=std::time(nullptr); std::tm date{}; gmtime_s(&date,&time); wchar_t folder[32]; swprintf_s(folder,L"%04d/%02d/%02d",date.tm_year+1900,date.tm_mon+1,date.tm_mday);
        auto sessions=sandbox/L"codex"/L"sessions"/folder; fs::create_directories(sessions);
        char stamp[32]; strftime(stamp,32,"%Y-%m-%dT%H:%M:%SZ",&date);
        auto event=Json{{"timestamp",stamp},{"payload",{{"type","token_count"},{"rate_limits",{{"primary",{{"used_percent",12},{"resets_in_seconds",3600}}}}}}}}.dump();
        writeAtomic(sessions/L"rollout-test.jsonl",event+"\n"+std::string(2*1024*1024,'x')+"\npartial");
        auto snapshot=latestRollout(sandbox/L"codex",time); check(snapshot&&highestUsed(*snapshot)==12&&snapshot->captured==time);
        Preferences p; p.home=utf8((sandbox/L"codex").wstring()); p.source="rollout";
        check(fetchCodex(p,time).source=="rollout");
        std::cout<<"PASS bounded rollout scan and offline provider (no real credentials)\n";
        fs::remove_all(sandbox.parent_path()); return 0;
    } catch(const std::exception& e) { std::cerr<<"FAIL Windows platform checks: "<<e.what()<<'\n'; fs::remove_all(sandbox.parent_path()); return 1; }
}
