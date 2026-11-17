// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Earmark",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Earmark", path: "Sources/Earmark"),
        .testTarget(name: "EarmarkTests", dependencies: ["Earmark"], path: "Tests/EarmarkTests"),
    ]
)
