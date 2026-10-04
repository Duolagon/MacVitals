import AppKit

/// Fixed-width rate fields keep both arrows and neighboring status items stationary.
enum StatusBarText {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    static var width: CGFloat { width(for: title(download: 999_000, upload: 999_000)) }
    static func width(for text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12
    }
    static func title(download: Double? = nil, upload: Double? = nil) -> String {
        let down = MetricsFormat.menuRate(download)
        let up = MetricsFormat.menuRate(upload)
        return "↓\(down) ↑\(up)"
    }
}
