import Foundation

enum CodeSigningError: Error, LocalizedError {
    case failed(URL, String)
    case unsafeNestedCode(URL, root: URL)
    case missingNestedCode(URL)
    case nestedSymlink(URL)
    case nestingTooDeep(URL)
    case couldNotStabilize(URL)
    case unsupportedAppBundleLayout(URL, rootEntries: [String])

    var errorDescription: String? {
        switch self {
        case .failed(let url, let output):
            return "Could not ad-hoc sign \(url.path): \(output)"
        case .unsafeNestedCode(let nested, let root):
            return "codesign reported nested code outside app bundle: \(nested.path) (root: \(root.path))"
        case .missingNestedCode(let url):
            return "codesign reported a nested code object that does not exist: \(url.path)"
        case .nestedSymlink(let url):
            return "codesign reported a symlink as an unsigned nested code object: \(url.path)"
        case .nestingTooDeep(let url):
            return "Too many nested unsigned code objects while signing \(url.path)"
        case .couldNotStabilize(let url):
            return "codesign could not stabilize \(url.path)"
        case .unsupportedAppBundleLayout(let app, let rootEntries):
            let entries = rootEntries.isEmpty ? "(empty bundle root)" : rootEntries.joined(separator: ", ")
            return "Proxy cannot be used for \(app.lastPathComponent) because the game bundle is not in a clean Steam state and macOS cannot safely re-sign it.\n\nVerify the game files in Steam:\nSteam → Properties → Installed Files → Verify integrity of game files\n\nThen try Proxy again, or use Inject instead.\n\nBundle root: \(entries)"
        }
    }
}

struct CodeSigningService {
    private let fileSystem: FileSystem

    init(fileSystem: FileSystem = .default) {
        self.fileSystem = fileSystem
    }

    func signAdHoc(_ url: URL) throws {
        _ = try SystemTool.run(
            "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", url.path]
        )
    }

    func verify(_ url: URL) throws {
        _ = try SystemTool.run(
            "/usr/bin/codesign",
            arguments: [
                "--verify",
                "--strict",
                "--all-architectures",
                "--verbose=4",
                url.path,
            ]
        )
    }

    /// Proxy modifies code inside the containing app bundle, so the outer bundle
    /// must be re-sealable before any Steam-managed file is touched. Modern
    /// codesign rejects app bundles that contain loose items beside Contents/.
    func preflightContainingAppsForResign(of target: URL) throws {
        for app in containingApps(of: target) {
            let entries = try fileSystem.contentsOfDirectory(
                at: app,
                includingPropertiesForKeys: nil,
                options: []
            )
            let names = entries.map(\.lastPathComponent).sorted()
            let unexpected = names.filter { $0 != "Contents" }
            guard names.contains("Contents"), unexpected.isEmpty else {
                throw CodeSigningError.unsupportedAppBundleLayout(
                    app,
                    rootEntries: names
                )
            }
        }
    }

    func resignContainingApps(of target: URL) throws {
        for app in containingApps(of: target) {
            LauncherLog.logger.info(
                "Re-signing containing application bundle",
                metadata: ["bundle": "\(app.lastPathComponent)"]
            )
            try resignAppBundle(app)
        }
    }

    /// Restoring an exact Valve dylib may make the app's original outer
    /// signature valid again. Verify first and only re-sign when verification
    /// still fails. This is important when a failed Proxy attempt never managed
    /// to replace the original app signature.
    func validateContainingAppsAfterRestore(of target: URL) throws {
        for app in containingApps(of: target) {
            let verification = try SystemTool.run(
                "/usr/bin/codesign",
                arguments: [
                    "--verify",
                    "--strict",
                    "--all-architectures",
                    "--verbose=4",
                    app.path,
                ],
                check: false
            )
            if verification.status == 0 {
                LauncherLog.logger.info(
                    "Containing application signature is valid after Proxy restore; re-sign is not required",
                    metadata: ["bundle": "\(app.lastPathComponent)"]
                )
                continue
            }

            LauncherLog.logger.warning(
                "Containing application signature is still invalid after Proxy restore; attempting ad-hoc re-sign",
                metadata: ["bundle": "\(app.lastPathComponent)"]
            )
            try resignAppBundle(app)
        }
    }

    private func containingApps(of target: URL) -> [URL] {
        var current = target.deletingLastPathComponent()
        var apps: [URL] = []

        while current.path != "/" {
            if current.pathExtension.lowercased() == "app" {
                apps.append(current)
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }

        return apps
    }

    private func resignAppBundle(_ app: URL) throws {
        for _ in 0..<20 {
            let result = try signPreservingMetadata(app)
            if result.status == 0 { return }

            guard let nested = try unsignedSubcomponent(from: result, rootBundle: app) else {
                throw CodeSigningError.failed(app, result.combinedOutput)
            }
            LauncherLog.logger.warning(
                "Unsigned nested code detected while signing app; signing the nested object and retrying",
                metadata: ["bundle": "\(app.lastPathComponent)", "nested": "\(nested.lastPathComponent)"]
            )
            try signNestedCode(nested, rootBundle: app, depth: 0)
        }

        throw CodeSigningError.couldNotStabilize(app)
    }

    private func signNestedCode(_ target: URL, rootBundle: URL, depth: Int) throws {
        guard depth < 20 else {
            throw CodeSigningError.nestingTooDeep(target)
        }

        for _ in 0..<20 {
            let preserving = try signPreservingMetadata(target)
            if preserving.status == 0 { return }

            if let nested = try unsignedSubcomponent(from: preserving, rootBundle: rootBundle) {
                LauncherLog.logger.warning(
                    "Unsigned nested code detected; signing nested object",
                    metadata: ["nested": "\(nested.lastPathComponent)", "depth": "\(depth + 1)"]
                )
                try signNestedCode(nested, rootBundle: rootBundle, depth: depth + 1)
                continue
            }

            let plain = try SystemTool.run(
                "/usr/bin/codesign",
                arguments: ["--force", "--sign", "-", target.path],
                check: false
            )
            if plain.status == 0 { return }

            if let nested = try unsignedSubcomponent(from: plain, rootBundle: rootBundle) {
                try signNestedCode(nested, rootBundle: rootBundle, depth: depth + 1)
                continue
            }

            throw CodeSigningError.failed(target, plain.combinedOutput)
        }

        throw CodeSigningError.couldNotStabilize(target)
    }

    private func signPreservingMetadata(_ url: URL) throws -> SystemToolResult {
        try SystemTool.run(
            "/usr/bin/codesign",
            arguments: [
                "--force",
                "--sign",
                "-",
                "--preserve-metadata=identifier,entitlements,flags",
                url.path,
            ],
            check: false
        )
    }

    private func unsignedSubcomponent(
        from result: SystemToolResult,
        rootBundle: URL
    ) throws -> URL? {
        let output = result.combinedOutput
        guard output.contains("code object is not signed at all") else {
            return nil
        }

        guard let line = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first(where: { $0.hasPrefix("In subcomponent:") }) else {
            return nil
        }

        let raw = String(line.dropFirst("In subcomponent:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let nested: URL
        if raw.hasPrefix("/") {
            nested = URL(fileURLWithPath: raw)
        } else {
            nested = rootBundle.appendingPathComponent(raw)
        }

        let normalizedNested = nested.standardizedFileURL
        guard fileSystem.fileExists(atPath: normalizedNested.path) else {
            throw CodeSigningError.missingNestedCode(normalizedNested)
        }

        do {
            try PathSafety.requireNotSymbolicLink(normalizedNested, fileSystem: fileSystem)
        } catch PathSafetyError.symbolicLink {
            throw CodeSigningError.nestedSymlink(normalizedNested)
        }

        do {
            return try PathSafety.requireInside(
                normalizedNested,
                root: rootBundle,
                fileSystem: fileSystem
            )
        } catch PathSafetyError.outsideAllowedRoot(let resolved, let root) {
            throw CodeSigningError.unsafeNestedCode(resolved, root: root)
        }
    }
}
