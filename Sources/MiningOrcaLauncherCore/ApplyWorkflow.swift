import Foundation

package enum ApplyRuntimeAction: String, Sendable {
    case unchanged
    case installed
    case reinstalled
}

package struct ApplyRequest: Sendable {
    package let transport: SteamTransport
    package let profile: RuntimeProfile
    package let policy: RuntimePolicy
    package let knownDLCs: [DLCInfo]
    package let restartSteamIfRunning: Bool

    package init(
        transport: SteamTransport,
        profile: RuntimeProfile,
        policy: RuntimePolicy,
        knownDLCs: [DLCInfo] = [],
        restartSteamIfRunning: Bool = false
    ) {
        self.transport = transport
        self.profile = profile
        self.policy = policy
        self.knownDLCs = knownDLCs
        self.restartSteamIfRunning = restartSteamIfRunning
    }

    package func runtimeConfig(appID: UInt32) -> RuntimeConfig {
        var relevantDLCIDs = Set(policy.dlcPurchaseTimes.keys)
        if case .explicit(let selected) = policy.selection {
            relevantDLCIDs.formUnion(selected)
        }

        var knownByID: [UInt32: String] = [:]
        for dlc in knownDLCs {
            if let name = dlc.name {
                knownByID[dlc.appID] = name
            }
        }

        var names: [UInt32: String] = [:]
        for dlcID in relevantDLCIDs {
            if let knownName = knownByID[dlcID] {
                names[dlcID] = knownName
            }
        }

        return RuntimeConfig(
            appID: appID,
            policy: policy,
            configuredDLCNames: names
        )
    }
}

enum ApplyError: Error, LocalizedError {
    case brokenInstallation([String])
    case postconditionFailed(expectedTransport: SteamTransport, expectedProfile: RuntimeProfile, actual: InstallationState)

    var errorDescription: String? {
        switch self {
        case .brokenInstallation(let issues):
            let details = issues.isEmpty ? "unknown inconsistent installation state" : issues.joined(separator: " ")
            return "Runtime installation is inconsistent. Use Restore to remove MiningOrca leftovers, then verify the game files in Steam before Apply. \(details)"
        case .postconditionFailed(let transport, let profile, let actual):
            return "Apply finished but installation verification failed: expected \(transport.rawValue)/\(profile.rawValue), got \(actual.kind.rawValue)/\(actual.runtimeIdentity.displayText)."
        }
    }
}

struct ApplyWorkflow {
    private let proxyInstaller: ProxyInstaller
    private let injectInstaller: InjectInstaller
    private let configFile: RuntimeConfigFile

    init(
        runtimeRepository: RuntimeRepository,
        helper: SteamHelperClient,
        steamSettings: LauncherSettings.Steam,
        runtimeSettings: LauncherSettings.Runtime,
        runtimeVerifier: RuntimeVerifier = RuntimeVerifier(),
        codeSigning: CodeSigningService = CodeSigningService(),
        quarantine: QuarantineService = QuarantineService(),
        fileSystem: FileSystem = .default
    ) {
        let injectCleaner = InjectTransportCleaner(
            helper: helper,
            steamSettings: steamSettings,
            runtimeSettings: runtimeSettings,
            fileSystem: fileSystem
        )
        self.proxyInstaller = ProxyInstaller(
            runtimeRepository: runtimeRepository,
            runtimeVerifier: runtimeVerifier,
            codeSigning: codeSigning,
            quarantine: quarantine,
            injectCleaner: injectCleaner,
            runtimeSettings: runtimeSettings,
            fileSystem: fileSystem
        )
        self.injectInstaller = InjectInstaller(
            runtimeRepository: runtimeRepository,
            helper: helper,
            steamSettings: steamSettings,
            runtimeSettings: runtimeSettings,
            runtimeVerifier: runtimeVerifier,
            codeSigning: codeSigning,
            quarantine: quarantine,
            fileSystem: fileSystem
        )
        self.configFile = RuntimeConfigFile(runtimeSettings: runtimeSettings, fileSystem: fileSystem)
    }

    func apply(
        game: SteamGame,
        targets: [SteamAPITarget],
        before: LauncherGameState,
        request: ApplyRequest
    ) throws {
        switch request.transport {
        case .inject:
            try applyInject(
                game: game,
                targets: targets,
                before: before,
                request: request
            )

        case .proxy:
            try applyProxy(
                game: game,
                targets: targets,
                before: before,
                request: request
            )
        }
    }

    private func applyInject(
        game: SteamGame,
        targets: [SteamAPITarget],
        before: LauncherGameState,
        request: ApplyRequest
    ) throws {
        logStart(game: game, request: request)
        LauncherLog.logger.info(
            "Inject is game-level; installing one runtime and one LaunchOptions hook for \(targets.count) discovered Steam API \(targets.count == 1 ? "library" : "libraries")",
            metadata: [
                "app_id": "\(game.appID)",
                "steam_api_count": "\(targets.count)",
            ]
        )

        // Inject files and LaunchOptions are game-level. When converting from
        // Proxy, restore every dylib first, then install Inject exactly once.
        for (target, state) in zip(targets, before.states) where state.transport == .proxy {
            _ = try proxyInstaller.restore(game: game, target: target)
        }

        let alreadyRequestedRuntime = before.matchesRuntime(
            transport: .inject,
            profile: request.profile
        )
        let action: ApplyRuntimeAction
        if alreadyRequestedRuntime {
            action = .unchanged
            LauncherLog.logger.info(
                "Runtime is already current; transport reinstall is not required",
                metadata: ["app_id": "\(game.appID)"]
            )
        } else {
            action = before.states.contains(where: { $0.transport == .inject })
                ? .reinstalled
                : .installed
            LauncherLog.logger.info(
                "Installing requested runtime transport",
                metadata: [
                    "app_id": "\(game.appID)",
                    "transport": "\(request.transport.rawValue)",
                    "profile": "\(request.profile.rawValue)",
                ]
            )
            _ = try injectInstaller.install(
                game: game,
                profile: request.profile,
                restartSteamIfRunning: request.restartSteamIfRunning
            )
        }

        try writeConfiguration(game: game, request: request)
        logCompletion(game: game, action: action)
    }

    private func applyProxy(
        game: SteamGame,
        targets: [SteamAPITarget],
        before: LauncherGameState,
        request: ApplyRequest
    ) throws {
        LauncherLog.logger.info(
            "Proxy will replace all \(targets.count) discovered Steam API \(targets.count == 1 ? "library" : "libraries")",
            metadata: [
                "app_id": "\(game.appID)",
                "steam_api_count": "\(targets.count)",
            ]
        )

        // Proxy replaces each concrete dylib, so every discovered copy must be
        // installed. Per-target backups prevent copies from clobbering each other.
        var injectWasCleaned = false
        for (target, state) in zip(targets, before.states) {
            logStart(game: game, request: request)
            let alreadyRequestedRuntime = state.transport == .proxy
                && state.runtimeIdentity == .current(request.profile)
            let action: ApplyRuntimeAction

            if alreadyRequestedRuntime {
                action = .unchanged
                LauncherLog.logger.info(
                    "Runtime is already current; transport reinstall is not required",
                    metadata: ["app_id": "\(game.appID)"]
                )
            } else {
                let effectiveTransport: SteamTransport? = state.transport == .inject && injectWasCleaned
                    ? nil
                    : state.transport
                action = effectiveTransport == nil ? .installed : .reinstalled
                LauncherLog.logger.info(
                    "Installing requested runtime transport",
                    metadata: [
                        "app_id": "\(game.appID)",
                        "transport": "\(request.transport.rawValue)",
                        "profile": "\(request.profile.rawValue)",
                    ]
                )
                _ = try proxyInstaller.install(
                    game: game,
                    target: target,
                    profile: request.profile,
                    restartSteamIfRunning: request.restartSteamIfRunning
                )
                if state.transport == .inject {
                    injectWasCleaned = true
                }
            }

            // Preserve the existing per-target ordering: once a Proxy target is
            // successfully applied (or already current), persist the requested
            // configuration before moving on to the next target.
            try writeConfiguration(game: game, request: request)
            logCompletion(game: game, action: action)
        }
    }

    private func writeConfiguration(
        game: SteamGame,
        request: ApplyRequest
    ) throws {
        LauncherLog.logger.info(
            "Writing runtime configuration",
            metadata: ["app_id": "\(game.appID)"]
        )
        try configFile.write(request.runtimeConfig(appID: game.appID), for: game)
    }

    private func logStart(
        game: SteamGame,
        request: ApplyRequest
    ) {
        LauncherLog.logger.info(
            "Applying runtime configuration",
            metadata: [
                "app_id": "\(game.appID)",
                "transport": "\(request.transport.rawValue)",
                "profile": "\(request.profile.rawValue)",
            ]
        )
    }

    private func logCompletion(
        game: SteamGame,
        action: ApplyRuntimeAction
    ) {
        LauncherLog.logger.info(
            "Apply completed",
            metadata: [
                "app_id": "\(game.appID)",
                "runtime_action": "\(action.rawValue)",
            ]
        )
    }
}
