import Foundation

enum QuarantineError: Error, LocalizedError {
    case inspectFailed(URL, String)
    case removeFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .inspectFailed(let url, let output):
            return "Could not inspect extended attributes for \(url.path): \(output)"
        case .removeFailed(let url, let output):
            return "Could not remove com.apple.quarantine from \(url.path): \(output)"
        }
    }
}

struct QuarantineService {
    static let attributeName = "com.apple.quarantine"

    init() {}

    func isQuarantined(_ url: URL) throws -> Bool {
        let result = try SystemTool.run(
            "/usr/bin/xattr",
            arguments: [url.path],
            check: false
        )
        guard result.status == 0 else {
            throw QuarantineError.inspectFailed(url, result.combinedOutput)
        }

        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains(Self.attributeName)
    }

    @discardableResult
    func removeIfPresent(from url: URL) throws -> Bool {
        guard try isQuarantined(url) else { return false }

        let result = try SystemTool.run(
            "/usr/bin/xattr",
            arguments: ["-d", Self.attributeName, url.path],
            check: false
        )
        guard result.status == 0 else {
            throw QuarantineError.removeFailed(url, result.combinedOutput)
        }
        return true
    }
}
