import Foundation
import Darwin

struct WidgetHistoryPoint: Codable, Equatable {
    let sampledAt: Date
    let cpu: Double?
    let memory: Double?
    let download: Double?
    let upload: Double?
    var valid: Bool { [cpu, memory, download, upload].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 } }
}

struct WidgetSnapshot: Codable, Equatable {
    let sampledAt: Date
    let cpu: Double?
    let memory: Double?
    let download: Double?
    let upload: Double?
    let interface: String
    var history: [WidgetHistoryPoint]? = nil

    static var fileURL: URL {
        // NSHomeDirectory points into the extension sandbox, whereas this is the host app's own data file.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/MacVitals/widget-snapshot.json")
    }
    static func read(from url: URL = fileURL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url), data.count <= 16_384,
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              [snapshot.cpu, snapshot.memory, snapshot.download, snapshot.upload].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }),
              snapshot.sampledAt.timeIntervalSinceNow <= 60,
              snapshot.history.map({ points in
                  points.count <= 32 && points.allSatisfy { $0.valid && $0.sampledAt <= snapshot.sampledAt }
                      && zip(points, points.dropFirst()).allSatisfy { $0.sampledAt <= $1.sampledAt }
              }) ?? true else { return nil }
        return snapshot
    }
    func write(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    static let example = WidgetSnapshot(sampledAt: Date(), cpu: 18, memory: 54, download: 256_000, upload: 32_000, interface: "en0")
}
