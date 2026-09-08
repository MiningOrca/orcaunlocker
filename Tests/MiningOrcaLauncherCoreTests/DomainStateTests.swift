import Foundation
import Testing
@testable import MiningOrcaLauncherCore

struct DomainStateTests {
    @Test
    func testTransportMapsToItsInstallationKind() {
        #expect(SteamTransport.proxy.installationKind == .proxy)
        #expect(SteamTransport.inject.installationKind == .inject)
    }

    @Test
    func testInjectFootprintPreservesExistingEvidenceSemantics() {
        #expect(!makeState().hasInjectFootprint)

        #expect(
            makeState(
                kind: .inject,
                transport: .inject,
                runtimeIdentity: .current(.production)
            ).hasInjectFootprint,
            "declared Inject transport is an Inject footprint"
        )
        #expect(
            makeState(injectDylibExists: true).hasInjectFootprint,
            "Inject dylib alone is an Inject footprint"
        )
        #expect(
            makeState(injectPrefixWrapperExists: true).hasInjectFootprint,
            "Inject prefix wrapper alone is an Inject footprint"
        )
        #expect(
            makeState(injectCommandWrapperExists: true).hasInjectFootprint,
            "Inject command wrapper alone is an Inject footprint"
        )
        #expect(
            makeState(launchOptionsHookCount: 1).hasInjectFootprint,
            "any inspected Launch Options hook is an Inject footprint"
        )
        #expect(
            !makeState(
                launchOptionsHookPresent: true,
                launchOptionsHookCount: 0
            ).hasInjectFootprint,
            "hook coverage boolean alone does not change the existing footprint predicate"
        )
    }

    @Test
    func testRuntimeMatchRequiresKindTransportAndRuntimeIdentity() {
        let proxyProduction = makeState(
            kind: .proxy,
            transport: .proxy,
            runtimeIdentity: .current(.production)
        )
        #expect(proxyProduction.matchesRuntime(transport: .proxy, profile: .production))
        #expect(!proxyProduction.matchesRuntime(transport: .proxy, profile: .debug))
        #expect(!proxyProduction.matchesRuntime(transport: .inject, profile: .production))

        #expect(
            !makeState(
                kind: .broken,
                transport: .proxy,
                runtimeIdentity: .current(.production)
            ).matchesRuntime(transport: .proxy, profile: .production),
            "matching transport/hash is insufficient when detector classified the target as broken"
        )
        #expect(
            !makeState(
                kind: .proxy,
                transport: .inject,
                runtimeIdentity: .current(.production)
            ).matchesRuntime(transport: .proxy, profile: .production),
            "transport must match independently of installation kind"
        )
        #expect(
            !makeState(
                kind: .proxy,
                transport: .proxy,
                runtimeIdentity: .other
            ).matchesRuntime(transport: .proxy, profile: .production),
            "older/unknown runtime identity is not the requested runtime"
        )

        let injectDebug = makeState(
            kind: .inject,
            transport: .inject,
            runtimeIdentity: .current(.debug)
        )
        #expect(injectDebug.matchesRuntime(transport: .inject, profile: .debug))
    }

    @Test
    func testGameStateAggregatesBrokenInjectAndUntouchedEvidence() {
        let empty = makeGameState([])
        #expect(!empty.hasBrokenState)
        #expect(!empty.hasInjectFootprint)
        #expect(!empty.isUntouchedAndPresent)

        let untouched = makeState(kind: .untouched, targetExists: true)
        let clean = makeGameState([untouched, untouched])
        #expect(!clean.hasBrokenState)
        #expect(!clean.hasInjectFootprint)
        #expect(clean.isUntouchedAndPresent)

        let missingTarget = makeGameState([
            untouched,
            makeState(kind: .untouched, targetExists: false),
        ])
        #expect(!missingTarget.isUntouchedAndPresent)

        let broken = makeGameState([
            untouched,
            makeState(kind: .broken, targetExists: true),
        ])
        #expect(broken.hasBrokenState)
        #expect(!broken.isUntouchedAndPresent)

        let injectLeftover = makeGameState([
            untouched,
            makeState(injectCommandWrapperExists: true),
        ])
        #expect(injectLeftover.hasInjectFootprint)
    }

    @Test
    func testGameRuntimeMatchRequiresAtLeastOneTargetAndEveryTargetToMatch() {
        #expect(!makeGameState([]).matchesRuntime(transport: .proxy, profile: .production))

        let matchingProxy = makeState(
            kind: .proxy,
            transport: .proxy,
            runtimeIdentity: .current(.production)
        )
        let allMatching = makeGameState([matchingProxy, matchingProxy])
        #expect(allMatching.matchesRuntime(transport: .proxy, profile: .production))

        let oneWrongProfile = makeGameState([
            matchingProxy,
            makeState(
                kind: .proxy,
                transport: .proxy,
                runtimeIdentity: .current(.debug)
            ),
        ])
        #expect(!oneWrongProfile.matchesRuntime(transport: .proxy, profile: .production))

        let oneBroken = makeGameState([
            matchingProxy,
            makeState(
                kind: .broken,
                transport: .proxy,
                runtimeIdentity: .current(.production)
            ),
        ])
        #expect(!oneBroken.matchesRuntime(transport: .proxy, profile: .production))
    }

    @Test
    func testGameStateRetainsKnownTargetURLsOnlyWhenRefreshOmitsThem() {
        let previousURLs = [
            URL(fileURLWithPath: "/tmp/game/a/libsteam_api.dylib"),
            URL(fileURLWithPath: "/tmp/game/b/libsteam_api.dylib"),
        ]
        let previous = makeGameState(
            [makeState(kind: .untouched)],
            recommendedTransport: .proxy,
            steamAPITargetURLs: previousURLs
        )

        let refreshedWithoutURLs = makeGameState(
            [
                makeState(
                    kind: .inject,
                    transport: .inject,
                    runtimeIdentity: .current(.production)
                ),
            ],
            recommendedTransport: .inject
        )
        let retained = refreshedWithoutURLs.retainingSteamAPITargetURLsIfEmpty(from: previous)
        #expect(retained.steamAPITargetURLs == previousURLs)
        #expect(retained.recommendedTransport == .inject)
        #expect(retained.states.count == 1)
        #expect(retained.states[0].kind == .inject)

        let refreshedURLs = [URL(fileURLWithPath: "/tmp/game/current/libsteam_api.dylib")]
        let refreshedWithURLs = makeGameState(
            [makeState(kind: .untouched)],
            recommendedTransport: .proxy,
            steamAPITargetURLs: refreshedURLs
        )
        let unchanged = refreshedWithURLs.retainingSteamAPITargetURLsIfEmpty(from: previous)
        #expect(unchanged.steamAPITargetURLs == refreshedURLs)
    }
}

private func makeGameState(
    _ states: [InstallationState],
    recommendedTransport: SteamTransport? = nil,
    steamAPITargetURLs: [URL] = []
) -> LauncherGameState {
    LauncherGameState(
        states: states,
        recommendedTransport: recommendedTransport,
        steamAPITargetURLs: steamAPITargetURLs
    )
}

private func makeState(
    kind: InstallationKind = .untouched,
    transport: SteamTransport? = nil,
    runtimeIdentity: InstalledRuntimeIdentity = .none,
    targetExists: Bool = true,
    originalSiblingExists: Bool = false,
    backupExists: Bool = false,
    injectDylibExists: Bool = false,
    injectPrefixWrapperExists: Bool = false,
    injectCommandWrapperExists: Bool = false,
    launchOptionsHookPresent: Bool? = nil,
    launchOptionsHookCount: Int? = nil,
    launchOptions: String? = nil,
    localConfigURL: URL? = nil,
    localConfigURLs: [URL] = [],
    configExists: Bool = false,
    logExists: Bool = false,
    dlcCatalogExists: Bool = false,
    issues: [String] = []
) -> InstallationState {
    InstallationState(
        kind: kind,
        transport: transport,
        runtimeIdentity: runtimeIdentity,
        targetExists: targetExists,
        originalSiblingExists: originalSiblingExists,
        backupExists: backupExists,
        injectDylibExists: injectDylibExists,
        injectPrefixWrapperExists: injectPrefixWrapperExists,
        injectCommandWrapperExists: injectCommandWrapperExists,
        launchOptionsHookPresent: launchOptionsHookPresent,
        launchOptionsHookCount: launchOptionsHookCount,
        launchOptions: launchOptions,
        localConfigURL: localConfigURL,
        localConfigURLs: localConfigURLs,
        configExists: configExists,
        logExists: logExists,
        dlcCatalogExists: dlcCatalogExists,
        issues: issues
    )
}
