import Darwin

/// Owns one host send-right reference for the entire sampler lifetime.
final class HostPort {
    let port = mach_host_self()
    deinit { mach_port_deallocate(mach_task_self_, port) }
}
struct ByteCounters: Equatable {
    let received: UInt64
    let sent: UInt64
}
struct ByteRate: Equatable {
    let received: Double
    let sent: Double
}
struct CounterTracker {
    private var previous: [String: ByteCounters] = [:]
    mutating func sample(_ current: [String: ByteCounters], elapsed: Double?) -> [String: ByteRate] {
        defer { previous = current }
        guard let elapsed, elapsed.isFinite, elapsed > 0 else { return [:] }
        var rates: [String: ByteRate] = [:]
        for (id, value) in current {
            guard let old = previous[id], value.received >= old.received, value.sent >= old.sent else { continue }
            rates[id] = ByteRate(received: Double(value.received-old.received)/elapsed, sent: Double(value.sent-old.sent)/elapsed)
        }
        return rates
    }
}
