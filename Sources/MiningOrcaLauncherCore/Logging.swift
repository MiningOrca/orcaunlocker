import Foundation
import Logging

package struct LauncherLogEntry: Sendable {
    package let timestamp: Date
    let level: Logger.Level
    package let message: String
    package let metadata: Logger.Metadata
    let source: String
    let file: String
    let function: String
    let line: UInt

    package var levelText: String {
        level.rawValue.uppercased()
    }

    package var appID: UInt32? {
        guard case .string(let value)? = metadata["app_id"] else { return nil }
        return UInt32(value)
    }
}

private final class LauncherLogStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [LauncherLogEntry] = []
    private var streamContinuations: [UUID: AsyncStream<LauncherLogEntry>.Continuation] = [:]

    var entries: [LauncherLogEntry] {
        lock.withLock { storedEntries }
    }

    func append(_ entry: LauncherLogEntry) {
        let continuations = lock.withLock { () -> [AsyncStream<LauncherLogEntry>.Continuation] in
            storedEntries.append(entry)
            return Array(streamContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(entry)
        }
    }

    func stream() -> AsyncStream<LauncherLogEntry> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.withLock {
                streamContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeStreamContinuation(id: id)
            }
        }
    }

    func clear() {
        lock.withLock {
            storedEntries.removeAll(keepingCapacity: true)
        }
    }

    func clear(appID: UInt32) {
        lock.withLock {
            storedEntries.removeAll { $0.appID == appID }
        }
    }

    private func removeStreamContinuation(id: UUID) {
        lock.withLock {
            _ = streamContinuations.removeValue(forKey: id)
        }
    }
}

private struct LauncherCollectingLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    var logLevel: Logger.Level = .info

    private let store: LauncherLogStore

    init(store: LauncherLogStore) {
        self.store = store
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata explicitMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        guard !LauncherLog.isCollectionSuppressed else { return }

        var mergedMetadata = metadataProvider?.get() ?? [:]
        mergedMetadata.merge(metadata) { _, handlerValue in handlerValue }
        mergedMetadata.merge(explicitMetadata ?? [:]) { _, explicitValue in explicitValue }
        if mergedMetadata["app_id"] == nil, let appID = LauncherLog.appID {
            mergedMetadata["app_id"] = .string(String(appID))
        }

        store.append(
            LauncherLogEntry(
                timestamp: Date(),
                level: level,
                message: message.description,
                metadata: mergedMetadata,
                source: source,
                file: file,
                function: function,
                line: line
            )
        )
    }
}

package enum LauncherLogging {
    private static let store = LauncherLogStore()

    static var entries: [LauncherLogEntry] {
        store.entries
    }

    static var warningsAndErrors: [LauncherLogEntry] {
        entries.filter { $0.level >= .warning }
    }

    package static func entries(appID: UInt32) -> [LauncherLogEntry] {
        entries.filter { $0.appID == appID }
    }

    package static func stream() -> AsyncStream<LauncherLogEntry> {
        store.stream()
    }

    static func clear() {
        store.clear()
    }

    package static func clear(appID: UInt32) {
        store.clear(appID: appID)
    }

    package static func bootstrap(includeStandardError: Bool = true) {
        let store = Self.store

        LoggingSystem.bootstrap { label in
            var collecting = LauncherCollectingLogHandler(store: store)
            collecting.logLevel = .info

            guard includeStandardError else {
                return collecting
            }

            var standardError = StreamLogHandler.standardError(label: label)
            standardError.logLevel = .info
            return MultiplexLogHandler([collecting, standardError])
        }
    }
}

enum LauncherLog {
    @TaskLocal static var appID: UInt32?
    @TaskLocal static var isCollectionSuppressed = false

    // swift-log requires a label, but the call site is already supplied separately as
    // file/function/line. An empty label avoids inventing a second source taxonomy and
    // keeps the standard stderr output free of a redundant per-message prefix.
    static let logger = Logger(label: "")

    static func withAppID<T>(_ gameAppID: UInt32, operation: () throws -> T) rethrows -> T {
        try $appID.withValue(gameAppID, operation: operation)
    }

    static func suppressCollection<T>(operation: () throws -> T) rethrows -> T {
        try $isCollectionSuppressed.withValue(true, operation: operation)
    }

    static func withAppID<T>(
        _ gameAppID: UInt32,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $appID.withValue(gameAppID, operation: operation)
    }
}
