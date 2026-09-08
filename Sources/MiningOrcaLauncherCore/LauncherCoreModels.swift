import Foundation

package struct LauncherGameState: Sendable {
    package let states: [InstallationState]
    package let recommendedTransport: SteamTransport?
    package let steamAPITargetURLs: [URL]

    init(
        states: [InstallationState],
        recommendedTransport: SteamTransport?,
        steamAPITargetURLs: [URL] = []
    ) {
        self.states = states
        self.recommendedTransport = recommendedTransport
        self.steamAPITargetURLs = steamAPITargetURLs
    }

    package var steamAPICount: Int { states.count }

    package var hasBrokenState: Bool {
        states.contains { $0.kind == .broken }
    }

    package var hasInjectFootprint: Bool {
        states.contains { $0.hasInjectFootprint }
    }

    package var isUntouchedAndPresent: Bool {
        !states.isEmpty
            && states.allSatisfy {
                $0.kind == .untouched && $0.targetExists
            }
    }

    package func matchesRuntime(
        transport: SteamTransport,
        profile: RuntimeProfile
    ) -> Bool {
        !states.isEmpty
            && states.allSatisfy {
                $0.matchesRuntime(transport: transport, profile: profile)
            }
    }

    package func retainingSteamAPITargetURLsIfEmpty(
        from previous: LauncherGameState
    ) -> LauncherGameState {
        guard steamAPITargetURLs.isEmpty else {
            return self
        }
        return LauncherGameState(
            states: states,
            recommendedTransport: recommendedTransport,
            steamAPITargetURLs: previous.steamAPITargetURLs
        )
    }

    package var issues: [String] {
        var seen = Set<String>()
        return states
            .flatMap(\.issues)
            .filter { seen.insert($0).inserted }
    }
}

package struct LauncherGameApplyResult: Sendable {
    package let runtimeAction: ApplyRuntimeAction
    package let configURL: URL
    package let configuration: RuntimeConfig
    package let configurationText: String
    let stateBefore: LauncherGameState
    package let stateAfter: LauncherGameState

    init(
        runtimeAction: ApplyRuntimeAction,
        configURL: URL,
        configuration: RuntimeConfig,
        configurationText: String,
        stateBefore: LauncherGameState,
        stateAfter: LauncherGameState
    ) {
        self.runtimeAction = runtimeAction
        self.configURL = configURL
        self.configuration = configuration
        self.configurationText = configurationText
        self.stateBefore = stateBefore
        self.stateAfter = stateAfter
    }
}

package struct LauncherRestoreResult: Sendable {
    package let restored: Bool
    package let requiresSteamRepair: Bool
    package let configurationSource: RuntimeConfigSource
    package let stateBefore: LauncherGameState
    package let stateAfter: LauncherGameState

    init(
        restored: Bool,
        requiresSteamRepair: Bool,
        configurationSource: RuntimeConfigSource,
        stateBefore: LauncherGameState,
        stateAfter: LauncherGameState
    ) {
        self.restored = restored
        self.requiresSteamRepair = requiresSteamRepair
        self.configurationSource = configurationSource
        self.stateBefore = stateBefore
        self.stateAfter = stateAfter
    }
}

package struct LauncherRuntimeVerification: Sendable {
    package let directory: URL
    package let artifacts: [RuntimeArtifactVerification]

    init(directory: URL, artifacts: [RuntimeArtifactVerification]) {
        self.directory = directory
        self.artifacts = artifacts
    }
}

package enum LauncherCoreError: Error, LocalizedError {
    case noSteamAPITargets(UInt32)
    case inconsistentGameInstallation
    case applyFailedRolledBack(String)
    case steamRepairRequired

    package var errorDescription: String? {
        switch self {
        case .noSteamAPITargets(let appID):
            return "No libsteam_api.dylib was found for Steam game \(appID)."
        case .inconsistentGameInstallation:
            return "The game's runtime installation is inconsistent across its Steam API copies. Restore it before continuing."
        case .applyFailedRolledBack(let originalError):
            return "Apply failed. Changes were rolled back to a clean state.\n\n\(originalError)"
        case .steamRepairRequired:
            return "Launcher cleaned everything up, but it's still a good idea to verify the game files in Steam.\n\nSteam → Properties → Installed Files → Verify integrity of game files\n\nAfter that, click Apply Changes again if needed."
        }
    }

    package var requiresSteamRepair: Bool {
        if case .steamRepairRequired = self {
            return true
        }
        return false
    }
}
