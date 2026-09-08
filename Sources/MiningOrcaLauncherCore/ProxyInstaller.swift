import Foundation

enum ProxyInstallerError: Error, LocalizedError {
    case targetMissing(URL)
    case partialProxyInstall(URL)
    case injectFilesPresent
    case backupMissing(URL)
    case expectedInstallName(String, actual: String)
    case notAProxy(URL)

    var errorDescription: String? {
        switch self {
        case .targetMissing(let url):
            return "Steam API target is missing: \(url.path)"
        case .partialProxyInstall(let sibling):
            return "Found \(sibling.path) without a clean install state. Run proxy restore first."
        case .injectFilesPresent:
            return "Inject runtime files are present. Inject → Proxy switching will be wired through the multi-account Launch Options cleanup in the Inject step; restore Inject before running this smoke command."
        case .backupMissing(let url):
            return "Proxy backup is missing: \(url.path)"
        case .expectedInstallName(let expected, let actual):
            return "Prepared Valve Steam API has the wrong install name: expected \(expected), got \(actual)"
        case .notAProxy(let url):
            return "Expected a Proxy runtime at \(url.path)"
        }
    }
}

struct ProxyInstallResult: Sendable {
    let profile: RuntimeProfile
    let target: URL
    let originalSibling: URL
    let backup: URL
}

struct ProxyRestoreResult: Sendable {
    let restored: Bool
    let target: URL
}

struct ProxyInstaller {
    private let runtimeRepository: RuntimeRepository?
    private let runtimeVerifier: RuntimeVerifier
    private let codeSigning: CodeSigningService
    private let quarantine: QuarantineService
    private let injectCleaner: InjectTransportCleaner?
    private let runtimeSettings: LauncherSettings.Runtime
    private let fileSystem: FileSystem

    init(
        runtimeRepository: RuntimeRepository? = nil,
        runtimeVerifier: RuntimeVerifier = RuntimeVerifier(),
        codeSigning: CodeSigningService = CodeSigningService(),
        quarantine: QuarantineService = QuarantineService(),
        injectCleaner: InjectTransportCleaner? = nil,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) {
        self.runtimeRepository = runtimeRepository
        self.runtimeVerifier = runtimeVerifier
        self.codeSigning = codeSigning
        self.quarantine = quarantine
        self.injectCleaner = injectCleaner
        self.runtimeSettings = runtimeSettings
        self.fileSystem = fileSystem
    }

    func install(
        game: SteamGame,
        target: SteamAPITarget,
        profile: RuntimeProfile,
        restartSteamIfRunning: Bool = false
    ) throws -> ProxyInstallResult {
        LauncherLog.logger.info(
            "Installing Proxy runtime",
            metadata: [
                "app_id": "\(game.appID)",
                "profile": "\(profile.rawValue)",
                "target": "\(target.relativePath)",
            ]
        )
        let paths = RuntimeTargetPaths(game: game, target: target, runtimeSettings: runtimeSettings)
        guard fileSystem.fileExists(atPath: target.url.path) else {
            LauncherLog.logger.error(
                "Steam API target is missing",
                metadata: ["app_id": "\(game.appID)", "target": "\(target.relativePath)"]
            )
            throw ProxyInstallerError.targetMissing(target.url)
        }

        // Preflight the destination runtime before touching the current transport.
        // A missing/corrupt Proxy artifact must never tear down a working Proxy or Inject install.
        guard let runtimeRepository else {
            LauncherLog.logger.error("Proxy runtime repository is unavailable")
            throw RuntimeRepositoryError.runtimeDirectoryUnavailable
        }
        let verifiedRuntime: RuntimeArtifactVerification
        do {
            verifiedRuntime = try runtimeVerifier.verify(
                transport: .proxy,
                profile: profile,
                in: runtimeRepository
            )
        } catch {
            LauncherLog.logger.error(
                "Proxy runtime preflight verification failed: \(error.localizedDescription)",
                metadata: ["app_id": "\(game.appID)"]
            )
            throw error
        }
        LauncherLog.logger.info(
            "Proxy runtime preflight verification passed",
            metadata: ["app_id": "\(game.appID)"]
        )

        try validateInstallPaths(game: game, target: target, paths: paths)

        // Proxy changes a Steam API dylib in place. If that dylib lives inside
        // an app bundle, make sure the outer bundle can actually be re-sealed
        // before creating backups, siblings, or replacing the target.
        try codeSigning.preflightContainingAppsForResign(of: target.url)

        let proxyInstalled = try RuntimeVerifier.isProxy(target.url)
        if proxyInstalled {
            LauncherLog.logger.info(
                "Existing Proxy installation detected; restoring before reinstall",
                metadata: ["app_id": "\(game.appID)"]
            )
            _ = try restore(game: game, target: target)
        } else if fileSystem.fileExists(atPath: paths.originalSibling.path) {
            LauncherLog.logger.error(
                "Proxy installation is incomplete: original sibling exists without a Proxy target",
                metadata: ["app_id": "\(game.appID)"]
            )
            throw ProxyInstallerError.partialProxyInstall(paths.originalSibling)
        }

        let injectFilesPresent = paths.gamePaths.injectRuntimeFiles.contains {
            fileSystem.fileExists(atPath: $0.path)
        }
        if injectFilesPresent {
            LauncherLog.logger.info(
                "Inject installation detected; cleaning it before Proxy install",
                metadata: ["app_id": "\(game.appID)"]
            )
            if let injectCleaner {
                _ = try injectCleaner.restore(
                    game: game,
                    restartSteamIfRunning: restartSteamIfRunning
                )
            } else {
                LauncherLog.logger.error(
                    "Inject files are present but no Inject cleaner is available",
                    metadata: ["app_id": "\(game.appID)"]
                )
                throw ProxyInstallerError.injectFilesPresent
            }
        }

        try fileSystem.createDirectory(
            at: paths.gamePaths.runtimeDirectory,
            withIntermediateDirectories: true
        )

        // Always refresh the backup from the currently installed untouched Valve
        // dylib. If Steam updated the game since the previous run, the backup must
        // follow that update rather than preserving stale bytes.
        LauncherLog.logger.info(
            "Backing up the current Valve Steam API",
            metadata: ["app_id": "\(game.appID)"]
        )
        try fileSystem.createDirectory(
            at: paths.backup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try copyReplacing(target.url, to: paths.backup)

        var proxyCommitted = false
        do {
            let stagingRoot = fileSystem.temporaryDirectory
                .appendingPathComponent("miningorca-proxy-\(UUID().uuidString)", isDirectory: true)
            try fileSystem.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            defer { try? fileSystem.removeItem(at: stagingRoot) }

            let stagedOriginal = stagingRoot.appendingPathComponent("libsteam_api_o.dylib")
            let stagedProxy = stagingRoot.appendingPathComponent("libsteam_api.dylib")

            try fileSystem.copyItem(at: target.url, to: stagedOriginal)
            try prepareOriginal(stagedOriginal)
            try fileSystem.copyItem(at: verifiedRuntime.fileURL, to: stagedProxy)

            let originalTemp = paths.originalSiblingStaging
            let proxyTemp = paths.proxyStaging
            for url in paths.proxyInstallStagingFiles {
                try? fileSystem.removeItem(at: url)
            }
            defer {
                for url in paths.proxyInstallStagingFiles {
                    try? fileSystem.removeItem(at: url)
                }
            }

            try fileSystem.copyItem(at: stagedOriginal, to: originalTemp)
            try fileSystem.copyItem(at: stagedProxy, to: proxyTemp)

            try fileSystem.atomicReplace(originalTemp, paths.originalSibling)
            do {
                try fileSystem.atomicReplace(proxyTemp, target.url)
                proxyCommitted = true
                let quarantineRemoved = try quarantine.removeIfPresent(from: target.url)
                if quarantineRemoved {
                    LauncherLog.logger.info(
                        "Removed quarantine from installed Proxy runtime",
                        metadata: ["app_id": "\(game.appID)"]
                    )
                }
            } catch {
                // Target is still the untouched Valve dylib if its replace failed.
                try? fileSystem.removeItem(at: paths.originalSibling)
                throw error
            }

            try codeSigning.verify(paths.originalSibling)
            try codeSigning.verify(target.url)
            guard try RuntimeVerifier.isProxy(target.url) else {
                throw ProxyInstallerError.notAProxy(target.url)
            }
            LauncherLog.logger.info(
                "Re-signing containing application bundles",
                metadata: ["app_id": "\(game.appID)"]
            )
            try codeSigning.resignContainingApps(of: target.url)
        } catch {
            LauncherLog.logger.error(
                "Proxy installation failed: \(error.localizedDescription)",
                metadata: ["app_id": "\(game.appID)"]
            )
            // Before the target proxy is committed, leave no fake installation
            // state behind. Once committed, keep backup+sibling so restore remains
            // possible even if a post-install verification/signing step failed.
            if !proxyCommitted {
                try? fileSystem.removeItem(at: paths.originalSibling)
                try? fileSystem.removeItem(at: paths.backup)
                try? removeEmptyBackupDirectories(paths: paths)
                try? removeRuntimeDirectoryIfEmpty(paths.gamePaths.runtimeDirectory)
            }
            throw error
        }

        LauncherLog.logger.info(
            "Proxy installation complete",
            metadata: ["app_id": "\(game.appID)", "profile": "\(profile.rawValue)"]
        )

        return ProxyInstallResult(
            profile: profile,
            target: target.url,
            originalSibling: paths.originalSibling,
            backup: paths.backup
        )
    }

    func restore(
        game: SteamGame,
        target: SteamAPITarget
    ) throws -> ProxyRestoreResult {
        LauncherLog.logger.info(
            "Restoring Proxy installation",
            metadata: ["app_id": "\(game.appID)", "target": "\(target.relativePath)"]
        )
        let paths = RuntimeTargetPaths(game: game, target: target, runtimeSettings: runtimeSettings)
        guard fileSystem.fileExists(atPath: target.url.path) else {
            throw ProxyInstallerError.targetMissing(target.url)
        }
        try validateRestorePaths(game: game, target: target, paths: paths)

        let proxyInstalled = try RuntimeVerifier.isProxy(target.url)
        let siblingExists = fileSystem.fileExists(atPath: paths.originalSibling.path)
        guard proxyInstalled || siblingExists else {
            LauncherLog.logger.info(
                "No Proxy installation found; restore is not required",
                metadata: ["app_id": "\(game.appID)"]
            )
            return ProxyRestoreResult(restored: false, target: target.url)
        }
        guard fileSystem.fileExists(atPath: paths.backup.path) else {
            LauncherLog.logger.error(
                "Cannot restore Proxy because the Valve backup is missing",
                metadata: ["app_id": "\(game.appID)"]
            )
            throw ProxyInstallerError.backupMissing(paths.backup)
        }
        let backupURL = paths.backup

        let restoreTemp = paths.restoreStaging
        try? fileSystem.removeItem(at: restoreTemp)

        do {
            try fileSystem.copyItem(at: backupURL, to: restoreTemp)
            try fileSystem.atomicReplace(restoreTemp, target.url)
        } catch {
            try? fileSystem.removeItem(at: restoreTemp)
            throw error
        }

        try? fileSystem.removeItem(at: paths.originalSibling)
        try codeSigning.verify(target.url)
        try codeSigning.validateContainingAppsAfterRestore(of: target.url)
        try fileSystem.removeItem(at: backupURL)
        try removeEmptyBackupDirectories(paths: paths)
        try removeRuntimeDirectoryIfEmpty(paths.gamePaths.runtimeDirectory)

        LauncherLog.logger.info(
            "Proxy restore complete",
            metadata: ["app_id": "\(game.appID)"]
        )
        return ProxyRestoreResult(restored: true, target: target.url)
    }

    private func validateInstallPaths(
        game: SteamGame,
        target: SteamAPITarget,
        paths: RuntimeTargetPaths
    ) throws {
        try validateRestorePaths(game: game, target: target, paths: paths)
        try paths.gamePaths.requireSafeRuntimePaths(
            paths.gamePaths.injectRuntimeFiles,
            fileSystem: fileSystem
        )
    }

    private func validateRestorePaths(
        game: SteamGame,
        target: SteamAPITarget,
        paths: RuntimeTargetPaths
    ) throws {
        _ = try PathSafety.requireNonSymlinkInside(
            target.url,
            inside: game.installDirectory,
            fileSystem: fileSystem
        )
        _ = try PathSafety.requireNonSymlinkInside(
            paths.originalSibling,
            inside: game.installDirectory,
            fileSystem: fileSystem
        )
        try paths.gamePaths.requireSafeRuntimePath(
            paths.backup,
            fileSystem: fileSystem
        )
    }

    private func prepareOriginal(_ url: URL) throws {
        _ = try SystemTool.run(
            "/usr/bin/install_name_tool",
            arguments: ["-id", RuntimeVerifier.originalReexportName, url.path]
        )
        try codeSigning.signAdHoc(url)
        try codeSigning.verify(url)

        let actual: String
        do {
            actual = try BinaryInspector.installName(url)
        } catch BinaryInspectionError.malformedToolOutput(_, _) {
            actual = ""
        }
        guard actual == RuntimeVerifier.originalReexportName else {
            throw ProxyInstallerError.expectedInstallName(
                RuntimeVerifier.originalReexportName,
                actual: actual
            )
        }
    }

    private func copyReplacing(_ source: URL, to destination: URL) throws {
        try fileSystem.removeItemIfExists(destination)
        try fileSystem.copyItem(at: source, to: destination)
    }


    private func removeEmptyBackupDirectories(paths: RuntimeTargetPaths) throws {
        var directory = paths.backup.deletingLastPathComponent()
        let runtimeDirectory = paths.gamePaths.runtimeDirectory.standardizedFileURL

        while directory.standardizedFileURL != runtimeDirectory {
            guard fileSystem.fileExists(atPath: directory.path) else {
                directory = directory.deletingLastPathComponent()
                continue
            }
            let contents = try fileSystem.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
            guard contents.isEmpty else { break }
            try fileSystem.removeItem(at: directory)
            directory = directory.deletingLastPathComponent()
        }
    }

    private func removeRuntimeDirectoryIfEmpty(_ directory: URL) throws {
        guard fileSystem.fileExists(atPath: directory.path) else { return }
        let contents = try fileSystem.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if contents.isEmpty {
            try fileSystem.removeItem(at: directory)
        }
    }
}
