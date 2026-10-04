import AppKit
import SwiftUI
import Charts
import Darwin
import IOKit.ps
import ServiceManagement
import CMetrics

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private let monitor = Monitor()
    private let dashboard = DashboardModel()
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var detailsWindow: NSWindow?
    private let detailsQueue = DispatchQueue(label: "local.macvitals.details", qos: .utility)
    private var detailsMonitor: DetailsMonitor?
    private var detailsTimer: Timer?
    private var detailsBusy = false
    private let menu = NSMenu()
    private var interval: Double { let v = UserDefaults.standard.double(forKey: "interval"); return [1.0, 2, 5, 10].contains(v) ? v : 2 }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusName = "MacVitals"
        item = NSStatusBar.system.statusItem(withLength: StatusBarText.width)
        item.autosaveName = statusName
        item.button?.font = StatusBarText.font
        item.button?.toolTip = "MacVitals · 点击查看系统状态"
        item.button?.target = self
        item.button?.action = #selector(showDashboard)
        popover.delegate = self
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 660)
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: dashboard, settings: { [weak self] in self?.showSettings() }, showDetails: { [weak self] in self?.showDetails() }))
        let refresh = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for value in [1, 2, 5, 10] {
            let row = NSMenuItem(title: "\(value) 秒", action: #selector(changeInterval(_:)), keyEquivalent: "")
            row.tag = value; row.target = self; row.state = Double(value) == interval ? .on : .off; submenu.addItem(row)
        }
        refresh.submenu = submenu; menu.addItem(refresh)
        let login = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
        let activity = NSMenuItem(title: "打开活动监视器", action: #selector(openActivity), keyEquivalent: "")
        activity.target = self; menu.addItem(activity)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MacVitals", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        update(); startTimer()
        if CommandLine.arguments.contains("--status-layout-diagnose") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let button = self.item.button, let window = button.window else {
                    print("status item window unavailable"); NSApp.terminate(nil); return
                }
                print("status frame: \(window.convertToScreen(button.convert(button.bounds, to: nil)))")
                print("status title: \(button.title)")
                for screen in NSScreen.screens { print("screen: \(screen.frame), visible: \(screen.visibleFrame)") }
                print("autosave: \(self.item.autosaveName ?? "nil")")
                NSApp.terminate(nil)
            }
        }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.updateDetails() }
        RunLoop.main.add(t, forMode: .common); detailsTimer = t
        updateDetails()
        if CommandLine.arguments.contains("--show-details") { showDetails() }
    }
    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    private func update() {
        let s = monitor.sample()
        item.button?.image = nil
        item.button?.title = StatusBarText.title(cpu: s.cpu, memory: s.memoryPercent, download: s.downloadBytesPerSecond, upload: s.uploadBytesPerSecond)
        item.button?.setAccessibilityLabel(StatusBarText.title(cpu: s.cpu, memory: s.memoryPercent, download: s.downloadBytesPerSecond, upload: s.uploadBytesPerSecond))
        item.button?.toolTip = "MacVitals · \(s.networkInterface) · 下载 \(MetricsFormat.rate(s.downloadBytesPerSecond)) · 上传 \(MetricsFormat.rate(s.uploadBytesPerSecond))"
        dashboard.record(s)
    }
    private func updateDetails() {
        guard !detailsBusy else { return }
        detailsBusy = true
        let snapshot = dashboard.latest
        detailsQueue.async { [weak self] in
            guard let self else { return }
            if self.detailsMonitor == nil { self.detailsMonitor = DetailsMonitor() }
            let sections = self.detailsMonitor!.sample(snapshot)
            DispatchQueue.main.async {
                self.dashboard.details = sections
                self.dashboard.detailsUpdated = Date()
                self.detailsBusy = false
            }
        }
    }
    private func showDetails() {
        popover.performClose(nil)
        if detailsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "MacVitals · 系统详情"
            window.contentViewController = NSHostingController(rootView: DetailsView(model: dashboard))
            window.isReleasedWhenClosed = false; window.center(); detailsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        detailsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func showDashboard() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            startDismissMonitoring()
        }
    }
    private func startDismissMonitoring() {
        stopDismissMonitoring()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.popover.performClose(nil); return nil }
            } else if event.window !== self.popover.contentViewController?.view.window && event.window !== self.item.button?.window {
                self.popover.performClose(nil)
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }
    private func stopDismissMonitoring() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        outsideClickMonitor = nil; localClickMonitor = nil; resignObserver = nil
    }
    func popoverDidClose(_ notification: Notification) { stopDismissMonitoring() }
    private func showSettings() {
        guard let button = item.button else { return }
        popover.performClose(nil)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }
    @objc private func changeInterval(_ sender: NSMenuItem) {
        UserDefaults.standard.set(Double(sender.tag), forKey: "interval")
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }; startTimer()
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
    @objc private func openActivity() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { stopDismissMonitoring(); timer?.invalidate(); detailsTimer?.invalidate() }
}
if CommandLine.arguments.contains("--sensors") {
    exit(Int32(mv_smc_dump()))
} else if CommandLine.arguments.contains("--details-diagnose") {
    let m = Monitor(); let details = DetailsMonitor(); _ = details.sample(m.sample()); Thread.sleep(forTimeInterval: 1)
    for section in details.sample(m.sample()) { print("\n[\(section.title)]"); for row in section.rows { print("\(row.label): \(row.value)") } }
} else if CommandLine.arguments.contains("--diagnose") {
    let m = Monitor(); _ = m.sample(); Thread.sleep(forTimeInterval: 1)
    let s = m.sample()
    print("CPU: \(s.cpu.map { String(format: "%.1f%%", $0) } ?? "unavailable")\n内存: \(s.memory)\n网络: \(s.networkInterface) 下载 \(MetricsFormat.rate(s.downloadBytesPerSecond)) 上传 \(MetricsFormat.rate(s.uploadBytesPerSecond))\n交换: \(s.swap) · 分配 \(s.swapAllocated)\n磁盘: \(s.disk)\n电池: \(s.battery)\n风扇: \(s.fans)\n温度: \(s.temperature)\n运行时间: \(s.uptime)")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
