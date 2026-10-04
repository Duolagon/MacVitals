import SwiftUI
import Darwin
import IOKit
import CMetrics

struct DetailEntry: Identifiable {
    var id: String { label }
    let label: String
    let value: String
}
struct DetailSection: Identifiable {
    var id: String { title }
    let title: String
    let rows: [DetailEntry]
}
final class DetailsMonitor {
    private var sensorKeys: [String] = []
    private let host = HostPort()
    private var networkTracker = CounterTracker()
    private var processOld: [Int32: (UInt64, UInt64)] = [:]
    private var diskTracker = CounterTracker()
    private var coreOld: [[UInt32]]?
    private var lastTime: TimeInterval?
    private let chip: String
    private let modelName = DetailsMonitor.sysString("hw.model")
    private let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
    init() {
        chip = Self.sysString("machdep.cpu.brand_string")
        for i in 0..<mv_smc_key_count() {
            var key = [CChar](repeating: 0, count: 5)
            if mv_smc_key_at(i, &key) != 0 {
                let name = String(cString: key)
                if name.hasPrefix("T") { sensorKeys.append(name) }
            }
        }
    }
    func resetRates() {
        lastTime = nil; coreOld = nil; processOld.removeAll()
        networkTracker = CounterTracker(); diskTracker = CounterTracker()
    }
    func sample(_ snapshot: Snapshot) -> [DetailSection] {
        let time = ProcessInfo.processInfo.systemUptime
        let elapsed = lastTime.map { max(0.001, time - $0) }
        lastTime = time
        func row(_ label: String, _ value: String) -> DetailEntry { DetailEntry(label: label, value: value) }
        func section(_ title: String, _ rows: [DetailEntry]) -> DetailSection { DetailSection(title: title, rows: rows) }
        var result: [DetailSection] = []
        var load = [Double](repeating: 0, count: 3); _ = getloadavg(&load, 3)
        result.append(section("系统与 CPU", [row("芯片", chip), row("机型", modelName), row("系统", systemVersion), row("核心", "\(ProcessInfo.processInfo.activeProcessorCount) / \(ProcessInfo.processInfo.processorCount) 个启用 / 总逻辑核心"), row("CPU 利用率", snapshot.cpu.map { String(format: "%.1f%%", $0) } ?? "采样中"), row("用户 / 系统占用", snapshot.cpuUser.flatMap { u in snapshot.cpuSystem.map { String(format: "%.1f%% / %.1f%%", u, $0) } } ?? "采样中"), row("负载均值 · 1/5/15 分钟", load.map { String(format: "%.2f", $0) }.joined(separator: " / ")), row("运行时间", snapshot.uptime), row("热状态", thermal())]))
        let power = PowerMetrics.load()
        result.append(section("CPU 每核利用率", coreUsage()))
        result.append(section("CPU 频率与功耗", power.cpuRows))
        result.append(section("芯片功耗 · 系统估算", power.summary))
        result.append(section("内存", memory(snapshot)))
        let temperatures = sensorKeys.compactMap { key -> DetailEntry? in
            let value = mv_smc_read(key)
            guard value > 0 && value < 130 else { return nil }
            let label: String
            if chip.contains("M5") && key == "Tp00" { label = "CPU 超级核心区域 · Tp00" }
            else if ["TB0T", "TB1T", "TB2T"].contains(key) { label = "电池 · \(key)" }
            else { label = key }
            return row(label, String(format: "%.1f °C", value))
        }
        let groups: [(String, (String) -> Bool)] = [
            ("CPU 温度候选 · Tp*", { $0.hasPrefix("Tp") }),
            ("GPU 温度候选 · Tg*", { $0.hasPrefix("Tg") }),
            ("内存温度候选 · Tm*", { $0.hasPrefix("Tm") }),
            ("电池温度 · TB*T", { $0.hasPrefix("TB") }),
            ("存储温度候选 · TH*", { $0.hasPrefix("TH") })
        ]
        for (title, match) in groups {
            let entries = temperatures.filter { entry in sensorKeys.contains { match($0) && entry.label.hasSuffix($0) } }
            result.append(section(title, entries.isEmpty ? [row("状态", "没有可解码的有效读数")] : entries))
        }
        let known = Set(temperatures.filter { e in groups.contains { _, match in sensorKeys.contains { match($0) && e.label.hasSuffix($0) } } }.map(\.id))
        result.append(section("其他温度传感器 · 位置未确认", temperatures.filter { !known.contains($0.id) }))
        result.append(section("网络 · 接口分别统计，勿直接相加", networks(elapsed)))
        result.append(section("磁盘", disks(snapshot, elapsed)))
        result.append(section("电池", battery(snapshot)))
        result.append(section("风扇", fans(snapshot)))
        result.append(section("GPU", gpu() + power.gpuRows))
        result.append(contentsOf: processes(elapsed))
        return result
    }
    private func coreUsage() -> [DetailEntry] {
        var cpuCount: natural_t = 0
        var data: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(host.port, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &data, &count) == KERN_SUCCESS, let data else { coreOld = nil; return [.init(label: "状态", value: "系统未提供")] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: data)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        let cores = (0..<Int(cpuCount)).map { i in (0..<4).map { UInt32(bitPattern: data[i*4+$0]) } }
        defer { coreOld = cores }
        return cores.enumerated().map { i, ticks in
            guard let old = coreOld, i < old.count else { return .init(label: "CPU \(i)", value: "采样中") }
            let delta = zip(ticks, old[i]).map { UInt64($0 &- $1) }
            let total = delta.reduce(0, +)
            return .init(label: "CPU \(i)", value: total > 0 ? String(format: "%.1f%%", Double(total-delta[2])/Double(total)*100) : "无新增采样")
        }
    }
    private func memory(_ snapshot: Snapshot) -> [DetailEntry] {
        var v = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &v) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host.port, HOST_VM_INFO64, $0, &count) } }
        var rows = [DetailEntry(label: "占用估算", value: snapshot.memory), DetailEntry(label: "交换已使用", value: snapshot.swap), DetailEntry(label: "交换当前分配", value: snapshot.swapAllocated)]
        if ok == KERN_SUCCESS {
            let metrics: [(String, UInt64)] = [("活动页", UInt64(v.active_count)), ("非活动页", UInt64(v.inactive_count)), ("Wired", UInt64(v.wire_count)), ("压缩器物理占用", UInt64(v.compressor_page_count)), ("压缩前逻辑大小", v.total_uncompressed_pages_in_compressor), ("文件缓存页", UInt64(v.external_page_count)), ("空闲页", UInt64(v.free_count))]
            rows += metrics.map { DetailEntry(label: $0.0, value: bytes($0.1 * UInt64(vm_kernel_page_size))) }
        }
        let pressure = Self.sysInt("kern.memorystatus_vm_pressure_level")
        rows.append(DetailEntry(label: "内存压力", value: [1:"正常", 2:"警告", 4:"严重"][pressure] ?? "系统未提供"))
        return rows
    }
    private func networks(_ elapsed: Double?) -> [DetailEntry] {
        var buffer = [MVNetwork](repeating: MVNetwork(), count: 64)
        let count = mv_network(&buffer, Int32(buffer.count))
        guard count >= 0 else { _ = networkTracker.sample([:], elapsed: nil); return [.init(label: "状态", value: "读取失败")] }
        var current: [String: ByteCounters] = [:]
        for var n in buffer.prefix(Int(count)) { current["\(cString(&n.name))#\(n.index)"] = ByteCounters(received: n.received, sent: n.sent) }
        let rates = networkTracker.sample(current, elapsed: elapsed)
        let rows: [DetailEntry] = buffer.prefix(Int(count)).map { original in
            var n = original
            let name = cString(&n.name), ip = cString(&n.address)
            let speed = rates["\(name)#\(n.index)"].map { "↓ \(bytes(UInt64($0.received)))/s  ↑ \(bytes(UInt64($0.sent)))/s" } ?? "速度采样中（首次读取或计数器重置）"
            return .init(label: name, value: "\(ip.isEmpty ? "无 IPv4" : ip)\n\(speed)\n接口累计 ↓ \(bytes(n.received)) ↑ \(bytes(n.sent))")
        }
        return rows.isEmpty ? [.init(label: "状态", value: "无活动网络接口")] : rows + [.init(label: "统计口径", value: "使用系统 64 位接口计数。包含虚拟接口，可能重复计算流量，勿相加。")]
    }
    private func disks(_ snapshot: Snapshot, _ elapsed: Double?) -> [DetailEntry] {
        var rows = [DetailEntry(label: "主目录所在卷", value: snapshot.disk)]
        var counters: [String: ByteCounters] = [:]
        for d in registry("IOBlockStorageDriver") {
            guard let id = d["_RegistryID"] as? String, let stats = d["Statistics"] as? [String: Any], let read = stats["Bytes (Read)"] as? NSNumber, let written = stats["Bytes (Write)"] as? NSNumber else { continue }
            counters[id] = ByteCounters(received: read.uint64Value, sent: written.uint64Value)
        }
        let rates = diskTracker.sample(counters, elapsed: elapsed)
        guard !counters.isEmpty else { return rows + [.init(label: "磁盘读写速度", value: "系统未提供统计")] }
        if rates.isEmpty { rows.append(.init(label: "磁盘读写速度", value: "采样中（首次读取或设备变更）")) }
        else {
            let read = rates.values.reduce(0) { $0+$1.received }, written = rates.values.reduce(0) { $0+$1.sent }
            rows.append(.init(label: "已连续采样驱动器", value: "读 \(bytes(UInt64(read)))/s · 写 \(bytes(UInt64(written)))/s"))
        }
        let read = counters.values.reduce(UInt64(0)) { $0+$1.received }, written = counters.values.reduce(UInt64(0)) { $0+$1.sent }
        rows.append(.init(label: "当前驱动器累计读 / 写", value: "\(bytes(read)) / \(bytes(written))"))
        return rows
    }
    private func battery(_ snapshot: Snapshot) -> [DetailEntry] {
        var rows = [DetailEntry(label: "状态", value: snapshot.battery)]
        guard let d = registry("AppleSmartBattery").first else { return rows + [.init(label: "健康信息", value: "无电池或系统未提供")] }
        let batteryData = d["BatteryData"] as? [String: Any] ?? [:]
        func n(_ key: String) -> Double? { ((d[key] ?? batteryData[key]) as? NSNumber)?.doubleValue }
        let full = n("AppleRawMaxCapacity") ?? n("FullChargeCapacity") ?? n("NominalChargeCapacity")
        for (label, key, unit) in [("循环次数", "CycleCount", "次"), ("设计容量", "DesignCapacity", "mAh"), ("当前满充容量", "FullChargeCapacity", "mAh")] {
            rows.append(.init(label: label, value: n(key).map { "\(Int($0)) \(unit)" } ?? "不可用"))
        }
        if let max = full, let design = n("DesignCapacity"), design > 0 { rows.append(.init(label: "容量健康估算", value: String(format: "%.1f%%（原始满充 / 设计容量）", max/design*100))) }
        let voltage = n("Voltage").map { $0/1000 }
        let current: Double? = (d["Amperage"] as? NSNumber).map { Double(Int16(truncatingIfNeeded: $0.int64Value))/1000 }
        rows.append(.init(label: "电压", value: voltage.map { String(format: "%.2f V", $0) } ?? "不可用"))
        rows.append(.init(label: "电流", value: current.map { String(format: "%.3f A", $0) } ?? "不可用"))
        if let voltage, let current { rows.append(.init(label: "电池侧功率估算", value: String(format: "%.2f W（正充电 / 负放电）", voltage*current))) }
        rows.append(.init(label: "剩余时间估算", value: n("TimeRemaining").flatMap { $0 > 0 && $0 < 65535 ? "\(Int($0)) 分钟" : nil } ?? "系统未提供有效估算"))
        return rows
    }
    private func fans(_ snapshot: Snapshot) -> [DetailEntry] {
        let count = mv_smc_read("FNum")
        guard count > 0 && count <= 16 else { return [.init(label: "状态", value: snapshot.fans)] }
        return (0..<Int(count)).map { i in
            let values = [("当前", "Ac"), ("最低", "Mn"), ("最高", "Mx")].map { label, suffix in
                let v = mv_smc_read("F\(i)\(suffix)")
                return "\(label) \(v >= 0 && v < 30000 ? "\(Int(v)) RPM" : "不可用")"
            }
            return .init(label: "风扇 \(i+1)", value: values.joined(separator: " · "))
        }
    }
    private func gpu() -> [DetailEntry] {
        let stats = registry("IOAccelerator").compactMap { $0["PerformanceStatistics"] as? [String: Any] }
        let value = stats.compactMap { ($0["Device Utilization %"] as? NSNumber)?.doubleValue }.first
        return [.init(label: "利用率", value: value.map { String(format: "%.1f%%", $0) } ?? "当前驱动未提供")]
    }
    private func processes(_ elapsed: Double?) -> [DetailSection] {
        var buffer = [MVProcess](repeating: MVProcess(), count: 4096)
        let count = mv_processes(&buffer, Int32(buffer.count))
        guard count >= 0 else { processOld = [:]; return [.init(title: "进程", rows: [.init(label: "状态", value: "读取失败")])] }
        var values: [(String, Double?, UInt64)] = []; var next: [Int32: (UInt64, UInt64)] = [:]
        for var p in buffer.prefix(Int(count)) {
            let old = processOld[p.pid]
            let cpu = old.flatMap { old -> Double? in guard let elapsed, p.started == old.1, p.cpu_ns >= old.0 else { return nil }; return Double(p.cpu_ns-old.0)/1e9/elapsed*100 }
            let name = cString(&p.name)
            values.append(("\(name.isEmpty ? "进程" : name) · \(p.pid)", cpu, p.resident)); next[p.pid] = (p.cpu_ns, p.started)
        }
        processOld = next
        let cpuRows = values.filter { $0.1 != nil }.sorted { ($0.1 ?? 0) > ($1.1 ?? 0) }.prefix(5).map { DetailEntry(label: $0.0, value: String(format: "%.1f%%", $0.1 ?? 0)) }
        let memoryRows = values.sorted { $0.2 > $1.2 }.prefix(5).map { DetailEntry(label: $0.0, value: bytes($0.2)) }
        return [.init(title: "高 CPU 进程 · 单核 100%，可超过 100%", rows: cpuRows.isEmpty ? [.init(label: "状态", value: "采样中；仅列出可读取进程")] : cpuRows), .init(title: "高内存进程 · 驻留内存", rows: memoryRows)]
    }
    private func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState { case .nominal: return "正常"; case .fair: return "稍热"; case .serious: return "较热"; case .critical: return "严重"; @unknown default: return "未知" }
    }
    private func registry(_ className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while true {
            let service = IOIteratorNext(iterator); if service == 0 { break }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS, var d = properties?.takeRetainedValue() as? [String: Any] {
                var id: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS { d["_RegistryID"] = String(id) }
                result.append(d)
            }
            IOObjectRelease(service)
        }
        return result
    }
    private func cString<T>(_ value: inout T) -> String { withUnsafePointer(to: &value) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } } }
    private func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(n, UInt64(Int64.max))), countStyle: .memory) }
    private static func sysString(_ name: String) -> String { var size = 0; guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "未知" }; var buffer = [CChar](repeating: 0, count: size); guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "未知" }; return String(cString: buffer) }
    private static func sysInt(_ name: String) -> Int { var value: Int32 = 0; var size = MemoryLayout<Int32>.size; return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : -1 }
}


struct DetailsView: View {
    @ObservedObject var model: DashboardModel
    @State private var query = ""
    @State private var expanded: Set<String> = ["系统与 CPU", "芯片功耗 · 系统估算", "内存", "磁盘", "电池", "风扇", "GPU"]
    private var visibleSections: [DetailSection] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return model.details }
        return model.details.compactMap { section in
            if section.title.localizedCaseInsensitiveContains(text) { return section }
            let rows = section.rows.filter { $0.label.localizedCaseInsensitiveContains(text) || $0.value.localizedCaseInsensitiveContains(text) }
            return rows.isEmpty ? nil : DetailSection(title: section.title, rows: rows)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2").font(.system(size: 22)).foregroundStyle(MonitorStyle.blue)
                    .frame(width: 44, height: 44).background(MonitorStyle.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("系统详情").font(.system(size: 23, weight: .semibold))
                    Text("MacVitals · 每 5 秒刷新").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索指标或数值", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }.font(.system(size: 12)).padding(10).frame(width: 210)
                    .background(MonitorStyle.card, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(MonitorStyle.border))
            }.padding(22)
            Divider().overlay(MonitorStyle.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(query.isEmpty ? "全部指标" : "搜索结果").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(visibleSections.reduce(0) { $0 + $1.rows.count }) 项").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("全部展开") { expanded = Set(model.details.map { $0.id }) }.buttonStyle(.borderless).font(.system(size: 11))
                        Button("收起") { expanded = [] }.buttonStyle(.borderless).font(.system(size: 11)).disabled(!query.isEmpty)
                    }
                    ForEach(visibleSections) { section in
                        DisclosureGroup(isExpanded: Binding(get: { !query.isEmpty || expanded.contains(section.id) }, set: { if $0 { expanded.insert(section.id) } else { expanded.remove(section.id) } })) {
                            VStack(spacing: 0) {
                                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, entry in
                                    HStack(alignment: .top, spacing: 20) {
                                        Text(entry.label).foregroundStyle(.secondary).frame(width: 210, alignment: .leading)
                                        Text(entry.value).fontWeight(.medium).monospacedDigit()
                                            .frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
                                    }.font(.system(size: 12)).padding(.vertical, 10).padding(.horizontal, 8)
                                        .background(index.isMultiple(of: 2) ? Color.white.opacity(0.025) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }
                                if section.title.contains("温度") {
                                    Text("温度按 SMC 候选键分组，分组不代表已确认的物理位置；Tp00 使用 M5 CPU 区域映射。")
                                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                                }
                            }.padding(.top, 10)
                        } label: {
                            HStack(spacing: 8) {
                                Text(section.title).font(.system(size: 13, weight: .semibold))
                                Text("\(section.rows.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }.tint(MonitorStyle.blue).modifier(MonitorCard())
                    }
                    if model.details.isEmpty {
                        ProgressView("正在采集系统指标…").frame(maxWidth: .infinity).padding(40)
                    } else if visibleSections.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: 25)).foregroundStyle(.secondary)
                            Text("没有匹配的指标").font(.system(size: 14, weight: .medium))
                            Text("尝试搜索 CPU、温度、网络或传感器键名").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(40)
                    }
                }.padding(22)
            }
            HStack {
                Label("只读系统采集", systemImage: "checkmark.shield").font(.system(size: 10))
                Spacer()
                Text("最近更新 " + model.detailsUpdated.formatted(date: .omitted, time: .standard)).font(.system(size: 10)).monospacedDigit()
            }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(MonitorStyle.border).frame(height: 1) }
        }.frame(minWidth: 660, minHeight: 550)
            .background(MonitorStyle.background).preferredColorScheme(.dark)
    }
}
