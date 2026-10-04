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
    static let background = Color(red: 0.018, green: 0.032, blue: 0.043)
    static let card = Color(red: 0.035, green: 0.062, blue: 0.078)
    static let cyan = Color(red: 0.38, green: 0.76, blue: 1)
    static let purple = Color(red: 0.74, green: 0.62, blue: 1)
    static let green = Color(red: 0.38, green: 0.86, blue: 0.72)
    static var height: CGFloat { min(820, max(480, (NSScreen.main?.visibleFrame.height ?? 850) - 70)) }
}
struct AgentsView: View {
    @ObservedObject var model: AgentsModel
    var interval: Double
    let setInterval: (Double) -> Void
    var showDetails: (AgentProcessID) -> Void = { _ in }
    private var totalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }
    private var cores: Double { Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AgentSigil(seed: 0, color: AgentsStyle.cyan).frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 5) {
                    Text("AGENT // NEXUS").font(.system(size: 18, weight: .bold, design: .monospaced)).tracking(1)
                    Text("LOCAL TELEMETRY / PROCESS LINK").font(.system(size: 8, design: .monospaced)).tracking(1.2).foregroundStyle(AgentsStyle.cyan.opacity(0.7))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "%02d", model.latest.usages.count)).font(.system(size: 25, weight: .light, design: .monospaced)).foregroundStyle(AgentsStyle.green)
                    Text("NODES").font(.system(size: 8, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                }
            }.padding(18)
            Rectangle().fill(AgentsStyle.cyan.opacity(0.3)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if model.latest.sampled && model.latest.available {
                        HStack(spacing: 12) {
                            summary("Σ CPU / COMPUTE", value: cpu(model.latest.totalCPU), color: AgentsStyle.cyan)
                            summary("Σ RSS / MEMORY", value: model.latest.totalMemory.map { MetricsFormat.bytes($0) } ?? "—", color: AgentsStyle.purple)
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
        }.frame(width: 440, height: AgentsStyle.height)
            .background {
                AgentsStyle.background
                Canvas { context, size in
                    for y in stride(from: CGFloat(0), to: size.height, by: 4) {
                        context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.white.opacity(0.015)))
                    }
                    for x in stride(from: CGFloat(0), to: size.width, by: 20) {
                        for y in stride(from: CGFloat(0), to: size.height, by: 20) {
                            context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(AgentsStyle.cyan.opacity(0.12)))
                        }
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }.preferredColorScheme(.dark)
    }
    private func cpu(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "采样中" }
    private func summary(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .medium, design: .monospaced)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            Rectangle().fill(color.opacity(0.55)).frame(height: 2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(AgentsStyle.card, in: RoundedRectangle(cornerRadius: 3))
    }
    private func empty(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(AgentsStyle.cyan.opacity(0.7))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 55).padding(.horizontal, 24)
    }
    private func agentCard(_ usage: AgentUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AgentSigil(seed: AgentKind.allCases.firstIndex(of: usage.kind) ?? 0, color: accent(usage)).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(usage.kind.rawValue.uppercased()).font(.system(size: 14, weight: .bold, design: .monospaced)).tracking(1)
                    Text("PROCESS LINK / DETECTED").font(.system(size: 8, design: .monospaced)).tracking(0.8).foregroundStyle(accent(usage))
                }
                Spacer()
                Button("详情") { showDetails(usage.id) }.buttonStyle(.borderless).foregroundStyle(accent(usage))
                Text("#\(String(usage.id.pid))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                meter("CPU", value: cpu(usage.cpu), detail: usage.cpu.map { String(format: "整机 %.1f%%", $0 / cores) } ?? "建立采样基线",
                      fraction: usage.cpu.map { $0 / (cores * 100) }, color: AgentsStyle.cyan)
                meter("内存", value: usage.memory.map { MetricsFormat.bytes($0) } ?? "不可读", detail: "进程 RSS 合计",
                      fraction: usage.memory.map { Double($0) / Double(totalMemory) }, color: AgentsStyle.purple)
            }
            HStack {
                Text("CPU / 120s TRACE").tracking(1)
                Spacer()
                Text("→ NOW")
            }.font(.system(size: 8, design: .monospaced)).foregroundStyle(accent(usage).opacity(0.8))
            historyStrip(usage)
            processBus(usage)
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
        }.padding(14)
            .overlay(alignment: .topLeading) { Rectangle().fill(accent(usage)).frame(width: 28, height: 2) }
            .background(AgentsStyle.card, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent(usage).opacity(0.3), lineWidth: 1))
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
    private func accent(_ usage: AgentUsage) -> Color {
        usage.kind == .claude ? AgentsStyle.purple : AgentsStyle.cyan
    }
    private func processBus(_ usage: AgentUsage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu").foregroundStyle(accent(usage))
            Rectangle().fill(accent(usage).opacity(0.35)).frame(width: 16, height: 1)
            Canvas { context, size in
                let count = min(24, usage.processes.count)
                for index in 0..<count {
                    let x = CGFloat(index) * size.width / CGFloat(max(1, count))
                    context.fill(Path(CGRect(x: x, y: 3, width: 4, height: 4)), with: .color(accent(usage).opacity(0.75)))
                }
            }.frame(height: 10).accessibilityHidden(true)
            Text("\(usage.processes.count) PROC").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
        }.help("进程集合；每个点代表一个进程，最多显示 24 个")
    }
    private func historyStrip(_ usage: AgentUsage) -> some View {
        Canvas { context, size in
            let columns = 48, rows = 8
            let cellWidth = size.width / CGFloat(columns)
            let cellHeight = size.height / CGFloat(rows)
            let start = model.latest.time.addingTimeInterval(-120)
            for index in 0..<columns {
                let lower = start.addingTimeInterval(Double(index) * 2.5)
                let upper = lower.addingTimeInterval(2.5)
                let values = model.history.filter { $0.time >= lower && $0.time < upper }
                    .compactMap { $0.snapshot.usages.first { $0.id == usage.id }?.cpu }
                let mean = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
                // Logarithmic display retains small loads; raw CPU remains above.
                let level = mean.map { min(1, log1p(max(0, $0)) / log1p(cores * 100)) }
                for row in 0..<rows {
                    let lit = level.map { $0 > Double(rows - 1 - row) / Double(rows) } ?? false
                    let rect = CGRect(x: CGFloat(index) * cellWidth, y: CGFloat(row) * cellHeight, width: max(1, cellWidth - 2), height: cellHeight - 2)
                    context.fill(Path(rect), with: .color(lit ? accent(usage).opacity(0.3 + Double(row) * 0.08) : .white.opacity(0.035)))
                }
            }
        }.frame(height: 32).help("最近 2 分钟 CPU 点阵历史，采用对数刻度；上方显示真实 CPU 百分比")
    }
}

/// Stable geometric identity; no fabricated activity or task state.
private struct AgentSigil: View {
    let seed: Int
    let color: Color
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * 0.43
            var outer = Path()
            for i in 0...6 {
                let angle = Double(i) * .pi / 3 - .pi / 2
                let point = CGPoint(x: center.x + CGFloat(Foundation.cos(angle)) * radius, y: center.y + CGFloat(Foundation.sin(angle)) * radius)
                if i == 0 { outer.move(to: point) } else { outer.addLine(to: point) }
            }
            context.stroke(outer, with: .color(color.opacity(0.65)), lineWidth: 1)
            for i in 0..<6 {
                let angle = Double(i) * .pi / 3 - .pi / 2
                let point = CGPoint(x: center.x + CGFloat(Foundation.cos(angle)) * radius * 0.65, y: center.y + CGFloat(Foundation.sin(angle)) * radius * 0.65)
                var spoke = Path(); spoke.move(to: center); spoke.addLine(to: point)
                context.stroke(spoke, with: .color(color.opacity(i % 2 == seed % 2 ? 0.7 : 0.2)), lineWidth: 1)
                context.fill(Path(CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(color))
            }
            context.fill(Path(CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(color))
        }.accessibilityHidden(true)
    }
}

struct AgentDetailsView: View {
    @ObservedObject var model: AgentsModel
    let instance: AgentProcessID
    @State private var lastKnown: AgentUsage?
    private var current: AgentUsage? { model.latest.usages.first { $0.id == instance } }
    private var usage: AgentUsage? { current ?? lastKnown }
    @State private var selection: AgentProcessID?
    private var accent: Color { usage?.kind == .claude ? AgentsStyle.purple : AgentsStyle.cyan }
    private var selected: AgentProcessUsage? {
        guard let usage else { return nil }
        return usage.processes.first { $0.id == (selection ?? instance) } ?? usage.processes.first { $0.id == instance } ?? usage.processes.first
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if let usage {
                HStack(spacing: 12) {
                    instrument("01 / COMPUTE", value: usage.cpu.map { String(format: "%.1f%%", $0) } ?? "—",
                               caption: usage.cpu.map { String(format: "整机 %.2f%% · 单核 100%%", $0 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))) } ?? "等待采样基线", channel: 0)
                    instrument("02 / MEMORY", value: bytes(usage.memory), caption: "RSS 合计 / 共享页可能重复", channel: 1)
                    instrument("03 / DISK RX", value: MetricsFormat.rate(usage.readRate), caption: "磁盘读取 / BYTES·SEC", channel: 2)
                    instrument("04 / DISK TX", value: MetricsFormat.rate(usage.writeRate), caption: "磁盘写入 / BYTES·SEC", channel: 3)
                }.padding(16)
                Rectangle().fill(accent.opacity(0.2)).frame(height: 1)
                HStack(spacing: 0) {
                    AgentNeuralMap(usage: usage, root: instance, selected: selected?.id ?? instance,
                                   accent: accent, live: current != nil && model.latest.available,
                                   select: { selection = $0 })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(accent.opacity(0.2)).frame(width: 1)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let selected {
                                HStack(spacing: 10) {
                                    AgentSigil(seed: selected.id == instance ? 0 : 1, color: accent).frame(width: 34, height: 34)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(selected.name.uppercased()).font(.system(size: 16, weight: .bold, design: .monospaced)).lineLimit(1)
                                        Text("NODE #" + String(selected.id.pid) + " / " + (selected.id == instance ? "ROOT PROCESS" : "CHILD PROCESS"))
                                            .font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(accent)
                                    }
                                    Spacer()
                                    Text(selected.cpu.map { String(format: "%.1f%%", $0) } ?? "—")
                                        .font(.system(size: 25, weight: .light, design: .monospaced)).foregroundStyle(accent).monospacedDigit()
                                }
                                processDetails(selected)
                            }
                            terminalSection("INSTANCE / 根实例") {
                                row("启动时间", started(instance.started))
                                row("运行时长", duration(max(0, model.latest.time.timeIntervalSince1970 - Double(instance.started) / 1e6)))
                                row("进程 / 可读线程合计", "\(usage.processes.count) / \(usage.processes.compactMap { $0.detail?.threads }.reduce(0, +))")
                                row("物理足迹合计", sum(usage.processes.compactMap { $0.detail?.footprint }))
                                row("采样覆盖", usage.partial ? "PARTIAL / 缺失指标或正在建立基线" : "CPU + RSS / 全部成员已覆盖")
                            }
                            DisclosureGroup {
                                Text("CPU 以单核 100% 计；RSS 与物理足迹相加可能重复计算共享资源，虚拟内存不代表实际占用。磁盘计数从进程启动累计。BSD 状态与运行线程数是瞬时状态，不能证明 Agent 正在执行任务。\n\n未接入：会话、任务内容、模型、Token、费用、工具调用、远程 Agent、单进程网速。不会展示提示词、完整命令参数或环境变量。")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
                            } label: {
                                Text("DATA CONTRACT / 指标口径与采集范围").font(.system(size: 9, design: .monospaced)).tracking(0.6)
                            }.tint(accent).padding(12).background(AgentsStyle.card)
                        }.padding(18)
                    }.frame(width: 390)
                }
            } else {
                Spacer()
                Text("NO PROCESS LINK / 正在等待实例数据").font(.system(size: 14, design: .monospaced)).foregroundStyle(accent)
                Spacer()
            }
            HStack(spacing: 8) {
                Rectangle().fill(model.latest.available && current != nil ? AgentsStyle.green : .orange).frame(width: 5, height: 5)
                Text(!model.latest.available ? "READ FAILED / 保留最后快照" : current == nil ? "OFFLINE / 实例已退出" : "LINK ESTABLISHED / 本地进程可见")
                Spacer()
                Text("120s BUFFER · READ ONLY · LOCAL")
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).padding(12)
                .overlay(alignment: .top) { Rectangle().fill(accent.opacity(0.25)).frame(height: 1) }
        }.frame(minWidth: 980, minHeight: 680)
            .background {
                AgentsStyle.background
                Canvas { context, size in
                    for y in stride(from: CGFloat(0), to: size.height, by: 4) {
                        context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(accent.opacity(0.025)))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }.preferredColorScheme(.dark)
            .onAppear { if let current { lastKnown = current } }
            .onReceive(model.$latest) { snapshot in
                if let value = snapshot.usages.first(where: { $0.id == instance }) { lastKnown = value }
            }
    }
    private var header: some View {
        HStack(spacing: 14) {
            AgentSigil(seed: 0, color: accent).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text((usage?.kind.rawValue.uppercased() ?? "AGENT") + " / NEURAL ATLAS")
                    .font(.system(size: 21, weight: .semibold)).tracking(0.6)
                Text("LOCAL PROCESS NETWORK / ROOT #" + String(instance.pid))
                    .font(.system(size: 9, design: .monospaced)).tracking(1.6).foregroundStyle(accent.opacity(0.8))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(String(format: "%02d", usage?.processes.count ?? 0)).font(.system(size: 27, weight: .light, design: .monospaced)).foregroundStyle(accent)
                Text("PROCESS NODES / " + model.latest.time.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
            }
        }.padding(20).overlay(alignment: .bottom) { Rectangle().fill(accent.opacity(0.4)).frame(height: 1) }
    }
    private func instrument(_ title: String, value: String, caption: String, channel: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(accent)
            Text(value).font(.system(size: 23, weight: .medium, design: .monospaced)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            trace(channel).frame(height: 18)
            Text(caption).font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(AgentsStyle.card)
            .overlay(Rectangle().stroke(accent.opacity(0.18), lineWidth: 1))
            .overlay(alignment: .topLeading) { Rectangle().fill(accent).frame(width: 20, height: 2) }
    }
    private func trace(_ channel: Int) -> some View {
        Canvas { context, size in
            let start = model.latest.time.addingTimeInterval(-120)
            let values: [Double?] = (0..<48).map { index in
                let lower = start.addingTimeInterval(Double(index) * 2.5)
                let readings = model.history.filter { $0.time >= lower && $0.time < lower.addingTimeInterval(2.5) }
                    .compactMap { $0.snapshot.usages.first { $0.id == instance } }
                    .compactMap { value -> Double? in
                        switch channel {
                        case 0: return value.cpu
                        case 1: return value.memory.map { Double($0) }
                        case 2: return value.readRate
                        default: return value.writeRate
                        }
                    }
                return readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
            }
            let maximum = max(1, values.compactMap { $0 }.max() ?? 1)
            for index in 0..<48 {
                let x = CGFloat(index) * size.width / 48
                let height = values[index].map { max(1, CGFloat(max(0, $0) / maximum) * size.height) } ?? 1
                context.fill(Path(CGRect(x: x, y: size.height - height, width: max(1, size.width / 48 - 2), height: height)), with: .color(values[index] == nil ? .white.opacity(0.05) : accent.opacity(0.75)))
            }
        }.help("最近 120 秒真实采样，按当前窗口峰值自动缩放")
    }
    private func terminalSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(accent)
                Spacer()
                Text("RO").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(12).background(accent.opacity(0.06))
            VStack(spacing: 0, content: content).padding(.horizontal, 12).padding(.vertical, 4)
        }.background(AgentsStyle.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.14), lineWidth: 1))
    }
    private func processDetails(_ p: AgentProcessUsage) -> some View {
        VStack(spacing: 14) {
            terminalSection("IDENTITY / 节点身份") {
                row("PID / PPID / UID", "\(p.id.pid) / \(p.detail.map { String($0.parent) } ?? "—") / \(p.detail.map { String($0.uid) } ?? "—")")
                row("启动时间", started(p.id.started))
                row("可执行文件", p.detail.flatMap { $0.executable.isEmpty ? nil : $0.executable } ?? "不可读")
                row("脚本 / 模块入口", p.detail.flatMap { $0.entrypoint.isEmpty ? nil : $0.entrypoint } ?? "未提供 / 原生进程")
                row("BSD 状态", p.detail.map { state($0.status) } ?? "不可读")
            }
            terminalSection("RESOURCES / 执行资源") {
                row("CPU / RSS", (p.cpu.map { String(format: "%.2f%%", $0) } ?? "不可读") + " / " + bytes(p.memory))
                row("线程 / 运行 / 优先级", number(p.detail?.threads) + " / " + number(p.detail?.runningThreads) + " / " + number(p.detail?.priority))
                row("物理足迹 / 虚拟内存", bytes(p.detail?.footprint) + " / " + bytes(p.detail?.virtualBytes))
                row("用户 / 内核 CPU 累计", seconds(p.detail?.userNS) + " / " + seconds(p.detail?.systemNS))
            }
            terminalSection("IO + KERNEL / 内核计数") {
                row("磁盘累计读 / 写", bytes(p.detail?.readBytes) + " / " + bytes(p.detail?.writtenBytes))
                row("磁盘读 / 写速率", MetricsFormat.rate(p.readRate) + " / " + MetricsFormat.rate(p.writeRate))
                row("缺页 / 页入 / 上下文切换", number(p.detail?.faults) + " / " + number(p.detail?.pageins) + " / " + number(p.detail?.switches))
            }
        }.textSelection(.enabled)
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).foregroundStyle(.secondary).frame(width: 106, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 10, design: .monospaced)).padding(.vertical, 9).textSelection(.enabled)
            .overlay(alignment: .bottom) { Rectangle().fill(accent.opacity(0.08)).frame(height: 1) }
    }
    private func started(_ value: UInt64) -> String { Date(timeIntervalSince1970: Double(value) / 1e6).formatted(date: .numeric, time: .standard) }
    private func duration(_ value: Double) -> String { String(format: "%dh %02dm %02ds", Int(value) / 3600, Int(value) / 60 % 60, Int(value) % 60) }
    private func bytes(_ value: UInt64?) -> String { value.map { MetricsFormat.bytes($0) } ?? "不可读" }
    private func sum(_ values: [UInt64]) -> String { values.isEmpty ? "不可读" : MetricsFormat.bytes(values.reduce(0, +)) }
    private func number<T: BinaryInteger>(_ value: T?) -> String { value.map { String($0) } ?? "不可读" }
    private func seconds(_ value: UInt64?) -> String { value.map { String(format: "%.3f s", Double($0) / 1e9) } ?? "不可读" }
    private func state(_ value: Int32) -> String {
        switch value {
        case 1: return "SIDL / 创建中"
        case 2: return "SRUN / 可运行"
        case 3: return "SSLEEP / 等待"
        case 4: return "SSTOP / 停止"
        case 5: return "SZOMB / 僵尸"
        default: return "未知 (\(value))"
        }
    }
}

/// Geometry is stable under CPU sorting; rings encode process ancestry depth.
enum AgentNeuralLayout {
    static func positions(_ processes: [AgentProcessUsage], root: AgentProcessID, size: CGSize) -> [AgentProcessID: CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.id.pid, $0) })
        func depth(_ p: AgentProcessUsage) -> Int {
            var parent = p.detail?.parent ?? root.pid, visited: Set<Int32> = [p.id.pid], value = 1
            while parent != root.pid, let ancestor = byPID[parent], visited.insert(parent).inserted {
                value += 1; parent = ancestor.detail?.parent ?? root.pid
            }
            return value
        }
        let children = processes.filter { $0.id != root }.sorted { $0.id.pid < $1.id.pid }
        // Split crowded depth groups into rings of at most 16 nodes.
        let groups = Dictionary(grouping: children, by: { min(3, depth($0)) })
        var rings: [[AgentProcessUsage]] = []
        for key in groups.keys.sorted() {
            let members = groups[key] ?? []
            for offset in stride(from: 0, to: members.count, by: 16) {
                rings.append(Array(members[offset..<min(offset + 16, members.count)]))
            }
        }
        var result: [AgentProcessID: CGPoint] = [root: center]
        let limit = max(60, min(size.width, size.height) / 2 - 42)
        for (index, ring) in rings.enumerated() {
            let radius = rings.count == 1 ? limit * 0.77 : 95 + max(0, limit - 95) * CGFloat(index + 1) / CGFloat(rings.count)
            for (offset, p) in ring.enumerated() {
                let angle = Double(offset) * .pi * 2 / Double(ring.count) - .pi / 2 + Double(index) * 0.27
                result[p.id] = CGPoint(x: center.x + CGFloat(Foundation.cos(angle)) * radius, y: center.y + CGFloat(Foundation.sin(angle)) * radius)
            }
        }
        return result
    }
}

private struct AgentNeuralMap: View {
    let usage: AgentUsage
    let root: AgentProcessID
    let selected: AgentProcessID
    let accent: Color
    let live: Bool
    let select: (AgentProcessID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var page = 0
    @State private var hovered: AgentProcessID?
    @State private var listMode = false
    private var children: [AgentProcessUsage] { usage.processes.filter { $0.id != root }.sorted { $0.id.pid < $1.id.pid } }
    private var pages: Int { max(1, (children.count + 47) / 48) }
    private var effectivePage: Int { min(page, pages - 1) }
    private var visible: [AgentProcessUsage] {
        let begin = effectivePage * 48
        return usage.processes.filter { $0.id == root } + Array(children.dropFirst(begin).prefix(48))
    }
    private func matches(_ p: AgentProcessUsage) -> Bool {
        query.isEmpty || "\(p.name) \(p.id.pid) \(p.detail?.executable ?? "") \(p.detail?.entrypoint ?? "")".localizedCaseInsensitiveContains(query)
    }
    private func radius(_ p: AgentProcessUsage) -> CGFloat {
        p.id == root ? 47 : CGFloat(7 + min(11, sqrt(Double(p.memory ?? 0) / 1e9) * 9))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PROCESS CONSTELLATION").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(accent)
                Spacer()
                Button(listMode ? "节点网络" : "进程列表") { listMode.toggle() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.top, 18)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(accent)
                TextField("查找进程、PID 或路径", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.font(.system(size: 11)).padding(11).background(.white.opacity(0.035), in: Capsule()).padding(.horizontal, 22).padding(.top, 14)
            if listMode || !query.isEmpty {
                processList
            } else {
                graph
            }
            HStack(spacing: 12) {
                HStack(spacing: 5) { Circle().stroke(accent).frame(width: 9, height: 9); Text("大小 · RSS") }
                HStack(spacing: 5) { Circle().stroke(AgentsStyle.green, lineWidth: 2).frame(width: 9, height: 9); Text("光环 · CPU") }
                Text("连线 · 父子进程").foregroundStyle(.secondary)
                Spacer()
                if pages > 1 {
                    Button { page = max(0, effectivePage - 1) } label: { Image(systemName: "chevron.left") }.disabled(effectivePage == 0)
                    Text("\(effectivePage + 1)/\(pages)")
                    Button { page = min(pages - 1, effectivePage + 1) } label: { Image(systemName: "chevron.right") }.disabled(effectivePage == pages-1)
                }
            }.font(.system(size: 9)).foregroundStyle(accent.opacity(0.9)).buttonStyle(.plain).padding(.horizontal, 22).padding(.bottom, 12)
            Text("粒子随已采集的 CPU 活动变化 · 不代表思考、任务或网络传输")
                .font(.system(size: 9)).foregroundStyle(.secondary).padding(.bottom, 16)
        }.background(Color.black.opacity(0.12))
    }
    private var graph: some View {
                GeometryReader { geometry in
                    let positions = AgentNeuralLayout.positions(visible, root: root, size: geometry.size)
                    let labeled = Set(visible.filter { $0.id != root }.sorted { ($0.memory ?? 0) > ($1.memory ?? 0) }.prefix(5).map { $0.id })
                    ZStack {
                        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !live)) { timeline in
                            Canvas { context, size in
                                draw(&context, size: size, positions: positions, time: timeline.date.timeIntervalSinceReferenceDate)
                            }
                        }.allowsHitTesting(false).accessibilityHidden(true)
                        ForEach(visible) { p in
                            if let point = positions[p.id] {
                                node(p, at: point, labeled: labeled.contains(p.id))
                            }
                        }
                        if visible.count <= 1 {
                            Text("当前只有根进程 · 暂无子进程").font(.system(size: 11)).foregroundStyle(.secondary)
                                .position(x: geometry.size.width/2, y: geometry.size.height/2 + 110)
                        }
                    }
                }
    }
    private func draw(_ context: inout GraphicsContext, size: CGSize, positions: [AgentProcessID: CGPoint], time: TimeInterval) {
                                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                                context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(Gradient(colors: [accent.opacity(0.10), .clear]), center: center, startRadius: 10, endRadius: min(size.width, size.height) / 2))
                                // Fixed star field is decorative, not inferred agent activity.
                                for index in 0..<90 {
                                    let x = CGFloat((index * 173 + 19) % 997) / 997 * size.width
                                    let y = CGFloat((index * 331 + 71) % 991) / 991 * size.height
                                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(accent.opacity(index % 4 == 0 ? 0.35 : 0.10)))
                                }
                                for scale in [0.31, 0.61, 0.89] {
                                    let r = min(size.width, size.height) * scale / 2
                                    context.stroke(Path(ellipseIn: CGRect(x: center.x-r, y: center.y-r, width: r*2, height: r*2)), with: .color(accent.opacity(0.09)), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                                }
                                for p in visible where p.id != root {
                                    guard let point = positions[p.id], let parent = p.detail?.parent,
                                          let parentProcess = visible.first(where: { $0.id.pid == parent }), let parentPoint = positions[parentProcess.id] else { continue }
                                    var path = Path(); path.move(to: parentPoint); path.addLine(to: point)
                                    let highlighted = p.id == selected || p.id == hovered || parentProcess.id == selected
                                    context.stroke(path, with: .color(accent.opacity(highlighted ? 0.45 : 0.15)), lineWidth: highlighted ? 1 : 0.6)
                                }
                                let now = time
                                for p in visible {
                                    guard let point = positions[p.id] else { continue }
                                    let r = radius(p), load = min(1, max(0, p.cpu ?? 0) / 100)
                                    let active = live && p.cpu != nil && (p.cpu ?? 0) > 0.1
                                    let glow = r + 14 + CGFloat(load * 12)
                                    context.fill(Path(ellipseIn: CGRect(x: point.x-glow, y: point.y-glow, width: glow*2, height: glow*2)), with: .radialGradient(Gradient(colors: [accent.opacity(p.id == selected ? 0.3 : 0.12 + load * 0.12), .clear]), center: point, startRadius: r * 0.5, endRadius: glow))
                                    context.fill(Path(ellipseIn: CGRect(x: point.x-r, y: point.y-r, width: r*2, height: r*2)), with: .color(AgentsStyle.background))
                                    context.stroke(Path(ellipseIn: CGRect(x: point.x-r, y: point.y-r, width: r*2, height: r*2)), with: .color(accent.opacity(p.id == selected ? 1 : 0.5)), lineWidth: p.id == selected ? 2 : 1)
                                    var arc = Path(); arc.addArc(center: point, radius: r+5, startAngle: .degrees(-90), endAngle: .degrees(-90 + load*360), clockwise: false)
                                    context.stroke(arc, with: .color(AgentsStyle.green), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    if active {
                                        let angle = (reduceMotion ? 0 : now * (0.3 + load)) + Double(p.id.pid % 23)
                                        let orbit = r + 7
                                        let dot = CGPoint(x: point.x + CGFloat(Foundation.cos(angle))*orbit, y: point.y + CGFloat(Foundation.sin(angle))*orbit)
                                        context.fill(Path(ellipseIn: CGRect(x: dot.x-2, y: dot.y-2, width: 4, height: 4)), with: .color(AgentsStyle.green))
                                    }
                                    if p.id != root {
                                        let core = max(2, r * 0.24)
                                        context.fill(Path(ellipseIn: CGRect(x: point.x-core, y: point.y-core, width: core*2, height: core*2)), with: .color(accent.opacity(0.8)))
                                    }
                                }
    }

    private var processList: some View {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(usage.processes.filter { matches($0) }.sorted { $0.id.pid < $1.id.pid }) { process in
                            Button { select(process.id); page = children.firstIndex(where: { $0.id == process.id }).map { $0 / 48 } ?? 0; query = ""; listMode = false } label: {
                                HStack {
                                    Circle().fill(accent).frame(width: 5, height: 5)
                                    Text(process.name).lineLimit(1)
                                    Spacer()
                                    Text("#" + String(process.id.pid)).foregroundStyle(.secondary)
                                    Text(process.cpu.map { String(format: "%.1f%%", $0) } ?? "—").frame(width: 60, alignment: .trailing)
                                }.font(.system(size: 11, design: .monospaced)).padding(12).background(selected == process.id ? accent.opacity(0.12) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                        if !usage.processes.contains(where: { matches($0) }) { Text("无匹配进程").foregroundStyle(.secondary).padding(30) }
                    }.padding(20)
                }
    }
    @ViewBuilder private func node(_ p: AgentProcessUsage, at point: CGPoint, labeled: Bool) -> some View {
        processButton(p).position(point)
            .onHover { inside in hovered = inside ? p.id : nil }
            .help(p.name + " #" + String(p.id.pid))
            .accessibilityLabel(p.name + "，PID " + String(p.id.pid))
                                if p.id != root && (labeled || p.id == selected || p.id == hovered) {
                                    VStack(spacing: 3) {
                                        Text(p.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                                        Text("#" + String(p.id.pid)).font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                                    }.frame(width: 100).padding(4).background(AgentsStyle.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
                                        .position(x: point.x, y: point.y + radius(p) + 24).allowsHitTesting(false)
                                }
    }
    private func processButton(_ p: AgentProcessUsage) -> some View {
        Button { select(p.id) } label: {
            Group {
                if p.id == root {
                    VStack(spacing: 4) {
                        Image(systemName: "cpu").font(.system(size: 21)).foregroundStyle(accent)
                        Text(usage.kind.rawValue).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text("ROOT").font(.system(size: 7, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                    }.frame(width: 92, height: 92)
                } else {
                    Color.clear.frame(width: max(30, radius(p)*2 + 8), height: max(30, radius(p)*2 + 8)).contentShape(Circle())
                }
            }
        }.buttonStyle(.plain)
    }

}
