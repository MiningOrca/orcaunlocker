import Foundation

package struct RuntimeArtifactVerification: Sendable {
    package let artifact: RuntimeArtifact
    let fileURL: URL
    let sha256: String
    let architectures: [String]
    let signatureValid: Bool
    let installName: String
    let proxyReexportValid: Bool?
    let quarantined: Bool
}

enum RuntimeVerificationError: Error, LocalizedError {
    case malformedToolOutput(String, String)
    case sha256Mismatch(String, expected: String, actual: String)
    case architectureMismatch(String, expected: Set<String>, actual: Set<String>)
    case installNameMismatch(String, expected: String, actual: String)
    case missingProxyReexport(String)

    var errorDescription: String? {
        switch self {
        case .malformedToolOutput(let tool, let output):
            return "Could not parse \(tool) output: \(output)"
        case .sha256Mismatch(let file, let expected, let actual):
            return "SHA-256 mismatch for \(file): expected \(expected), got \(actual)"
        case .architectureMismatch(let file, let expected, let actual):
            return "Architecture mismatch for \(file): expected \(expected.sorted()), got \(actual.sorted())"
        case .installNameMismatch(let file, let expected, let actual):
            return "Install name mismatch for \(file): expected \(expected), got \(actual)"
        case .missingProxyReexport(let file):
            return "Proxy runtime \(file) does not re-export @loader_path/libsteam_api_o.dylib."
        }
    }
}

struct RuntimeVerifier {
    static let proxyInstallName = "@loader_path/libsteam_api.dylib"
    static let injectInstallName = "@rpath/orcaunlocker.dylib"
    static let originalReexportName = "@loader_path/libsteam_api_o.dylib"

    init() {}

    func verify(_ repository: RuntimeRepository) throws -> [RuntimeArtifactVerification] {
        var results: [RuntimeArtifactVerification] = []

        for transport in SteamTransport.allCases {
            for profile in RuntimeProfile.allCases {
                results.append(
                    try verify(
                        transport: transport,
                        profile: profile,
                        in: repository
                    )
                )
            }
        }

        return results
    }

    func verify(
        transport: SteamTransport,
        profile: RuntimeProfile,
        in repository: RuntimeRepository
    ) throws -> RuntimeArtifactVerification {
        let artifact = try repository.artifact(transport: transport, profile: profile)
        return try verify(artifact, in: repository)
    }

    static func isProxy(_ url: URL) throws -> Bool {
        try BinaryInspector.links(
            to: originalReexportName,
            in: url
        )
    }

    private func verify(
        _ artifact: RuntimeArtifact,
        in repository: RuntimeRepository
    ) throws -> RuntimeArtifactVerification {
        LauncherLog.logger.info(
            "Verifying runtime artifact",
            metadata: [
                "transport": "\(artifact.transport.rawValue)",
                "profile": "\(artifact.profile.rawValue)",
                "file": "\(artifact.file)",
            ]
        )
        let fileURL = try repository.existingFileURL(for: artifact)

        let actualSHA256 = try inspectBinary {
            try BinaryInspector.sha256(fileURL)
        }
        guard actualSHA256.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
            LauncherLog.logger.error(
                "Runtime SHA-256 verification failed",
                metadata: ["file": "\(artifact.file)"]
            )
            throw RuntimeVerificationError.sha256Mismatch(
                artifact.file,
                expected: artifact.sha256,
                actual: actualSHA256
            )
        }
        LauncherLog.logger.info("Runtime SHA-256 verified", metadata: ["file": "\(artifact.file)"])

        let actualArchitectures = try inspectBinary {
            try BinaryInspector.architectures(fileURL)
        }
        let expectedArchitectures = Set(artifact.architectures)
        guard Set(actualArchitectures) == expectedArchitectures else {
            LauncherLog.logger.error(
                "Runtime architecture verification failed",
                metadata: ["file": "\(artifact.file)"]
            )
            throw RuntimeVerificationError.architectureMismatch(
                artifact.file,
                expected: expectedArchitectures,
                actual: Set(actualArchitectures)
            )
        }
        LauncherLog.logger.info(
            "Runtime architectures verified",
            metadata: ["file": "\(artifact.file)", "architectures": "\(actualArchitectures.joined(separator: ","))"]
        )

        try verifySignature(fileURL)
        LauncherLog.logger.info("Runtime code signature verified", metadata: ["file": "\(artifact.file)"])

        let actualInstallName = try inspectBinary {
            try BinaryInspector.installName(fileURL)
        }
        let expectedInstallName = artifact.transport == .proxy
            ? Self.proxyInstallName
            : Self.injectInstallName
        guard actualInstallName == expectedInstallName else {
            LauncherLog.logger.error(
                "Runtime install-name verification failed",
                metadata: ["file": "\(artifact.file)"]
            )
            throw RuntimeVerificationError.installNameMismatch(
                artifact.file,
                expected: expectedInstallName,
                actual: actualInstallName
            )
        }
        LauncherLog.logger.info("Runtime install name verified", metadata: ["file": "\(artifact.file)"])

        let quarantined = try QuarantineService().isQuarantined(fileURL)

        let reexportValid: Bool?
        if artifact.transport == .proxy {
            let reexports = try BinaryInspector.reexportedDependencies(fileURL)
            guard reexports.contains(Self.originalReexportName) else {
                LauncherLog.logger.error(
                    "Proxy runtime re-export verification failed",
                    metadata: ["file": "\(artifact.file)"]
                )
                throw RuntimeVerificationError.missingProxyReexport(artifact.file)
            }
            LauncherLog.logger.info("Proxy runtime re-export verified", metadata: ["file": "\(artifact.file)"])
            reexportValid = true
        } else {
            reexportValid = nil
        }

        LauncherLog.logger.info(
            "Runtime artifact verification complete",
            metadata: ["file": "\(artifact.file)"]
        )
        return RuntimeArtifactVerification(
            artifact: artifact,
            fileURL: fileURL,
            sha256: actualSHA256,
            architectures: actualArchitectures,
            signatureValid: true,
            installName: actualInstallName,
            proxyReexportValid: reexportValid,
            quarantined: quarantined
        )
    }

    private func verifySignature(_ url: URL) throws {
        _ = try SystemTool.run(
            "/usr/bin/codesign",
            arguments: [
                "--verify",
                "--strict",
                "--all-architectures",
                "--verbose=2",
                url.path,
            ]
        )
    }

    private func inspectBinary<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch BinaryInspectionError.malformedToolOutput(let tool, let output) {
            throw RuntimeVerificationError.malformedToolOutput(tool, output)
        }
    }


}
