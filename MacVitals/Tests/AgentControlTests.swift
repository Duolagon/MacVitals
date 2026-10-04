import Foundation
import Darwin
import CMetrics

private func controlUsage(_ root: AgentProcessID, _ ids: [AgentProcessID]) -> AgentUsage {
    .init(id: root, kind: .codex, processes: ids.map { .init(id: $0, name: "fixture", cpu: nil, memory: nil) },
          cpu: nil, memory: nil, readRate: nil, writeRate: nil, partial: false)
}
private func controlIdentity(_ id: AgentProcessID, parent: Int32, uid: Int32 = Int32(getuid())) -> AgentProcessIdentity {
    .init(id: id, parent: parent, uid: uid, status: 3, name: "fixture")
}

func testAgentTerminationScopeAndOrder() {
    let root = AgentProcessID(pid: 41001, started: 1), child = AgentProcessID(pid: 41002, started: 2)
    let leaf = AgentProcessID(pid: 41003, started: 3), unrelated = AgentProcessID(pid: 41004, started: 4)
    let createdAfterConfirmation = AgentProcessID(pid: 41005, started: 5)
    let usage = controlUsage(root, [root, child, leaf])
    let live = [controlIdentity(root, parent: 1), controlIdentity(child, parent: root.pid),
                controlIdentity(leaf, parent: child.pid), controlIdentity(unrelated, parent: 1),
                controlIdentity(createdAfterConfirmation, parent: root.pid)]
    var signals: [(AgentProcessID, Int32)] = []
    let terminator = AgentTerminator(discover: { live }, signal: { signals.append(($0, $1)); return 0 })
    do {
        let plan = AgentTerminationPlan(usage: usage)!
        let result = try terminator.execute(plan, force: false)
        XCTAssertEqual(result.sent, [leaf, child, root])
        XCTAssertTrue(signals.allSatisfy { $0.1 == SIGTERM })
        XCTAssertEqual(signals.count, 3)
        signals.removeAll()
        let single = AgentTerminationPlan(usage: usage, process: child)!
        _ = try terminator.execute(single, force: true)
        XCTAssertEqual(signals.count, 1); XCTAssertEqual(signals[0].0, child); XCTAssertEqual(signals[0].1, SIGKILL)
        XCTAssertNil(AgentTerminationPlan(usage: usage, process: unrelated))
        let own = AgentProcessID(pid: getpid(), started: 1)
        XCTAssertNil(AgentTerminationPlan(usage: controlUsage(own, [own])))
    } catch { XCTFail("Termination scope: \(error)") }
}

func testAgentTerminationRejectsStaleAndUnownedTargets() {
    let root = AgentProcessID(pid: 42001, started: 1), reused = AgentProcessID(pid: 42002, started: 2)
    let moved = AgentProcessID(pid: 42003, started: 3), foreign = AgentProcessID(pid: 42004, started: 4)
    let exited = AgentProcessID(pid: 42005, started: 5), raced = AgentProcessID(pid: 42006, started: 6)
    let denied = AgentProcessID(pid: 42007, started: 7)
    let plan = AgentTerminationPlan(usage: controlUsage(root, [root, reused, moved, foreign, exited, raced, denied]))!
    let live = [controlIdentity(root, parent: 1), controlIdentity(.init(pid: reused.pid, started: 99), parent: root.pid),
                controlIdentity(moved, parent: 1), controlIdentity(foreign, parent: root.pid, uid: Int32(getuid()) + 1),
                controlIdentity(raced, parent: root.pid), controlIdentity(denied, parent: root.pid)]
    var signaled: [AgentProcessID] = []
    do {
        let report = try AgentTerminator(discover: { live }, signal: { id, _ in
            signaled.append(id); return id == raced ? ESTALE : (id == denied ? EPERM : 0)
        }).execute(plan, force: false)
        XCTAssertEqual(Set(signaled), Set([root, raced, denied]))
        XCTAssertEqual(report.sent, [root]); XCTAssertEqual(report.skipped.count, 5)
        XCTAssertEqual(report.failures.count, 1); XCTAssertEqual(report.failures[0].0, denied)
        for discovery: [AgentProcessIdentity]? in [nil, [controlIdentity(.init(pid: root.pid, started: 99), parent: 1)]] {
            var called = false
            do {
                _ = try AgentTerminator(discover: { discovery }, signal: { _, _ in called = true; return 0 }).execute(plan, force: true)
                XCTFail("Stale instance must fail")
            } catch { XCTAssertTrue(!called) }
        }
    } catch { XCTFail("Termination identity guards: \(error)") }
}

func testNativeAgentTerminationSignals() {
    XCTAssertEqual(mv_agent_signal(0, 1, SIGTERM), EINVAL)
    XCTAssertEqual(mv_agent_signal(-1, 1, SIGKILL), EINVAL)
    XCTAssertEqual(mv_agent_signal(1, 1, SIGKILL), EINVAL)
    XCTAssertEqual(mv_agent_signal(getpid(), 1, SIGTERM), EINVAL)
    for force in [false, true] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["8"]
        do { try process.run() } catch { XCTFail("Create controlled fixture: \(error)"); return }
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let source = NativeAgentProcessSource()
        guard let identity = source.discover()?.first(where: { $0.id.pid == process.processIdentifier }) else {
            XCTFail("Controlled child not discoverable"); return
        }
        XCTAssertEqual(mv_agent_signal(identity.id.pid, identity.id.started + 1, SIGKILL), ESTALE)
        XCTAssertEqual(mv_agent_signal(identity.id.pid, identity.id.started, SIGINT), EINVAL)
        XCTAssertTrue(process.isRunning)
        let plan = AgentTerminationPlan(usage: controlUsage(identity.id, [identity.id]))!
        do {
            let report = try AgentTerminator().execute(plan, force: force)
            XCTAssertEqual(report.sent, [identity.id]); XCTAssertTrue(report.failures.isEmpty)
        } catch { XCTFail("Controlled child termination: \(error)") }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, Process.TerminationReason.uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, force ? SIGKILL : SIGTERM)
    }
}
