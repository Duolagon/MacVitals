import Foundation
import CMetrics

struct AgentProcessIdentity {
    let id: AgentProcessID
    let parent: Int32, uid: Int32, status: Int32
    let name: String
}
struct AgentProcessMetadata: Equatable {
    let name: String, executable: String, entrypoint: String
    var interpreter: Bool {
        let leaf = (executable as NSString).lastPathComponent.lowercased()
        return leaf == "node" || leaf == "nodejs" || leaf.hasPrefix("python")
    }
}
protocol AgentProcessSource {
    func discover() -> [AgentProcessIdentity]?
    func metadata(for identity: AgentProcessIdentity) -> AgentProcessMetadata?
    func resources(for identity: AgentProcessIdentity, metadata: AgentProcessMetadata) -> AgentProcessReading?
}

final class NativeAgentProcessSource: AgentProcessSource {
    private var buffer = [MVAgentIdentity](repeating: MVAgentIdentity(), count: 4096)
    private func string<T>(_ value: inout T) -> String {
        withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }
    func discover() -> [AgentProcessIdentity]? {
        let capacity = buffer.count
        let count = mv_agent_identities(&buffer, Int32(capacity))
        guard count >= 0 else { return nil }
        return buffer.prefix(Int(count)).map { raw in
            var p = raw
            return AgentProcessIdentity(id: .init(pid: p.pid, started: p.started), parent: p.parent,
                                        uid: p.uid, status: p.status, name: string(&p.name))
        }
    }
    func metadata(for identity: AgentProcessIdentity) -> AgentProcessMetadata? {
        var p = MVAgentProcess()
        guard mv_agent_metadata(identity.id.pid, identity.id.started, &p) != 0 else { return nil }
        return AgentProcessMetadata(name: string(&p.name), executable: string(&p.executable), entrypoint: string(&p.entrypoint))
    }
    func resources(for identity: AgentProcessIdentity, metadata: AgentProcessMetadata) -> AgentProcessReading? {
        var p = MVAgentProcess()
        guard mv_agent_resources(identity.id.pid, identity.id.started, &p) != 0 else { return nil }
        return .init(pid: p.pid, parent: identity.parent, started: p.started,
                     name: metadata.name.isEmpty ? identity.name : metadata.name,
                     executable: metadata.executable, entrypoint: metadata.entrypoint,
                     cpuNanoseconds: p.readable != 0 ? p.cpu_ns : nil, memory: p.readable != 0 ? p.resident : nil,
                     readBytes: p.readable != 0 ? p.read_bytes : nil, writtenBytes: p.readable != 0 ? p.written_bytes : nil,
                     detail: .init(parent: p.parent, uid: p.uid, status: p.status,
                        executable: metadata.executable, entrypoint: metadata.entrypoint,
                        threads: p.task_readable != 0 ? p.threads : nil, runningThreads: p.task_readable != 0 ? p.running_threads : nil,
                        priority: p.task_readable != 0 ? p.priority : nil, virtualBytes: p.task_readable != 0 ? p.virtual_bytes : nil,
                        footprint: p.readable != 0 ? p.footprint : nil, userNS: p.readable != 0 ? p.user_ns : nil, systemNS: p.readable != 0 ? p.system_ns : nil,
                        faults: p.task_readable != 0 ? p.faults : nil, pageins: p.task_readable != 0 ? p.pageins : nil, switches: p.task_readable != 0 ? p.switches : nil,
                        readBytes: p.readable != 0 ? p.read_bytes : nil, writtenBytes: p.readable != 0 ? p.written_bytes : nil))
    }
}

enum AgentOwnership {
    static func roots(parents: [Int32: Int32], matches: [Int32: AgentKind]) -> [Int32: AgentKind] {
        var roots = matches
        for (pid, kind) in matches {
            var parent = parents[pid] ?? 0, visited: Set<Int32> = [pid]
            while parent > 0 && visited.insert(parent).inserted {
                if let ancestor = matches[parent] {
                    if ancestor == kind { roots.removeValue(forKey: pid) }
                    break
                }
                parent = parents[parent] ?? 0
            }
        }
        return roots
    }
    static func owner(of pid: Int32, parents: [Int32: Int32], roots: [Int32: AgentKind]) -> Int32? {
        var pid = pid, visited: Set<Int32> = []
        while pid > 0 && visited.insert(pid).inserted {
            if roots[pid] != nil { return pid }
            pid = parents[pid] ?? 0
        }
        return nil
    }
}
