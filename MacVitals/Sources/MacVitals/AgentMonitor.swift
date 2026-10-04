import Foundation
import AppKit
import CMetrics

enum AgentKind: String, CaseIterable {
    case codex = "Codex", claude = "Claude Code", gemini = "Gemini CLI"
    case opencode = "OpenCode", cursor = "Cursor", aider = "Aider"
}
struct AgentProcessID: Hashable { let pid: Int32; let started: UInt64 }
struct AgentProcessReading {
    let pid: Int32, parent: Int32
    let started: UInt64
    let name: String, executable: String, entrypoint: String
    let cpuNanoseconds: UInt64?, memory: UInt64?, readBytes: UInt64?, writtenBytes: UInt64?
    var id: AgentProcessID { .init(pid: pid, started: started) }
}
struct AgentProcessUsage: Identifiable {
    let id: AgentProcessID
    let name: String
    let cpu: Double?
    let memory: UInt64?
}
struct AgentUsage: Identifiable {
    let id: AgentProcessID
    let kind: AgentKind
    let processes: [AgentProcessUsage]
    let cpu: Double?
    let memory: UInt64?
    let readRate: Double?, writeRate: Double?
    let partial: Bool
}
struct AgentSnapshot {
    var usages: [AgentUsage] = []
    var available = true
    var sampled = false
    var time = Date()
    var totalCPU: Double? { let values = usages.compactMap { $0.cpu }; return values.isEmpty ? nil : values.reduce(0, +) }
    var totalMemory: UInt64? { let values = usages.compactMap { $0.memory }; return values.isEmpty ? nil : values.reduce(0, +) }
}
enum AgentRecognition {
    static func kind(executable: String, entrypoint: String) -> AgentKind? {
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        switch name {
        case "codex": return .codex
        case "claude", "claude.exe": return .claude
        case "gemini": return .gemini
        case "opencode": return .opencode
        case "cursor-agent": return .cursor
        case "aider": return .aider
        default: break
        }
        if name == "agent" && executable.contains("/cursor-agent/") { return .cursor }
        guard name == "node" || name == "nodejs" || name.hasPrefix("python") else { return nil }
        let script = entrypoint.lowercased()
        let leaf = URL(fileURLWithPath: script).lastPathComponent
        if script.contains("/node_modules/@openai/codex/") { return .codex }
        if script.contains("/node_modules/@anthropic-ai/claude-code/") { return .claude }
        if script.contains("/node_modules/@google/gemini-cli/") { return .gemini }
        if script.contains("/node_modules/opencode-ai/") { return .opencode }
        if leaf == "aider" || script == "aider" || script.contains("/aider/__main__.py") { return .aider }
        if ["codex", "claude", "gemini", "opencode", "cursor-agent"].contains(leaf) {
            return kind(executable: "/" + leaf, entrypoint: "")
        }
        return nil
    }
    static func desktops() -> [Int32: AgentKind] {
        var result: [Int32: AgentKind] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if app.bundleIdentifier == "com.openai.codex" { result[app.processIdentifier] = .codex }
            if app.bundleURL?.lastPathComponent.lowercased() == "cursor.app" { result[app.processIdentifier] = .cursor }
            if app.bundleURL?.lastPathComponent.lowercased() == "opencode.app" { result[app.processIdentifier] = .opencode }
        }
        return result
    }
}
/// Its counters, timing and queue are independent of the system monitor.
final class AgentMonitor {
    private var previous: [AgentProcessID: UInt64] = [:]
    private var io = CounterTracker()
    private var lastTime: TimeInterval?
    func sample(desktops: [Int32: AgentKind]) -> AgentSnapshot {
        var buffer = [MVAgentProcess](repeating: MVAgentProcess(), count: 4096)
        let count = mv_agent_processes(&buffer, Int32(buffer.count))
        guard count >= 0 else {
            previous = [:]; io = CounterTracker(); lastTime = nil
            return AgentSnapshot(available: false, sampled: true)
        }
        let readings = buffer.prefix(Int(count)).map { raw -> AgentProcessReading in
            var p = raw
            func string<T>(_ x: inout T) -> String {
                withUnsafePointer(to: &x) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
            }
            return .init(pid: p.pid, parent: p.parent, started: p.started,
                         name: string(&p.name), executable: string(&p.executable), entrypoint: string(&p.entrypoint),
                         cpuNanoseconds: p.readable != 0 ? p.cpu_ns : nil, memory: p.readable != 0 ? p.resident : nil,
                         readBytes: p.readable != 0 ? p.read_bytes : nil, writtenBytes: p.readable != 0 ? p.written_bytes : nil)
        }
        return aggregate(readings, desktops: desktops, uptime: ProcessInfo.processInfo.systemUptime)
    }
    func aggregate(_ readings: [AgentProcessReading], desktops: [Int32: AgentKind] = [:], uptime: TimeInterval) -> AgentSnapshot {
        let elapsed = lastTime.map { uptime - $0 }; lastTime = uptime
        let byPID = Dictionary(uniqueKeysWithValues: readings.map { ($0.pid, $0) })
        var matches: [Int32: AgentKind] = [:]
        for p in readings {
            if let kind = desktops[p.pid] ?? AgentRecognition.kind(executable: p.executable, entrypoint: p.entrypoint) { matches[p.pid] = kind }
        }
        var roots = matches
        for (pid, kind) in matches {
            var parent = byPID[pid]?.parent ?? 0, visited: Set<Int32> = [pid]
            while parent > 0 && visited.insert(parent).inserted {
                if let ancestor = matches[parent] {
                    if ancestor == kind { roots.removeValue(forKey: pid) }
                    break
                }
                parent = byPID[parent]?.parent ?? 0
            }
        }
        var groups: [Int32: [AgentProcessReading]] = [:]
        for p in readings {
            var pid = p.pid, visited: Set<Int32> = []
            while pid > 0 && visited.insert(pid).inserted {
                if roots[pid] != nil { groups[pid, default: []].append(p); break }
                pid = byPID[pid]?.parent ?? 0
            }
        }
        var cpu: [AgentProcessID: Double] = [:], next: [AgentProcessID: UInt64] = [:]
        var counters: [String: ByteCounters] = [:]
        func key(_ id: AgentProcessID) -> String { "\(id.pid)#\(id.started)" }
        for p in readings {
            if let value = p.cpuNanoseconds {
                next[p.id] = value
                if let old = previous[p.id], let elapsed, elapsed > 0, value >= old {
                    cpu[p.id] = Double(value - old) / 1e9 / elapsed * 100
                }
            }
            if let read = p.readBytes, let written = p.writtenBytes { counters[key(p.id)] = .init(received: read, sent: written) }
        }
        previous = next
        let rates = io.sample(counters, elapsed: elapsed)
        let usages = groups.compactMap { root, members -> AgentUsage? in
            guard let process = byPID[root], let kind = roots[root] else { return nil }
            let cpuValues = members.compactMap { cpu[$0.id] }, memoryValues = members.compactMap { $0.memory }
            let ioValues = members.compactMap { rates[key($0.id)] }
            return AgentUsage(id: process.id, kind: kind,
                processes: members.map { .init(id: $0.id, name: $0.name, cpu: cpu[$0.id], memory: $0.memory) }.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) },
                cpu: cpuValues.isEmpty ? nil : cpuValues.reduce(0, +), memory: memoryValues.isEmpty ? nil : memoryValues.reduce(0, +),
                readRate: ioValues.isEmpty ? nil : ioValues.reduce(0) { $0 + $1.received }, writeRate: ioValues.isEmpty ? nil : ioValues.reduce(0) { $0 + $1.sent },
                partial: cpuValues.count < members.count || memoryValues.count < members.count)
        }.sorted { $0.kind.rawValue == $1.kind.rawValue ? $0.id.pid < $1.id.pid : $0.kind.rawValue < $1.kind.rawValue }
        return AgentSnapshot(usages: usages, sampled: true)
    }
}
