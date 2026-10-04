import SwiftUI
import WidgetKit
import OSLog

private struct MetricsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var stale: Bool { snapshot.map { date.timeIntervalSince($0.sampledAt) >= 120 } ?? true }
}
private struct MetricsProvider: TimelineProvider {
    let kind: String
    private let logger = Logger(subsystem: "local.macvitals.monitor", category: "widgetProbe")
    func placeholder(in context: Context) -> MetricsEntry { .init(date: Date(), snapshot: .example) }
    func getSnapshot(in context: Context, completion: @escaping (MetricsEntry) -> Void) {
        completion(.init(date: Date(), snapshot: context.isPreview ? .example : WidgetSnapshot.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MetricsEntry>) -> Void) {
        let now = Date(), snapshot = WidgetSnapshot.read()
        logger.debug("PROBE timeline kind=\(kind, privacy: .public) callback=\(now.timeIntervalSince1970, privacy: .public) sampled=\(snapshot?.sampledAt.timeIntervalSince1970 ?? -1, privacy: .public)")
        var entries = [MetricsEntry(date: now, snapshot: snapshot)]
        if let sampledAt = snapshot?.sampledAt {
            let expires = sampledAt.addingTimeInterval(120)
            if expires > now { entries.append(.init(date: expires, snapshot: snapshot)) }
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
    }
}
private struct MetricsWidgetView: View {
    let entry: MetricsEntry
    let system: Bool
    @Environment(\.widgetFamily) private var family
    private var snapshot: WidgetSnapshot? { entry.snapshot }
    var body: some View {
        Group {
            if system && family != .systemSmall {
                TelemetryWidgetView(snapshot: snapshot, date: entry.date, expanded: family == .systemLarge)
            } else {
                compactView
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .containerBackground(for: .widget) {
            if system && family != .systemSmall { TelemetryWidgetBackground() }
            else {
                LinearGradient(colors: [Color(red: 0.12, green: 0.28, blue: 0.48), Color(red: 0.055, green: 0.12, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .widgetURL(URL(string: "macvitals://dashboard"))
    }
    private var compactView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(system ? "系统状态" : "网速", systemImage: system ? "cpu" : "network")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if family == .systemMedium {
                    Text(snapshot?.interface ?? "MacVitals").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let snapshot {
                if system {
                    HStack(spacing: 18) {
                        metric("CPU", value: percent(snapshot.cpu), color: .cyan)
                        metric("内存", value: percent(snapshot.memory), color: .purple)
                    }
                } else { network(snapshot) }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Circle().fill(entry.stale ? Color.orange : Color.green).frame(width: 4, height: 4)
                    Text(entry.stale ? "历史采样" : "最近采样")
                    Spacer(minLength: 0)
                    Text(snapshot.sampledAt, style: .time)
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 0)
                Text("尚未采样").font(.system(size: 19, weight: .medium))
                Text("点击打开 MacVitals").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
    private func percent(_ value: Double?) -> String { value.map { "\(Int(min(100, $0)))%" } ?? "—" }
    private func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return MetricsFormat.rate(value)
    }
    private func metric(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: system ? 25 : (family == .systemSmall ? 19 : 28), weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func network(_ snapshot: WidgetSnapshot) -> some View {
        Group {
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 6) {
                    metric("↓ 下载", value: rate(snapshot.download), color: .cyan)
                    metric("↑ 上传", value: rate(snapshot.upload), color: .orange)
                }
            } else {
                HStack(spacing: 18) {
                    metric("↓ 下载", value: rate(snapshot.download), color: .cyan)
                    metric("↑ 上传", value: rate(snapshot.upload), color: .orange)
                }
            }
        }
    }
}
private struct NetworkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacVitals.Network", provider: MetricsProvider(kind: "MacVitals.Network")) { MetricsWidgetView(entry: $0, system: false) }
            .configurationDisplayName("网速")
            .description("查看最近采样的下载和上传速度，以及采样时间。刷新由 macOS 调度。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
private struct SystemWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacVitals.System", provider: MetricsProvider(kind: "MacVitals.System")) { MetricsWidgetView(entry: $0, system: true) }
            .configurationDisplayName("系统状态")
            .description("CPU、内存环形仪表，下载与上传历史柱条，支持中号和大号。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
@main
struct MacVitalsWidgets: WidgetBundle {
    var body: some Widget { NetworkWidget(); SystemWidget() }
}
