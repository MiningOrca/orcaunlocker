import Foundation

/// Composition root shared by the command-line and SwiftUI frontends.
///
/// Frontends operate on a Steam game. Individual libsteam_api.dylib copies are an
/// implementation detail owned by the core: discovery, inspection, Apply, Restore,
/// diagnostics, and profile switching always cover every copy found for the game.
package struct LauncherCore {
    private let settings: LauncherSettings
    private let helper: SteamHelperClient
    private let discovery: SteamDiscoveryService
    private let configFile: RuntimeConfigFile
    private let fileSystem: FileSystem

    private init(
        settings: LauncherSettings,
        helper: SteamHelperClient,
        fileSystem: FileSystem
    ) {
        self.settings = settings
        self.helper = helper
        self.discovery = SteamDiscoveryService(helper: helper, fileSystem: fileSystem)
        self.configFile = RuntimeConfigFile(runtimeSettings: settings.runtime, fileSystem: fileSystem)
        self.fileSystem = fileSystem
    }

    package static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> LauncherCore {
        let fileSystem = FileSystem(fileManager: fileManager)
        let settings = try LauncherSettingsLoader.load(
            environment: environment,
            fileSystem: fileSystem
        ).settings
        let helper = try SteamHelperClient.locateDefault(
            configuredPath: settings.helper.executablePath,
            environment: environment,
            currentDirectory: URL(fileURLWithPath: fileSystem.currentDirectoryPath, isDirectory: true),
            fileSystem: fileSystem
        )
        return LauncherCore(settings: settings, helper: helper, fileSystem: fileSystem)
    }

    package func installedLibrary() throws -> SteamLibrary {
        try discovery.installedLibrary()
    }

    package func installedGames() throws -> [SteamGame] {
        try installedLibrary().games
    }

    package func cachedArtwork(
        for games: [SteamGame],
        steamRootURL: URL
    ) async throws -> [UInt32: SteamArtwork] {
        let service = try artworkService(steamRootURL: steamRootURL)
        return await service.cachedArtwork(for: games.map(\.appID))
    }

    package func artwork(
        for game: SteamGame,
        steamRootURL: URL
    ) async throws -> SteamArtwork {
        let service = try artworkService(steamRootURL: steamRootURL)
        return await service.resolvedArtwork(for: game.appID)
    }

    private func artworkService(steamRootURL: URL) throws -> SteamArtworkService {
        SteamArtworkService(
            steamRootURL: steamRootURL,
            launcherCacheDirectory: try LauncherSettingsLoader.artworkCacheDirectory(
                settings: settings,
                fileSystem: fileSystem
            ),
            requestTimeout: settings.store.requestTimeoutSeconds,
            userAgent: settings.store.userAgent,
            fileSystem: fileSystem
        )
    }

    package func inspect(
        game: SteamGame,
        runtimeDirectory: URL? = nil
    ) throws -> LauncherGameState {
        try LauncherLog.withAppID(game.appID) {
            try inspectUnscoped(game: game, runtimeDirectory: runtimeDirectory)
        }
    }

    /// Lightweight installation-state polling for UI status refreshes. This performs
    /// the same structural inspection as `inspect`, but does not append routine poll
    /// activity to the user-visible launcher operation log.
    package func pollInstallationState(
        game: SteamGame,
        runtimeDirectory: URL? = nil
    ) throws -> LauncherGameState {
        try LauncherLog.suppressCollection {
            try LauncherLog.withAppID(game.appID) {
                try inspectUnscoped(game: game, runtimeDirectory: runtimeDirectory)
            }
        }
    }

    private func inspectUnscoped(
        game: SteamGame,
        runtimeDirectory: URL? = nil
    ) throws -> LauncherGameState {
        let repository = try runtimeRepository(explicitDirectory: runtimeDirectory)
        let detector = installationStateDetector(repository: repository)
        let targets = try discovery.targets(for: game)
        return try inspect(game: game, targets: targets, detector: detector)
    }

    private func configuration(for game: SteamGame) throws -> RuntimeConfig? {
        try configurationSource(for: game).configuration
    }

    package func configurationSource(for game: SteamGame) throws -> RuntimeConfigSource {
        try configFile.source(for: game)
    }

    @discardableResult
    package func saveConfigurationText(_ text: String, for game: SteamGame) throws -> RuntimeConfigSource {
        try LauncherLog.withAppID(game.appID) {
            let source = try configFile.writeRawText(text, for: game)
            LauncherLog.logger.info(
                "Saved advanced runtime configuration",
                metadata: [
                    "app_id": "\(game.appID)",
                    "config_path": "\(source.url.path)",
                ]
            )
            return source
        }
    }

    package func steamIsRunning(for game: SteamGame) throws -> Bool {
        try LauncherLog.withAppID(game.appID) {
            try SteamProcessController(settings: settings.steam).isRunning()
        }
    }

    /// Stops Steam once for a caller that needs to perform several related
    /// localconfig mutations as one operation. Returns true only when this call
    /// actually stopped a running Steam client, so the caller can restore the
    /// previous running state exactly once after all mutations are complete.
    @discardableResult
    package func stopSteamForMutation(game: SteamGame) throws -> Bool {
        try LauncherLog.withAppID(game.appID) {
            let controller = SteamProcessController(settings: settings.steam)
            guard try controller.isRunning() else { return false }
            LauncherLog.logger.info("Stopping Steam for grouped configuration changes")
            try controller.quitAndWait()
            return true
        }
    }

    package func startSteamAfterMutation(game: SteamGame) throws {
        try LauncherLog.withAppID(game.appID) {
            LauncherLog.logger.info("Restarting Steam after grouped configuration changes")
            try SteamProcessController(settings: settings.steam).restartAndWait()
        }
    }

    package func discoverDLCs(
        game: SteamGame,
        forceStoreRefresh: Bool = false,
        includeContentState: Bool = false
    ) async throws -> DLCDiscoveryResult {
        try await LauncherLog.withAppID(game.appID) {
            try await discoverDLCsUnscoped(
                game: game,
                forceStoreRefresh: forceStoreRefresh,
                includeContentState: includeContentState
            )
        }
    }

    private func discoverDLCsUnscoped(
        game: SteamGame,
        forceStoreRefresh: Bool,
        includeContentState: Bool
    ) async throws -> DLCDiscoveryResult {
        let existingConfig = try configFile.read(for: game)
        let cacheDirectory = try LauncherSettingsLoader.cacheDirectory(
            settings: settings,
            fileSystem: fileSystem
        )

        let discovered = await DLCDiscoveryService(
            appInfo: helper,
            store: SteamStoreClient(settings: settings.store),
            settings: settings,
            cacheDirectory: cacheDirectory,
            fileSystem: fileSystem
        ).discover(
            appID: game.appID,
            configuredDLCs: existingConfig?.configuredDLCs ?? [],
            forceStoreRefresh: forceStoreRefresh
        )

        let result: DLCDiscoveryResult
        if includeContentState {
            do {
                let content = try helper.contentState(
                    baseAppID: game.appID,
                    appIDs: discovered.dlcs.map(\.appID),
                    installDirectory: game.installDirectory
                )
                result = discovered.withContentSnapshot(content)
            } catch {
                result = discovered
                LauncherLog.logger.warning(
                    "Steam DLC content state unavailable: \(error.localizedDescription)",
                    metadata: ["app_id": "\(game.appID)"]
                )
            }
        } else {
            result = discovered
        }

        let ownedCount = result.ownershipByAppID.values.filter { $0 == .owned }.count
        let notOwnedCount = result.ownershipByAppID.values.filter { $0 == .notOwned }.count
        let ownershipUnknownCount = result.ownershipByAppID.values.filter { $0 == .unknown }.count
        let ownershipCacheStatus: String
        if !result.ownershipAccountSelected {
            ownershipCacheStatus = "unavailable"
        } else if result.ownershipPackageMetadataComplete {
            ownershipCacheStatus = "complete"
        } else {
            ownershipCacheStatus = "incomplete"
        }

        LauncherLog.logger.info(
            "Loaded DLC catalog for \(game.name): \(result.dlcs.count) \(result.dlcs.count == 1 ? "DLC" : "DLCs") detected",
            metadata: [
                "app_id": "\(game.appID)",
                "dlc_count": "\(result.dlcs.count)",
                "appinfo_count": "\(result.appInfoCount)",
                "store_count": "\(result.storeCount)",
                "config_count": "\(result.configCount)",
                "store_cache": "\(result.storeCacheStatus.rawValue)",
                "ownership_cache": "\(ownershipCacheStatus)",
                "owned_count": "\(ownedCount)",
                "not_owned_count": "\(notOwnedCount)",
                "ownership_unknown_count": "\(ownershipUnknownCount)",
            ]
        )
        return result
    }

    package func apply(
        game: SteamGame,
        request: ApplyRequest,
        runtimeDirectory: URL? = nil
    ) throws -> LauncherGameApplyResult {
        try LauncherLog.withAppID(game.appID) {
            try applyUnscoped(
                game: game,
                request: request,
                runtimeDirectory: runtimeDirectory
            )
        }
    }

    private func applyUnscoped(
        game: SteamGame,
        request: ApplyRequest,
        runtimeDirectory: URL?
    ) throws -> LauncherGameApplyResult {
        let repository = try runtimeRepository(explicitDirectory: runtimeDirectory)
        let targets = try requireTargets(for: game)
        LauncherLog.logger.info(
            "Applying \(request.transport.rawValue) configuration to \(game.name) across \(targets.count) Steam API \(targets.count == 1 ? "library" : "libraries")",
            metadata: [
                "app_id": "\(game.appID)",
                "transport": "\(request.transport.rawValue)",
                "steam_api_count": "\(targets.count)",
            ]
        )
        let detector = installationStateDetector(repository: repository)
        let before = try inspect(game: game, targets: targets, detector: detector)

        if before.hasBrokenState {
            throw ApplyError.brokenInstallation(before.issues)
        }

        try preflight(
            game: game,
            targets: targets,
            request: request,
            repository: repository
        )

        let workflow = ApplyWorkflow(
            runtimeRepository: repository,
            helper: helper,
            steamSettings: settings.steam,
            runtimeSettings: settings.runtime,
            fileSystem: fileSystem
        )

        do {
            try workflow.apply(
                game: game,
                targets: targets,
                before: before,
                request: request
            )

            let after = try inspect(game: game, targets: targets, detector: detector)
            try requirePostcondition(after, request: request)

            let configSource = try configFile.source(for: game)
            guard let configuration = configSource.configuration else {
                throw RuntimeConfigValidationError(
                    line: 1,
                    key: "runtime.app_id",
                    reason: "Apply completed without a readable runtime configuration."
                )
            }

            return LauncherGameApplyResult(
                runtimeAction: runtimeAction(before: before, request: request),
                configURL: configSource.url,
                configuration: configuration,
                configurationText: configSource.text,
                stateBefore: before,
                stateAfter: after
            )
        } catch {
            let applyError = error
            LauncherLog.logger.error(
                "Apply failed; rolling the game back to a clean state: \(applyError.localizedDescription)",
                metadata: ["app_id": "\(game.appID)"]
            )

            let requiresSteamRepair = try rollbackFailedApplyToClean(
                game: game,
                targets: targets,
                repository: repository,
                restartSteamIfRunning: request.restartSteamIfRunning
            )
            if requiresSteamRepair {
                throw LauncherCoreError.steamRepairRequired
            }

            LauncherLog.logger.info(
                "Failed Apply rollback restored a clean game state",
                metadata: ["app_id": "\(game.appID)"]
            )
            throw LauncherCoreError.applyFailedRolledBack(applyError.localizedDescription)
        }
    }

    private func rollbackFailedApplyToClean(
        game: SteamGame,
        targets: [SteamAPITarget],
        repository: RuntimeRepository,
        restartSteamIfRunning: Bool
    ) throws -> Bool {
        let detector = installationStateDetector(repository: repository)

        do {
            // Failed Apply never restores an older MiningOrca setup. Remove Inject
            // state first, then restore every Proxy target from its verified backup.
            // Partial Inject state is still cleanable, so do not reject it merely
            // because the installation detector currently classifies it as broken.
            _ = try InjectTransportCleaner(
                helper: helper,
                steamSettings: settings.steam,
                runtimeSettings: settings.runtime,
                fileSystem: fileSystem
            ).restore(
                game: game,
                restartSteamIfRunning: restartSteamIfRunning
            )

            _ = try restoreProxyTargets(
                game: game,
                targets: targets,
                detector: detector
            )

            _ = try removeMiningOrcaArtifactsPreservingLogAndConfig(
                game: game,
                targets: targets
            )

            let after = try inspect(game: game, targets: targets, detector: detector)
            guard isCleanRollbackState(after) else {
                throw LauncherCoreError.inconsistentGameInstallation
            }
            return false
        } catch {
            LauncherLog.logger.warning(
                "Could not restore an exact clean state after failed Apply; removing launcher state and requiring Steam file verification: \(error.localizedDescription)",
                metadata: ["app_id": "\(game.appID)"]
            )
            _ = try purgeInstallationForSteamRepair(
                game: game,
                targets: targets,
                restartSteamIfRunning: restartSteamIfRunning
            )
            return true
        }
    }

    private func isCleanRollbackState(_ state: LauncherGameState) -> Bool {
        !state.states.isEmpty && state.states.allSatisfy {
            $0.kind == .untouched
                && $0.transport == nil
                && $0.runtimeIdentity == .none
                && $0.targetExists
                && !$0.originalSiblingExists
                && !$0.backupExists
                && !$0.injectDylibExists
                && !$0.injectPrefixWrapperExists
                && !$0.injectCommandWrapperExists
                && $0.launchOptionsHookCount == 0
                && !$0.dlcCatalogExists
        }
    }


    package func restore(
        game: SteamGame,
        runtimeDirectory: URL? = nil,
        restartSteamIfRunning: Bool = false
    ) throws -> LauncherRestoreResult {
        try LauncherLog.withAppID(game.appID) {
            try restoreUnscoped(
                game: game,
                runtimeDirectory: runtimeDirectory,
                restartSteamIfRunning: restartSteamIfRunning
            )
        }
    }

    private func restoreUnscoped(
        game: SteamGame,
        runtimeDirectory: URL?,
        restartSteamIfRunning: Bool
    ) throws -> LauncherRestoreResult {
        let repository = try runtimeRepository(explicitDirectory: runtimeDirectory)
        let targets = try requireTargets(for: game)
        LauncherLog.logger.info(
            "Restoring \(game.name) across \(targets.count) Steam API \(targets.count == 1 ? "library" : "libraries")",
            metadata: [
                "app_id": "\(game.appID)",
                "steam_api_count": "\(targets.count)",
            ]
        )
        let detector = installationStateDetector(repository: repository)
        let before = try inspect(game: game, targets: targets, detector: detector)

        // A broken installation is no longer treated as something we can safely
        // reconstruct from whichever leftovers happen to remain. Remove every
        // MiningOrca-owned footprint we can identify, then require Steam to repair
        // its own files before another Apply. This deliberately does not trust a
        // stale/partial backup as authoritative input.
        if before.hasBrokenState {
            let restored = try purgeInstallationForSteamRepair(
                game: game,
                targets: targets,
                restartSteamIfRunning: restartSteamIfRunning
            )
            let after = try inspect(game: game, targets: targets, detector: detector)
            let configurationSource = try configFile.source(for: game)
            return LauncherRestoreResult(
                restored: restored,
                requiresSteamRepair: true,
                configurationSource: configurationSource,
                stateBefore: before,
                stateAfter: after
            )
        }

        var restored = false

        // Inject is shared by the whole game. Remove its files/LaunchOptions once.
        if before.hasInjectFootprint {
            let result = try InjectTransportCleaner(
                helper: helper,
                steamSettings: settings.steam,
                runtimeSettings: settings.runtime,
                fileSystem: fileSystem
            ).restore(
                game: game,
                restartSteamIfRunning: restartSteamIfRunning
            )
            restored = restored || result.restored
        }

        restored = try restoreProxyTargets(
            game: game,
            targets: targets,
            detector: detector
        ) || restored

        let after = try inspect(game: game, targets: targets, detector: detector)
        let configurationSource = try configFile.source(for: game)
        return LauncherRestoreResult(
            restored: restored,
            requiresSteamRepair: false,
            configurationSource: configurationSource,
            stateBefore: before,
            stateAfter: after
        )
    }

    private func restoreProxyTargets(
        game: SteamGame,
        targets: [SteamAPITarget],
        detector: InstallationStateDetector
    ) throws -> Bool {
        let proxyInstaller = ProxyInstaller(
            runtimeSettings: settings.runtime,
            fileSystem: fileSystem
        )
        var restored = false
        for target in targets {
            let state = try detector.inspect(game: game, target: target)
            if state.transport == .proxy || state.originalSiblingExists {
                let result = try proxyInstaller.restore(game: game, target: target)
                restored = restored || result.restored
            }
        }
        return restored
    }

    private func purgeInstallationForSteamRepair(
        game: SteamGame,
        targets: [SteamAPITarget],
        restartSteamIfRunning: Bool
    ) throws -> Bool {
        LauncherLog.logger.warning(
            "Removing launcher state before Steam file verification",
            metadata: [
                "app_id": "\(game.appID)",
                "steam_api_count": "\(targets.count)",
            ]
        )

        // Validate every path before the first destructive file operation.
        for target in targets {
            let paths = RuntimeTargetPaths(game: game, target: target, runtimeSettings: settings.runtime)
            for url in [target.url, paths.originalSibling] + paths.proxyStagingFiles {
                _ = try PathSafety.requireNonSymlinkInside(
                    url,
                    inside: game.installDirectory,
                    fileSystem: fileSystem
                )
            }
            try paths.gamePaths.requireSafeRuntimePaths(
                [paths.gamePaths.log, paths.gamePaths.config],
                fileSystem: fileSystem
            )
        }

        var changed = false

        // LaunchOptions must be cleaned before wrapper files disappear. This is safe
        // to call even when no Inject hook is present.
        let injectResult = try InjectTransportCleaner(
            helper: helper,
            steamSettings: settings.steam,
            runtimeSettings: settings.runtime,
            fileSystem: fileSystem
        ).restore(
            game: game,
            restartSteamIfRunning: restartSteamIfRunning
        )
        changed = changed || injectResult.restored

        // Once exact restoration is no longer trustworthy, do not keep any Steam API
        // copy that MiningOrca may have modified. Steam Verify is authoritative.
        for target in targets {
            let paths = RuntimeTargetPaths(game: game, target: target, runtimeSettings: settings.runtime)
            let leftovers = [target.url, paths.originalSibling] + paths.proxyStagingFiles
            for url in leftovers {
                changed = try fileSystem.removeItemIfExists(url) || changed
            }
        }

        changed = try removeMiningOrcaArtifactsPreservingLogAndConfig(
            game: game,
            targets: targets
        ) || changed

        LauncherLog.logger.warning(
            "Cleanup complete; Steam file verification is required before Apply",
            metadata: ["app_id": "\(game.appID)"]
        )
        return changed
    }

    private func removeMiningOrcaArtifactsPreservingLogAndConfig(
        game: SteamGame,
        targets: [SteamAPITarget]
    ) throws -> Bool {
        guard !targets.isEmpty else {
            return false
        }

        var changed = false
        let paths = RuntimeGamePaths(game: game, runtimeSettings: settings.runtime)

        for target in targets {
            let targetPaths = RuntimeTargetPaths(game: game, target: target, runtimeSettings: settings.runtime)
            let leftovers = [targetPaths.originalSibling] + targetPaths.proxyStagingFiles
            for url in leftovers {
                _ = try PathSafety.requireNonSymlinkInside(
                    url,
                    inside: game.installDirectory,
                    fileSystem: fileSystem
                )
                changed = try fileSystem.removeItemIfExists(url) || changed
            }
        }

        guard fileSystem.fileExists(atPath: paths.runtimeDirectory.path) else {
            return changed
        }

        try paths.requireSafeRuntimePaths(
            [paths.log, paths.config],
            fileSystem: fileSystem
        )

        let preservedURLs = Set([
            paths.log.standardizedFileURL,
            paths.config.standardizedFileURL,
        ])
        let contents = try fileSystem.contentsOfDirectory(
            at: paths.runtimeDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in contents where !preservedURLs.contains(url.standardizedFileURL) {
            _ = try PathSafety.requireInside(
                url,
                root: paths.runtimeDirectory,
                fileSystem: fileSystem
            )
            try fileSystem.removeItem(at: url)
            changed = true
        }

        let remaining = try fileSystem.contentsOfDirectory(
            at: paths.runtimeDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        if remaining.isEmpty {
            try fileSystem.removeItem(at: paths.runtimeDirectory)
            changed = true
        }
        return changed
    }

    package func diagnostics(
        game: SteamGame,
        runtimeDirectory: URL? = nil,
        lineLimit: Int? = nil
    ) throws -> DiagnosticReport {
        let repository = try runtimeRepository(explicitDirectory: runtimeDirectory)
        let targets = try requireTargets(for: game)
        let service = DiagnosticsService(
            runtimeRepository: repository,
            helper: helper,
            diagnosticsSettings: settings.diagnostics,
            runtimeSettings: settings.runtime,
            fileSystem: fileSystem
        )

        let reports = service.reports(
            game: game,
            targets: targets,
            lineLimit: lineLimit
        )
        if reports.count == 1, let report = reports.first {
            return report
        }

        let sections = reports.enumerated().map { index, report in
            "===== Steam API copy \(index + 1)/\(reports.count) =====\n\(report.text)"
        }
        return DiagnosticReport(text: sections.joined(separator: "\n"))
    }

    package func logTail(
        game: SteamGame,
        runtimeDirectory: URL? = nil,
        lineLimit: Int? = nil
    ) throws -> DiagnosticLogTail {
        let repository = try runtimeRepository(explicitDirectory: runtimeDirectory)
        return try DiagnosticsService(
            runtimeRepository: repository,
            helper: helper,
            diagnosticsSettings: settings.diagnostics,
            runtimeSettings: settings.runtime,
            fileSystem: fileSystem
        ).logTail(game: game, lineLimit: lineLimit)
    }

    package func debugConfigurationSnapshot(
        game: SteamGame
    ) throws -> DebugConfigurationSnapshot {
        try DebugSessionSupport.configurationSnapshot(
            game: game,
            runtimeSettings: settings.runtime,
            fileSystem: fileSystem
        )
    }

    package func restoreDebugConfiguration(
        _ snapshot: DebugConfigurationSnapshot,
        game: SteamGame
    ) throws -> RuntimeConfigSource {
        try LauncherLog.withAppID(game.appID) {
            try DebugSessionSupport.restoreConfiguration(
                snapshot,
                game: game,
                runtimeSettings: settings.runtime,
                fileSystem: fileSystem
            )
            LauncherLog.logger.info(
                "Restored pre-debug runtime configuration state",
                metadata: [
                    "app_id": "\(game.appID)",
                    "file_existed": "\(snapshot.fileExisted)",
                ]
            )
            return try configFile.source(for: game)
        }
    }

    package func clearDebugRuntimeLog(game: SteamGame) throws {
        try LauncherLog.withAppID(game.appID) {
            LauncherLog.logger.info(
                "Clearing runtime and debug trace logs before debug launch",
                metadata: ["app_id": "\(game.appID)"]
            )
            try DebugSessionSupport.clearRuntimeLog(
                game: game,
                runtimeSettings: settings.runtime,
                fileSystem: fileSystem
            )
        }
    }

    package func launchDebugGame(game: SteamGame) throws {
        try LauncherLog.withAppID(game.appID) {
            LauncherLog.logger.info(
                "Launching game through Steam for debug session",
                metadata: ["app_id": "\(game.appID)"]
            )
            try DebugSessionSupport.launch(game: game)
        }
    }

    package func debugSessionPulse(game: SteamGame) throws -> DebugSessionPulse {
        try LauncherLog.suppressCollection {
            try DebugSessionSupport.pulse(
                game: game,
                runtimeSettings: settings.runtime,
                fileSystem: fileSystem
            )
        }
    }

    package func inspectDebugProcess(
        _ identity: DebugProcessIdentity,
        game: SteamGame,
        steamAPITargets: [URL]
    ) -> DebugProcessObservation {
        LauncherLog.suppressCollection {
            DebugSessionSupport.inspectProcess(
                identity,
                game: game,
                steamAPITargets: steamAPITargets,
                runtimeSettings: settings.runtime,
                fileSystem: fileSystem
            )
        }
    }

    package func captureDebugArtifacts(
        game: SteamGame,
        installLog: String,
        transport: SteamTransport,
        debugState: LauncherGameState,
        processObservations: [DebugProcessObservation]
    ) throws -> DebugArtifactCapture {
        try LauncherLog.withAppID(game.appID) {
            let capture = try DebugSessionArtifacts.capture(
                game: game,
                installLog: installLog,
                transport: transport,
                debugState: debugState,
                processObservations: processObservations,
                runtimeSettings: settings.runtime,
                fileSystem: fileSystem
            )
            LauncherLog.logger.info(
                "Staged debug session artifacts before cleanup",
                metadata: [
                    "app_id": "\(game.appID)",
                    "directory": "\(capture.directory.path)",
                ]
            )
            return capture
        }
    }

    package func finalizeDebugArtifacts(
        capture: DebugArtifactCapture,
        game: SteamGame,
        context: DebugReportContext,
        cleanupLog: String
    ) throws -> DebugArtifactCapture {
        try LauncherLog.withAppID(game.appID) {
            let finalized = try DebugSessionArtifacts.finalize(
                capture: capture,
                game: game,
                context: context,
                cleanupLog: cleanupLog,
                fileSystem: fileSystem
            )
            LauncherLog.logger.info(
                "Finalized diagnostic report archive",
                metadata: [
                    "app_id": "\(game.appID)",
                    "archive": "\(finalized.archiveURL.path)",
                ]
            )
            return finalized
        }
    }

    package func switchRuntimeProfile(
        game: SteamGame,
        profile: RuntimeProfile,
        runtimeDirectory: URL? = nil,
        restartSteamIfRunning: Bool = false
    ) throws -> LauncherGameApplyResult {
        let current = try inspect(game: game, runtimeDirectory: runtimeDirectory)
        guard !current.states.isEmpty else {
            throw LauncherCoreError.noSteamAPITargets(game.appID)
        }
        guard !current.hasBrokenState else {
            throw ApplyError.brokenInstallation(current.issues)
        }

        guard let transport = current.states.first?.transport,
              current.states.allSatisfy({ $0.transport == transport }) else {
            throw LauncherCoreError.inconsistentGameInstallation
        }

        guard let config = try configuration(for: game) else {
            throw DiagnosticsError.configRequired(configFile.url(for: game))
        }

        return try apply(
            game: game,
            request: ApplyRequest(
                transport: transport,
                profile: profile,
                policy: config.policy,
                knownDLCs: config.configuredDLCs,
                restartSteamIfRunning: restartSteamIfRunning
            ),
            runtimeDirectory: runtimeDirectory
        )
    }

    package func verifyRuntime(directory: URL? = nil) throws -> LauncherRuntimeVerification {
        let repository = try runtimeRepository(explicitDirectory: directory)
        return LauncherRuntimeVerification(
            directory: repository.directory,
            artifacts: try RuntimeVerifier().verify(repository)
        )
    }

    private func requireTargets(for game: SteamGame) throws -> [SteamAPITarget] {
        let targets = try discovery.targets(for: game)
        guard !targets.isEmpty else {
            throw LauncherCoreError.noSteamAPITargets(game.appID)
        }
        return targets
    }

    private func installationStateDetector(
        repository: RuntimeRepository
    ) -> InstallationStateDetector {
        InstallationStateDetector(
            helper: helper,
            runtimeRepository: repository,
            runtimeSettings: settings.runtime,
            fileSystem: fileSystem
        )
    }

    private func inspect(
        game: SteamGame,
        targets: [SteamAPITarget],
        detector: InstallationStateDetector
    ) throws -> LauncherGameState {
        LauncherGameState(
            states: try detector.inspect(game: game, targets: targets),
            recommendedTransport: recommendedTransport(for: targets),
            steamAPITargetURLs: targets.map(\.url)
        )
    }

    private func recommendedTransport(for targets: [SteamAPITarget]) -> SteamTransport? {
        guard !targets.isEmpty else { return nil }
        return targets.contains(where: { $0.recommendedTransport == .inject }) ? .inject : .proxy
    }

    private func preflight(
        game: SteamGame,
        targets: [SteamAPITarget],
        request: ApplyRequest,
        repository: RuntimeRepository
    ) throws {
        _ = try RuntimeVerifier().verify(
            transport: request.transport,
            profile: request.profile,
            in: repository
        )

        for target in targets {
            _ = try PathSafety.requireNonSymlinkInside(
                target.url,
                inside: game.installDirectory,
                fileSystem: fileSystem
            )
            let paths = RuntimeTargetPaths(game: game, target: target, runtimeSettings: settings.runtime)
            _ = try PathSafety.requireNonSymlinkInside(
                paths.originalSibling,
                inside: game.installDirectory,
                fileSystem: fileSystem
            )
            try paths.gamePaths.requireSafeRuntimePaths(
                [paths.backup]
                    + paths.gamePaths.injectRuntimeFiles
                    + [paths.gamePaths.config],
                fileSystem: fileSystem
            )
        }
    }

    private func requirePostcondition(
        _ state: LauncherGameState,
        request: ApplyRequest
    ) throws {
        if let failed = state.states.first(where: {
            !$0.matchesRuntime(
                transport: request.transport,
                profile: request.profile
            )
        }) {
            throw ApplyError.postconditionFailed(
                expectedTransport: request.transport,
                expectedProfile: request.profile,
                actual: failed
            )
        }
    }

    private func runtimeAction(
        before: LauncherGameState,
        request: ApplyRequest
    ) -> ApplyRuntimeAction {
        let alreadyRequested = before.matchesRuntime(
            transport: request.transport,
            profile: request.profile
        )
        if alreadyRequested {
            return .unchanged
        }
        return before.states.contains(where: { $0.transport != nil }) ? .reinstalled : .installed
    }


    private func runtimeRepository(explicitDirectory: URL?) throws -> RuntimeRepository {
        let directory: URL
        if let explicitDirectory {
            directory = explicitDirectory.standardizedFileURL
        } else {
            directory = try RuntimeRepository.defaultDirectory(settings: settings.runtime)
        }
        return try RuntimeRepository.load(from: directory)
    }
}
