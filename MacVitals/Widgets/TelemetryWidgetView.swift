import SwiftUI

/// Native data transitions on fixed gauges; history is reserved for network traffic.
struct TelemetryWidgetView: View {
    let snapshot: WidgetSnapshot?
    let date: Date
    var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let green = Color(red: 0.57, green: 0.95, blue: 0.64)
    private let cyan = Color(red: 0.40, green: 0.85, blue: 0.96)
    private let amber = Color(red: 1, green: 0.74, blue: 0.38)
    private var stale: Bool { snapshot.map { date.timeIntervalSince($0.sampledAt) >= 120 } ?? true }
    private var history: [WidgetHistoryPoint] { snapshot?.history ?? [] }
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.35) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(">_").foregroundStyle(green).font(.system(size: 11, weight: .bold, design: .monospaced))
                Text("MACVITALS").tracking(1.6).foregroundStyle(.white.opacity(0.9))
                Text("/ SYS").foregroundStyle(.white.opacity(0.35))
                Spacer(minLength: 0)
                Text(snapshot.map { $0.interface.isEmpty ? "LOCAL" : $0.interface.uppercased() } ?? "LOCAL")
                    .foregroundStyle(cyan.opacity(0.8)).lineLimit(1)
            }.font(.system(size: 8, weight: .medium, design: .monospaced))
                .contentTransition(.identity)

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    tile("01", label: "CPU", value: percent(snapshot?.cpu), unit: "%", color: green, percentage: snapshot?.cpu)
                    tile("02", label: "MEM", value: percent(snapshot?.memory), unit: "%", color: cyan, percentage: snapshot?.memory)
                }
                HStack(spacing: 6) {
                    tile("03", label: "RX ↓", value: rate(snapshot?.download).0, unit: rate(snapshot?.download).1, color: cyan, readings: history.map(\.download))
                    tile("04", label: "TX ↑", value: rate(snapshot?.upload).0, unit: rate(snapshot?.upload).1, color: amber, readings: history.map(\.upload))
                }
            }.frame(maxHeight: expanded ? .infinity : nil)

            HStack(spacing: 5) {
                Circle().fill(stale ? amber : green).frame(width: 4, height: 4)
                Text(snapshot == nil ? "NO DATA" : (stale ? "STALE" : "SAMPLED"))
                    .foregroundStyle(stale ? amber : green.opacity(0.8)).contentTransition(.identity)
                Spacer(minLength: 0)
                if let snapshot {
                    Text(snapshot.sampledAt, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                        .foregroundStyle(.white.opacity(0.4)).monospacedDigit()
                        .contentTransition(.identity).animation(nil, value: snapshot.sampledAt)
                } else { Text("点击打开监控").foregroundStyle(.white.opacity(0.5)) }
                Text("//").foregroundStyle(green.opacity(0.35))
            }.font(.system(size: 8, weight: .medium, design: .monospaced))
        }.frame(maxHeight: expanded ? .infinity : nil)
        .accessibilityElement(children: .contain)
    }
    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f", min(100, $0)) } ?? "—"
    }
    private func rate(_ value: Double?) -> (String, String) {
        guard let value else { return ("—", "B/s") }
        let parts = MetricsFormat.rate(value).split(separator: " ", maxSplits: 1)
        return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "B/s")
    }
    private func number(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: expanded ? 27 : 20, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText()).animation(motion, value: value)
                .frame(width: unit == "%" ? (expanded ? 51 : 38) : (expanded ? 84 : 60), alignment: .leading)
            Text(unit).font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45)).contentTransition(.identity)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: unit == "%" ? 9 : 24, alignment: .leading)
        }
    }
    private func tile(_ index: String, label: String, value: String, unit: String, color: Color,
                      percentage: Double? = nil, readings: [Double?] = []) -> some View {
        let gauge = label == "CPU" || label == "MEM"
        let series = TelemetryHistogram(points: history, readings: readings, sampledAt: snapshot?.sampledAt ?? date,
                                        slots: expanded ? 30 : 12)
        return VStack(alignment: .leading, spacing: expanded ? 7 : 1) {
            HStack(spacing: 4) {
                Text(index).foregroundStyle(color.opacity(0.35))
                Text(label).tracking(1).foregroundStyle(color.opacity(0.85))
                Spacer(minLength: 0)
                if expanded { Text(gauge ? "0—100%" : "60s").foregroundStyle(color.opacity(0.4)) }
            }.font(.system(size: 8, weight: .medium, design: .monospaced)).contentTransition(.identity)
            if gauge && expanded {
                Spacer(minLength: 0)
                TelemetryRing(percentage: percentage, color: color, lineWidth: 5)
                    .frame(width: 88, height: 88)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(value).font(.system(size: 27, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.95)).monospacedDigit()
                                .contentTransition(.numericText()).animation(motion, value: value)
                            Text("%").font(.system(size: 9, design: .monospaced)).foregroundStyle(color.opacity(0.6))
                        }
                    }.frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .center, spacing: 5) {
                    number(value, unit: unit)
                    Spacer(minLength: 0)
                    if !expanded {
                        if gauge {
                            TelemetryRing(percentage: percentage, color: color, lineWidth: 2.5)
                                .frame(width: 26, height: 26).accessibilityHidden(true)
                        } else {
                            TelemetryBars(series: series, color: color)
                                .frame(width: 36, height: 22).accessibilityHidden(true)
                        }
                    }
                }
                if expanded {
                    Spacer(minLength: 0)
                    TelemetryBars(series: series, color: color)
                        .frame(height: 44).accessibilityHidden(true)
                    HStack {
                        Text("≤ " + MetricsFormat.rate(series.ceiling))
                        Spacer(minLength: 0)
                        Text("NOW")
                    }.font(.system(size: 7, design: .monospaced)).foregroundStyle(color.opacity(0.4))
                        .contentTransition(.identity).animation(nil, value: series.ceiling)
                }
            }
        }
        .padding(.horizontal, expanded ? 10 : 8).padding(.vertical, expanded ? 10 : 3)
        .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : nil, alignment: .leading)
        .background(color.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.13), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label == "MEM" ? "内存" : (label.hasPrefix("RX") ? "下载" : (label.hasPrefix("TX") ? "上传" : "CPU")))
        .accessibilityValue("\(value) \(unit)")
    }
}

private struct TelemetryRing: View {
    let percentage: Double?
    let color: Color
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var fraction: Double { min(100, max(0, percentage ?? 0)) / 100 }
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.12), lineWidth: lineWidth)
            Circle().trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: fraction)
        }.padding(lineWidth / 2)
    }
}

/// Fixed 60-second bins use measured peaks; empty bins remain empty. Scale changes only at 1/2/5 bands.
private struct TelemetryHistogram {
    let values: [Double?]
    let ceiling: Double
    init(points: [WidgetHistoryPoint], readings: [Double?], sampledAt: Date, slots: Int) {
        var bins = [Double?](repeating: nil, count: slots)
        for (point, reading) in zip(points, readings) {
            guard let reading, reading.isFinite, reading >= 0 else { continue }
            let age = sampledAt.timeIntervalSince(point.sampledAt)
            guard age >= 0, age < 60 else { continue }
            // Allow small timer jitter around nominal bin boundaries.
            let offset = min(slots - 1, Int((age + 0.1) / (60 / Double(slots))))
            let index = slots - 1 - offset
            bins[index] = max(bins[index] ?? 0, reading)
        }
        values = bins
        let peak = max(1, bins.compactMap { $0 }.max() ?? 1)
        let order = pow(10, floor(log10(peak)))
        ceiling = ([1.0, 2, 5, 10].first { $0 * order >= peak } ?? 10) * order
    }
}

private struct TelemetryBars: View {
    let series: TelemetryHistogram
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(series.values.indices, id: \.self) { index in
                    let reading = series.values[index]
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color.opacity(index == series.values.count - 1 ? 1 : 0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: reading.map { max(1, min(1, $0 / series.ceiling) * geometry.size.height) } ?? 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: series.values)
                }
            }.frame(height: geometry.size.height, alignment: .bottom)
            .overlay(alignment: .bottom) { Rectangle().fill(color.opacity(0.12)).frame(height: 0.5) }
        }
    }
}

struct TelemetryWidgetBackground: View {
    var body: some View {
        GeometryReader { geometry in
            Color(red: 0.025, green: 0.045, blue: 0.045)
            Path { path in
                for x in stride(from: CGFloat(0), through: geometry.size.width, by: 16) {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }
                for y in stride(from: CGFloat(0), through: geometry.size.height, by: 16) {
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }.stroke(Color.green.opacity(0.025), lineWidth: 0.5)
            LinearGradient(colors: [.green.opacity(0.025), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
