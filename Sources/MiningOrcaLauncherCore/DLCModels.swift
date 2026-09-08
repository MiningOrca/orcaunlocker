import Foundation

package struct DLCInfo: Codable, Identifiable, Hashable, Sendable {
    static let unknownDisplayName = "Unknown DLC"
    package let appID: UInt32
    package let name: String?
    package let isFree: Bool?

    package var id: UInt32 { appID }
    package var displayName: String { name ?? Self.unknownDisplayName }

    init(appID: UInt32, name: String?, isFree: Bool? = nil) {
        self.appID = appID
        self.name = Self.normalizedName(name)
        self.isFree = isFree
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appID = try container.decode(UInt32.self, forKey: .appID)
        name = Self.normalizedName(try container.decodeIfPresent(String.self, forKey: .name))
        isFree = try container.decodeIfPresent(Bool.self, forKey: .isFree)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appID, forKey: .appID)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(isFree, forKey: .isFree)
    }

    static func normalizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case name
        case isFree = "is_free"
    }
}

package enum DLCOwnershipStatus: String, Codable, Sendable {
    case owned
    case notOwned = "not_owned"
    case unknown
}

struct DLCAppOwnership: Codable, Hashable, Sendable {
    let appID: UInt32
    let status: DLCOwnershipStatus

    init(appID: UInt32, status: DLCOwnershipStatus) {
        self.appID = appID
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case status
    }
}

struct DLCOwnershipSnapshot: Codable, Sendable {
    let accountSelected: Bool
    let licenseCount: Int
    let packageMetadataComplete: Bool
    let missingPackageMetadataCount: Int
    let apps: [DLCAppOwnership]

    init(
        accountSelected: Bool,
        licenseCount: Int,
        packageMetadataComplete: Bool,
        missingPackageMetadataCount: Int,
        apps: [DLCAppOwnership]
    ) {
        self.accountSelected = accountSelected
        self.licenseCount = licenseCount
        self.packageMetadataComplete = packageMetadataComplete
        self.missingPackageMetadataCount = missingPackageMetadataCount
        self.apps = apps
    }

    var byAppID: [UInt32: DLCOwnershipStatus] {
        Dictionary(uniqueKeysWithValues: apps.map { ($0.appID, $0.status) })
    }

    enum CodingKeys: String, CodingKey {
        case accountSelected = "account_selected"
        case licenseCount = "license_count"
        case packageMetadataComplete = "package_metadata_complete"
        case missingPackageMetadataCount = "missing_package_metadata_count"
        case apps
    }
}


package enum DLCContentState: String, Codable, Sendable {
    case present
    case missing
    case incomplete
    case unknown
}

struct DLCAppContentState: Codable, Hashable, Sendable {
    let appID: UInt32
    let state: DLCContentState
    let source: String

    init(appID: UInt32, state: DLCContentState, source: String) {
        self.appID = appID
        self.state = state
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case state
        case source
    }
}

package enum DLCContentStorage: String, Codable, Sendable {
    case separate
    case bundled
    case unknown
}

struct DLCContentSnapshot: Codable, Sendable {
    let baseAppID: UInt32
    let storage: DLCContentStorage?
    let contentRoot: String?
    let apps: [DLCAppContentState]

    init(
        baseAppID: UInt32,
        apps: [DLCAppContentState],
        storage: DLCContentStorage? = nil,
        contentRoot: String? = nil
    ) {
        self.baseAppID = baseAppID
        self.storage = storage
        self.contentRoot = contentRoot
        self.apps = apps
    }

    var byAppID: [UInt32: DLCContentState] {
        Dictionary(uniqueKeysWithValues: apps.map { ($0.appID, $0.state) })
    }


    enum CodingKeys: String, CodingKey {
        case baseAppID = "base_app_id"
        case storage
        case contentRoot = "content_root"
        case apps
    }
}

package enum StoreCacheStatus: String, Codable, Sendable {
    case hit
    case refreshed
    case staleFallback = "stale-fallback"
    case unavailable
}

package struct DLCDiscoveryResult: Sendable {
    let appID: UInt32
    package let dlcs: [DLCInfo]
    package let appInfoCount: Int
    package let storeCount: Int
    package let configCount: Int
    package let storeCacheStatus: StoreCacheStatus
    let ownershipByAppID: [UInt32: DLCOwnershipStatus]
    let ownershipAccountSelected: Bool
    let ownershipPackageMetadataComplete: Bool
    let contentByAppID: [UInt32: DLCContentState]
    package let contentStorage: DLCContentStorage
    package let contentRootURL: URL?

    init(
        appID: UInt32,
        dlcs: [DLCInfo],
        appInfoCount: Int,
        storeCount: Int,
        configCount: Int,
        storeCacheStatus: StoreCacheStatus,
        ownershipByAppID: [UInt32: DLCOwnershipStatus] = [:],
        ownershipAccountSelected: Bool = false,
        ownershipPackageMetadataComplete: Bool = false,
        contentByAppID: [UInt32: DLCContentState] = [:],
        contentStorage: DLCContentStorage = .unknown,
        contentRootURL: URL? = nil
    ) {
        self.appID = appID
        self.dlcs = dlcs
        self.appInfoCount = appInfoCount
        self.storeCount = storeCount
        self.configCount = configCount
        self.storeCacheStatus = storeCacheStatus
        self.ownershipByAppID = ownershipByAppID
        self.ownershipAccountSelected = ownershipAccountSelected
        self.ownershipPackageMetadataComplete = ownershipPackageMetadataComplete
        self.contentByAppID = contentByAppID
        self.contentStorage = contentStorage
        self.contentRootURL = contentRootURL
    }

    package func ownershipStatus(for appID: UInt32) -> DLCOwnershipStatus {
        ownershipByAppID[appID] ?? .unknown
    }

    package func contentState(for appID: UInt32) -> DLCContentState {
        contentByAppID[appID] ?? .unknown
    }

    func withContentSnapshot(_ snapshot: DLCContentSnapshot) -> DLCDiscoveryResult {
        DLCDiscoveryResult(
            appID: appID,
            dlcs: dlcs,
            appInfoCount: appInfoCount,
            storeCount: storeCount,
            configCount: configCount,
            storeCacheStatus: storeCacheStatus,
            ownershipByAppID: ownershipByAppID,
            ownershipAccountSelected: ownershipAccountSelected,
            ownershipPackageMetadataComplete: ownershipPackageMetadataComplete,
            contentByAppID: snapshot.byAppID,
            contentStorage: snapshot.storage ?? .unknown,
            contentRootURL: snapshot.contentRoot.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        )
    }
}
