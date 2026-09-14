// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "herdr-dopa-monitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "herdr-dopa-monitor", targets: ["HerdrDopaMonitor"]),
    ],
    targets: [
        .executableTarget(
            name: "HerdrDopaMonitor",
            path: "Sources/HerdrDopaMonitor",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "HerdrDopaMonitorTests",
            dependencies: ["HerdrDopaMonitor"],
            path: "tests/HerdrDopaMonitorTests"
        ),
    ]
)
