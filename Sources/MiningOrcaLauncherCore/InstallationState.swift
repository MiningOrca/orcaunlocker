import Foundation

package enum InstallationKind: String, Sendable {
    case untouched
    case proxy
    case inject
    case broken
}

package enum InstalledRuntimeIdentity: Equatable, Sendable {
    case none
    case current(RuntimeProfile)
    case other

    package var displayText: String {
        switch self {
        case .none:
            return "none"
        case .current(let profile):
            return profile.rawValue
        case .other:
            return "other/older runtime"
        }
    }
}

package struct InstallationState: Sendable {
    package let kind: InstallationKind
    package let transport: SteamTransport?
    package let runtimeIdentity: InstalledRuntimeIdentity
    let targetExists: Bool
    let originalSiblingExists: Bool
    let backupExists: Bool
    let injectDylibExists: Bool
    let injectPrefixWrapperExists: Bool
    let injectCommandWrapperExists: Bool
    package let launchOptionsHookPresent: Bool?
    package let launchOptionsHookCount: Int?
    let launchOptions: String?
    let localConfigURL: URL?
    package let localConfigURLs: [URL]
    let configExists: Bool
    let logExists: Bool
    let dlcCatalogExists: Bool
    package let issues: [String]

    var hasInjectFootprint: Bool {
        transport == .inject
            || injectDylibExists
            || injectPrefixWrapperExists
            || injectCommandWrapperExists
            || (launchOptionsHookCount ?? 0) > 0
    }

    func matchesRuntime(
        transport expectedTransport: SteamTransport,
        profile expectedProfile: RuntimeProfile
    ) -> Bool {
        kind == expectedTransport.installationKind
            && transport == expectedTransport
            && runtimeIdentity == .current(expectedProfile)
    }
}

enum InstallationStateError: Error, LocalizedError {
    case malformedHash(String)

    var errorDescription: String? {
        switch self {
        case .malformedHash(let output):
            return "Could not parse shasum output: \(output)"
        }
    }
}

enum InjectLaunchOptions {
    static func containsHook(_ value: String, gamePaths: RuntimeGamePaths) -> Bool {
        let lowered = value.lowercased()
        return [gamePaths.injectPrefixWrapper, gamePaths.injectCommandWrapper].contains { wrapper in
            let suffix = "/\(wrapper.deletingLastPathComponent().lastPathComponent)/\(wrapper.lastPathComponent)"
                .lowercased()
            return lowered.contains(suffix)
        }
    }

    static func hookCoverage(
        in snapshot: SteamLaunchOptionsSnapshot,
        gamePaths: RuntimeGamePaths
    ) -> InjectLaunchOptionsHookCoverage {
        let hookedAccounts = snapshot.accounts.filter { containsHook($0.launchOptions, gamePaths: gamePaths) }
        let hookedLocalConfigs = Set(hookedAccounts.map { $0.localConfigURL.standardizedFileURL })

        var seen = Set<URL>()
        let expectedLocalConfigs = snapshot.accounts
            .map(\.localConfigURL)
            .map(\.standardizedFileURL)
            .filter { seen.insert($0).inserted }

        return InjectLaunchOptionsHookCoverage(
            hookedAccounts: hookedAccounts,
            expectedLocalConfigURLs: expectedLocalConfigs,
            allExpectedConfigsHooked: !expectedLocalConfigs.isEmpty
                && expectedLocalConfigs.allSatisfy { hookedLocalConfigs.contains($0.standardizedFileURL) }
        )
    }
}

struct InjectLaunchOptionsHookCoverage {
    let hookedAccounts: [SteamLaunchOptionsAccount]
    let expectedLocalConfigURLs: [URL]
    let allExpectedConfigsHooked: Bool

    var anyHook: Bool {
        !hookedAccounts.isEmpty
    }
}

struct InstallationGameEvidence {
    let injectDylibExists: Bool
    let injectPrefixWrapperExists: Bool
    let injectCommandWrapperExists: Bool
    let configExists: Bool
    let logExists: Bool
    let dlcCatalogExists: Bool
    let launchInspectionErrorDescription: String?
    let launchOptionsHookPresent: Bool?
    let launchOptionsHookCount: Int?
    let launchOptions: String?
    let localConfigURL: URL?
    let localConfigURLs: [URL]
    let anyLaunchOptionsHook: Bool
}

struct InstallationTargetEvidence {
    let paths: RuntimeTargetPaths
    let targetExists: Bool
    let originalSiblingExists: Bool
    let backupExists: Bool
}

struct InstallationStateDetector {
    private let helper: SteamHelperClient
    private let runtimeRepository: RuntimeRepository
    private let runtimeSettings: LauncherSettings.Runtime
    private let fileSystem: FileSystem

    init(
        helper: SteamHelperClient,
        runtimeRepository: RuntimeRepository,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) {
        self.helper = helper
        self.runtimeRepository = runtimeRepository
        self.runtimeSettings = runtimeSettings
        self.fileSystem = fileSystem
    }

    func gameEvidence(for game: SteamGame) -> InstallationGameEvidence {
        let gamePaths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let injectDylibExists = fileSystem.fileExists(atPath: gamePaths.injectDylib.path)
        let injectPrefixWrapperExists = fileSystem.fileExists(atPath: gamePaths.injectPrefixWrapper.path)
        let injectCommandWrapperExists = fileSystem.fileExists(atPath: gamePaths.injectCommandWrapper.path)
        let configExists = fileSystem.fileExists(atPath: gamePaths.config.path)
        let logExists = fileSystem.fileExists(atPath: gamePaths.log.path)
        let dlcCatalogExists = fileSystem.fileExists(atPath: gamePaths.dlcCatalog.path)

        let launchInspection: SteamLaunchOptionsSnapshot?
        let launchInspectionErrorDescription: String?
        do {
            launchInspection = try helper.launchOptionsAll(appID: game.appID)
            launchInspectionErrorDescription = nil
        } catch {
            launchInspection = nil
            launchInspectionErrorDescription = error.localizedDescription
        }

        let launchCoverage = launchInspection.map { InjectLaunchOptions.hookCoverage(in: $0, gamePaths: gamePaths) }
        let hookedAccounts = launchCoverage?.hookedAccounts
        let localConfigURLs = launchCoverage?.expectedLocalConfigURLs ?? []

        return InstallationGameEvidence(
            injectDylibExists: injectDylibExists,
            injectPrefixWrapperExists: injectPrefixWrapperExists,
            injectCommandWrapperExists: injectCommandWrapperExists,
            configExists: configExists,
            logExists: logExists,
            dlcCatalogExists: dlcCatalogExists,
            launchInspectionErrorDescription: launchInspectionErrorDescription,
            launchOptionsHookPresent: launchCoverage?.allExpectedConfigsHooked,
            launchOptionsHookCount: hookedAccounts?.count,
            launchOptions: hookedAccounts?.first?.launchOptions,
            localConfigURL: hookedAccounts?.first?.localConfigURL
                ?? launchInspection?.accounts.first?.localConfigURL
                ?? localConfigURLs.first,
            localConfigURLs: localConfigURLs,
            anyLaunchOptionsHook: launchCoverage?.anyHook == true
        )
    }

    func targetEvidence(
        game: SteamGame,
        target: SteamAPITarget
    ) -> InstallationTargetEvidence {
        let paths = RuntimeTargetPaths(game: game, target: target, runtimeSettings: runtimeSettings)
        return InstallationTargetEvidence(
            paths: paths,
            targetExists: fileSystem.fileExists(atPath: target.url.path),
            originalSiblingExists: fileSystem.fileExists(atPath: paths.originalSibling.path),
            backupExists: fileSystem.fileExists(atPath: paths.backup.path)
        )
    }

    func inspect(game: SteamGame, target: SteamAPITarget) throws -> InstallationState {
        let targetSnapshot = targetEvidence(game: game, target: target)
        return try inspect(
            game: game,
            target: target,
            gameEvidence: gameEvidence(for: game),
            targetEvidence: targetSnapshot
        )
    }

    func inspect(
        game: SteamGame,
        targets: [SteamAPITarget]
    ) throws -> [InstallationState] {
        guard !targets.isEmpty else { return [] }
        let targetSnapshots = targets.map { targetEvidence(game: game, target: $0) }
        let gameSnapshot = gameEvidence(for: game)
        return try zip(targets, targetSnapshots).map { target, evidence in
            try inspect(
                game: game,
                target: target,
                gameEvidence: gameSnapshot,
                targetEvidence: evidence
            )
        }
    }

    func inspect(
        game: SteamGame,
        target: SteamAPITarget,
        gameEvidence: InstallationGameEvidence,
        targetEvidence: InstallationTargetEvidence
    ) throws -> InstallationState {
        let paths = targetEvidence.paths
        let gamePaths = paths.gamePaths
        let targetExists = targetEvidence.targetExists
        let originalSiblingExists = targetEvidence.originalSiblingExists
        let backupExists = targetEvidence.backupExists

        if let launchInspectionErrorDescription = gameEvidence.launchInspectionErrorDescription {
            LauncherLog.logger.warning(
                "Steam Launch Options could not be inspected: \(launchInspectionErrorDescription)",
                metadata: ["app_id": "\(game.appID)"]
            )
        }

        let injectDylibExists = gameEvidence.injectDylibExists
        let injectPrefixWrapperExists = gameEvidence.injectPrefixWrapperExists
        let injectCommandWrapperExists = gameEvidence.injectCommandWrapperExists
        let launchOptionsHookPresent = gameEvidence.launchOptionsHookPresent
        let launchOptionsHookCount = gameEvidence.launchOptionsHookCount
        let launchOptions = gameEvidence.launchOptions
        let localConfigURL = gameEvidence.localConfigURL
        let localConfigURLs = gameEvidence.localConfigURLs
        let configExists = gameEvidence.configExists
        let logExists = gameEvidence.logExists
        let dlcCatalogExists = gameEvidence.dlcCatalogExists

        guard targetExists else {
            LauncherLog.logger.error(
                "Steam API target is missing while inspecting installation state",
                metadata: ["app_id": "\(game.appID)", "target": "\(target.relativePath)"]
            )
            return InstallationState(
                kind: .broken,
                transport: nil,
                runtimeIdentity: .none,
                targetExists: false,
                originalSiblingExists: originalSiblingExists,
                backupExists: backupExists,
                injectDylibExists: injectDylibExists,
                injectPrefixWrapperExists: injectPrefixWrapperExists,
                injectCommandWrapperExists: injectCommandWrapperExists,
                launchOptionsHookPresent: launchOptionsHookPresent,
                launchOptionsHookCount: launchOptionsHookCount,
                launchOptions: launchOptions,
                localConfigURL: localConfigURL,
                localConfigURLs: localConfigURLs,
                configExists: configExists,
                logExists: logExists,
                dlcCatalogExists: dlcCatalogExists,
                issues: ["Steam API target is missing: \(target.url.path)"]
            )
        }

        let proxyDetected = try RuntimeVerifier.isProxy(target.url)
        let injectAny = injectDylibExists || injectPrefixWrapperExists || injectCommandWrapperExists
        let injectComplete = injectDylibExists && injectPrefixWrapperExists && injectCommandWrapperExists

        var issues: [String] = []
        var kind: InstallationKind
        var transport: SteamTransport?
        var runtimeIdentity: InstalledRuntimeIdentity = .none

        if proxyDetected {
            transport = .proxy
            runtimeIdentity = try identifyRuntime(file: target.url, transport: .proxy)

            if !originalSiblingExists {
                issues.append("Proxy is installed but libsteam_api_o.dylib is missing.")
            }
            if !backupExists {
                issues.append("Proxy is installed but its target-scoped backup is missing.")
            }
            if injectAny {
                issues.append("Proxy and inject runtime files are present at the same time.")
            }
            if gameEvidence.anyLaunchOptionsHook {
                issues.append("Proxy is installed but Steam Launch Options still contain an inject hook.")
            }

            kind = issues.isEmpty ? .proxy : .broken
        } else if originalSiblingExists {
            transport = nil
            issues.append("libsteam_api_o.dylib exists but the target is not a Proxy runtime.")
            if injectAny || gameEvidence.anyLaunchOptionsHook {
                issues.append("Proxy leftovers and inject state are mixed.")
            }
            kind = .broken
        } else if injectAny || gameEvidence.anyLaunchOptionsHook {
            transport = .inject

            if injectDylibExists {
                runtimeIdentity = try identifyRuntime(file: gamePaths.injectDylib, transport: .inject)
            }
            if !injectComplete {
                issues.append("Inject installation is incomplete; dylib and both wrappers are required.")
            }
            if gameEvidence.launchInspectionErrorDescription != nil {
                issues.append("Inject runtime files exist but Steam Launch Options could not be verified.")
            } else if launchOptionsHookPresent != true {
                if localConfigURLs.isEmpty {
                    issues.append("Inject runtime files exist but no Steam localconfig.vdf could be inspected.")
                } else {
                    issues.append(
                        "Inject Steam Launch Options hook is present in \(launchOptionsHookCount ?? 0) of \(localConfigURLs.count) Steam account configurations; all are required."
                    )
                }
            }
            if backupExists {
                issues.append("Inject installation has a stale proxy backup.")
            }

            kind = issues.isEmpty ? .inject : .broken
        } else {
            transport = nil
            if backupExists {
                issues.append("Proxy backup exists without an installed Proxy runtime.")
            }
            kind = issues.isEmpty ? .untouched : .broken
        }

        for issue in issues {
            LauncherLog.logger.error(
                "\(issue)",
                metadata: ["app_id": "\(game.appID)", "target": "\(target.relativePath)"]
            )
        }

        return InstallationState(
            kind: kind,
            transport: transport,
            runtimeIdentity: runtimeIdentity,
            targetExists: targetExists,
            originalSiblingExists: originalSiblingExists,
            backupExists: backupExists,
            injectDylibExists: injectDylibExists,
            injectPrefixWrapperExists: injectPrefixWrapperExists,
            injectCommandWrapperExists: injectCommandWrapperExists,
            launchOptionsHookPresent: launchOptionsHookPresent,
            launchOptionsHookCount: launchOptionsHookCount,
            launchOptions: launchOptions,
            localConfigURL: localConfigURL,
            localConfigURLs: localConfigURLs,
            configExists: configExists,
            logExists: logExists,
            dlcCatalogExists: dlcCatalogExists,
            issues: issues
        )
    }

    private func identifyRuntime(file: URL, transport: SteamTransport) throws -> InstalledRuntimeIdentity {
        let actual: String
        do {
            actual = try BinaryInspector.sha256(file)
        } catch BinaryInspectionError.malformedToolOutput(_, let output) {
            throw InstallationStateError.malformedHash(output)
        }

        for profile in RuntimeProfile.allCases {
            let artifact = try runtimeRepository.artifact(transport: transport, profile: profile)
            if actual.caseInsensitiveCompare(artifact.sha256) == .orderedSame {
                return .current(profile)
            }
        }

        return .other
    }

}
