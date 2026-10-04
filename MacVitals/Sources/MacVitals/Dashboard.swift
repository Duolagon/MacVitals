import SwiftUI
import Charts

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
    static var panelHeight: CGFloat { min(760, max(480, (NSScreen.main?.visibleFrame.height ?? 850) - 70)) }
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
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    let settings: () -> Void
    let showDetails: () -> Void
    @State private var seconds = 120
    private var points: [Reading] { model.readings.filter { $0.time >= model.now.addingTimeInterval(-Double(seconds)) } }
    private var domain: ClosedRange<Date> { model.now.addingTimeInterval(-Double(seconds))...model.now }
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("性能概览").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Picker("曲线时间范围", selection: $seconds) {
                            Text("30 秒").tag(30)
                            Text("1 分钟").tag(60)
                            Text("2 分钟").tag(120)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 188).controlSize(.small)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        metricCard("CPU", icon: "cpu", value: model.latest.cpu.map { String(format: "%.0f", $0) }, unit: "%", detail: "全部核心", color: MonitorStyle.blue, ceiling: 100, metric: { $0.cpu })
                        metricCard("内存", icon: "memorychip", value: model.latest.memoryPercent.map { String(Int($0)) }, unit: "%", detail: model.latest.memory, color: MonitorStyle.purple, ceiling: 100, metric: { $0.memoryPercent })
                        metricCard("风扇", icon: "fanblades", value: model.latest.fanRPM.map { String(format: "%.0f", $0) }, unit: "RPM", detail: "最高转速", color: MonitorStyle.mint, ceiling: max(6000, (points.compactMap { $0.snapshot.fanRPM }.max() ?? 0) * 1.1), metric: { $0.fanRPM })
                        metricCard("温度", icon: "thermometer.medium", value: model.latest.temperatureC.map { String(format: "%.1f", $0) }, unit: "°C", detail: "CPU 区域传感器", color: MonitorStyle.amber, ceiling: max(100, (points.compactMap { $0.snapshot.temperatureC }.max() ?? 0) * 1.1), metric: { $0.temperatureC })
                    }
                    networkCard
                    systemCard
                }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 18)
            }
            footer
        }
        .frame(width: 440, height: MonitorStyle.panelHeight)
        .background(MonitorStyle.background)
        .preferredColorScheme(.dark)
    }
    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 21, weight: .medium))
                .foregroundStyle(MonitorStyle.blue).frame(width: 38, height: 38)
                .background(MonitorStyle.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("MacVitals").font(.system(size: 19, weight: .semibold))
                Text("系统实时监控").font(.system(size: 11)).foregroundStyle(.secondary)
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
    private func metricCard(_ title: String, icon: String, value: String?, unit: String, detail: String, color: Color, ceiling: Double, metric: @escaping (Snapshot) -> Double?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(unit).foregroundStyle(.secondary)
            }.font(.system(size: 11, weight: .medium))
            Text(value ?? "—").font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(.primary)
            Text(value == nil ? "暂无可用数据" : detail).font(.system(size: 10))
                .foregroundStyle(.secondary).lineLimit(1).help(detail)
            Chart {
                ForEach(points) { point in
                    if let number = metric(point.snapshot) {
                        AreaMark(x: .value("时间", point.time), yStart: .value("零", 0), yEnd: .value(title, number))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.24), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", point.time), y: .value(title, number))
                            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.7))
                    }
                }
            }.chartXScale(domain: domain).chartYScale(domain: 0...ceiling)
                .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 32)
                .accessibilityLabel("\(title)最近\(seconds)秒曲线，当前\(value ?? "不可用")\(unit)")
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
            Chart {
                ForEach(points) { point in
                    if let value = point.snapshot.downloadBytesPerSecond {
                        LineMark(x: .value("时间", point.time), y: .value("速度", value), series: .value("线路", "下载 " + point.snapshot.networkInterface))
                            .foregroundStyle(MonitorStyle.blue).lineStyle(StrokeStyle(lineWidth: 1.8))
                    }
                    if let value = point.snapshot.uploadBytesPerSecond {
                        LineMark(x: .value("时间", point.time), y: .value("速度", value), series: .value("线路", "上传 " + point.snapshot.networkInterface))
                            .foregroundStyle(MonitorStyle.amber).lineStyle(StrokeStyle(lineWidth: 1.8, dash: [4, 3]))
                    }
                }
            }.chartXScale(domain: domain).chartYScale(domain: 0...ceiling)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, ceiling]) { value in
                        AxisGridLine().foregroundStyle(MonitorStyle.border)
                        AxisValueLabel {
                            if let rate = value.as(Double.self) { Text(MetricsFormat.rate(rate)).font(.system(size: 8)).foregroundStyle(.secondary) }
                        }
                    }
                }.frame(height: 48)
                .overlay {
                    if values.isEmpty { Text("等待网络采样").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            HStack { Text("−\(seconds) 秒"); Spacer(); Text("现在") }
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
    private var systemCard: some View {
        VStack(spacing: 9) {
            summaryRow("电池", model.latest.battery, icon: "battery.75percent")
            summaryRow("磁盘可用", model.latest.disk, icon: "internaldrive")
            summaryRow("交换空间", model.latest.swap, icon: "arrow.left.arrow.right")
        }.modifier(MonitorCard())
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
