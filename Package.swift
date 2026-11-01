// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Soundctl",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Soundctl",
            path: "Sources/Soundctl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SoundctlTests",
            dependencies: ["Soundctl"],
            path: "Tests/SoundctlTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
