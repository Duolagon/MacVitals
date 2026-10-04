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
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if i == 0 { outer.move(to: point) } else { outer.addLine(to: point) }
            }
            context.stroke(outer, with: .color(color.opacity(0.65)), lineWidth: 1)
            for i in 0..<6 {
                let angle = Double(i) * .pi / 3 - .pi / 2
                let point = CGPoint(x: center.x + cos(angle) * radius * 0.65, y: center.y + sin(angle) * radius * 0.65)
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
    @State private var query = ""
    @State private var lastKnown: AgentUsage?
    private var current: AgentUsage? { model.latest.usages.first { $0.id == instance } }
    private var usage: AgentUsage? { current ?? lastKnown }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text((usage?.kind.rawValue.uppercased() ?? "AGENT") + " // INSPECTOR")
                        .font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(AgentsStyle.cyan)
                    Text("ROOT #\(instance.pid) · PROCESS TREE TELEMETRY").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(!model.latest.available ? "读取失败 · 保留快照" : current == nil ? "实例已退出 · 最后快照" : "LIVE / \(model.latest.time.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(AgentsStyle.green)
            }
            TextField("搜索进程名、PID、路径", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let usage {
                        GroupBox("INSTANCE / 实例汇总") {
                            VStack(spacing: 0) {
                                row("启动时间", started(instance.started))
                                row("运行时长", duration(max(0, model.latest.time.timeIntervalSince1970 - Double(instance.started) / 1e6)))
                                row("进程数 / 线程数", "\(usage.processes.count) / \(usage.processes.compactMap { $0.detail?.threads }.reduce(0, +))（可读项合计）")
                                row("CPU / 整机占比", usage.cpu.map { String(format: "%.2f%% / %.2f%%", $0, $0 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))) } ?? "建立基线 / 不可读")
                                row("RSS / 物理足迹合计", bytes(usage.memory) + " / " + sum(usage.processes.compactMap { $0.detail?.footprint }))
                                row("磁盘读 / 写速率", MetricsFormat.rate(usage.readRate) + " / " + MetricsFormat.rate(usage.writeRate))
                                row("采样覆盖", usage.partial ? "部分指标缺失或新进程正在建立基线" : "CPU 与 RSS 已覆盖所有成员")
                            }.padding(8)
                        }
                        Text("PROCESS TREE / 按父子关系排列，展开查看每个进程")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(AgentsStyle.cyan)
                        ForEach(ordered(usage)) { process in
                            if matches(process) {
                                DisclosureGroup {
                                    processDetails(process).padding(.top, 8)
                                } label: {
                                    HStack {
                                        Text(String(repeating: "  ", count: min(8, depth(process, usage))) + (process.id == instance ? "◆ " : "└ ") + process.name)
                                        Spacer()
                                        Text("#\(process.id.pid)")
                                        Text(process.cpu.map { String(format: "%.1f%%", $0) } ?? "—").frame(width: 65, alignment: .trailing)
                                        Text(bytes(process.memory)).frame(width: 90, alignment: .trailing)
                                    }.font(.system(size: 11, design: .monospaced))
                                }.padding(12).background(AgentsStyle.card, in: RoundedRectangle(cornerRadius: 3)).tint(AgentsStyle.cyan)
                            }
                        }
                    } else {
                        Text("正在等待实例数据；实例可能已经退出。")
                    }
                    GroupBox("采集范围与口径") {
                        Text("当前用户的本地进程及子进程。CPU 单核 100%，RSS 和物理足迹相加可能包含共享资源；虚拟内存不代表实际占用。磁盘计数为进程生命周期累计值，速度为两次采样增量。线程状态是采样瞬间值，BSD 状态不能证明 Agent 正在执行任务。\n\n未接入：会话、任务内容、模型、Token、费用、工具调用、远程 Agent、单进程网速。不会读取或展示提示词、完整命令参数和环境变量。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }.padding(.vertical, 3)
            }
        }.padding(20).frame(minWidth: 650, minHeight: 450).background(AgentsStyle.background).preferredColorScheme(.dark)
            .onAppear { if let current { lastKnown = current } }
            .onReceive(model.$latest) { snapshot in
                if let value = snapshot.usages.first(where: { $0.id == instance }) { lastKnown = value }
            }
    }
    private func processDetails(_ p: AgentProcessUsage) -> some View {
        VStack(spacing: 0) {
            row("PID / PPID / UID", "\(p.id.pid) / \(p.detail.map { String($0.parent) } ?? "—") / \(p.detail.map { String($0.uid) } ?? "—")")
            row("启动时间", started(p.id.started))
            row("可执行文件", p.detail?.executable.isEmpty == false ? p.detail!.executable : "不可读")
            row("脚本 / 模块入口", p.detail?.entrypoint.isEmpty == false ? p.detail!.entrypoint : "未提供 / 原生进程")
            row("BSD 状态", p.detail.map { state($0.status) } ?? "不可读")
            row("线程 / 运行线程 / 优先级", number(p.detail?.threads) + " / " + number(p.detail?.runningThreads) + " / " + number(p.detail?.priority))
            row("RSS / 物理足迹 / 虚拟内存", bytes(p.memory) + " / " + bytes(p.detail?.footprint) + " / " + bytes(p.detail?.virtualBytes))
            row("累计用户 / 内核 CPU 时间", seconds(p.detail?.userNS) + " / " + seconds(p.detail?.systemNS))
            row("磁盘累计读 / 写", bytes(p.detail?.readBytes) + " / " + bytes(p.detail?.writtenBytes))
            row("磁盘读 / 写速率", MetricsFormat.rate(p.readRate) + " / " + MetricsFormat.rate(p.writeRate))
            row("缺页 / 页入 / 上下文切换累计", number(p.detail?.faults) + " / " + number(p.detail?.pageins) + " / " + number(p.detail?.switches))
        }.textSelection(.enabled)
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 165, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11, design: .monospaced)).padding(.vertical, 6).textSelection(.enabled)
    }
    private func matches(_ p: AgentProcessUsage) -> Bool {
        query.isEmpty || "\(p.name) \(p.id.pid) \(p.detail?.executable ?? "") \(p.detail?.entrypoint ?? "")".localizedCaseInsensitiveContains(query)
    }
    private func depth(_ p: AgentProcessUsage, _ usage: AgentUsage) -> Int {
        let byPID = Dictionary(uniqueKeysWithValues: usage.processes.map { ($0.id.pid, $0) })
        var parent = p.detail?.parent ?? 0, visited: Set<Int32> = [p.id.pid], result = 0
        while let ancestor = byPID[parent], visited.insert(parent).inserted {
            result += 1; parent = ancestor.detail?.parent ?? 0
        }
        return result
    }
    private func ordered(_ usage: AgentUsage) -> [AgentProcessUsage] {
        let byPID = Dictionary(uniqueKeysWithValues: usage.processes.map { ($0.id.pid, $0) })
        let children = Dictionary(grouping: usage.processes, by: { $0.detail?.parent ?? 0 })
        var result: [AgentProcessUsage] = [], visited: Set<AgentProcessID> = []
        func append(_ p: AgentProcessUsage) {
            guard visited.insert(p.id).inserted else { return }
            result.append(p)
            for child in (children[p.id.pid] ?? []).sorted(by: { $0.id.pid < $1.id.pid }) { append(child) }
        }
        if let root = byPID[instance.pid] { append(root) }
        for p in usage.processes.sorted(by: { $0.id.pid < $1.id.pid }) { append(p) }
        return result
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
