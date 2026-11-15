import Foundation

@main
enum GrokUsageTests {
    static func main() {
        var checks = 0
        func expect(_ actual: @autoclosure () -> Bool, _ message: String) {
            guard actual() else { fatalError(message) }
            checks += 1
        }

        // 真实响应结构：用量在 config 里，周期是每周，产品按同一额度归因。
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-11-12T00:48:31.616+00:00","end":"2026-11-19T00:48:31.616+00:00"},
         "creditUsagePercent":76.0,
         "productUsage":[{"product":"GrokBot","usagePercent":52.0},{"product":"GrokBuild","usagePercent":22.0},{"product":"Cursor","usagePercent":2.0}],
         "isUnifiedBillingUser":true,"prepaidBalance":{"val":0},
         "billingPeriodStart":"2026-11-12T00:48:31.616+00:00","billingPeriodEnd":"2026-11-19T00:48:31.616+00:00"}}
        """.data(using: .utf8)!
        let snapshot = try! GrokSnapshot.parse(json: json)
        expect(snapshot.usedPercent == 76, "creditUsagePercent parsed")
        expect(snapshot.window?.displayPercent == 24, "Used percent converts to remaining percent")
        expect(snapshot.window?.windowDurationMins == 10_080, "Weekly period is 10080 minutes")
        expect(snapshot.window?.durationLabel == "本周", "Weekly label")
        expect(snapshot.periodLabel == "本周", "Period label follows the server period")
        expect(snapshot.window?.resetDate != nil, "Reset time parsed from period end")
        expect(snapshot.isUnifiedBilling, "Unified billing flag kept")
        expect(snapshot.products.count == 3, "Product breakdown kept")
        expect(snapshot.productSummary == "GrokBot 52% · GrokBuild 22% · Cursor 2%", "Product summary text")
        expect(snapshot.prepaidBalance == 0, "Prepaid balance read from val")

        // 缺 config 外壳时字段也可能直接铺在顶层；不能因为包装不同就当失败。
        let flat = #"{"creditUsagePercent":12.5,"billingPeriodEnd":"2026-12-05T00:48:22Z"}"#.data(using: .utf8)!
        let flatSnapshot = try! GrokSnapshot.parse(json: flat)
        expect(flatSnapshot.usedPercent == 12.5, "Flat payload accepted")
        expect(flatSnapshot.window?.displayPercent == 87, "Flat payload remaining percent")
        expect(flatSnapshot.periodMinutes == nil, "No start/end means unknown period length, not zero")

        // 未知不是 0：没有百分比也没有周期结束时间就是坏响应。
        var threw = false
        do { _ = try GrokSnapshot.parse(json: "{}".data(using: .utf8)!) } catch { threw = true }
        expect(threw, "Empty payload is an error")

        // 套餐：同一账号同时挂着 SuperGrok 与 X Premium+，两条都要保留。
        let planJSON = """
        {"subscriptions":[
          {"plan":"supergrok","tier":"SUBSCRIPTION_TIER_GROK_PRO","status":"SUBSCRIPTION_STATUS_ACTIVE",
           "billingPeriodEnd":"2026-12-05T00:48:22Z","cancelAtPeriodEnd":false,"billingInterval":"BILLING_INTERVAL_MONTHLY"},
          {"tier":"SUBSCRIPTION_TIER_X_PREMIUM_PLUS","status":"SUBSCRIPTION_STATUS_ACTIVE"}],
         "dominantPlan":{"plan":"supergrok"}}
        """.data(using: .utf8)!
        let plans = GrokSnapshot.parsePlans(json: planJSON)
        expect(plans.count == 2, "Both subscriptions are kept")
        expect(plans.first?.plan == "supergrok", "Dominant plan listed first")
        expect(plans.first?.displayName == "SuperGrok", "GROK_PRO displays as SuperGrok")
        expect(plans.first?.interval == "月付", "Monthly interval is readable")
        expect(plans.first?.renewsAt != nil, "Renewal date parsed")
        expect(plans.last?.displayName == "X Premium+", "X Premium+ keeps its own name, not SuperGrok")
        let premiumOnly = GrokSnapshot.parsePlans(json: #"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_X_PREMIUM_PLUS","status":"SUBSCRIPTION_STATUS_ACTIVE"}],"dominantPlan":{"plan":"supergrok"}}"#.data(using: .utf8)!)
        expect(premiumOnly.count == 1 && premiumOnly.first?.displayName == "X Premium+", "Missing dominant entry does not drop X Premium+")
        // 显示口径：有 X Premium+ 时以它命名，SuperGrok 只是额度归属
        let snapshotWithPlans = try! GrokSnapshot.parse(json: json, plans: plans)
        expect(snapshotWithPlans.planLabel == "X Premium+", "Account label follows X Premium+ when present")
        let superOnly = try! GrokSnapshot.parse(json: json, plans: [plans.first!])
        expect(superOnly.planLabel == "SuperGrok", "SuperGrok-only account keeps SuperGrok label")

        // 凭证：只认 auth.x.ai 条目，过期就报过期，多个账号取最晚到期的可用条目。
        // 凭证时间必须相对当前时刻生成，写死日期会随日历过期，让测试某天突然失败。
        let token = "header.payload.signature"
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let freshExpiry = fmt.string(from: Date().addingTimeInterval(6 * 3_600))
        let staleExpiry = fmt.string(from: Date().addingTimeInterval(-3_600))
        let creds = """
        {"https://auth.x.ai::client-a":{"key":"\(token)","email":"a@example.com","expires_at":"\(freshExpiry)","oidc_issuer":"https://auth.x.ai"},
         "https://other.example::client-b":{"key":"other","expires_at":"\(freshExpiry)"}}
        """
        let parsed = GrokCredentialStore.parse(creds.data(using: .utf8)!)
        expect(parsed.count == 1, "Only auth.x.ai entries are used")
        expect(parsed.first?.accessToken == token, "Token read without echoing it")
        expect(parsed.first?.isExpired(at: Date()) == false, "Fresh token is usable")
        let expiredCreds = #"{"https://auth.x.ai::client-x":{"key":"old","expires_at":"2020-01-01T00:00:00Z","oidc_issuer":"https://auth.x.ai"}}"#.data(using: .utf8)!
        expect(GrokCredentialStore.parse(expiredCreds).first?.isExpired(at: Date()) == true, "Expiry is detected")
        let twoAccounts = """
        {"https://auth.x.ai::client-old":{"key":"old","expires_at":"\(staleExpiry)","oidc_issuer":"https://auth.x.ai"},
         "https://auth.x.ai::client-new":{"key":"new","expires_at":"\(freshExpiry)","oidc_issuer":"https://auth.x.ai"}}
        """
        let best = GrokCredentialStore.parse(twoAccounts.data(using: .utf8)!)
            .filter { !$0.isExpired(at: Date()) }
            .max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
        expect(best?.accessToken == "new", "Latest usable token wins")

        print("GrokUsageTests: \(checks) checks passed")
    }
}