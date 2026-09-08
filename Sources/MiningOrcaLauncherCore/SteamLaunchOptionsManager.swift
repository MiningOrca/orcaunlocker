import Foundation

enum SteamLaunchOptionsError: Error, LocalizedError {
    case steamDidNotQuit
    case steamDidNotRestart

    var errorDescription: String? {
        switch self {
        case .steamDidNotQuit:
            return "Steam did not quit before the configured timeout."
        case .steamDidNotRestart:
            return "Steam did not restart before the configured timeout."
        }
    }
}

struct SteamLaunchOptionsMutationResult: Sendable {
    let modifiedLocalConfigs: [URL]
    let steamWasRunning: Bool
    let steamRestarted: Bool

    init(modifiedLocalConfigs: [URL], steamWasRunning: Bool, steamRestarted: Bool) {
        self.modifiedLocalConfigs = modifiedLocalConfigs
        self.steamWasRunning = steamWasRunning
        self.steamRestarted = steamRestarted
    }
}

struct SteamProcessController {
    private let settings: LauncherSettings.Steam

    init(settings: LauncherSettings.Steam) {
        self.settings = settings
    }

    func isRunning() throws -> Bool {
        let checks = [
            ["-x", "steam_osx"],
            ["-x", "Steam"],
        ]
        for arguments in checks {
            let result = try SystemTool.run("/usr/bin/pgrep", arguments: arguments, check: false)
            if result.status == 0 { return true }
        }
        return false
    }

    func quitAndWait() throws {
        _ = try SystemTool.run(
            "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Steam\" to quit"],
            check: false
        )

        try waitForRunningState(false, timeoutError: .steamDidNotQuit)
    }

    func restartAndWait() throws {
        _ = try SystemTool.run("/usr/bin/open", arguments: ["-a", "Steam"])

        try waitForRunningState(true, timeoutError: .steamDidNotRestart)
    }

    private func waitForRunningState(
        _ expectedRunning: Bool,
        timeoutError: SteamLaunchOptionsError
    ) throws {
        let deadline = Date().addingTimeInterval(settings.restartTimeoutSeconds)
        while Date() < deadline {
            if try isRunning() == expectedRunning { return }
            Thread.sleep(forTimeInterval: settings.restartPollIntervalSeconds)
        }
        throw timeoutError
    }
}

struct SteamLaunchOptionsManager {
    private let helper: SteamHelperClient
    private let processController: SteamProcessController

    init(
        helper: SteamHelperClient,
        steamSettings: LauncherSettings.Steam
    ) {
        self.helper = helper
        self.processController = SteamProcessController(settings: steamSettings)
    }

    func inspect(appID: UInt32) throws -> SteamLaunchOptionsSnapshot {
        try helper.launchOptionsAll(appID: appID)
    }

    func installHook(
        appID: UInt32,
        prefixWrapper: URL,
        commandWrapper: URL,
        restartSteamIfRunning: Bool
    ) throws -> SteamLaunchOptionsMutationResult {
        try mutate(appID: appID, restartSteamIfRunning: restartSteamIfRunning) {
            LauncherLog.logger.info(
                "Writing Inject Launch Options through Steam helper",
                metadata: ["app_id": "\(appID)"]
            )
            return try helper.installLaunchOptions(
                appID: appID,
                prefixWrapper: prefixWrapper,
                commandWrapper: commandWrapper
            )
        }
    }

    func removeHooks(
        appID: UInt32,
        prefixWrapper: URL,
        commandWrapper: URL,
        restartSteamIfRunning: Bool
    ) throws -> SteamLaunchOptionsMutationResult {
        try mutate(appID: appID, restartSteamIfRunning: restartSteamIfRunning) {
            LauncherLog.logger.info(
                "Removing Inject Launch Options through Steam helper",
                metadata: ["app_id": "\(appID)"]
            )
            return try helper.removeLaunchOptions(
                appID: appID,
                prefixWrapper: prefixWrapper,
                commandWrapper: commandWrapper
            )
        }
    }

    private func mutate(
        appID: UInt32,
        restartSteamIfRunning: Bool,
        action: () throws -> [URL]
    ) throws -> SteamLaunchOptionsMutationResult {
        let wasRunning = try processController.isRunning()
        var restarted = false

        if wasRunning && restartSteamIfRunning {
            LauncherLog.logger.info(
                "Steam is running; quitting it before Launch Options update",
                metadata: ["app_id": "\(appID)"]
            )
            try processController.quitAndWait()
        } else if wasRunning {
            LauncherLog.logger.warning(
                "Steam is running; Launch Options will be written without restarting Steam and may be overwritten later",
                metadata: ["app_id": "\(appID)"]
            )
        }

        do {
            // The helper reads localconfig only after Steam has quit, so any config
            // Steam flushed during shutdown is included in the mutation.
            let modified = try action()

            if wasRunning && restartSteamIfRunning {
                LauncherLog.logger.info(
                    "Restarting Steam after Launch Options update",
                    metadata: ["app_id": "\(appID)"]
                )
                try processController.restartAndWait()
                restarted = true
            }

            LauncherLog.logger.info(
                modified.isEmpty ? "Steam Launch Options already match requested state" : "Steam Launch Options update complete",
                metadata: ["app_id": "\(appID)", "accounts_modified": "\(modified.count)"]
            )
            return SteamLaunchOptionsMutationResult(
                modifiedLocalConfigs: modified,
                steamWasRunning: wasRunning,
                steamRestarted: restarted
            )
        } catch {
            LauncherLog.logger.error(
                "Steam Launch Options update failed: \(error.localizedDescription)",
                metadata: ["app_id": "\(appID)"]
            )
            if wasRunning && restartSteamIfRunning && !restarted {
                LauncherLog.logger.warning(
                    "Launch Options update failed after Steam was stopped; attempting to reopen Steam",
                    metadata: ["app_id": "\(appID)"]
                )
                try? processController.restartAndWait()
            }
            throw error
        }
    }
}
