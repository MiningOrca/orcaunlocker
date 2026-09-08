// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiningOrcaLauncher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "orcaunlocker",
            targets: ["DlcUnlockerCLI"]
        ),
        .executable(
            name: "OrcaUnlockerApp",
            targets: ["MiningOrcaApp"]
        ),
    ],
    dependencies: [
        // 1.8.x is the newest swift-log line that still supports Swift tools 6.0.
        .package(
            url: "https://github.com/apple/swift-log.git",
            .upToNextMinor(from: "1.8.0")
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            .upToNextMinor(from: "1.8.2")
        ),
        // This Command Line Tools setup does not ship the built-in Testing module.
        // Pin the official Swift 6.0.3 release so tests stay compatible with
        // the package's Swift 6.0 toolchain without affecting runtime targets.
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "18c42c19cac3fafd61cab1156d4088664b7424ae"
        ),
    ],
    targets: [
        .target(
            name: "MiningOrcaLauncherCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "DlcUnlockerCLI",
            dependencies: [
                "MiningOrcaLauncherCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MiningOrcaLauncherCoreTests",
            dependencies: [
                "MiningOrcaLauncherCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .executableTarget(
            name: "MiningOrcaApp",
            dependencies: ["MiningOrcaLauncherCore"]
        ),
    ]
)
