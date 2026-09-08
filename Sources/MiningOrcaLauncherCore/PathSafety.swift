import Foundation

enum PathSafetyError: Error, Equatable {
    case outsideAllowedRoot(URL, URL)
    case symbolicLink(URL)
}

enum PathSafety {
    static func requireInside(
        _ url: URL,
        root: URL,
        fileSystem: FileSystem = .default
    ) throws -> URL {
        let resolvedRoot = try canonicalURL(root, fileSystem: fileSystem)
        let resolvedURL = try canonicalURL(url, fileSystem: fileSystem)

        guard isSameOrDescendant(resolvedURL, of: resolvedRoot) else {
            throw PathSafetyError.outsideAllowedRoot(resolvedURL, resolvedRoot)
        }

        return resolvedURL
    }

    static func requireNotSymbolicLink(
        _ url: URL,
        fileSystem: FileSystem = .default
    ) throws {
        do {
            let attributes = try fileSystem.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw PathSafetyError.symbolicLink(url.standardizedFileURL)
            }
        } catch let error as PathSafetyError {
            throw error
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // A not-yet-created destination cannot itself be a symlink. Foundation
            // may surface attributesOfItem() misses as either generic no-such-file
            // or file-read-no-such-file depending on the Foundation implementation.
        }
    }

    @discardableResult
    static func requireNonSymlinkInside(
        _ url: URL,
        inside root: URL,
        fileSystem: FileSystem = .default
    ) throws -> URL {
        try requireNotSymbolicLink(url, fileSystem: fileSystem)
        return try requireInside(url, root: root, fileSystem: fileSystem)
    }


    private static func canonicalURL(
        _ url: URL,
        fileSystem: FileSystem
    ) throws -> URL {
        let standardized = url.standardizedFileURL

        if pathExistsIncludingSymlink(standardized, fileSystem: fileSystem) {
            return fileSystem.resolvingSymlinks(in: standardized).standardizedFileURL
        }

        var ancestor = standardized
        var suffix: [String] = []

        while !pathExistsIncludingSymlink(ancestor, fileSystem: fileSystem) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else {
                break
            }
            suffix.append(ancestor.lastPathComponent)
            ancestor = parent
        }

        var resolved = fileSystem.resolvingSymlinks(in: ancestor).standardizedFileURL
        for component in suffix.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    private static func pathExistsIncludingSymlink(
        _ url: URL,
        fileSystem: FileSystem
    ) -> Bool {
        do {
            _ = try fileSystem.attributesOfItem(atPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func isSameOrDescendant(_ child: URL, of root: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents

        guard childComponents.count >= rootComponents.count else {
            return false
        }

        return zip(rootComponents, childComponents).allSatisfy(==)
    }
}
