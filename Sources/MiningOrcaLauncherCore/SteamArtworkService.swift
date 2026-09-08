import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package struct SteamLibrary: Sendable {
    package let steamRootURL: URL
    package let games: [SteamGame]

    init(steamRootURL: URL, games: [SteamGame]) {
        self.steamRootURL = steamRootURL
        self.games = games
    }
}

package struct SteamArtwork: Equatable, Sendable {
    package let portraitURL: URL?
    package let heroURL: URL?
    package let headerURL: URL?
    package let iconURL: URL?

    init(
        portraitURL: URL? = nil,
        heroURL: URL? = nil,
        headerURL: URL? = nil,
        iconURL: URL? = nil
    ) {
        self.portraitURL = portraitURL
        self.heroURL = heroURL
        self.headerURL = headerURL
        self.iconURL = iconURL
    }

    package var isEmpty: Bool {
        portraitURL == nil && heroURL == nil && headerURL == nil && iconURL == nil
    }
}

actor SteamArtworkService {
    private enum Kind {
        case portrait
        case hero
        case header
        case icon

        var localFileNames: [String] {
            switch self {
            case .portrait:
                return ["library_600x900_2x.jpg", "library_600x900.jpg", "library_capsule.jpg"]
            case .hero:
                return ["library_hero.jpg"]
            case .header:
                return ["library_header.jpg", "header.jpg"]
            case .icon:
                return ["icon.jpg", "icon.png"]
            }
        }

        var cdnFileNames: [String] {
            switch self {
            case .portrait:
                return ["library_600x900_2x.jpg", "library_600x900.jpg"]
            case .hero:
                return ["library_hero.jpg"]
            case .header:
                return ["header.jpg"]
            case .icon:
                // Steam's store CDN does not expose a stable unhashed icon URL for
                // every title. Keep icon resolution local and let the UI fall back
                // to the portrait/header artwork when it is absent.
                return []
            }
        }

        var cacheFileName: String {
            switch self {
            case .portrait: return "portrait.jpg"
            case .hero: return "hero.jpg"
            case .header: return "header.jpg"
            case .icon: return "icon.jpg"
            }
        }
    }

    private let steamRootURL: URL
    private let launcherCacheDirectory: URL
    private let requestTimeout: TimeInterval
    private let userAgent: String
    private let fileSystem: FileSystem
    private let session: URLSession

    init(
        steamRootURL: URL,
        launcherCacheDirectory: URL,
        requestTimeout: TimeInterval,
        userAgent: String,
        session: URLSession = .shared,
        fileSystem: FileSystem = .default
    ) {
        self.steamRootURL = steamRootURL.standardizedFileURL
        self.launcherCacheDirectory = launcherCacheDirectory.standardizedFileURL
        self.requestTimeout = requestTimeout
        self.userAgent = userAgent
        self.session = session
        self.fileSystem = fileSystem
    }

    func cachedArtwork(for appID: UInt32) -> SteamArtwork {
        artwork(for: appID)
    }

    func cachedArtwork(for appIDs: [UInt32]) -> [UInt32: SteamArtwork] {
        var result: [UInt32: SteamArtwork] = [:]
        result.reserveCapacity(appIDs.count)
        for appID in appIDs {
            let artwork = artwork(for: appID)
            if !artwork.isEmpty {
                result[appID] = artwork
            }
        }
        return result
    }

    func resolvedArtwork(for appID: UInt32) async -> SteamArtwork {
        let local = artwork(for: appID)

        async let portraitURL = resolveMissing(local.portraitURL, kind: .portrait, appID: appID)
        async let headerURL = resolveMissing(local.headerURL, kind: .header, appID: appID)

        let resolved = await (portraitURL, headerURL)
        return SteamArtwork(
            portraitURL: resolved.0,
            // Hero artwork is local-cache-only for now. The application banner is
            // reserved for Mining Orca artwork rather than a per-game Steam hero.
            heroURL: local.heroURL,
            headerURL: resolved.1,
            iconURL: local.iconURL
        )
    }

    private func resolveMissing(_ existing: URL?, kind: Kind, appID: UInt32) async -> URL? {
        if let existing {
            return existing
        }
        return await download(kind: kind, appID: appID)
    }

    private func artwork(for appID: UInt32) -> SteamArtwork {
        SteamArtwork(
            portraitURL: localURL(kind: .portrait, appID: appID),
            heroURL: localURL(kind: .hero, appID: appID),
            headerURL: localURL(kind: .header, appID: appID),
            iconURL: localURL(kind: .icon, appID: appID)
        )
    }

    private func localURL(kind: Kind, appID: UInt32) -> URL? {
        let libraryCache = steamRootURL
            .appendingPathComponent("appcache", isDirectory: true)
            .appendingPathComponent("librarycache", isDirectory: true)
        let appDirectory = libraryCache.appendingPathComponent(String(appID), isDirectory: true)

        // Current flat-in-AppID layout.
        for fileName in kind.localFileNames {
            let candidate = appDirectory.appendingPathComponent(fileName, isDirectory: false)
            if isReadableRegularFile(candidate) {
                return candidate
            }
        }

        // Newer Steam builds also store assets below one or more content-hash
        // directories. Do not assume the hash value or a single child directory.
        if let children = try? fileSystem.contentsOfDirectory(
            at: appDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? fileSystem.resourceValues(for: child, keys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                for fileName in kind.localFileNames {
                    let candidate = child.appendingPathComponent(fileName, isDirectory: false)
                    if isReadableRegularFile(candidate) {
                        return candidate
                    }
                }
            }
        }

        // Legacy Steam layout: librarycache/<appid>_<asset>.
        for fileName in kind.localFileNames {
            let candidate = libraryCache.appendingPathComponent(
                "\(appID)_\(fileName)",
                isDirectory: false
            )
            if isReadableRegularFile(candidate) {
                return candidate
            }
        }

        // Launcher-owned CDN cache is deliberately last: if Steam later fills or
        // refreshes its own cache, the client-owned artwork immediately wins.
        let cached = launcherCacheURL(kind: kind, appID: appID)
        if isReadableRegularFile(cached) {
            return cached
        }

        return nil
    }

    private func download(kind: Kind, appID: UInt32) async -> URL? {
        if let existing = localURL(kind: kind, appID: appID) {
            return existing
        }

        for fileName in kind.cdnFileNames {
            guard let source = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/\(fileName)") else {
                continue
            }

            var request = URLRequest(url: source)
            request.timeoutInterval = requestTimeout
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/*", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      data.count >= 128 else {
                    continue
                }
                if let mimeType = http.mimeType,
                   !mimeType.lowercased().hasPrefix("image/") {
                    continue
                }

                let destination = launcherCacheURL(kind: kind, appID: appID)
                try fileSystem.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileSystem.writeData(data, to: destination, options: .atomic)
                return destination
            } catch {
                continue
            }
        }

        return nil
    }

    private func launcherCacheURL(kind: Kind, appID: UInt32) -> URL {
        launcherCacheDirectory
            .appendingPathComponent(String(appID), isDirectory: true)
            .appendingPathComponent(kind.cacheFileName, isDirectory: false)
    }

    private func isReadableRegularFile(_ url: URL) -> Bool {
        guard fileSystem.isReadableFile(atPath: url.path) else { return false }
        let values = try? fileSystem.resourceValues(for: url, keys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
    }
}
