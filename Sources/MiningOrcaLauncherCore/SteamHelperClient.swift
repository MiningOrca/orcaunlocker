import Foundation

enum SteamHelperError: Error, LocalizedError, Sendable {
    case helperNotFound([URL])
    case launchFailed(String)
    case commandFailed(Int32, String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .helperNotFound(let candidates):
            return "Steam helper was not found. Checked: " + candidates.map(\.path).joined(separator: ", ")
        case .launchFailed(let message):
            return "Could not launch Steam helper: \(message)"
        case .commandFailed(let status, let message):
            return "Steam helper failed with status \(status): \(message)"
        case .invalidResponse(let message):
            return "Steam helper returned invalid JSON: \(message)"
        }
    }
}

struct SteamHelperClient: Sendable {
    let executableURL: URL
    private let steamRootURL: URL?

    init(executableURL: URL) {
        self.executableURL = executableURL
        self.steamRootURL = nil
    }

    init(executableURL: URL, steamRootURL: URL) {
        self.executableURL = executableURL
        self.steamRootURL = steamRootURL
    }

    static func locateDefault(
        configuredPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileSystem.default.currentDirectoryPath),
        fileSystem: FileSystem = .default
    ) throws -> SteamHelperClient {
        var candidates: [URL] = []

        if let explicit = environment["MININGORCA_STEAM_HELPER"], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }

        if let configuredPath, !configuredPath.isEmpty {
            candidates.append(URL(fileURLWithPath: configuredPath))
        }

        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "miningorca-steam-helper") {
            candidates.append(bundled)
        }

        candidates.append(
            currentDirectory
                .appendingPathComponent("helper")
                .appendingPathComponent("target")
                .appendingPathComponent("release")
                .appendingPathComponent("miningorca-steam-helper")
        )

        if let existing = candidates.first(where: { fileSystem.isExecutableFile(atPath: $0.path) }) {
            return SteamHelperClient(executableURL: existing)
        }

        throw SteamHelperError.helperNotFound(candidates)
    }

    func installedLibrary() throws -> SteamLibrary {
        struct Response: Decodable {
            let steamRoot: String
            let games: [SteamGame]

            enum CodingKeys: String, CodingKey {
                case steamRoot = "steam_root"
                case games
            }
        }

        let response: Response = try run(arguments: ["games"])
        return SteamLibrary(
            steamRootURL: URL(fileURLWithPath: response.steamRoot, isDirectory: true),
            games: response.games.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        )
    }

    func launchOptionsAll(appID: UInt32) throws -> SteamLaunchOptionsSnapshot {
        let arguments = launchOptionsArguments(command: "launch-options-all", appID: appID)
        do {
            return try run(arguments: arguments)
        } catch {
            LauncherLog.logger.warning(
                "Steam Launch Options inspection failed; retrying in 5 seconds: \(error.localizedDescription)",
                metadata: ["app_id": "\(appID)"]
            )
            Thread.sleep(forTimeInterval: 5.0)
            return try run(arguments: arguments)
        }
    }

    func installLaunchOptions(
        appID: UInt32,
        prefixWrapper: URL,
        commandWrapper: URL
    ) throws -> [URL] {
        let arguments = launchOptionsArguments(
            command: "install-launch-options",
            appID: appID,
            positional: [prefixWrapper.path, commandWrapper.path]
        )
        let response: LaunchOptionsMutationResponse = try run(arguments: arguments)
        return try mutationURLs(response, expectedAppID: appID)
    }

    func removeLaunchOptions(
        appID: UInt32,
        prefixWrapper: URL,
        commandWrapper: URL
    ) throws -> [URL] {
        let arguments = launchOptionsArguments(
            command: "remove-launch-options",
            appID: appID,
            positional: [prefixWrapper.path, commandWrapper.path]
        )
        let response: LaunchOptionsMutationResponse = try run(arguments: arguments)
        return try mutationURLs(response, expectedAppID: appID)
    }

    func localDLCs(appID: UInt32, appInfoURL: URL? = nil) throws -> LocalDLCList {
        var arguments = ["appinfo", String(appID)]
        if let appInfoURL {
            arguments += ["--path", appInfoURL.path]
        }
        return try run(arguments: arguments)
    }

    func ownership(appIDs: [UInt32]) throws -> DLCOwnershipSnapshot {
        let ids = Array(Set(appIDs.filter { $0 != 0 })).sorted()
        guard !ids.isEmpty else {
            return DLCOwnershipSnapshot(
                accountSelected: false,
                licenseCount: 0,
                packageMetadataComplete: false,
                missingPackageMetadataCount: 0,
                apps: []
            )
        }

        var arguments = [
            "ownership",
            ids.map(String.init).joined(separator: ","),
        ]
        if let steamRootURL {
            arguments += ["--steam-root", steamRootURL.path]
        }
        return try run(arguments: arguments)
    }

    func contentState(
        baseAppID: UInt32,
        appIDs: [UInt32],
        installDirectory: URL
    ) throws -> DLCContentSnapshot {
        let ids = Array(Set(appIDs.filter { $0 != 0 })).sorted()
        guard !ids.isEmpty else {
            return DLCContentSnapshot(baseAppID: baseAppID, apps: [])
        }

        let steamRoot: URL
        if let steamRootURL {
            steamRoot = steamRootURL
        } else {
            steamRoot = try installedLibrary().steamRootURL
        }

        return try run(arguments: [
            "content-state",
            String(baseAppID),
            ids.map(String.init).joined(separator: ","),
            "--steam-root",
            steamRoot.path,
            "--install-dir",
            installDirectory.path,
        ])
    }

    private func mutationURLs(
        _ response: LaunchOptionsMutationResponse,
        expectedAppID: UInt32
    ) throws -> [URL] {
        guard response.appID == expectedAppID else {
            throw SteamHelperError.invalidResponse(
                "Launch Options response AppID \(response.appID) does not match requested AppID \(expectedAppID)"
            )
        }
        return response.modifiedLocalConfigs.map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    private func launchOptionsArguments(
        command: String,
        appID: UInt32,
        positional: [String] = []
    ) -> [String] {
        var arguments = [command, String(appID)] + positional
        if let steamRootURL {
            arguments += ["--steam-root", steamRootURL.path]
        }
        return arguments
    }

    private func run<Response: Decodable>(arguments: [String]) throws -> Response {
        let execution: ProcessRunnerResult
        do {
            execution = try ProcessRunner.run(
                executableURL: executableURL,
                arguments: arguments
            )
        } catch ProcessRunnerError.launchFailed(let message) {
            throw SteamHelperError.launchFailed(message)
        }

        let outputData = execution.stdout
        let errorText = String(decoding: execution.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard execution.status == 0 else {
            throw SteamHelperError.commandFailed(execution.status, errorText)
        }

        if !errorText.isEmpty {
            LauncherLog.logger.warning(
                "Steam helper wrote to stderr: \(errorText)",
                metadata: ["command": "\(arguments.first ?? "unknown")"]
            )
        }

        do {
            return try JSONDecoder().decode(Response.self, from: outputData)
        } catch {
            let raw = String(decoding: outputData, as: UTF8.self)
            throw SteamHelperError.invalidResponse("\(error.localizedDescription); response=\(raw)")
        }
    }
}

private struct LaunchOptionsMutationResponse: Decodable {
    let appID: UInt32
    let modifiedLocalConfigs: [String]

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case modifiedLocalConfigs = "modified_localconfigs"
    }
}
