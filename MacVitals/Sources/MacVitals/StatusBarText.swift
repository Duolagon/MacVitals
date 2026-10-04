import AppKit

/// Reserve three digits and the percent sign for each metric.
/// Monospaced spaces keep labels and trailing digits in the same positions.
enum StatusBarText {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    static var width: CGFloat {
        ceil(("CPU 100%  MEM 100%" as NSString).size(withAttributes: [.font: font]).width) + 16
    }
    static func title(cpu: Double?, memory: Double?) -> String {
        "CPU \(field(cpu, rounding: .toNearestOrAwayFromZero))  MEM \(field(memory, rounding: .towardZero))"
    }
    private static func field(_ value: Double?, rounding: FloatingPointRoundingRule) -> String {
        guard let value, value.isFinite else { return "   —" }
        let percent = Int(min(100, max(0, value)).rounded(rounding))
        return String(format: "%3d%%", percent)
    }
}
