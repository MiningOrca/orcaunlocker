import Foundation

struct SystemToolResult: Sendable {
    let stdout: String
    let stderr: String
    let status: Int32

    var combinedOutput: String {
        [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SystemToolError: Error, LocalizedError {
    case launchFailed(String, String)
    case failed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let executable, let message):
            return "Could not launch \(executable): \(message)"
        case .failed(let executable, let status, let output):
            return "\(executable) failed with exit code \(status): \(output)"
        }
    }
}

enum SystemTool {
    static func run(
        _ executable: String,
        arguments: [String],
        check: Bool = true
    ) throws -> SystemToolResult {
        LauncherLog.logger.debug(
            "Running system tool",
            metadata: [
                "executable": "\(executable)",
                "arguments": "\(arguments.joined(separator: " "))",
            ]
        )
        let execution: ProcessRunnerResult
        do {
            execution = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments
            )
        } catch ProcessRunnerError.launchFailed(let message) {
            LauncherLog.logger.error(
                "Could not launch \(executable): \(message)"
            )
            throw SystemToolError.launchFailed(executable, message)
        }

        let stdoutText = String(
            decoding: execution.stdout,
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrText = String(
            decoding: execution.stderr,
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let result = SystemToolResult(
            stdout: stdoutText,
            stderr: stderrText,
            status: execution.status
        )

        if check, result.status != 0 {
            LauncherLog.logger.error(
                "\(executable) failed with exit code \(result.status): \(result.combinedOutput)"
            )
            throw SystemToolError.failed(executable, result.status, result.combinedOutput)
        }

        return result
    }
}
