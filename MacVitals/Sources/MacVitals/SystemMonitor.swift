import Foundation
import Darwin
import IOKit.ps
import CMetrics

struct Snapshot {
    var cpu: Double? = nil
    var cpuUser: Double?
    var cpuSystem: Double?
    var memory = "读取中…"
    var memoryPercent: Double?
    var fanRPM: Double?
    var temperatureC: Double?
    var swap = "不可用"
    var swapAllocated = "不可用"
    var downloadBytesPerSecond: Double?
    var uploadBytesPerSecond: Double?
    var networkInterface = "采样中"
    var networkIPv4 = ""
    var networkIPv6 = ""
    var diskAvailableBytes: UInt64?
    var diskTotalBytes: UInt64?
    var batteryPercent: Double?
    var batteryCharging = false
    var disk = "不可用"
    var battery = "无电池或不可用"
    var fans = "不可用（无风扇或系统未开放）"
    var temperature = "不可用"
    var uptime = ""
}
struct DiskCapacityReading { let available: UInt64, total: UInt64 }
struct BatteryStatusReading { let percent: Double; let charging: Bool; let description: String }
final class Monitor {
    private let host = HostPort()
    private let network = NetworkSampler()
    private var previous: [UInt32]?
    private var slowCadence: SampleCadence
    private var slow = Snapshot()
    private let diskReader: () -> DiskCapacityReading?
    private let batteryReader: () -> BatteryStatusReading?
    private let totalMemory = ProcessInfo.processInfo.physicalMemory
    init(slowInterval: TimeInterval = 15, diskReader: @escaping () -> DiskCapacityReading? = Monitor.readDisk,
         batteryReader: @escaping () -> BatteryStatusReading? = Monitor.readBattery) {
        slowCadence = SampleCadence(interval: slowInterval)
        self.diskReader = diskReader; self.batteryReader = batteryReader
    }
    func sample(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, forceSlow: Bool = false) -> Snapshot {
        var s = Snapshot()
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host.port, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let ticks: [UInt32] = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
            if let old = previous {
                let delta = zip(ticks, old).map { UInt64($0 &- $1) }
                let total = delta.reduce(0, +)
                if total > 0 { s.cpu = Double(total - delta[2]) / Double(total) * 100; s.cpuUser = Double(delta[0] + delta[3]) / Double(total) * 100; s.cpuSystem = Double(delta[1]) / Double(total) * 100 }
            }
            previous = ticks
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host.port, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        s.memory = "不可用"
        if vmResult == KERN_SUCCESS {
            let used = (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count) - min(UInt64(vm.active_count), UInt64(vm.purgeable_count))) * UInt64(vm_kernel_page_size)
            let total = totalMemory
            s.memoryPercent = min(100, Double(used) / Double(total) * 100)
            s.memory = "\(bytes(used)) / \(bytes(total))（\(Int(s.memoryPercent ?? 0))%）"
        }
        var swap = xsw_usage(); var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            s.swap = swap.xsu_used == 0 ? "0 B（未使用）" : MetricsFormat.bytes(swap.xsu_used)
            s.swapAllocated = MetricsFormat.bytes(swap.xsu_total)
        }
        let networkReading = network.sample()
        s.networkInterface = networkReading.interface
        s.networkIPv4 = networkReading.ipv4
        s.networkIPv6 = networkReading.ipv6
        s.downloadBytesPerSecond = networkReading.download
        s.uploadBytesPerSecond = networkReading.upload
        if slowCadence.shouldRefresh(at: uptime, force: forceSlow) {
            slow = Snapshot()
            if let disk = diskReader() {
                slow.diskAvailableBytes = disk.available; slow.diskTotalBytes = disk.total
                slow.disk = "可用 \(bytes(disk.available)) / \(bytes(disk.total))"
            }
            if let battery = batteryReader() {
                slow.batteryPercent = battery.percent; slow.batteryCharging = battery.charging; slow.battery = battery.description
            }
        }
        s.diskAvailableBytes = slow.diskAvailableBytes; s.diskTotalBytes = slow.diskTotalBytes; s.disk = slow.disk
        s.batteryPercent = slow.batteryPercent; s.batteryCharging = slow.batteryCharging; s.battery = slow.battery
        let fanCount = mv_smc_read("FNum")
        if fanCount >= 0 && fanCount <= 16 {
            if fanCount == 0 { s.fans = "设备无风扇" }
            else {
                var speeds: [Double] = []
                s.fans = (0..<Int(fanCount)).map { index in
                    let rpm = mv_smc_read("F\(index)Ac")
                    if rpm >= 0 && rpm < 30000 { speeds.append(rpm) }
                    return "风扇 \(index + 1)：\(rpm >= 0 && rpm < 30000 ? "\(Int(rpm)) RPM" : "不可用")"
                }.joined(separator: " · ")
                s.fanRPM = speeds.max()
            }
        }
        for key in ["TC0P", "TC0D", "Tp09", "Tp0T", "Tp01", "Tp00"] {
            let t = mv_smc_read(key)
            if t > 0 && t < 130 { s.temperatureC = t; s.temperature = String(format: "%.1f °C（%@）", t, key); break }
        }
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        s.uptime = "\(seconds / 86400) 天 \(seconds / 3600 % 24) 小时 \(seconds / 60 % 60) 分钟"
        return s
    }
    static func readDisk() -> DiskCapacityReading? {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return .init(available: UInt64(max(0, free)), total: UInt64(max(0, total)))
    }
    static func readBattery() -> BatteryStatusReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let maximum = d[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let state = d[kIOPSPowerSourceStateKey] as? String ?? ""
            let percent = min(100, max(0, Double(current) * 100 / Double(maximum)))
            return .init(percent: percent, charging: charging,
                         description: "\(Int(percent))% · \(charging ? "充电中" : state == kIOPSACPowerValue ? "接通电源" : "使用电池")")
        }
        return nil
    }
    private func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(n, UInt64(Int64.max))), countStyle: .memory)
    }
}
