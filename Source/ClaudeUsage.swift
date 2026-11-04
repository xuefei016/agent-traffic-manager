import Foundation

enum ClaudeUsageError: Error, LocalizedError, Equatable {
    case credentialsNotFound
    case loginExpired
    case unauthorized
    case serviceUnavailable
    case timedOut
    case invalidResponse
    case networkUnavailable
    case rateLimited(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound: return "未找到 Claude Code 登录信息，请先打开并登录 Claude Code。"
        case .loginExpired: return "Claude 登录凭证已过期，请打开 Claude Code 用一次以刷新。"
        case .unauthorized: return "Claude 拒绝了这次查询，请重新登录 Claude Code。"
        case .serviceUnavailable: return "暂时无法读取 Claude 用量，稍后会自动重试。"
        case .timedOut: return "Claude 用量查询超时，稍后会自动重试。"
        case .invalidResponse: return "Claude 返回的用量格式暂不支持。"
        case .networkUnavailable: return "网络不可用，暂时无法读取 Claude 用量。"
        case .rateLimited(let after):
            let wait = after.map { "\(Int($0.rounded())) 秒后" } ?? "稍后"
            return "Claude 用量查询被限流，\(wait)自动重试（菜单保留上次读数）。"
        }
    }
}

/// Claude Code 账号额度快照。只用服务端返回的五个小时与七天周期，未知绝不当成 0。
struct ClaudeSnapshot: Sendable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let fetchedAt: Date

    static let fiveHourMinutes = 300
    static let sevenDayMinutes = 10_080

    init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, fetchedAt: Date = Date()) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }

    var windows: [UsageWindow] { [fiveHour, sevenDay].compactMap { $0 } }

    /// 按菜单栏统一口径取窗口：5 小时或每周；缺哪个就退回另一个，绝不显示空白。
    func window(for selection: UsageDisplayWindow) -> UsageWindow? {
        switch selection {
        case .shortTerm: return fiveHour ?? sevenDay
        case .weekly: return sevenDay ?? fiveHour
        case .limiting: return chosenWindow()
        }
    }

    /// 与 Codex 一致地选“剩余最少且仍有效的周期”，仅用于旧的自动口径。
    func chosenWindow(now: Date = Date()) -> UsageWindow? {
        let known = windows.filter { $0.remainingPercent != nil }
        let current = known.filter { $0.resetDate.map { $0 > now } ?? true }
        return (current.isEmpty ? known : current)
            .min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) } ?? windows.first
    }

    static func parse(json data: Data, fetchedAt: Date = Date()) throws -> ClaudeSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.invalidResponse
        }
        var fiveHour = window(root["five_hour"], minutes: fiveHourMinutes)
        var sevenDay = window(root["seven_day"], minutes: sevenDayMinutes)
        // 新版接口同时给出 limits 数组；仅在命名周期缺失时作为兜底。
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = limit["kind"] as? String else { continue }
                switch kind {
                case "session" where fiveHour == nil:
                    fiveHour = window(limit, minutes: fiveHourMinutes, percentKey: "percent")
                case "weekly_all" where sevenDay == nil:
                    sevenDay = window(limit, minutes: sevenDayMinutes, percentKey: "percent")
                default: break
                }
            }
        }
        guard fiveHour != nil || sevenDay != nil else { throw ClaudeUsageError.invalidResponse }
        return ClaudeSnapshot(fiveHour: fiveHour, sevenDay: sevenDay, fetchedAt: fetchedAt)
    }

    private static func window(_ value: Any?, minutes: Int, percentKey: String = "utilization") -> UsageWindow? {
        guard let object = value as? [String: Any] else { return nil }
        let used = number(object[percentKey])
        let reset = (object["resets_at"] as? String).flatMap(isoDate)
        guard used != nil || reset != nil else { return nil }
        return UsageWindow(usedPercent: used, windowDurationMins: minutes, resetsAt: reset?.timeIntervalSince1970)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    /// resets_at 形如 2026-10-27T12:10:00.331967+00:00。
    /// 429 会给出 retry-after 秒数，照它退避比盲目翻倍更准。
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "retry-after"),
              let seconds = Double(raw.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds > 0
        else { return nil }
        return min(seconds, 3_600)
    }

    static func isoDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // 微秒位数超过 3 位时部分系统解析失败，截断后再试一次。
        if let dot = text.firstIndex(of: "."),
           let zoneStart = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let head = text[..<dot]
            let fraction = text[text.index(after: dot)..<zoneStart].prefix(3)
            return fractional.date(from: "\(head).\(fraction)\(text[zoneStart...])")
        }
        return nil
    }
}

/// 上次成功的读数留一份在本地：限流或离线时不至于空白，也不会把旧值当新值。
enum ClaudeUsageCache {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Battery", isDirectory: true)
        return base.appendingPathComponent("claude-cache.json")
    }

    static func load() -> ClaudeSnapshot? {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fetched = (root["fetchedAt"] as? NSNumber).map({ Date(timeIntervalSince1970: $0.doubleValue) })
        else { return nil }
        return ClaudeSnapshot(fiveHour: window(root["fiveHour"], minutes: ClaudeSnapshot.fiveHourMinutes),
                              sevenDay: window(root["sevenDay"], minutes: ClaudeSnapshot.sevenDayMinutes),
                              fetchedAt: fetched)
    }

    static func save(_ snapshot: ClaudeSnapshot) {
        let root: [String: Any] = [
            "fetchedAt": snapshot.fetchedAt.timeIntervalSince1970,
            "fiveHour": encode(snapshot.fiveHour),
            "sevenDay": encode(snapshot.sevenDay)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func encode(_ window: UsageWindow?) -> Any {
        guard let window else { return NSNull() }
        return ["used": (window.usedPercent as Any?) ?? NSNull(), "reset": (window.resetsAt as Any?) ?? NSNull()]
    }

    private static func window(_ value: Any?, minutes: Int) -> UsageWindow? {
        guard let object = value as? [String: Any] else { return nil }
        let used = (object["used"] as? NSNumber)?.doubleValue
        let reset = (object["reset"] as? NSNumber)?.doubleValue
        guard used != nil || reset != nil else { return nil }
        return UsageWindow(usedPercent: used, windowDurationMins: minutes, resetsAt: reset)
    }
}

struct ClaudeCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date?

    var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }
}

enum ClaudeCredentialStore {
    static let keychainService = "Claude Code-credentials"

    /// 先读钥匙串（Claude Code 的真实来源），再退回 ~/.claude/.credentials.json。
    static func load() throws -> ClaudeCredentials {
        if let data = keychainData(), let value = decode(data), !value.isExpired { return value }
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        if let data = FileManager.default.contents(atPath: path), let value = decode(data) {
            guard !value.isExpired else { throw ClaudeUsageError.loginExpired }
            return value
        }
        if let data = keychainData(), let value = decode(data) {
            throw value.isExpired ? ClaudeUsageError.loginExpired : ClaudeUsageError.credentialsNotFound
        }
        throw ClaudeUsageError.credentialsNotFound
    }

    private static func decode(_ data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiry = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1_000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expiry)
    }

    /// 调用系统 security 读取通用密码；读不到时静默返回 nil，由调用方退回文件。
    private static func keychainData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }
}

/// 只读查询 Claude Code 账号额度，不发起任何推理请求。
struct ClaudeUsageClient: Sendable {
    let endpoint: URL
    let timeout: TimeInterval

    init(endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeout: TimeInterval = 25) {
        self.endpoint = endpoint
        self.timeout = max(1, timeout)
    }

    func fetch() throws -> ClaudeSnapshot {
        let credentials = try ClaudeCredentialStore.load()
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(Data, HTTPURLResponse), Error> = .failure(ClaudeUsageError.networkUnavailable)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error as? URLError, error.code == .timedOut {
                outcome = .failure(ClaudeUsageError.timedOut)
                return
            }
            guard error == nil, let data, let http = response as? HTTPURLResponse else {
                outcome = .failure(ClaudeUsageError.networkUnavailable)
                return
            }
            outcome = .success((data, http))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw ClaudeUsageError.timedOut
        }

        switch outcome {
        case .failure(let error):
            throw error
        case .success(let (data, response)):
            switch response.statusCode {
            case 200: return try ClaudeSnapshot.parse(json: data)
            case 401, 403: throw ClaudeUsageError.unauthorized
            case 429: throw ClaudeUsageError.rateLimited(retryAfter: ClaudeSnapshot.retryAfter(from: response))
            case 500...599: throw ClaudeUsageError.serviceUnavailable
            default: throw ClaudeUsageError.invalidResponse
            }
        }
    }
}
