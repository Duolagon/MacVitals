import Foundation
import AppKit
import CMetrics

enum AgentKind: String, CaseIterable {
    case codex = "Codex", claude = "Claude Code", gemini = "Gemini CLI"
    case opencode = "OpenCode", cursor = "Cursor", aider = "Aider"
}
struct AgentProcessID: Hashable { let pid: Int32; let started: UInt64 }
struct AgentProcessDetails {
    let parent: Int32, uid: Int32, status: Int32
    let executable: String, entrypoint: String
    let threads: Int32?, runningThreads: Int32?, priority: Int32?
    let virtualBytes: UInt64?, footprint: UInt64?, userNS: UInt64?, systemNS: UInt64?
    let faults: UInt32?, pageins: UInt32?, switches: UInt32?
    let readBytes: UInt64?, writtenBytes: UInt64?
}
struct AgentProcessReading {
    let pid: Int32, parent: Int32
    let started: UInt64
    let name: String, executable: String, entrypoint: String
    let cpuNanoseconds: UInt64?, memory: UInt64?, readBytes: UInt64?, writtenBytes: UInt64?
    var detail: AgentProcessDetails? = nil
    var id: AgentProcessID { .init(pid: pid, started: started) }
}
struct AgentProcessUsage: Identifiable {
    let id: AgentProcessID
    let name: String
    let cpu: Double?
    let memory: UInt64?
    var detail: AgentProcessDetails? = nil
    var readRate: Double? = nil
    var writeRate: Double? = nil
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
        let name = (executable as NSString).lastPathComponent.lowercased()
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
        let leaf = (script as NSString).lastPathComponent
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
    private struct CachedMetadata {
        let observedName: String
        let metadata: AgentProcessMetadata
        let kind: AgentKind?
        let refreshEveryScan: Bool
        let refreshedAt: TimeInterval
    }
    private let source: AgentProcessSource
    private var metadataCache: [AgentProcessID: CachedMetadata] = [:]
    private(set) var discoveryCount = 0
    private(set) var metadataReadCount = 0
    private(set) var resourceReadCount = 0
    init(source: AgentProcessSource = NativeAgentProcessSource()) { self.source = source }

    func resetSamplingBaseline() { previous = [:]; io = CounterTracker(); lastTime = nil }

    func sample(desktops: [Int32: AgentKind], uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, detailedInstances: Set<AgentProcessID>? = nil, instances: Set<AgentProcessID>? = nil) -> AgentSnapshot {
        metadataReadCount = 0; resourceReadCount = 0; discoveryCount = 0
        guard let identities = source.discover() else {
            previous = [:]; io = CounterTracker(); lastTime = nil; metadataCache.removeAll()
            return AgentSnapshot(available: false, sampled: true)
        }
        discoveryCount = identities.count
        let live = Set(identities.map { $0.id })
        metadataCache = metadataCache.filter { live.contains($0.key) }
        var matches: [Int32: AgentKind] = [:]
        for identity in identities {
            let old = metadataCache[identity.id]
            // Interpreters may exec a different script while keeping PID and start time.
            // Refresh their entrypoint every scan so recognition remains immediate.
            if old == nil || old?.observedName != identity.name || old?.refreshEveryScan == true || uptime - (old?.refreshedAt ?? uptime) >= 30 {
                metadataReadCount += 1
                if let metadata = source.metadata(for: identity) {
                    let kind = old?.metadata == metadata ? old?.kind : AgentRecognition.kind(executable: metadata.executable, entrypoint: metadata.entrypoint)
                    metadataCache[identity.id] = CachedMetadata(observedName: identity.name, metadata: metadata, kind: kind, refreshEveryScan: metadata.interpreter || (metadata.executable as NSString).lastPathComponent.lowercased() == "agent", refreshedAt: uptime)
                } else { metadataCache.removeValue(forKey: identity.id) }
            }
            if let kind = desktops[identity.id.pid] ?? metadataCache[identity.id]?.kind { matches[identity.id.pid] = kind }
        }
        let parents = Dictionary(uniqueKeysWithValues: identities.map { ($0.id.pid, $0.parent) })
        let roots = AgentOwnership.roots(parents: parents, matches: matches)
        let ids = Dictionary(uniqueKeysWithValues: identities.map { ($0.id.pid, $0.id) })
        var readings: [AgentProcessReading] = []
        for identity in identities {
            guard let owner = AgentOwnership.owner(of: identity.id.pid, parents: parents, roots: roots) else { continue }
            if let instances, let ownerID = ids[owner], !instances.contains(ownerID) { continue }
            resourceReadCount += 1
            let metadata = metadataCache[identity.id]?.metadata ?? .init(name: identity.name, executable: "", entrypoint: "")
            let includeDetails = detailedInstances == nil || ids[owner].map { detailedInstances!.contains($0) } == true
            if let reading = source.resources(for: identity, metadata: metadata, includeDetails: includeDetails) { readings.append(reading) }
        }
        return aggregate(readings, uptime: uptime, recognized: matches)
    }
    func aggregate(_ readings: [AgentProcessReading], desktops: [Int32: AgentKind] = [:], uptime: TimeInterval, recognized: [Int32: AgentKind]? = nil) -> AgentSnapshot {
        let elapsed = lastTime.map { uptime - $0 }; lastTime = uptime
        let byPID = Dictionary(uniqueKeysWithValues: readings.map { ($0.pid, $0) })
        let parents = Dictionary(uniqueKeysWithValues: readings.map { ($0.pid, $0.parent) })
        var matches: [Int32: AgentKind] = [:]
        for p in readings {
            let kind: AgentKind?
            if let recognized { kind = recognized[p.pid] }
            else { kind = desktops[p.pid] ?? AgentRecognition.kind(executable: p.executable, entrypoint: p.entrypoint) }
            if let kind { matches[p.pid] = kind }
        }
        let roots = AgentOwnership.roots(parents: parents, matches: matches)
        var groups: [Int32: [AgentProcessReading]] = [:]
        for p in readings {
            if let owner = AgentOwnership.owner(of: p.pid, parents: parents, roots: roots) { groups[owner, default: []].append(p) }
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
                processes: members.map { .init(id: $0.id, name: $0.name, cpu: cpu[$0.id], memory: $0.memory, detail: $0.detail, readRate: rates[key($0.id)]?.received, writeRate: rates[key($0.id)]?.sent) }.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) },
                cpu: cpuValues.isEmpty ? nil : cpuValues.reduce(0, +), memory: memoryValues.isEmpty ? nil : memoryValues.reduce(0, +),
                readRate: ioValues.isEmpty ? nil : ioValues.reduce(0) { $0 + $1.received }, writeRate: ioValues.isEmpty ? nil : ioValues.reduce(0) { $0 + $1.sent },
                partial: cpuValues.count < members.count || memoryValues.count < members.count)
        }.sorted { $0.kind.rawValue == $1.kind.rawValue ? $0.id.pid < $1.id.pid : $0.kind.rawValue < $1.kind.rawValue }
        return AgentSnapshot(usages: usages, sampled: true)
    }
}
