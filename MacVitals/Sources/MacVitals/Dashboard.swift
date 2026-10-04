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
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    let settings: () -> Void
    let showDetails: () -> Void
    private let blue = Color(red: 0.27, green: 0.65, blue: 1)
    private let purple = Color(red: 0.72, green: 0.49, blue: 1)
    private let green = Color(red: 0.26, green: 0.85, blue: 0.66)
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacVitals").font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("实时系统状态 · 最近 2 分钟").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(green).frame(width: 6, height: 6)
                Text("实时").font(.system(size: 11)).foregroundStyle(green)
                Button("详情", action: showDetails).buttonStyle(.bordered).controlSize(.small)
                Button(action: settings) { Image(systemName: "gearshape").font(.system(size: 15)) }
                    .buttonStyle(.plain).padding(.leading, 8).help("刷新间隔、登录启动与退出")
            }
            graph(title: "CPU", value: model.latest.cpu.map { String(format: "%.0f%%", $0) } ?? "采样中", detail: "所有核心整体利用率", color: blue, ceiling: 100, unit: "%", metric: { $0.cpu })
            graph(title: "内存", value: model.latest.memoryPercent.map { "\(Int($0))%" } ?? "不可用", detail: model.latest.memory, color: purple, ceiling: 100, unit: "%", metric: { $0.memoryPercent })
            graph(title: "风扇", value: model.latest.fanRPM.map { "\(Int($0)) RPM" } ?? "不可用", detail: model.latest.fans, color: green, ceiling: max(6000, (model.readings.compactMap { $0.snapshot.fanRPM }.max() ?? 0) * 1.15), unit: "", metric: { $0.fanRPM })
            networkGraph
            VStack(spacing: 9) {
                detailRow("温度", model.latest.temperature, icon: "thermometer.medium", color: .orange)
                detailRow("电池", model.latest.battery, icon: "battery.75percent", color: green)
                detailRow("磁盘", model.latest.disk, icon: "internaldrive", color: blue)
                detailRow("交换空间", model.latest.swap, icon: "arrow.left.arrow.right", color: purple)
                detailRow("运行", model.latest.uptime, icon: "clock", color: .secondary)
            }.padding(12).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("曲线持续采样 · 风扇曲线显示最高转速").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(model.now, style: .time).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        }
        .frame(width: 420, height: 660)
        .background(Color(red: 0.065, green: 0.08, blue: 0.12))
        .preferredColorScheme(.dark)
    }
    private var networkGraph: some View {
        let rates = model.readings.flatMap { [$0.snapshot.downloadBytesPerSecond, $0.snapshot.uploadBytesPerSecond].compactMap { $0 } }
        let ceiling = max(1000, (rates.max() ?? 0) * 1.15)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("实时网速").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.latest.networkInterface).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack {
                Text("↓ " + MetricsFormat.rate(model.latest.downloadBytesPerSecond)).foregroundStyle(blue)
                Spacer()
                Text("↑ " + MetricsFormat.rate(model.latest.uploadBytesPerSecond)).foregroundStyle(.orange)
            }.font(.system(size: 13, weight: .semibold, design: .monospaced))
            Chart {
                ForEach(model.readings) { point in
                    if let value = point.snapshot.downloadBytesPerSecond {
                        LineMark(x: .value("时间", point.time), y: .value("速度", value), series: .value("线路", "下载 " + point.snapshot.networkInterface))
                            .foregroundStyle(blue).lineStyle(StrokeStyle(lineWidth: 1.8))
                    }
                    if let value = point.snapshot.uploadBytesPerSecond {
                        LineMark(x: .value("时间", point.time), y: .value("速度", value), series: .value("线路", "上传 " + point.snapshot.networkInterface))
                            .foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 1.8))
                    }
                }
            }
            .chartXScale(domain: model.now.addingTimeInterval(-120)...model.now)
            .chartYScale(domain: 0...ceiling)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, ceiling]) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(MetricsFormat.rate(number)).font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 48)
            Text("蓝色下载 · 橙色上传 · 最近 2 分钟").font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(12).background(blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private func graph(title: String, value: String, detail: String, color: Color, ceiling: Double, unit: String, metric: @escaping (Snapshot) -> Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
            }
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(detail)
            Chart {
                ForEach(model.readings) { point in
                    if let number = metric(point.snapshot) {
                        AreaMark(x: .value("时间", point.time), yStart: .value("零", 0), yEnd: .value(title, number))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", point.time), y: .value(title, number))
                            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.8))
                        if point.id == model.readings.last?.id {
                            PointMark(x: .value("时间", point.time), y: .value(title, number)).foregroundStyle(color).symbolSize(16)
                        }
                    }
                }
            }
            .chartXScale(domain: model.now.addingTimeInterval(-120)...model.now)
            .chartYScale(domain: 0...ceiling)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, ceiling / 2, ceiling]) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                    AxisValueLabel {
                        if let n = value.as(Double.self) { Text("\(Int(n))\(unit)").font(.system(size: 8)).foregroundStyle(.secondary) }
                    }
                }
            }
            .frame(height: 48)
            .overlay {
                if !model.readings.contains(where: { metric($0.snapshot) != nil }) {
                    Text("暂无可用传感器数据").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("\(title)最近两分钟曲线，当前\(value)")
            HStack {
                Text("−2 分钟"); Spacer(); Text("现在")
            }.font(.system(size: 8)).foregroundStyle(.secondary)
        }.padding(12).background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private func detailRow(_ label: String, _ value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Spacer(minLength: 4)
            Text(value).lineLimit(1).help(value)
        }.font(.system(size: 11))
    }
}
