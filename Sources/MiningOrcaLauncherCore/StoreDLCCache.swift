import Foundation

struct StoreDLCCacheEntry: Codable, Equatable {
    static let format = 2

    let format: Int
    let appID: UInt32
    let fetchedAt: TimeInterval
    let dlcs: [DLCInfo]

    init(appID: UInt32, fetchedAt: TimeInterval, dlcs: [DLCInfo]) {
        self.format = Self.format
        self.appID = appID
        self.fetchedAt = fetchedAt
        self.dlcs = dlcs
    }
}

struct StoreDLCCache {
    let directory: URL
    let fileSystem: FileSystem

    init(directory: URL, fileSystem: FileSystem = .default) {
        self.directory = directory
        self.fileSystem = fileSystem
    }

    func load(appID: UInt32) -> StoreDLCCacheEntry? {
        let url = cacheURL(appID: appID)
        guard let data = try? fileSystem.readData(from: url),
              let entry = try? JSONDecoder().decode(StoreDLCCacheEntry.self, from: data),
              entry.format == StoreDLCCacheEntry.format,
              entry.appID == appID else {
            return nil
        }
        return entry
    }

    func save(appID: UInt32, dlcs: [DLCInfo], now: TimeInterval) throws {
        try fileSystem.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = StoreDLCCacheEntry(appID: appID, fetchedAt: now, dlcs: dlcs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entry)
        try fileSystem.writeData(data, to: cacheURL(appID: appID), options: .atomic)
    }

    func isFresh(_ entry: StoreDLCCacheEntry, now: TimeInterval, ttl: TimeInterval) -> Bool {
        guard ttl > 0 else { return false }
        let age = max(0, now - entry.fetchedAt)
        return age < ttl
    }

    private func cacheURL(appID: UInt32) -> URL {
        directory.appendingPathComponent("\(appID).json", isDirectory: false)
    }
}
