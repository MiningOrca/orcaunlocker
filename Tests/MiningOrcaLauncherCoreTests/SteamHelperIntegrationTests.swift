import Foundation
import Testing
@testable import MiningOrcaLauncherCore

struct SteamHelperIntegrationTests {
    private let processBootstrap: Void = bootstrapTestProcess()

    @Test
    func testLocalConfigRoundTripAcrossMultipleAccounts() throws {
        let temporaryRoot = try makeTemporaryRoot("localconfig-roundtrip")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let helperExecutable = try rustHelperExecutable()
        let syntheticSteamRoot = temporaryRoot.appendingPathComponent("synthetic-steam", isDirectory: true)
        let accountOne = syntheticSteamRoot.appendingPathComponent("userdata/1/config/localconfig.vdf")
        let accountTwo = syntheticSteamRoot.appendingPathComponent("userdata/2/config/localconfig.vdf")
        let accountThree = syntheticSteamRoot.appendingPathComponent("userdata/3/config/localconfig.vdf")
        for account in [accountOne, accountTwo, accountThree] {
            try FileManager.default.createDirectory(
                at: account.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        try Self.accountOneOriginal.write(to: accountOne, atomically: true, encoding: .utf8)
        try Self.accountTwoOriginal.write(to: accountTwo, atomically: true, encoding: .utf8)
        try Self.accountThreeOriginal.write(to: accountThree, atomically: true, encoding: .utf8)

        let realHelper = SteamHelperClient(
            executableURL: helperExecutable,
            steamRootURL: syntheticSteamRoot
        )
        let beforeInstall = try realHelper.launchOptionsAll(appID: 281990)
        #expect(beforeInstall.accounts.count == 3, "Rust helper returns every Steam localconfig")
        let beforeByPath: [URL: String] = Dictionary(uniqueKeysWithValues: beforeInstall.accounts.map {
            ($0.localConfigURL.standardizedFileURL, $0.launchOptions)
        })
        #expect(beforeByPath[accountOne.standardizedFileURL] == "-novid", "Rust helper reads case-insensitive Steam VDF keys")
        #expect(beforeByPath[accountTwo.standardizedFileURL] == "", "Rust helper returns account without AppID")
        #expect(beforeByPath[accountThree.standardizedFileURL] == "-foo %command% -bar", "Rust helper reads existing command LaunchOptions")

        let runtimeSettings = try testRuntimeSettings()
        let gamePaths = RuntimeGamePaths(
            game: SteamGame(appID: 281990, name: "Synthetic", installDirectory: temporaryRoot),
            runtimeSettings: runtimeSettings
        )
        let prefixWrapper = gamePaths.injectPrefixWrapper
        let commandWrapper = gamePaths.injectCommandWrapper
        let multiAccountManager = SteamLaunchOptionsManager(
            helper: realHelper,
            steamSettings: try testSteamSettings()
        )
        let multiAccountResult = try multiAccountManager.installHook(
            appID: 281990,
            prefixWrapper: prefixWrapper,
            commandWrapper: commandWrapper,
            restartSteamIfRunning: false
        )
        #expect(multiAccountResult.modifiedLocalConfigs.count == 3, "Rust helper patches every discovered localconfig")

        let installedSnapshot = try multiAccountManager.inspect(appID: 281990)
        let installedCoverage = InjectLaunchOptions.hookCoverage(in: installedSnapshot, gamePaths: gamePaths)
        #expect(installedSnapshot.accounts.count == 3, "strict Inject inspection sees every Steam account")
        #expect(installedCoverage.hookedAccounts.count == 3, "strict Inject inspection counts every installed hook")
        #expect(installedCoverage.allExpectedConfigsHooked, "strict Inject postcondition accepts real helper 3/3 coverage")

        let installedByPath: [URL: String] = Dictionary(uniqueKeysWithValues: installedSnapshot.accounts.map {
            ($0.localConfigURL.standardizedFileURL, $0.launchOptions)
        })
        #expect(installedByPath[accountOne.standardizedFileURL]?.contains("run-prefix.sh") == true, "Inject uses prefix wrapper without pre-existing %command%")
        #expect(installedByPath[accountOne.standardizedFileURL]?.contains("-novid") == true, "Inject preserves existing ordinary LaunchOptions")
        #expect(installedByPath[accountTwo.standardizedFileURL]?.contains("run-prefix.sh") == true, "Inject creates missing AppID through Rust helper")
        #expect(installedByPath[accountThree.standardizedFileURL]?.contains("run-command.sh") == true, "Inject uses command wrapper around existing %command%")
        #expect(installedByPath[accountThree.standardizedFileURL]?.contains("-foo") == true, "Inject preserves text before existing %command%")
        #expect(installedByPath[accountThree.standardizedFileURL]?.contains("-bar") == true, "Inject preserves text after existing %command%")

        let accountOneInstalledText = try String(contentsOf: accountOne, encoding: .utf8)
        #expect(accountOneInstalledText.contains("\"userlocalconfigstore\""), "Rust surgical mutation preserves original key casing")
        let accountTwoInstalledText = try String(contentsOf: accountTwo, encoding: .utf8)
        #expect(accountTwoInstalledText.contains("\"999999\""), "Rust surgical mutation preserves unrelated app configuration")
        #expect(accountTwoInstalledText.contains("-safe"), "Rust surgical mutation preserves unrelated LaunchOptions")

        let removeResult = try multiAccountManager.removeHooks(
            appID: 281990,
            prefixWrapper: prefixWrapper,
            commandWrapper: commandWrapper,
            restartSteamIfRunning: false
        )
        #expect(removeResult.modifiedLocalConfigs.count == 3, "Rust helper removes hooks from every modified localconfig")
        let restoredSnapshot = try multiAccountManager.inspect(appID: 281990)
        let restoredByPath: [URL: String] = Dictionary(uniqueKeysWithValues: restoredSnapshot.accounts.map {
            ($0.localConfigURL.standardizedFileURL, $0.launchOptions)
        })
        #expect(restoredByPath[accountOne.standardizedFileURL] == "-novid", "Inject restore preserves original ordinary LaunchOptions")
        #expect(restoredByPath[accountTwo.standardizedFileURL] == "", "Inject restore removes hook from previously missing AppID")
        #expect(restoredByPath[accountThree.standardizedFileURL] == "-foo %command% -bar", "Inject restore reconstructs original command LaunchOptions")
        let accountTwoRestoredText = try String(contentsOf: accountTwo, encoding: .utf8)
        #expect(accountTwoRestoredText.contains("-safe"), "Inject restore preserves unrelated Steam configuration")
    }

    @Test
    func testLocalConfigTransactionRollsBackEarlierWrites() throws {
        let temporaryRoot = try makeTemporaryRoot("localconfig-rollback")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let rollbackSteamRoot = temporaryRoot.appendingPathComponent("rollback-steam", isDirectory: true)
        let rollbackOne = rollbackSteamRoot.appendingPathComponent("userdata/1/config/localconfig.vdf")
        let rollbackTwo = rollbackSteamRoot.appendingPathComponent("userdata/2/config/localconfig.vdf")
        try FileManager.default.createDirectory(at: rollbackOne.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rollbackTwo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.accountOneOriginal.write(to: rollbackOne, atomically: true, encoding: .utf8)
        try Self.accountOneOriginal.write(to: rollbackTwo, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: rollbackTwo.deletingLastPathComponent().path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: rollbackTwo.deletingLastPathComponent().path
            )
        }

        let rollbackHelper = SteamHelperClient(
            executableURL: try rustHelperExecutable(),
            steamRootURL: rollbackSteamRoot
        )
        do {
            _ = try rollbackHelper.installLaunchOptions(
                appID: 281990,
                prefixWrapper: temporaryRoot.appendingPathComponent(".orcaunlocker/run-prefix.sh"),
                commandWrapper: temporaryRoot.appendingPathComponent(".orcaunlocker/run-command.sh")
            )
            #expect(Bool(false), "Rust localconfig transaction fails when a later account cannot be replaced")
        } catch {
            #expect(
                error.localizedDescription.contains("could not create"),
                "Rust transaction test reaches the second-account write failure"
            )
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: rollbackTwo.deletingLastPathComponent().path
        )
        let rollbackOneAfter = try String(contentsOf: rollbackOne, encoding: .utf8)
        #expect(rollbackOneAfter == Self.accountOneOriginal, "Rust localconfig transaction rolls back an earlier account after later failure")
    }

    @Test
    func testLocalConfigRejectsParentSymlinkEscape() throws {
        let temporaryRoot = try makeTemporaryRoot("localconfig-symlink")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let unsafeSteamRoot = temporaryRoot.appendingPathComponent("unsafe-steam", isDirectory: true)
        let unsafeUser = unsafeSteamRoot.appendingPathComponent("userdata/1", isDirectory: true)
        let outsideConfig = temporaryRoot.appendingPathComponent("outside-steam-config", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeUser, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideConfig, withIntermediateDirectories: true)
        try Self.accountOneOriginal.write(
            to: outsideConfig.appendingPathComponent("localconfig.vdf"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: unsafeUser.appendingPathComponent("config", isDirectory: true),
            withDestinationURL: outsideConfig
        )
        let unsafeHelper = SteamHelperClient(
            executableURL: try rustHelperExecutable(),
            steamRootURL: unsafeSteamRoot
        )
        do {
            _ = try unsafeHelper.launchOptionsAll(appID: 281990)
            #expect(Bool(false), "Rust helper rejects localconfig parent symlink escape")
        } catch {
            #expect(
                error.localizedDescription.contains("outside userdata"),
                "Rust helper reports localconfig symlink escape"
            )
        }
    }

    @Test
    func testHookCoverageRequiresEveryExpectedConfig() throws {
        let gamePaths = RuntimeGamePaths(
            game: SteamGame(
                appID: 281990,
                name: "Synthetic",
                installDirectory: URL(fileURLWithPath: "/tmp/Game", isDirectory: true)
            ),
            runtimeSettings: try testRuntimeSettings()
        )
        let accountOne = URL(fileURLWithPath: "/tmp/account-one/localconfig.vdf")
        let accountTwo = URL(fileURLWithPath: "/tmp/account-two/localconfig.vdf")
        let partialHookSnapshot = SteamLaunchOptionsSnapshot(
            appID: 281990,
            accounts: [
                SteamLaunchOptionsAccount(
                    localConfigURL: accountOne,
                    launchOptions: #""/tmp/Game/.orcaunlocker/run-prefix.sh" %command%"#
                ),
                SteamLaunchOptionsAccount(localConfigURL: accountTwo, launchOptions: ""),
            ]
        )
        let partialHookCoverage = InjectLaunchOptions.hookCoverage(in: partialHookSnapshot, gamePaths: gamePaths)
        #expect(partialHookCoverage.anyHook, "Inject hook coverage detects a partial hook")
        #expect(partialHookCoverage.hookedAccounts.count == 1, "Inject hook coverage counts hooked accounts")
        #expect(partialHookCoverage.expectedLocalConfigURLs.count == 2, "Inject hook coverage counts every localconfig")
        #expect(!partialHookCoverage.allExpectedConfigsHooked, "Inject requires hooks in every localconfig")

        let completeHookSnapshot = SteamLaunchOptionsSnapshot(
            appID: 281990,
            accounts: [
                SteamLaunchOptionsAccount(
                    localConfigURL: accountOne,
                    launchOptions: #""/tmp/Game/.orcaunlocker/run-prefix.sh" %command%"#
                ),
                SteamLaunchOptionsAccount(
                    localConfigURL: accountTwo,
                    launchOptions: #""/tmp/Game/.orcaunlocker/run-prefix.sh" %command%"#
                ),
            ]
        )
        let completeHookCoverage = InjectLaunchOptions.hookCoverage(in: completeHookSnapshot, gamePaths: gamePaths)
        #expect(completeHookCoverage.allExpectedConfigsHooked, "Inject accepts hooks present in every localconfig")
    }

    @Test
    func testLaunchOptionsInspectionRetriesOnceAndLogsWarnings() throws {
        let temporaryRoot = try makeTemporaryRoot("launch-options-retry")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let accountOne = temporaryRoot.appendingPathComponent("account-one/localconfig.vdf")
        let accountTwo = temporaryRoot.appendingPathComponent("account-two/localconfig.vdf")
        let completeHookSnapshot = SteamLaunchOptionsSnapshot(
            appID: 281990,
            accounts: [
                SteamLaunchOptionsAccount(
                    localConfigURL: accountOne,
                    launchOptions: #""/tmp/Game/.orcaunlocker/run-prefix.sh" %command%"#
                ),
                SteamLaunchOptionsAccount(
                    localConfigURL: accountTwo,
                    launchOptions: #""/tmp/Game/.orcaunlocker/run-prefix.sh" %command%"#
                ),
            ]
        )

        let retrySnapshotURL = temporaryRoot.appendingPathComponent("launch-options.json")
        try JSONEncoder().encode(completeHookSnapshot).write(to: retrySnapshotURL)
        let retryCounterURL = temporaryRoot.appendingPathComponent("attempts")
        let retryHelper = temporaryRoot.appendingPathComponent("fake-steam-helper.sh")
        let quotedRetrySnapshot = "'" + retrySnapshotURL.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let quotedRetryCounter = "'" + retryCounterURL.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let retryHelperScript = """
        #!/bin/sh
        if [ ! -f \(quotedRetryCounter) ]; then
            echo 1 > \(quotedRetryCounter)
            echo "synthetic transient failure" >&2
            exit 1
        fi
        echo 2 > \(quotedRetryCounter)
        echo "synthetic helper warning" >&2
        cat \(quotedRetrySnapshot)
        """
        try retryHelperScript.write(to: retryHelper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: retryHelper.path)

        let retryClient = SteamHelperClient(executableURL: retryHelper)
        let retrySnapshot = try retryClient.launchOptionsAll(appID: 281990)
        #expect(retrySnapshot.appID == 281990, "LaunchOptions inspection succeeds after one retry")
        let retryAttempts = try String(contentsOf: retryCounterURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(retryAttempts == "2", "LaunchOptions inspection retries exactly once after failure")
        let retryWarnings = LauncherLogging.warningsAndErrors.filter {
            $0.file.hasSuffix("/SteamHelperClient.swift")
                && $0.message.contains("retrying in 5 seconds")
        }
        #expect(!retryWarnings.isEmpty, "swift-log collector captures warning with source file")
        let successfulHelperStderrWarnings = LauncherLogging.warningsAndErrors.filter {
            $0.file.hasSuffix("/SteamHelperClient.swift")
                && $0.message.contains("Steam helper wrote to stderr: synthetic helper warning")
        }
        #expect(
            !successfulHelperStderrWarnings.isEmpty,
            "successful Steam helper stderr is forwarded to swift-log"
        )
    }

    private static let accountOneOriginal = """
    "userlocalconfigstore"
    {
        "software"
        {
            "valve"
            {
                "steam"
                {
                    "apps"
                    {
                        "281990"
                        {
                            "launchoptions" "-novid"
                        }
                    }
                }
            }
        }
    }
    """

    private static let accountTwoOriginal = """
    "UserLocalConfigStore"
    {
        "Software"
        {
            "Valve"
            {
                "Steam"
                {
                    "Apps"
                    {
                        "999999"
                        {
                            "LaunchOptions" "-safe"
                        }
                    }
                }
            }
        }
    }
    """

    private static let accountThreeOriginal = """
    "UserLocalConfigStore"
    {
        "Software"
        {
            "Valve"
            {
                "Steam"
                {
                    "Apps"
                    {
                        "281990"
                        {
                            "LaunchOptions" "-foo %command% -bar"
                        }
                    }
                }
            }
        }
    }
    """
}
