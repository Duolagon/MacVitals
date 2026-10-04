// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MacVitals", platforms: [.macOS(.v13)], products: [.executable(name: "MacVitals", targets: ["MacVitals"])], targets: [.target(name: "CMetrics", linkerSettings: [.linkedFramework("IOKit")]), .executableTarget(name: "MacVitals", dependencies: ["CMetrics"], linkerSettings: [.linkedFramework("AppKit")])])
