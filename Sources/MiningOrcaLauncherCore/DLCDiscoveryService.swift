import Foundation

protocol AppInfoProviding {
    func localDLCs(appID: UInt32, appInfoURL: URL?) throws -> LocalDLCList
    func ownership(appIDs: [UInt32]) throws -> DLCOwnershipSnapshot
}

extension SteamHelperClient: AppInfoProviding {}

struct DLCDiscoveryService {
    private let appInfo: any AppInfoProviding
    private let store: any SteamStoreProviding
    private let cache: StoreDLCCache
    private let settings: LauncherSettings
    private let now: () -> TimeInterval

    init(
        appInfo: any AppInfoProviding,
        store: any SteamStoreProviding,
        settings: LauncherSettings,
        cacheDirectory: URL,
        fileSystem: FileSystem = .default,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.appInfo = appInfo
        self.store = store
        self.settings = settings
        self.cache = StoreDLCCache(directory: cacheDirectory, fileSystem: fileSystem)
        self.now = now
    }

    func discover(
        appID: UInt32,
        appInfoURL: URL? = nil,
        configuredDLCs: [DLCInfo] = [],
        forceStoreRefresh: Bool = false
    ) async -> DLCDiscoveryResult {
        let local: [LocalDLC]
        do {
            local = try appInfo.localDLCs(appID: appID, appInfoURL: appInfoURL).dlcs
        } catch {
            local = []
            LauncherLog.logger.warning(
                "AppInfo unavailable: \(error.localizedDescription)",
                metadata: ["app_id": "\(appID)"]
            )
        }

        let timestamp = now()
        let cached = cache.load(appID: appID)
        let storeDLCs: [DLCInfo]
        let cacheStatus: StoreCacheStatus

        if !forceStoreRefresh,
           let cached,
           cache.isFresh(cached, now: timestamp, ttl: settings.store.cacheTTLSeconds) {
            storeDLCs = cached.dlcs
            cacheStatus = .hit
        } else {
            do {
                let fetched = try await store.dlcs(for: appID)
                storeDLCs = fetched
                cacheStatus = .refreshed
                do {
                    try cache.save(appID: appID, dlcs: fetched, now: timestamp)
                } catch {
                    LauncherLog.logger.warning(
                        "Could not save Steam Store cache: \(error.localizedDescription)",
                        metadata: ["app_id": "\(appID)"]
                    )
                }
            } catch {
                if let cached {
                    storeDLCs = cached.dlcs
                    cacheStatus = .staleFallback
                    LauncherLog.logger.warning(
                        "Steam Store unavailable; using stale cache: \(error.localizedDescription)",
                        metadata: ["app_id": "\(appID)"]
                    )
                } else {
                    storeDLCs = []
                    cacheStatus = .unavailable
                    LauncherLog.logger.warning(
                        "Steam Store unavailable: \(error.localizedDescription)",
                        metadata: ["app_id": "\(appID)"]
                    )
                }
            }
        }

        var ids = Set<UInt32>()
        var localNames: [UInt32: String] = [:]
        var storeNames: [UInt32: String] = [:]
        var storeFreeByAppID: [UInt32: Bool] = [:]
        var configNames: [UInt32: String] = [:]

        for dlc in local {
            ids.insert(dlc.appID)
            if let name = dlc.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                localNames[dlc.appID] = name
            }
        }

        for dlc in storeDLCs {
            ids.insert(dlc.appID)
            if let name = dlc.name {
                storeNames[dlc.appID] = name
            }
            if let isFree = dlc.isFree {
                storeFreeByAppID[dlc.appID] = isFree
            }
        }

        for dlc in configuredDLCs {
            ids.insert(dlc.appID)
            if let name = dlc.name {
                configNames[dlc.appID] = name
            }
        }

        let merged = ids.map { id in
            DLCInfo(
                appID: id,
                name: storeNames[id] ?? localNames[id] ?? configNames[id],
                isFree: storeFreeByAppID[id]
            )
        }.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame ? $0.appID < $1.appID : comparison == .orderedAscending
        }

        let ownershipSnapshot: DLCOwnershipSnapshot
        do {
            ownershipSnapshot = try appInfo.ownership(appIDs: merged.map(\.appID))
        } catch {
            ownershipSnapshot = DLCOwnershipSnapshot(
                accountSelected: false,
                licenseCount: 0,
                packageMetadataComplete: false,
                missingPackageMetadataCount: 0,
                apps: merged.map { DLCAppOwnership(appID: $0.appID, status: .unknown) }
            )
            LauncherLog.logger.warning(
                "Steam ownership cache unavailable: \(error.localizedDescription)",
                metadata: ["app_id": "\(appID)"]
            )
        }

        return DLCDiscoveryResult(
            appID: appID,
            dlcs: merged,
            appInfoCount: local.count,
            storeCount: storeDLCs.count,
            configCount: configuredDLCs.count,
            storeCacheStatus: cacheStatus,
            ownershipByAppID: ownershipSnapshot.byAppID,
            ownershipAccountSelected: ownershipSnapshot.accountSelected,
            ownershipPackageMetadataComplete: ownershipSnapshot.packageMetadataComplete
        )
    }
}
