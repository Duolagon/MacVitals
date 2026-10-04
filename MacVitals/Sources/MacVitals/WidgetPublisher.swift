import Foundation
import WidgetKit
import OSLog

/// Publish each new host sample; WidgetKit still controls when requests are serviced.
final class WidgetPublisher {
    private let queue = DispatchQueue(label: "local.macvitals.widget-snapshot", qos: .utility)
    private var lastWrite: TimeInterval?
    private var lastReload: TimeInterval?
    private var wroteValidSample = false
    private var history: [WidgetHistoryPoint] = []
    private let logger = Logger(subsystem: "local.macvitals.monitor", category: "widgetProbe")
    private let probeInterval: TimeInterval? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--widget-refresh-probe"), index + 1 < CommandLine.arguments.count,
              let seconds = Double(CommandLine.arguments[index + 1]), [1.0, 2, 5, 10, 30, 60, 300].contains(seconds) else { return nil }
        return seconds
    }()
    init() {
        if let probeInterval {
            logger.notice("PROBE interval=\(probeInterval, privacy: .public)")
            WidgetCenter.shared.getCurrentConfigurations { [logger] result in
                switch result {
                case .success(let widgets):
                    logger.notice("PROBE configurations count=\(widgets.count, privacy: .public) kinds=\(widgets.map(\.kind).joined(separator: ","), privacy: .public)")
                case .failure(let error): logger.error("PROBE configurations failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            logger.debug("PROBE interval=host-setting")
        }
    }
    func record(_ sample: Snapshot) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let valid = sample.cpu != nil && sample.downloadBytesPerSecond != nil
        let probing = probeInterval != nil
        guard lastWrite == nil || uptime - (lastWrite ?? 0) >= 0.95 || (valid && !wroteValidSample) else { return }
        lastWrite = uptime
        if valid { wroteValidSample = true }
        let reload = valid && (lastReload == nil || uptime - (lastReload ?? 0) >= (probeInterval.map { $0 - 0.05 } ?? 0.95))
        if reload { lastReload = uptime }
        let now = Date()
        history.append(.init(sampledAt: now, cpu: sample.cpu, memory: sample.memoryPercent,
                             download: sample.downloadBytesPerSecond, upload: sample.uploadBytesPerSecond))
        history.removeAll { now.timeIntervalSince($0.sampledAt) > 60 }
        if history.count > 32 { history.removeFirst(history.count - 32) }
        var snapshot = WidgetSnapshot(sampledAt: now, cpu: sample.cpu, memory: sample.memoryPercent,
                                      download: sample.downloadBytesPerSecond, upload: sample.uploadBytesPerSecond, interface: sample.networkInterface)
        snapshot.history = history
        queue.async {
            do {
                try snapshot.write()
                if probing {
                    self.logger.notice("PROBE sample epoch=\(snapshot.sampledAt.timeIntervalSince1970, privacy: .public) request=\(reload, privacy: .public)")
                } else {
                    self.logger.debug("PROBE sample epoch=\(snapshot.sampledAt.timeIntervalSince1970, privacy: .public) request=\(reload, privacy: .public)")
                }
                if reload {
                    // Update only kinds the user has actually added.
                    WidgetCenter.shared.getCurrentConfigurations { [logger = self.logger] result in
                        guard case .success(let widgets) = result else {
                            logger.error("Widget configuration query failed")
                            return
                        }
                        for kind in Set(widgets.map(\.kind)).intersection(["MacVitals.Network", "MacVitals.System"]) {
                            WidgetCenter.shared.reloadTimelines(ofKind: kind)
                        }
                    }
                }
            } catch { NSLog("MacVitals widget snapshot: %@", error.localizedDescription) }
        }
    }
}
