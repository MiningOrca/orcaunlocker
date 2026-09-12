import Foundation

enum DebugSessionSupport {
    static func configurationSnapshot(
        game: SteamGame,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) throws -> DebugConfigurationSnapshot {
        let paths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let config = paths.config
        try paths.requireSafeRuntimePath(config, fileSystem: fileSystem)
        guard fileSystem.fileExists(atPath: config.path) else {
            return DebugConfigurationSnapshot(data: nil)
        }
        return DebugConfigurationSnapshot(data: try fileSystem.readData(from: config))
    }

    static func restoreConfiguration(
        _ snapshot: DebugConfigurationSnapshot,
        game: SteamGame,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) throws {
        let paths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let directory = paths.runtimeDirectory
        let config = paths.config
        try paths.requireSafeRuntimePaths(
            [config] + paths.debugTraceFiles,
            fileSystem: fileSystem
        )
        for trace in paths.debugTraceFiles {
            try fileSystem.removeItemIfExists(trace)
        }

        guard let data = snapshot.data else {
            try fileSystem.removeItemIfExists(config)
            try fileSystem.removeDirectoryIfEmpty(directory)
            return
        }

        try fileSystem.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileSystem.writeData(data, to: config, options: .atomic)
    }

    static func clearRuntimeLog(
        game: SteamGame,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) throws {
        let paths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let debugFiles = [paths.log] + paths.debugTraceFiles
        try paths.requireSafeRuntimePaths(debugFiles, fileSystem: fileSystem)
        for url in debugFiles {
            try fileSystem.removeItemIfExists(url)
        }
    }

    static func launch(game: SteamGame) throws {
        _ = try SystemTool.run(
            "/usr/bin/open",
            arguments: ["steam://run/\(game.appID)"]
        )
    }

    static func pulse(
        game: SteamGame,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) throws -> DebugSessionPulse {
        let paths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let log = paths.log
        try paths.requireSafeRuntimePath(log, fileSystem: fileSystem)

        let attributes: [FileAttributeKey: Any]
        if fileSystem.fileExists(atPath: log.path) {
            attributes = try fileSystem.attributesOfItem(atPath: log.path)
        } else {
            attributes = [:]
        }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date
        let processes = try gameProcesses(game, fileSystem: fileSystem)

        return DebugSessionPulse(
            gameProcessRunning: !processes.isEmpty,
            logExists: !attributes.isEmpty,
            logSize: size,
            logModificationDate: modificationDate,
            processes: processes
        )
    }

    static func inspectProcess(
        _ identity: DebugProcessIdentity,
        game: SteamGame,
        steamAPITargets: [URL],
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) -> DebugProcessObservation {
        let executable = identity.executable ?? processExecutable(pid: identity.pid)
        let binaryArchitectures = executable.map(binaryArchitectures) ?? []
        let architecture = processArchitecture(
            pid: identity.pid,
            binaryArchitectures: binaryArchitectures
        )
        let translated = translatedByRosetta(
            architecture: architecture,
            binaryArchitectures: binaryArchitectures
        )
        let environment = processEnvironment(pid: identity.pid)

        let gamePaths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let vmmap = processMappings(
            pid: identity.pid,
            runtimeDylib: gamePaths.injectDylib,
            steamAPITargets: steamAPITargets
        )

        return DebugProcessObservation(
            pid: identity.pid,
            ppid: identity.ppid,
            command: identity.command,
            executable: executable,
            architecture: architecture,
            binaryArchitectures: binaryArchitectures,
            translatedByRosetta: translated,
            dyldInsertLibrariesPresent: environment,
            runtimeLoaded: vmmap.runtimeLoaded,
            steamAPIMappings: vmmap.steamAPIMappings,
            inspectionError: vmmap.error
        )
    }

    private static func gameProcesses(
        _ game: SteamGame,
        fileSystem: FileSystem
    ) throws -> [DebugProcessIdentity] {
        let result = try SystemTool.run(
            "/bin/ps",
            arguments: ["-axww", "-o", "pid=,ppid=,command="],
            check: false
        )
        guard result.status == 0 else {
            throw SystemToolError.failed("/bin/ps", result.status, result.combinedOutput)
        }

        let prefixes = Set([
            game.installDirectory.standardizedFileURL.path + "/",
            fileSystem.resolvingSymlinks(in: game.installDirectory).standardizedFileURL.path + "/",
        ])

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> DebugProcessIdentity? in
                let parts = line.split(
                    maxSplits: 2,
                    omittingEmptySubsequences: true,
                    whereSeparator: \.isWhitespace
                )
                guard parts.count == 3,
                      let pid = Int32(parts[0]),
                      let ppid = Int32(parts[1]) else {
                    return nil
                }

                let command = String(parts[2])
                guard prefixes.contains(where: { command.contains($0) }) else {
                    return nil
                }
                return DebugProcessIdentity(
                    pid: pid,
                    ppid: ppid,
                    command: command,
                    executable: processExecutable(pid: pid)
                )
            }
    }

    private static func processExecutable(pid: Int32) -> String? {
        if let result = try? SystemTool.run(
            "/usr/sbin/lsof",
            arguments: ["-a", "-p", "\(pid)", "-d", "txt", "-Fn"],
            check: false
        ), result.status == 0 {
            for line in result.stdout.split(whereSeparator: \.isNewline) {
                guard line.first == "n" else { continue }
                let path = String(line.dropFirst())
                if path.hasPrefix("/") {
                    return path
                }
            }
        }

        guard let result = try? SystemTool.run(
            "/bin/ps",
            arguments: ["-p", "\(pid)", "-o", "comm="],
            check: false
        ), result.status == 0 else {
            return nil
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func binaryArchitectures(_ executable: String) -> [String] {
        guard let result = try? SystemTool.run(
            "/usr/bin/lipo",
            arguments: ["-archs", executable],
            check: false
        ), result.status == 0 else {
            return []
        }
        return result.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func processArchitecture(
        pid: Int32,
        binaryArchitectures: [String]
    ) -> String? {
        if let result = try? SystemTool.run(
            "/bin/ps",
            arguments: ["-p", "\(pid)", "-o", "arch="],
            check: false
        ), result.status == 0 {
            let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }

        return binaryArchitectures.count == 1 ? binaryArchitectures[0] : nil
    }

    private static func translatedByRosetta(
        architecture: String?,
        binaryArchitectures: [String]
    ) -> Bool? {
        guard let appleSilicon = hardwareIsAppleSilicon() else { return nil }
        guard appleSilicon else { return false }

        if architecture == "x86_64" || architecture == "i386" {
            return true
        }
        if architecture?.hasPrefix("arm64") == true {
            return false
        }
        if binaryArchitectures == ["x86_64"] || binaryArchitectures == ["i386"] {
            return true
        }
        if !binaryArchitectures.isEmpty,
           binaryArchitectures.allSatisfy({ $0.hasPrefix("arm64") }) {
            return false
        }
        return nil
    }

    private static func hardwareIsAppleSilicon() -> Bool? {
        guard let result = try? SystemTool.run(
            "/usr/sbin/sysctl",
            arguments: ["-in", "hw.optional.arm64"],
            check: false
        ), result.status == 0 else {
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private static func processEnvironment(pid: Int32) -> Bool? {
        guard let result = try? SystemTool.run(
            "/bin/ps",
            arguments: ["eww", "-p", "\(pid)", "-o", "command="],
            check: false
        ), result.status == 0 else {
            return nil
        }
        return result.stdout.contains("DYLD_INSERT_LIBRARIES=")
    }

    private static func processMappings(
        pid: Int32,
        runtimeDylib: URL,
        steamAPITargets: [URL]
    ) -> (runtimeLoaded: Bool?, steamAPIMappings: [String], error: String?) {
        guard let result = try? SystemTool.run(
            "/usr/bin/vmmap",
            arguments: ["\(pid)"],
            check: false
        ) else {
            return (nil, [], "Could not run vmmap")
        }
        guard result.status == 0 else {
            let error = result.combinedOutput.isEmpty
                ? "vmmap exited with code \(result.status)"
                : "vmmap exited with code \(result.status): \(result.combinedOutput)"
            return (nil, [], error)
        }

        let output = result.stdout
        let runtimeLoaded = output.contains(runtimeDylib.path)
            || output.contains(runtimeDylib.lastPathComponent)

        let targetPaths = Set(steamAPITargets.map(\.path))
        let targetNames = Set(steamAPITargets.map(\.lastPathComponent))
        var mappings: [String] = []
        var seen = Set<String>()
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let matchesPath = targetPaths.contains(where: { line.contains($0) })
            let matchesName = targetNames.contains(where: { line.contains($0) })
            if (matchesPath || matchesName), seen.insert(line).inserted {
                mappings.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return (runtimeLoaded, mappings, nil)
    }
}
