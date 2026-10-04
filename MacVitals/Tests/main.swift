func XCTFail(_ message: String) { print("FAIL: \(message)"); exit(1) }
func XCTAssertTrue(_ value: Bool) { if !value { XCTFail("Expected true") } }
func XCTAssertNil<T>(_ value: T?) { if value != nil { XCTFail("Expected nil") } }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { if a != b { XCTFail("\(a) != \(b)") } }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double) { if abs(a-b) > accuracy { XCTFail("\(a) != \(b) ± \(accuracy)") } }
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T) { if a == b { XCTFail("Expected different values") } }
func XCTAssertGreaterThan(_ a: Double, _ b: Double) { if a <= b { XCTFail("\(a) <= \(b)") } }
import Foundation
import AppKit
import Darwin
import CMetrics


final class MetricsTests {
    func testFormattingAndInterfaceSelection() {
        XCTAssertEqual(MetricsFormat.bytes(0), "0 B")
        XCTAssertEqual(MetricsFormat.rate(0), "0.0 B/s")
        XCTAssertEqual(MetricsFormat.rate(1000), "1.0 KB/s")
        XCTAssertEqual(MetricsFormat.rate(Double.nan), "不可用")
        let baseline = StatusBarText.title(download: 0, upload: 0).count
        for value in [0.0, 9, 10, 99, 100, 999.94, 999.95, 1000, 1e6, 1e20] {
            XCTAssertEqual(MetricsFormat.compactRate(value).count, 8)
            XCTAssertEqual(MetricsFormat.menuRate(value).count, 4)
            XCTAssertEqual(StatusBarText.title(download: value, upload: value).count, baseline)
        }
        XCTAssertEqual(MetricsFormat.compactRate(nil).count, 8)
        XCTAssertEqual(MetricsFormat.menuRate(nil).count, 4)
        XCTAssertEqual(MetricsFormat.menuRate(999.5), "  1K")
        XCTAssertTrue(StatusBarText.width <= 250)
        XCTAssertEqual(StatusBarText.font.pointSize, 13)
        let interfaces = [
            NetworkInterfaceReading(name: "utun0", index: 1, address: "10.0.0.1", counters: .init(received: 0, sent: 0)),
            NetworkInterfaceReading(name: "en0", index: 2, address: "192.168.1.2", counters: .init(received: 0, sent: 0)),
            NetworkInterfaceReading(name: "en1", index: 3, address: "192.168.2.2", counters: .init(received: 0, sent: 0))
        ]
        XCTAssertEqual(NetworkSampler.select(interfaces, primary: "en1")?.name, "en1")
        XCTAssertEqual(NetworkSampler.select(interfaces, primary: "utun0")?.name, "en0")
        XCTAssertNil(NetworkSampler.select([], primary: nil))
        let ipv6Only = NetworkInterfaceReading(name: "en3", index: 4, address: "", ipv6: "2001:db8::42\nfe80::42%en3", counters: .init(received: 0, sent: 0))
        XCTAssertEqual(NetworkSampler.select([interfaces[0], ipv6Only], primary: nil)?.ipv6, ipv6Only.ipv6)
        XCTAssertEqual(NetworkSampler.select([interfaces[1], ipv6Only], primary: "en3")?.name, "en3")
        let linkOnly = NetworkInterfaceReading(name: "en0", index: 5, address: "", ipv6: "fe80::42%en0", counters: .init(received: 0, sent: 0))
        XCTAssertEqual(NetworkSampler.select([linkOnly, ipv6Only], primary: nil)?.name, "en3")
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

func testNeuralGeometry() {
    let root = AgentProcessID(pid: 100, started: 1)
    var nodes: [AgentProcessUsage] = []
    for index in 0..<49 {
        let id = AgentProcessID(pid: Int32(100 + index), started: 1)
        let memory = UInt64(index) * 1024
        let process = AgentProcessUsage(id: id, name: "node", cpu: Double(index), memory: memory)
        nodes.append(process)
    }
    let size = CGSize(width: 600, height: 420)
    let positions = AgentNeuralLayout.positions(nodes, root: root, size: size)
    XCTAssertEqual(positions.count, nodes.count)
    XCTAssertEqual(positions[root], CGPoint(x: 300, y: 210))
    XCTAssertEqual(positions, AgentNeuralLayout.positions(Array(nodes.reversed()), root: root, size: size))
    for point in positions.values {
        XCTAssertTrue(point.x.isFinite && point.y.isFinite)
        XCTAssertTrue(point.x >= 0 && point.x <= size.width && point.y >= 0 && point.y <= size.height)
    }
    XCTAssertEqual(Set(positions.values.map { "\($0.x),\($0.y)" }).count, nodes.count)
}

func testGraphViewport() {
    XCTAssertEqual(AgentGraphViewport.scale(0.2), 1)
    XCTAssertEqual(AgentGraphViewport.scale(10), 3.5)
    XCTAssertEqual(AgentGraphViewport.scale(.nan), 1)
    let size = CGSize(width: 600, height: 400)
    XCTAssertEqual(AgentGraphViewport.offset(CGSize(width: 100, height: -100), scale: 1, size: size), .zero)
    XCTAssertEqual(AgentGraphViewport.offset(CGSize(width: 10000, height: -10000), scale: 2, size: size), CGSize(width: 300, height: -200))
    XCTAssertEqual(AgentGraphViewport.offset(CGSize(width: 80, height: -40), scale: 2, size: size), CGSize(width: 80, height: -40))
    XCTAssertEqual(AgentGraphViewport.offset(CGSize(width: CGFloat.nan, height: CGFloat.infinity), scale: 2, size: size), .zero)
}

func testGraphNodeHitTesting() {
    let root = AgentProcessID(pid: 1, started: 1), child = AgentProcessID(pid: 2, started: 1)
    let size = CGSize(width: 600, height: 400)
    let positions = [root: CGPoint(x: 300, y: 200), child: CGPoint(x: 400, y: 240)]
    let radii: [AgentProcessID: CGFloat] = [root: 47, child: 10]
    func hit(_ point: CGPoint, zoom: CGFloat = 1, offset: CGSize = .zero) -> AgentProcessID? {
        AgentGraphHitTest.node(at: point, positions: positions, radii: radii, labeled: [child], scale: zoom, offset: offset, size: size)
    }
    XCTAssertEqual(hit(CGPoint(x: 300, y: 200)), root)
    XCTAssertEqual(hit(CGPoint(x: 418, y: 240)), child)
    XCTAssertEqual(hit(CGPoint(x: 445, y: 274)), child)
    XCTAssertNil(hit(CGPoint(x: 20, y: 20)))
    XCTAssertEqual(hit(CGPoint(x: 460, y: 310), zoom: 2, offset: CGSize(width: -40, height: 30)), child)
    XCTAssertEqual(hit(CGPoint(x: 550, y: 378), zoom: 2, offset: CGSize(width: -40, height: 30)), child)
    XCTAssertNil(hit(CGPoint(x: 20, y: 20), zoom: 2, offset: CGSize(width: -40, height: 30)))
}

func inspectorFixture(_ root: AgentProcessID, child: AgentProcessID? = nil) -> AgentUsage {
    var processes = [AgentProcessUsage(id: root, name: "codex", cpu: 2, memory: 100)]
    if let child { processes.append(.init(id: child, name: "worker", cpu: 3, memory: 200)) }
    return AgentUsage(id: root, kind: .codex, processes: processes, cpu: 5, memory: 300,
                      readRate: 10, writeRate: 20, partial: false)
}

func testInspectorSelectedNodeExit() {
    let root = AgentProcessID(pid: 10, started: 1_000_000)
    let child = AgentProcessID(pid: 11, started: 2_000_000)
    let session = AgentInspectorSession()
    session.navigation.selection = child
    XCTAssertEqual(session.selected(in: inspectorFixture(root, child: child), instance: root)?.id, child)
    XCTAssertNil(session.selected(in: inspectorFixture(root), instance: root))
    // A replacement with the same PID is a different process, not the selected node.
    XCTAssertNil(session.selected(in: inspectorFixture(root, child: .init(pid: 11, started: 3_000_000)), instance: root))
    XCTAssertEqual(session.navigation.selection, child)
    session.navigation.selection = root
    XCTAssertEqual(session.selected(in: inspectorFixture(root), instance: root)?.id, root)
}

func testInspectorFrozenSampleTime() {
    let root = AgentProcessID(pid: 10, started: 1_000_000)
    let session = AgentInspectorSession()
    let online = AgentSnapshot(usages: [inspectorFixture(root)], sampled: true, time: Date(timeIntervalSince1970: 20))
    session.record(online, instance: root)
    let exited = AgentSnapshot(sampled: true, time: Date(timeIntervalSince1970: 90))
    session.record(exited, instance: root)
    XCTAssertEqual(session.usage(in: exited, instance: root)?.id, root)
    XCTAssertEqual(session.sampleTime(in: exited, instance: root), online.time)
    let failed = AgentSnapshot(available: false, sampled: true, time: Date(timeIntervalSince1970: 120))
    session.record(failed, instance: root)
    XCTAssertEqual(session.sampleTime(in: failed, instance: root), online.time)
    XCTAssertEqual(session.capture?.time, online.time)
    let recovered = AgentSnapshot(usages: [inspectorFixture(root)], sampled: true, time: Date(timeIntervalSince1970: 130))
    session.record(recovered, instance: root)
    XCTAssertEqual(session.sampleTime(in: recovered, instance: root), recovered.time)
    let reused = AgentSnapshot(usages: [inspectorFixture(.init(pid: 10, started: 100_000_000))], sampled: true, time: Date(timeIntervalSince1970: 140))
    session.record(reused, instance: root)
    XCTAssertEqual(session.sampleTime(in: reused, instance: root), recovered.time)
}

func testInspectorWindowReleaseAndNavigation() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let windows = AgentInspectorWindows(limit: 2)
    let root = AgentProcessID(pid: 10, started: 1)
    var navigation = AgentInspectorNavigation()
    navigation.selection = .init(pid: 11, started: 2)
    navigation.zoom = 1.3; navigation.pan = CGSize(width: 40, height: -20)
    navigation.query = "worker"; navigation.page = 1; navigation.listMode = true; navigation.expandedGraph = true
    weak var releasedWindow: NSWindow?
    weak var releasedController: NSViewController?
    weak var releasedSession: AgentInspectorSession?
    autoreleasepool {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        let controller = NSViewController(); controller.view = NSView()
        window.contentViewController = controller
        let session = AgentInspectorSession(navigation: navigation)
        releasedWindow = window; releasedController = controller; releasedSession = session
        windows.insert(window, session: session, for: root)
        XCTAssertEqual(windows.entries.count, 1)
        window.close()
        XCTAssertTrue(windows.entries.isEmpty)
        XCTAssertNil(window.contentViewController)
        XCTAssertEqual(windows.navigation(for: root), navigation)
    }
    XCTAssertNil(releasedWindow); XCTAssertNil(releasedController); XCTAssertNil(releasedSession)
    let restored = AgentInspectorSession(navigation: windows.navigation(for: root)!)
    XCTAssertEqual(restored.navigation, navigation)
    XCTAssertNil(restored.capture)
    for pid: Int32 in [20, 30] {
        let id = AgentProcessID(pid: pid, started: 1)
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        windows.insert(window, session: AgentInspectorSession(), for: id)
        window.close()
    }
    XCTAssertNil(windows.navigation(for: root)) // Bounded eviction.
    let remaining = AgentProcessID(pid: 30, started: 1)
    windows.prune(active: [remaining])
    XCTAssertNil(windows.navigation(for: .init(pid: 20, started: 1)))
    XCTAssertTrue(windows.navigation(for: remaining) != nil)
    windows.closeAll()
    XCTAssertNil(windows.navigation(for: remaining))
}

func testSlowMetricCadence() {
    var diskCalls = 0, batteryCalls = 0, available: UInt64 = 1000
    var readable = true
    let monitor = Monitor(diskReader: {
        diskCalls += 1
        return readable ? .init(available: available, total: 2000) : nil
    }, batteryReader: {
        batteryCalls += 1
        return readable ? .init(percent: 75, charging: true, description: "75%") : nil
    })
    let first = monitor.sample(uptime: 0)
    XCTAssertEqual(first.diskAvailableBytes, 1000); XCTAssertEqual(first.batteryPercent, 75)
    available = 900
    for time: Double in [2, 4, 6, 8, 10, 12, 14] {
        let sample = monitor.sample(uptime: time)
        XCTAssertEqual(sample.diskAvailableBytes, 1000)
        XCTAssertTrue(sample.memoryPercent != nil)
    }
    XCTAssertEqual(diskCalls, 1); XCTAssertEqual(batteryCalls, 1)
    XCTAssertEqual(monitor.sample(uptime: 16).diskAvailableBytes, 900)
    XCTAssertEqual(diskCalls, 2)
    available = 800
    XCTAssertEqual(monitor.sample(uptime: 18, forceSlow: true).diskAvailableBytes, 800)
    XCTAssertEqual(diskCalls, 3); XCTAssertEqual(batteryCalls, 3)
    _ = monitor.sample(uptime: 20); XCTAssertEqual(diskCalls, 3)
    readable = false
    let failed = monitor.sample(uptime: 34)
    XCTAssertNil(failed.diskAvailableBytes); XCTAssertNil(failed.batteryPercent)
    readable = true
    XCTAssertEqual(monitor.sample(uptime: 36, forceSlow: true).diskAvailableBytes, 800)
    var cadence = SampleCadence(interval: 15)
    XCTAssertTrue(cadence.shouldRefresh(at: 20))
    XCTAssertTrue(!cadence.shouldRefresh(at: 21))
    XCTAssertTrue(cadence.shouldRefresh(at: 10)) // Clock reset must not stall refresh.
    XCTAssertTrue(!cadence.shouldRefresh(at: .nan))
}

func testDetailsSamplingLifecycle() {
    var gate = DetailSamplingGate()
    XCTAssertNil(gate.begin())
    XCTAssertTrue(gate.resume()); XCTAssertTrue(!gate.resume())
    let first = gate.begin()!; XCTAssertNil(gate.begin())
    gate.pause(); XCTAssertNil(gate.begin())
    XCTAssertTrue(!gate.finish(first)) // Closing drops an in-flight result.
    XCTAssertTrue(gate.resume())
    let second = gate.begin()!
    gate.pause(); XCTAssertTrue(gate.resume()) // Reopened before the old job finished.
    XCTAssertNil(gate.begin())
    XCTAssertTrue(!gate.finish(second))
    let third = gate.begin()!
    XCTAssertTrue(third != second)
    XCTAssertTrue(!gate.finish(second)); XCTAssertNil(gate.begin())
    XCTAssertTrue(gate.finish(third))
    let fourth = gate.begin()!; XCTAssertTrue(gate.finish(fourth))
}

final class FakeAgentSource: AgentProcessSource {
    var identities: [AgentProcessIdentity] = []
    var paths: [AgentProcessID: AgentProcessMetadata] = [:]
    var readable = true
    var cpu: UInt64 = 0
    var metadataCalls: [AgentProcessID] = []
    var resourceCalls: [AgentProcessID] = []
    func discover() -> [AgentProcessIdentity]? { readable ? identities : nil }
    func metadata(for identity: AgentProcessIdentity) -> AgentProcessMetadata? {
        metadataCalls.append(identity.id); return paths[identity.id]
    }
    func resources(for identity: AgentProcessIdentity, metadata: AgentProcessMetadata) -> AgentProcessReading? {
        resourceCalls.append(identity.id)
        return .init(pid: identity.id.pid, parent: identity.parent, started: identity.id.started,
                     name: metadata.name, executable: metadata.executable, entrypoint: metadata.entrypoint,
                     cpuNanoseconds: cpu, memory: 100, readBytes: cpu, writtenBytes: cpu)
    }
    func add(_ pid: Int32, parent: Int32 = 0, started: UInt64 = 1, name: String, executable: String, entrypoint: String = "") -> AgentProcessID {
        let id = AgentProcessID(pid: pid, started: started)
        identities.append(.init(id: id, parent: parent, uid: 501, status: 2, name: name))
        paths[id] = .init(name: name, executable: executable, entrypoint: entrypoint)
        return id
    }
}

func testAgentSelectiveResourcesAndCache() {
    let source = FakeAgentSource()
    let root = source.add(10, name: "codex", executable: "/bin/codex")
    let child = source.add(11, parent: 10, name: "worker", executable: "/bin/worker")
    let unrelated = source.add(20, name: "worker", executable: "/bin/worker")
    let monitor = AgentMonitor(source: source)
    let first = monitor.sample(desktops: [:], uptime: 1)
    XCTAssertEqual(first.usages.count, 1); XCTAssertEqual(first.usages[0].processes.count, 2)
    XCTAssertEqual(Set(source.resourceCalls), [root, child])
    XCTAssertTrue(!source.resourceCalls.contains(unrelated))
    XCTAssertEqual(monitor.discoveryCount, 3); XCTAssertEqual(monitor.resourceReadCount, 2)
    XCTAssertEqual(monitor.metadataReadCount, 3)
    source.cpu = 200_000_000; source.metadataCalls.removeAll(); source.resourceCalls.removeAll()
    let next = monitor.sample(desktops: [:], uptime: 3)
    XCTAssertEqual(monitor.metadataReadCount, 0); XCTAssertTrue(source.metadataCalls.isEmpty)
    XCTAssertEqual(next.usages[0].cpu ?? -1, 20, accuracy: 0.001)
    XCTAssertEqual(next.usages[0].readRate ?? -1, 200_000_000, accuracy: 1)
    let newRoot = source.add(30, name: "claude", executable: "/bin/claude")
    XCTAssertEqual(monitor.sample(desktops: [:], uptime: 5).usages.count, 2)
    XCTAssertEqual(source.metadataCalls, [newRoot]) // Discovery is never slowed down.
    source.identities.removeAll { $0.id == root || $0.id == child }
    source.resourceCalls.removeAll()
    XCTAssertEqual(monitor.sample(desktops: [:], uptime: 7).usages.count, 1)
    XCTAssertEqual(source.resourceCalls, [newRoot])
    let reused = source.add(10, started: 2, name: "worker", executable: "/bin/worker")
    source.metadataCalls.removeAll()
    XCTAssertEqual(monitor.sample(desktops: [:], uptime: 9).usages.count, 1)
    XCTAssertTrue(source.metadataCalls.contains(reused))
    source.readable = false
    XCTAssertTrue(!monitor.sample(desktops: [:], uptime: 11).available)
    source.readable = true
    let recovered = monitor.sample(desktops: [:], uptime: 13)
    XCTAssertNil(recovered.usages[0].cpu)
    source.metadataCalls.removeAll()
    _ = monitor.sample(desktops: [:], uptime: 45)
    XCTAssertTrue(source.metadataCalls.contains(newRoot)) // Stable paths also refresh periodically.
}

func testAgentExecAndInterpreterRefresh() {
    let source = FakeAgentSource()
    let interpreter = source.add(10, name: "node", executable: "/bin/node", entrypoint: "/tmp/ordinary.js")
    let native = source.add(20, name: "ordinary", executable: "/bin/ordinary")
    let monitor = AgentMonitor(source: source)
    XCTAssertTrue(monitor.sample(desktops: [:], uptime: 1).usages.isEmpty)
    source.paths[interpreter] = .init(name: "node", executable: "/bin/node", entrypoint: "/usr/node_modules/@google/gemini-cli/index.js")
    let changed = monitor.sample(desktops: [:], uptime: 3)
    XCTAssertEqual(changed.usages.first?.kind, .gemini)
    source.paths[interpreter] = .init(name: "node", executable: "/bin/node", entrypoint: "/tmp/ordinary.js")
    source.identities[1] = .init(id: native, parent: 0, uid: 501, status: 2, name: "claude")
    source.paths[native] = .init(name: "claude", executable: "/bin/claude", entrypoint: "")
    let nativeExec = monitor.sample(desktops: [:], uptime: 5)
    XCTAssertEqual(nativeExec.usages.count, 1); XCTAssertEqual(nativeExec.usages[0].kind, .claude)
    source.paths.removeValue(forKey: interpreter)
    XCTAssertEqual(monitor.sample(desktops: [:], uptime: 7).usages.count, 1)
}

func testNativeAgentDiscoveryAndIdentityGuard() {
    let source = NativeAgentProcessSource()
    guard let identities = source.discover(), let own = identities.first(where: { $0.id.pid == getpid() }),
          let metadata = source.metadata(for: own), let reading = source.resources(for: own, metadata: metadata) else {
        XCTFail("Native two-phase collection failed"); return
    }
    XCTAssertEqual(reading.id, own.id); XCTAssertTrue(!metadata.executable.isEmpty)
    XCTAssertTrue(reading.cpuNanoseconds != nil); XCTAssertTrue(reading.memory != nil)
    XCTAssertTrue(reading.detail?.threads != nil)
    let wrong = AgentProcessIdentity(id: .init(pid: own.id.pid, started: own.id.started + 1), parent: own.parent, uid: own.uid, status: own.status, name: own.name)
    XCTAssertNil(source.metadata(for: wrong)); XCTAssertNil(source.resources(for: wrong, metadata: metadata))
    let monitor = AgentMonitor()
    let sample = monitor.sample(desktops: [getpid(): .codex])
    XCTAssertTrue(sample.usages.contains { $0.processes.contains { $0.id == own.id } })
    XCTAssertTrue(monitor.resourceReadCount < monitor.discoveryCount)
    _ = monitor.sample(desktops: [getpid(): .codex])
    XCTAssertTrue(monitor.metadataReadCount < monitor.discoveryCount)
}

func testWidgetSnapshotExchange() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVitals-widget-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("widget-snapshot.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    XCTAssertNil(WidgetSnapshot.read(from: url))
    do {
        let sample = WidgetSnapshot(sampledAt: Date(), cpu: 25, memory: nil, download: 1000, upload: nil, interface: "en0")
        try sample.write(to: url)
        XCTAssertEqual(WidgetSnapshot.read(from: url), sample)
        var chart = sample
        chart.history = (0..<32).map { (index: Int) -> WidgetHistoryPoint in
            let timestamp = sample.sampledAt.addingTimeInterval(Double(index - 31))
            let download: Double? = index == 7 ? nil : Double(index * 1000)
            return WidgetHistoryPoint(sampledAt: timestamp, cpu: Double(index), memory: 50, download: download, upload: 50)
        }
        try chart.write(to: url)
        XCTAssertEqual(WidgetSnapshot.read(from: url), chart)
        XCTAssertTrue((try Data(contentsOf: url)).count < 16_384)
        chart.history!.append(chart.history!.last!)
        try chart.write(to: url)
        XCTAssertNil(WidgetSnapshot.read(from: url))
        chart.history = [WidgetHistoryPoint(sampledAt: sample.sampledAt.addingTimeInterval(1), cpu: 0, memory: 0, download: 0, upload: 0)]
        try chart.write(to: url)
        XCTAssertNil(WidgetSnapshot.read(from: url))
        let stopped = WidgetSnapshot(sampledAt: Date().addingTimeInterval(-3600), cpu: nil, memory: nil, download: nil, upload: nil, interface: "")
        try stopped.write(to: url)
        XCTAssertEqual(WidgetSnapshot.read(from: url), stopped)
        let future = WidgetSnapshot(sampledAt: Date().addingTimeInterval(600), cpu: 25, memory: 50, download: 1, upload: 1, interface: "en0")
        try future.write(to: url)
        XCTAssertNil(WidgetSnapshot.read(from: url))
        let invalid = WidgetSnapshot(sampledAt: Date(), cpu: -1, memory: nil, download: nil, upload: nil, interface: "en0")
        try invalid.write(to: url)
        XCTAssertNil(WidgetSnapshot.read(from: url))
        try Data("{broken".utf8).write(to: url)
        XCTAssertNil(WidgetSnapshot.read(from: url))
        try Data(repeating: 32, count: 16_385).write(to: url)
        XCTAssertNil(WidgetSnapshot.read(from: url))
    } catch { XCTFail("Widget snapshot exchange: \(error)") }
}

let tests = MetricsTests()
let agentTests = AgentTests()
let cases: [(String, () -> Void)] = [
    ("Widget snapshot / missing, valid, old, future and corrupt data", testWidgetSnapshotExchange),
    ("Agent termination / instance scope and child-first order", testAgentTerminationScopeAndOrder),
    ("Agent termination / reuse, reparenting, ownership and failures", testAgentTerminationRejectsStaleAndUnownedTargets),
    ("Agent termination / native TERM and KILL on controlled children", testNativeAgentTerminationSignals),
    ("System slow metrics / cadence, force refresh and failure", testSlowMetricCadence),
    ("Details sampling / close, minimize and stale jobs", testDetailsSamplingLifecycle),
    ("Agent selective resources / cache, discovery and recovery", testAgentSelectiveResourcesAndCache),
    ("Agent exec / native rename and interpreter replacement", testAgentExecAndInterpreterRefresh),
    ("Native agent discovery / identity guard and selective reads", testNativeAgentDiscoveryAndIdentityGuard),
    ("Inspector selected node / exit and PID reuse", testInspectorSelectedNodeExit),
    ("Inspector snapshot / frozen time and recovery", testInspectorFrozenSampleTime),
    ("Inspector windows / release and bounded navigation restore", testInspectorWindowReleaseAndNavigation),
    ("Graph node hit testing / labels and viewport transforms", testGraphNodeHitTesting),
    ("Graph viewport / zoom limits and pan reset", testGraphViewport),
    ("Neural geometry / stable order and bounds", testNeuralGeometry),
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
