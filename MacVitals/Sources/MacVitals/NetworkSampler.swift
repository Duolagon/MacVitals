import Foundation
import SystemConfiguration
import CMetrics

struct NetworkReading {
    var interface = "无活动网络"
    var download: Double?
    var upload: Double?
}
struct NetworkInterfaceReading {
    let name: String
    let index: UInt32
    let address: String
    let counters: ByteCounters
    var id: String { "\(name)#\(index)" }
}
final class NetworkSampler {
    private let store = SCDynamicStoreCreate(nil, "MacVitals" as CFString, nil, nil)
    private var tracker = CounterTracker()
    private var lastTime: TimeInterval?
    private var selectedID: String?
    func sample() -> NetworkReading {
        let time = ProcessInfo.processInfo.systemUptime
        let elapsed = lastTime.map { time-$0 }
        lastTime = time
        var buffer = [MVNetwork](repeating: MVNetwork(), count: 64)
        let count = mv_network(&buffer, Int32(buffer.count))
        guard count >= 0 else {
            _ = tracker.sample([:], elapsed: nil); selectedID = nil
            return NetworkReading(interface: "网络读取失败")
        }
        let interfaces = buffer.prefix(Int(count)).map { original -> NetworkInterfaceReading in
            var n = original
            func string<T>(_ value: inout T) -> String { withUnsafePointer(to: &value) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } } }
            return NetworkInterfaceReading(name: string(&n.name), index: n.index, address: string(&n.address), counters: .init(received: n.received, sent: n.sent))
        }
        let rates = tracker.sample(Dictionary(uniqueKeysWithValues: interfaces.map { ($0.id, $0.counters) }), elapsed: elapsed)
        var primary: String?
        if let store {
            for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
                if let info = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any], let name = info["PrimaryInterface"] as? String { primary = name; break }
            }
        }
        guard let selected = Self.select(interfaces, primary: primary) else { selectedID = nil; return NetworkReading() }
        let sameInterface = selectedID == selected.id
        selectedID = selected.id
        let rate = sameInterface ? rates[selected.id] : nil
        return NetworkReading(interface: selected.name, download: rate?.received, upload: rate?.sent)
    }
    /// Prefer a single primary physical interface to avoid VPN double counting.
    static func select(_ interfaces: [NetworkInterfaceReading], primary: String?) -> NetworkInterfaceReading? {
        if let selected = interfaces.first(where: { $0.name == primary && $0.name.hasPrefix("en") }) { return selected }
        if let physical = interfaces.filter({ $0.name.hasPrefix("en") && !$0.address.isEmpty }).sorted(by: { $0.name < $1.name }).first { return physical }
        if let selected = interfaces.first(where: { $0.name == primary }) { return selected }
        return nil
    }
}
