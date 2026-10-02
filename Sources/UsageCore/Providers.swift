import Foundation

public struct HTTPResult: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}
public protocol UsageHTTPClient: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> HTTPResult
}

// Never forward credentials through a redirect. Only two fixed HTTPS hosts are used.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class SecureHTTPClient: UsageHTTPClient, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    public func get(url: URL, headers: [String: String]) async throws -> HTTPResult {
        guard url.scheme == "https", ["chatgpt.com", "api.deepseek.com"].contains(url.host ?? "") else { throw UsageError.network }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers.merging(["Accept": "application/json", "User-Agent": "UsageBar/1.0"]) { first, _ in first }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
            // Reject error bodies before consuming them; no remote error text is logged or displayed.
            try Self.validate(response.statusCode)
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_048_576 else { throw UsageError.invalidResponse }
                data.append(byte)
            }
            return HTTPResult(status: response.statusCode, data: data)
        } catch let error as UsageError { throw error }
        catch let error as URLError where error.code == .timedOut { throw UsageError.timeout }
        catch is CancellationError { throw CancellationError() }
        catch { throw UsageError.network }
    }
    public static func validate(_ status: Int) throws {
        if status == 401 || status == 403 { throw UsageError.unauthorized }
        guard (200..<300).contains(status) else { throw UsageError.http(status) }
    }
}

public struct CodexAuth: Equatable, Sendable {
    public let accessToken: String
    public let accountID: String?
    public static func parse(data: Data) throws -> CodexAuth {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = j["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { throw UsageError.noLogin }
        let direct = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let account = direct ?? accountID(jwt: tokens["id_token"] as? String) ?? accountID(jwt: token)
        return CodexAuth(accessToken: token, accountID: account)
    }
    private static func accountID(jwt: String?) -> String? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let nested = claims["https://api.openai.com/auth"] as? [String: Any]
        return CodexParser.string(claims["chatgpt_account_id"], nested?["chatgpt_account_id"])
    }
}

public actor CodexProvider {
    private let client: any UsageHTTPClient
    private let reader: RolloutReader
    public init(client: any UsageHTTPClient = SecureHTTPClient(), reader: RolloutReader = RolloutReader()) {
        self.client = client; self.reader = reader
    }
    public func fetch(home: URL, source: CodexSource, now: Date = Date()) async throws -> CodexSnapshot {
        var fallback: String?
        if source != .rollout {
            do {
                let authData: Data
                do { authData = try Data(contentsOf: home.appendingPathComponent("auth.json")) }
                catch { throw UsageError.noLogin }
                let auth = try CodexAuth.parse(data: authData)
                var headers = ["Authorization": "Bearer " + auth.accessToken]
                if let account = auth.accountID { headers["ChatGPT-Account-Id"] = account }
                let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
                let result = try await client.get(url: url, headers: headers)
                try SecureHTTPClient.validate(result.status)
                return try CodexParser.parse(data: result.data, capturedAt: now, origin: url.absoluteString)
            } catch is CancellationError { throw CancellationError() }
            catch { fallback = error.localizedDescription }
        }
        if var snapshot = await reader.latest(home: home, now: now) {
            snapshot.fallbackReason = fallback
            return snapshot
        }
        if let fallback { throw ProviderFailure(message: fallback + "\n" + UsageError.noRollout.localizedDescription) }
        throw UsageError.noRollout
    }
}

public struct ProviderFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public struct DeepSeekProvider: Sendable {
    private let client: any UsageHTTPClient
    public init(client: any UsageHTTPClient = SecureHTTPClient()) { self.client = client }
    public func fetch(key: String, now: Date = Date()) async throws -> BalanceSnapshot {
        let result = try await client.get(url: URL(string: "https://api.deepseek.com/user/balance")!, headers: ["Authorization": "Bearer " + key])
        try SecureHTTPClient.validate(result.status)
        return try BalanceParser.parse(data: result.data, capturedAt: now)
    }
}
