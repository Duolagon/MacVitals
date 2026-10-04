import Foundation

struct SampleCadence {
    let interval: TimeInterval
    private var last: TimeInterval?
    init(interval: TimeInterval) { self.interval = interval.isFinite && interval > 0 ? interval : 15 }
    mutating func shouldRefresh(at time: TimeInterval, force: Bool = false) -> Bool {
        guard time.isFinite else { return false }
        if force || last == nil || time < last! || time - last! >= interval {
            last = time; return true
        }
        return false
    }
}

/// Invalidates pending results on close/minimize; allows only one job at a time.
struct DetailSamplingGate {
    private(set) var active = false
    private(set) var generation: UInt64 = 0
    private var inFlight: UInt64?
    mutating func resume() -> Bool {
        guard !active else { return false }
        active = true; generation &+= 1; return true
    }
    mutating func pause() {
        guard active else { return }
        active = false; generation &+= 1
    }
    mutating func begin() -> UInt64? {
        guard active, inFlight == nil else { return nil }
        inFlight = generation; return generation
    }
    mutating func finish(_ token: UInt64) -> Bool {
        guard inFlight == token else { return false }
        inFlight = nil
        return active && generation == token
    }
}
