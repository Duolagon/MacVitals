import Foundation
import Darwin

/// A short-lived advisory lease; the privileged collector never executes or reads app code.
final class PowerSamplingDemand {
    let fileURL: URL
    private var active = false
    private var cadence = SampleCadence(interval: 20)
    init(fileURL: URL = URL(fileURLWithPath: "/tmp/local.macvitals.power-demand.\(getpid())")) { self.fileURL = fileURL }
    func start() { active = true; renew(force: true) }
    func renew(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, force: Bool = false) {
        guard active, cadence.shouldRefresh(at: uptime, force: force) else { return }
        do {
            try Data("active\n".utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { NSLog("MacVitals power demand: %@", error.localizedDescription) }
    }
    func stop() { active = false; try? FileManager.default.removeItem(at: fileURL) }
    deinit { stop() }
}

struct PowerMetrics {
    static let path = "/var/run/local.macvitals.power/sample.plist"
    var cpuRows: [DetailEntry] = []
    var gpuRows: [DetailEntry] = []
    var summary: [DetailEntry] = []
    static func load() -> PowerMetrics {
        var result = PowerMetrics()
        func unavailable(_ message: String) -> PowerMetrics {
            let rows = [DetailEntry(label: "管理员采集", value: message)]
            return PowerMetrics(cpuRows: rows, gpuRows: rows, summary: rows)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let size = attributes[.size] as? NSNumber, size.intValue <= 1_000_000, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return unavailable("等待管理员采集服务的首次读数")
        }
        // powermetrics plist frames terminate with NUL.
        let frame = Array(data).split(separator: UInt8(0)).last.map { Data($0) } ?? data
        guard let dict = (try? PropertyListSerialization.propertyList(from: frame, format: nil)) as? [String: Any], let timestamp = dict["timestamp"] as? Date else { return unavailable("采集结果格式不受支持") }
        let age = Date().timeIntervalSince(timestamp)
        guard age >= -5 && age < 90 else { return unavailable("等待按需功耗采样（采集间隔约 30 秒）") }
        let processor = dict["processor"] as? [String: Any] ?? [:]
        let gpu = dict["gpu"] as? [String: Any] ?? [:]
        func n(_ d: [String: Any], _ key: String) -> Double? {
            guard let value = (d[key] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }; return value
        }
        func watts(_ key: String) -> String { n(processor, key).map { String(format: "%.2f W", $0 / 1000) } ?? "未提供" }
        func frequency(_ d: [String: Any], cpu: Bool) -> String {
            guard let raw = n(d, "freq_hz") else { return "未提供" }
            if raw == 0 { return "休眠 / 无活跃频率" }
            // This macOS build reports CPU freq_hz in Hz but GPU freq_hz in MHz.
            // Compare GPU frequency with its MHz DVFM table to support both schemas.
            let states = d["dvfm_states"] as? [[String: Any]] ?? []
            let maxMHz = states.compactMap { n($0, "freq") }.max()
            let mhz = cpu ? raw / 1e6 : (maxMHz.map { raw <= $0 * 1.1 ? raw : raw / 1e6 } ?? raw / 1e6)
            return String(format: "%.0f MHz", mhz)
        }
        result.cpuRows = [.init(label: "CPU 功耗估算", value: watts("cpu_power"))]
        let clusters = processor["clusters"] as? [[String: Any]] ?? []
        for cluster in clusters {
            let name = cluster["name"] as? String ?? "核心簇"
            result.cpuRows.append(.init(label: "\(name) · 有效频率", value: frequency(cluster, cpu: true)))
            for core in cluster["cpus"] as? [[String: Any]] ?? [] {
                if let id = n(core, "cpu") { result.cpuRows.append(.init(label: "CPU \(Int(id)) · 有效频率", value: frequency(core, cpu: true))) }
            }
        }
        result.gpuRows = [.init(label: "GPU 有效频率", value: frequency(gpu, cpu: false)), .init(label: "GPU 功耗估算", value: watts("gpu_power"))]
        result.summary = [.init(label: "CPU", value: watts("cpu_power")), .init(label: "GPU", value: watts("gpu_power")), .init(label: "神经引擎 ANE", value: watts("ane_power")), .init(label: "CPU + GPU + ANE 合计", value: watts("combined_power")), .init(label: "整机功耗", value: "系统未提供；芯片合计不包含屏幕等部件"), .init(label: "采样口径", value: "仅详情可见时请求，约每 30 秒采集 1 秒窗口；功耗为系统估算，频率为活跃期间的有效频率"), .init(label: "采样时间", value: timestamp.formatted(date: .omitted, time: .standard))]
        return result
    }
}
