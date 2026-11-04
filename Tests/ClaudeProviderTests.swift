import Foundation

@main enum ClaudeProviderTests {
    static func main() throws {
        var count = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        func parse(_ data: String) throws -> BAIBalance { try BAIBalance.parse(Data(data.utf8)) }
        let zero = try parse(#"{"success":true,"data":{"api_key_type":"personal","personal_balance":0,"active_status":"active"}}"#)
        expect(zero.available == 0 && zero.text == "0 Credits", "Zero is real zero")
        expect(zero.active == "active", "Active status")
        let missing = try parse(#"{"success":true,"data":{"api_key_type":"personal"}}"#)
        expect(missing.available == nil && missing.text == "未知 Credits", "Missing is not zero")
        expect(missing.compactText == "--", "Missing compact text is unknown, not zero")
        // K 缩写：短、可读，且不改变真实值
        func compact(_ value: Int64) -> String {
            BAIBalance(keyType: "personal", active: nil, personal: value, team: nil, role: nil, quotaType: nil,
                       quotaLimit: nil, quotaUsed: nil, resetAt: nil, serverTimestamp: nil, fetchedAt: Date()).compactText
        }
        expect(compact(0) == "0", "Zero stays zero")
        expect(compact(999) == "999", "Below one thousand keeps exact digits")
        expect(compact(1_000) == "1.0K", "Exactly one thousand uses K")
        expect(compact(12_345) == "12.3K", "Thousands keep one decimal below 100K")
        expect(compact(99_999) == "100.0K", "Rounding boundary still uses K")
        expect(compact(123_456) == "123K", "Above 100K drops decimals")
        expect(compact(999_999) == "1000K", "Just below a million is still K")
        // 百万以上以 M 为主单位
        expect(compact(1_000_000) == "1.00M", "Exactly one million uses M")
        expect(compact(4_840_236) == "4.84M", "Real balance uses M with two decimals")
        expect(compact(12_345_678) == "12.35M", "Tens of millions keep two decimals")
        expect(compact(150_000_000) == "150.0M", "Hundreds of millions keep one decimal")
        expect(compact(2_000_000_000) == "2000M", "Billions drop decimals")
        expect(compact(12_345).count <= 8, "Compact text stays short")
        expect(zero.compactText == "0", "Zero compact is exact")
        for raw in [#"{"success":false,"message":"secret"}"#, #"{"data":{"api_key_type":"personal"}}"#, #"{"success":1,"data":{"api_key_type":"personal"}}"#, #"{"success":true,"data":{"api_key_type":"unknown"}}"#] {
            var failed = false
            do { _ = try parse(raw) } catch { failed = true; expect(!error.localizedDescription.contains("secret"), "Sanitized failure") }
            expect(failed, "Reject unsuccessful or malformed response")
        }
        let admin = try parse(#"{"success":true,"data":{"api_key_type":"team","team":{"team_role":"admin","team_balance":50000,"quota_limit_type":"unlimited"}}}"#)
        expect(admin.available == 50000, "Admin sees team balance")
        let limited = try parse(#"{"success":true,"data":{"api_key_type":"team","team":{"team_role":"member","team_balance":999999,"quota_limit_type":"limited","member_quota_limit":1000,"member_quota_used":234,"quota_reset_at":"2026-11-01"}}}"#)
        expect(limited.available == 766 && limited.team == nil, "Member uses only own remaining quota")
        expect(limited.resetAt == "2026-11-01", "Optional reset")
        let unlimited = try parse(#"{"success":true,"data":{"api_key_type":"team","team":{"team_role":"member","quota_limit_type":"unlimited"}}}"#)
        expect(unlimited.available == nil && unlimited.details.contains { $0.contains("无限制") }, "Unlimited is not zero or team balance")
        let partial = try parse(#"{"success":true,"data":{"api_key_type":"team","team":{"team_role":"member","quota_limit_type":"limited","member_quota_limit":1000}}}"#)
        expect(partial.available == nil, "Partial quota unknown")
        for bad in ["true", "-1", "1.25", "\"100\""] {
            let value = try parse("{\"success\":true,\"data\":{\"api_key_type\":\"personal\",\"personal_balance\":\(bad)}}")
            expect(value.available == nil, "Credits must be nonnegative integer")
        }
        expect(zero.isStale(now: zero.fetchedAt.addingTimeInterval(901)), "Stale after 15 min")
        expect(!zero.isStale(now: zero.fetchedAt.addingTimeInterval(899)), "Fresh before 15 min")
        expect(try JSONDecoder().decode(BAIBalance.self, from: JSONEncoder().encode(limited)) == limited, "Cache round trip")
        let valid = ["ANTHROPIC_BASE_URL":"https://api.b.ai/anthropic", "ANTHROPIC_API_KEY":"test-only"]
        expect(BAIKeyStore.configuredKey(valid) == "test-only", "Host bound discovery")
        for base in ["https://api.anthropic.com", "https://api.b.ai.evil.test", "http://api.b.ai", "https://api.b.ai@evil.test"] {
            expect(BAIKeyStore.configuredKey(["ANTHROPIC_BASE_URL":base, "ANTHROPIC_API_KEY":"test-only"]) == nil, "Other host forbidden")
        }
        expect(BAIKeyStore.configuredKey(["ANTHROPIC_API_KEY":"test-only"]) == nil, "Unbound key forbidden")
        var gate = ProviderRequestGate(); let old = gate.generation; gate.invalidate(); gate.invalidate()
        expect(!gate.accepts(old) && gate.accepts(gate.generation), "A-B-A race")
        expect(BAICache.url != ClaudeUsageCache.fileURL, "Provider caches isolated")
        print("ClaudeProviderTests: \(count) checks passed")
    }
}
