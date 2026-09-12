import Foundation

struct LauncherSettings: Codable, Equatable, Sendable {
    struct Store: Codable, Equatable, Sendable {
        var appDetailsURL: URL
        var language: String
        var cacheTTLSeconds: TimeInterval
        var requestTimeoutSeconds: TimeInterval
        var maxConcurrentRequests: Int
        var userAgent: String
    }

    struct Cache: Codable, Equatable, Sendable {
        var directoryName: String
        var artworkDirectoryName: String
    }

    struct Helper: Codable, Equatable, Sendable {
        var executablePath: String?
    }

    struct Runtime: Codable, Equatable, Sendable {
        var developmentDirectory: String?
        var bundledDirectoryName: String
        var installDirectoryName: String
        var configFileName: String
        var logFileName: String
    }

    struct Steam: Codable, Equatable, Sendable {
        var restartTimeoutSeconds: TimeInterval
        var restartPollIntervalSeconds: TimeInterval
    }

    struct Diagnostics: Codable, Equatable, Sendable {
        var logTailLines: Int
        var maxLogBytes: Int
    }

    var store: Store
    var cache: Cache
    var helper: Helper
    var runtime: Runtime
    var steam: Steam
    var diagnostics: Diagnostics
}

struct LoadedLauncherSettings: Equatable {
    let settings: LauncherSettings
    let overrideURL: URL
    let overrideWasLoaded: Bool

    init(settings: LauncherSettings, overrideURL: URL, overrideWasLoaded: Bool) {
        self.settings = settings
        self.overrideURL = overrideURL
        self.overrideWasLoaded = overrideWasLoaded
    }
}

enum LauncherSettingsError: Error, LocalizedError {
    case bundledDefaultsMissing
    case invalidBundledDefaults(String)
    case invalidOverride(URL, String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .bundledDefaultsMissing:
            return "Bundled launcher default-settings.json is missing."
        case .invalidBundledDefaults(let message):
            return "Bundled launcher settings are invalid: \(message)"
        case .invalidOverride(let url, let message):
            return "Launcher settings override is invalid at \(url.path): \(message)"
        case .invalidValue(let message):
            return "Launcher settings contain an invalid value: \(message)"
        }
    }
}

enum LauncherSettingsLoader {
    private struct Overrides: Decodable {
        struct Store: Decodable {
            var appDetailsURL: URL?
            var language: String?
            var cacheTTLSeconds: TimeInterval?
            var requestTimeoutSeconds: TimeInterval?
            var maxConcurrentRequests: Int?
            var userAgent: String?
        }

        struct Cache: Decodable {
            var directoryName: String?
            var artworkDirectoryName: String?
        }

        struct Helper: Decodable {
            var executablePath: String?
        }

        struct Runtime: Decodable {
            var developmentDirectory: String?
            var bundledDirectoryName: String?
            var installDirectoryName: String?
            var configFileName: String?
            var logFileName: String?
        }

        struct Steam: Decodable {
            var restartTimeoutSeconds: TimeInterval?
            var restartPollIntervalSeconds: TimeInterval?
        }

        struct Diagnostics: Decodable {
            var logTailLines: Int?
            var maxLogBytes: Int?
        }

        var store: Store?
        var cache: Cache?
        var helper: Helper?
        var runtime: Runtime?
        var steam: Steam?
        var diagnostics: Diagnostics?
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileSystem: FileSystem = .default
    ) throws -> LoadedLauncherSettings {
        let defaults = try loadBundledDefaults(fileSystem: fileSystem)
        let overrideURL = try settingsOverrideURL(environment: environment, fileSystem: fileSystem)

        guard fileSystem.fileExists(atPath: overrideURL.path) else {
            try validate(defaults)
            return LoadedLauncherSettings(
                settings: defaults,
                overrideURL: overrideURL,
                overrideWasLoaded: false
            )
        }

        let data: Data
        do {
            data = try fileSystem.readData(from: overrideURL)
        } catch {
            throw LauncherSettingsError.invalidOverride(overrideURL, error.localizedDescription)
        }

        let overrides: Overrides
        do {
            overrides = try JSONDecoder().decode(Overrides.self, from: data)
        } catch {
            throw LauncherSettingsError.invalidOverride(overrideURL, error.localizedDescription)
        }

        let merged = apply(overrides, to: defaults)
        try validate(merged)
        return LoadedLauncherSettings(
            settings: merged,
            overrideURL: overrideURL,
            overrideWasLoaded: true
        )
    }

    static func settingsOverrideURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileSystem: FileSystem = .default
    ) throws -> URL {
        if let explicit = environment["MININGORCA_CONFIG"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit).standardizedFileURL
        }

        let base = try fileSystem.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return base
            .appendingPathComponent("MiningOrca", isDirectory: true)
            .appendingPathComponent("launcher-settings.json", isDirectory: false)
    }

    static func cacheDirectory(
        settings: LauncherSettings,
        fileSystem: FileSystem = .default
    ) throws -> URL {
        let base = try fileSystem.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return settings.cache.directoryName
            .split(separator: "/")
            .reduce(base) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
    }


    static func artworkCacheDirectory(
        settings: LauncherSettings,
        fileSystem: FileSystem = .default
    ) throws -> URL {
        let base = try fileSystem.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return settings.cache.artworkDirectoryName
            .split(separator: "/")
            .reduce(base) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
    }

    private static func loadBundledDefaults(fileSystem: FileSystem) throws -> LauncherSettings {
    guard let url =
        Bundle.main.url(forResource: "default-settings", withExtension: "json")
        ?? Bundle.module.url(forResource: "default-settings", withExtension: "json")
    else {
        throw LauncherSettingsError.bundledDefaultsMissing
    }

    do {
        let settings = try JSONDecoder().decode(
            LauncherSettings.self,
            from: fileSystem.readData(from: url)
        )
        try validate(settings)
        return settings
    } catch let error as LauncherSettingsError {
        throw error
    } catch {
        throw LauncherSettingsError.invalidBundledDefaults(error.localizedDescription)
    }
}

    private static func apply(_ overrides: Overrides, to defaults: LauncherSettings) -> LauncherSettings {
        var settings = defaults

        if let store = overrides.store {
            settings.store.appDetailsURL = store.appDetailsURL ?? settings.store.appDetailsURL
            settings.store.language = store.language ?? settings.store.language
            settings.store.cacheTTLSeconds = store.cacheTTLSeconds ?? settings.store.cacheTTLSeconds
            settings.store.requestTimeoutSeconds = store.requestTimeoutSeconds ?? settings.store.requestTimeoutSeconds
            settings.store.maxConcurrentRequests = store.maxConcurrentRequests ?? settings.store.maxConcurrentRequests
            settings.store.userAgent = store.userAgent ?? settings.store.userAgent
        }

        if let cache = overrides.cache {
            settings.cache.directoryName = cache.directoryName ?? settings.cache.directoryName
            settings.cache.artworkDirectoryName = cache.artworkDirectoryName ?? settings.cache.artworkDirectoryName
        }

        if let helper = overrides.helper {
            settings.helper.executablePath = helper.executablePath
        }

        if let runtime = overrides.runtime {
            settings.runtime.developmentDirectory = runtime.developmentDirectory
            settings.runtime.bundledDirectoryName = runtime.bundledDirectoryName ?? settings.runtime.bundledDirectoryName
            settings.runtime.installDirectoryName = runtime.installDirectoryName ?? settings.runtime.installDirectoryName
            settings.runtime.configFileName = runtime.configFileName ?? settings.runtime.configFileName
            settings.runtime.logFileName = runtime.logFileName ?? settings.runtime.logFileName
        }

        if let steam = overrides.steam {
            settings.steam.restartTimeoutSeconds = steam.restartTimeoutSeconds ?? settings.steam.restartTimeoutSeconds
            settings.steam.restartPollIntervalSeconds = steam.restartPollIntervalSeconds ?? settings.steam.restartPollIntervalSeconds
        }

        if let diagnostics = overrides.diagnostics {
            settings.diagnostics.logTailLines = diagnostics.logTailLines ?? settings.diagnostics.logTailLines
            settings.diagnostics.maxLogBytes = diagnostics.maxLogBytes ?? settings.diagnostics.maxLogBytes
        }

        return settings
    }

    private static func validate(_ settings: LauncherSettings) throws {
        guard let scheme = settings.store.appDetailsURL.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw LauncherSettingsError.invalidValue("store.appDetailsURL must use http or https")
        }
        guard !settings.store.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LauncherSettingsError.invalidValue("store.language must not be empty")
        }
        guard settings.store.cacheTTLSeconds >= 0 else {
            throw LauncherSettingsError.invalidValue("store.cacheTTLSeconds must be >= 0")
        }
        guard settings.store.requestTimeoutSeconds > 0 else {
            throw LauncherSettingsError.invalidValue("store.requestTimeoutSeconds must be > 0")
        }
        guard settings.store.maxConcurrentRequests >= 1 else {
            throw LauncherSettingsError.invalidValue("store.maxConcurrentRequests must be >= 1")
        }
        guard !settings.store.userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LauncherSettingsError.invalidValue("store.userAgent must not be empty")
        }
        guard !settings.cache.directoryName.isEmpty, !settings.cache.directoryName.hasPrefix("/") else {
            throw LauncherSettingsError.invalidValue("cache.directoryName must be a non-empty relative path")
        }
        guard !settings.cache.artworkDirectoryName.isEmpty,
              !settings.cache.artworkDirectoryName.hasPrefix("/") else {
            throw LauncherSettingsError.invalidValue("cache.artworkDirectoryName must be a non-empty relative path")
        }
        guard !settings.runtime.bundledDirectoryName.isEmpty,
              !settings.runtime.bundledDirectoryName.hasPrefix("/") else {
            throw LauncherSettingsError.invalidValue("runtime.bundledDirectoryName must be a non-empty relative path")
        }
        if let developmentDirectory = settings.runtime.developmentDirectory,
           developmentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LauncherSettingsError.invalidValue("runtime.developmentDirectory must be null or non-empty")
        }
        for (key, value) in [
            ("runtime.installDirectoryName", settings.runtime.installDirectoryName),
            ("runtime.configFileName", settings.runtime.configFileName),
            ("runtime.logFileName", settings.runtime.logFileName),
        ] {
            guard isSinglePathComponent(value) else {
                throw LauncherSettingsError.invalidValue("\(key) must be a non-empty single path component")
            }
        }
        guard settings.steam.restartTimeoutSeconds > 0 else {
            throw LauncherSettingsError.invalidValue("steam.restartTimeoutSeconds must be > 0")
        }
        guard settings.steam.restartPollIntervalSeconds > 0 else {
            throw LauncherSettingsError.invalidValue("steam.restartPollIntervalSeconds must be > 0")
        }
        guard settings.diagnostics.logTailLines > 0 else {
            throw LauncherSettingsError.invalidValue("diagnostics.logTailLines must be > 0")
        }
        guard settings.diagnostics.maxLogBytes > 0 else {
            throw LauncherSettingsError.invalidValue("diagnostics.maxLogBytes must be > 0")
        }
    }

    private static func isSinglePathComponent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.contains("/")
            && value != "."
            && value != ".."
    }
}
