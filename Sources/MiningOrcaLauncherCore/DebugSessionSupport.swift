import Foundation

enum DebugSessionSupport {
    static func configurationSnapshot(
        game: SteamGame,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) throws -> DebugConfigurationSnapshot {
        let paths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let config = paths.config
        try paths.requireSafeRuntimePath(config, fileSystem: fileSystem)
        guard fileSystem.fileExists(atPath: config.path) else {
            return DebugConfigurationSnapshot(data: nil)
        }
        return DebugConfigurationSnapshot(data: try fileSystem.readData(from: config))
    }

    static func restoreConfiguration(
        _ snapshot: DebugConfigurationSnapshot,
        game: SteamGame,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) throws {
        let paths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let directory = paths.runtimeDirectory
        let config = paths.config
        try paths.requireSafeRuntimePath(config, fileSystem: fileSystem)

        guard let data = snapshot.data else {
            try fileSystem.removeItemIfExists(config)
            try fileSystem.removeDirectoryIfEmpty(directory)
            return
        }

        try fileSystem.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileSystem.writeData(data, to: config, options: .atomic)
    }

    static func clearRuntimeLog(
        game: SteamGame,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) throws {
        let paths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let log = paths.log
        try paths.requireSafeRuntimePath(log, fileSystem: fileSystem)
        try fileSystem.removeItemIfExists(log)
    }

    static func launch(game: SteamGame) throws {
        _ = try SystemTool.run(
            "/usr/bin/open",
            arguments: ["steam://run/\(game.appID)"]
        )
    }

    static func pulse(
        game: SteamGame,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) throws -> DebugSessionPulse {
        let paths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let log = paths.log
        try paths.requireSafeRuntimePath(log, fileSystem: fileSystem)

        let attributes: [FileAttributeKey: Any]
        if fileSystem.fileExists(atPath: log.path) {
            attributes = try fileSystem.attributesOfItem(atPath: log.path)
        } else {
            attributes = [:]
        }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date

        return DebugSessionPulse(
            gameProcessRunning: try gameProcessIsRunning(game, fileSystem: fileSystem),
            logExists: !attributes.isEmpty,
            logSize: size,
            logModificationDate: modificationDate
        )
    }

    private static func gameProcessIsRunning(
        _ game: SteamGame,
        fileSystem: FileSystem
    ) throws -> Bool {
        let result = try SystemTool.run(
            "/bin/ps",
            arguments: ["-axww", "-o", "command="],
            check: false
        )
        guard result.status == 0 else {
            throw SystemToolError.failed("/bin/ps", result.status, result.combinedOutput)
        }

        let prefixes = Set([
            game.installDirectory.standardizedFileURL.path + "/",
            fileSystem.resolvingSymlinks(in: game.installDirectory).standardizedFileURL.path + "/",
        ])
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .contains { line in
                let command = String(line)
                return prefixes.contains { command.contains($0) }
            }
    }

}
