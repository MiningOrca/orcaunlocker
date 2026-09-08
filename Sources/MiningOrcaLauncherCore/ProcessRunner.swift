import Foundation

struct ProcessRunnerResult: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

enum ProcessRunnerError: Error, Sendable {
    case launchFailed(String)
}

private final class ProcessPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private(set) var data = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readToEnd() {
        data = handle.readDataToEndOfFile()
    }
}

enum ProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String]
    ) throws -> ProcessRunnerResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // The child inherited the write descriptors. Closing the parent's copies
        // lets the blocking readers below observe EOF when the child exits.
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let stdoutReader = ProcessPipeReader(handle: stdoutPipe.fileHandleForReading)
        let stderrReader = ProcessPipeReader(handle: stderrPipe.fileHandleForReading)
        let drains = DispatchGroup()

        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutReader.readToEnd()
            drains.leave()
        }

        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrReader.readToEnd()
            drains.leave()
        }

        process.waitUntilExit()
        drains.wait()

        return ProcessRunnerResult(
            stdout: stdoutReader.data,
            stderr: stderrReader.data,
            status: process.terminationStatus
        )
    }
}
