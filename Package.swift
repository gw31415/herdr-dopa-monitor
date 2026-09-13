// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "herdr-dopa-monitor",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "herdr-dopa-monitor",
            path: "Sources/herdr-dopa-monitor"
        ),
        .testTarget(
            name: "herdr-dopa-monitorTests",
            dependencies: ["herdr-dopa-monitor"],
            path: "Tests/herdr-dopa-monitorTests"
        ),
    ]
)
