// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "herdr-dopa",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "herdr-dopa",
            path: "Sources/herdr-dopa"
        ),
        .testTarget(
            name: "herdr-dopaTests",
            dependencies: ["herdr-dopa"],
            path: "Tests/herdr-dopaTests"
        ),
    ]
)
