import Foundation

@main
enum ClaudeWindowTests {
    static func main() {
        var checks = 0
        func expect(_ actual: @autoclosure () -> Bool, _ message: String) {
            guard actual() else { fatalError(message) }
            checks += 1
        }

        let json = """
        {"five_hour":{"utilization":26.0,"resets_at":"2026-10-27T12:10:00.331967+00:00"},
         "seven_day":{"utilization":29.0,"resets_at":"2026-10-30T17:00:00.331984+00:00"},
         "limits":[{"kind":"session","percent":26},{"kind":"weekly_all","percent":29}]}
        """.data(using: .utf8)!
        let snapshot = try! ClaudeSnapshot.parse(json: json)

        expect(snapshot.windows.count == 2, "Both periods are kept")
        expect(snapshot.fiveHour?.windowDurationMins == 300, "Five-hour window is 300 minutes")
        expect(snapshot.sevenDay?.windowDurationMins == 10_080, "Weekly window is 10080 minutes")
        expect(snapshot.fiveHour?.displayPercent == 74, "Utilization is converted to remaining percent")
        expect(snapshot.sevenDay?.displayPercent == 71, "Weekly remaining percent")
        expect(snapshot.fiveHour?.durationLabel == "5 小时", "Short label")
        expect(snapshot.sevenDay?.durationLabel == "本周", "Weekly label")
        expect(snapshot.fiveHour?.resetDate != nil && snapshot.sevenDay?.resetDate != nil, "Reset times parsed")

        // 统一口径：同一个 selection 必须挑到对应周期
        expect(snapshot.window(for: .shortTerm)?.windowDurationMins == 300, "Short selection picks the 5-hour window")
        expect(snapshot.window(for: .weekly)?.windowDurationMins == 10_080, "Weekly selection picks the weekly window")
        expect(snapshot.window(for: .limiting)?.displayPercent == 71, "Limiting still picks the tighter period")

        // 缺周期时退回另一个，不能显示空白
        let onlyShort = ClaudeSnapshot(fiveHour: snapshot.fiveHour, sevenDay: nil)
        expect(onlyShort.window(for: .weekly)?.windowDurationMins == 300, "Missing weekly falls back to the 5-hour window")
        let onlyWeekly = ClaudeSnapshot(fiveHour: nil, sevenDay: snapshot.sevenDay)
        expect(onlyWeekly.window(for: .shortTerm)?.windowDurationMins == 10_080, "Missing 5-hour falls back to weekly")

        // 非法/异常响应必须报错
        var threw = false
        do { _ = try ClaudeSnapshot.parse(json: "{}".data(using: .utf8)!) } catch { threw = true }
        expect(threw, "Empty payload is an error")

        print("ClaudeWindowTests: \(checks) checks passed")
    }
}
