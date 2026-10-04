import SwiftUI

struct AgentHistory {
    let time: Date
    let snapshot: AgentSnapshot
}
final class AgentsModel: ObservableObject {
    @Published var latest = AgentSnapshot()
    @Published var history: [AgentHistory] = []
    func record(_ snapshot: AgentSnapshot) {
        latest = snapshot
        history.removeAll { $0.time < snapshot.time.addingTimeInterval(-120) }
        history.append(.init(time: snapshot.time, snapshot: snapshot))
    }
}
enum AgentsStyle {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.085)
    static let card = Color(red: 0.095, green: 0.108, blue: 0.135)
    static let cyan = Color(red: 0.38, green: 0.76, blue: 1)
    static let purple = Color(red: 0.74, green: 0.62, blue: 1)
    static let green = Color(red: 0.38, green: 0.86, blue: 0.72)
    static var height: CGFloat { min(680, max(480, (NSScreen.main?.visibleFrame.height ?? 850) - 70)) }
}
struct AgentsView: View {
    @ObservedObject var model: AgentsModel
    var interval: Double
    let setInterval: (Double) -> Void
    private var totalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }
    private var cores: Double { Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "terminal").font(.system(size: 22)).foregroundStyle(AgentsStyle.cyan)
                    .frame(width: 40, height: 40).background(AgentsStyle.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent Monitor").font(.system(size: 19, weight: .semibold))
                    Text("LOCAL PROCESS TELEMETRY").font(.system(size: 9, design: .monospaced)).tracking(0.8).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.latest.usages.count) 实例").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Color.white.opacity(0.05), in: Capsule())
            }.padding(18)
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if model.latest.sampled && model.latest.available {
                        HStack(spacing: 12) {
                            summary("CPU 合计", value: cpu(model.latest.totalCPU), color: AgentsStyle.cyan)
                            summary("驻留内存合计", value: model.latest.totalMemory.map { MetricsFormat.bytes($0) } ?? "—", color: AgentsStyle.purple)
                        }
                    }
                    if !model.latest.sampled {
                        ProgressView("正在识别本地 agent…").frame(maxWidth: .infinity).padding(50)
                    } else if !model.latest.available {
                        empty("读取进程失败", detail: "稍后会自动重试；不会将失败显示成零占用。", icon: "exclamationmark.triangle")
                    } else if model.latest.usages.isEmpty {
                        empty("未发现支持的 Agent", detail: "支持 Codex、Claude Code、Gemini CLI、OpenCode、Cursor 和 Aider。启动后会自动出现。", icon: "terminal")
                    } else {
                        ForEach(model.latest.usages) { usage in agentCard(usage) }
                    }
                }.padding(18)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("本地进程存在，不代表正在执行任务").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach([2.0, 5, 10], id: \.self) { value in
                            Button("\(Int(value)) 秒" + (interval == value ? " ✓" : "")) { setInterval(value) }
                        }
                    } label: { Text("\(Int(interval))s 刷新").font(.system(size: 10)).foregroundStyle(.secondary) }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Agent 刷新间隔")
                }
                Text("CPU 单核 100% · 包含子进程 · RSS 合计的共享页可能重复计算")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
        }.frame(width: 440, height: AgentsStyle.height).background(AgentsStyle.background).preferredColorScheme(.dark)
    }
    private func cpu(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "采样中" }
    private func summary(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .medium, design: .monospaced)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            Rectangle().fill(color.opacity(0.55)).frame(height: 2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(AgentsStyle.card, in: RoundedRectangle(cornerRadius: 12))
    }
    private func empty(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(AgentsStyle.cyan.opacity(0.7))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 55).padding(.horizontal, 24)
    }
    private func agentCard(_ usage: AgentUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RoundedRectangle(cornerRadius: 2).fill(AgentsStyle.green).frame(width: 5, height: 13)
                Text(usage.kind.rawValue).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("PID \(usage.id.pid)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                meter("CPU", value: cpu(usage.cpu), detail: usage.cpu.map { String(format: "整机 %.1f%%", $0 / cores) } ?? "建立采样基线",
                      fraction: usage.cpu.map { $0 / (cores * 100) }, color: AgentsStyle.cyan)
                meter("内存", value: usage.memory.map { MetricsFormat.bytes($0) } ?? "不可读", detail: "进程 RSS 合计",
                      fraction: usage.memory.map { Double($0) / Double(totalMemory) }, color: AgentsStyle.purple)
            }
            historyStrip(usage)
            HStack {
                Text("磁盘 ↓ " + MetricsFormat.rate(usage.readRate))
                Spacer()
                Text("↑ " + MetricsFormat.rate(usage.writeRate))
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            DisclosureGroup {
                VStack(spacing: 7) {
                    ForEach(usage.processes) { process in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(process.name.isEmpty ? "进程" : process.name).lineLimit(1)
                                Text("PID \(process.id.pid)").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(cpu(process.cpu)).frame(width: 65, alignment: .trailing)
                            Text(process.memory.map { MetricsFormat.bytes($0) } ?? "不可读").frame(width: 78, alignment: .trailing)
                        }.font(.system(size: 10, design: .monospaced)).padding(.vertical, 3)
                    }
                }.padding(.top, 10)
            } label: {
                HStack {
                    Text("\(usage.processes.count) 个进程").font(.system(size: 10))
                    if usage.partial { Text(usage.cpu == nil ? "采样中" : "部分采样").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
            }.tint(AgentsStyle.cyan)
        }.padding(14).background(AgentsStyle.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.075), lineWidth: 1))
    }
    private func meter(_ title: String, value: String, detail: String, fraction: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .medium, design: .monospaced)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(fraction.map { Double(index) / 24 < min(1, max(0, $0)) } == true ? color : Color.white.opacity(0.06))
                }
            }.frame(height: 5)
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func historyStrip(_ usage: AgentUsage) -> some View {
        Canvas { context, size in
            let width = (size.width - 31 * 2) / 32
            let start = model.latest.time.addingTimeInterval(-120)
            for index in 0..<32 {
                let lower = start.addingTimeInterval(Double(index) * 120 / 32)
                let upper = lower.addingTimeInterval(120.0 / 32)
                let values = model.history.filter { $0.time >= lower && $0.time <= upper }
                    .compactMap { $0.snapshot.usages.first { $0.id == usage.id }?.cpu }
                let mean = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
                let rect = CGRect(x: CGFloat(index) * (width + 2), y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(mean.map { AgentsStyle.cyan.opacity(0.15 + min(1, $0 / (cores * 100)) * 0.85) } ?? .white.opacity(0.035)))
            }
        }.frame(height: 5).help("最近 2 分钟 CPU 采样强度，亮度按整机占用计算")
    }
}
