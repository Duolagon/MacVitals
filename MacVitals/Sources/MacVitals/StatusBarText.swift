import AppKit

/// Reserve three digits and the percent sign for each metric.
/// Monospaced spaces keep labels and trailing digits in the same positions.
enum StatusBarText {
    static let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
    static var width: CGFloat {
        ceil((title(cpu: 100, memory: 100, download: 999_900, upload: 999_900) as NSString).size(withAttributes: [.font: font]).width) + 12
    }
    static func title(cpu: Double?, memory: Double?, download: Double? = nil, upload: Double? = nil) -> String {
        "CPU\(field(cpu, rounding: .toNearestOrAwayFromZero)) MEM\(field(memory, rounding: .towardZero)) ↓\(MetricsFormat.menuRate(download)) ↑\(MetricsFormat.menuRate(upload))"
    }
    private static func field(_ value: Double?, rounding: FloatingPointRoundingRule) -> String {
        guard let value, value.isFinite else { return "   —" }
        let percent = Int(min(100, max(0, value)).rounded(rounding))
        return String(format: "%3d%%", percent)
    }
}
