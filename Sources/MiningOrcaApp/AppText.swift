import MiningOrcaLauncherCore

enum AppText {
    enum Common {
        static let appName = "Orca Unlocker"
        static let ok = "OK"
        static let open = "Open"
        static let proxy = "Proxy"
        static let inject = "Inject"
        static let none = "None"
        static let mixed = "Mixed"
        static let valveBehavior = "Valve behavior"
        static let valveDefault = "Valve (default)"
        static let on = "On"
        static let off = "Off"
        static let datePlaceholder = "dd.MM.yyyy"

        static func transportName(_ transport: SteamTransport) -> String {
            switch transport {
            case .proxy: return proxy
            case .inject: return inject
            }
        }
    }

    enum GameDetail {
        static let installedGames = "Installed Games"
        static let searchGames = "Search games"
        static let loadingGameState = "Loading game state…"
        static let gameStateUnavailable = "Game State Unavailable"
        static let gameStateUnavailableMessage = "The selected game's state could not be loaded."
        static let selectSteamGame = "Select a Steam Game"
        static let selectSteamGameMessage = "Choose an installed game from the sidebar."

        static let overviewTab = "Overview"
        static let dlcsTab = "DLCs"
        static let advancedTab = "Advanced"
        static let diagnosticsTab = "Diagnostics"

        static let steamRunning = "Steam is running"
        static let steamRunningCancel = "I'm not ready for this"
        static let steamRunningContinue = "Continue"
        static let steamRunningMessage = "This operation needs to modify Steam's localconfig.vdf. Continue lets MiningOrca restart Steam automatically and continue."
        static let openInSteam = "Open in Steam"

        static let restoreOriginal = "Restore Original"
        static let restoreOriginalHelp = "Restore the original Steam transport state for this game."
        static let applyChanges = "Apply Changes"
        static let applyChangesHelp = "Apply the selected runtime and DLC configuration to this game."

        static let installationState = "Installation State"
        static let status = "Status"
        static let transport = "Transport"
        static let runtime = "Runtime"
        static let lowViolence = "Low Violence"
        static let purchaseTime = "Purchase Time"
        static let dlcPolicy = "DLC Policy"
        static let noSteamAPITarget = "No Steam API target"
        static let broken = "Broken"
        static let original = "Original"
        static let installed = "Installed"
        static let otherOlderRuntime = "Other/older runtime"

        static let dlcsTitle = "DLCs"
        static let openDLCFilesFolder = "Open DLC files folder"
        static let bundledDLCFiles = "Lucky you — DLC files are already in the game"
        static let bundledDLCFilesHelp = "DLC content is stored in the base game's files; there is no separate DLC folder."
        static let searchDLCs = "Search DLCs"
        static let filesPresent = "Files present"
        static let filesProbablyMissing = "Probably missing files"
        static let filesUnknown = "Files unknown"
        static let selected = "Selected"
        static let notSelected = "Not selected"
        static let selectDLC = "Select DLC"
        static let deselectDLC = "Deselect DLC"
        static let freeDLCStoreTitle = "Gabe's bounty"
        static let ownedDLCStoreTitle = "Gabe approves"
        static let buyDLCStoreTitle = "Appease Gabe"
        static let unknownOwnershipStoreTitle = "Augurs unsure"
        static let freeDLCStoreHelp = "This DLC is free on the Steam Store."
        static let buyDLCStoreHelp = "Make Gabe a little richer"
        static let ownershipOwnedHelp = "The selected Steam account's local license cache includes this DLC."
        static let ownershipNotOwnedHelp = "The selected Steam account's local license cache does not currently include this DLC."
        static let ownershipUnknownHelp = "Ownership could not be determined safely from the local Steam license cache."

        static let recentOperationLog = "Recent Operation Log"
        static let clearOperationLog = "Clear"
        static let noOperationLogEntries = "No log entries yet."

        static let checkingSteam = "Checking Steam…"
        static let waitingForSteamChoice = "Waiting for Steam choice…"
        static let applyingChanges = "Applying changes…"
        static let restoringOriginal = "Restoring original…"
        static let preparingDebugSession = "Preparing debug session…"
        static let debugSessionRunning = "Debug session running…"
        static let capturingDebugArtifacts = "Capturing debug artifacts…"
        static let restoringCleanState = "Restoring clean state…"
        static let steamRepairRequired = "Steam repair required"
        static let restoreRequired = "Restore required"
        static let pendingChanges = "Pending changes"
        static let runtimeInstallationRequired = "Runtime installation required"
        static let noPendingChanges = "No pending changes"

        static func appID(_ appID: UInt32) -> String {
            "AppID: \(appID)"
        }

        static func tabTitle(_ tab: GameDetailTab, dlcCount: Int) -> String {
            switch tab {
            case .overview: return overviewTab
            case .dlcs: return "\(dlcsTab) (\(dlcCount))"
            case .advanced: return advancedTab
            case .diagnostics: return diagnosticsTab
            }
        }

        static func dlcListSummary(
            detectedCount: Int,
            policy: DLCPolicyDraft,
            selectedCount: Int
        ) -> String {
            let selection: String
            switch policy {
            case .all:
                selection = "all current and future DLCs"
            case .none:
                selection = Common.valveBehavior
            case .explicit:
                selection = "\(selectedCount) selected"
            }
            return "\(detectedCount) detected · \(selection)"
        }

        static func runtimeIdentity(_ identity: InstalledRuntimeIdentity) -> String {
            switch identity {
            case .none: return Common.none
            case .current(let profile): return profile.rawValue.capitalized
            case .other: return otherOlderRuntime
            }
        }

        static func dlcFallbackName(_ appID: UInt32) -> String {
            "DLC \(appID)"
        }
    }

    enum Configuration {
        static let configuration = "Configuration"
        static let transport = "Transport"
        static let transportHelp = "Proxy replaces the game's Steam API library. Inject loads the runtime through Steam Launch Options."
        static let lowViolence = "Low Violence"
        static let lowViolenceHelp = "Valve uses the game's normal Steam behavior. On or Off overrides it."
        static let purchaseTime = "Purchase Time"
        static let purchaseTimeHelp = "Leave empty to use Valve's purchase time, or enter a date as dd.MM.yyyy. It will be converted to a Steam timestamp when changes are applied."

        static let dlcConfiguration = "DLC Configuration"
        static let policy = "Policy"
        static let policyHelp = "All unlocks current and future DLC. None uses Valve behavior. Explicit unlocks only selected DLC IDs."
        static let configureDLCs = "Configure DLCs…"
        static let policyAll = "All"
        static let policyNone = "None"
        static let policyExplicit = "Explicit"
        static let allDLCsDescription = "All current and future DLCs will be unlocked."
        static let noDLCOverridesDescription = "DLC entitlement checks use normal Valve behavior."

        static let purchaseDate = "Purchase date"
        static let purchaseTimeUseGlobal = "Use global"
        static let purchaseTimeValve = "Valve"
        static let purchaseTimeCustomDate = "Custom date"
        static let purchaseDateHelp = "Use global inherits the Purchase Time from Overview. Valve explicitly uses Steam behavior for this DLC. Custom date stores a per-DLC purchase_time override."

        static let advancedConfiguration = "Advanced Configuration"
        static let unsavedChanges = "Unsaved changes"
        static let saved = "Saved"
        static let advancedConfigurationHelp = "Save validates syntax and known runtime values before the file is touched. Unknown keys and comments are preserved by normal Apply operations."
        static let resetToGenerated = "Reset to Generated"
        static let saving = "Saving…"
        static let save = "Save"
        static let rawConfiguration = "Raw orcaunlocker.conf"

        static func detectedDLCs(_ count: Int) -> String {
            "\(count) DLCs detected"
        }

        static func selectedDLCs(_ selectedCount: Int, totalCount: Int) -> String {
            "\(selectedCount) of \(totalCount) DLCs selected."
        }

        static func selectionSummary(_ selection: DLCSelection, totalKnown: Int) -> String {
            switch selection {
            case .all:
                return "All current and future DLC"
            case .none:
                return "No DLC overrides"
            case .explicit(let ids):
                return "\(ids.count)/\(totalKnown) selected — current DLC only"
            }
        }

        static func purchaseDateField(dlcName: String, appID: UInt32) -> String {
            "purchase date for \(dlcName) [\(appID)]"
        }
    }

    enum Diagnostics {
        static let debugTransport = "Debug transport"
        static let debugTransportHelp = "Transport used only for this debug session."
        static let checkNow = "Check Now"
        static let checkNowHelp = "Refresh installation state without rediscovering DLCs."
        static let stopDebug = "Stop Debug"
        static let runDebug = "Run Debug"
        static let waitingForSteamRepair = "Waiting for Steam to restore the game files. MiningOrca checks the selected game's installation state automatically every 10 seconds."
        static let copyReportPath = "Copy report path"
        static let showReportInFinder = "Show report archive in Finder"
        static let copyFullPath = "Copy full path"
        static let openInFinder = "Open in Finder"
        static let folderDoesNotExist = "Folder does not exist yet"
        static let runtimeLog = "Runtime Log"
        static let logTail = "tail"
        static let report = "Report"
        static let emptyRuntimeLog = "orcaunlocker.log is empty or has not been created yet."

        static func steamAPIFolderHelp(copyCount: Int) -> String {
            if copyCount > 1 {
                return "Primary libsteam_api.dylib folder. \(copyCount) Steam API copies were discovered for this game."
            }
            return "Folder containing libsteam_api.dylib."
        }

        static func unableToReadRuntimeLog(_ error: String) -> String {
            "Unable to read orcaunlocker.log: \(error)"
        }

        static let gameExited = "Game process exited"
        static let logInactive = "No runtime log activity for 10 minutes"
        static let stoppedByUser = "Stopped by user"
        static let sessionFailedBeforeRuntimeCompleted = "Session failed before runtime completed"
        static let cleanStateRestored = "clean state restored"

        static func preparingRuntime(_ transport: SteamTransport) -> String {
            "Preparing \(transport.rawValue) debug runtime…"
        }

        static func sessionRunning(_ transport: SteamTransport) -> String {
            "Debug session running · \(transport.rawValue)"
        }

        static func result(_ endReason: String, suffix: String) -> String {
            "\(endReason) · \(suffix)"
        }
    }

    enum Errors {
        static let quitGameBeforeDebug = "Quit the game before starting a debug session."
        static let debugPrecleanFailed = "MiningOrca could not reach a clean installation state before the debug session."
        static let debugCleanupFailed = "MiningOrca could not verify a clean installation state after the debug session."

        static func invalidPurchaseDate(field: String, value: String) -> String {
            "Invalid \(field) '\(value)'. Use dd.MM.yyyy, for example 05.09.2026."
        }

        static func diagnosticReportSuffix(path: String) -> String {
            " Diagnostic report: \(path)."
        }

        static func debugSessionFailed(_ description: String, captureSuffix: String) -> String {
            "Debug session failed: \(description).\(captureSuffix)"
        }

        static func debugSessionFailed(
            _ description: String,
            cleanupFailure: String,
            captureSuffix: String
        ) -> String {
            "Debug session failed: \(description) Cleanup also failed: \(cleanupFailure).\(captureSuffix)"
        }
    }
}
