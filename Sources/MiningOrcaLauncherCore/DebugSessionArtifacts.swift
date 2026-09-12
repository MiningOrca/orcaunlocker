import Darwin
import Foundation

enum DebugSessionArtifacts {
    /// Freeze the files that can disappear during cleanup. The archive itself is
    /// finalized only after cleanup so report.txt can include the cleanup result.
    static func capture(
        game: SteamGame,
        installLog: String,
        transport: SteamTransport,
        debugState: LauncherGameState,
        processObservations: [DebugProcessObservation],
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) throws -> DebugArtifactCapture {
        let cacheRoot = try fileSystem.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("MiningOrca", isDirectory: true)
        .appendingPathComponent("debug-sessions", isDirectory: true)

        try fileSystem.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let timestamp = archiveTimestamp(Date())
        let baseName = "MiningOrca-Diagnostics-\(game.appID)-\(timestamp)"
        let sessionName = uniqueSessionName(baseName, cacheRoot: cacheRoot, fileSystem: fileSystem)
        let directory = cacheRoot.appendingPathComponent(sessionName, isDirectory: true)
        let archiveURL = cacheRoot.appendingPathComponent("\(sessionName).zip", isDirectory: false)
        try fileSystem.createDirectory(at: directory, withIntermediateDirectories: false)

        do {
            let installLogURL = directory.appendingPathComponent("install.log", isDirectory: false)
            try writeRedacted(installLog, to: installLogURL, fileSystem: fileSystem)

            let gamePaths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
            let sourceLog = gamePaths.log
            try gamePaths.requireSafeRuntimePath(sourceLog, fileSystem: fileSystem)
            let capturedLog: URL?
            if fileSystem.fileExists(atPath: sourceLog.path) {
                let destination = directory.appendingPathComponent("runtime.log", isDirectory: false)
                try copyRedactedText(from: sourceLog, to: destination, fileSystem: fileSystem)
                capturedLog = destination
            } else {
                capturedLog = nil
            }

            let capturedEarlyRuntimeLog = try captureOptionalTextFile(
                source: gamePaths.earlyRuntimeLog,
                destinationName: "runtime-early.log",
                gamePaths: gamePaths,
                directory: directory,
                fileSystem: fileSystem
            )
            let capturedLaunchTrace = try captureOptionalTextFile(
                source: gamePaths.injectLaunchTrace,
                destinationName: "launch-trace.log",
                gamePaths: gamePaths,
                directory: directory,
                fileSystem: fileSystem
            )

            let capturedProcessTrace: URL?
            if processObservations.isEmpty {
                capturedProcessTrace = nil
            } else {
                let destination = directory.appendingPathComponent("processes.txt", isDirectory: false)
                try writeRedacted(
                    processTraceText(processObservations),
                    to: destination,
                    fileSystem: fileSystem
                )
                capturedProcessTrace = destination
            }

            let sourceConfig = gamePaths.config
            try gamePaths.requireSafeRuntimePath(sourceConfig, fileSystem: fileSystem)
            let capturedConfig: URL?
            if fileSystem.fileExists(atPath: sourceConfig.path) {
                let destination = directory.appendingPathComponent("orcaunlocker.conf", isDirectory: false)
                try copyRedactedText(from: sourceConfig, to: destination, fileSystem: fileSystem)
                capturedConfig = destination
            } else {
                capturedConfig = nil
            }

            let runtimeObservation = capturedLog.flatMap { DebugSessionArtifacts.runtimeObservation(from: $0, fileSystem: fileSystem) }
            let processObservation = bestProcessObservation(game: game, observations: processObservations)
            let observedArchitecture = runtimeObservation?.architecture ?? processObservation?.architecture
            let observedExecutable = runtimeObservation?.executable ?? processObservation?.executable
            let hardwareArchitecture = hardwareArchitecture()
            let launcherArchitecture = launcherArchitecture()
            let launcherTranslatedByRosetta = launcherTranslatedByRosetta()
            let runtimeArchitectures = debugRuntimeArchitectures(
                game: game,
                transport: transport,
                debugState: debugState,
                runtimeSettings: runtimeSettings,
                fileSystem: fileSystem
            )

            let systemURL = directory.appendingPathComponent("system.txt", isDirectory: false)
            try writeRedacted(
                systemText(
                    hardwareArchitecture: hardwareArchitecture,
                    launcherArchitecture: launcherArchitecture,
                    launcherTranslatedByRosetta: launcherTranslatedByRosetta,
                    runtimeObservation: RuntimeObservation(
                        architecture: observedArchitecture,
                        executable: observedExecutable
                    ),
                    processObservation: processObservation,
                    debugRuntimeArchitectures: runtimeArchitectures
                ),
                to: systemURL,
                fileSystem: fileSystem
            )

            let filesURL = directory.appendingPathComponent("files.txt", isDirectory: false)
            try writeRedacted(
                filesText(
                    game: game,
                    transport: transport,
                    debugState: debugState,
                    runtimeSettings: runtimeSettings,
                    fileSystem: fileSystem
                ),
                to: filesURL,
                fileSystem: fileSystem
            )

            let codesignURL = directory.appendingPathComponent("codesign.txt", isDirectory: false)
            try writeRedacted(
                codesignText(
                    game: game,
                    transport: transport,
                    debugState: debugState,
                    runtimeSettings: runtimeSettings,
                    fileSystem: fileSystem
                ),
                to: codesignURL,
                fileSystem: fileSystem
            )

            return DebugArtifactCapture(
                directory: directory,
                archiveURL: archiveURL,
                installLogURL: installLogURL,
                runtimeLogURL: capturedLog,
                earlyRuntimeLogURL: capturedEarlyRuntimeLog,
                launchTraceURL: capturedLaunchTrace,
                processTraceURL: capturedProcessTrace,
                configurationURL: capturedConfig,
                hardwareArchitecture: hardwareArchitecture,
                launcherArchitecture: launcherArchitecture,
                launcherTranslatedByRosetta: launcherTranslatedByRosetta,
                observedRuntimeArchitecture: observedArchitecture,
                observedExecutable: observedExecutable,
                observedProcessPID: processObservation?.pid,
                observedProcessPPID: processObservation?.ppid,
                observedTranslatedByRosetta: processObservation?.translatedByRosetta,
                observedRuntimeLoaded: processObservation?.runtimeLoaded,
                observedSteamAPIMappings: processObservation?.steamAPIMappings ?? [],
                debugRuntimeArchitectures: runtimeArchitectures
            )
        } catch {
            try? fileSystem.removeItem(at: archiveURL)
            try? fileSystem.removeItem(at: directory)
            throw error
        }
    }

    static func finalize(
        capture: DebugArtifactCapture,
        game: SteamGame,
        context: DebugReportContext,
        cleanupLog: String,
        fileSystem: FileSystem = .default
    ) throws -> DebugArtifactCapture {
        guard fileSystem.fileExists(atPath: capture.directory.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let cleanupLogURL = capture.directory.appendingPathComponent("cleanup.log", isDirectory: false)
        try writeRedacted(cleanupLog, to: cleanupLogURL, fileSystem: fileSystem)

        let reportURL = capture.directory.appendingPathComponent("report.txt", isDirectory: false)
        try writeRedacted(reportText(game: game, context: context, capture: capture), to: reportURL, fileSystem: fileSystem)

        let installationURL = capture.directory.appendingPathComponent("installation.json", isDirectory: false)
        try fileSystem.writeData(installationJSON(game: game, context: context, capture: capture), to: installationURL, options: .atomic)

        try fileSystem.removeItemIfExists(capture.archiveURL)
        _ = try SystemTool.run(
            "/usr/bin/ditto",
            arguments: [
                "-c",
                "-k",
                "--norsrc",
                "--noextattr",
                "--keepParent",
                capture.directory.path,
                capture.archiveURL.path,
            ]
        )

        // The ZIP is the durable report artifact. Keeping the staging tree around
        // only duplicates every report and makes Finder/cache cleanup noisy.
        try fileSystem.removeItem(at: capture.directory)
        return capture
    }

    private static func reportText(
        game: SteamGame,
        context: DebugReportContext,
        capture: DebugArtifactCapture
    ) -> String {
        let cleanupStatus: String
        if let cleanupError = context.cleanupError {
            cleanupStatus = "FAILED — \(cleanupError)"
        } else if context.cleanupRequiresSteamRepair {
            cleanupStatus = "Steam repair required"
        } else if let cleanupState = context.cleanupState,
                  cleanupState.isUntouchedAndPresent {
            cleanupStatus = "Clean state restored"
        } else {
            cleanupStatus = "Unknown"
        }

        var lines: [String] = [
            "MiningOrca Diagnostic Report",
            "",
            "Game",
            "  Name: \(game.name)",
            "  AppID: \(game.appID)",
            "  Install directory: \(game.installDirectory.path)",
            "",
            "Debug session",
            "  Started: \(isoTimestamp(context.startedAt))",
            "  Finished: \(isoTimestamp(context.finishedAt))",
            "  End reason: \(context.endReason)",
            "  Transport: \(context.transport.rawValue)",
            "  Runtime profile: debug",
            "  Steam API copies: \(context.debugState.steamAPICount)",
            "  Hardware architecture: \(capture.hardwareArchitecture)",
            "  Launcher architecture: \(capture.launcherArchitecture)",
            "  Launcher translated by Rosetta: \(yesNoUnknown(capture.launcherTranslatedByRosetta))",
            "  Observed game process architecture: \(capture.observedRuntimeArchitecture ?? "unknown")",
            "  Observed process PID: \(capture.observedProcessPID.map(String.init) ?? "unknown")",
            "  Observed process PPID: \(capture.observedProcessPPID.map(String.init) ?? "unknown")",
            "  Observed process translated by Rosetta: \(yesNoUnknown(capture.observedTranslatedByRosetta))",
            "  Debug runtime architectures: \(capture.debugRuntimeArchitectures.isEmpty ? "unknown" : capture.debugRuntimeArchitectures.joined(separator: ", "))",
        ]

        if let observedExecutable = capture.observedExecutable {
            lines.append("  Observed executable: \(observedExecutable)")
        }

        if context.transport == .inject {
            lines.append("  Inject wrapper invoked: \(capture.launchTraceURL == nil ? "no" : "yes")")
            lines.append("  orcaunlocker.dylib loaded in observed process: \(yesNoUnknown(capture.observedRuntimeLoaded))")
            lines.append("  Early runtime marker log: \(capture.earlyRuntimeLogURL == nil ? "no" : "yes")")
            let hookedAccounts = context.debugState.states.compactMap(\.launchOptionsHookCount).max() ?? 0
            let localConfigCount = context.debugState.states.map { $0.localConfigURLs.count }.max() ?? 0
            if localConfigCount > 0 {
                lines.append("  Steam Launch Options hooks: \(hookedAccounts)/\(localConfigCount)")
            }
        }

        if let sessionError = context.sessionError {
            lines.append("  Session error: \(sessionError)")
        }

        lines.append(contentsOf: [
            "",
            "Cleanup",
            "  Status: \(cleanupStatus)",
            "",
            "Included artifacts",
            "  install.log: yes",
            "  runtime.log: \(capture.runtimeLogURL == nil ? "no" : "yes")",
            "  runtime-early.log: \(capture.earlyRuntimeLogURL == nil ? "no" : "yes")",
            "  launch-trace.log: \(capture.launchTraceURL == nil ? "no" : "yes")",
            "  processes.txt: \(capture.processTraceURL == nil ? "no" : "yes")",
            "  orcaunlocker.conf: \(capture.configurationURL == nil ? "no" : "yes")",
            "  cleanup.log: yes",
            "  installation.json: yes",
            "  codesign.txt: yes",
            "  files.txt: yes",
            "  system.txt: yes",
            "",
            "Steam API copies during debug",
        ])

        for (index, target) in context.debugState.steamAPITargetURLs.enumerated() {
            let state = index < context.debugState.states.count ? context.debugState.states[index] : nil
            lines.append("  \(index + 1). \(target.path)")
            if let state {
                lines.append("     State: \(state.kind.rawValue), runtime=\(state.runtimeIdentity.displayText)")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func installationJSON(
        game: SteamGame,
        context: DebugReportContext,
        capture: DebugArtifactCapture
    ) throws -> Data {
        let payload: [String: Any] = [
            "schema_version": 2,
            "game": [
                "name": game.name,
                "app_id": game.appID,
                "install_directory": DiagnosticPrivacy.redact(game.installDirectory.path),
            ],
            "session": [
                "started_at": isoTimestamp(context.startedAt),
                "finished_at": isoTimestamp(context.finishedAt),
                "end_reason": context.endReason,
                "transport": context.transport.rawValue,
                "runtime_profile": "debug",
                "error": jsonValue(context.sessionError.map { DiagnosticPrivacy.redact($0) }),
            ],
            "environment": [
                "hardware_architecture": capture.hardwareArchitecture,
                "launcher_architecture": capture.launcherArchitecture,
                "launcher_translated_by_rosetta": jsonValue(capture.launcherTranslatedByRosetta),
                "observed_game_process_architecture": jsonValue(capture.observedRuntimeArchitecture),
                "observed_executable": jsonValue(capture.observedExecutable.map { DiagnosticPrivacy.redact($0) }),
                "observed_process_pid": jsonValue(capture.observedProcessPID),
                "observed_process_ppid": jsonValue(capture.observedProcessPPID),
                "observed_process_translated_by_rosetta": jsonValue(capture.observedTranslatedByRosetta),
                "observed_runtime_loaded": jsonValue(capture.observedRuntimeLoaded),
                "observed_steam_api_mappings": capture.observedSteamAPIMappings.map { DiagnosticPrivacy.redact($0) },
                "debug_runtime_architectures": capture.debugRuntimeArchitectures,
            ],
            "debug_installation": stateJSONObject(context.debugState),
            "cleanup": [
                "requires_steam_repair": context.cleanupRequiresSteamRepair,
                "error": jsonValue(context.cleanupError.map { DiagnosticPrivacy.redact($0) }),
                "installation": jsonValue(context.cleanupState.map(stateJSONObject)),
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private static func stateJSONObject(_ state: LauncherGameState) -> [String: Any] {
        let copies: [[String: Any]] = state.states.enumerated().map { index, installation in
            let targetPath = index < state.steamAPITargetURLs.count
                ? DiagnosticPrivacy.redact(state.steamAPITargetURLs[index].path)
                : "(unknown)"
            return [
                "target": targetPath,
                "kind": installation.kind.rawValue,
                "transport": jsonValue(installation.transport?.rawValue),
                "runtime": installation.runtimeIdentity.displayText,
                "target_exists": installation.targetExists,
                "original_sibling_exists": installation.originalSiblingExists,
                "backup_exists": installation.backupExists,
                "inject_dylib_exists": installation.injectDylibExists,
                "inject_prefix_wrapper_exists": installation.injectPrefixWrapperExists,
                "inject_command_wrapper_exists": installation.injectCommandWrapperExists,
                "launch_options_hook_present": jsonValue(installation.launchOptionsHookPresent),
                "launch_options_hook_count": jsonValue(installation.launchOptionsHookCount),
                "local_config_count": installation.localConfigURLs.count,
                "config_exists": installation.configExists,
                "log_exists": installation.logExists,
                "dlc_catalog_exists": installation.dlcCatalogExists,
                "issues": installation.issues.map { DiagnosticPrivacy.redact($0) },
            ]
        }
        return [
            "steam_api_count": state.steamAPICount,
            "recommended_transport": jsonValue(state.recommendedTransport?.rawValue),
            "copies": copies,
        ]
    }

    private static func jsonValue<T>(_ value: T?) -> Any {
        if let value {
            return value
        }
        return NSNull()
    }

    private static func captureOptionalTextFile(
        source: URL,
        destinationName: String,
        gamePaths: RuntimeGamePaths,
        directory: URL,
        fileSystem: FileSystem
    ) throws -> URL? {
        try gamePaths.requireSafeRuntimePath(source, fileSystem: fileSystem)
        guard fileSystem.fileExists(atPath: source.path) else { return nil }
        let destination = directory.appendingPathComponent(destinationName, isDirectory: false)
        try copyRedactedText(from: source, to: destination, fileSystem: fileSystem)
        return destination
    }

    private static func processTraceText(_ observations: [DebugProcessObservation]) -> String {
        var lines: [String] = []
        for observation in observations {
            lines.append("PID: \(observation.pid)")
            lines.append("PPID: \(observation.ppid)")
            lines.append("Command: \(observation.command)")
            lines.append("Executable: \(observation.executable ?? "unknown")")
            lines.append("Active architecture: \(observation.architecture ?? "unknown")")
            lines.append(
                "Binary architectures: \(observation.binaryArchitectures.isEmpty ? "unknown" : observation.binaryArchitectures.joined(separator: ", "))"
            )
            lines.append("Translated by Rosetta: \(yesNoUnknown(observation.translatedByRosetta))")
            lines.append("DYLD_INSERT_LIBRARIES present: \(yesNoUnknown(observation.dyldInsertLibrariesPresent))")
            lines.append("orcaunlocker.dylib mapped: \(yesNoUnknown(observation.runtimeLoaded))")
            if observation.steamAPIMappings.isEmpty {
                lines.append("Steam API mappings: none observed")
            } else {
                lines.append("Steam API mappings:")
                lines.append(contentsOf: observation.steamAPIMappings.map { "  \($0)" })
            }
            if let inspectionError = observation.inspectionError {
                lines.append("Inspection warning: \(inspectionError)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func bestProcessObservation(
        game: SteamGame,
        observations: [DebugProcessObservation]
    ) -> DebugProcessObservation? {
        let installPrefix = game.installDirectory.standardizedFileURL.path + "/"
        return observations.max { lhs, rhs in
            processScore(lhs, installPrefix: installPrefix) < processScore(rhs, installPrefix: installPrefix)
        }
    }

    private static func processScore(
        _ observation: DebugProcessObservation,
        installPrefix: String
    ) -> Int {
        var score = 0
        if observation.executable?.hasPrefix(installPrefix) == true { score += 8 }
        if !observation.steamAPIMappings.isEmpty { score += 4 }
        if observation.runtimeLoaded == true { score += 2 }
        if observation.architecture != nil { score += 1 }
        return score
    }

    private struct RuntimeObservation {
        let architecture: String?
        let executable: String?
    }

    private static func systemText(
        hardwareArchitecture: String,
        launcherArchitecture: String,
        launcherTranslatedByRosetta: Bool?,
        runtimeObservation: RuntimeObservation?,
        processObservation: DebugProcessObservation?,
        debugRuntimeArchitectures: [String]
    ) -> String {
        var sections: [String] = []
        sections.append("macOS\n\(toolOutput("/usr/bin/sw_vers", arguments: []))")
        sections.append("Hardware architecture\n\(hardwareArchitecture)")
        sections.append("Launcher architecture\n\(launcherArchitecture)")
        sections.append("Launcher translated by Rosetta\n\(yesNoUnknown(launcherTranslatedByRosetta))")
        sections.append("Observed game process architecture\n\(runtimeObservation?.architecture ?? "unknown")")
        if let executable = runtimeObservation?.executable {
            sections.append("Observed game executable\n\(executable)")
        }
        if let processObservation {
            sections.append("Observed PID / PPID\n\(processObservation.pid) / \(processObservation.ppid)")
            sections.append("Observed process translated by Rosetta\n\(yesNoUnknown(processObservation.translatedByRosetta))")
            sections.append("DYLD_INSERT_LIBRARIES visible in process environment\n\(yesNoUnknown(processObservation.dyldInsertLibrariesPresent))")
            sections.append("orcaunlocker.dylib mapped\n\(yesNoUnknown(processObservation.runtimeLoaded))")
            if !processObservation.steamAPIMappings.isEmpty {
                sections.append("Steam API mappings\n\(processObservation.steamAPIMappings.joined(separator: "\n"))")
            }
            if let inspectionError = processObservation.inspectionError {
                sections.append("Process inspection warning\n\(inspectionError)")
            }
        }
        sections.append(
            "Debug runtime architectures\n\(debugRuntimeArchitectures.isEmpty ? "unknown" : debugRuntimeArchitectures.joined(separator: ", "))"
        )
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func runtimeObservation(
        from logURL: URL,
        fileSystem: FileSystem
    ) -> RuntimeObservation? {
        guard let data = try? fileSystem.readData(from: logURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let loadedLine = text.split(whereSeparator: \.isNewline).first(where: { $0.contains("[orcaunlocker] loaded:") }) else {
            return nil
        }
        let line = String(loadedLine)
        return RuntimeObservation(
            architecture: field(named: "arch", in: line),
            executable: field(named: "executable", in: line, endingBefore: " accessor=")
        )
    }

    private static func field(
        named name: String,
        in line: String,
        endingBefore explicitTerminator: String? = nil
    ) -> String? {
        let marker = "\(name)="
        guard let markerRange = line.range(of: marker) else { return nil }
        let valueStart = markerRange.upperBound
        let valueEnd: String.Index
        if let explicitTerminator,
           let range = line.range(of: explicitTerminator, range: valueStart..<line.endIndex) {
            valueEnd = range.lowerBound
        } else if let space = line[valueStart...].firstIndex(of: " ") {
            valueEnd = space
        } else {
            valueEnd = line.endIndex
        }
        let value = line[valueStart..<valueEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func hardwareArchitecture() -> String {
        let arm64 = toolResult("/usr/sbin/sysctl", arguments: ["-in", "hw.optional.arm64"])
        if arm64.status == 0, arm64.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return "arm64"
        }
        let uname = toolResult("/usr/bin/uname", arguments: ["-m"])
        return uname.status == 0 && !uname.output.isEmpty ? uname.output : "unknown"
    }

    private static func launcherArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func launcherTranslatedByRosetta() -> Bool? {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        guard status == 0 else { return nil }
        return translated == 1
    }

    private static func yesNoUnknown(_ value: Bool?) -> String {
        switch value {
            case true?: return "yes"
            case false?: return "no"
            case nil: return "unknown"
        }
    }

    private static func debugRuntimeArchitectures(
        game: SteamGame,
        transport: SteamTransport,
        debugState: LauncherGameState,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem
    ) -> [String] {
        let urls: [URL]
        switch transport {
        case .proxy:
            urls = debugState.steamAPITargetURLs
        case .inject:
            urls = [RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings).injectDylib]
        }

        var seen = Set<String>()
        var architectures: [String] = []
        for url in uniqueURLs(urls) where fileSystem.fileExists(atPath: url.path) {
            let result = toolResult("/usr/bin/lipo", arguments: ["-archs", url.path])
            guard result.status == 0 else { continue }
            for architecture in result.output.split(whereSeparator: \.isWhitespace).map(String.init) {
                if seen.insert(architecture).inserted {
                    architectures.append(architecture)
                }
            }
        }
        return architectures
    }

    private static func filesText(
        game: SteamGame,
        transport: SteamTransport,
        debugState: LauncherGameState,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem
    ) -> String {
        let urls = diagnosticArtifactURLs(
            game: game,
            transport: transport,
            debugState: debugState,
            runtimeSettings: runtimeSettings
        )

        var lines: [String] = []
        for url in urls {
            lines.append("Path: \(url.path)")
            if fileSystem.fileExists(atPath: url.path) {
                lines.append("file: \(toolOutput("/usr/bin/file", arguments: [url.path]))")
                lines.append("sha256: \(toolOutput("/usr/bin/shasum", arguments: ["-a", "256", url.path]))")
            } else {
                lines.append("missing")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func codesignText(
        game: SteamGame,
        transport: SteamTransport,
        debugState: LauncherGameState,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem
    ) -> String {
        let urls = diagnosticCodeURLs(
            game: game,
            transport: transport,
            debugState: debugState,
            runtimeSettings: runtimeSettings
        )

        var lines: [String] = []
        for url in urls {
            lines.append("Path: \(url.path)")
            guard fileSystem.fileExists(atPath: url.path) else {
                lines.append("Status: missing")
                lines.append("")
                continue
            }
            let result = toolResult(
                "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "--all-architectures", "--verbose=4", url.path]
            )
            lines.append("Status: \(result.status == 0 ? "valid" : "invalid") (exit \(result.status))")
            if !result.output.isEmpty {
                lines.append(result.output)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func diagnosticArtifactURLs(
        game: SteamGame,
        transport: SteamTransport,
        debugState: LauncherGameState,
        runtimeSettings: LauncherSettings.Runtime
    ) -> [URL] {
        var urls = debugState.steamAPITargetURLs
        switch transport {
        case .proxy:
            for targetURL in debugState.steamAPITargetURLs {
                let target = SteamAPITarget(
                    url: targetURL,
                    gameDirectory: game.installDirectory
                )
                let paths = RuntimeTargetPaths(game: game, target: target, runtimeSettings: runtimeSettings)
                urls.append(paths.originalSibling)
                urls.append(paths.backup)
            }
        case .inject:
            let gamePaths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
            urls += gamePaths.injectRuntimeFiles + gamePaths.debugTraceFiles
        }
        return uniqueURLs(urls)
    }

    private static func diagnosticCodeURLs(
        game: SteamGame,
        transport: SteamTransport,
        debugState: LauncherGameState,
        runtimeSettings: LauncherSettings.Runtime
    ) -> [URL] {
        var urls = debugState.steamAPITargetURLs
        switch transport {
        case .proxy:
            for targetURL in debugState.steamAPITargetURLs {
                let target = SteamAPITarget(
                    url: targetURL,
                    gameDirectory: game.installDirectory
                )
                let paths = RuntimeTargetPaths(game: game, target: target, runtimeSettings: runtimeSettings)
                urls.append(paths.originalSibling)
                urls.append(paths.backup)
            }
        case .inject:
            urls.append(RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings).injectDylib)
        }
        return uniqueURLs(urls)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func toolOutput(_ executable: String, arguments: [String]) -> String {
        let result = toolResult(executable, arguments: arguments)
        if result.output.isEmpty {
            return "exit \(result.status)"
        }
        return "exit \(result.status)\n\(result.output)"
    }

    private static func toolResult(_ executable: String, arguments: [String]) -> (status: Int32, output: String) {
        do {
            let result = try SystemTool.run(executable, arguments: arguments, check: false)
            return (result.status, result.combinedOutput)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private static func uniqueSessionName(
        _ baseName: String,
        cacheRoot: URL,
        fileSystem: FileSystem
    ) -> String {
        let directory = cacheRoot.appendingPathComponent(baseName, isDirectory: true)
        let archive = cacheRoot.appendingPathComponent("\(baseName).zip", isDirectory: false)
        if !fileSystem.fileExists(atPath: directory.path),
           !fileSystem.fileExists(atPath: archive.path) {
            return baseName
        }
        return "\(baseName)-\(UUID().uuidString.prefix(8))"
    }

    private static func archiveTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func writeRedacted(
        _ text: String,
        to destination: URL,
        fileSystem: FileSystem
    ) throws {
        try fileSystem.writeData(
            Data(DiagnosticPrivacy.redact(text).utf8),
            to: destination,
            options: .atomic
        )
    }

    private static func copyRedactedText(
        from source: URL,
        to destination: URL,
        fileSystem: FileSystem
    ) throws {
        let data = try fileSystem.readData(from: source)
        let text = String(decoding: data, as: UTF8.self)
        try writeRedacted(text, to: destination, fileSystem: fileSystem)
    }

}
