import Foundation
import Testing
@testable import MiningOrcaLauncherCore

struct FileSystemAndRuntimeTests {
    private let processBootstrap: Void = bootstrapTestProcess()

    @Test
    func testConfigFileValidationPreservesExistingBytesAndMalformedSource() throws {
        let temporaryRoot = try makeTemporaryRoot("config-file")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let rawConfigGameRoot = temporaryRoot.appendingPathComponent("raw-config-game", isDirectory: true)
        try FileManager.default.createDirectory(at: rawConfigGameRoot, withIntermediateDirectories: true)
        let rawConfigGame = SteamGame(
            appID: 281990,
            name: "Raw Config Game",
            installDirectory: rawConfigGameRoot
        )
        let rawConfigFile = RuntimeConfigFile(runtimeSettings: try testRuntimeSettings())
        let validRawConfig = RuntimeConfigCodec.render(
            RuntimeConfig(appID: 281990, policy: RuntimePolicy(selection: .none))
        ) + "# custom tail comment\n[custom.future]\nanswer = 42\n"
        _ = try rawConfigFile.writeRawText(validRawConfig, for: rawConfigGame)
        let bytesBeforeRejectedSave = try Data(contentsOf: rawConfigFile.url(for: rawConfigGame))

        let invalidRawConfig = validRawConfig.replacingOccurrences(
            of: "purchase_time = valve",
            with: "purchase_time = yesterday"
        )
        do {
            _ = try rawConfigFile.writeRawText(invalidRawConfig, for: rawConfigGame)
            #expect(Bool(false), "invalid advanced Save is rejected")
        } catch let error as RuntimeConfigValidationError {
            #expect(error.key == "global.purchase_time", "rejected Save reports the invalid key")
        }
        let bytesAfterRejectedSave = try Data(contentsOf: rawConfigFile.url(for: rawConfigGame))
        #expect(bytesAfterRejectedSave == bytesBeforeRejectedSave, "validation failure leaves orcaunlocker.conf byte-for-byte untouched")

        // An externally malformed file must still be exposed to Advanced so the
        // user can repair it instead of losing the entire game-detail view.
        try invalidRawConfig.write(to: rawConfigFile.url(for: rawConfigGame), atomically: true, encoding: .utf8)
        let malformedSource = try rawConfigFile.source(for: rawConfigGame)
        #expect(malformedSource.text == invalidRawConfig, "malformed on-disk config remains available as raw text")
        #expect(malformedSource.configuration == nil, "malformed on-disk config does not produce a structured configuration")
        #expect(malformedSource.validationError?.key == "global.purchase_time", "malformed on-disk config exposes its validation error")
    }

    @Test
    func testMissingConfigDefaultsLauncherSelectionToAll() throws {
        let temporaryRoot = try makeTemporaryRoot("missing-config")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let game = SteamGame(
            appID: 281990,
            name: "Missing Config Game",
            installDirectory: temporaryRoot
        )
        let source = try RuntimeConfigFile(runtimeSettings: try testRuntimeSettings()).source(for: game)

        #expect(!source.fileExists, "missing config source remains marked as absent")
        #expect(source.configuration == nil, "missing config does not pretend to be persisted configuration")
        #expect(source.text.contains("launcher_selection = all"), "generated config defaults launcher_selection to all")
    }

    @Test
    func testArtworkResolvesNestedSteamLibraryCacheLayout() async throws {
        let temporaryRoot = try makeTemporaryRoot("artwork")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let syntheticSteamRoot = temporaryRoot.appendingPathComponent("steam", isDirectory: true)
        let syntheticLibraryCache = syntheticSteamRoot
            .appendingPathComponent("appcache/librarycache/281990/hash-a", isDirectory: true)
        let syntheticArtworkCache = temporaryRoot.appendingPathComponent("artwork-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: syntheticLibraryCache, withIntermediateDirectories: true)
        let syntheticHero = syntheticLibraryCache.appendingPathComponent("library_hero.jpg")
        try Data("hero".utf8).write(to: syntheticHero)
        let artworkService = SteamArtworkService(
            steamRootURL: syntheticSteamRoot,
            launcherCacheDirectory: syntheticArtworkCache,
            requestTimeout: 1,
            userAgent: "MiningOrcaTests"
        )
        let syntheticArtwork = await artworkService.cachedArtwork(for: 281990)
        #expect(
            syntheticArtwork.heroURL?.standardizedFileURL == syntheticHero.standardizedFileURL,
            "Steam artwork resolves nested content-hash librarycache layout"
        )
    }

    @Test
    func testPathSafetyRejectsSymlinkEscapesAndProtectedLeaves() throws {
        let temporaryRoot = try makeTemporaryRoot("path-safety")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathSafetyRoot = temporaryRoot.appendingPathComponent("path-safety", isDirectory: true)
        let realRoot = pathSafetyRoot.appendingPathComponent("real-root", isDirectory: true)
        let outsideRoot = pathSafetyRoot.appendingPathComponent("outside", isDirectory: true)
        let rootAlias = pathSafetyRoot.appendingPathComponent("root-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: realRoot)

        let missingRuntimeDirectory = realRoot.appendingPathComponent(".orcaunlocker", isDirectory: true)
        try PathSafety.requireNotSymbolicLink(missingRuntimeDirectory)

        let runtimePathGame = SteamGame(
            appID: 281990,
            name: "Runtime Path Game",
            installDirectory: realRoot
        )
        let runtimePaths = RuntimeGamePaths(game: runtimePathGame, runtimeSettings: try testRuntimeSettings())
        try runtimePaths.requireSafeRuntimePaths([runtimePaths.config, runtimePaths.log])

        do {
            try runtimePaths.requireSafeRuntimePath(outsideRoot.appendingPathComponent("outside-runtime"))
            #expect(Bool(false), "runtime path safety rejects paths outside the game install root")
        } catch PathSafetyError.outsideAllowedRoot {
            // Expected.
        }

        let safeMissingPath = rootAlias
            .appendingPathComponent(".orcaunlocker", isDirectory: true)
            .appendingPathComponent("orcaunlocker.conf", isDirectory: false)
        let resolvedSafeMissingPath = try PathSafety.requireInside(safeMissingPath, root: rootAlias)
        #expect(
            resolvedSafeMissingPath.path == realRoot.appendingPathComponent(".orcaunlocker/orcaunlocker.conf").path,
            "symlinked allowed root resolves before validating a not-yet-created child"
        )

        let escapedDirectory = realRoot.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escapedDirectory, withDestinationURL: outsideRoot)
        let escapedFile = outsideRoot.appendingPathComponent("payload")
        try Data("outside".utf8).write(to: escapedFile)
        do {
            _ = try PathSafety.requireInside(
                escapedDirectory.appendingPathComponent("payload"),
                root: realRoot
            )
            #expect(Bool(false), "symlink escape outside allowed root is rejected")
        } catch PathSafetyError.outsideAllowedRoot {
            // Expected.
        }

        let leafSymlink = realRoot.appendingPathComponent("leaf-link")
        try FileManager.default.createSymbolicLink(at: leafSymlink, withDestinationURL: escapedFile)
        do {
            try PathSafety.requireNotSymbolicLink(leafSymlink)
            #expect(Bool(false), "protected symlink leaf is rejected")
        } catch PathSafetyError.symbolicLink {
            // Expected.
        }

        let symlinkedConfigGameRoot = pathSafetyRoot.appendingPathComponent("config-game", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkedConfigGameRoot, withIntermediateDirectories: true)
        let symlinkedRuntimeDirectory = symlinkedConfigGameRoot.appendingPathComponent(".orcaunlocker", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkedRuntimeDirectory, withDestinationURL: outsideRoot)
        let symlinkedConfigGame = SteamGame(
            appID: 281990,
            name: "Symlinked Config Game",
            installDirectory: symlinkedConfigGameRoot
        )
        do {
            try RuntimeConfigFile(runtimeSettings: try testRuntimeSettings()).write(
                RuntimeConfig(appID: 281990, policy: RuntimePolicy(selection: .none)),
                for: symlinkedConfigGame
            )
            #expect(Bool(false), "runtime config write rejects a symlinked runtime directory")
        } catch PathSafetyError.symbolicLink {
            // Expected.
        }
    }

    @Test
    func testRuntimeLayoutSettingsLoadOverridesAndRejectNestedPaths() throws {
        let defaults = try testRuntimeSettings()
        #expect(defaults.installDirectoryName == ".orcaunlocker")
        #expect(defaults.configFileName == "orcaunlocker.conf")
        #expect(defaults.logFileName == "orcaunlocker.log")

        let temporaryRoot = try makeTemporaryRoot("runtime-layout-settings")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let overrideURL = temporaryRoot.appendingPathComponent("launcher-settings.json", isDirectory: false)
        let validOverride = """
        {
          "runtime": {
            "installDirectoryName": ".custom-runtime",
            "configFileName": "custom.conf",
            "logFileName": "custom.log"
          }
        }
        """
        try validOverride.write(to: overrideURL, atomically: true, encoding: .utf8)
        let loaded = try LauncherSettingsLoader.load(
            environment: ["MININGORCA_CONFIG": overrideURL.path]
        ).settings.runtime
        #expect(loaded.installDirectoryName == ".custom-runtime")
        #expect(loaded.configFileName == "custom.conf")
        #expect(loaded.logFileName == "custom.log")

        let invalidOverride = """
        {
          "runtime": {
            "installDirectoryName": "../escape"
          }
        }
        """
        try invalidOverride.write(to: overrideURL, atomically: true, encoding: .utf8)
        do {
            _ = try LauncherSettingsLoader.load(
                environment: ["MININGORCA_CONFIG": overrideURL.path]
            )
            #expect(Bool(false), "runtime layout settings reject nested path components")
        } catch let error as LauncherSettingsError {
            #expect(
                error.localizedDescription.contains("runtime.installDirectoryName"),
                "invalid runtime layout setting reports the failing key"
            )
        }
    }

    @Test
    func testAtomicReplacementCommitsOrPreservesLiveDestination() throws {
        let temporaryRoot = try makeTemporaryRoot("atomic-replace")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let atomicRoot = temporaryRoot.appendingPathComponent("atomic-replace", isDirectory: true)
        try FileManager.default.createDirectory(at: atomicRoot, withIntermediateDirectories: true)
        let atomicDestination = atomicRoot.appendingPathComponent("live")
        let atomicSource = atomicRoot.appendingPathComponent("staged")
        try Data("old".utf8).write(to: atomicDestination)
        try Data("new".utf8).write(to: atomicSource)
        try FileSystem.default.atomicReplace(atomicSource, atomicDestination)
        let atomicCommittedText = try String(contentsOf: atomicDestination, encoding: .utf8)
        #expect(atomicCommittedText == "new", "atomic replacement commits staged bytes")
        #expect(!FileManager.default.fileExists(atPath: atomicSource.path), "atomic replacement consumes the staged path")

        let missingAtomicSource = atomicRoot.appendingPathComponent("missing")
        do {
            try FileSystem.default.atomicReplace(missingAtomicSource, atomicDestination)
            #expect(Bool(false), "failed atomic replacement throws")
        } catch AtomicFileReplacementError.replaceFailed {
            // Expected.
        }
        let atomicPreservedText = try String(contentsOf: atomicDestination, encoding: .utf8)
        #expect(atomicPreservedText == "new", "failed atomic replacement preserves the live destination")
    }

    @Test
    func testConditionalFilesystemRemovalPrimitives() throws {
        let temporaryRoot = try makeTemporaryRoot("conditional-removal")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let fileSystem = FileSystem.default
        let missing = temporaryRoot.appendingPathComponent("missing")
        #expect(
            try !fileSystem.removeItemIfExists(missing),
            "conditional file removal reports an absent path without throwing"
        )

        let removableFile = temporaryRoot.appendingPathComponent("remove-me")
        try Data("payload".utf8).write(to: removableFile)
        #expect(
            try fileSystem.removeItemIfExists(removableFile),
            "conditional file removal reports a removed entry"
        )
        #expect(!FileManager.default.fileExists(atPath: removableFile.path))
        #expect(
            try !fileSystem.removeItemIfExists(removableFile),
            "conditional file removal remains idempotent after removal"
        )

        let emptyDirectory = temporaryRoot.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        #expect(
            try fileSystem.removeDirectoryIfEmpty(emptyDirectory),
            "empty directory removal reports a removed directory"
        )
        #expect(!FileManager.default.fileExists(atPath: emptyDirectory.path))

        let nonEmptyDirectory = temporaryRoot.appendingPathComponent("non-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: nonEmptyDirectory, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: nonEmptyDirectory.appendingPathComponent("file"))
        #expect(
            try !fileSystem.removeDirectoryIfEmpty(nonEmptyDirectory),
            "non-empty directories are preserved"
        )
        #expect(FileManager.default.fileExists(atPath: nonEmptyDirectory.path))

        let hiddenOnlyDirectory = temporaryRoot.appendingPathComponent("hidden-only", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenOnlyDirectory, withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: hiddenOnlyDirectory.appendingPathComponent(".keep"))
        #expect(
            try !fileSystem.removeDirectoryIfEmpty(hiddenOnlyDirectory),
            "hidden entries count as directory contents"
        )
        #expect(FileManager.default.fileExists(atPath: hiddenOnlyDirectory.path))
    }

    @Test
    func testRuntimeVerifierOwnsArtifactLookupAndProxyIdentification() throws {
        let temporaryRoot = try makeTemporaryRoot("runtime-verifier")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let artifact = RuntimeArtifact(
            file: "missing-proxy-debug.dylib",
            transport: .proxy,
            profile: .debug,
            architectures: ["arm64", "x86_64"],
            sha256: String(repeating: "a", count: 64)
        )
        let repository = RuntimeRepository(
            directory: temporaryRoot,
            manifest: RuntimeManifest(format: 1, artifacts: [artifact])
        )

        do {
            _ = try RuntimeVerifier().verify(
                transport: .proxy,
                profile: .debug,
                in: repository
            )
            #expect(Bool(false), "transport/profile verification resolves the requested artifact")
        } catch RuntimeRepositoryError.artifactFileMissing(let url) {
            #expect(
                url == temporaryRoot.appendingPathComponent(artifact.file),
                "transport/profile verification preserves the selected artifact's missing-file error"
            )
        }

        let ordinarySystemBinary = URL(fileURLWithPath: "/bin/ls", isDirectory: false)
        #expect(
            try !RuntimeVerifier.isProxy(ordinarySystemBinary),
            "Proxy identification does not classify an ordinary Mach-O executable as a Proxy runtime"
        )
    }

    @Test
    func testRuntimeManifestAndPathBoundaries() throws {
        let temporaryRoot = try makeTemporaryRoot("runtime-layout")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let syntheticHash = String(repeating: "a", count: 64)
        let runtimeDirectory = temporaryRoot.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        let runtimeManifest = RuntimeManifest(
            format: 1,
            artifacts: [
                RuntimeArtifact(file: "orcaunlocker-proxy.dylib", transport: .proxy, profile: .production, architectures: ["arm64", "x86_64"], sha256: syntheticHash),
                RuntimeArtifact(file: "orcaunlocker-proxy-debug.dylib", transport: .proxy, profile: .debug, architectures: ["x86_64", "arm64"], sha256: syntheticHash),
                RuntimeArtifact(file: "orcaunlocker-inject.dylib", transport: .inject, profile: .production, architectures: ["arm64", "x86_64"], sha256: syntheticHash),
                RuntimeArtifact(file: "orcaunlocker-inject-debug.dylib", transport: .inject, profile: .debug, architectures: ["x86_64", "arm64"], sha256: syntheticHash),
            ]
        )
        try RuntimeManifestCodec.validate(runtimeManifest)
        let manifestData = try JSONEncoder().encode(runtimeManifest)
        try manifestData.write(to: runtimeDirectory.appendingPathComponent(RuntimeRepository.manifestFileName))
        let runtimeRepository = try RuntimeRepository.load(from: runtimeDirectory)
        let proxyDebug = try runtimeRepository.artifact(transport: .proxy, profile: .debug)
        #expect(proxyDebug.file == "orcaunlocker-proxy-debug.dylib", "runtime manifest proxy/debug lookup")
        #expect(runtimeRepository.manifest.artifacts.count == 4, "runtime manifest contains four artifacts")

        let syntheticTargetURL = temporaryRoot.appendingPathComponent("libsteam_api.dylib")
        let syntheticTarget = SteamAPITarget(
            url: syntheticTargetURL,
            gameDirectory: temporaryRoot
        )
        let syntheticGame = SteamGame(appID: 281990, name: "Synthetic Stellaris", installDirectory: temporaryRoot)
        let gamePaths = RuntimeGamePaths(game: syntheticGame, runtimeSettings: try testRuntimeSettings())
        let paths = RuntimeTargetPaths(game: syntheticGame, target: syntheticTarget, runtimeSettings: try testRuntimeSettings())
        #expect(paths.backup.lastPathComponent == "libsteam_api.original", "Proxy backup filename")
        #expect(paths.backup.path.contains("/.orcaunlocker/backups/"), "Proxy backup is target-scoped")
        #expect(gamePaths.injectDylib.lastPathComponent == "orcaunlocker.dylib", "Inject dylib is game-level")
        #expect(RuntimeVerifier.injectInstallName == "@rpath/orcaunlocker.dylib", "Inject runtime install name matches the installed filename")

        var customRuntimeSettings = try testRuntimeSettings()
        customRuntimeSettings.installDirectoryName = ".custom-runtime"
        customRuntimeSettings.configFileName = "custom.conf"
        customRuntimeSettings.logFileName = "custom.log"
        let customGamePaths = RuntimeGamePaths(
            game: syntheticGame,
            runtimeSettings: customRuntimeSettings
        )
        #expect(customGamePaths.runtimeDirectory.lastPathComponent == ".custom-runtime")
        #expect(customGamePaths.config.lastPathComponent == "custom.conf")
        #expect(customGamePaths.log.lastPathComponent == "custom.log")
        #expect(customGamePaths.injectDylib.lastPathComponent == "orcaunlocker.dylib", "Inject dylib filename is not a layout setting")
        #expect(
            InjectLaunchOptions.containsHook(
                #""/moved/library/.custom-runtime/run-prefix.sh" %command%"#,
                gamePaths: customGamePaths
            ),
            "Inject hook detection follows the configured runtime directory after a game move"
        )
        #expect(
            gamePaths.injectRuntimeFiles == [
                gamePaths.injectDylib,
                gamePaths.injectPrefixWrapper,
                gamePaths.injectCommandWrapper,
            ],
            "Inject runtime footprint has one canonical game-level file group"
        )

        let secondTargetURL = temporaryRoot
            .appendingPathComponent("Nested/Game.app/Contents/MacOS", isDirectory: true)
            .appendingPathComponent("libsteam_api.dylib", isDirectory: false)
        let secondTarget = SteamAPITarget(
            url: secondTargetURL,
            gameDirectory: temporaryRoot
        )
        let secondPaths = RuntimeTargetPaths(game: syntheticGame, target: secondTarget, runtimeSettings: try testRuntimeSettings())
        #expect(paths.backup != secondPaths.backup, "multiple Steam API copies use distinct Proxy backups")
        #expect(paths.originalSibling.lastPathComponent == "libsteam_api_o.dylib", "Proxy original sibling path")
        #expect(paths.gamePaths.runtimeDirectory == secondPaths.gamePaths.runtimeDirectory, "targets share the same game-level runtime directory")
        #expect(
            paths.proxyStagingFiles == [
                paths.originalSiblingStaging,
                paths.proxyStaging,
                paths.restoreStaging,
            ],
            "Proxy temporary files have one canonical target-level staging group"
        )
        #expect(
            paths.proxyStagingFiles.allSatisfy { $0.deletingLastPathComponent() == syntheticTargetURL.deletingLastPathComponent() },
            "Proxy staging files remain beside their target for atomic replacement"
        )
        #expect(paths.originalSiblingStaging.lastPathComponent == ".libsteam_api_o.orcaunlocker.tmp")
        #expect(paths.proxyStaging.lastPathComponent == ".libsteam_api.orcaunlocker.tmp")
        #expect(paths.restoreStaging.lastPathComponent == ".libsteam_api.restore.orcaunlocker.tmp")
        #expect(
            InjectLaunchOptions.containsHook(
                "\"\(gamePaths.injectPrefixWrapper.path)\" %command% -foo",
                gamePaths: gamePaths
            ),
            "current inject LaunchOptions hook detection"
        )
        #expect(
            !InjectLaunchOptions.containsHook("-novid -windowed", gamePaths: gamePaths),
            "ordinary LaunchOptions are not treated as Inject hooks"
        )
        #expect(
            !InjectLaunchOptions.containsHook(
                #""/tmp/Game/.obsolete-runtime/inject/run.sh" %command%"#,
                gamePaths: gamePaths
            ),
            "obsolete in-game inject wrapper is not treated as an installed hook"
        )
        #expect(
            !InjectLaunchOptions.containsHook(
                #""/Users/test/Library/Application Support/obsolete-runtime/281990/inject/run.sh" %command%"#,
                gamePaths: gamePaths
            ),
            "obsolete Application Support inject wrapper is not treated as an installed hook"
        )
        #expect(
            !InjectLaunchOptions.containsHook(
                #""/tmp/tww3-wrapper.sh" %command%"#,
                gamePaths: gamePaths
            ),
            "obsolete TWW3 wrapper is not treated as an installed hook"
        )
    }

    @Test
    func testInstallationEvidenceUsesOnlyTargetScopedProxyBackup() throws {
        let temporaryRoot = try makeTemporaryRoot("target-scoped-proxy-backup")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let game = SteamGame(
            appID: 281990,
            name: "Target Scoped Backup Game",
            installDirectory: temporaryRoot
        )
        let target = SteamAPITarget(
            url: temporaryRoot.appendingPathComponent("libsteam_api.dylib", isDirectory: false),
            gameDirectory: temporaryRoot
        )
        let paths = RuntimeTargetPaths(game: game, target: target, runtimeSettings: try testRuntimeSettings())
        try FileManager.default.createDirectory(
            at: paths.gamePaths.runtimeDirectory,
            withIntermediateDirectories: true
        )
        let unscopedBackup = paths.gamePaths.runtimeDirectory
            .appendingPathComponent("libsteam_api.original", isDirectory: false)
        try Data("old-unscoped-backup".utf8).write(to: unscopedBackup)

        let detector = InstallationStateDetector(
            helper: SteamHelperClient(
                executableURL: temporaryRoot.appendingPathComponent("unused-helper", isDirectory: false)
            ),
            runtimeRepository: RuntimeRepository(
                directory: temporaryRoot,
                manifest: RuntimeManifest(format: 1, artifacts: [])
            ),
            runtimeSettings: try testRuntimeSettings()
        )

        #expect(
            !detector.targetEvidence(game: game, target: target).backupExists,
            "pre-multi-target game-level backup is ignored"
        )

        try FileManager.default.createDirectory(
            at: paths.backup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("target-scoped-backup".utf8).write(to: paths.backup)
        #expect(
            detector.targetEvidence(game: game, target: target).backupExists,
            "target-scoped Proxy backup is detected"
        )
    }

    @Test
    func testInstallationStateDetectorReusesGameEvidenceAcrossTargets() throws {
        let temporaryRoot = try makeTemporaryRoot("installation-game-evidence")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let gameRoot = temporaryRoot.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)

        let game = SteamGame(
            appID: 281990,
            name: "Evidence Game",
            installDirectory: gameRoot
        )
        let runtimeSettings = try testRuntimeSettings()
        let hookPath = RuntimeGamePaths(
            game: game,
            runtimeSettings: runtimeSettings
        ).injectPrefixWrapper.path

        let helperURL = temporaryRoot.appendingPathComponent("synthetic-helper.sh", isDirectory: false)
        let invocationCountURL = temporaryRoot.appendingPathComponent("launch-options-count", isDirectory: false)
        let helperScript = """
        #!/bin/sh
        count_file='\(invocationCountURL.path)'
        count=0
        if [ -f "$count_file" ]; then
            count=$(cat "$count_file")
        fi
        echo $((count + 1)) > "$count_file"
        printf '%s\n' '{"app_id":281990,"accounts":[{"localconfig":"/tmp/localconfig.vdf","launch_options":"\(hookPath) %command%"}]}'
        """
        try helperScript.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        let targets = ["a", "b"].map { component in
            SteamAPITarget(
                url: gameRoot
                    .appendingPathComponent(component, isDirectory: true)
                    .appendingPathComponent("libsteam_api.dylib", isDirectory: false),
                gameDirectory: gameRoot
            )
        }
        let detector = InstallationStateDetector(
            helper: SteamHelperClient(executableURL: helperURL),
            runtimeRepository: RuntimeRepository(
                directory: temporaryRoot,
                manifest: RuntimeManifest(format: 1, artifacts: [])
            ),
            runtimeSettings: runtimeSettings
        )

        let emptyStates = try detector.inspect(game: game, targets: [])
        #expect(emptyStates.isEmpty)
        let states = try detector.inspect(game: game, targets: targets)
        let invocationCount = try String(contentsOf: invocationCountURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(invocationCount == "1", "game-level Launch Options evidence is inspected once for all targets")
        #expect(states.count == 2)
        #expect(states.allSatisfy { $0.kind == .broken && !$0.targetExists })
        #expect(states.allSatisfy { $0.launchOptionsHookPresent == true })
        #expect(states.allSatisfy { $0.launchOptionsHookCount == 1 })
        #expect(states.allSatisfy { $0.localConfigURLs.count == 1 })
    }
}
