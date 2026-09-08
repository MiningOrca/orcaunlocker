import Foundation
import Testing
@testable import MiningOrcaLauncherCore

struct ModelsAndConfigTests {
    private let processBootstrap: Void = bootstrapTestProcess()

    @Test
    func testHelperModelsAndLauncherErrors() throws {
        let helperGameJSON = Data(#"{"app_id":281990,"name":"Synthetic Stellaris","install_dir":"/tmp/MiningOrca Synthetic/Stellaris"}"#.utf8)
        let decodedGame = try JSONDecoder().decode(SteamGame.self, from: helperGameJSON)
        #expect(decodedGame.installDirectory.isFileURL, "helper install_dir decodes as a file URL")
        #expect(
            decodedGame.installDirectory.path == "/tmp/MiningOrca Synthetic/Stellaris",
            "helper install_dir preserves the POSIX path"
        )

        let rolledBackError = LauncherCoreError.applyFailedRolledBack("synthetic Apply failure")
        #expect(!rolledBackError.requiresSteamRepair, "successful failed-Apply rollback does not require Steam verification")
        #expect(
            rolledBackError.localizedDescription == "Apply failed. Changes were rolled back to a clean state.\n\nsynthetic Apply failure",
            "successful failed-Apply rollback is explicit in the user-facing error"
        )

        let repairError = LauncherCoreError.steamRepairRequired
        #expect(repairError.requiresSteamRepair, "failed Apply repair error is marked as requiring Steam verification")
        #expect(
            repairError.localizedDescription.hasPrefix("Launcher cleaned everything up, but it's still a good idea to verify the game files in Steam."),
            "Steam repair error uses the shared user-facing cleanup message"
        )

        let ownershipJSON = Data(#"{"account_selected":true,"license_count":37,"package_metadata_complete":true,"missing_package_metadata_count":0,"apps":[{"app_id":1522090,"status":"owned"},{"app_id":2534090,"status":"not_owned"},{"app_id":4241410,"status":"unknown"}]}"#.utf8)
        let ownershipSnapshot = try JSONDecoder().decode(DLCOwnershipSnapshot.self, from: ownershipJSON)
        #expect(ownershipSnapshot.accountSelected, "ownership helper selects a Steam account")
        #expect(ownershipSnapshot.packageMetadataComplete, "ownership helper reports complete package metadata")
        #expect(ownershipSnapshot.byAppID[1522090] == .owned, "ownership helper decodes owned")
        #expect(ownershipSnapshot.byAppID[2534090] == .notOwned, "ownership helper decodes not-owned")
        #expect(ownershipSnapshot.byAppID[4241410] == .unknown, "ownership helper decodes unknown")

        let contentJSON = Data(#"{"base_app_id":281990,"storage":"separate","content_root":"/tmp/Stellaris/dlc","apps":[{"app_id":844810,"state":"present","source":"active_size_match"},{"app_id":1522090,"state":"incomplete","source":"exact_manifest"},{"app_id":2534090,"state":"unknown","source":"separate_payload_not_installed"}]}"#.utf8)
        let contentSnapshot = try JSONDecoder().decode(DLCContentSnapshot.self, from: contentJSON)
        #expect(contentSnapshot.baseAppID == 281990, "content-state helper preserves base AppID")
        #expect(contentSnapshot.storage == .separate, "content-state helper decodes separate DLC storage")
        #expect(contentSnapshot.contentRoot == "/tmp/Stellaris/dlc", "content-state helper decodes inferred DLC content root")
        #expect(contentSnapshot.byAppID[844810] == .present, "content-state helper decodes present")
        #expect(contentSnapshot.byAppID[1522090] == .incomplete, "content-state helper decodes incomplete")
        #expect(contentSnapshot.byAppID[2534090] == .unknown, "content-state helper decodes unknown")

        let bundledContentJSON = Data(#"{"base_app_id":281990,"storage":"bundled","apps":[{"app_id":1,"state":"present","source":"bundled"},{"app_id":2,"state":"unknown","source":"insufficient_evidence"}]}"#.utf8)
        let bundledContentSnapshot = try JSONDecoder().decode(DLCContentSnapshot.self, from: bundledContentJSON)
        #expect(bundledContentSnapshot.storage == .bundled, "content-state carries game-level bundled storage independently of per-DLC states")

        let unnamedDLC = DLCInfo(appID: 999999, name: nil)
        #expect(unnamedDLC.name == nil, "unknown DLC keeps absence of a real name in the domain model")
        #expect(unnamedDLC.displayName == DLCInfo.unknownDisplayName, "unknown DLC display fallback is centralized")

        let namedUnknownDLCJSON = Data(#"{"app_id":999999,"name":"Unknown DLC"}"#.utf8)
        let namedUnknownDLC = try JSONDecoder().decode(DLCInfo.self, from: namedUnknownDLCJSON)
        #expect(namedUnknownDLC.name == "Unknown DLC", "Unknown DLC is preserved when it is actual DLC data")
    }

    @Test
    func testConfigRoundTripsAndDocumentMerge() throws {
        let all = RuntimeConfig(
            appID: 281990,
            policy: RuntimePolicy(
                selection: .all,
                globalPurchaseTime: .timestamp(1_700_000_000)
            )
        )
        let allText = RuntimeConfigCodec.render(all)
        #expect(allText.contains("launcher_selection = all"), "launcher selection is a regular runtime field")
        #expect(!allText.contains("# launcher_selection"), "launcher selection is not encoded in a comment")
        let allParsed = try RuntimeConfigCodec.parse(allText)
        #expect(allParsed.policy.selection == .all, "all selection round-trip")
        #expect(allParsed.policy.globalPurchaseTime == .timestamp(1_700_000_000), "all global purchase_time round-trip")
        #expect(allParsed.policy.dlcPurchaseTimes.isEmpty, "all config has no synthetic per-DLC purchase_time")

        let explicitIDs: Set<UInt32> = [447680, 554350]
        let explicit = RuntimeConfig(
            appID: 281990,
            policy: RuntimePolicy(
                selection: .explicit(explicitIDs),
                dlcPurchaseTimes: [
                    447680: .timestamp(1_700_000_000),
                    554350: .timestamp(1_700_000_000),
                ]
            ),
            configuredDLCNames: [
                447680: "Leviathans Story Pack",
                554350: "Utopia",
            ]
        )
        let explicitText = RuntimeConfigCodec.render(explicit)
        let explicitParsed = try RuntimeConfigCodec.parse(explicitText)
        #expect(explicitParsed.policy.selection == .explicit(explicitIDs), "explicit selection round-trip")
        #expect(explicitParsed.configuredDLCNames[554350] == "Utopia", "DLC name round-trip")
        #expect(explicitParsed.policy.selection != .all, "explicit all-current intent stays distinct from all/future")
        #expect(explicitParsed.policy.globalPurchaseTime == .valve, "matching per-DLC purchase_time values do not become global")
        #expect(explicitParsed.policy.dlcPurchaseTimes[447680] == .timestamp(1_700_000_000), "first explicit DLC purchase_time round-trip")
        #expect(explicitParsed.policy.dlcPurchaseTimes[554350] == .timestamp(1_700_000_000), "second explicit DLC purchase_time round-trip")


        let unknownNameText = """
        [runtime]
        app_id = 281990
        launcher_selection = explicit

        [global]
        subscribed = valve
        installed = valve
        licensed = valve

        [dlc.999999]
        name = "Unknown DLC"
        subscribed = true
        installed = true
        licensed = true
        """
        let unknownName = try RuntimeConfigCodec.parse(unknownNameText)
        #expect(unknownName.policy.selection == .explicit([999999]), "Unknown DLC name does not affect explicit DLC selection")
        #expect(unknownName.configuredDLCNames[999999] == "Unknown DLC", "Unknown DLC is preserved as configured DLC data")
        #expect(RuntimeConfigCodec.render(unknownName).contains(#"name = "Unknown DLC""#), "configured Unknown DLC name round-trips")

        let mixedPurchaseTimes = RuntimeConfig(
            appID: 281990,
            policy: RuntimePolicy(
                selection: .all,
                globalPurchaseTime: .timestamp(1_600_000_000),
                dlcPurchaseTimes: [
                    447680: .timestamp(1_700_000_000),
                    554350: .valve,
                ]
            ),
            configuredDLCNames: [
                447680: "Leviathans Story Pack",
                554350: "Utopia",
            ]
        )
        let mixedParsed = try RuntimeConfigCodec.parse(RuntimeConfigCodec.render(mixedPurchaseTimes))
        #expect(mixedParsed == mixedPurchaseTimes, "global and per-DLC purchase_time overrides round-trip independently")

        let differingPurchaseTimesText = """
        [runtime]
        app_id = 281990
        launcher_selection = explicit

        [global]
        subscribed = valve
        installed = valve
        licensed = valve
        purchase_time = valve

        [dlc.447680]
        subscribed = true
        installed = true
        licensed = true
        purchase_time = 1700000000

        [dlc.554350]
        subscribed = true
        installed = true
        licensed = true
        purchase_time = 1800000000
        """
        let differingPurchaseTimes = try RuntimeConfigCodec.parse(differingPurchaseTimesText)
        #expect(differingPurchaseTimes.policy.globalPurchaseTime == .valve, "differing per-DLC purchase_time values leave global at valve")
        #expect(differingPurchaseTimes.policy.dlcPurchaseTimes[447680] == .timestamp(1_700_000_000), "first differing DLC timestamp is preserved")
        #expect(differingPurchaseTimes.policy.dlcPurchaseTimes[554350] == .timestamp(1_800_000_000), "second differing DLC timestamp is preserved")

        let defaultSelection = """
        # launcher_selection = none
        [runtime]
        app_id = 281990

        [global]
        subscribed = valve
        installed = valve
        licensed = valve
        language = valve
        low_violence = valve
        purchase_time = valve

        [dlc.447680]
        name = "Leviathans Story Pack"
        subscribed = true
        installed = true
        licensed = true
        """
        let defaultSelectionParsed = try RuntimeConfigCodec.parse(defaultSelection)
        #expect(defaultSelectionParsed.policy.selection == .all, "missing runtime.launcher_selection defaults to all")

        let rawWithUnknownFields = """
        # hand-edited config survives structured Apply
        [runtime]
        app_id = 281990
        launcher_selection = none
        future_runtime_key = keep-me

        [global]
        subscribed = valve
        installed = valve
        licensed = valve
        language = schinese
        low_violence = valve
        purchase_time = valve
        future_global_key = "keep me exactly"

        [custom.future]
        enabled = definitely
        """ + "\n"
        let rawDocument = try RuntimeConfigDocument.parse(
            rawWithUnknownFields,
            expectedAppID: 281990,
            requireExplicitAppID: true
        )
        let structuredUpdate = RuntimeConfig(
            appID: 281990,
            policy: RuntimePolicy(
                selection: .all,
                globalPurchaseTime: .timestamp(1_700_000_000),
                language: "polish"
            )
        )
        let mergedRaw = try rawDocument.mergingKnownFields(from: structuredUpdate)
        #expect(mergedRaw.contains("# hand-edited config survives structured Apply"), "structured config merge preserves comments")
        #expect(mergedRaw.contains("future_runtime_key = keep-me"), "structured config merge preserves unknown runtime keys")
        #expect(mergedRaw.contains("future_global_key = \"keep me exactly\""), "structured config merge preserves unknown global keys")
        #expect(mergedRaw.contains("[custom.future]\nenabled = definitely"), "structured config merge preserves unknown sections")
        #expect(mergedRaw.contains("launcher_selection = all"), "structured config merge updates launcher selection")
        #expect(mergedRaw.contains("language = polish"), "structured config merge updates known values")
        #expect(mergedRaw.contains("purchase_time = 1700000000"), "structured config merge updates purchase_time")

        let handEditedExplicit = """
        [runtime]
        app_id = 281990
        launcher_selection = explicit

        [global]
        subscribed = valve
        installed = valve
        licensed = valve
        purchase_time = valve

        [dlc.1522090]
        name = "Nemesis"
        subscribed = true
        installed = valve
        licensed = false
        purchase_time = 1700000000
        custom_entitlement_note = keep-this
        """ + "\n"
        let handEditedDocument = try RuntimeConfigDocument.parse(
            handEditedExplicit,
            expectedAppID: 281990,
            requireExplicitAppID: true
        )
        #expect(
            handEditedDocument.configuration.policy.selection == .explicit([1522090]),
            "explicit runtime selection keeps a hand-edited partial entitlement section selected"
        )
        let handEditedUpdate = RuntimeConfig(
            appID: 281990,
            policy: RuntimePolicy(
                selection: .explicit([1522090, 2534090]),
                dlcPurchaseTimes: [1522090: .timestamp(1_800_000_000)]
            ),
            configuredDLCNames: [
                1522090: "Nemesis",
                2534090: "Astral Planes",
            ]
        )
        let handEditedMerged = try handEditedDocument.mergingKnownFields(from: handEditedUpdate)
        #expect(handEditedMerged.contains("subscribed = true"), "structured Explicit preserves custom subscribed")
        #expect(handEditedMerged.contains("installed = valve"), "structured Explicit preserves custom installed")
        #expect(handEditedMerged.contains("licensed = false"), "structured Explicit preserves custom licensed")
        #expect(handEditedMerged.contains("custom_entitlement_note = keep-this"), "structured Explicit preserves unknown per-DLC keys")
        #expect(handEditedMerged.contains("purchase_time = 1800000000"), "structured Explicit may still update managed non-entitlement fields")
        #expect(handEditedMerged.contains("[dlc.2534090]"), "structured Explicit adds newly selected DLC section")
        let handEditedRoundTrip = try RuntimeConfigDocument.parse(
            handEditedMerged,
            expectedAppID: 281990,
            requireExplicitAppID: true
        )
        #expect(
            handEditedRoundTrip.configuration.policy.selection == .explicit([1522090, 2534090]),
            "newly selected DLC remains explicit after safe merge"
        )
    }

    @Test
    func testConfigValidationErrorsReportSourceLocation() throws {
        let invalidPurchaseTime = """
        [runtime]
        app_id = 281990

        [global]
        subscribed = valve
        installed = valve
        licensed = valve
        purchase_time = yesterday
        """
        do {
            _ = try RuntimeConfigDocument.parse(
                invalidPurchaseTime,
                expectedAppID: 281990,
                requireExplicitAppID: true
            )
            #expect(Bool(false), "advanced parser rejects invalid purchase_time")
        } catch let error as RuntimeConfigValidationError {
            #expect(error.line == 8, "advanced validation reports exact source line")
            #expect(error.key == "global.purchase_time", "advanced validation reports qualified key")
        }

        let mismatchedAppID = """
        [runtime]
        app_id = 440
        """
        do {
            _ = try RuntimeConfigDocument.parse(
                mismatchedAppID,
                expectedAppID: 281990,
                requireExplicitAppID: true
            )
            #expect(Bool(false), "advanced parser rejects a config for another game")
        } catch let error as RuntimeConfigValidationError {
            #expect(error.line == 2, "AppID mismatch reports app_id line")
            #expect(error.key == "runtime.app_id", "AppID mismatch reports runtime.app_id")
        }

        let invalidSelection = """
        [runtime]
        app_id = 281990
        launcher_selection = current
        """
        do {
            _ = try RuntimeConfigDocument.parse(
                invalidSelection,
                expectedAppID: 281990,
                requireExplicitAppID: true
            )
            #expect(Bool(false), "advanced parser rejects invalid launcher_selection")
        } catch let error as RuntimeConfigValidationError {
            #expect(error.line == 3, "launcher_selection validation reports exact source line")
            #expect(error.key == "runtime.launcher_selection", "launcher_selection validation reports qualified key")
        }
    }
}
