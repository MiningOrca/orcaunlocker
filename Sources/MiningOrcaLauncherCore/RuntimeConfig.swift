import Foundation

package enum DLCSelection: Equatable, Sendable {
    case all
    case explicit(Set<UInt32>)
    case none

    var modeName: String {
        switch self {
        case .all: return "all"
        case .explicit: return "explicit"
        case .none: return "none"
        }
    }

    package var selectedAppIDs: Set<UInt32> {
        switch self {
        case .all, .none:
            return []
        case .explicit(let ids):
            return ids
        }
    }

    package func displayText(totalKnown: Int) -> String {
        switch self {
        case .all:
            return "All current and future DLC"
        case .none:
            return "No DLC overrides"
        case .explicit(let ids):
            return "\(ids.count)/\(totalKnown) selected — current DLC only"
        }
    }
}


package enum RuntimePurchaseTime: Equatable, Sendable {
    case valve
    case timestamp(Int64)

    var displayText: String {
        switch self {
        case .valve:
            return "valve"
        case .timestamp(let value):
            return String(value)
        }
    }
}

package struct RuntimePolicy: Equatable, Sendable {
    package let selection: DLCSelection
    package let globalPurchaseTime: RuntimePurchaseTime
    package let dlcPurchaseTimes: [UInt32: RuntimePurchaseTime]
    package let language: String?
    package let lowViolence: Bool?

    package init(
        selection: DLCSelection,
        globalPurchaseTime: RuntimePurchaseTime = .valve,
        dlcPurchaseTimes: [UInt32: RuntimePurchaseTime] = [:],
        language: String? = nil,
        lowViolence: Bool? = nil
    ) {
        self.selection = selection
        self.globalPurchaseTime = globalPurchaseTime
        self.dlcPurchaseTimes = dlcPurchaseTimes
        self.language = language
        self.lowViolence = lowViolence
    }
}

package struct RuntimeConfig: Equatable, Sendable {
    let appID: UInt32
    package let policy: RuntimePolicy
    let configuredDLCNames: [UInt32: String]

    init(
        appID: UInt32,
        policy: RuntimePolicy,
        configuredDLCNames: [UInt32: String] = [:]
    ) {
        self.appID = appID
        self.policy = policy
        self.configuredDLCNames = configuredDLCNames
    }

    var configuredDLCs: [DLCInfo] {
        configuredDLCNames
            .map { DLCInfo(appID: $0.key, name: $0.value) }
            .sorted {
                let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return comparison == .orderedSame ? $0.appID < $1.appID : comparison == .orderedAscending
            }
    }
}

package enum RuntimeConfigCodec {
    static func parse(_ text: String, fallbackAppID: UInt32? = nil) throws -> RuntimeConfig {
        try RuntimeConfigDocument.parse(text, fallbackAppID: fallbackAppID).configuration
    }

    package static func render(_ config: RuntimeConfig) -> String {
        let policy = config.policy
        let globalUnlock = policy.selection == .all ? "true" : "valve"
        let globalPurchase = policy.globalPurchaseTime.displayText
        let language = policy.language?.isEmpty == false ? policy.language! : "valve"
        let lowViolence = policy.lowViolence.map { $0 ? "true" : "false" } ?? "valve"

        var lines = [
            "# Orca Unlocker runtime policy.",
            "#",
            "# All means all current and future DLC.",
            "# Explicit means only the listed DLC, even when every current DLC is listed.",
            "",
            "[runtime]",
            "app_id = \(config.appID)",
            "launcher_selection = \(policy.selection.modeName)",
            "",
            "[global]",
            "subscribed = \(globalUnlock)",
            "installed = \(globalUnlock)",
            "licensed = \(globalUnlock)",
            "language = \(language)",
            "low_violence = \(lowViolence)",
            "purchase_time = \(globalPurchase)",
        ]

        var sectionIDs = Set(policy.dlcPurchaseTimes.keys)
        var explicitlySelected = Set<UInt32>()
        if case .explicit(let selected) = policy.selection {
            explicitlySelected = selected
            sectionIDs.formUnion(selected)
        }

        for appID in sectionIDs.sorted() {
            lines += ["", "[dlc.\(appID)]"]
            if let name = config.configuredDLCNames[appID] {
                lines.append("name = \(quote(name))")
            }
            if explicitlySelected.contains(appID) {
                lines += [
                    "subscribed = true",
                    "installed = true",
                    "licensed = true",
                ]
            }
            if let purchaseTime = policy.dlcPurchaseTimes[appID] {
                lines.append("purchase_time = \(purchaseTime.displayText)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }


}

struct RuntimeConfigFile {
    private let runtimeSettings: LauncherSettings.Runtime
    private let fileSystem: FileSystem

    init(
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) {
        self.runtimeSettings = runtimeSettings
        self.fileSystem = fileSystem
    }

    func url(for game: SteamGame) -> URL {
        RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings).config
    }

    func read(for game: SteamGame) throws -> RuntimeConfig? {
        try source(for: game).configuration
    }

    func source(for game: SteamGame) throws -> RuntimeConfigSource {
        let configURL = url(for: game)
        guard fileSystem.fileExists(atPath: configURL.path) else {
            let generated = RuntimeConfig(
                appID: game.appID,
                policy: RuntimePolicy(selection: .all)
            )
            return RuntimeConfigSource(
                url: configURL,
                text: RuntimeConfigCodec.render(generated),
                configuration: nil,
                fileExists: false
            )
        }

        try RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings).requireSafeRuntimePath(configURL, fileSystem: fileSystem)
        let text = try fileSystem.readString(from: configURL)
        do {
            let document = try RuntimeConfigDocument.parse(
                text,
                fallbackAppID: game.appID,
                expectedAppID: game.appID
            )
            return RuntimeConfigSource(
                url: configURL,
                text: text,
                configuration: document.configuration,
                fileExists: true
            )
        } catch let validationError as RuntimeConfigValidationError {
            // A malformed file must remain editable from the Advanced tab. Do not
            // fail the whole game-detail load just because the config needs repair.
            return RuntimeConfigSource(
                url: configURL,
                text: text,
                configuration: nil,
                fileExists: true,
                validationError: validationError
            )
        }
    }

    @discardableResult
    func writeRawText(_ text: String, for game: SteamGame) throws -> RuntimeConfigSource {
        let document = try RuntimeConfigDocument.parse(
            text,
            expectedAppID: game.appID,
            requireExplicitAppID: true
        )
        let configURL = url(for: game)
        try RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings).requireSafeRuntimePath(configURL, fileSystem: fileSystem)
        try writeValidatedText(text, to: configURL)
        return RuntimeConfigSource(
            url: configURL,
            text: text,
            configuration: document.configuration,
            fileExists: true
        )
    }

    func write(_ config: RuntimeConfig, for game: SteamGame) throws {
        let configURL = url(for: game)
        try RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings).requireSafeRuntimePath(configURL, fileSystem: fileSystem)

        let text: String
        if fileSystem.fileExists(atPath: configURL.path) {
            let existingText = try fileSystem.readString(from: configURL)
            let existing = try RuntimeConfigDocument.parse(
                existingText,
                fallbackAppID: game.appID,
                expectedAppID: game.appID
            )
            text = try existing.mergingKnownFields(from: config)
        } else {
            text = RuntimeConfigCodec.render(config)
        }

        // Validate the final merged document before touching the on-disk file.
        _ = try RuntimeConfigDocument.parse(
            text,
            expectedAppID: game.appID,
            requireExplicitAppID: true
        )
        try writeValidatedText(text, to: configURL)
    }

    private func writeValidatedText(_ text: String, to url: URL) throws {
        try PathSafety.requireNotSymbolicLink(url, fileSystem: fileSystem)
        try fileSystem.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileSystem.writeString(text, to: url, atomically: true)
    }

}
