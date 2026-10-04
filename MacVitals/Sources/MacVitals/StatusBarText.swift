import AppKit

/// Reserve three digits and the percent sign for each metric.
/// Monospaced spaces keep labels and trailing digits in the same positions.
enum StatusBarText {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    // Two rows keep all four readings within a compact menu bar item.
    static let width: CGFloat = 154
    static func image(cpu: Double?, memory: Double?, download: Double?, upload: Double?) -> NSImage {
        let image = NSImage(size: NSSize(width: width - 12, height: 22))
        image.lockFocus()
        let smallFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        func draw(_ text: String, x: CGFloat, y: CGFloat, color: NSColor) {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: smallFont, .foregroundColor: color])
        }
        draw("CPU" + field(cpu, rounding: .toNearestOrAwayFromZero), x: 0, y: 11, color: .labelColor)
        draw("MEM" + field(memory, rounding: .towardZero), x: 75, y: 11, color: .labelColor)
        draw("↓" + MetricsFormat.compactRate(download), x: 0, y: 0, color: .systemBlue)
        draw("↑" + MetricsFormat.compactRate(upload), x: 75, y: 0, color: .systemOrange)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
    static func title(cpu: Double?, memory: Double?, download: Double? = nil, upload: Double? = nil) -> String {
        "CPU \(field(cpu, rounding: .toNearestOrAwayFromZero))  MEM \(field(memory, rounding: .towardZero)) ↓ \(MetricsFormat.compactRate(download)) ↑ \(MetricsFormat.compactRate(upload))"
    }
    private static func field(_ value: Double?, rounding: FloatingPointRoundingRule) -> String {
        guard let value, value.isFinite else { return "   —" }
        let percent = Int(min(100, max(0, value)).rounded(rounding))
        return String(format: "%3d%%", percent)
    }
}
