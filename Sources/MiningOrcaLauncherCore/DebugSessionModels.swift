import Foundation

package struct DebugProcessIdentity: Hashable, Sendable {
    package let pid: Int32
    package let ppid: Int32
    package let command: String
    package let executable: String?
}

package struct DebugProcessObservation: Hashable, Sendable {
    package let pid: Int32
    package let ppid: Int32
    package let command: String
    package let executable: String?
    package let architecture: String?
    package let binaryArchitectures: [String]
    package let translatedByRosetta: Bool?
    package let dyldInsertLibrariesPresent: Bool?
    package let runtimeLoaded: Bool?
    package let steamAPIMappings: [String]
    package let inspectionError: String?
}

package struct DebugSessionPulse: Equatable, Sendable {
    package let gameProcessRunning: Bool
    let logExists: Bool
    let logSize: UInt64
    let logModificationDate: Date?
    package let processes: [DebugProcessIdentity]

    init(
        gameProcessRunning: Bool,
        logExists: Bool,
        logSize: UInt64,
        logModificationDate: Date?,
        processes: [DebugProcessIdentity]
    ) {
        self.gameProcessRunning = gameProcessRunning
        self.logExists = logExists
        self.logSize = logSize
        self.logModificationDate = logModificationDate
        self.processes = processes
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
    let earlyRuntimeLogURL: URL?
    let launchTraceURL: URL?
    let processTraceURL: URL?
    let configurationURL: URL?
    let hardwareArchitecture: String
    let launcherArchitecture: String
    let launcherTranslatedByRosetta: Bool?
    let observedRuntimeArchitecture: String?
    let observedExecutable: String?
    let observedProcessPID: Int32?
    let observedProcessPPID: Int32?
    let observedTranslatedByRosetta: Bool?
    let observedRuntimeLoaded: Bool?
    let observedSteamAPIMappings: [String]
    let debugRuntimeArchitectures: [String]

    init(
        directory: URL,
        archiveURL: URL,
        installLogURL: URL,
        runtimeLogURL: URL?,
        earlyRuntimeLogURL: URL?,
        launchTraceURL: URL?,
        processTraceURL: URL?,
        configurationURL: URL?,
        hardwareArchitecture: String,
        launcherArchitecture: String,
        launcherTranslatedByRosetta: Bool?,
        observedRuntimeArchitecture: String?,
        observedExecutable: String?,
        observedProcessPID: Int32?,
        observedProcessPPID: Int32?,
        observedTranslatedByRosetta: Bool?,
        observedRuntimeLoaded: Bool?,
        observedSteamAPIMappings: [String],
        debugRuntimeArchitectures: [String]
    ) {
        self.directory = directory
        self.archiveURL = archiveURL
        self.installLogURL = installLogURL
        self.runtimeLogURL = runtimeLogURL
        self.earlyRuntimeLogURL = earlyRuntimeLogURL
        self.launchTraceURL = launchTraceURL
        self.processTraceURL = processTraceURL
        self.configurationURL = configurationURL
        self.hardwareArchitecture = hardwareArchitecture
        self.launcherArchitecture = launcherArchitecture
        self.launcherTranslatedByRosetta = launcherTranslatedByRosetta
        self.observedRuntimeArchitecture = observedRuntimeArchitecture
        self.observedExecutable = observedExecutable
        self.observedProcessPID = observedProcessPID
        self.observedProcessPPID = observedProcessPPID
        self.observedTranslatedByRosetta = observedTranslatedByRosetta
        self.observedRuntimeLoaded = observedRuntimeLoaded
        self.observedSteamAPIMappings = observedSteamAPIMappings
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
