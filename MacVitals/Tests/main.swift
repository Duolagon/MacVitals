func XCTFail(_ message: String) { print("FAIL: \(message)"); exit(1) }
func XCTAssertTrue(_ value: Bool) { if !value { XCTFail("Expected true") } }
func XCTAssertNil<T>(_ value: T?) { if value != nil { XCTFail("Expected nil") } }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { if a != b { XCTFail("\(a) != \(b)") } }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double) { if abs(a-b) > accuracy { XCTFail("\(a) != \(b) ± \(accuracy)") } }
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T) { if a == b { XCTFail("Expected different values") } }
func XCTAssertGreaterThan(_ a: Double, _ b: Double) { if a <= b { XCTFail("\(a) <= \(b)") } }
import Foundation
import Darwin
import CMetrics


final class MetricsTests {
    func testFormattingAndInterfaceSelection() {
        XCTAssertEqual(MetricsFormat.bytes(0), "0 B")
        XCTAssertEqual(MetricsFormat.rate(0), "0.0 B/s")
        XCTAssertEqual(MetricsFormat.rate(1000), "1.0 KB/s")
        XCTAssertEqual(MetricsFormat.rate(Double.nan), "不可用")
        let baseline = StatusBarText.title(cpu: 0, memory: 0, download: 0, upload: 0).count
        for value in [0.0, 9, 10, 99, 100, 999.94, 999.95, 1000, 1e6, 1e20] {
            XCTAssertEqual(MetricsFormat.compactRate(value).count, 8)
            XCTAssertEqual(StatusBarText.title(cpu: value, memory: value, download: value, upload: value).count, baseline)
        }
        XCTAssertEqual(MetricsFormat.compactRate(nil).count, 8)
        let interfaces = [
            NetworkInterfaceReading(name: "utun0", index: 1, address: "10.0.0.1", counters: .init(received: 0, sent: 0)),
            NetworkInterfaceReading(name: "en0", index: 2, address: "192.168.1.2", counters: .init(received: 0, sent: 0)),
            NetworkInterfaceReading(name: "en1", index: 3, address: "192.168.2.2", counters: .init(received: 0, sent: 0))
        ]
        XCTAssertEqual(NetworkSampler.select(interfaces, primary: "en1")?.name, "en1")
        XCTAssertEqual(NetworkSampler.select(interfaces, primary: "utun0")?.name, "en0")
        XCTAssertNil(NetworkSampler.select([], primary: nil))
    }
    func testCounterResetAndInterfaceReplacement() {
        var tracker = CounterTracker()
        XCTAssertTrue(tracker.sample(["en0#1": .init(received: 100_000_000, sent: 20)], elapsed: nil).isEmpty)
        XCTAssertTrue(tracker.sample(["en0#1": .init(received: 100, sent: 0)], elapsed: 5).isEmpty)
        let rate = tracker.sample(["en0#1": .init(received: 600, sent: 100)], elapsed: 5)
        XCTAssertEqual(rate["en0#1"], ByteRate(received: 100, sent: 20))
        XCTAssertTrue(tracker.sample(["en0#2": .init(received: 100_000_000, sent: 0)], elapsed: 5).isEmpty)
    }
    func testDiskHotplugDoesNotCountHistoricalTraffic() {
        var tracker = CounterTracker()
        _ = tracker.sample(["diskA": .init(received: 100, sent: 200)], elapsed: nil)
        let rates = tracker.sample(["diskA": .init(received: 600, sent: 300), "diskB": .init(received: 9_000_000_000, sent: 8_000_000_000)], elapsed: 5)
        XCTAssertEqual(rates.count, 1)
        XCTAssertEqual(rates["diskA"], .init(received: 100, sent: 20))
        _ = tracker.sample([:], elapsed: 5)
        XCTAssertTrue(tracker.sample(["diskA": .init(received: 600, sent: 300)], elapsed: 5).isEmpty)
    }
    func testCountersBeyondFourGiBRemainAccurate() {
        var tracker = CounterTracker()
        _ = tracker.sample(["en0": .init(received: 4_294_967_290, sent: 0)], elapsed: nil)
        XCTAssertEqual(tracker.sample(["en0": .init(received: 4_294_967_790, sent: 100)], elapsed: 5)["en0"], .init(received: 100, sent: 20))
    }
    func testHostRightsAreReleased() {
        let reference = HostPort()
        func refs() -> mach_port_urefs_t {
            var count: mach_port_urefs_t = 0
            XCTAssertEqual(mach_port_get_refs(mach_task_self_, reference.port, MACH_PORT_RIGHT_SEND, &count), KERN_SUCCESS)
            return count
        }
        let before = refs()
        for _ in 0..<1000 { let temporary = HostPort(); XCTAssertEqual(temporary.port, reference.port) }
        XCTAssertEqual(refs(), before)
    }
    func testProcessCPUUsesNanoseconds() {
        func processCPU() -> UInt64? {
            var buffer = [MVProcess](repeating: MVProcess(), count: 4096)
            let count = mv_processes(&buffer, Int32(buffer.count))
            guard count >= 0 else { return nil }
            return buffer.prefix(Int(count)).first { $0.pid == getpid() }?.cpu_ns
        }
        func cpuSeconds() -> Double {
            var r = rusage(); XCTAssertEqual(getrusage(RUSAGE_SELF, &r), 0)
            return Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1e6
        }
        guard let before = processCPU() else { return XCTFail("Cannot read own process") }
        let cpuBefore = cpuSeconds()
        let until = ProcessInfo.processInfo.systemUptime + 0.2
        var checksum: UInt64 = 1
        while ProcessInfo.processInfo.systemUptime < until { checksum = checksum &* 1664525 &+ 1013904223 }
        XCTAssertNotEqual(checksum, 0)
        let cpuAfter = cpuSeconds()
        guard let after = processCPU() else { return XCTFail("Cannot read own process") }
        let expected = cpuAfter-cpuBefore
        XCTAssertGreaterThan(expected, 0.01)
        XCTAssertEqual(Double(after-before)/1e9, expected, accuracy: max(0.02, expected*0.2))
    }
    func testMissingMemoryDoesNotBecomeZeroPercent() {
        let snapshot = Snapshot()
        XCTAssertNil(snapshot.memoryPercent)
        let model = DashboardModel(); model.record(snapshot)
        XCTAssertNil(model.readings.last?.snapshot.memoryPercent)
    }
    func testSMCConcurrentCloseAndReadDoesNotCorruptConnection() {
        let before = mv_smc_read("FNum")
        DispatchQueue.concurrentPerform(iterations: 30) { i in
            if i % 3 == 0 { mv_smc_close() }
            else { let value = mv_smc_read("FNum"); XCTAssertTrue(value == -1 || (value >= 0 && value <= 16)) }
        }
        if before >= 0 { XCTAssertEqual(mv_smc_read("FNum"), before) }
    }
}

let tests = MetricsTests()
let cases: [(String, () -> Void)] = [
    ("Swap / rate formatting and primary interface", tests.testFormattingAndInterfaceSelection),
    ("Counter reset / interface replacement", tests.testCounterResetAndInterfaceReplacement),
    ("Disk hotplug", tests.testDiskHotplugDoesNotCountHistoricalTraffic),
    ("64-bit network counters", tests.testCountersBeyondFourGiBRemainAccurate),
    ("Host rights released", tests.testHostRightsAreReleased),
    ("Process CPU nanoseconds", tests.testProcessCPUUsesNanoseconds),
    ("Missing memory", tests.testMissingMemoryDoesNotBecomeZeroPercent),
    ("Concurrent SMC reconnect", tests.testSMCConcurrentCloseAndReadDoesNotCorruptConnection)
]
for (name, run) in cases { run(); print("PASS: \(name)") }
print("All \(cases.count) regression checks passed")
