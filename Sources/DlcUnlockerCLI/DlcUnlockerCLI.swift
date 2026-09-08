import ArgumentParser
import Foundation
import MiningOrcaLauncherCore

@main
struct DlcUnlockerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orcaunlocker",
        abstract: "Manage MiningOrca dlc unlocker runtime installations.",
        subcommands: [
            Games.self,
            State.self,
            Apply.self,
            Restore.self,
            Diagnostics.self,
            Profile.self,
            DLCs.self,
            Runtime.self,
        ]
    )
}

private enum CLITransport: String, ExpressibleByArgument, CaseIterable {
    case proxy
    case inject

    var core: SteamTransport { SteamTransport(rawValue: rawValue)! }
}

private enum CLIProfile: String, ExpressibleByArgument, CaseIterable {
    case production
    case debug

    var core: RuntimeProfile { RuntimeProfile(rawValue: rawValue)! }
}

private enum CLILowViolence: String, ExpressibleByArgument, CaseIterable {
    case valve
    case enabled = "true"
    case disabled = "false"

    var core: Bool? {
        switch self {
        case .valve: nil
        case .enabled: true
        case .disabled: false
        }
    }
}

private struct GameOptions: ParsableArguments {
    @Argument(help: "Steam AppID.")
    var appID: UInt32
}

private struct RuntimeOptions: ParsableArguments {
    @Option(help: "Runtime directory containing manifest.json and the four runtime artifacts.")
    var runtime: String?
}

private struct CLIContext {
    let launcher: LauncherCore

    static func load() throws -> CLIContext {
        LauncherLogging.bootstrap(includeStandardError: true)
        return CLIContext(launcher: try LauncherCore.load())
    }

    func game(appID: UInt32) throws -> SteamGame {
        guard let game = try launcher.installedGames().first(where: { $0.appID == appID }) else {
            throw ValidationError("Steam game \(appID) is not installed.")
        }
        return game
    }

    func runtimeDirectory(_ requested: String?) -> URL? {
        guard let requested else { return nil }
        let expanded = NSString(string: requested).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
}

private struct Games: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List installed Steam games.")

    mutating func run() throws {
        let context = try CLIContext.load()
        for game in try context.launcher.installedGames() {
            print("\(game.appID)\t\(game.name)\t\(game.installDirectory.path)")
        }
    }
}

private struct State: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect MiningOrca installation state for a game.")

    @OptionGroup var game: GameOptions
    @OptionGroup var runtime: RuntimeOptions

    mutating func run() throws {
        let context = try CLIContext.load()
        let installedGame = try context.game(appID: game.appID)
        let state = try context.launcher.inspect(
            game: installedGame,
            runtimeDirectory: context.runtimeDirectory(runtime.runtime)
        )
        printState(state, game: installedGame)
    }
}

private struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Apply runtime transport/profile and DLC policy to a game.")

    @OptionGroup var game: GameOptions
    @OptionGroup var runtime: RuntimeOptions

    @Option(help: "Runtime transport: proxy or inject.")
    var transport: CLITransport

    @Option(help: "Runtime profile.")
    var profile: CLIProfile = .production

    @Option(help: "DLC selection: all, none, or a comma-separated list of DLC AppIDs.")
    var selection: String

    @Option(name: .customLong("purchase-time"), help: "Purchase time: valve or a non-negative Unix timestamp.")
    var purchaseTime: String = "valve"

    @Option(help: "Language override, or valve.")
    var language: String = "valve"

    @Option(name: .customLong("low-violence"), help: "Low-violence override.")
    var lowViolence: CLILowViolence = .valve

    @Flag(name: .customLong("restart-steam"), help: "Quit Steam before LaunchOptions mutation and reopen it afterwards.")
    var restartSteam = false

    @Flag(help: "Refresh Steam Store DLC data instead of using a fresh cache entry.")
    var refresh = false

    mutating func run() async throws {
        let context = try CLIContext.load()
        let installedGame = try context.game(appID: game.appID)
        let parsedSelection = try parseSelection(selection)
        let parsedPurchaseTime = try parsePurchaseTime(purchaseTime)
        let discovered = try await context.launcher.discoverDLCs(
            game: installedGame,
            forceStoreRefresh: refresh
        )

        let purchaseTimes = purchaseTimeOverrides(selection: parsedSelection, timestamp: parsedPurchaseTime)
        let request = ApplyRequest(
            transport: transport.core,
            profile: profile.core,
            policy: RuntimePolicy(
                selection: parsedSelection,
                globalPurchaseTime: purchaseTimes.global,
                dlcPurchaseTimes: purchaseTimes.perDLC,
                language: language.lowercased() == "valve" ? nil : language,
                lowViolence: lowViolence.core
            ),
            knownDLCs: discovered.dlcs,
            restartSteamIfRunning: restartSteam
        )

        let result = try context.launcher.apply(
            game: installedGame,
            request: request,
            runtimeDirectory: context.runtimeDirectory(runtime.runtime)
        )

        print("Apply complete")
        print("Game: \(installedGame.name) [\(installedGame.appID)]")
        print("Steam API copies: \(result.stateAfter.steamAPICount)")
        print("Transport: \(transport.rawValue)")
        print("Profile: \(profile.rawValue)")
        print("Runtime action: \(result.runtimeAction.rawValue)")
        print("Selection: \(parsedSelection.displayText(totalKnown: discovered.dlcs.count))")
        print("State: \(kindSummary(result.stateAfter))")
        print("Runtime: \(runtimeSummary(result.stateAfter))")
        print("Config: \(result.configURL.path)")
    }
}

private struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restore the original Steam transport state for a game.")

    @OptionGroup var game: GameOptions
    @OptionGroup var runtime: RuntimeOptions

    @Flag(name: .customLong("restart-steam"), help: "Quit and reopen Steam when removing Inject LaunchOptions.")
    var restartSteam = false

    mutating func run() throws {
        let context = try CLIContext.load()
        let installedGame = try context.game(appID: game.appID)
        let result = try context.launcher.restore(
            game: installedGame,
            runtimeDirectory: context.runtimeDirectory(runtime.runtime),
            restartSteamIfRunning: restartSteam
        )

        if result.restored {
            print("Restore complete")
            print("Steam API copies: \(result.stateAfter.steamAPICount)")
            print("State: \(kindSummary(result.stateAfter))")
        } else {
            print("Nothing to restore")
        }
    }
}

private struct Diagnostics: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate a privacy-redacted diagnostic report for a game.")

    @OptionGroup var game: GameOptions
    @OptionGroup var runtime: RuntimeOptions

    @Option(help: "Number of runtime log lines to include.")
    var lines: Int?

    func validate() throws {
        if let lines, lines < 1 {
            throw ValidationError("--lines must be greater than zero.")
        }
    }

    mutating func run() throws {
        let context = try CLIContext.load()
        let installedGame = try context.game(appID: game.appID)
        let report = try context.launcher.diagnostics(
            game: installedGame,
            runtimeDirectory: context.runtimeDirectory(runtime.runtime),
            lineLimit: lines
        )
        print(report.text)
    }
}

private struct Profile: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Switch production/debug profile for a game while preserving current policy.")

    @OptionGroup var game: GameOptions
    @OptionGroup var runtime: RuntimeOptions

    @Argument(help: "Runtime profile.")
    var profile: CLIProfile

    @Flag(name: .customLong("restart-steam"), help: "Quit and reopen Steam if Inject LaunchOptions are rewritten.")
    var restartSteam = false

    mutating func run() throws {
        let context = try CLIContext.load()
        let installedGame = try context.game(appID: game.appID)
        let result = try context.launcher.switchRuntimeProfile(
            game: installedGame,
            profile: profile.core,
            runtimeDirectory: context.runtimeDirectory(runtime.runtime),
            restartSteamIfRunning: restartSteam
        )
        print("Profile: \(profile.rawValue)")
        print("Runtime action: \(result.runtimeAction.rawValue)")
        print("State: \(kindSummary(result.stateAfter))")
    }
}

private struct DLCs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Discover DLC from AppInfo, Steam Store, and existing config.")

    @Argument(help: "Steam AppID.")
    var appID: UInt32

    @Flag(help: "Refresh Steam Store DLC data instead of using a fresh cache entry.")
    var refresh = false

    mutating func run() async throws {
        let context = try CLIContext.load()
        let game = try context.game(appID: appID)
        let result = try await context.launcher.discoverDLCs(
            game: game,
            forceStoreRefresh: refresh
        )

        for dlc in result.dlcs {
            print("\(dlc.appID)\t\(dlc.displayName)")
        }
        print("DLCs: \(result.dlcs.count) (appinfo=\(result.appInfoCount), store=\(result.storeCount), config=\(result.configCount), cache=\(result.storeCacheStatus.rawValue))")
    }
}

private struct Runtime: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Verify the runtime repository and all four artifacts.")

    @Argument(help: "Runtime directory. Uses launcher settings when omitted.")
    var directory: String?

    mutating func run() throws {
        let context = try CLIContext.load()
        let verification = try context.launcher.verifyRuntime(
            directory: context.runtimeDirectory(directory)
        )

        print("Runtime directory: \(verification.directory.path)")
        for result in verification.artifacts {
            print("\(result.artifact.transport.rawValue) / \(result.artifact.profile.rawValue): OK")
        }
        print("RUNTIME OK")
    }
}

private func parseSelection(_ value: String) throws -> DLCSelection {
    switch value.lowercased() {
    case "all":
        return .all
    case "none":
        return .none
    default:
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !tokens.isEmpty else { throw ValidationError("DLC selection is empty.") }
        var ids = Set<UInt32>()
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UInt32(trimmed) else {
                throw ValidationError("Invalid DLC AppID in --selection: \(token)")
            }
            ids.insert(id)
        }
        return .explicit(ids)
    }
}

private func parsePurchaseTime(_ value: String) throws -> Int64? {
    if value.lowercased() == "valve" { return nil }
    guard let timestamp = Int64(value), timestamp >= 0 else {
        throw ValidationError("--purchase-time must be valve or a non-negative Unix timestamp.")
    }
    return timestamp
}

private func purchaseTimeOverrides(
    selection: DLCSelection,
    timestamp: Int64?
) -> (global: RuntimePurchaseTime, perDLC: [UInt32: RuntimePurchaseTime]) {
    switch selection {
    case .all:
        return (timestamp.map(RuntimePurchaseTime.timestamp) ?? .valve, [:])
    case .explicit(let ids):
        guard let timestamp else { return (.valve, [:]) }
        return (.valve, Dictionary(uniqueKeysWithValues: ids.map { ($0, .timestamp(timestamp)) }))
    case .none:
        return (.valve, [:])
    }
}

private func printState(_ state: LauncherGameState, game: SteamGame) {
    print("Game: \(game.name) [\(game.appID)]")
    print("Steam API copies: \(state.steamAPICount)")

    guard !state.states.isEmpty else {
        print("State: no-steam-api")
        return
    }

    print("State: \(kindSummary(state))")
    print("Transport: \(transportSummary(state))")
    print("Runtime: \(runtimeSummary(state))")
    print("Inject Launch Options: \(launchOptionsSummary(state))")

    if !state.issues.isEmpty {
        print("Issues:")
        for issue in state.issues { print("  - \(issue)") }
    }
}

private func kindSummary(_ state: LauncherGameState) -> String {
    let values = Set(state.states.map { $0.kind.rawValue })
    return values.count == 1 ? values.first! : "mixed"
}

private func transportSummary(_ state: LauncherGameState) -> String {
    let values = Set(state.states.map { $0.transport?.rawValue ?? "none" })
    return values.count == 1 ? values.first! : "mixed"
}

private func runtimeSummary(_ state: LauncherGameState) -> String {
    let values = Set(state.states.map { $0.runtimeIdentity.displayText })
    return values.count == 1 ? values.first! : "mixed"
}

private func launchOptionsSummary(_ state: LauncherGameState) -> String {
    let values = state.states.compactMap(\.launchOptionsHookPresent)
    guard !values.isEmpty else { return "unknown" }

    let hooked = state.states.map { $0.launchOptionsHookCount ?? 0 }.max() ?? 0
    let total = state.states.map { $0.localConfigURLs.count }.max() ?? 0
    if values.allSatisfy({ $0 }) {
        return "yes (\(hooked)/\(total) accounts)"
    }
    if values.contains(true) || hooked > 0 {
        return "partial (\(hooked)/\(total) accounts)"
    }
    return "no (0/\(total) accounts)"
}
