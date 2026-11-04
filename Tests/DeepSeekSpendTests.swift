import Foundation

@main
enum DeepSeekSpendTests {
    static func main() {
        var checks = 0
        func expect(_ actual: @autoclosure () -> Bool, _ message: String) {
            guard actual() else { fatalError(message) }
            checks += 1
        }
        let china = TimeZone(identifier: "Asia/Shanghai")!
        // 2026-10-27 09:00 北京时间
        let morning = Date(timeIntervalSince1970: 1_793_062_800)
        let evening = morning.addingTimeInterval(6 * 3_600)
        let nextDay = morning.addingTimeInterval(24 * 3_600)

        func balance(_ total: Double, at date: Date) -> DeepSeekBalance {
            DeepSeekBalance(currency: "CNY", total: total, granted: 0, toppedUp: total,
                            isAvailable: true, fetchedAt: date)
        }

        // 当天首次采样：建立基准，花费为 0
        var state = DeepSeekSpendTracker.update(.empty(), with: balance(39.38, at: morning), now: morning, timeZone: china)
        expect(state.day == "2026-10-27", "Day key uses local calendar")
        expect(abs(state.dayStartBalance - 39.38) < 0.0001, "First sample sets the baseline")
        expect(state.spentToday == 0, "First sample spends nothing")

        // 余额下降：按差额计花费
        state = DeepSeekSpendTracker.update(state, with: balance(38.15, at: evening), now: evening, timeZone: china)
        expect(abs(state.spentToday - 1.23) < 0.0001, "Spend is the balance difference")
        expect(state.toppedUpToday == 0, "No top-up recorded")

        // 充值：基准随之上移，不计入花费
        state = DeepSeekSpendTracker.update(state, with: balance(88.15, at: evening.addingTimeInterval(60)), now: evening, timeZone: china)
        expect(abs(state.toppedUpToday - 50) < 0.0001, "Top-up is detected")
        expect(abs(state.spentToday - 1.23) < 0.0001, "Top-up does not count as spend")

        // 充值后继续消耗
        state = DeepSeekSpendTracker.update(state, with: balance(87.65, at: evening.addingTimeInterval(600)), now: evening, timeZone: china)
        expect(abs(state.spentToday - 1.73) < 0.0001, "Spend keeps accumulating after a top-up")

        // 跨天：重新起算
        state = DeepSeekSpendTracker.update(state, with: balance(87.0, at: nextDay), now: nextDay, timeZone: china)
        expect(state.day == "2026-10-28", "New local day resets the counter")
        expect(state.spentToday == 0 && state.toppedUpToday == 0, "New day starts clean")
        expect(abs(state.dayStartBalance - 87.0) < 0.0001, "New day baseline is today's first reading")

        // 余额不变：花费不倒退
        state = DeepSeekSpendTracker.update(state, with: balance(87.0, at: nextDay.addingTimeInterval(600)), now: nextDay, timeZone: china)
        expect(state.spentToday == 0, "Unchanged balance keeps zero spend")

        // 充值 + 同间隔消费：余额只给净值 +95，这 5 元无法拆分（已知限制，靠缩短采样间隔缓解）
        var sameInterval = DeepSeekSpendTracker.update(.empty(), with: balance(50, at: morning), now: morning, timeZone: china)
        sameInterval = DeepSeekSpendTracker.update(sameInterval, with: balance(145, at: evening), now: evening, timeZone: china)
        expect(abs(sameInterval.toppedUpToday - 95) < 0.0001, "Net rise is treated as a top-up")
        expect(sameInterval.spentToday == 0, "Same-interval spend is folded into the top-up")
        // 充值之后的消费必须正常计入
        sameInterval = DeepSeekSpendTracker.update(sameInterval, with: balance(143, at: evening.addingTimeInterval(180)),
                                                   now: evening, timeZone: china)
        expect(abs(sameInterval.spentToday - 2) < 0.0001, "Spend after the top-up is counted")

        // 校准：用官网今日消费倒推当天基准，之后继续累加
        var calibrated = DeepSeekSpendTracker.calibrate(.empty(), currentBalance: 39.12, spentToday: 6.96,
                                                        now: evening, timeZone: china)
        expect(abs(calibrated.dayStartBalance - 46.08) < 0.0001, "Calibration back-computes the day baseline")
        expect(abs(calibrated.spentToday - 6.96) < 0.0001, "Calibration keeps the reported spend")
        expect(calibrated.day == "2026-10-27", "Calibration writes today's key")
        calibrated = DeepSeekSpendTracker.update(calibrated, with: balance(38.62, at: evening.addingTimeInterval(600)),
                                                 now: evening, timeZone: china)
        expect(abs(calibrated.spentToday - 7.46) < 0.0001, "Spend keeps accumulating after calibration")

        // 解析官方响应
        let json = """
        {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"39.59","granted_balance":"0.00","topped_up_balance":"39.59"}]}
        """.data(using: .utf8)!
        let parsed = try! DeepSeekBalance.parse(json: json, fetchedAt: morning)
        expect(abs(parsed.total - 39.59) < 0.0001, "Parses total balance")
        expect(parsed.granted == 0 && parsed.toppedUp == 39.59, "Parses balance breakdown")
        expect(parsed.compactText == "¥39.6", "Compact menu bar text")
        expect(parsed.detailText == "¥39.59", "Detail keeps cents")

        // 异常响应必须报错，不能当成 0 余额
        let bad = "{\"balance_infos\":[]}".data(using: .utf8)!
        var threw = false
        do { _ = try DeepSeekBalance.parse(json: bad) } catch { threw = true }
        expect(threw, "Empty balance list is an error, not zero")

        print("DeepSeekSpendTests: \(checks) checks passed")
    }
}
