import Foundation

enum DeepSeekUsageError: Error, LocalizedError, Equatable {
    case keyNotFound
    case unauthorized
    case serviceUnavailable(retryAfter: TimeInterval?)
    case timedOut
    case invalidResponse
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .keyNotFound: return "未找到 DeepSeek API Key（~/.hermes/.env 或 config.yaml）。"
        case .unauthorized: return "DeepSeek 拒绝了 API Key，请检查密钥是否有效。"
        case .serviceUnavailable(let after):
            let wait = after.map { "\(Int($0.rounded())) 秒后" } ?? "稍后"
            return "DeepSeek 余额接口暂时不可用，\(wait)自动重试。"
        case .timedOut: return "DeepSeek 余额查询超时，稍后会自动重试。"
        case .invalidResponse: return "DeepSeek 返回的余额格式暂不支持。"
        case .networkUnavailable: return "网络不可用，暂时无法读取 DeepSeek 余额。"
        }
    }
}

/// DeepSeek 是预付费余额制，官方没有“剩余百分比”，只有账户余额。
struct DeepSeekBalance: Sendable, Equatable {
    let currency: String
    let total: Double
    let granted: Double?
    let toppedUp: Double?
    let isAvailable: Bool
    let fetchedAt: Date

    /// 菜单栏文本：大额省小数位，小额保留到分。
    var compactText: String {
        let symbol = currency == "CNY" ? "¥" : (currency == "USD" ? "$" : currency + " ")
        if total >= 100 { return symbol + String(format: "%.0f", total) }
        if total >= 10 { return symbol + String(format: "%.1f", total) }
        return symbol + String(format: "%.2f", total)
    }

    var detailText: String {
        let symbol = currency == "CNY" ? "¥" : (currency == "USD" ? "$" : currency + " ")
        return symbol + String(format: "%.2f", total)
    }

    static func parse(json data: Data, fetchedAt: Date = Date()) throws -> DeepSeekBalance {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]],
              let first = infos.first,
              let totalText = first["total_balance"] as? String,
              let total = Double(totalText) else {
            throw DeepSeekUsageError.invalidResponse
        }
        func number(_ key: String) -> Double? { (first[key] as? String).flatMap(Double.init) }
        return DeepSeekBalance(
            currency: first["currency"] as? String ?? "CNY",
            total: total,
            granted: number("granted_balance"),
            toppedUp: number("topped_up_balance"),
            isAvailable: root["is_available"] as? Bool ?? true,
            fetchedAt: fetchedAt
        )
    }
}

enum DeepSeekKeyStore {
    /// 依次查 ~/.hermes/.env、进程环境、~/.hermes/config.yaml 里 base_url 指向 api.deepseek.com 的 api_key。
    static func load() throws -> String {
        if let key = fromEnvFile() { return key }
        if let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !key.isEmpty { return key }
        if let key = fromHermesConfig() { return key }
        throw DeepSeekUsageError.keyNotFound
    }

    private static func fromEnvFile() -> String? {
        let path = NSHomeDirectory() + "/.hermes/.env"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("DEEPSEEK_API_KEY") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if value.hasPrefix("sk-") { return value }
        }
        return nil
    }

    private static func fromHermesConfig() -> String? {
        let path = NSHomeDirectory() + "/.hermes/config.yaml"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var pendingMatch = false
        for line in lines {
            if line.contains("api.deepseek.com") { pendingMatch = true; continue }
            guard pendingMatch, let range = line.range(of: "api_key:") else {
                if line.contains("base_url:") { pendingMatch = false }
                continue
            }
            let value = String(line[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if value.hasPrefix("sk-") { return value }
            pendingMatch = false
        }
        return nil
    }
}

struct DeepSeekClient: Sendable {
    let endpoint: URL
    let timeout: TimeInterval

    init(endpoint: URL = URL(string: "https://api.deepseek.com/user/balance")!, timeout: TimeInterval = 20) {
        self.endpoint = endpoint
        self.timeout = max(1, timeout)
    }

    func fetch() throws -> DeepSeekBalance {
        let key = try DeepSeekKeyStore.load()
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(Data, HTTPURLResponse), Error> = .failure(DeepSeekUsageError.networkUnavailable)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error as? URLError, error.code == .timedOut {
                outcome = .failure(DeepSeekUsageError.timedOut)
                return
            }
            guard error == nil, let data, let http = response as? HTTPURLResponse else {
                outcome = .failure(DeepSeekUsageError.networkUnavailable)
                return
            }
            outcome = .success((data, http))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw DeepSeekUsageError.timedOut
        }

        switch outcome {
        case .failure(let error):
            throw error
        case .success(let (data, response)):
            switch response.statusCode {
            case 200: return try DeepSeekBalance.parse(json: data)
            case 401, 403: throw DeepSeekUsageError.unauthorized
            case 429, 500...599:
                let after = response.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                throw DeepSeekUsageError.serviceUnavailable(retryAfter: after)
            default: throw DeepSeekUsageError.invalidResponse
            }
        }
    }
}

/// 上次成功的余额留一份，重启或限流时仍能显示上次读数。
enum DeepSeekCache {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Battery", isDirectory: true)
            .appendingPathComponent("deepseek-cache.json")
    }

    static func load() -> DeepSeekBalance? {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = (root["total"] as? NSNumber)?.doubleValue,
              let fetched = (root["fetchedAt"] as? NSNumber)?.doubleValue else { return nil }
        return DeepSeekBalance(
            currency: root["currency"] as? String ?? "CNY",
            total: total,
            granted: (root["granted"] as? NSNumber)?.doubleValue,
            toppedUp: (root["toppedUp"] as? NSNumber)?.doubleValue,
            isAvailable: root["isAvailable"] as? Bool ?? true,
            fetchedAt: Date(timeIntervalSince1970: fetched)
        )
    }

    static func save(_ balance: DeepSeekBalance) {
        let root: [String: Any] = [
            "currency": balance.currency, "total": balance.total,
            "granted": (balance.granted as Any?) ?? NSNull(), "toppedUp": (balance.toppedUp as Any?) ?? NSNull(),
            "isAvailable": balance.isAvailable, "fetchedAt": balance.fetchedAt.timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// DeepSeek 没有用量接口：今日花费只能用余额差分估算，充值时自动平移当日基准。
enum DeepSeekSpendTracker {
    struct State: Codable, Sendable, Equatable {
        var day: String
        var dayStartBalance: Double
        var lastBalance: Double
        var spentToday: Double
        var updatedAt: Date
        var toppedUpToday: Double

        static func empty() -> State {
            State(day: "", dayStartBalance: 0, lastBalance: 0, spentToday: 0, updatedAt: .distantPast, toppedUpToday: 0)
        }
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Battery", isDirectory: true)
            .appendingPathComponent("deepseek-spend.json")
    }

    static func load() -> State {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return .empty() }
        return state
    }

    static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// 用官网显示的“今日消费”倒推当天起始余额；之后仍按余额变化自动累加。
    static func calibrate(_ state: State, currentBalance: Double, spentToday: Double, now: Date = Date(),
                          timeZone: TimeZone = .current) -> State {
        var next = state
        let spent = max(0, spentToday)
        next.day = dayKey(now, timeZone: timeZone)
        next.dayStartBalance = currentBalance + spent
        next.lastBalance = currentBalance
        next.spentToday = spent
        next.toppedUpToday = 0
        next.updatedAt = now
        return next
    }

    /// 返回更新后的状态；跨天重新起算，余额上涨视为充值并平移基准。
    static func update(_ state: State, with balance: DeepSeekBalance, now: Date = Date(), timeZone: TimeZone = .current) -> State {
        var next = state
        let day = dayKey(now, timeZone: timeZone)

        if state.day != day {
            next.day = day
            next.dayStartBalance = balance.total
            next.spentToday = 0
            next.toppedUpToday = 0
        } else if balance.total > state.lastBalance + 0.0001 {
            let delta = balance.total - state.lastBalance
            next.dayStartBalance = state.dayStartBalance + delta
            next.toppedUpToday = state.toppedUpToday + delta
        }
        next.lastBalance = balance.total
        next.spentToday = max(0, next.dayStartBalance - balance.total)
        next.updatedAt = now
        return next
    }

    static func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
