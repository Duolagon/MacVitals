import AppKit
import SwiftUI

@main
struct WidgetPreview {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets/screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let cases: [(String, WidgetSnapshot?)] = [
            ("widget-telemetry", WidgetSnapshot.read() ?? .example),
            ("widget-telemetry-wide-values", .init(sampledAt: now.addingTimeInterval(-600), cpu: 100, memory: 100, download: 999_900_000, upload: 999_900_000, interface: "en0")),
            ("widget-telemetry-missing", nil)
        ]
        for (name, snapshot) in cases {
            let view = TelemetryWidgetView(snapshot: snapshot, date: now)
                .padding(16).frame(width: 344, height: 164)
                .background(TelemetryWidgetBackground())
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            guard let image = renderer.cgImage else { fatalError("Widget render failed") }
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            let path = directory.appendingPathComponent("\(name).png")
            try data.write(to: path)
            print(path.path)
        }
        let large = TelemetryWidgetView(snapshot: WidgetSnapshot.read() ?? .example, date: now, expanded: true)
            .padding(16).frame(width: 344, height: 344)
            .background(TelemetryWidgetBackground()).clipShape(RoundedRectangle(cornerRadius: 28))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: large)
        renderer.scale = 3
        guard let image = renderer.cgImage else { fatalError("Large widget render failed") }
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try data.write(to: directory.appendingPathComponent("widget-telemetry-large.png"))
    }
}
