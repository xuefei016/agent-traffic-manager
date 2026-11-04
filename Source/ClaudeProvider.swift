import Foundation
import Security

/// Add supported providers here; never present an unimplemented vendor.
enum ClaudeProvider: String, CaseIterable {
    case official, bai
    static let preferenceKey = "claudeProvider"
    var title: String { self == .official ? "官方订阅（Claude）" : "第三方 · B.AI" }
    var label: String { self == .official ? "Claude" : "B.AI" }
    var source: String { self == .official ? "https://api.anthropic.com/api/oauth/usage" : "https://api.b.ai/v1/balance" }
    static func selected(in preferences: UserDefaults) -> Self {
        Self(rawValue: preferences.string(forKey: preferenceKey) ?? "") ?? .official
    }
}

/// A generation also invalidates A → B → A and key changes while a request is running.
struct ProviderRequestGate {
    private(set) var generation = 0
    mutating func invalidate() { generation += 1 }
    func accepts(_ ticket: Int) -> Bool { ticket == generation }
}

enum BAIError: Error, LocalizedError {
    case missingKey, keychain, unauthorized, rejected, invalidResponse, network, rateLimited(TimeInterval?)
    var errorDescription: String? {
        switch self {
        case .missingKey: return "尚未配置 B.AI API Key，请在菜单中安全配置。"
        case .keychain: return "B.AI 密钥未能保存到系统钥匙串。"
        case .unauthorized: return "B.AI 密钥无效或无权读取余额。"
        case .rejected: return "B.AI 返回查询失败，稍后重试。"
        case .invalidResponse: return "B.AI 余额响应缺少有效字段。"
        case .network: return "B.AI 余额查询网络失败或超时。"
        case .rateLimited: return "B.AI 查询被限流，稍后自动重试。"
        }
    }
}

struct BAIBalance: Codable, Equatable {
    let keyType: String
    let active: String?
    let personal: Int64?
    let team: Int64?
    let role: String?
    let quotaType: String?
    let quotaLimit: Int64?
    let quotaUsed: Int64?
    let resetAt: String?
    let serverTimestamp: String?
    let fetchedAt: Date

    var available: Int64? {
        if keyType == "personal" { return personal }
        if role == "admin" { return team }
        if quotaType == "limited", let quotaLimit, let quotaUsed { return max(0, quotaLimit - quotaUsed) }
        return nil
    }
    func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(fetchedAt) > 900 }
    var text: String { available.map { "\($0) Credits" } ?? "未知 Credits" }

    /// 菜单栏以 M 为主单位（百万以上），不足百万才退到 K／原值；精确值只放菜单详情。
    var compactText: String {
        guard let value = available else { return "--" }
        let negative = value < 0
        let magnitude = abs(Double(value))
        let body: String
        if magnitude >= 1_000_000 {
            let millions = magnitude / 1_000_000
            if millions < 100 {
                body = String(format: "%.2fM", millions)
            } else if millions < 1_000 {
                body = String(format: "%.1fM", millions)
            } else {
                body = String(format: "%.0fM", millions)
            }
        } else if magnitude >= 100_000 {
            body = String(format: "%.0fK", magnitude / 1_000)
        } else if magnitude >= 1_000 {
            body = String(format: "%.1fK", magnitude / 1_000)
        } else {
            body = String(Int64(magnitude))
        }
        return (negative ? "-" : "") + body
    }
    var details: [String] {
        var lines = ["B.AI · \(keyType == "personal" ? "个人余额" : "团队余额/成员配额")", "可用：\(text)"]
        if let active { lines.append("密钥状态：\(active == "active" ? "有效" : "非有效状态")") }
        if let role { lines.append("团队角色：\(role)") }
        if let team { lines.append("团队余额：\(team) Credits") }
        if let quotaType { lines.append("成员配额：\(quotaType == "unlimited" ? "无限制（非团队余额）" : "有限")") }
        if let quotaLimit { lines.append("成员配额上限：\(quotaLimit) Credits") }
        if let quotaUsed { lines.append("成员已用：\(quotaUsed) Credits") }
        if let resetAt { lines.append("配额重置：\(resetAt)") }
        return lines
    }
    static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = root["success"] as? NSNumber, CFGetTypeID(success) == CFBooleanGetTypeID() else { throw BAIError.invalidResponse }
        guard success.boolValue else { throw BAIError.rejected }
        guard let d = root["data"] as? [String: Any], let type = d["api_key_type"] as? String,
              ["personal", "team"].contains(type) else { throw BAIError.invalidResponse }
        func integer(_ value: Any?) -> Int64? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  let result = Int64(n.stringValue), result >= 0 else { return nil }
            return result
        }
        let t = d["team"] as? [String: Any] ?? [:]
        let active = d["active_status"] as? String
        return Self(keyType: type, active: active, personal: integer(d["personal_balance"]),
                    team: (t["team_role"] as? String) == "admin" ? integer(t["team_balance"]) : nil,
                    role: ["admin", "member"].contains(t["team_role"] as? String ?? "") ? t["team_role"] as? String : nil,
                    quotaType: ["limited", "unlimited"].contains(t["quota_limit_type"] as? String ?? "") ? t["quota_limit_type"] as? String : nil,
                    quotaLimit: (t["quota_limit_type"] as? String) == "limited" ? integer(t["member_quota_limit"]) : nil, quotaUsed: integer(t["member_quota_used"]),
                    resetAt: t["quota_reset_at"] as? String,
                    serverTimestamp: (d["timestamp"] as? NSNumber)?.stringValue, fetchedAt: now)
    }
}

/// Only read credentials paired with the exact B.AI host in that same configuration.
enum BAIKeyStore {
    static let service = "local.codex-battery.bai"
    static let account = "api.b.ai"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    static func configuredKey(_ env: [String: String]) -> String? {
        guard let base = env["ANTHROPIC_BASE_URL"], let url = URL(string: base),
              url.scheme == "https", url.host?.lowercased() == "api.b.ai", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"].compactMap { env[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
    static func load() throws -> String {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty { return key }
        if let key = configuredKey(ProcessInfo.processInfo.environment) { return key }
        for name in ["settings.local.json", "settings.json"] {
            let path = NSHomeDirectory() + "/.claude/" + name
            if let data = FileManager.default.contents(atPath: path),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let env = root["env"] as? [String: String], let key = configuredKey(env) { return key }
        }
        throw BAIError.missingKey
    }
    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw BAIError.keychain }
        } else if status != errSecSuccess { throw BAIError.keychain }
    }
}

enum BAICache {
    static var url: URL { ClaudeUsageCache.fileURL.deletingLastPathComponent().appendingPathComponent("bai-cache.json") }
    static func load() -> BAIBalance? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(BAIBalance.self, from: $0) } }
    static func save(_ value: BAIBalance) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}

/// Fixed host, sanitized errors, no response body or credential in diagnostics.
struct BAIClient {
    func fetch() throws -> BAIBalance {
        let key = try BAIKeyStore.load()
        var request = URLRequest(url: URL(string: ClaudeProvider.bai.source)!)
        request.httpMethod = "GET"; request.timeoutInterval = 25
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<BAIBalance, Error> = .failure(BAIError.network)
        let session = URLSession(configuration: .ephemeral, delegate: NoBAIRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil, let http = response as? HTTPURLResponse, let data else { return }
            switch http.statusCode {
            case 200: outcome = Result { try BAIBalance.parse(data) }
            case 401, 403: outcome = .failure(BAIError.unauthorized)
            case 429: outcome = .failure(BAIError.rateLimited(ClaudeSnapshot.retryAfter(from: http)))
            default: outcome = .failure(BAIError.rejected)
            }
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 30) == .success else { task.cancel(); throw BAIError.network }
        return try outcome.get()
    }
}
private final class NoBAIRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
