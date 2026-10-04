import AppKit
import SwiftUI

/// Independent status item, lifecycle, sampling timer and background queue.
final class AgentsController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: 56)
    private let popover = NSPopover()
    private let model = AgentsModel()
    private let sampler = AgentMonitor()
    private let queue = DispatchQueue(label: "local.macvitals.agents", qos: .utility)
    private var timer: Timer?
    private var busy = false
    private var running = true
    private var clickMonitor: Any?, localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var previewWindow: NSWindow?
    private let detailWindows = AgentInspectorWindows()
    private let networkWindows = AgentInspectorWindows()
    private var didPreviewDetails = false
    private var interval: Double {
        let value = UserDefaults.standard.double(forKey: "agents.interval")
        return [2.0, 5, 10].contains(value) ? value : 2
    }
    override init() {
        super.init()
        item.autosaveName = "MacVitals.Agents"
        item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Agent Monitor")
        item.button?.imagePosition = .imageLeading
        item.button?.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        item.button?.title = " —"
        item.button?.target = self; item.button?.action = #selector(toggle)
        popover.behavior = .transient; popover.delegate = self
        popover.contentSize = NSSize(width: 440, height: AgentsStyle.height)
        configureView()
        startTimer(); sample()
    }
    private func configureView() {
        popover.contentViewController = NSHostingController(rootView: view())
        previewWindow?.contentViewController = NSHostingController(rootView: view())
    }
    private func view() -> AgentsView {
        AgentsView(model: model, interval: interval, setInterval: { [weak self] value in
            UserDefaults.standard.set(value, forKey: "agents.interval")
            self?.configureView(); self?.startTimer()
        }, showDetails: { [weak self] id in self?.showDetails(id) }, showNetwork: { [weak self] id in self?.showNetwork(id) })
    }
    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func sample() {
        guard running, !busy else { return }
        busy = true
        let desktops = AgentRecognition.desktops()
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.sampler.sample(desktops: desktops)
            DispatchQueue.main.async {
                self.busy = false; guard self.running else { return }
                self.model.record(snapshot)
                if snapshot.available {
                    let active = Set(snapshot.usages.map { $0.id })
                    self.detailWindows.prune(active: active); self.networkWindows.prune(active: active)
                }
                if !self.didPreviewDetails, let usage = snapshot.usages.max(by: { $0.processes.count < $1.processes.count }),
                   CommandLine.arguments.contains("--preview-agent-details") || CommandLine.arguments.contains("--export-agent-details") {
                    self.didPreviewDetails = true
                    if CommandLine.arguments.contains("--preview-agent-details") { self.showDetails(usage.id) }
                    if let index = CommandLine.arguments.firstIndex(of: "--export-agent-details"), index + 1 < CommandLine.arguments.count {
                        let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                            self?.exportDetails(usage.id, to: destination); NSApp.terminate(nil)
                        }
                    }
                }
                self.item.button?.title = snapshot.available ? (snapshot.usages.count > 99 ? "99+" : String(format: "%2d", snapshot.usages.count)) : " —"
                let names = snapshot.usages.map { $0.kind.rawValue }.joined(separator: "、")
                let cpu = snapshot.totalCPU.map { String(format: "%.1f%%", $0) } ?? "采样中"
                let memory = snapshot.totalMemory.map { MetricsFormat.bytes($0) } ?? "—"
                self.item.button?.toolTip = snapshot.available ? "Agent Monitor · \(snapshot.usages.count) 个本地实例\n\(names)\nCPU \(cpu) · RSS \(memory)" : "Agent Monitor · 进程读取失败，正在重试"
                self.item.button?.setAccessibilityLabel("Agent Monitor，\(snapshot.usages.count) 个本地实例")
            }
        }
    }
    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        stopDismissMonitoring()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.popover.performClose(nil) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.popover.performClose(nil); return nil }
            } else if event.window !== self.popover.contentViewController?.view.window {
                let ownButton: Bool
                if let button = self.item.button, event.window === button.window {
                    ownButton = button.bounds.contains(button.convert(event.locationInWindow, from: nil))
                } else { ownButton = false }
                if !ownButton { self.popover.performClose(nil) }
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in self?.popover.performClose(nil) }
    }
    private func stopDismissMonitoring() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        clickMonitor = nil; localMonitor = nil; resignObserver = nil
    }
    func popoverDidClose(_ notification: Notification) { stopDismissMonitoring() }
    func showPreview() {
        if previewWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: AgentsStyle.height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "MacVitals · Agent Monitor"
            window.isReleasedWhenClosed = false; window.contentViewController = NSHostingController(rootView: view())
            window.center(); previewWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); previewWindow?.makeKeyAndOrderFront(nil)
    }
    private func inspectorSession(_ windows: AgentInspectorWindows, id: AgentProcessID, selected: AgentProcessID? = nil) -> AgentInspectorSession {
        let session = AgentInspectorSession(navigation: windows.navigation(for: id) ?? .init())
        if let selected { session.navigation.selection = selected }
        session.record(model.latest, instance: id)
        return session
    }
    private func showDetails(_ id: AgentProcessID) {
        if detailWindows.entries[id] == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            let session = inspectorSession(detailWindows, id: id)
            window.title = "Agent 详情 · PID \(id.pid)"
            window.contentViewController = NSHostingController(rootView: AgentDetailsView(model: model, instance: id, session: session, openNetwork: { [weak self] node in self?.showNetwork(id, selected: node) }))
            window.center(); detailWindows.insert(window, session: session, for: id)
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true); detailWindows.entries[id]?.window.makeKeyAndOrderFront(nil)
    }
    private func showNetwork(_ id: AgentProcessID, selected node: AgentProcessID? = nil) {
        popover.performClose(nil)
        let window: NSWindow
        if let existing = networkWindows.entries[id] {
            window = existing.window
            if let node {
                existing.session.navigation.selection = node
                existing.session.navigation.expandedGraph = false
            }
        } else {
            let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
            let size = NSSize(width: min(1280, available.width - 60), height: min(860, available.height - 60))
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            let session = inspectorSession(networkWindows, id: id, selected: node)
            if node != nil { session.navigation.expandedGraph = false }
            window.title = "神经网络 · PID \(id.pid)"
            window.collectionBehavior = [.fullScreenPrimary]
            window.contentViewController = NSHostingController(rootView: AgentDetailsView(model: model, instance: id, session: session, networkWindow: true))
            window.center(); networkWindows.insert(window, session: session, for: id)
        }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    /// Export only this module's own view with live samples, for layout review.
    private func exportDetails(_ id: AgentProcessID, to destination: URL) {
        let host = NSHostingView(rootView: AgentDetailsView(model: model, instance: id))
        let size = NSSize(width: 1140, height: 820)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
        host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: destination, options: .atomic)
            print("Exported agent detail view: \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
        } catch { print("Agent detail export failed: \(error.localizedDescription)") }
    }
    func layoutDescription() -> String {
        guard let button = item.button, let window = button.window else { return "agent status window unavailable" }
        return "agent status frame: \(window.convertToScreen(button.convert(button.bounds, to: nil))) · title: \(button.title)"
    }
    func stop() {
        running = false; timer?.invalidate(); timer = nil
        popover.performClose(nil); stopDismissMonitoring()
        detailWindows.closeAll()
        networkWindows.closeAll()
        previewWindow?.close(); NSStatusBar.system.removeStatusItem(item)
    }
}
