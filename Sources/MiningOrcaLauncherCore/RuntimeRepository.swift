import Foundation

enum RuntimeRepositoryError: Error, LocalizedError {
    case runtimeDirectoryUnavailable
    case missingArtifact(SteamTransport, RuntimeProfile)
    case artifactFileMissing(URL)

    var errorDescription: String? {
        switch self {
        case .runtimeDirectoryUnavailable:
            return "Bundled runtime directory is unavailable."
        case .missingArtifact(let transport, let profile):
            return "Runtime artifact not found for \(transport.rawValue)/\(profile.rawValue)."
        case .artifactFileMissing(let url):
            return "Runtime artifact file is missing: \(url.path)"
        }
    }
}

struct RuntimeRepository: Sendable {
    static let manifestFileName = "manifest.json"

    let directory: URL
    let manifest: RuntimeManifest

    init(directory: URL, manifest: RuntimeManifest) {
        self.directory = directory.standardizedFileURL
        self.manifest = manifest
    }

    static func load(from directory: URL) throws -> RuntimeRepository {
        let normalized = directory.standardizedFileURL
        let manifestURL = normalized.appendingPathComponent(manifestFileName, isDirectory: false)
        let manifest = try RuntimeManifestCodec.load(from: manifestURL)
        return RuntimeRepository(directory: normalized, manifest: manifest)
    }

    static func defaultDirectory(settings: LauncherSettings.Runtime) throws -> URL {
        if let configured = settings.developmentDirectory {
            let expanded = NSString(string: configured).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }

        guard let resources = Bundle.main.resourceURL else {
            throw RuntimeRepositoryError.runtimeDirectoryUnavailable
        }

        return settings.bundledDirectoryName
            .split(separator: "/")
            .reduce(resources) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
    }

    func artifact(
        transport: SteamTransport,
        profile: RuntimeProfile
    ) throws -> RuntimeArtifact {
        guard let artifact = manifest.artifacts.first(where: {
            $0.transport == transport && $0.profile == profile
        }) else {
            throw RuntimeRepositoryError.missingArtifact(transport, profile)
        }
        return artifact
    }

    func fileURL(for artifact: RuntimeArtifact) -> URL {
        directory.appendingPathComponent(artifact.file, isDirectory: false)
    }

    func existingFileURL(for artifact: RuntimeArtifact) throws -> URL {
        let url = fileURL(for: artifact)
        guard FileSystem.default.fileExists(atPath: url.path) else {
            throw RuntimeRepositoryError.artifactFileMissing(url)
        }
        return url
    }
}
