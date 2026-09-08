import Foundation
@testable import MiningOrcaLauncherCore

enum TestSupportError: LocalizedError {
    case missingRustHelper(URL)

    var errorDescription: String? {
        switch self {
        case .missingRustHelper(let url):
            return "real Rust Steam helper is available for integration tests: \(url.path)"
        }
    }
}

private enum TestProcessBootstrap {
    static let logging: Void = {
        LauncherLogging.bootstrap(includeStandardError: true)
    }()
}

func bootstrapTestProcess() {
    _ = TestProcessBootstrap.logging
}

func makeTemporaryRoot(_ name: String) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("miningorca-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func rustHelperExecutable() throws -> URL {
    let url = ProcessInfo.processInfo.environment["MININGORCA_STEAM_HELPER"]
        .map { URL(fileURLWithPath: $0, isDirectory: false) }
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("helper/target/release/miningorca-steam-helper")

    guard FileManager.default.isExecutableFile(atPath: url.path) else {
        throw TestSupportError.missingRustHelper(url)
    }
    return url
}

func testSteamSettings() throws -> LauncherSettings.Steam {
    try LauncherSettingsLoader.load(environment: [:]).settings.steam
}

func testRuntimeSettings() throws -> LauncherSettings.Runtime {
    try LauncherSettingsLoader.load(environment: [:]).settings.runtime
}
