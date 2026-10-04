import AppKit
import SwiftUI
import Charts
import Darwin
import IOKit.ps
import ServiceManagement
import CMetrics

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var agentsController: AgentsController?
    private var item: NSStatusItem!
    private var timer: Timer?
    private let monitor = Monitor()
    private let dashboard = DashboardModel()
    private let widgetPublisher = WidgetPublisher()
    private let popover = NSPopover()
    private var localClickMonitor: Any?
    private var previewWindow: NSWindow?
    private var widgetDashboardWindow: NSWindow?
    private var widgetOnly: Bool { UserDefaults.standard.bool(forKey: "widgetOnly") }
    private var detailsWindow: NSWindow?
    private let detailsQueue = DispatchQueue(label: "local.macvitals.details", qos: .utility)
    private var detailsMonitor: DetailsMonitor?
    private var detailsTimer: Timer?
    private var detailsSampling = DetailSamplingGate()
    private var detailsNeedsReset = false
    private let powerDemand = PowerSamplingDemand()
    private let menu = NSMenu()
    private let interval: Double = 2
    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusName = "MacVitals"
        item = NSStatusBar.system.statusItem(withLength: StatusBarText.width)
        item.autosaveName = statusName
        item.button?.font = StatusBarText.font
        item.button?.toolTip = "MacVitals · 点击查看系统状态"
        item.button?.target = self
        item.button?.action = #selector(showDashboard)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 440, height: MonitorStyle.panelHeight)
        menu.addItem(NSMenuItem(title: "CPU / 内存 / 网速：每 2 秒采集", action: nil, keyEquivalent: ""))
        let widgetsOnly = NSMenuItem(title: "仅显示小组件（隐藏顶栏）", action: #selector(toggleWidgetOnly(_:)), keyEquivalent: "")
        widgetsOnly.target = self; widgetsOnly.state = widgetOnly ? .on : .off; menu.addItem(widgetsOnly)
        let login = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
        let activity = NSMenuItem(title: "打开活动监视器", action: #selector(openActivity), keyEquivalent: "")
        activity.target = self; menu.addItem(activity)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MacVitals", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        update(); startTimer()
        agentsController = AgentsController()
        item.isVisible = !widgetOnly
        agentsController?.setMenuBarVisible(!widgetOnly)
        if CommandLine.arguments.contains("--widget-mode-diagnose") {
            let original = widgetOnly
            let started = Date()
            setWidgetOnly(true)
            print("widget-only: networkVisible=\(item.isVisible) agentVisible=\(agentsController?.menuBarIsVisible ?? true) dashboardVisible=\(widgetDashboardWindow?.isVisible ?? false)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                let advanced = WidgetSnapshot.read().map { $0.sampledAt > started.addingTimeInterval(1) } ?? false
                self.setWidgetOnly(original)
                print("widget-only sampling advanced=\(advanced); restored=\(self.widgetOnly == original) networkVisible=\(self.item.isVisible)")
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--preview-agents") { agentsController?.showPreview() }
        if CommandLine.arguments.contains("--status-layout-diagnose") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let button = self.item.button, let window = button.window else {
                    print("status item window unavailable"); NSApp.terminate(nil); return
                }
                print("status frame: \(window.convertToScreen(button.convert(button.bounds, to: nil)))")
                print("status title: \(button.title)")
                print(self.agentsController?.layoutDescription() ?? "agent module unavailable")
                for screen in NSScreen.screens {
                    print("screen: \(screen.frame), visible: \(screen.visibleFrame)")
                    print("menu right area: \(String(describing: screen.auxiliaryTopRightArea)), left area: \(String(describing: screen.auxiliaryTopLeftArea))")
                }
                print("autosave: \(self.item.autosaveName ?? "nil")")
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--show-details") { showDetails() }
        if CommandLine.arguments.contains("--show-dashboard") {
            DispatchQueue.main.async { [weak self] in self?.showDashboard() }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--export-screenshot"), index + 1 < CommandLine.arguments.count {
            let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.exportScreenshot(to: destination)
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--preview-dashboard") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: MonitorStyle.panelHeight), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "MacVitals · 实时面板预览"
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: DashboardView(model: dashboard, settings: { [weak self] in self?.showSettings() }, showDetails: { [weak self] in self?.showDetails() }))
            window.isReleasedWhenClosed = false; window.center()
            previewWindow = window
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
    }
    /// Capture only the application's own full panel, using live samples.
    private func exportScreenshot(to destination: URL) {
        let root = DashboardView(model: dashboard, settings: {}, showDetails: {}, exportMode: true)
            .fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 2000)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("Screenshot render failed"); return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { print("PNG encoding failed"); return }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            print("Exported live panel: \(destination.path) · \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
        } catch { print("Screenshot export failed: \(error.localizedDescription)") }
    }
    private func startTimer() {
        timer?.invalidate()
        let samplingInterval = CommandLine.arguments.contains("--widget-refresh-probe") ? 1 : interval
        let t = Timer(timeInterval: samplingInterval, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    private func update(forceSlow: Bool = false) {
        let windows = [previewWindow, widgetDashboardWindow, detailsWindow].compactMap { $0 }
        let visible = popover.isShown || windows.contains { $0.isVisible && !$0.isMiniaturized }
        let s = monitor.sample(forceSlow: forceSlow, includeSecondary: visible || forceSlow)
        if CommandLine.arguments.contains("--sampling-probe") {
            print("sampling system primary=cpu,memory,network secondary=\(visible || forceSlow) details=\(detailsSampling.active)")
            fflush(stdout)
        }
        item.button?.image = nil
        let title = StatusBarText.title(download: s.downloadBytesPerSecond, upload: s.uploadBytesPerSecond)
        item.button?.title = title
        item.button?.setAccessibilityLabel("下载 \(MetricsFormat.rate(s.downloadBytesPerSecond))，上传 \(MetricsFormat.rate(s.uploadBytesPerSecond))")
        item.button?.toolTip = "MacVitals · \(s.networkInterface)\n下载 \(MetricsFormat.rate(s.downloadBytesPerSecond)) · 上传 \(MetricsFormat.rate(s.uploadBytesPerSecond))"
        dashboard.record(s)
        widgetPublisher.record(s)
    }
    private func startDetailsSampling() {
        guard detailsWindow?.isVisible == true, detailsWindow?.isMiniaturized == false,
              detailsSampling.resume() else { return }
        detailsNeedsReset = true
        powerDemand.start()
        dashboard.details = []
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.updateDetails() }
        RunLoop.main.add(timer, forMode: .common); detailsTimer = timer
        updateDetails()
        let generation = detailsSampling.generation
        // Establish a fresh rate baseline promptly when opening or restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.detailsSampling.active, self.detailsSampling.generation == generation else { return }
            self.updateDetails()
        }
    }
    private func stopDetailsSampling() {
        powerDemand.stop()
        detailsSampling.pause(); detailsTimer?.invalidate(); detailsTimer = nil
    }
    private func updateDetails() {
        powerDemand.renew()
        guard let token = detailsSampling.begin() else { return }
        let reset = detailsNeedsReset; detailsNeedsReset = false
        let snapshot = dashboard.latest
        detailsQueue.async { [weak self] in
            guard let self else { return }
            if self.detailsMonitor == nil { self.detailsMonitor = DetailsMonitor() }
            if reset { self.detailsMonitor?.resetRates() }
            let sections = self.detailsMonitor!.sample(snapshot)
            DispatchQueue.main.async {
                if self.detailsSampling.finish(token) {
                    self.dashboard.details = sections; self.dashboard.detailsUpdated = Date()
                } else if self.detailsSampling.active { self.updateDetails() }
            }
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === detailsWindow { stopDetailsSampling(); detailsWindow = nil }
        else if window === widgetDashboardWindow { widgetDashboardWindow = nil }
        else if window === previewWindow { previewWindow = nil }
        else { return }
        window.contentViewController = nil; window.delegate = nil
    }
    func windowDidMiniaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === detailsWindow { stopDetailsSampling() }
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === detailsWindow { update(forceSlow: true); startDetailsSampling() }
    }
    private func showDetails() {
        popover.performClose(nil)
        if detailsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "MacVitals · 系统详情"
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: DetailsView(model: dashboard))
            window.isReleasedWhenClosed = false; window.center(); detailsWindow = window
        }
        update(forceSlow: true)
        NSApp.activate(ignoringOtherApps: true)
        if detailsWindow?.isMiniaturized == true { detailsWindow?.deminiaturize(nil) }
        detailsWindow?.makeKeyAndOrderFront(nil)
        startDetailsSampling()
    }
    @objc private func showDashboard() {
        if widgetOnly { showWidgetDashboard(); return }
        guard let button = item.button else { return }
        toggleDashboard(relativeTo: button)
    }
    private func showWidgetDashboard() {
        if widgetDashboardWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: MonitorStyle.panelHeight), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "MacVitals · 小组件设置"
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: DashboardView(model: dashboard, settings: { [weak self] in self?.showSettings() }, showDetails: { [weak self] in self?.showDetails() }))
            window.center(); widgetDashboardWindow = window
        }
        update(forceSlow: true)
        NSApp.activate(ignoringOtherApps: true)
        if widgetDashboardWindow?.isMiniaturized == true { widgetDashboardWindow?.deminiaturize(nil) }
        widgetDashboardWindow?.makeKeyAndOrderFront(nil)
    }
    private func toggleDashboard(relativeTo button: NSButton) {
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.contentViewController = NSHostingController(rootView: DashboardView(model: dashboard, settings: { [weak self] in self?.showSettings() }, showDetails: { [weak self] in self?.showDetails() }))
            update(forceSlow: true)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            startDismissMonitoring()
        }
    }
    private func startDismissMonitoring() {
        stopDismissMonitoring()
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.keyCode == 53, event.window === self.popover.contentViewController?.view.window {
                self.popover.performClose(nil)
                return nil
            }
            return event
        }
    }
    func popoverDidClose(_ notification: Notification) { stopDismissMonitoring(); popover.contentViewController = nil }
    private func stopDismissMonitoring() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        localClickMonitor = nil
    }
    private func showSettings() {
        popover.performClose(nil)
        if widgetOnly, let view = widgetDashboardWindow?.contentView {
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - 20, y: view.bounds.maxY - 20), in: view)
            return
        }
        guard let button = item.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }
    @objc private func toggleWidgetOnly(_ sender: NSMenuItem) {
        let enabled = !widgetOnly
        setWidgetOnly(enabled)
        sender.state = enabled ? .on : .off
    }
    private func setWidgetOnly(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "widgetOnly")
        popover.performClose(nil)
        item.isVisible = !enabled
        agentsController?.setMenuBarVisible(!enabled)
        if enabled { showWidgetDashboard() } else { widgetDashboardWindow?.close() }
    }
    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let alert = NSAlert(); alert.messageText = "无法设置登录启动"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "macvitals" && $0.host == "dashboard" }) { showDashboard() }
    }
    @objc private func openActivity() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { powerDemand.stop(); agentsController?.stop(); stopDismissMonitoring(); timer?.invalidate(); detailsTimer?.invalidate() }
}
if CommandLine.arguments.contains("--agents-diagnose") {
    let m = AgentMonitor(); let desktops = AgentRecognition.desktops()
    _ = m.sample(desktops: desktops); Thread.sleep(forTimeInterval: 1)
    let snapshot = m.sample(desktops: AgentRecognition.desktops())
    print("Agents: \(snapshot.usages.count) · available \(snapshot.available)")
    print("Collector: \(m.discoveryCount) discovered · \(m.metadataReadCount) metadata reads · \(m.resourceReadCount) resource reads")
    for usage in snapshot.usages {
        print("\(usage.kind.rawValue) PID \(usage.id.pid) · \(usage.processes.count) processes · CPU \(usage.cpu.map { String(format: "%.1f%%", $0) } ?? "sampling") · RSS \(usage.memory.map { MetricsFormat.bytes($0) } ?? "unavailable") · read \(MetricsFormat.rate(usage.readRate)) · write \(MetricsFormat.rate(usage.writeRate))")
    }
} else if CommandLine.arguments.contains("--sensors") {
    exit(Int32(mv_smc_dump()))
} else if CommandLine.arguments.contains("--details-diagnose") {
    let m = Monitor(); let details = DetailsMonitor(); _ = details.sample(m.sample()); Thread.sleep(forTimeInterval: 1)
    for section in details.sample(m.sample()) { print("\n[\(section.title)]"); for row in section.rows { print("\(row.label): \(row.value)") } }
} else if CommandLine.arguments.contains("--diagnose") {
    let m = Monitor(); _ = m.sample(); Thread.sleep(forTimeInterval: 1)
    let s = m.sample()
    print("CPU: \(s.cpu.map { String(format: "%.1f%%", $0) } ?? "unavailable")\n内存: \(s.memory)\n网络: \(s.networkInterface) 下载 \(MetricsFormat.rate(s.downloadBytesPerSecond)) 上传 \(MetricsFormat.rate(s.uploadBytesPerSecond))\nIPv4: \(s.networkIPv4.isEmpty ? "未分配" : s.networkIPv4)\nIPv6: \(s.networkIPv6.isEmpty ? "未分配" : s.networkIPv6)\n交换: \(s.swap) · 分配 \(s.swapAllocated)\n磁盘: \(s.disk)\n电池: \(s.battery)\n风扇: \(s.fans)\n温度: \(s.temperature)\n运行时间: \(s.uptime)")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
