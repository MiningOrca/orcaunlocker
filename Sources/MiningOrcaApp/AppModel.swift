import Combine
import Foundation
import MiningOrcaLauncherCore

private enum ConfigurationValidationError: Error, LocalizedError {
    case invalidPurchaseDate(field: String, value: String)

    var errorDescription: String? {
        switch self {
        case .invalidPurchaseDate(let field, let value):
            return AppText.Errors.invalidPurchaseDate(field: field, value: value)
        }
    }
}

private enum PendingSteamOperation: Sendable {
    case apply(game: SteamGame, request: ApplyRequest)
    case restore(game: SteamGame)
    case debug(game: SteamGame, request: ApplyRequest)
}

private enum CompletedSteamOperation: Sendable {
    case apply(game: SteamGame, request: ApplyRequest, result: LauncherGameApplyResult)
    case restore(game: SteamGame, result: LauncherRestoreResult)
}

private enum LauncherOperationState: Equatable {
    case idle
    case checkingSteam
    case awaitingSteamDecision
    case applying
    case restoring
    case preparingDebug
    case debugRunning
    case capturingDebug
    case cleaningDebug
}

private enum DebugSessionEndReason {
    case gameExited
    case logInactive
    case stopped

    var text: String {
        switch self {
        case .gameExited:
            return AppText.Diagnostics.gameExited
        case .logInactive:
            return AppText.Diagnostics.logInactive
        case .stopped:
            return AppText.Diagnostics.stoppedByUser
        }
    }
}

private enum DebugSessionError: Error, LocalizedError {
    case gameAlreadyRunning
    case precleanFailed
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .gameAlreadyRunning:
            return AppText.Errors.quitGameBeforeDebug
        case .precleanFailed:
            return AppText.Errors.debugPrecleanFailed
        case .cleanupFailed:
            return AppText.Errors.debugCleanupFailed
        }
    }
}

@MainActor
final class LauncherAppModel: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var selectedGameID: UInt32?
    @Published var detail: GameDetailSnapshot?
    @Published var selectedTab: GameDetailTab = .overview
    @Published var searchText = ""
    @Published var draft = ConfigurationDraft()
    @Published var logs: [LauncherLogEntry] = []
    @Published var artworkByAppID: [UInt32: GameArtworkImages] = [:]
    @Published var advancedConfigText = ""
    @Published var advancedConfigError: String?
    @Published var diagnosticLogLines: [String] = []
    @Published var diagnosticLogTruncated = false
    @Published var diagnosticLogError: String?
    @Published var debugTransport: SteamTransport = .proxy
    @Published var debugLastResultText: String?
    @Published var debugLastCaptureURL: URL?
    @Published var isSavingAdvancedConfig = false
    @Published var isLoadingGames = false
    @Published var isLoadingDetail = false
    @Published var errorMessage: String?
    @Published var isSteamRunningPromptPresented = false
    @Published private var operationState: LauncherOperationState = .idle
    @Published private var steamRepairRequiredAppID: UInt32?
    private var pendingSteamOperation: PendingSteamOperation?
    private var logStreamTask: Task<Void, Never>?
    private var statusRefreshTask: Task<Void, Never>?
    private var steamRootURL: URL?
    private var artworkTasks: [UInt32: Task<Void, Never>] = [:]

    private var baselineDraft = ConfigurationDraft()
    private var advancedConfigBaselineText = ""
    private var advancedConfigFileExists = false
    private var steamRepairExpectedSteamAPICount: Int?
    private var debugStopRequested = false

    var filteredGames: [SteamGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return games
        }
        return games.filter {
            $0.name.localizedCaseInsensitiveContains(query) || String($0.appID).contains(query)
        }
    }

    var selectedGame: SteamGame? {
        guard let selectedGameID else {
            return nil
        }
        return games.first {
            $0.appID == selectedGameID
        }
    }

    var hasPendingChanges: Bool {
        draft != baselineDraft
    }

    var advancedConfigHasChanges: Bool {
        guard detail != nil else {
            return false
        }
        return advancedConfigText != advancedConfigBaselineText || !advancedConfigFileExists
    }

    var advancedConfigURL: URL? {
        detail?.configurationSource.url
    }

    var canSaveAdvancedConfig: Bool {
        advancedConfigHasChanges && !isSavingAdvancedConfig && !isOperationInProgress && !requiresSteamRepairForSelectedGame
    }

    var isOperationInProgress: Bool {
        operationState != .idle
    }

    var canRestoreOriginal: Bool {
        guard let detail, !requiresSteamRepairForSelectedGame else {
            return false
        }
        return detail.installation.states.contains {
            $0.kind != .untouched
        }
    }

    var canApplyChanges: Bool {
        guard let detail, !detail.installation.states.isEmpty, !requiresSteamRepairForSelectedGame else {
            return false
        }
        guard !detail.installation.hasBrokenState else {
            return false
        }
        return hasPendingChanges || (
            detail.configurationSource.validationError == nil
                && runtimeNeedsApply(detail: detail, transport: draft.transport)
        )
    }

    var requiresSteamRepairForSelectedGame: Bool {
        guard let selectedGameID else {
            return false
        }
        return steamRepairRequiredAppID == selectedGameID
    }

    var canRunDebug: Bool {
        guard let detail else {
            return false
        }
        return !detail.installation.states.isEmpty && !isOperationInProgress && !requiresSteamRepairForSelectedGame
    }

    var canStopDebug: Bool {
        operationState == .debugRunning
    }

    var debugSessionStatusText: String? {
        switch operationState {
        case .preparingDebug:
            return AppText.Diagnostics.preparingRuntime(debugTransport)
        case .debugRunning:
            return AppText.Diagnostics.sessionRunning(debugTransport)
        case .capturingDebug:
            return AppText.GameDetail.capturingDebugArtifacts
        case .cleaningDebug:
            return AppText.GameDetail.restoringCleanState
        default:
            return debugLastResultText
        }
    }

    var actionStatusText: String {
        switch operationState {
        case .checkingSteam:
            return AppText.GameDetail.checkingSteam
        case .awaitingSteamDecision:
            return AppText.GameDetail.waitingForSteamChoice
        case .applying:
            return AppText.GameDetail.applyingChanges
        case .restoring:
            return AppText.GameDetail.restoringOriginal
        case .preparingDebug:
            return AppText.GameDetail.preparingDebugSession
        case .debugRunning:
            return AppText.GameDetail.debugSessionRunning
        case .capturingDebug:
            return AppText.GameDetail.capturingDebugArtifacts
        case .cleaningDebug:
            return AppText.GameDetail.restoringCleanState
        case .idle:
            if requiresSteamRepairForSelectedGame {
                return AppText.GameDetail.steamRepairRequired
            }
            if detail?.installation.hasBrokenState == true {
                return AppText.GameDetail.restoreRequired
            }
            if hasPendingChanges {
                return AppText.GameDetail.pendingChanges
            }
            if let detail,
            detail.configurationSource.validationError == nil,
            runtimeNeedsApply(detail: detail, transport: draft.transport) {
                return AppText.GameDetail.runtimeInstallationRequired
            }
            return AppText.GameDetail.noPendingChanges
        }
    }

    init() {
        LauncherLogging.bootstrap(includeStandardError: false)
        let logStream = LauncherLogging.stream()
        logStreamTask = Task {
            [weak self] in
            for await entry in logStream {
                guard let self else {
                    return
                }
                guard entry.appID == self.selectedGameID else {
                    continue
                }
                self.refreshLogs()
            }
        }
        statusRefreshTask = Task {
            [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self else {
                    return
                }
                await self.refreshSelectedGameStatus()
            }
        }
        Task {
            await reloadGames()
        }
    }

    func reloadGames() async {
        isLoadingGames = true
        errorMessage = nil

        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let launcher = try LauncherCore.load()
                let library = try launcher.installedLibrary()
                let cachedArtwork = try await launcher.cachedArtwork(
                    for: library.games,
                    steamRootURL: library.steamRootURL
                )
                return (library, cachedArtwork)
            }.value

            steamRootURL = loaded.0.steamRootURL
            games = loaded.0.games.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            artworkByAppID = loaded.1.mapValues(GameArtworkImages.init)

            if selectedGameID == nil || !games.contains(where: {
                $0.appID == selectedGameID
            }) {
                selectedGameID = games.first?.appID
            }

            if let game = selectedGame {
                loadArtwork(for: game)
                await loadDetail(for: game)
            } else {
                detail = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        refreshLogs()
        isLoadingGames = false
    }

    func selectedGameChanged() {
        guard let game = selectedGame else {
            detail = nil
            isLoadingDetail = false
            logs = []
            advancedConfigText = ""
            advancedConfigBaselineText = ""
            advancedConfigFileExists = false
            advancedConfigError = nil
            diagnosticLogLines = []
            diagnosticLogTruncated = false
            diagnosticLogError = nil
            return
        }
        isLoadingDetail = true
        selectedTab = .overview
        diagnosticLogLines = []
        diagnosticLogTruncated = false
        diagnosticLogError = nil
        debugLastResultText = nil
        debugLastCaptureURL = nil
        refreshLogs()
        loadArtwork(for: game)
        Task {
            await loadDetail(for: game)
        }
    }

    private func loadArtwork(for game: SteamGame) {
        guard let steamRootURL else {
            return
        }
        guard artworkTasks[game.appID] == nil else {
            return
        }

        let appID = game.appID
        artworkTasks[appID] = Task {
            [weak self] in
            defer {
                self?.artworkTasks[appID] = nil
            }
            do {
                let artwork = try await Task.detached(priority: .utility) {
                    let launcher = try LauncherCore.load()
                    return try await launcher.artwork(for: game, steamRootURL: steamRootURL)
                }.value
                guard !artwork.isEmpty else {
                    return
                }
                self?.artworkByAppID[appID] = GameArtworkImages(artwork)
            } catch {
                // Artwork is decorative. A missing Steam cache entry, CDN failure,
                // or an unwritable launcher cache must never block game discovery.
            }
        }
    }

    func clearLogs() {
        guard let selectedGameID else {
            return
        }
        LauncherLogging.clear(appID: selectedGameID)
        refreshLogs()
    }

    func clearAdvancedConfigError() {
        advancedConfigError = nil
    }

    func resetAdvancedConfigurationToGenerated() {
        guard let detail else {
            return
        }
        do {
            let request = try makeApplyRequest(detail: detail)
            advancedConfigText = RuntimeConfigCodec.render(request.runtimeConfig(appID: detail.game.appID))
            advancedConfigError = nil
        } catch {
            advancedConfigError = error.localizedDescription
        }
    }

    func saveAdvancedConfiguration() {
        guard canSaveAdvancedConfig, let detail else {
            return
        }
        let game = detail.game
        let text = advancedConfigText
        let requestedAppID = game.appID
        isSavingAdvancedConfig = true
        advancedConfigError = nil

        Task {
            do {
                let source = try await Task.detached(priority: .userInitiated) {
                    try LauncherCore.load().saveConfigurationText(text, for: game)
                }.value

                if selectedGameID == requestedAppID, let current = self.detail {
                    let snapshot = GameDetailSnapshot(
                        game: current.game,
                        installation: current.installation,
                        configurationSource: source,
                        dlcs: current.dlcs
                    )
                    self.detail = snapshot
                    self.draft = ConfigurationDraft(snapshot: snapshot)
                    self.baselineDraft = self.draft
                    self.loadAdvancedConfiguration(from: source)
                    self.refreshLogs()
                }
            } catch {
                if selectedGameID == requestedAppID {
                    advancedConfigError = error.localizedDescription
                }
            }
            isSavingAdvancedConfig = false
        }
    }

    func requestApply() {
        guard canApplyChanges, !isOperationInProgress, let detail else {
            return
        }

        let request: ApplyRequest
        do {
            request = try makeApplyRequest(detail: detail)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let operation = PendingSteamOperation.apply(game: detail.game, request: request)
        Task {
            await prepare(operation, detail: detail)
        }
    }

    func requestRestore() {
        guard canRestoreOriginal, !isOperationInProgress, let detail else {
            return
        }
        let operation = PendingSteamOperation.restore(game: detail.game)
        Task {
            await prepare(operation, detail: detail)
        }
    }

    func requestRunDebug() {
        guard canRunDebug, let detail else {
            return
        }

        let request: ApplyRequest
        do {
            request = try makeDebugRequest(detail: detail, transport: debugTransport)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        debugLastResultText = nil
        debugLastCaptureURL = nil
        let operation = PendingSteamOperation.debug(game: detail.game, request: request)
        Task {
            await prepare(operation, detail: detail)
        }
    }

    func requestStopDebug() {
        guard canStopDebug else {
            return
        }
        debugStopRequested = true
    }

    func continueSteamRunningOperation() {
        guard let operation = pendingSteamOperation else {
            return
        }
        pendingSteamOperation = nil
        isSteamRunningPromptPresented = false
        Task {
            await perform(operation, restartSteamIfRunning: true)
        }
    }

    func cancelSteamRunningPrompt() {
        pendingSteamOperation = nil
        isSteamRunningPromptPresented = false
        operationState = .idle
    }

    func isDLCSelected(_ appID: UInt32) -> Bool {
        switch draft.dlcPolicy {
        case .all:
            return true
        case .none:
            return false
        case .explicit:
            return draft.selectedDLCIDs.contains(appID)
        }
    }

    func setDLCSelected(_ appID: UInt32, selected: Bool, knownDLCIDs: Set<UInt32>) {
        switch draft.dlcPolicy {
        case .all:
            guard !selected else {
                return
            }
            draft.selectedDLCIDs = knownDLCIDs
            draft.selectedDLCIDs.remove(appID)
            draft.dlcPolicy = .explicit

        case .none:
            guard selected else {
                return
            }
            draft.selectedDLCIDs = [appID]
            draft.dlcPolicy = .explicit

        case .explicit:
            if selected {
                draft.selectedDLCIDs.insert(appID)
            } else {
                draft.selectedDLCIDs.remove(appID)
            }
        }
    }

    func dlcPurchaseTime(_ appID: UInt32) -> DLCPurchaseTimeDraft {
        draft.dlcPurchaseTimes[appID] ?? .inherit
    }

    func setDLCPurchaseTime(
        _ value: DLCPurchaseTimeDraft,
        for appID: UInt32,
        knownDLCIDs: Set<UInt32>
    ) {
        if value == .inherit {
            draft.dlcPurchaseTimes.removeValue(forKey: appID)
        } else {
            draft.dlcPurchaseTimes[appID] = value
        }

        guard case .custom(let text) = value, !text.isEmpty else {
            return
        }

        switch draft.dlcPolicy {
        case .all:
            // A per-DLC override makes the selection explicit. Preserve the current
            // meaning of All by carrying every DLC currently known to the UI across.
            draft.selectedDLCIDs = knownDLCIDs
            draft.selectedDLCIDs.insert(appID)
            draft.dlcPolicy = .explicit

        case .none:
            draft.selectedDLCIDs = [appID]
            draft.dlcPolicy = .explicit

        case .explicit:
            draft.selectedDLCIDs.insert(appID)
        }
    }

    private func prepare(_ operation: PendingSteamOperation, detail: GameDetailSnapshot) async {
        operationState = .checkingSteam
        errorMessage = nil

        do {
            let needsLaunchOptions = requiresSteamConfigMutation(operation, detail: detail)
            let steamRunning: Bool
            if needsLaunchOptions {
                steamRunning = try await Task.detached(priority: .userInitiated) {
                    try LauncherCore.load().steamIsRunning(for: detail.game)
                }.value
            } else {
                steamRunning = false
            }

            if steamRunning {
                pendingSteamOperation = operation
                operationState = .awaitingSteamDecision
                isSteamRunningPromptPresented = true
            } else {
                await perform(operation, restartSteamIfRunning: false)
            }
        } catch {
            operationState = .idle
            errorMessage = error.localizedDescription
            refreshLogs()
        }
    }

    private func perform(_ operation: PendingSteamOperation,
    restartSteamIfRunning: Bool) async {
        let game: SteamGame
        switch operation {
        case .apply(let operationGame, _):
            game = operationGame
            operationState = .applying
        case .restore(let operationGame):
            game = operationGame
            operationState = .restoring
        case .debug(let operationGame, let request):
            await performDebug(
                game: operationGame,
                request: request,
                restartSteamIfRunning: restartSteamIfRunning
            )
            return
        }

        errorMessage = nil

        do {
            let completed = try await Task.detached(priority: .userInitiated) {
                let launcher = try LauncherCore.load()
                switch operation {
                case .apply(let game, let request):
                    let effectiveRequest = ApplyRequest(
                        transport: request.transport,
                        profile: request.profile,
                        policy: request.policy,
                        knownDLCs: request.knownDLCs,
                        restartSteamIfRunning: restartSteamIfRunning
                    )
                    let result = try launcher.apply(game: game, request: effectiveRequest)
                    return CompletedSteamOperation.apply(
                        game: game,
                        request: request,
                        result: result
                    )

                case .restore(let game):
                    let result = try launcher.restore(
                        game: game,
                        restartSteamIfRunning: restartSteamIfRunning
                    )
                    return CompletedSteamOperation.restore(game: game, result: result)

                case .debug:
                    preconditionFailure("Debug operations are handled by performDebug")
                }
            }.value

            if selectedGameID == game.appID {
                updateDetail(after: completed)
            }
            refreshLogs()
        } catch {
            if let launcherError = error as? LauncherCoreError,
               launcherError.requiresSteamRepair {
                steamRepairRequiredAppID = game.appID
                steamRepairExpectedSteamAPICount = detail?.game.appID == game.appID
                    ? detail?.installation.states.count
                    : nil
            }
            errorMessage = error.localizedDescription
            refreshLogs()
        }

        operationState = .idle
    }

    private func performDebug(
        game: SteamGame,
        request: ApplyRequest,
        restartSteamIfRunning: Bool
    ) async {
        operationState = .preparingDebug
        errorMessage = nil
        debugStopRequested = false
        debugTransport = request.transport
        let sessionStartedAt = Date()
        var cleanupNeeded = false
        var steamStoppedForPreparation = false
        var capture: DebugArtifactCapture?
        var configurationSnapshot: DebugConfigurationSnapshot?
        var debugInstalledState: LauncherGameState?
        var cleanupState: LauncherGameState?
        var cleanupRequiresSteamRepair = false
        var cleanupStartedAt: Date?
        var endReasonText = AppText.Diagnostics.sessionFailedBeforeRuntimeCompleted

        do {
            let initialPulse = try await Task.detached(priority: .utility) {
                try LauncherCore.load().debugSessionPulse(game: game)
            }.value
            guard !initialPulse.gameProcessRunning else {
                throw DebugSessionError.gameAlreadyRunning
            }

            configurationSnapshot = try await Task.detached(priority: .utility) {
                try LauncherCore.load().debugConfigurationSnapshot(game: game)
            }.value

            if restartSteamIfRunning {
                steamStoppedForPreparation = try await Task.detached(priority: .userInitiated) {
                    try LauncherCore.load().stopSteamForMutation(game: game)
                }.value
            }

            let preclean = try await Task.detached(priority: .userInitiated) {
                try LauncherCore.load().restore(
                    game: game,
                    // A debug preparation is a grouped operation. If Steam was
                    // running, it was stopped once above and must stay stopped
                    // through both pre-clean and debug Apply.
                    restartSteamIfRunning: false
                )
            }.value

            if preclean.requiresSteamRepair {
                if steamStoppedForPreparation {
                    try await Task.detached(priority: .userInitiated) {
                        try LauncherCore.load().startSteamAfterMutation(game: game)
                    }.value
                    steamStoppedForPreparation = false
                }
                if selectedGameID == game.appID {
                    updateDetail(after: .restore(game: game, result: preclean))
                }
                refreshLogs()
                operationState = .idle
                return
            }

            guard preclean.stateAfter.isUntouchedAndPresent else {
                throw DebugSessionError.precleanFailed
            }

            // From this point forward, any failure may have left a partial debug
            // transport behind. Always attempt a clean restore before returning.
            cleanupNeeded = true

            let debugApply = try await Task.detached(priority: .userInitiated) {
                let effectiveRequest = ApplyRequest(
                    transport: request.transport,
                    profile: request.profile,
                    policy: request.policy,
                    knownDLCs: request.knownDLCs,
                    restartSteamIfRunning: false
                )
                return try LauncherCore.load().apply(game: game, request: effectiveRequest)
            }.value
            debugInstalledState = debugApply.stateAfter

            if steamStoppedForPreparation {
                try await Task.detached(priority: .userInitiated) {
                    try LauncherCore.load().startSteamAfterMutation(game: game)
                }.value
                steamStoppedForPreparation = false
            }

            let installLog = formatLauncherLog(appID: game.appID, since: sessionStartedAt)
            let runtime = try await runDebugRuntimeAndCapture(
                game: game,
                installLog: installLog,
                transport: request.transport,
                debugState: debugApply.stateAfter
            )
            capture = runtime.capture
            endReasonText = runtime.endReason.text

            operationState = .cleaningDebug
            cleanupStartedAt = Date()
            let cleanup = try await restoreDebugInstallation(game: game)
            cleanupNeeded = false
            cleanupState = cleanup.stateAfter
            cleanupRequiresSteamRepair = cleanup.requiresSteamRepair
            try await finishDebugCleanup(
                cleanup,
                game: game,
                configurationSnapshot: configurationSnapshot,
                endReason: runtime.endReason
            )

            let context = DebugReportContext(
                transport: request.transport,
                startedAt: sessionStartedAt,
                finishedAt: Date(),
                endReason: endReasonText,
                debugState: debugApply.stateAfter,
                cleanupState: cleanupState,
                cleanupRequiresSteamRepair: cleanupRequiresSteamRepair,
                cleanupError: nil,
                sessionError: nil
            )
            debugLastCaptureURL = try await finalizeDebugReport(
                capture: runtime.capture,
                game: game,
                context: context,
                cleanupStartedAt: cleanupStartedAt ?? sessionStartedAt
            )
        } catch {
            let sessionErrorDescription = error.localizedDescription
            var cleanupFailure: Error?

            if cleanupNeeded {
                cleanupStartedAt = cleanupStartedAt ?? Date()
                let recovery = await recoverFailedDebugCleanup(
                    game: game,
                    configurationSnapshot: configurationSnapshot
                )
                cleanupState = recovery.result?.stateAfter
                cleanupRequiresSteamRepair = recovery.result?.requiresSteamRepair ?? false
                cleanupFailure = recovery.failure
            }

            if steamStoppedForPreparation {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try LauncherCore.load().startSteamAfterMutation(game: game)
                    }.value
                    steamStoppedForPreparation = false
                } catch {
                    if cleanupFailure == nil {
                        cleanupFailure = error
                    }
                }
            }

            if let capture, let debugInstalledState {
                let context = DebugReportContext(
                    transport: request.transport,
                    startedAt: sessionStartedAt,
                    finishedAt: Date(),
                    endReason: endReasonText,
                    debugState: debugInstalledState,
                    cleanupState: cleanupState,
                    cleanupRequiresSteamRepair: cleanupRequiresSteamRepair,
                    cleanupError: cleanupFailure?.localizedDescription,
                    sessionError: sessionErrorDescription
                )
                do {
                    debugLastCaptureURL = try await finalizeDebugReport(
                        capture: capture,
                        game: game,
                        context: context,
                        cleanupStartedAt: cleanupStartedAt ?? sessionStartedAt
                    )
                } catch {
                    // Preserve the original debug-session error if best-effort report
                    // finalization also fails.
                }
            }

            let captureText = debugLastCaptureURL.map {
                AppText.Errors.diagnosticReportSuffix(path: $0.path)
            } ?? ""
            if let cleanupFailure {
                errorMessage = AppText.Errors.debugSessionFailed(
                    sessionErrorDescription,
                    cleanupFailure: cleanupFailure.localizedDescription,
                    captureSuffix: captureText
                )
            } else {
                errorMessage = AppText.Errors.debugSessionFailed(
                    sessionErrorDescription,
                    captureSuffix: captureText
                )
            }
        }

        debugStopRequested = false
        operationState = .idle
        refreshLogs()
        await refreshSelectedGameStatus()
    }

    private func runDebugRuntimeAndCapture(
        game: SteamGame,
        installLog: String,
        transport: SteamTransport,
        debugState: LauncherGameState
    ) async throws -> (endReason: DebugSessionEndReason, capture: DebugArtifactCapture) {
        try await Task.detached(priority: .userInitiated) {
            let launcher = try LauncherCore.load()
            try launcher.clearDebugRuntimeLog(game: game)
            try launcher.launchDebugGame(game: game)
        }.value

        diagnosticLogLines = []
        diagnosticLogTruncated = false
        diagnosticLogError = nil
        operationState = .debugRunning

        let sessionEnd = try await waitForDebugSessionEnd(
            game: game,
            steamAPITargets: debugState.steamAPITargetURLs
        )
        let endReason = sessionEnd.reason

        // Give the process a brief moment to flush final buffered log lines after
        // it disappears from the process table before freezing the artifacts.
        if case .gameExited = endReason {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        operationState = .capturingDebug
        await refreshDiagnosticLog()
        let capture = try await Task.detached(priority: .utility) {
            try LauncherCore.load().captureDebugArtifacts(
                game: game,
                installLog: installLog,
                transport: transport,
                debugState: debugState,
                processObservations: sessionEnd.processObservations
            )
        }.value
        return (endReason, capture)
    }

    private func restoreDebugInstallation(game: SteamGame) async throws -> LauncherRestoreResult {
        try await Task.detached(priority: .userInitiated) {
            try LauncherCore.load().restore(
                game: game,
                // Cleanup is part of the already-approved debug session. Stop/restart
                // Steam automatically when removing an Inject hook rather than writing
                // localconfig.vdf under a running client.
                restartSteamIfRunning: true
            )
        }.value
    }

    private func finishDebugCleanup(
        _ cleanup: LauncherRestoreResult,
        game: SteamGame,
        configurationSnapshot: DebugConfigurationSnapshot?,
        endReason: DebugSessionEndReason
    ) async throws {
        if cleanup.requiresSteamRepair {
            if selectedGameID == game.appID {
                updateDetail(after: .restore(game: game, result: cleanup))
            }
            debugLastResultText = AppText.Diagnostics.result(
                endReason.text,
                suffix: AppText.GameDetail.steamRepairRequired
            )
            return
        }

        guard cleanup.stateAfter.isUntouchedAndPresent,
              let configurationSnapshot else {
            throw DebugSessionError.cleanupFailed
        }

        try await restoreDebugConfigurationAfterCleanup(
            configurationSnapshot,
            game: game,
            state: cleanup.stateAfter
        )
        debugLastResultText = AppText.Diagnostics.result(
            endReason.text,
            suffix: AppText.Diagnostics.cleanStateRestored
        )
    }

    private func recoverFailedDebugCleanup(
        game: SteamGame,
        configurationSnapshot: DebugConfigurationSnapshot?
    ) async -> (result: LauncherRestoreResult?, failure: Error?) {
        operationState = .cleaningDebug
        var result: LauncherRestoreResult?

        do {
            let cleanup = try await restoreDebugInstallation(game: game)
            result = cleanup

            if cleanup.requiresSteamRepair {
                if selectedGameID == game.appID {
                    updateDetail(after: .restore(game: game, result: cleanup))
                }
            } else if let configurationSnapshot {
                try await restoreDebugConfigurationAfterCleanup(
                    configurationSnapshot,
                    game: game,
                    state: cleanup.stateAfter
                )
            }
            return (result, nil)
        } catch {
            return (result, error)
        }
    }

    private func restoreDebugConfigurationAfterCleanup(
        _ snapshot: DebugConfigurationSnapshot,
        game: SteamGame,
        state: LauncherGameState
    ) async throws {
        let configurationSource = try await Task.detached(priority: .userInitiated) {
            try LauncherCore.load().restoreDebugConfiguration(snapshot, game: game)
        }.value
        if selectedGameID == game.appID {
            updateDetailAfterDebugCleanup(
                game: game,
                state: state,
                configurationSource: configurationSource
            )
        }
    }

    private func finalizeDebugReport(
        capture: DebugArtifactCapture,
        game: SteamGame,
        context: DebugReportContext,
        cleanupStartedAt: Date
    ) async throws -> URL {
        let cleanupLog = formatLauncherLog(appID: game.appID, since: cleanupStartedAt)
        let finalized = try await Task.detached(priority: .utility) {
            try LauncherCore.load().finalizeDebugArtifacts(
                capture: capture,
                game: game,
                context: context,
                cleanupLog: cleanupLog
            )
        }.value
        return finalized.archiveURL
    }

    private func waitForDebugSessionEnd(
        game: SteamGame,
        steamAPITargets: [URL]
    ) async throws -> (reason: DebugSessionEndReason, processObservations: [DebugProcessObservation]) {
        let inactivityLimit: TimeInterval = 10 * 60
        var sawGameProcess = false
        var previousGameProcessRunning: Bool?
        var previousLogFingerprint: DebugLogFingerprint?
        var lastLogActivity = Date()
        var observedPIDs = Set<Int32>()
        var processObservations: [DebugProcessObservation] = []

        while !Task.isCancelled {
            if debugStopRequested {
                return (.stopped, processObservations)
            }

            let pulse = try await Task.detached(priority: .utility) {
                try LauncherCore.load().debugSessionPulse(game: game)
            }.value

            for identity in pulse.processes where observedPIDs.insert(identity.pid).inserted {
                let observation = try await Task.detached(priority: .utility) {
                   try LauncherCore.load().inspectDebugProcess(
                        identity,
                        game: game,
                        steamAPITargets: steamAPITargets
                    )
                }.value
                processObservations.append(observation)
            }

            if previousGameProcessRunning != pulse.gameProcessRunning {
                previousGameProcessRunning = pulse.gameProcessRunning
            }

            if pulse.gameProcessRunning {
                sawGameProcess = true
            } else if sawGameProcess {
                return (.gameExited, processObservations)
            }

            let fingerprint = pulse.logFingerprint
            if let previousLogFingerprint {
                if fingerprint != previousLogFingerprint {
                    lastLogActivity = Date()
                }
            } else if fingerprint.exists {
                lastLogActivity = Date()
            }
            previousLogFingerprint = fingerprint

            if Date().timeIntervalSince(lastLogActivity) >= inactivityLimit {
                return (.logInactive, processObservations)
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        return (.stopped, processObservations)
    }

    private func formatLauncherLog(appID: UInt32,
    since start: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let lines = LauncherLogging.entries(appID: appID).filter {
            $0.timestamp >= start
        }.map {
            entry in
            let metadata = entry.metadata.filter {
                $0.key != "app_id"
            }.sorted {
                $0.key < $1.key
            }.map {
                "\($0.key)=\($0.value)"
            }.joined(separator: " ")
            let suffix = metadata.isEmpty ? "": " \(metadata)"
            return "\(formatter.string(from: entry.timestamp)) \(entry.levelText) \(entry.message)\(suffix)"
        }

        return lines.joined(separator: "\n") + (lines.isEmpty ? "": "\n")
    }

    private func updateDetailAfterDebugCleanup(game: SteamGame,
    state: LauncherGameState,
    configurationSource: RuntimeConfigSource) {
        guard let current = detail, current.game.appID == game.appID else {
            return
        }

        detail = GameDetailSnapshot(
            game: game,
            installation: state,
            configurationSource: configurationSource,
            dlcs: current.dlcs
        )
        // A debug session is transport-only. Preserve the user's structured draft,
        // raw editor text, and their baselines exactly as they were before the run.
    }

    private func updateDetail(after completed: CompletedSteamOperation) {
        guard let current = detail else {
            return
        }

        let snapshot: GameDetailSnapshot
        switch completed {
        case .apply(let game, _, let result):
            guard current.game.appID == game.appID else {
                return
            }
            if steamRepairRequiredAppID == game.appID {
                steamRepairRequiredAppID = nil
                steamRepairExpectedSteamAPICount = nil
            }
            snapshot = GameDetailSnapshot(
                game: game,
                installation: result.stateAfter,
                configurationSource: RuntimeConfigSource(
                    url: result.configURL,
                    text: result.configurationText,
                    configuration: result.configuration,
                    fileExists: true
                ),
                dlcs: current.dlcs
            )

        case .restore(let game, let result):
            guard current.game.appID == game.appID else {
                return
            }
            snapshot = GameDetailSnapshot(
                game: game,
                installation: result.stateAfter,
                configurationSource: result.configurationSource,
                dlcs: current.dlcs
            )
            if result.requiresSteamRepair {
                steamRepairRequiredAppID = game.appID
                steamRepairExpectedSteamAPICount = result.stateBefore.steamAPICount
                errorMessage = LauncherCoreError.steamRepairRequired.localizedDescription
            }
        }

        detail = snapshot
        draft = ConfigurationDraft(snapshot: snapshot)
        baselineDraft = draft
        loadAdvancedConfiguration(from: snapshot.configurationSource)
    }

    private func makeApplyRequest(detail: GameDetailSnapshot) throws -> ApplyRequest {
        let selection: DLCSelection
        switch draft.dlcPolicy {
        case .all:
            selection = .all
        case .none:
            selection = .none
        case .explicit:
            selection = .explicit(draft.selectedDLCIDs)
        }

        let globalPurchaseTime = try parsePurchaseDate(
            draft.purchaseTime,
            field: AppText.Configuration.purchaseTime,
            emptyMeansValve: true
        )

        var dlcNames: [UInt32: String] = [:]
        for dlc in detail.dlcs.dlcs {
            if let name = dlc.name {
                dlcNames[dlc.appID] = name
            }
        }
        var perDLC: [UInt32: RuntimePurchaseTime] = [:]
        for (appID, value) in draft.dlcPurchaseTimes {
            switch value {
            case .inherit:
                break
            case .valve:
                perDLC[appID] = .valve
            case .custom(let text):
                let name = dlcNames[appID] ?? AppText.GameDetail.dlcFallbackName(appID)
                perDLC[appID] = try parsePurchaseDate(
                    text,
                    field: AppText.Configuration.purchaseDateField(dlcName: name, appID: appID),
                    emptyMeansValve: false
                )
            }
        }

        let language = draft.language.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowViolence: Bool?
        switch draft.lowViolence {
        case .valve:
            lowViolence = nil
        case .enabled:
            lowViolence = true
        case .disabled:
            lowViolence = false
        }

        return ApplyRequest(
            transport: draft.transport,
            profile: .production,
            policy: RuntimePolicy(
                selection: selection,
                globalPurchaseTime: globalPurchaseTime,
                dlcPurchaseTimes: perDLC,
                language: language.isEmpty ? nil : language,
                lowViolence: lowViolence
            ),
            knownDLCs: detail.dlcs.dlcs,
            restartSteamIfRunning: false
        )
    }

    private func makeDebugRequest(detail: GameDetailSnapshot,
    transport: SteamTransport) throws -> ApplyRequest {
        if let config = detail.configuration {
            return ApplyRequest(
                transport: transport,
                profile: .debug,
                policy: config.policy,
                knownDLCs: detail.dlcs.dlcs,
                restartSteamIfRunning: false
            )
        }

        let generated = try makeApplyRequest(detail: detail)
        return ApplyRequest(
            transport: transport,
            profile: .debug,
            policy: generated.policy,
            knownDLCs: generated.knownDLCs,
            restartSteamIfRunning: false
        )
    }

    private func parsePurchaseDate(_ rawValue: String,
    field: String,
    emptyMeansValve: Bool) throws -> RuntimePurchaseTime {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty, emptyMeansValve {
            return .valve
        }

        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
        parts[0].count == 2,
        parts[1].count == 2,
        parts[2].count == 4,
        let day = Int(parts[0]),
        let month = Int(parts[1]),
        let year = Int(parts[2]) else {
            throw ConfigurationValidationError.invalidPurchaseDate(field: field, value: value)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day

        guard let date = calendar.date(from: components) else {
            throw ConfigurationValidationError.invalidPurchaseDate(field: field, value: value)
        }

        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            throw ConfigurationValidationError.invalidPurchaseDate(field: field, value: value)
        }

        let timestamp = Int64(date.timeIntervalSince1970)
        guard timestamp >= 0 else {
            throw ConfigurationValidationError.invalidPurchaseDate(field: field, value: value)
        }
        return .timestamp(timestamp)
    }

    private func requiresSteamConfigMutation(_ operation: PendingSteamOperation,
    detail: GameDetailSnapshot) -> Bool {
        switch operation {
        case .apply(_, let request):
            switch request.transport {
            case .inject:
                return runtimeNeedsApply(detail: detail, transport: .inject)
            case .proxy:
                return detail.installation.hasInjectFootprint
            }
        case .restore:
            return detail.installation.hasInjectFootprint
        case .debug(_, let request):
            return detail.installation.hasInjectFootprint
                || (!detail.installation.hasBrokenState && request.transport == .inject)
        }
    }

    private func runtimeNeedsApply(detail: GameDetailSnapshot,
    transport: SteamTransport) -> Bool {
        guard !detail.installation.states.isEmpty else { return false }
        return !detail.installation.matchesRuntime(transport: transport, profile: .production)
    }

    func refreshSelectedGameStatusNow() {
        Task {
            await refreshSelectedGameStatus()
        }
    }

    func refreshDiagnosticLog() async {
        guard let game = selectedGame else {
            diagnosticLogLines = []
            diagnosticLogTruncated = false
            diagnosticLogError = nil
            return
        }

        let requestedAppID = game.appID
        do {
            let tail = try await Task.detached(priority: .utility) {
                try LauncherCore.load().logTail(game: game)
            }.value

            guard selectedGameID == requestedAppID else {
                return
            }
            diagnosticLogLines = tail.lines
            diagnosticLogTruncated = tail.truncatedByBytes
            diagnosticLogError = nil
        } catch {
            guard selectedGameID == requestedAppID else {
                return
            }
            diagnosticLogError = error.localizedDescription
        }
    }

    private func refreshSelectedGameStatus() async {
        guard operationState == .idle,
        !isLoadingDetail,
        let game = selectedGame,
        detail != nil else {
            return
        }

        let requestedAppID = game.appID
        do {
            let gameState = try await Task.detached(priority: .utility) {
                try LauncherCore.load().pollInstallationState(game: game)
            }.value

            guard selectedGameID == requestedAppID,
            let latest = detail,
            latest.game.appID == requestedAppID else {
                return
            }

            detail = GameDetailSnapshot(
                game: latest.game,
                installation: gameState.retainingSteamAPITargetURLsIfEmpty(
                    from: latest.installation
                ),
                configurationSource: latest.configurationSource,
                dlcs: latest.dlcs
            )

            if steamRepairRequiredAppID == requestedAppID,
            steamRepairIsComplete(gameState) {
                steamRepairRequiredAppID = nil
                steamRepairExpectedSteamAPICount = nil
            }
        } catch {
            // Periodic status refresh is best-effort. Keep the last known snapshot
            // and let explicit user operations surface actionable errors.
        }
    }

    private func steamRepairIsComplete(_ state: LauncherGameState) -> Bool {
        let expectedCount = steamRepairExpectedSteamAPICount ?? 1
        return state.states.count >= expectedCount && state.isUntouchedAndPresent
    }

    private func loadDetail(for game: SteamGame) async {
        isLoadingDetail = true
        errorMessage = nil
        let requestedAppID = game.appID

        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let launcher = try LauncherCore.load()
                let gameState = try launcher.inspect(game: game)
                let configurationSource = try launcher.configurationSource(for: game)
                let dlcs = try await launcher.discoverDLCs(game: game, includeContentState: true)
                return GameDetailSnapshot(
                    game: game,
                    installation: gameState,
                    configurationSource: configurationSource,
                    dlcs: dlcs
                )
            }.value

            guard selectedGameID == requestedAppID else {
                return
            }
            if steamRepairRequiredAppID == requestedAppID,
            steamRepairIsComplete(snapshot.installation) {
                steamRepairRequiredAppID = nil
                steamRepairExpectedSteamAPICount = nil
            }
            detail = snapshot
            draft = ConfigurationDraft(snapshot: snapshot)
            baselineDraft = draft
            debugTransport = draft.transport
            loadAdvancedConfiguration(from: snapshot.configurationSource)
        } catch {
            guard selectedGameID == requestedAppID else {
                return
            }
            detail = nil
            errorMessage = error.localizedDescription
        }

        refreshLogs()
        isLoadingDetail = false
    }

    private func loadAdvancedConfiguration(from source: RuntimeConfigSource) {
        advancedConfigText = source.text
        advancedConfigBaselineText = source.text
        advancedConfigFileExists = source.fileExists
        advancedConfigError = source.validationError?.localizedDescription
    }

    private func refreshLogs() {
        guard let selectedGameID else {
            logs = []
            return
        }
        logs = LauncherLogging.entries(appID: selectedGameID)
    }

}

func formatPurchaseDateInput(_ rawValue: String) -> String {
    let digits = rawValue.filter { $0.isNumber }.prefix(8)
    let value = String(digits)

    guard value.count > 2 else {
        return value
    }

    let dayEnd = value.index(value.startIndex, offsetBy: 2)
    let day = value[..<dayEnd]
    let remainder = value[dayEnd...]

    guard remainder.count > 2 else {
        return "\(day).\(remainder)"
    }

    let monthEnd = remainder.index(remainder.startIndex, offsetBy: 2)
    let month = remainder[..<monthEnd]
    let year = remainder[monthEnd...]
    return "\(day).\(month).\(year)"
}
