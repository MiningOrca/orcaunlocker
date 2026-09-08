import Foundation

enum DiagnosticsError: Error, LocalizedError {
    case configRequired(URL)

    var errorDescription: String? {
        switch self {
        case .configRequired(let url):
            return "Runtime configuration is required to switch diagnostic profile: \(url.path)"
        }
    }
}

package struct DiagnosticReport: Sendable {
    package let text: String

    init(text: String) {
        self.text = text
    }
}

package struct DiagnosticLogTail: Sendable {
    package let lines: [String]
    package let truncatedByBytes: Bool

    init(lines: [String], truncatedByBytes: Bool) {
        self.lines = lines
        self.truncatedByBytes = truncatedByBytes
    }
}

enum DiagnosticPrivacy {
    static func redact(
        _ text: String,
        homeDirectory: URL = FileSystem.default.homeDirectoryForCurrentUser
    ) -> String {
        var result = text
        let homePath = homeDirectory.standardizedFileURL.path
        if homePath != "/", !homePath.isEmpty {
            result = result.replacingOccurrences(of: homePath, with: "~")
        }

        // Steam account IDs are irrelevant to a bug report. Keep the path shape,
        // but do not expose the user's account-number directory.
        if let regex = try? NSRegularExpression(pattern: #"(?i)(/userdata/)\d+(?=/)"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1<account>"
            )
        }
        return result
    }
}

enum DiagnosticLogReader {
    static func tail(
        url: URL,
        lineLimit: Int,
        maxBytes: Int,
        fileSystem: FileSystem = .default
    ) throws -> DiagnosticLogTail {
        guard lineLimit > 0, maxBytes > 0,
              fileSystem.fileExists(atPath: url.path) else {
            return DiagnosticLogTail(lines: [], truncatedByBytes: false)
        }

        let tail = try fileSystem.readLastBytes(from: url, maxBytes: maxBytes)
        var text = String(decoding: tail.data, as: UTF8.self)

        if tail.truncated, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        return DiagnosticLogTail(
            lines: Array(lines.suffix(lineLimit)),
            truncatedByBytes: tail.truncated
        )
    }
}

struct DiagnosticsService {
    private let runtimeRepository: RuntimeRepository
    private let detector: InstallationStateDetector
    private let diagnosticsSettings: LauncherSettings.Diagnostics
    private let runtimeSettings: LauncherSettings.Runtime
    private let configFile: RuntimeConfigFile
    private let fileSystem: FileSystem

    init(
        runtimeRepository: RuntimeRepository,
        helper: SteamHelperClient,
        diagnosticsSettings: LauncherSettings.Diagnostics,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) {
        self.runtimeRepository = runtimeRepository
        self.diagnosticsSettings = diagnosticsSettings
        self.runtimeSettings = runtimeSettings
        self.fileSystem = fileSystem
        self.detector = InstallationStateDetector(
            helper: helper,
            runtimeRepository: runtimeRepository,
            runtimeSettings: runtimeSettings,
            fileSystem: fileSystem
        )
        self.configFile = RuntimeConfigFile(runtimeSettings: runtimeSettings, fileSystem: fileSystem)
    }

    func reports(
        game: SteamGame,
        targets: [SteamAPITarget],
        lineLimit: Int? = nil
    ) -> [DiagnosticReport] {
        guard !targets.isEmpty else { return [] }
        let targetSnapshots = targets.map { detector.targetEvidence(game: game, target: $0) }
        let gameSnapshot = detector.gameEvidence(for: game)
        return zip(targets, targetSnapshots).map { target, evidence in
            report(
                game: game,
                target: target,
                lineLimit: lineLimit,
                gameEvidence: gameSnapshot,
                targetEvidence: evidence
            )
        }
    }

    private func report(
        game: SteamGame,
        target: SteamAPITarget,
        lineLimit: Int?,
        gameEvidence: InstallationGameEvidence,
        targetEvidence: InstallationTargetEvidence
    ) -> DiagnosticReport {
        let requestedLines = max(1, lineLimit ?? diagnosticsSettings.logTailLines)
        var lines: [String] = [
            "MiningOrca diagnostic report",
            "Game: \(game.name) [\(game.appID)]",
            "Target: \(target.relativePath)",
            "Recommended transport: \(target.recommendedTransport.rawValue)",
            "Runtime manifest format: \(runtimeRepository.manifest.format)",
        ]

        do {
            let architectures = try BinaryInspector.architectureOutput(target.url)
            lines.append("Target architectures: \(architectures.isEmpty ? "unknown" : architectures)")
        } catch {
            lines.append("Target architectures: unavailable (\(error.localizedDescription))")
            LauncherLog.logger.warning(
                "Target architectures could not be inspected: \(error.localizedDescription)",
                metadata: ["app_id": "\(game.appID)"]
            )
        }

        let state: InstallationState?
        do {
            state = try detector.inspect(
                game: game,
                target: target,
                gameEvidence: gameEvidence,
                targetEvidence: targetEvidence
            )
        } catch {
            state = nil
            LauncherLog.logger.warning(
                "Installation state could not be inspected: \(error.localizedDescription)",
                metadata: ["app_id": "\(game.appID)"]
            )
        }

        if let state {
            lines += [
                "Installation: \(state.kind.rawValue)",
                "Transport: \(state.transport?.rawValue ?? "none")",
                "Runtime: \(state.runtimeIdentity.displayText)",
                "Original sibling: \(yesNo(state.originalSiblingExists))",
                "Backup: \(yesNo(state.backupExists))",
                "Inject dylib: \(yesNo(state.injectDylibExists))",
                "Inject prefix wrapper: \(yesNo(state.injectPrefixWrapperExists))",
                "Inject command wrapper: \(yesNo(state.injectCommandWrapperExists))",
                "Inject Launch Options: \(launchOptionsText(state))",
                "Config: \(yesNo(state.configExists))",
                "Log: \(yesNo(state.logExists))",
                "DLC catalog: \(yesNo(state.dlcCatalogExists))",
            ]
            if !state.issues.isEmpty {
                lines.append("Issues:")
                lines += state.issues.map { "  - \($0)" }
            }
        } else {
            lines += [
                "Installation: unavailable",
                "Transport: unavailable",
                "Runtime: unavailable",
            ]
        }

        let configURL = configFile.url(for: game)
        do {
            if let config = try configFile.read(for: game) {
                lines += [
                    "Selection: \(selectionText(config.policy.selection))",
                    "Global purchase time: \(config.policy.globalPurchaseTime.displayText)",
                    "DLC purchase time overrides: \(config.policy.dlcPurchaseTimes.count)",
                    "Language: \(config.policy.language ?? "valve")",
                    "Low violence: \(config.policy.lowViolence.map { $0 ? "true" : "false" } ?? "valve")",
                ]
            } else {
                lines.append("Selection: unavailable (no config)")
            }
        } catch {
            lines.append("Selection: unavailable (config unreadable: \(error.localizedDescription))")
            LauncherLog.logger.warning(
                "Runtime configuration could not be read at \(configURL.path): \(error.localizedDescription)",
                metadata: ["app_id": "\(game.appID)"]
            )
        }

        let gamePaths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let logURL = gamePaths.log
        do {
            try gamePaths.requireSafeRuntimePath(logURL, fileSystem: fileSystem)
            let tail = try DiagnosticLogReader.tail(
                url: logURL,
                lineLimit: requestedLines,
                maxBytes: diagnosticsSettings.maxLogBytes,
                fileSystem: fileSystem
            )
            lines.append("")
            lines.append("Log tail (last \(requestedLines) lines):")
            if tail.lines.isEmpty {
                lines.append("  (empty or unavailable)")
            } else {
                lines += tail.lines
            }
            if tail.truncatedByBytes {
                lines.append("  (tail limited to the last \(diagnosticsSettings.maxLogBytes) bytes)")
                LauncherLog.logger.warning(
                    "Runtime log tail was limited to the last \(diagnosticsSettings.maxLogBytes) bytes before selecting lines",
                    metadata: ["app_id": "\(game.appID)"]
                )
            }
        } catch {
            lines.append("")
            lines.append("Log tail: unavailable (\(error.localizedDescription))")
            LauncherLog.logger.warning(
                "Runtime log could not be read: \(error.localizedDescription)",
                metadata: ["app_id": "\(game.appID)"]
            )
        }

        let raw = lines.joined(separator: "\n") + "\n"
        return DiagnosticReport(text: DiagnosticPrivacy.redact(raw))
    }

    func logTail(
        game: SteamGame,
        lineLimit: Int? = nil
    ) throws -> DiagnosticLogTail {
        let gamePaths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let url = gamePaths.log
        try gamePaths.requireSafeRuntimePath(url, fileSystem: fileSystem)
        return try DiagnosticLogReader.tail(
            url: url,
            lineLimit: max(1, lineLimit ?? diagnosticsSettings.logTailLines),
            maxBytes: diagnosticsSettings.maxLogBytes,
            fileSystem: fileSystem
        )
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private func launchOptionsText(_ state: InstallationState) -> String {
        guard let present = state.launchOptionsHookPresent else { return "unknown" }
        if present {
            return "yes (\(state.launchOptionsHookCount ?? 0) account(s))"
        }
        if let hooked = state.launchOptionsHookCount, hooked > 0, !state.localConfigURLs.isEmpty {
            return "partial (\(hooked)/\(state.localConfigURLs.count) account(s))"
        }
        return "no"
    }

    private func selectionText(_ selection: DLCSelection) -> String {
        switch selection {
        case .all:
            return "all current and future DLC"
        case .none:
            return "Valve behavior"
        case .explicit(let ids):
            return "explicit, \(ids.count) current DLC ID(s)"
        }
    }
}
