import Foundation
import UsageCore

private actor FakeClient: UsageHTTPClient {
    let result: HTTPResult
    var requests: [(URL, [String: String])] = []
    init(status: Int = 200, body: String) { result = HTTPResult(status: status, data: Data(body.utf8)) }
    func get(url: URL, headers: [String: String]) async throws -> HTTPResult {
        requests.append((url, headers)); return result
    }
}

final class ProviderTests {
    private var temporaryDirectories: [URL] = []
    deinit { temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) } }
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
    private func rolloutURL(_ home: URL, date: Date, name: String = "rollout-fixture.jsonl") throws -> URL {
        let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy/MM/dd"
        let directory = home.appendingPathComponent("sessions/" + f.string(from: date))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
    private func line(_ percent: Int, date: Date, relative: Int = 30) -> String {
        "{\"timestamp\":\"\(ISO8601DateFormatter().string(from: date))\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":\(percent),\"window_minutes\":300,\"resets_in_seconds\":\(relative)}}}}"
    }
    func testAPIUsesExistingCredentialWithoutModifyingFile() async throws {
        let home = try temporaryHome()
        let auth = Data(#"{"tokens":{"access_token":"fixture-token","account_id":"fixture-account"}}"#.utf8)
        let path = home.appendingPathComponent("auth.json")
        try auth.write(to: path)
        let client = FakeClient(body: #"{"rate_limit":{"primary_window":{"used_percent":20,"window_minutes":300}}}"#)
        let snapshot = try await CodexProvider(client: client).fetch(home: home, source: .auto)
        expect(snapshot.source == "api")
        let requests = await client.requests
        expect(requests.count == 1)
        expect(requests[0].0.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        expect(requests[0].1["Authorization"] == "Bearer fixture-token")
        expect(requests[0].1["ChatGPT-Account-Id"] == "fixture-account")
        expect(try Data(contentsOf: path) == auth)
    }
    func testUnauthorizedFallsBackAndOfflineNeverCallsNetwork() async throws {
        let home = try temporaryHome(); let now = Date()
        try Data(#"{"tokens":{"access_token":"fixture-token"}}"#.utf8).write(to: home.appendingPathComponent("auth.json"))
        try Data(line(44, date: now).utf8).write(to: rolloutURL(home, date: now))
        let client = FakeClient(status: 401, body: "")
        let provider = CodexProvider(client: client)
        let fallback = try await provider.fetch(home: home, source: .api, now: now)
        expect(fallback.source == "rollout")
        expect(fallback.fallbackReason != nil)
        expect(fallback.highestUsed == 44)
        let offline = try await provider.fetch(home: home, source: .rollout, now: now)
        expect(offline.fallbackReason == nil)
        let requests = await client.requests
        expect(requests.count == 1)
    }
    func testReverseScanHandlesChunkBoundariesPartialLinesAndCacheInvalidation() async throws {
        let home = try temporaryHome(); let now = Date()
        let url = try rolloutURL(home, date: now)
        let content = line(10, date: now.addingTimeInterval(-60)) + "\n" + String(repeating: "x", count: 130000) + "\n" + line(45, date: now) + "\n{\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}\n{partial"
        try Data(content.utf8).write(to: url)
        let reader = RolloutReader()
        let first = await reader.latest(home: home, now: now)
        expect(first?.highestUsed == 45)
        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + line(70, date: now.addingTimeInterval(10))).utf8)); try handle.close()
        let second = await reader.latest(home: home, now: now)
        expect(second?.highestUsed == 70)
    }
    func testUsesEventTimestampRatherThanTouchedFileOrder() async throws {
        let home = try temporaryHome(); let now = Date()
        let older = try rolloutURL(home, date: now, name: "rollout-older.jsonl")
        let newer = try rolloutURL(home, date: now, name: "rollout-newer.jsonl")
        try Data(line(22, date: now.addingTimeInterval(-3600)).utf8).write(to: older)
        try Data(line(80, date: now).utf8).write(to: newer)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: older.path)
        let snapshot = await RolloutReader().latest(home: home, now: now)
        expect(snapshot?.highestUsed == 80)
    }
    func testVeryLongConversationLineDoesNotHideEarlierEvent() async throws {
        let home = try temporaryHome(); let now = Date(); let url = try rolloutURL(home, date: now)
        try Data((line(19, date: now) + "\n" + String(repeating: "x", count: 1_200_000) + "\n{partial").utf8).write(to: url)
        let snapshot = await RolloutReader().latest(home: home, now: now)
        expect(snapshot?.highestUsed == 19)
    }
    func testDeepSeekTypedFailures() async throws {
        for status in [401, 402, 429, 503] {
            let client = FakeClient(status: status, body: "private remote error")
            do { _ = try await DeepSeekProvider(client: client).fetch(key: "fixture"); recordFailure("Should reject HTTP \(status)") }
            catch { expect((error as? UsageError) == (status == 401 ? .unauthorized : .http(status))) }
        }
    }
}
