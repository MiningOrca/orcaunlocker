import Foundation

struct InjectInstallResult: Sendable {
    let profile: RuntimeProfile
    let dylib: URL
    let prefixWrapper: URL
    let commandWrapper: URL
    let modifiedLocalConfigs: [URL]
    let steamWasRunning: Bool
    let steamRestarted: Bool
}

struct InjectRestoreResult: Sendable {
    let restored: Bool
    let modifiedLocalConfigs: [URL]
    let steamWasRunning: Bool
    let steamRestarted: Bool
}

struct InjectTransportCleaner {
    private let launchOptions: SteamLaunchOptionsManager
    private let runtimeSettings: LauncherSettings.Runtime
    private let fileSystem: FileSystem

    init(
        helper: SteamHelperClient,
        steamSettings: LauncherSettings.Steam,
        runtimeSettings: LauncherSettings.Runtime,
        fileSystem: FileSystem = .default
    ) {
        self.launchOptions = SteamLaunchOptionsManager(
            helper: helper,
            steamSettings: steamSettings
        )
        self.runtimeSettings = runtimeSettings
        self.fileSystem = fileSystem
    }

    func restore(
        game: SteamGame,
        restartSteamIfRunning: Bool
    ) throws -> InjectRestoreResult {
        LauncherLog.logger.info(
            "Restoring Inject installation",
            metadata: ["app_id": "\(game.appID)"]
        )
        let paths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)
        let removableFiles = paths.injectRuntimeFiles + paths.debugTraceFiles
        try paths.requireSafeRuntimePaths(
            removableFiles,
            fileSystem: fileSystem
        )
        let launchResult = try launchOptions.removeHooks(
            appID: game.appID,
            prefixWrapper: paths.injectPrefixWrapper,
            commandWrapper: paths.injectCommandWrapper,
            restartSteamIfRunning: restartSteamIfRunning
        )

        var removedFiles = false
        for url in removableFiles {
            removedFiles = try fileSystem.removeItemIfExists(url) || removedFiles
        }
        try fileSystem.removeDirectoryIfEmpty(paths.runtimeDirectory)

        let restored = removedFiles || !launchResult.modifiedLocalConfigs.isEmpty
        LauncherLog.logger.info(
            restored ? "Inject restore complete" : "No Inject installation found; restore is not required",
            metadata: ["app_id": "\(game.appID)"]
        )
        return InjectRestoreResult(
            restored: restored,
            modifiedLocalConfigs: launchResult.modifiedLocalConfigs,
            steamWasRunning: launchResult.steamWasRunning,
            steamRestarted: launchResult.steamRestarted
        )
    }
}

struct InjectInstaller {
    private let runtimeRepository: RuntimeRepository
    private let runtimeVerifier: RuntimeVerifier
    private let codeSigning: CodeSigningService
    private let quarantine: QuarantineService
    private let launchOptions: SteamLaunchOptionsManager
    private let cleaner: InjectTransportCleaner
    private let runtimeSettings: LauncherSettings.Runtime
    private let fileSystem: FileSystem

    init(
        runtimeRepository: RuntimeRepository,
        helper: SteamHelperClient,
        steamSettings: LauncherSettings.Steam,
        runtimeSettings: LauncherSettings.Runtime,
        runtimeVerifier: RuntimeVerifier = RuntimeVerifier(),
        codeSigning: CodeSigningService = CodeSigningService(),
        quarantine: QuarantineService = QuarantineService(),
        fileSystem: FileSystem = .default
    ) {
        self.runtimeRepository = runtimeRepository
        self.runtimeVerifier = runtimeVerifier
        self.codeSigning = codeSigning
        self.quarantine = quarantine
        self.launchOptions = SteamLaunchOptionsManager(
            helper: helper,
            steamSettings: steamSettings
        )
        self.cleaner = InjectTransportCleaner(
            helper: helper,
            steamSettings: steamSettings,
            runtimeSettings: runtimeSettings,
            fileSystem: fileSystem
        )
        self.runtimeSettings = runtimeSettings
        self.fileSystem = fileSystem
    }

    func install(
        game: SteamGame,
        profile: RuntimeProfile,
        restartSteamIfRunning: Bool
    ) throws -> InjectInstallResult {
        LauncherLog.logger.info(
            "Installing game-level Inject runtime",
            metadata: [
                "app_id": "\(game.appID)",
                "profile": "\(profile.rawValue)",
            ]
        )
        let gamePaths = RuntimeGamePaths(game: game, runtimeSettings: runtimeSettings)

        // Re-verify the destination runtime immediately before mutating the
        // game-level Inject files. LauncherCore has already preflighted the full
        // game before the workflow restores any Proxy targets.
        let verifiedRuntime: RuntimeArtifactVerification
        do {
            verifiedRuntime = try runtimeVerifier.verify(
                transport: .inject,
                profile: profile,
                in: runtimeRepository
            )
        } catch {
            LauncherLog.logger.error(
                "Inject runtime preflight verification failed: \(error.localizedDescription)",
                metadata: ["app_id": "\(game.appID)"]
            )
            throw error
        }
        LauncherLog.logger.info(
            "Inject runtime preflight verification passed",
            metadata: ["app_id": "\(game.appID)"]
        )

        try gamePaths.requireSafeRuntimePaths(
            gamePaths.injectRuntimeFiles,
            fileSystem: fileSystem
        )

        try fileSystem.createDirectory(
            at: gamePaths.runtimeDirectory,
            withIntermediateDirectories: true
        )

        // Prepare every runtime file before touching its live path. Each staged
        // file lives beside its destination, so rename(2) can commit it atomically.
        // A preparation failure therefore leaves an existing Inject install intact.
        LauncherLog.logger.info(
            "Preparing Inject runtime files",
            metadata: ["app_id": "\(game.appID)"]
        )
        let stagedDylib = stagingURL(for: gamePaths.injectDylib)
        let stagedPrefixWrapper = stagingURL(for: gamePaths.injectPrefixWrapper)
        let stagedCommandWrapper = stagingURL(for: gamePaths.injectCommandWrapper)
        let stagedFiles = [stagedDylib, stagedPrefixWrapper, stagedCommandWrapper]
        defer {
            for url in stagedFiles {
                try? fileSystem.removeItem(at: url)
            }
        }

        try fileSystem.copyItem(at: verifiedRuntime.fileURL, to: stagedDylib)
        let quarantineRemoved = try quarantine.removeIfPresent(from: stagedDylib)
        if quarantineRemoved {
            LauncherLog.logger.info(
                "Removed quarantine from staged Inject runtime",
                metadata: ["app_id": "\(game.appID)"]
            )
        }
        try codeSigning.verify(stagedDylib)
        try writeWrapper(
            stagedPrefixWrapper,
            dylib: gamePaths.injectDylib,
            launchTrace: gamePaths.injectLaunchTrace,
            earlyRuntimeLog: gamePaths.earlyRuntimeLog,
            diagnosticsEnabled: profile == .debug
        )
        try writeWrapper(
            stagedCommandWrapper,
            dylib: gamePaths.injectDylib,
            launchTrace: gamePaths.injectLaunchTrace,
            earlyRuntimeLog: gamePaths.earlyRuntimeLog,
            diagnosticsEnabled: profile == .debug
        )

        LauncherLog.logger.info(
            "Committing Inject runtime files",
            metadata: ["app_id": "\(game.appID)"]
        )
        try fileSystem.atomicReplace(stagedDylib, gamePaths.injectDylib)
        try fileSystem.atomicReplace(stagedPrefixWrapper, gamePaths.injectPrefixWrapper)
        try fileSystem.atomicReplace(stagedCommandWrapper, gamePaths.injectCommandWrapper)

        do {
            LauncherLog.logger.info(
                "Updating Steam Launch Options",
                metadata: ["app_id": "\(game.appID)"]
            )
            let launchResult = try launchOptions.installHook(
                appID: game.appID,
                prefixWrapper: gamePaths.injectPrefixWrapper,
                commandWrapper: gamePaths.injectCommandWrapper,
                restartSteamIfRunning: restartSteamIfRunning
            )
            LauncherLog.logger.info(
                "Inject installation complete",
                metadata: [
                    "app_id": "\(game.appID)",
                    "profile": "\(profile.rawValue)",
                    "accounts_modified": "\(launchResult.modifiedLocalConfigs.count)",
                ]
            )
            return InjectInstallResult(
                profile: profile,
                dylib: gamePaths.injectDylib,
                prefixWrapper: gamePaths.injectPrefixWrapper,
                commandWrapper: gamePaths.injectCommandWrapper,
                modifiedLocalConfigs: launchResult.modifiedLocalConfigs,
                steamWasRunning: launchResult.steamWasRunning,
                steamRestarted: launchResult.steamRestarted
            )
        } catch {
            LauncherLog.logger.error(
                "Inject Launch Options update failed; removing installed Inject files: \(error.localizedDescription)",
                metadata: ["app_id": "\(game.appID)"]
            )
            // LaunchOptions updates are transactional. If they fail, no account is
            // left partially patched, so remove the staged Inject files too.
            for url in gamePaths.injectRuntimeFiles {
                try? fileSystem.removeItem(at: url)
            }
            _ = try? fileSystem.removeDirectoryIfEmpty(gamePaths.runtimeDirectory)
            throw error
        }
    }

    func restore(
        game: SteamGame,
        restartSteamIfRunning: Bool
    ) throws -> InjectRestoreResult {
        try cleaner.restore(
            game: game,
            restartSteamIfRunning: restartSteamIfRunning
        )
    }

    private func writeWrapper(
        _ url: URL,
        dylib: URL,
        launchTrace: URL,
        earlyRuntimeLog: URL,
        diagnosticsEnabled: Bool
    ) throws {
        let quotedDylib = shellSingleQuote(dylib.path)
        let diagnosticPrelude: String

        if diagnosticsEnabled {
            let quotedLaunchTrace = shellSingleQuote(launchTrace.path)
            let quotedEarlyRuntimeLog = shellSingleQuote(earlyRuntimeLog.path)
            diagnosticPrelude = """
LAUNCH_TRACE=\(quotedLaunchTrace)
EARLY_RUNTIME_LOG=\(quotedEarlyRuntimeLog)

{
    printf '%s\\n' '--- wrapper invocation ---'
    printf 'timestamp=%s\\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'wrapper=%q\\n' "$0"
    printf 'pid=%s\\n' "$$"
    printf 'ppid=%s\\n' "$PPID"
    printf 'cwd=%q\\n' "$PWD"
    printf 'argv_count=%s\\n' "$#"
    ARG_INDEX=0
    for ARG_VALUE in "$@"; do
        printf 'argv[%d]=%q\\n' "$ARG_INDEX" "$ARG_VALUE"
        ARG_INDEX=$((ARG_INDEX + 1))
    done
    printf 'DYLD_INSERT_LIBRARIES_before=%q\\n' "${DYLD_INSERT_LIBRARIES:-}"
} >> "$LAUNCH_TRACE" 2>&1 || true
"""
        } else {
            diagnosticPrelude = ""
        }

        let script = """
#!/bin/bash
set -euo pipefail

TRACE_DYLIB=\(quotedDylib)
\(diagnosticPrelude)
if [ "$#" -lt 1 ]; then
    echo "[orcaunlocker] ERROR: Steam did not pass %command%" >&2
    exit 64
fi

LAUNCH_TARGET="$1"
shift

DYLD_VALUE="$TRACE_DYLIB"
if [ -n "${DYLD_INSERT_LIBRARIES:-}" ]; then
    DYLD_VALUE="$TRACE_DYLIB:$DYLD_INSERT_LIBRARIES"
fi

if [ -n "${LAUNCH_TRACE:-}" ]; then
    {
        printf 'launch_target=%q\\n' "$LAUNCH_TARGET"
        printf 'DYLD_INSERT_LIBRARIES_after=%q\\n' "$DYLD_VALUE"
    } >> "$LAUNCH_TRACE" 2>&1 || true
fi

if [ -d "$LAUNCH_TARGET" ] && [[ "$LAUNCH_TARGET" == *.app ]]; then
    if [ -n "${LAUNCH_TRACE:-}" ]; then
        BUNDLE_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$LAUNCH_TARGET/Contents/Info.plist" 2>/dev/null || true)"
        {
            printf '%s\\n' 'launch_kind=app_bundle'
            if [ -n "$BUNDLE_EXECUTABLE" ]; then
                printf 'resolved_executable=%q\\n' "$LAUNCH_TARGET/Contents/MacOS/$BUNDLE_EXECUTABLE"
            else
                printf '%s\\n' 'resolved_executable=(unknown)'
            fi
        } >> "$LAUNCH_TRACE" 2>&1 || true
    fi

    if [ -n "${EARLY_RUNTIME_LOG:-}" ]; then
        exec /usr/bin/open -W --env "DYLD_INSERT_LIBRARIES=$DYLD_VALUE" --env "ORCAUNLOCKER_EARLY_LOG=$EARLY_RUNTIME_LOG" "$LAUNCH_TARGET" --args "$@"
    fi
    exec /usr/bin/open -W --env "DYLD_INSERT_LIBRARIES=$DYLD_VALUE" "$LAUNCH_TARGET" --args "$@"
fi

if [ ! -f "$LAUNCH_TARGET" ]; then
    echo "[orcaunlocker] ERROR: executable not found: $LAUNCH_TARGET" >&2
    exit 66
fi

if [ -n "${LAUNCH_TRACE:-}" ]; then
    {
        printf '%s\\n' 'launch_kind=executable'
        printf 'resolved_executable=%q\\n' "$LAUNCH_TARGET"
    } >> "$LAUNCH_TRACE" 2>&1 || true
fi

export DYLD_INSERT_LIBRARIES="$DYLD_VALUE"
if [ -n "${EARLY_RUNTIME_LOG:-}" ]; then
    export ORCAUNLOCKER_EARLY_LOG="$EARLY_RUNTIME_LOG"
fi
cd "$(dirname "$LAUNCH_TARGET")"
exec "$LAUNCH_TARGET" "$@"
"""
        try fileSystem.writeData(Data(script.utf8), to: url)
        try fileSystem.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).miningorca.\(UUID().uuidString).tmp",
            isDirectory: false
        )
    }

    private func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
