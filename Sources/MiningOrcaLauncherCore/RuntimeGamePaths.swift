import Foundation

struct RuntimeGamePaths: Sendable {
    let game: SteamGame
    let runtimeSettings: LauncherSettings.Runtime

    init(game: SteamGame, runtimeSettings: LauncherSettings.Runtime) {
        self.game = game
        self.runtimeSettings = runtimeSettings
    }

    var runtimeDirectory: URL {
        game.installDirectory.appendingPathComponent(runtimeSettings.installDirectoryName, isDirectory: true)
    }

    var backupsDirectory: URL {
        runtimeDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    var injectDylib: URL {
        runtimeDirectory.appendingPathComponent("orcaunlocker.dylib", isDirectory: false)
    }

    var injectPrefixWrapper: URL {
        runtimeDirectory.appendingPathComponent("run-prefix.sh", isDirectory: false)
    }

    var injectCommandWrapper: URL {
        runtimeDirectory.appendingPathComponent("run-command.sh", isDirectory: false)
    }

    var injectRuntimeFiles: [URL] {
        [injectDylib, injectPrefixWrapper, injectCommandWrapper]
    }

    var config: URL {
        runtimeDirectory.appendingPathComponent(runtimeSettings.configFileName, isDirectory: false)
    }

    var log: URL {
        runtimeDirectory.appendingPathComponent(runtimeSettings.logFileName, isDirectory: false)
    }

    var dlcCatalog: URL {
        runtimeDirectory.appendingPathComponent("dlc-catalog.txt", isDirectory: false)
    }

    func requireSafeRuntimePath(
        _ url: URL,
        fileSystem: FileSystem = .default
    ) throws {
        try requireSafeRuntimePaths([url], fileSystem: fileSystem)
    }

    func requireSafeRuntimePaths(
        _ urls: [URL],
        fileSystem: FileSystem = .default
    ) throws {
        _ = try PathSafety.requireNonSymlinkInside(
            runtimeDirectory,
            inside: game.installDirectory,
            fileSystem: fileSystem
        )
        for url in urls {
            _ = try PathSafety.requireNonSymlinkInside(
                url,
                inside: game.installDirectory,
                fileSystem: fileSystem
            )
        }
    }
}
