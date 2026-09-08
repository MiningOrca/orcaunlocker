import Foundation
import Testing
@testable import MiningOrcaLauncherCore

struct DiagnosticsAndProcessTests {
    private let processBootstrap: Void = bootstrapTestProcess()

    @Test
    func testProcessRunnerDrainsLargeStdoutAndStderr() throws {
        let temporaryRoot = try makeTemporaryRoot("process-runner")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        // A child that writes more than a pipe buffer before exiting deadlocked the old
        // waitUntilExit() -> readDataToEndOfFile() implementation. Exercise both streams
        // with >1 MiB so ProcessRunner must drain while the child is still running.
        let largeOutputScript = temporaryRoot.appendingPathComponent("large-process-output.sh")
        let largeOutputScriptText = """
        #!/bin/sh
        /usr/bin/awk 'BEGIN { for (i = 0; i < 20000; i++) print "stdout-012345678901234567890123456789012345678901234567890123456789" }'
        /usr/bin/awk 'BEGIN { for (i = 0; i < 20000; i++) print "stderr-012345678901234567890123456789012345678901234567890123456789" }' >&2
        """
        try largeOutputScriptText.write(to: largeOutputScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: largeOutputScript.path)
        let largeOutputResult = try SystemTool.run(largeOutputScript.path, arguments: [])
        #expect(largeOutputResult.stdout.utf8.count > 1_000_000, "ProcessRunner drains large stdout without deadlock")
        #expect(largeOutputResult.stderr.utf8.count > 1_000_000, "ProcessRunner drains large stderr without deadlock")
        #expect(largeOutputResult.status == 0, "ProcessRunner preserves child exit status")
    }

    @Test
    func testDiagnosticRedactionAndLogTail() throws {
        let temporaryRoot = try makeTemporaryRoot("diagnostics")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let redacted = DiagnosticPrivacy.redact(
            "/Users/example/Library/Application Support/Steam/userdata/61200707/config/localconfig.vdf",
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )
        #expect(
            redacted == "~/Library/Application Support/Steam/userdata/<account>/config/localconfig.vdf",
            "diagnostic privacy redaction"
        )

        let diagnosticLog = temporaryRoot.appendingPathComponent("diagnostic.log")
        try "one\ntwo\nthree\nfour\n".write(to: diagnosticLog, atomically: true, encoding: .utf8)
        let diagnosticTail = try DiagnosticLogReader.tail(url: diagnosticLog, lineLimit: 2, maxBytes: 1024)
        #expect(diagnosticTail.lines == ["three", "four"], "diagnostic log tail")
    }

    @Test
    func testApplyRequestBuildsRuntimeConfigWithoutDroppingUnknownDLCIDs() {
        let policy = RuntimePolicy(
            selection: .explicit([447680, 999999]),
            dlcPurchaseTimes: [
                447680: .timestamp(1_700_000_000),
                999999: .timestamp(1_700_000_000),
            ]
        )
        let applyRequest = ApplyRequest(
            transport: .proxy,
            profile: .production,
            policy: policy,
            knownDLCs: [DLCInfo(appID: 447680, name: "Leviathans Story Pack")]
        )
        let applyConfig = applyRequest.runtimeConfig(appID: 281990)
        #expect(applyConfig.policy == policy, "Apply preserves the complete runtime policy")
        #expect(applyConfig.configuredDLCNames[447680] == "Leviathans Story Pack", "Apply uses discovered DLC names")
        #expect(applyConfig.configuredDLCNames[999999] == nil, "Apply does not materialize a display fallback as DLC data")
        #expect(applyConfig.policy.selection == .explicit([447680, 999999]), "Apply preserves unknown explicit DLC IDs through selection")
    }

    @Test
    func testConfigFileWriteReadRoundTrip() throws {
        let temporaryRoot = try makeTemporaryRoot("config-roundtrip")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let explicit = RuntimeConfig(
            appID: 281990,
            policy: RuntimePolicy(
                selection: .explicit([447680, 554350]),
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
        let game = SteamGame(appID: 281990, name: "Synthetic Stellaris", installDirectory: temporaryRoot)
        let file = RuntimeConfigFile(runtimeSettings: try testRuntimeSettings())
        try file.write(explicit, for: game)
        let diskParsed = try file.read(for: game)
        #expect(diskParsed == explicit, "atomic config file write/read")
    }
}
