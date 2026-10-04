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
            XCTAssertEqual(MetricsFormat.menuRate(value).count, 4)
            XCTAssertEqual(StatusBarText.title(cpu: value, memory: value, download: value, upload: value).count, baseline)
        }
        XCTAssertEqual(MetricsFormat.compactRate(nil).count, 8)
        XCTAssertEqual(MetricsFormat.menuRate(nil).count, 4)
        XCTAssertEqual(MetricsFormat.menuRate(999.5), "  1K")
        XCTAssertTrue(StatusBarText.width <= 194)
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

final class AgentTests {
    private func process(_ pid: Int32, parent: Int32 = 1, started: UInt64 = 1, executable: String = "/bin/worker",
                         cpu: UInt64? = 0, memory: UInt64? = 100, io: UInt64? = 0) -> AgentProcessReading {
        .init(pid: pid, parent: parent, started: started, name: "process", executable: executable, entrypoint: "",
              cpuNanoseconds: cpu, memory: memory, readBytes: io, writtenBytes: io)
    }
    func testRecognition() {
        for (path, script, kind) in [
            ("/bin/codex", "", AgentKind.codex), ("/bin/claude.exe", "", .claude),
            ("/bin/node", "/opt/node_modules/@google/gemini-cli/dist/index.js", .gemini),
            ("/bin/opencode", "", .opencode), ("/bin/cursor-agent", "", .cursor),
            ("/bin/python3.13", "aider", .aider),
            ("/bin/node", "/opt/node_modules/@anthropic-ai/claude-code/cli.js", .claude),
            ("/bin/node", "/opt/node_modules/@openai/codex/bin/codex.js", .codex),
            ("/bin/node", "/opt/node_modules/opencode-ai/bin/opencode", .opencode)
        ] { XCTAssertEqual(AgentRecognition.kind(executable: path, entrypoint: script), kind) }
        XCTAssertNil(AgentRecognition.kind(executable: "/usr/libexec/UserEventAgent", entrypoint: ""))
        XCTAssertNil(AgentRecognition.kind(executable: "/System/CursorUIViewService", entrypoint: ""))
        XCTAssertNil(AgentRecognition.kind(executable: "/tmp/agent", entrypoint: ""))
        XCTAssertNil(AgentRecognition.kind(executable: "/bin/node", entrypoint: "/tmp/not-codex.js"))
    }
    func testNestedSameAgentCountedOnce() {
        let m = AgentMonitor()
        let first = [process(10, executable: "/Applications/ChatGPT"),
                     process(11, parent: 10, executable: "/bin/codex", memory: 200),
                     process(12, parent: 11, memory: 300), process(20)]
        let a = m.aggregate(first, desktops: [10: .codex], uptime: 1)
        XCTAssertEqual(a.usages.count, 1); XCTAssertEqual(a.usages[0].processes.count, 3)
        XCTAssertEqual(a.usages[0].memory, 600); XCTAssertNil(a.usages[0].cpu)
        let second = [process(10, executable: "/Applications/ChatGPT", cpu: 100_000_000),
                      process(11, parent: 10, executable: "/bin/codex", cpu: 200_000_000, memory: 200),
                      process(12, parent: 11, cpu: 200_000_000, memory: 300), process(20)]
        let b = m.aggregate(second, desktops: [10: .codex], uptime: 3)
        XCTAssertEqual(b.usages[0].cpu ?? -1, 25, accuracy: 0.001)
        XCTAssertTrue(!b.usages[0].partial)
    }
    func testDifferentAgentsDoNotDoubleCountChildren() {
        let m = AgentMonitor()
        let snapshot = m.aggregate([process(1, parent: 0, executable: "/bin/codex", memory: 100),
                                    process(2, parent: 1, executable: "/bin/claude", memory: 200),
                                    process(3, parent: 2, memory: 300)], uptime: 1)
        XCTAssertEqual(snapshot.usages.count, 2)
        XCTAssertEqual(snapshot.totalMemory, 600)
        XCTAssertEqual(snapshot.usages.first { $0.kind == .codex }?.processes.count, 1)
        XCTAssertEqual(snapshot.usages.first { $0.kind == .claude }?.processes.count, 2)
    }
    func testPIDReuseAndExitDoNotCreateSpikes() {
        let m = AgentMonitor()
        _ = m.aggregate([process(42, executable: "/bin/codex", cpu: 9_000_000_000, io: 9_000_000_000)], uptime: 1)
        let next = m.aggregate([process(42, started: 2, executable: "/bin/codex", cpu: 10_000_000_000, io: 10_000_000_000)], uptime: 3)
        XCTAssertNil(next.usages[0].cpu); XCTAssertNil(next.usages[0].readRate)
        XCTAssertEqual(m.aggregate([], uptime: 5).usages.count, 0)
        XCTAssertNil(m.aggregate([process(42, started: 3, executable: "/bin/codex")], uptime: 7).usages[0].cpu)
    }
    func testMissingResourcesRemainUnavailable() {
        let snapshot = AgentMonitor().aggregate([process(42, executable: "/bin/codex", cpu: nil, memory: nil, io: nil)], uptime: 1)
        XCTAssertNil(snapshot.usages[0].memory); XCTAssertNil(snapshot.usages[0].cpu)
        XCTAssertNil(snapshot.usages[0].readRate); XCTAssertTrue(snapshot.usages[0].partial)
    }
    func testNativeMetadataAndCPU() {
        func own() -> MVAgentProcess {
            var buffer = [MVAgentProcess](repeating: MVAgentProcess(), count: 4096)
            let count = mv_agent_processes(&buffer, Int32(buffer.count))
            guard count > 0, let p = buffer.prefix(Int(count)).first(where: { $0.pid == getpid() }) else { XCTFail("Own agent metadata unavailable"); return MVAgentProcess() }
            return p
        }
        let before = own(); XCTAssertEqual(before.parent, getppid())
        XCTAssertEqual(before.readable, 1); XCTAssertTrue(before.started > 0)
        var usage = rusage(); XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        let start = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let until = ProcessInfo.processInfo.systemUptime + 0.15
        var checksum: UInt64 = 0
        while ProcessInfo.processInfo.systemUptime < until { checksum = checksum &* 1664525 &+ 1013904223 }
        XCTAssertNotEqual(checksum, 0)
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        let end = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let after = own(); XCTAssertEqual(after.started, before.started)
        XCTAssertEqual(Double(after.cpu_ns - before.cpu_ns) / 1e9, end - start, accuracy: 0.03)
        XCTAssertTrue(after.resident > 0)
        XCTAssertEqual(after.uid, Int32(getuid()))
        XCTAssertEqual(after.task_readable, 1)
        XCTAssertTrue(after.threads > 0)
        XCTAssertTrue(after.virtual_bytes >= after.resident)
        XCTAssertTrue(after.footprint > 0)
        XCTAssertTrue(abs(Double(after.user_ns + after.system_ns) - Double(after.cpu_ns)) <= 2)
    }
}

let tests = MetricsTests()
let agentTests = AgentTests()
let cases: [(String, () -> Void)] = [
    ("Agent recognition / false positives", agentTests.testRecognition),
    ("Nested agent aggregation", agentTests.testNestedSameAgentCountedOnce),
    ("Different agent ownership", agentTests.testDifferentAgentsDoNotDoubleCountChildren),
    ("Agent PID reuse / exit", agentTests.testPIDReuseAndExitDoNotCreateSpikes),
    ("Agent unreadable resources", agentTests.testMissingResourcesRemainUnavailable),
    ("Agent native metadata / CPU units", agentTests.testNativeMetadataAndCPU),
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
