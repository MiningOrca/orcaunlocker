import Foundation

enum BinaryInspectionError: Error {
    case malformedToolOutput(String, String)
}

/// Stateless inspection primitives for runtime binaries.
///
/// This type owns only invocation/parsing of binary inspection tools. Callers
/// remain responsible for deciding which hashes, install names, or linked
/// libraries are valid for a particular runtime or installation state.
enum BinaryInspector {
    static func sha256(_ url: URL) throws -> String {
        let output = try SystemTool.run(
            "/usr/bin/shasum",
            arguments: ["-a", "256", url.path]
        ).stdout
        guard let hash = output.split(whereSeparator: { $0.isWhitespace }).first,
              hash.count == 64 else {
            throw BinaryInspectionError.malformedToolOutput("shasum", output)
        }
        return String(hash).lowercased()
    }

    static func architectureOutput(_ url: URL) throws -> String {
        try SystemTool.run(
            "/usr/bin/lipo",
            arguments: ["-archs", url.path]
        ).stdout
    }

    static func architectures(_ url: URL) throws -> [String] {
        let output = try architectureOutput(url)
        let values = output.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !values.isEmpty else {
            throw BinaryInspectionError.malformedToolOutput("lipo", output)
        }
        return values
    }

    static func installName(_ url: URL) throws -> String {
        let output = try SystemTool.run(
            "/usr/bin/otool",
            arguments: ["-D", url.path]
        ).stdout
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else {
            throw BinaryInspectionError.malformedToolOutput("otool -D", output)
        }
        return lines[1]
    }

    static func links(
        to dependency: String,
        in url: URL
    ) throws -> Bool {
        let output = try SystemTool.run(
            "/usr/bin/otool",
            arguments: ["-L", url.path]
        ).stdout
        return output.contains(dependency)
    }

    static func reexportedDependencies(_ url: URL) throws -> [String] {
        let output = try SystemTool.run(
            "/usr/bin/otool",
            arguments: ["-l", url.path]
        ).stdout
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var result: [String] = []

        for index in lines.indices where lines[index].trimmingCharacters(in: .whitespaces) == "cmd LC_REEXPORT_DYLIB" {
            let end = min(lines.count, index + 7)
            for candidate in lines[(index + 1)..<end] {
                let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("name ") else { continue }
                let value = trimmed.dropFirst("name ".count)
                if let offsetRange = value.range(of: " (offset ") {
                    result.append(String(value[..<offsetRange.lowerBound]))
                }
                break
            }
        }

        return result
    }
}
