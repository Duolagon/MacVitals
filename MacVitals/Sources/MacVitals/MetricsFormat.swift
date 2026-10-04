import Foundation

enum MetricsFormat {
    static func bytes(_ value: UInt64) -> String {
        guard value > 0 else { return "0 B" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))))
    }
    /// Eight monospaced characters, using decimal byte-rate units.
    static func compactRate(_ value: Double?) -> String {
        guard var value, value.isFinite, value >= 0 else { return "    —   " }
        let units = ["B", "K", "M", "G", "T", "P", "E"]
        var index = 0
        while value >= 999.95 && index < units.count-1 { value /= 1000; index += 1 }
        guard value < 999.95 else { return "   >1E/s" }
        return String(format: "%5.1f%@/s", value, units[index])
    }
    /// Four characters for the menu bar; precise rates remain in the panel.
    static func menuRate(_ value: Double?) -> String {
        guard var value, value.isFinite, value >= 0 else { return "  — " }
        let units = ["B", "K", "M", "G", "T", "P", "E"]
        var index = 0
        while value >= 999.5 && index < units.count - 1 { value /= 1000; index += 1 }
        guard value < 999.5 else { return " >1E" }
        return String(format: "%3.0f%@", value, units[index])
    }
    static func rate(_ value: Double?) -> String {
        guard let value else { return "采样中" }
        guard value.isFinite, value >= 0 else { return "不可用" }
        let compact = compactRate(value)
        if compact.contains(">") { return ">1 EB/s" }
        guard let unit = compact.dropLast(2).last else { return "不可用" }
        let units: [Character: String] = ["B":"B", "K":"KB", "M":"MB", "G":"GB", "T":"TB", "P":"PB", "E":"EB"]
        return "\(compact.prefix(5).trimmingCharacters(in: .whitespaces)) \(units[unit] ?? "B")/s"
    }
}
