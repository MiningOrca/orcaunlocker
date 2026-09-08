import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum AtomicFileReplacementError: Error, LocalizedError {
    case replaceFailed(URL, URL, Int32)

    var errorDescription: String? {
        switch self {
        case .replaceFailed(let source, let destination, let code):
            return "Could not atomically replace \(destination.path) with \(source.path) (errno \(code))."
        }
    }
}

/// The single Swift-side boundary for filesystem I/O.
///
/// Path construction belongs in path/layout types such as `RuntimeGamePaths` and `RuntimeTargetPaths`,
/// while security policy remains in `PathSafety`. This type only owns the
/// concrete filesystem primitives used by MiningOrca Swift targets.
package struct FileSystem: @unchecked Sendable {
    private let fileManager: FileManager

    package static let `default` = FileSystem()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var currentDirectoryPath: String {
        fileManager.currentDirectoryPath
    }

    var homeDirectoryForCurrentUser: URL {
        fileManager.homeDirectoryForCurrentUser
    }

    var temporaryDirectory: URL {
        fileManager.temporaryDirectory
    }

    func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        try fileManager.url(
            for: directory,
            in: domain,
            appropriateFor: url,
            create: shouldCreate
        )
    }

    func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    package func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func isExecutableFile(atPath path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    func isReadableFile(atPath path: String) -> Bool {
        fileManager.isReadableFile(atPath: path)
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try fileManager.attributesOfItem(atPath: path)
    }

    func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        try fileManager.setAttributes(attributes, ofItemAtPath: path)
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: path)
    }

    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }

    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = [],
        errorHandler handler: ((URL, Error) -> Bool)? = nil
    ) -> FileManager.DirectoryEnumerator? {
        fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask,
            errorHandler: handler
        )
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    @discardableResult
    func removeItemIfExists(_ url: URL) throws -> Bool {
        guard fileExists(atPath: url.path) else { return false }
        try removeItem(at: url)
        return true
    }

    /// Removes a directory only when it contains no entries, including hidden ones.
    @discardableResult
    func removeDirectoryIfEmpty(_ url: URL) throws -> Bool {
        guard fileExists(atPath: url.path) else { return false }
        guard try contentsOfDirectory(atPath: url.path).isEmpty else { return false }
        try removeItem(at: url)
        return true
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try fileManager.copyItem(at: source, to: destination)
    }

    func resourceValues(
        for url: URL,
        keys: Set<URLResourceKey>
    ) throws -> URLResourceValues {
        try url.resourceValues(forKeys: keys)
    }

    func resolvingSymlinks(in url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }

    func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func readLastBytes(
        from url: URL,
        maxBytes: Int
    ) throws -> (data: Data, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let byteLimit = UInt64(maxBytes)
        let start = size > byteLimit ? size - byteLimit : 0
        try handle.seek(toOffset: start)
        return (handle.readDataToEndOfFile(), start > 0)
    }

    func writeData(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions = []
    ) throws {
        try data.write(to: url, options: options)
    }

    func readString(
        from url: URL,
        encoding: String.Encoding = .utf8
    ) throws -> String {
        try String(contentsOf: url, encoding: encoding)
    }

    func writeString(
        _ string: String,
        to url: URL,
        atomically useAuxiliaryFile: Bool,
        encoding: String.Encoding = .utf8
    ) throws {
        try string.write(to: url, atomically: useAuxiliaryFile, encoding: encoding)
    }

    /// Atomically replaces one filesystem entry with another using POSIX rename(2).
    /// Callers must stage `source` in the destination directory so the rename stays
    /// on one filesystem and the live destination is never removed first.
    func atomicReplace(_ source: URL, _ destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw AtomicFileReplacementError.replaceFailed(source, destination, errno)
        }
    }
}
