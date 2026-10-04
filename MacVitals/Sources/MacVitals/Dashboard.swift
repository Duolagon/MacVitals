import SwiftUI
import Charts
import Darwin

struct Reading: Identifiable {
    let id = UUID()
    let time: Date
    let snapshot: Snapshot
}
final class DashboardModel: ObservableObject {
    @Published var latest = Snapshot()
    @Published var readings: [Reading] = []
    @Published var now = Date()
    @Published var details: [DetailSection] = []
    @Published var detailsUpdated = Date()
    func record(_ snapshot: Snapshot) {
        let time = Date()
        latest = snapshot
        now = time
        readings.removeAll { $0.time < time.addingTimeInterval(-120) }
        readings.append(Reading(time: time, snapshot: snapshot))
    }
}

enum MonitorStyle {
    static var panelHeight: CGFloat { min(820, max(480, (NSScreen.main?.visibleFrame.height ?? 850) - 70)) }
    static let background = Color(red: 0.055, green: 0.065, blue: 0.085)
    static let card = Color(red: 0.095, green: 0.108, blue: 0.135)
    static let border = Color.white.opacity(0.075)
    static let blue = Color(red: 0.38, green: 0.76, blue: 1)
    static let purple = Color(red: 0.74, green: 0.62, blue: 1)
    static let mint = Color(red: 0.38, green: 0.86, blue: 0.72)
    static let amber = Color(red: 1, green: 0.73, blue: 0.38)
}
struct MonitorCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(14)
            .background(MonitorStyle.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(MonitorStyle.border, lineWidth: 1))
    }
}

enum InstrumentKind { case cpu, memory, fan, temperature }
struct MetricInstrument: View {
    let kind: InstrumentKind
    let value: Double?
    let display: String?
    let unit: String
    let color: Color
    let maximum: Double
    private var fraction: Double { min(1, max(0, (value ?? 0) / maximum)) }
    var body: some View {
        ZStack {
            Canvas { context, size in draw(context: &context, size: size) }
            readout
        }.frame(height: 84)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(display ?? "不可用") \(unit)")
    }
    private func draw(context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        if kind == .cpu {
            let radius = min(size.height / 2 - 4, 41)
            for index in 0..<40 {
                let lit = value != nil && Double(index) / 40 < fraction
                let angle = Double(index) / 40 * 2 * Double.pi - Double.pi / 2
                var path = Path()
                path.move(to: CGPoint(x: center.x + CGFloat(Darwin.cos(angle)) * (radius - 5), y: center.y + CGFloat(Darwin.sin(angle)) * (radius - 5)))
                path.addLine(to: CGPoint(x: center.x + CGFloat(Darwin.cos(angle)) * radius, y: center.y + CGFloat(Darwin.sin(angle)) * radius))
                context.stroke(path, with: .color(lit ? color : .white.opacity(0.075)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            let inner = CGRect(x: center.x - radius + 10, y: center.y - radius + 10, width: (radius - 10) * 2, height: (radius - 10) * 2)
            context.stroke(Path(ellipseIn: inner), with: .color(color.opacity(0.12)), lineWidth: 0.5)
        } else if kind == .memory {
            let columns = 20
            let gap: CGFloat = 3
            let width = (size.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            for index in 0..<columns {
                let lit = value != nil && Double(index) / Double(columns) < fraction
                for row in 0..<3 {
                    let rect = CGRect(x: CGFloat(index) * (width + gap), y: 56 + CGFloat(row) * 8, width: width, height: 5)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(lit ? color.opacity(1 - Double(row) * 0.18) : .white.opacity(0.065)))
                }
            }
        } else if kind == .fan {
            let center = CGPoint(x: size.width / 2, y: 58)
            let radius: CGFloat = 47
            for index in 0..<31 {
                let angle = Double.pi + Double(index) / 30 * Double.pi
                let lit = value != nil && fraction > 0 && Double(index) / 30 <= fraction
                var tick = Path()
                tick.move(to: CGPoint(x: center.x + CGFloat(Darwin.cos(angle)) * (radius - 5), y: center.y + CGFloat(Darwin.sin(angle)) * (radius - 5)))
                tick.addLine(to: CGPoint(x: center.x + CGFloat(Darwin.cos(angle)) * radius, y: center.y + CGFloat(Darwin.sin(angle)) * radius))
                context.stroke(tick, with: .color(lit ? color : .white.opacity(0.075)), style: StrokeStyle(lineWidth: index % 5 == 0 ? 2.5 : 1.5, lineCap: .round))
            }
            if value != nil {
                let angle = Double.pi + fraction * Double.pi
                var needle = Path()
                needle.move(to: center)
                needle.addLine(to: CGPoint(x: center.x + CGFloat(Darwin.cos(angle)) * 31, y: center.y + CGFloat(Darwin.sin(angle)) * 31))
                context.stroke(needle, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(color))
            }
        } else {
            for index in 0..<20 {
                let rect = CGRect(x: 4, y: 78 - CGFloat(index) * 3.7, width: 13, height: 2.5)
                let lit = value != nil && Double(index) / 20 < fraction
                let tint = index < 10 ? MonitorStyle.blue : (index < 16 ? color : Color(red: 1, green: 0.4, blue: 0.4))
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(lit ? tint : .white.opacity(0.075)))
            }
            for index in 0...4 {
                let y = 78 - CGFloat(index) * 18.5
                var tick = Path()
                tick.move(to: CGPoint(x: 22, y: y)); tick.addLine(to: CGPoint(x: 28, y: y))
                context.stroke(tick, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            }
        }

    }
    @ViewBuilder private var readout: some View {
        if kind == .cpu {
            VStack(spacing: 0) {
                Text(display ?? "—").font(.system(size: 25, weight: .medium, design: .monospaced)).monospacedDigit()
                Text("LOAD · %").font(.system(size: 7, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
        } else if kind == .memory {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(display ?? "—").font(.system(size: 27, weight: .medium, design: .monospaced)).monospacedDigit()
                    Text("%").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("ALLOCATED").font(.system(size: 8, design: .monospaced)).tracking(1).foregroundStyle(color.opacity(0.8))
                Spacer()
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else if kind == .fan {
            VStack(spacing: 1) {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "fanblades").foregroundStyle(color).font(.system(size: 9))
                    Text(display ?? "—").font(.system(size: 19, weight: .medium, design: .monospaced)).monospacedDigit()
                    Text("RPM").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(display ?? "—").font(.system(size: 26, weight: .medium, design: .monospaced)).monospacedDigit()
                    Text("°C").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("THERMAL").font(.system(size: 8, design: .monospaced)).tracking(1).foregroundStyle(color.opacity(0.8))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 42)
        }
    }
}
struct HistoryRaster: View {
    let points: [Reading]
    let now: Date
    let seconds: Int
    let ceiling: Double
    let metric: (Snapshot) -> Double?
    let color: Color
    var body: some View {
        Canvas { context, size in
            let count = 32
            let gap: CGFloat = 2
            let width = (size.width - CGFloat(count - 1) * gap) / CGFloat(count)
            let start = now.addingTimeInterval(-Double(seconds))
            for index in 0..<count {
                let lower = start.addingTimeInterval(Double(index) * Double(seconds) / Double(count))
                let upper = lower.addingTimeInterval(Double(seconds) / Double(count))
                let values = points.filter { $0.time >= lower && ($0.time < upper || (index == count - 1 && $0.time <= upper)) }.compactMap { metric($0.snapshot) }
                let mean = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(mean.map { color.opacity(0.16 + min(1, max(0, $0 / ceiling)) * 0.84) } ?? .white.opacity(0.035)))
            }
        }.frame(height: 5).accessibilityLabel("最近\(seconds)秒历史强度；空格表示尚无采样")
    }
}

struct ResourceInstrument: View {
    let battery: Bool
    let fraction: Double?
    let value: String
    let subtitle: String
    let charging: Bool
    private var color: Color { battery ? MonitorStyle.mint : MonitorStyle.purple }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: battery ? "battery.75percent" : "internaldrive").foregroundStyle(color)
                Text(battery ? "电池" : "磁盘").foregroundStyle(.secondary)
                Spacer()
                if charging { Image(systemName: "bolt.fill").foregroundStyle(color) }
            }.font(.system(size: 11, weight: .medium))
            Text(value).font(.system(size: battery ? 25 : 20, weight: .medium, design: .monospaced))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            Canvas { context, size in
                let fraction = min(1, max(0, fraction ?? 0))
                if battery {
                    let body = CGRect(x: 0.5, y: 2, width: size.width - 7, height: 26)
                    context.stroke(Path(roundedRect: body, cornerRadius: 4), with: .color(color.opacity(0.3)), lineWidth: 1)
                    context.fill(Path(roundedRect: CGRect(x: size.width - 5, y: 10, width: 4, height: 10), cornerRadius: 1), with: .color(color.opacity(0.4)))
                    let width = (body.width - 12 - 19 * 2) / 20
                    for index in 0..<20 {
                        let lit = self.fraction != nil && Double(index) / 20 < fraction
                        let rect = CGRect(x: 6 + CGFloat(index) * (width + 2), y: 7, width: width, height: 16)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(lit ? color : .white.opacity(0.065)))
                    }
                } else {
                    let width = (size.width - 15 * 3) / 16
                    for row in 0..<3 {
                        for column in 0..<16 {
                            let index = row * 16 + column
                            let lit = self.fraction != nil && Double(index) / 48 < fraction
                            let rect = CGRect(x: CGFloat(column) * (width + 3), y: CGFloat(row) * 9, width: width, height: 6)
                            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(lit ? color.opacity(1 - Double(row) * 0.1) : .white.opacity(0.065)))
                        }
                    }
                }
            }.frame(height: 30)
                .accessibilityLabel(battery ? "电量分段刻度" : "磁盘占用分段刻度")
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(subtitle)
        }.frame(maxWidth: .infinity, alignment: .leading).modifier(MonitorCard())
    }
}
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    let settings: () -> Void
    let showDetails: () -> Void
    var exportMode = false
    @State private var seconds = 120
    init(model: DashboardModel, settings: @escaping () -> Void, showDetails: @escaping () -> Void, exportMode: Bool = false) {
        self.model = model; self.settings = settings; self.showDetails = showDetails
        self.exportMode = exportMode
        _seconds = State(initialValue: exportMode ? 30 : 120)
    }
    private var points: [Reading] { model.readings.filter { $0.time >= model.now.addingTimeInterval(-Double(seconds)) } }
    private var domain: ClosedRange<Date> { model.now.addingTimeInterval(-Double(seconds))...model.now }
    var body: some View {
        VStack(spacing: 0) {
            header
            contentContainer
            footer
        }
        .frame(width: 440, height: exportMode ? nil : MonitorStyle.panelHeight)
        .background(MonitorStyle.background)
        .preferredColorScheme(.dark)
    }
    @ViewBuilder private var contentContainer: some View {
        if exportMode { content } else { ScrollView { content } }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("遥测仪表").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("曲线时间范围", selection: $seconds) {
                    Text("30 秒").tag(30)
                    Text("1 分钟").tag(60)
                    Text("2 分钟").tag(120)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 188).controlSize(.small)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                metricCard("CPU", icon: "cpu", value: model.latest.cpu.map { String(format: "%.0f", $0) }, unit: "%", detail: "全部核心", color: MonitorStyle.blue, kind: .cpu, ceiling: 100, metric: { $0.cpu })
                metricCard("内存", icon: "memorychip", value: model.latest.memoryPercent.map { String(Int($0)) }, unit: "%", detail: model.latest.memory, color: MonitorStyle.purple, kind: .memory, ceiling: 100, metric: { $0.memoryPercent })
                metricCard("风扇", icon: "fanblades", value: model.latest.fanRPM.map { String(format: "%.0f", $0) }, unit: "RPM", detail: "最高转速", color: MonitorStyle.mint, kind: .fan, ceiling: max(6000, (points.compactMap { $0.snapshot.fanRPM }.max() ?? 0) * 1.1), metric: { $0.fanRPM })
                metricCard("温度", icon: "thermometer.medium", value: model.latest.temperatureC.map { String(format: "%.1f", $0) }, unit: "°C", detail: "CPU 区域传感器", color: MonitorStyle.amber, kind: .temperature, ceiling: max(100, (points.compactMap { $0.snapshot.temperatureC }.max() ?? 0) * 1.1), metric: { $0.temperatureC })
            }
            networkCard
            systemCard
        }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 18)
    }
    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 21, weight: .medium))
                .foregroundStyle(MonitorStyle.blue).frame(width: 38, height: 38)
                .background(MonitorStyle.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("MacVitals").font(.system(size: 19, weight: .semibold))
                Text("SYSTEM TELEMETRY").tracking(1.1).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(model.latest.cpu == nil ? Color.gray : MonitorStyle.mint).frame(width: 5, height: 5)
                Text(model.latest.cpu == nil ? "等待采样" : "实时采样").font(.system(size: 10, weight: .medium))
            }.padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.white.opacity(0.05), in: Capsule())
            Button(action: settings) { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("刷新间隔、登录启动与退出")
                .accessibilityLabel("监控设置")
        }.padding(.horizontal, 18).padding(.vertical, 15)
        .overlay(alignment: .bottom) { Rectangle().fill(MonitorStyle.border).frame(height: 1) }
    }
    private func metricCard(_ title: String, icon: String, value: String?, unit: String, detail: String, color: Color, kind: InstrumentKind, ceiling: Double, metric: @escaping (Snapshot) -> Double?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(unit).foregroundStyle(.secondary)
            }.font(.system(size: 11, weight: .medium))
            MetricInstrument(kind: kind, value: metric(model.latest), display: value, unit: unit, color: color, maximum: ceiling)
            Text(value == nil ? "暂无可用数据" : detail).font(.system(size: 10))
                .foregroundStyle(.secondary).lineLimit(1).help(detail)
            HistoryRaster(points: points, now: model.now, seconds: seconds, ceiling: ceiling, metric: metric, color: color)
                .help("最近 \(seconds) 秒平均采样强度，越亮表示数值越高")
        }.frame(maxWidth: .infinity, alignment: .leading).modifier(MonitorCard())
    }
    private var networkCard: some View {
        let values = points.flatMap { [$0.snapshot.downloadBytesPerSecond, $0.snapshot.uploadBytesPerSecond].compactMap { $0 } }
        let ceiling = max(1000, (values.max() ?? 0) * 1.15)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("网络流量", systemImage: "network").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.latest.networkInterface).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.white.opacity(0.05), in: Capsule())
            }
            HStack {
                networkValue("下载", arrow: "arrow.down", rate: model.latest.downloadBytesPerSecond, color: MonitorStyle.blue)
                Spacer(minLength: 12)
                networkValue("上传", arrow: "arrow.up", rate: model.latest.uploadBytesPerSecond, color: MonitorStyle.amber)
            }
            VStack(alignment: .leading, spacing: 7) {
                networkAddress("IPv4", value: model.latest.networkIPv4)
                networkAddress("IPv6", value: model.latest.networkIPv6)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            Chart {
                RuleMark(y: .value("零线", 0)).foregroundStyle(MonitorStyle.border)
                ForEach(points) { point in
                    if let value = point.snapshot.downloadBytesPerSecond {
                        BarMark(x: .value("时间", point.time), yStart: .value("零", 0), yEnd: .value("下载", value), width: .fixed(3))
                            .foregroundStyle(LinearGradient(colors: [MonitorStyle.blue.opacity(0.9), MonitorStyle.blue.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                    }
                    if let value = point.snapshot.uploadBytesPerSecond {
                        BarMark(x: .value("时间", point.time), yStart: .value("零", 0), yEnd: .value("上传", -value), width: .fixed(3))
                            .foregroundStyle(LinearGradient(colors: [MonitorStyle.amber.opacity(0.35), MonitorStyle.amber.opacity(0.9)], startPoint: .top, endPoint: .bottom))
                    }
                }
            }.chartXScale(domain: domain).chartYScale(domain: -ceiling...ceiling)
                .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 56)
                .overlay(alignment: .topLeading) {
                    Text("↓").font(.system(size: 9)).foregroundStyle(MonitorStyle.blue)
                }
                .overlay(alignment: .bottomLeading) {
                    Text("↑").font(.system(size: 9)).foregroundStyle(MonitorStyle.amber)
                }
                .overlay {
                    if values.isEmpty { Text("等待网络采样").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            HStack { Text("−\(seconds) 秒"); Spacer(); Text("刻度 " + MetricsFormat.rate(ceiling)); Spacer(); Text("现在") }
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.modifier(MonitorCard())
    }
    private func networkValue(_ title: String, arrow: String, rate: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: arrow).font(.system(size: 10)).foregroundStyle(color)
            Text(MetricsFormat.rate(rate)).font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func networkAddress(_ family: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(family).font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(MonitorStyle.mint).frame(width: 34, alignment: .leading)
            Text(value.isEmpty ? "未分配" : value).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).help(value.isEmpty ? "该接口未分配 \(family) 地址" : value)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).disabled(value.isEmpty)
                .accessibilityLabel("复制 \(family) 地址").help("复制全部 \(family) 地址")
        }
    }
    private var systemCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ResourceInstrument(battery: true, fraction: model.latest.batteryPercent.map { $0 / 100 },
                    value: model.latest.batteryPercent.map { "\(Int($0))%" } ?? "—",
                    subtitle: model.latest.battery, charging: model.latest.batteryCharging)
                ResourceInstrument(battery: false, fraction: diskUsedFraction,
                    value: model.latest.diskAvailableBytes.map { MetricsFormat.bytes($0) } ?? "—",
                    subtitle: diskUsedFraction.map { "可用 · 已用 \(Int($0 * 100))%" } ?? "暂无可用数据", charging: false)
                    .help(model.latest.disk + "；亮色块表示已占用容量")
            }
            summaryRow("交换空间", model.latest.swap, icon: "arrow.left.arrow.right").modifier(MonitorCard())
        }
    }
    private var diskUsedFraction: Double? {
        guard let total = model.latest.diskTotalBytes, total > 0, let available = model.latest.diskAvailableBytes else { return nil }
        return 1 - min(1, Double(available) / Double(total))
    }
    private func summaryRow(_ title: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).lineLimit(1).truncationMode(.middle).help(value)
        }.font(.system(size: 11))
    }
    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("运行 " + model.latest.uptime).font(.system(size: 10)).lineLimit(1)
                Text("更新 " + model.now.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 9)).monospacedDigit()
            }.foregroundStyle(.secondary)
            Spacer()
            Button(action: showDetails) {
                HStack(spacing: 5) { Text("系统详情"); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
        }.padding(.horizontal, 18).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(MonitorStyle.border).frame(height: 1) }
    }
}
