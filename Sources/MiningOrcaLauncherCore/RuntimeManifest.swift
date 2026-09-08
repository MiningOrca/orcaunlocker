import Foundation

package enum RuntimeProfile: String, Codable, CaseIterable, Hashable, Sendable {
    case production
    case debug
}

package struct RuntimeArtifact: Codable, Hashable, Sendable {
    let file: String
    package let transport: SteamTransport
    package let profile: RuntimeProfile
    let architectures: [String]
    let sha256: String

    init(
        file: String,
        transport: SteamTransport,
        profile: RuntimeProfile,
        architectures: [String],
        sha256: String
    ) {
        self.file = file
        self.transport = transport
        self.profile = profile
        self.architectures = architectures
        self.sha256 = sha256
    }
}

struct RuntimeManifest: Codable, Equatable, Sendable {
    let format: Int
    let artifacts: [RuntimeArtifact]

    init(format: Int, artifacts: [RuntimeArtifact]) {
        self.format = format
        self.artifacts = artifacts
    }
}

enum RuntimeManifestError: Error, LocalizedError {
    case unreadable(URL, String)
    case invalidJSON(URL, String)
    case unsupportedFormat(Int)
    case invalidArtifact(String)
    case duplicateArtifact(SteamTransport, RuntimeProfile)
    case missingArtifact(SteamTransport, RuntimeProfile)
    case unexpectedArtifactCount(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url, let message):
            return "Runtime manifest could not be read at \(url.path): \(message)"
        case .invalidJSON(let url, let message):
            return "Runtime manifest is invalid JSON at \(url.path): \(message)"
        case .unsupportedFormat(let format):
            return "Unsupported runtime manifest format: \(format)"
        case .invalidArtifact(let message):
            return "Invalid runtime artifact: \(message)"
        case .duplicateArtifact(let transport, let profile):
            return "Runtime manifest contains duplicate \(transport.rawValue)/\(profile.rawValue) artifact."
        case .missingArtifact(let transport, let profile):
            return "Runtime manifest is missing \(transport.rawValue)/\(profile.rawValue) artifact."
        case .unexpectedArtifactCount(let count):
            return "Runtime manifest must contain exactly 4 artifacts, found \(count)."
        }
    }
}

enum RuntimeManifestCodec {
    static let supportedFormat = 1
    static let expectedArchitectures: Set<String> = ["arm64", "x86_64"]

    static func load(from url: URL) throws -> RuntimeManifest {
        let data: Data
        do {
            data = try FileSystem.default.readData(from: url)
        } catch {
            throw RuntimeManifestError.unreadable(url, error.localizedDescription)
        }

        let manifest: RuntimeManifest
        do {
            manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        } catch {
            throw RuntimeManifestError.invalidJSON(url, error.localizedDescription)
        }

        try validate(manifest)
        return manifest
    }

    static func validate(_ manifest: RuntimeManifest) throws {
        guard manifest.format == supportedFormat else {
            throw RuntimeManifestError.unsupportedFormat(manifest.format)
        }
        guard manifest.artifacts.count == 4 else {
            throw RuntimeManifestError.unexpectedArtifactCount(manifest.artifacts.count)
        }

        var seen: Set<RuntimeArtifactKey> = []
        for artifact in manifest.artifacts {
            try validateArtifact(artifact)
            let key = RuntimeArtifactKey(transport: artifact.transport, profile: artifact.profile)
            guard seen.insert(key).inserted else {
                throw RuntimeManifestError.duplicateArtifact(artifact.transport, artifact.profile)
            }
        }

        for transport in SteamTransport.allCases {
            for profile in RuntimeProfile.allCases {
                let key = RuntimeArtifactKey(transport: transport, profile: profile)
                guard seen.contains(key) else {
                    throw RuntimeManifestError.missingArtifact(transport, profile)
                }
            }
        }
    }

    private static func validateArtifact(_ artifact: RuntimeArtifact) throws {
        let file = artifact.file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !file.isEmpty,
              file == URL(fileURLWithPath: file).lastPathComponent,
              file != ".",
              file != ".." else {
            throw RuntimeManifestError.invalidArtifact("unsafe file name: \(artifact.file)")
        }

        guard Set(artifact.architectures) == expectedArchitectures else {
            throw RuntimeManifestError.invalidArtifact(
                "\(artifact.file) must declare exactly arm64+x86_64"
            )
        }

        let hash = artifact.sha256.lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
            throw RuntimeManifestError.invalidArtifact("invalid SHA-256 for \(artifact.file)")
        }
    }
}

struct RuntimeArtifactKey: Hashable, Sendable {
    let transport: SteamTransport
    let profile: RuntimeProfile

    init(transport: SteamTransport, profile: RuntimeProfile) {
        self.transport = transport
        self.profile = profile
    }
}
