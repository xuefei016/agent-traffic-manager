import AppKit

/// 菜单栏标题：各服务剩余额度并列，再接原有倒计时／提醒尾段。
enum ProviderBadge {
    /// 一个服务的显示片段；value 已是 "68%" / "--" 这类最终文本。
    struct Segment {
        let label: String
        let value: String
        let stale: Bool
    }

    static func title(segments: [Segment], countdown: String, alert: TiboAlert?, fallbackIndicator: String = "",
                      imminent: Bool = false, dark: Bool? = nil, readIndicator: String = "") -> NSAttributedString {
        let strong: NSColor = dark.map { $0 ? .white : .black } ?? .labelColor
        let dim: NSColor = dark.map {
            $0 ? NSColor(calibratedWhite: 0.72, alpha: 1) : NSColor(calibratedWhite: 0.40, alpha: 1)
        } ?? .secondaryLabelColor
        let result = NSMutableAttributedString()

        for segment in segments {
            if result.length > 0 {
                result.append(NSAttributedString(string: "  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular), .foregroundColor: dim
                ]))
            }
            if !segment.label.isEmpty {
                result.append(NSAttributedString(string: segment.label, attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: dim
                ]))
            }
            result.append(NSAttributedString(string: (segment.label.isEmpty ? "" : " ") + segment.value, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: segment.stale ? dim : strong
            ]))
        }

        let tail = AlertAppearance.title(countdown: countdown, alert: alert, fallbackIndicator: fallbackIndicator,
                                         imminent: imminent, dark: dark, readIndicator: readIndicator)
        guard tail.length > 0 else { return result }
        if result.length > 0 {
            result.append(NSAttributedString(string: "  ", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim
            ]))
        }
        result.append(tail)
        return result
    }
}
