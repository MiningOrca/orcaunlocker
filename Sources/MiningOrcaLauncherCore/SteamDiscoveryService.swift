import Foundation

struct SteamDiscoveryService {
    private let helper: SteamHelperClient
    private let fileSystem: FileSystem

    init(helper: SteamHelperClient, fileSystem: FileSystem = .default) {
        self.helper = helper
        self.fileSystem = fileSystem
    }

    func installedLibrary() throws -> SteamLibrary {
        try helper.installedLibrary()
    }

    func installedGames() throws -> [SteamGame] {
        try installedLibrary().games
    }

    func targets(for game: SteamGame) throws -> [SteamAPITarget] {
        guard let enumerator = fileSystem.enumerator(
            at: game.installDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "libsteam_api.dylib" else { continue }
            let values = try? fileSystem.resourceValues(for: url, keys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            urls.append(url)
        }

        let targets = urls
            .map { SteamAPITarget(url: $0, gameDirectory: game.installDirectory) }
            .sorted {
                $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
            }

        LauncherLog.logger.info(
            "Discovered \(targets.count) Steam API \(targets.count == 1 ? "library" : "libraries") for \(game.name)",
            metadata: [
                "app_id": "\(game.appID)",
                "steam_api_count": "\(targets.count)",
            ]
        )
        if let injectTarget = targets.first(where: { $0.recommendedTransport == .inject }) {
            LauncherLog.logger.info(
                "Recommended Inject for \(game.name) because Steam API library \(injectTarget.relativePath) is inside a macOS application bundle",
                metadata: [
                    "app_id": "\(game.appID)",
                    "recommended_transport": .string(SteamTransport.inject.rawValue),
                    "reason": "steam_api_inside_app_bundle",
                    "target": "\(injectTarget.relativePath)",
                ]
            )
        } else if !targets.isEmpty {
            LauncherLog.logger.info(
                "Recommended Proxy for \(game.name) because no discovered Steam API library is inside a macOS application bundle",
                metadata: [
                    "app_id": "\(game.appID)",
                    "recommended_transport": .string(SteamTransport.proxy.rawValue),
                    "reason": "steam_api_outside_app_bundle",
                ]
            )
        }

        if targets.count > 1 {
            for (index, target) in targets.enumerated() {
                LauncherLog.logger.info(
                    "Steam API library \(index + 1)/\(targets.count): \(target.relativePath)",
                    metadata: [
                        "app_id": "\(game.appID)",
                        "target": "\(target.relativePath)",
                    ]
                )
            }
        }

        return targets
    }
}
