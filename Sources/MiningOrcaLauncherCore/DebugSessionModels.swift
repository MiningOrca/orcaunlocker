import Foundation

package struct DebugSessionPulse: Equatable, Sendable {
    package let gameProcessRunning: Bool
    let logExists: Bool
    let logSize: UInt64
    let logModificationDate: Date?

    init(
        gameProcessRunning: Bool,
        logExists: Bool,
        logSize: UInt64,
        logModificationDate: Date?
    ) {
        self.gameProcessRunning = gameProcessRunning
        self.logExists = logExists
        self.logSize = logSize
        self.logModificationDate = logModificationDate
    }

    package var logFingerprint: DebugLogFingerprint {
        DebugLogFingerprint(
            exists: logExists,
            size: logSize,
            modificationDate: logModificationDate
        )
    }
}

package struct DebugLogFingerprint: Equatable, Sendable {
    package let exists: Bool
    let size: UInt64
    let modificationDate: Date?

    init(exists: Bool, size: UInt64, modificationDate: Date?) {
        self.exists = exists
        self.size = size
        self.modificationDate = modificationDate
    }
}

package struct DebugConfigurationSnapshot: Sendable {
    let data: Data?

    init(data: Data?) {
        self.data = data
    }

    var fileExisted: Bool {
        data != nil
    }
}

package struct DebugArtifactCapture: Sendable {
    let directory: URL
    package let archiveURL: URL
    let installLogURL: URL
    let runtimeLogURL: URL?
    let configurationURL: URL?
    let hardwareArchitecture: String
    let launcherArchitecture: String
    let launcherTranslatedByRosetta: Bool?
    let observedRuntimeArchitecture: String?
    let observedExecutable: String?
    let debugRuntimeArchitectures: [String]

    init(
        directory: URL,
        archiveURL: URL,
        installLogURL: URL,
        runtimeLogURL: URL?,
        configurationURL: URL?,
        hardwareArchitecture: String,
        launcherArchitecture: String,
        launcherTranslatedByRosetta: Bool?,
        observedRuntimeArchitecture: String?,
        observedExecutable: String?,
        debugRuntimeArchitectures: [String]
    ) {
        self.directory = directory
        self.archiveURL = archiveURL
        self.installLogURL = installLogURL
        self.runtimeLogURL = runtimeLogURL
        self.configurationURL = configurationURL
        self.hardwareArchitecture = hardwareArchitecture
        self.launcherArchitecture = launcherArchitecture
        self.launcherTranslatedByRosetta = launcherTranslatedByRosetta
        self.observedRuntimeArchitecture = observedRuntimeArchitecture
        self.observedExecutable = observedExecutable
        self.debugRuntimeArchitectures = debugRuntimeArchitectures
    }
}

package struct DebugReportContext: Sendable {
    let transport: SteamTransport
    let startedAt: Date
    let finishedAt: Date
    let endReason: String
    let debugState: LauncherGameState
    let cleanupState: LauncherGameState?
    let cleanupRequiresSteamRepair: Bool
    let cleanupError: String?
    let sessionError: String?

    package init(
        transport: SteamTransport,
        startedAt: Date,
        finishedAt: Date,
        endReason: String,
        debugState: LauncherGameState,
        cleanupState: LauncherGameState?,
        cleanupRequiresSteamRepair: Bool,
        cleanupError: String?,
        sessionError: String?
    ) {
        self.transport = transport
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.endReason = endReason
        self.debugState = debugState
        self.cleanupState = cleanupState
        self.cleanupRequiresSteamRepair = cleanupRequiresSteamRepair
        self.cleanupError = cleanupError
        self.sessionError = sessionError
    }
}
