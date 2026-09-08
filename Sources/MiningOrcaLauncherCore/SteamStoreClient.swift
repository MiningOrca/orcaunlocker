import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SteamStoreError: Error, LocalizedError {
    case invalidURL
    case invalidHTTPStatus(Int)
    case unsuccessfulResponse(UInt32)
    case missingData(UInt32)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Could not construct Steam Store appdetails URL."
        case .invalidHTTPStatus(let status):
            return "Steam Store returned HTTP \(status)."
        case .unsuccessfulResponse(let appID):
            return "Steam Store returned success=false for AppID \(appID)."
        case .missingData(let appID):
            return "Steam Store response has no data object for AppID \(appID)."
        }
    }
}

protocol SteamStoreProviding {
    func dlcs(for appID: UInt32) async throws -> [DLCInfo]
}

struct SteamStoreClient: SteamStoreProviding, Sendable {
    private struct Envelope: Decodable {
        let success: Bool
        let data: AppData?
    }

    private struct AppData: Decodable {
        let name: String?
        let dlc: [UInt32]?
        let isFree: Bool?

        enum CodingKeys: String, CodingKey {
            case name
            case dlc
            case isFree = "is_free"
        }
    }

    private let settings: LauncherSettings.Store
    private let session: URLSession

    init(settings: LauncherSettings.Store, session: URLSession? = nil) {
        self.settings = settings
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = settings.requestTimeoutSeconds
            configuration.timeoutIntervalForResource = settings.requestTimeoutSeconds
            self.session = URLSession(configuration: configuration)
        }
    }

    func dlcs(for appID: UInt32) async throws -> [DLCInfo] {
        let parent = try await appDetails(appID: appID, basic: false)
        let ids = Array(Set(parent.dlc ?? [])).sorted()
        guard !ids.isEmpty else { return [] }

        var names: [UInt32: String] = [:]
        var freeByAppID: [UInt32: Bool] = [:]
        let batchSize = settings.maxConcurrentRequests

        var start = 0
        while start < ids.count {
            let end = min(start + batchSize, ids.count)
            let batch = Array(ids[start..<end])

            await withTaskGroup(of: (UInt32, String?, Bool?).self) { group in
                for childID in batch {
                    group.addTask {
                        do {
                            let child = try await appDetails(appID: childID, basic: true)
                            let name = child.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                            return (childID, name?.isEmpty == false ? name : nil, child.isFree)
                        } catch {
                            return (childID, nil, nil)
                        }
                    }
                }

                for await (childID, name, isFree) in group {
                    if let name {
                        names[childID] = name
                    }
                    if let isFree {
                        freeByAppID[childID] = isFree
                    }
                }
            }

            start = end
        }

        return ids.map { appID in
            DLCInfo(
                appID: appID,
                name: names[appID],
                isFree: freeByAppID[appID]
            )
        }
    }

    private func appDetails(appID: UInt32, basic: Bool) async throws -> AppData {
        guard var components = URLComponents(url: settings.appDetailsURL, resolvingAgainstBaseURL: false) else {
            throw SteamStoreError.invalidURL
        }

        var query = [
            URLQueryItem(name: "appids", value: String(appID)),
            URLQueryItem(name: "l", value: settings.language),
        ]
        if basic {
            query.append(URLQueryItem(name: "filters", value: "basic"))
        }
        components.queryItems = query

        guard let url = components.url else {
            throw SteamStoreError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: settings.requestTimeoutSeconds)
        request.setValue(settings.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SteamStoreError.invalidHTTPStatus(http.statusCode)
        }

        let payload = try JSONDecoder().decode([String: Envelope].self, from: data)
        guard let envelope = payload[String(appID)], envelope.success else {
            throw SteamStoreError.unsuccessfulResponse(appID)
        }
        guard let result = envelope.data else {
            throw SteamStoreError.missingData(appID)
        }
        return result
    }
}
