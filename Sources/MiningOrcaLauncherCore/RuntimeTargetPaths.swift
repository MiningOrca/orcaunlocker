import Foundation

struct RuntimeTargetPaths: Sendable {
    let gamePaths: RuntimeGamePaths
    let target: SteamAPITarget

    init(
        game: SteamGame,
        target: SteamAPITarget,
        runtimeSettings: LauncherSettings.Runtime
    ) {
        self.gamePaths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        self.target = target
    }

    /// Proxy backups are keyed by the target's relative directory. The path is
    /// stable even if a later game update adds or removes another Steam API copy.
    var backup: URL {
        var directory = gamePaths.backupsDirectory
        let components = target.relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .dropLast()
        for component in components {
            directory.appendPathComponent(String(component), isDirectory: true)
        }
        return directory.appendingPathComponent("libsteam_api.original", isDirectory: false)
    }

    var originalSibling: URL {
        target.url
            .deletingLastPathComponent()
            .appendingPathComponent("libsteam_api_o.dylib", isDirectory: false)
    }

    var originalSiblingStaging: URL {
        target.url.deletingLastPathComponent()
            .appendingPathComponent(".libsteam_api_o.orcaunlocker.tmp", isDirectory: false)
    }

    var proxyStaging: URL {
        target.url.deletingLastPathComponent()
            .appendingPathComponent(".libsteam_api.orcaunlocker.tmp", isDirectory: false)
    }

    var restoreStaging: URL {
        target.url.deletingLastPathComponent()
            .appendingPathComponent(".libsteam_api.restore.orcaunlocker.tmp", isDirectory: false)
    }

    var proxyInstallStagingFiles: [URL] {
        [originalSiblingStaging, proxyStaging]
    }

    var proxyStagingFiles: [URL] {
        proxyInstallStagingFiles + [restoreStaging]
    }
}
