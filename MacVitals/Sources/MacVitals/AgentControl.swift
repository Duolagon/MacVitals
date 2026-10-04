import Foundation
import Darwin
import CMetrics

struct AgentTerminationRequest {
    let instance: AgentProcessID
    var process: AgentProcessID? = nil
    var force = false
}

/// Freeze the exact scope shown in the confirmation; never expand it to new processes afterward.
struct AgentTerminationPlan {
    let instance: AgentProcessID
    let targets: [AgentProcessID]
    let name: String
    let singleProcess: Bool
    init?(usage: AgentUsage, process: AgentProcessID? = nil) {
        guard usage.id.pid > 1, usage.id.pid != getpid(), usage.processes.contains(where: { $0.id == usage.id }) else { return nil }
        let members = process.map { id in usage.processes.filter { $0.id == id } } ?? usage.processes
        guard !members.isEmpty, members.allSatisfy({ $0.id.pid > 1 && $0.id.pid != getpid() && $0.id.started > 0 }) else { return nil }
        instance = usage.id
        targets = Array(Set(members.map(\.id))).sorted { $0.pid < $1.pid }
        singleProcess = process != nil
        name = process == nil ? usage.kind.rawValue : (members[0].name.isEmpty ? "进程" : members[0].name)
    }
}

struct AgentTerminationResult {
    var sent: [AgentProcessID] = []
    var skipped: [AgentProcessID] = []
    var failures: [(AgentProcessID, Int32)] = []
}

enum AgentControlError: Error, LocalizedError {
    case unavailable, instanceChanged
    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法读取当前进程，未发送结束请求。"
        case .instanceChanged: return "该 Agent 实例已退出或身份已变化，未发送结束请求。"
        }
    }
}

final class AgentTerminator {
    private let discover: () -> [AgentProcessIdentity]?
    private let signal: (AgentProcessID, Int32) -> Int32
    init(discover: @escaping () -> [AgentProcessIdentity]? = { NativeAgentProcessSource().discover() },
         signal: @escaping (AgentProcessID, Int32) -> Int32 = { mv_agent_signal($0.pid, $0.started, $1) }) {
        self.discover = discover; self.signal = signal
    }
    func execute(_ plan: AgentTerminationPlan, force: Bool) throws -> AgentTerminationResult {
        guard let identities = discover() else { throw AgentControlError.unavailable }
        let live = Dictionary(uniqueKeysWithValues: identities.map { ($0.id.pid, $0) })
        guard let root = live[plan.instance.pid], root.id == plan.instance, root.uid == Int32(getuid()), root.status != 5 else {
            throw AgentControlError.instanceChanged
        }
        func depth(_ id: AgentProcessID) -> Int? {
            guard let process = live[id.pid], process.id == id, process.uid == Int32(getuid()), process.status != 5,
                  id.pid > 1, id.pid != getpid() else { return nil }
            var pid = id.pid, seen: Set<Int32> = [], distance = 0
            while seen.insert(pid).inserted {
                if pid == plan.instance.pid { return distance }
                guard let parent = live[pid] else { return nil }
                pid = parent.parent; distance += 1
            }
            return nil
        }
        var result = AgentTerminationResult()
        let eligible = plan.targets.compactMap { id -> (AgentProcessID, Int)? in
            guard let distance = depth(id) else { result.skipped.append(id); return nil }
            return (id, distance)
        }.sorted { $0.1 == $1.1 ? $0.0.pid < $1.0.pid : $0.1 > $1.1 }
        for (id, _) in eligible {
            // Native delivery rechecks the identity, covering exits or PID reuse during this loop.
            switch signal(id, force ? SIGKILL : SIGTERM) {
            case 0: result.sent.append(id)
            case ESRCH, ESTALE: result.skipped.append(id)
            case let error: result.failures.append((id, error))
            }
        }
        return result
    }
}
