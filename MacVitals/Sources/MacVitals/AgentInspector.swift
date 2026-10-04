import AppKit
import SwiftUI

/// Only navigation values survive a closed window; no views or process snapshots.
struct AgentInspectorNavigation: Equatable {
    var selection: AgentProcessID?
    var expandedGraph = false
    var query = ""
    var page = 0
    var listMode = false
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
}

final class AgentInspectorSession: ObservableObject {
    struct Capture {
        let usage: AgentUsage
        let time: Date
    }
    @Published var navigation: AgentInspectorNavigation
    @Published private(set) var capture: Capture?

    init(navigation: AgentInspectorNavigation = .init()) { self.navigation = navigation }

    func record(_ snapshot: AgentSnapshot, instance: AgentProcessID) {
        guard snapshot.available, let usage = snapshot.usages.first(where: { $0.id == instance }) else { return }
        capture = Capture(usage: usage, time: snapshot.time)
    }

    func usage(in snapshot: AgentSnapshot, instance: AgentProcessID) -> AgentUsage? {
        (snapshot.available ? snapshot.usages.first { $0.id == instance } : nil) ?? capture?.usage
    }

    func sampleTime(in snapshot: AgentSnapshot, instance: AgentProcessID) -> Date {
        if snapshot.available && snapshot.usages.contains(where: { $0.id == instance }) { return snapshot.time }
        return capture?.time ?? snapshot.time
    }

    func selected(in usage: AgentUsage, instance: AgentProcessID) -> AgentProcessUsage? {
        // An exited or reused PID must never silently become a different node.
        usage.processes.first { $0.id == (navigation.selection ?? instance) }
    }
}

/// Owns visible windows and a bounded cache of navigation for recently closed ones.
final class AgentInspectorWindows: NSObject, NSWindowDelegate {
    struct Entry {
        let window: NSWindow
        let session: AgentInspectorSession
    }
    private(set) var entries: [AgentProcessID: Entry] = [:]
    private var saved: [AgentProcessID: AgentInspectorNavigation] = [:]
    private var recency: [AgentProcessID] = []
    private let limit: Int

    init(limit: Int = 32) { self.limit = max(0, limit); super.init() }
    func navigation(for id: AgentProcessID) -> AgentInspectorNavigation? { saved[id] }

    func insert(_ window: NSWindow, session: AgentInspectorSession, for id: AgentProcessID) {
        window.isReleasedWhenClosed = false
        window.delegate = self
        entries[id] = Entry(window: window, session: session)
        saved.removeValue(forKey: id); recency.removeAll { $0 == id }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let (id, entry) = entries.first(where: { $0.value.window === window }) else { return }
        saved[id] = entry.session.navigation
        recency.removeAll { $0 == id }; recency.append(id)
        while recency.count > limit { saved.removeValue(forKey: recency.removeFirst()) }
        // Drop the hosting view and its subscriptions/animation immediately.
        window.contentViewController = nil
        window.delegate = nil
        entries.removeValue(forKey: id)
    }

    func prune(active: Set<AgentProcessID>) {
        saved = saved.filter { active.contains($0.key) }
        recency.removeAll { !active.contains($0) }
    }

    func closeAll() {
        for entry in Array(entries.values) { entry.window.close() }
        entries.removeAll(); saved.removeAll(); recency.removeAll()
    }
}
