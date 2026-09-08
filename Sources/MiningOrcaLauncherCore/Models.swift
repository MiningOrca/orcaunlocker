import Foundation

package enum SteamTransport: String, Codable, CaseIterable, Hashable, Sendable {
    case proxy
    case inject

    var installationKind: InstallationKind {
        switch self {
        case .proxy:
            return .proxy
        case .inject:
            return .inject
        }
    }
}

package struct SteamGame: Codable, Identifiable, Hashable, Sendable {
    package let appID: UInt32
    package let name: String
    package let installDirectory: URL

    package var id: UInt32 { appID }

    init(appID: UInt32, name: String, installDirectory: URL) {
        self.appID = appID
        self.name = name
        self.installDirectory = installDirectory
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case name
        case installDirectory = "install_dir"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appID = try container.decode(UInt32.self, forKey: .appID)
        name = try container.decode(String.self, forKey: .name)

        // The helper emits a POSIX path, not a URL string. Foundation's
        // synthesized URL decoder treats "/Users/..." as a relative URL with
        // no file:// scheme, which then breaks FileManager/String(contentsOf:).
        let path = try container.decode(String.self, forKey: .installDirectory)
        installDirectory = URL(fileURLWithPath: path, isDirectory: true)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appID, forKey: .appID)
        try container.encode(name, forKey: .name)
        try container.encode(installDirectory.path, forKey: .installDirectory)
    }
}

struct SteamAPITarget: Hashable, Sendable {
    let url: URL
    let gameDirectory: URL

    init(url: URL, gameDirectory: URL) {
        self.url = url
        self.gameDirectory = gameDirectory
    }

    var relativePath: String {
        let gamePath = gameDirectory.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath.hasPrefix(gamePath + "/") else { return targetPath }
        return String(targetPath.dropFirst(gamePath.count + 1))
    }

    var isInsideAppBundle: Bool {
        url.standardizedFileURL.pathComponents.contains { component in
            component.lowercased().hasSuffix(".app")
        }
    }

    var recommendedTransport: SteamTransport {
        isInsideAppBundle ? .inject : .proxy
    }
}


struct LocalDLC: Codable, Identifiable, Hashable, Sendable {
    let appID: UInt32
    let name: String?

    var id: UInt32 { appID }

    init(appID: UInt32, name: String?) {
        self.appID = appID
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case name
    }
}

struct LocalDLCList: Codable, Hashable, Sendable {
    let appID: UInt32
    let dlcs: [LocalDLC]

    init(appID: UInt32, dlcs: [LocalDLC]) {
        self.appID = appID
        self.dlcs = dlcs
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case dlcs
    }
}

struct SteamLaunchOptionsAccount: Codable, Hashable, Sendable {
    let localConfigURL: URL
    let launchOptions: String

    init(localConfigURL: URL, launchOptions: String) {
        self.localConfigURL = localConfigURL
        self.launchOptions = launchOptions
    }

    enum CodingKeys: String, CodingKey {
        case localConfigURL = "localconfig"
        case launchOptions = "launch_options"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .localConfigURL)
        localConfigURL = URL(fileURLWithPath: path, isDirectory: false)
        launchOptions = try container.decode(String.self, forKey: .launchOptions)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localConfigURL.path, forKey: .localConfigURL)
        try container.encode(launchOptions, forKey: .launchOptions)
    }
}

struct SteamLaunchOptionsSnapshot: Codable, Hashable, Sendable {
    let appID: UInt32
    let accounts: [SteamLaunchOptionsAccount]

    init(appID: UInt32, accounts: [SteamLaunchOptionsAccount]) {
        self.appID = appID
        self.accounts = accounts
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case accounts
    }
}
