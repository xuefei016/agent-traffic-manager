import Foundation

enum GrokUsageError: Error, LocalizedError, Equatable {
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
        case .credentialsNotFound: return "未找到 Grok CLI 登录信息，请在终端运行一次 grok 并登录。"
        case .loginExpired: return "Grok 登录凭证已过期，自动续期失败；请在终端运行 grok login 重新登录。"
        case .unauthorized: return "Grok 拒绝了这次查询，请重新登录 Grok CLI。"
        case .serviceUnavailable: return "暂时无法读取 Grok 额度，稍后会自动重试。"
        case .timedOut: return "Grok 额度查询超时，稍后会自动重试。"
        case .invalidResponse: return "Grok 返回的额度格式暂不支持。"
        case .networkUnavailable: return "网络不可用，暂时无法读取 Grok 额度。"
        case .rateLimited(let after):
            let wait = after.map { "\(Int($0.rounded())) 秒后" } ?? "稍后"
            return "Grok 额度查询被限流，\(wait)自动重试（菜单保留上次读数）。"
        }
    }
}

/// 一个产品的用量占比；Grok 把总额度按产品分账，例如 GrokBot / GrokBuild / Cursor。
struct GrokProductUsage: Sendable, Equatable {
    let product: String
    let usedPercent: Double
}

/// 订阅套餐信息（来自 grok.com/rest/subscriptions，取不到时留空，不影响用量读数）。
struct GrokPlanInfo: Sendable, Equatable {
    let plan: String
    let tier: String
    let active: Bool
    let renewsAt: Date?
    let cancelAtPeriodEnd: Bool

    var displayName: String {
        switch plan.lowercased() {
        case "supergrok": return "SuperGrok"
        case "": return tier.isEmpty ? "Grok 订阅" : tier
        default: return plan.prefix(1).uppercased() + plan.dropFirst()
        }
    }
}

/// Grok 账号额度快照。百分比来自服务端 creditUsagePercent，未知绝不当成 0。
struct GrokSnapshot: Sendable, Equatable {
    let usedPercent: Double?
    let periodStart: Date?
    let periodEnd: Date?
    let periodType: String?
    let products: [GrokProductUsage]
    let prepaidBalance: Double?
    let isUnifiedBilling: Bool
    let plan: GrokPlanInfo?
    let fetchedAt: Date

    init(usedPercent: Double?, periodStart: Date?, periodEnd: Date?, periodType: String?,
         products: [GrokProductUsage] = [], prepaidBalance: Double? = nil, isUnifiedBilling: Bool = false,
         plan: GrokPlanInfo? = nil, fetchedAt: Date = Date()) {
        self.usedPercent = usedPercent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.periodType = periodType
        self.products = products
        self.prepaidBalance = prepaidBalance
        self.isUnifiedBilling = isUnifiedBilling
        self.plan = plan
        self.fetchedAt = fetchedAt
    }

    /// 服务端周期长度（周/月）换算成分钟，用于统一的 UsageWindow 口径。
    var periodMinutes: Int? {
        guard let periodStart, let periodEnd else { return nil }
        let minutes = Int((periodEnd.timeIntervalSince(periodStart) / 60).rounded())
        return minutes > 0 ? minutes : nil
    }

    var window: UsageWindow? {
        guard usedPercent != nil || periodEnd != nil else { return nil }
        return UsageWindow(usedPercent: usedPercent, windowDurationMins: periodMinutes,
                           resetsAt: periodEnd?.timeIntervalSince1970)
    }

    var periodLabel: String {
        if let minutes = periodMinutes, minutes == 10_080 { return "本周" }
        switch periodType {
        case "USAGE_PERIOD_TYPE_WEEKLY": return "本周"
        case "USAGE_PERIOD_TYPE_MONTHLY": return "本月"
        case "USAGE_PERIOD_TYPE_DAILY": return "今天"
        default: return "当前周期"
        }
    }

    /// 产品分账只用于明细展示；它按同一总额度归因，不叠加成新的额度。
    var productSummary: String {
        products
            .filter { !$0.product.isEmpty }
            .map { "\($0.product) \(Int($0.usedPercent.rounded()))%" }
            .joined(separator: " · ")
    }

    static func parse(json data: Data, plan: GrokPlanInfo? = nil, fetchedAt: Date = Date()) throws -> GrokSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokUsageError.invalidResponse
        }
        // 用量字段在 config 里；部分响应直接把 config 铺在顶层，两种都接受。
        let config = (root["config"] as? [String: Any]) ?? root
        let percent = number(config["creditUsagePercent"])
        let period = config["currentPeriod"] as? [String: Any]
        let start = (period?["start"] as? String).flatMap(GrokSnapshot.isoDate)
        let end = (period?["end"] as? String).flatMap(GrokSnapshot.isoDate)
            ?? (config["billingPeriodEnd"] as? String).flatMap(GrokSnapshot.isoDate)
        let type = period?["type"] as? String
        let products = (config["productUsage"] as? [[String: Any]] ?? []).compactMap { entry -> GrokProductUsage? in
            guard let name = entry["product"] as? String, let used = number(entry["usagePercent"]) else { return nil }
            return GrokProductUsage(product: name, usedPercent: used)
        }
        let prepaid = (config["prepaidBalance"] as? [String: Any]).flatMap { number($0["val"]) }
        let unified = (config["isUnifiedBillingUser"] as? Bool) ?? false
        guard percent != nil || end != nil else { throw GrokUsageError.invalidResponse }
        return GrokSnapshot(usedPercent: percent, periodStart: start, periodEnd: end, periodType: type,
                            products: products, prepaidBalance: prepaid, isUnifiedBilling: unified,
                            plan: plan, fetchedAt: fetchedAt)
    }

    /// 套餐接口的响应用同一套 ISO8601 解析。
    static func parsePlan(json data: Data) -> GrokPlanInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subscriptions = root["subscriptions"] as? [[String: Any]] else { return nil }
        // 同一个账号可能同时挂着 SuperGrok 和 X Premium：以 dominantPlan 为准，否则取第一份有效订阅。
        var chosen: [String: Any]?
        if let dominant = (root["dominantPlan"] as? [String: Any])?["plan"] as? String, !dominant.isEmpty {
            chosen = subscriptions.first { ($0["plan"] as? String) == dominant }
        }
        if chosen == nil {
            chosen = subscriptions.first { ($0["status"] as? String) == "SUBSCRIPTION_STATUS_ACTIVE" } ?? subscriptions.first
        }
        guard let entry = chosen else { return nil }
        let status = entry["status"] as? String ?? ""
        return GrokPlanInfo(plan: entry["plan"] as? String ?? "",
                            tier: entry["tier"] as? String ?? "",
                            active: status == "SUBSCRIPTION_STATUS_ACTIVE",
                            renewsAt: (entry["billingPeriodEnd"] as? String).flatMap(isoDate),
                            cancelAtPeriodEnd: entry["cancelAtPeriodEnd"] as? Bool ?? false)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "retry-after"),
              let seconds = Double(raw.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds > 0
        else { return nil }
        return min(seconds, 3_600)
    }

    /// 服务端时间形如 2026-11-12T00:48:31.616+00:00。
    static func isoDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        if let dot = text.firstIndex(of: "."),
           let zoneStart = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let head = text[..<dot]
            let fraction = text[text.index(after: dot)..<zoneStart].prefix(3)
            return fractional.date(from: "\(head).\(fraction)\(text[zoneStart...])")
        }
        return nil
    }
}

/// 上次成功的读数留一份在本地：凭证过期或离线时不至于空白，也不会把旧值当新值。
enum GrokUsageCache {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Battery", isDirectory: true)
        return base.appendingPathComponent("grok-cache.json")
    }

    static func load() -> GrokSnapshot? {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fetched = (root["fetchedAt"] as? NSNumber).map({ Date(timeIntervalSince1970: $0.doubleValue) })
        else { return nil }
        let products = (root["products"] as? [[String: Any]] ?? []).compactMap { entry -> GrokProductUsage? in
            guard let name = entry["product"] as? String, let used = (entry["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            return GrokProductUsage(product: name, usedPercent: used)
        }
        let plan = (root["plan"] as? [String: Any]).map { entry in
            GrokPlanInfo(plan: entry["plan"] as? String ?? "", tier: entry["tier"] as? String ?? "",
                         active: entry["active"] as? Bool ?? false,
                         renewsAt: (entry["renewsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                         cancelAtPeriodEnd: entry["cancelAtPeriodEnd"] as? Bool ?? false)
        }
        return GrokSnapshot(
            usedPercent: (root["usedPercent"] as? NSNumber)?.doubleValue,
            periodStart: (root["periodStart"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            periodEnd: (root["periodEnd"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            periodType: root["periodType"] as? String,
            products: products,
            prepaidBalance: (root["prepaidBalance"] as? NSNumber)?.doubleValue,
            isUnifiedBilling: root["isUnifiedBilling"] as? Bool ?? false,
            plan: plan,
            fetchedAt: fetched)
    }

    static func save(_ snapshot: GrokSnapshot) {
        var root: [String: Any] = [
            "fetchedAt": snapshot.fetchedAt.timeIntervalSince1970,
            "isUnifiedBilling": snapshot.isUnifiedBilling,
            "products": snapshot.products.map { ["product": $0.product, "usedPercent": $0.usedPercent] }
        ]
        root["usedPercent"] = snapshot.usedPercent as Any? ?? NSNull()
        root["periodStart"] = snapshot.periodStart?.timeIntervalSince1970 as Any? ?? NSNull()
        root["periodEnd"] = snapshot.periodEnd?.timeIntervalSince1970 as Any? ?? NSNull()
        root["periodType"] = snapshot.periodType as Any? ?? NSNull()
        root["prepaidBalance"] = snapshot.prepaidBalance as Any? ?? NSNull()
        if let plan = snapshot.plan {
            root["plan"] = ["plan": plan.plan, "tier": plan.tier, "active": plan.active,
                            "renewsAt": plan.renewsAt?.timeIntervalSince1970 as Any? ?? NSNull(),
                            "cancelAtPeriodEnd": plan.cancelAtPeriodEnd]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct GrokCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let email: String?

    func isExpired(at now: Date = Date()) -> Bool { expiresAt.map { $0 <= now } ?? false }
}

/// 凭证过期时踢一脚 Grok CLI：`grok models` 会联网做登录检查，CLI 用 refresh_token 自行续期并写回 auth.json。
/// 只读、无副作用、不消耗额度、不改写任何文件（auth.json 由 CLI 自己维护）。
enum GrokAuthRefresher {
    static func refresh() throws {
        let binary = try locate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["models"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(40)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            throw GrokUsageError.loginExpired
        }
    }

    /// GUI 应用启动时 PATH 很精简，优先用绝对路径；找不到才回退到 PATH。
    private static func locate() throws -> String {
        let home = NSHomeDirectory()
        for path in [home + "/.local/bin/grok", home + "/.grok/bin/grok"] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "grok"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        which.waitUntilExit()
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !found.isEmpty else { throw GrokUsageError.loginExpired }
        return found
    }
}

/// Grok CLI 的登录凭证在 ~/.grok/auth.json，按 OIDC 发行方分条目；只读，不改写别人的登录状态。
enum GrokCredentialStore {
    static var fileURL: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.grok/auth.json") }

    static func load(now: Date = Date()) throws -> GrokCredentials {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GrokUsageError.credentialsNotFound
        }
        if let best = bestUsable(in: read(), now: now) { return best }
        // auth.json 存在但所有 token 都过期：让 CLI 用 refresh_token 续期，再读一次。
        try GrokAuthRefresher.refresh()
        if let best = bestUsable(in: read(), now: now) { return best }
        throw GrokUsageError.loginExpired
    }

    private static func read() -> Data? {
        FileManager.default.contents(atPath: fileURL.path)
    }

    private static func bestUsable(in data: Data?, now: Date) -> GrokCredentials? {
        let candidates = parse(data ?? Data())
        guard !candidates.isEmpty else { return nil }
        // 同机可能有多个账号/客户端条目：优先未过期的，其次到期时间最晚的那个。
        return candidates.filter { !$0.isExpired(at: now) }
            .max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) })
    }

    static func parse(_ data: Data) -> [GrokCredentials] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root.compactMap { key, value -> GrokCredentials? in
            guard let entry = value as? [String: Any],
                  let token = entry["key"] as? String, !token.isEmpty else { return nil }
            // 只取 auth.x.ai 发行方的条目，别的 OAuth 客户端条目身份不明。
            guard key.hasPrefix("https://auth.x.ai") || (entry["oidc_issuer"] as? String) == "https://auth.x.ai" else { return nil }
            let expiry = (entry["expires_at"] as? String).flatMap(GrokSnapshot.isoDate)
            return GrokCredentials(accessToken: token, expiresAt: expiry, email: entry["email"] as? String)
        }
    }
}

/// 只读查询 Grok 订阅额度，不发起任何推理请求，也不消耗额度。
struct GrokUsageClient: Sendable {
    let endpoint: URL
    let planEndpoint: URL
    let timeout: TimeInterval

    init(endpoint: URL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
         planEndpoint: URL = URL(string: "https://grok.com/rest/subscriptions")!,
         timeout: TimeInterval = 20) {
        self.endpoint = endpoint
        self.planEndpoint = planEndpoint
        self.timeout = max(1, timeout)
    }

    func fetch() throws -> GrokSnapshot {
        let credentials = try GrokCredentialStore.load()
        let (data, response) = try get(endpoint, token: credentials.accessToken)
        switch response.statusCode {
        case 200: break
        case 401, 403: throw GrokUsageError.unauthorized
        case 429: throw GrokUsageError.rateLimited(retryAfter: GrokSnapshot.retryAfter(from: response))
        case 500...599: throw GrokUsageError.serviceUnavailable
        default: throw GrokUsageError.invalidResponse
        }
        // 套餐信息只是补充展示，拿不到就当没有，不影响用量读数。
        let plan = (try? get(planEndpoint, token: credentials.accessToken))
            .flatMap { $0.1.statusCode == 200 ? GrokSnapshot.parsePlan(json: $0.0) : nil }
        return try GrokSnapshot.parse(json: data, plan: plan)
    }

    private func get(_ url: URL, token: String) throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(Data, HTTPURLResponse), Error> = .failure(GrokUsageError.networkUnavailable)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error as? URLError, error.code == .timedOut {
                outcome = .failure(GrokUsageError.timedOut)
                return
            }
            guard error == nil, let data, let http = response as? HTTPURLResponse else {
                outcome = .failure(GrokUsageError.networkUnavailable)
                return
            }
            outcome = .success((data, http))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw GrokUsageError.timedOut
        }
        switch outcome {
        case .failure(let error): throw error
        case .success(let pair): return pair
        }
    }
}
