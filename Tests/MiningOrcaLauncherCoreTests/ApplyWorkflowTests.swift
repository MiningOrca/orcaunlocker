import Foundation
import Testing
@testable import MiningOrcaLauncherCore

struct ApplyWorkflowTests {
    private let processBootstrap: Void = bootstrapTestProcess()

    @Test
    func testCurrentInjectWorkflowUsesGameStateWithoutReinspectingTargets() throws {
        let temporaryRoot = try makeTemporaryRoot("apply-workflow-current-inject")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let firstTargetURL = temporaryRoot.appendingPathComponent("Frameworks/libsteam_api.dylib")
        let secondTargetURL = temporaryRoot.appendingPathComponent("Plugins/libsteam_api.dylib")
        try FileManager.default.createDirectory(
            at: firstTargetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondTargetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: firstTargetURL)
        try Data().write(to: secondTargetURL)

        let game = SteamGame(
            appID: 281990,
            name: "Synthetic Stellaris",
            installDirectory: temporaryRoot
        )
        let targets = [firstTargetURL, secondTargetURL].map {
            SteamAPITarget(url: $0, gameDirectory: temporaryRoot)
        }
        let currentInject = InstallationState(
            kind: .inject,
            transport: .inject,
            runtimeIdentity: .current(.production),
            targetExists: true,
            originalSiblingExists: false,
            backupExists: false,
            injectDylibExists: true,
            injectPrefixWrapperExists: true,
            injectCommandWrapperExists: true,
            launchOptionsHookPresent: true,
            launchOptionsHookCount: 1,
            launchOptions: nil,
            localConfigURL: nil,
            localConfigURLs: [],
            configExists: false,
            logExists: false,
            dlcCatalogExists: false,
            issues: []
        )
        let before = LauncherGameState(
            states: [currentInject, currentInject],
            recommendedTransport: .inject,
            steamAPITargetURLs: targets.map(\.url)
        )
        let policy = RuntimePolicy(selection: .all)
        let request = ApplyRequest(
            transport: .inject,
            profile: .production,
            policy: policy
        )
        let repository = RuntimeRepository(
            directory: temporaryRoot.appendingPathComponent("runtime", isDirectory: true),
            manifest: RuntimeManifest(format: 1, artifacts: [])
        )
        let workflow = ApplyWorkflow(
            runtimeRepository: repository,
            helper: SteamHelperClient(
                executableURL: temporaryRoot.appendingPathComponent("missing-helper")
            ),
            steamSettings: LauncherSettings.Steam(
                restartTimeoutSeconds: 1,
                restartPollIntervalSeconds: 0.01
            ),
            runtimeSettings: try testRuntimeSettings()
        )

        try workflow.apply(
            game: game,
            targets: targets,
            before: before,
            request: request
        )

        let written = try RuntimeConfigFile(runtimeSettings: try testRuntimeSettings()).read(for: game)
        #expect(written?.appID == game.appID)
        #expect(written?.policy == policy)
    }
}
