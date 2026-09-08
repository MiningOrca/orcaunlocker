import Foundation

package struct RuntimeConfigValidationError: Error, LocalizedError, Equatable, Sendable {
    let line: Int
    let key: String?
    let reason: String

    init(line: Int, key: String? = nil, reason: String) {
        self.line = line
        self.key = key
        self.reason = reason
    }

    package var errorDescription: String? {
        if let key, !key.isEmpty {
            return "Line \(line) (\(key)): \(reason)"
        }
        return "Line \(line): \(reason)"
    }
}

package struct RuntimeConfigSource: Equatable, Sendable {
    package let url: URL
    package let text: String
    package let configuration: RuntimeConfig?
    package let fileExists: Bool
    package let validationError: RuntimeConfigValidationError?

    package init(
        url: URL,
        text: String,
        configuration: RuntimeConfig?,
        fileExists: Bool,
        validationError: RuntimeConfigValidationError? = nil
    ) {
        self.url = url
        self.text = text
        self.configuration = configuration
        self.fileExists = fileExists
        self.validationError = validationError
    }
}

struct RuntimeConfigDocument: Equatable, Sendable {
    enum LineKind: Equatable, Sendable {
        case blank
        case comment(String)
        case section(name: String)
        case assignment(section: String, key: String, value: String, rawValue: String)
    }

    struct Line: Equatable, Sendable {
        let number: Int
        let raw: String
        let kind: LineKind
    }

    let text: String
    let lines: [Line]
    let configuration: RuntimeConfig

    static func parse(
        _ text: String,
        fallbackAppID: UInt32? = nil,
        expectedAppID: UInt32? = nil,
        requireExplicitAppID: Bool = false
    ) throws -> RuntimeConfigDocument {
        let parsedLines = try parseLines(text)
        let configuration = try decode(
            parsedLines,
            fallbackAppID: fallbackAppID,
            expectedAppID: expectedAppID,
            requireExplicitAppID: requireExplicitAppID
        )
        return RuntimeConfigDocument(text: text, lines: parsedLines, configuration: configuration)
    }

    func mergingKnownFields(from desired: RuntimeConfig) throws -> String {
        let desiredText = RuntimeConfigCodec.render(desired)
        let desiredDocument = try RuntimeConfigDocument.parse(
            desiredText,
            expectedAppID: desired.appID,
            requireExplicitAppID: true
        )

        var desiredAssignments: [String: [String: String]] = [:]
        var desiredSectionOrder: [String] = []
        let desiredExplicitIDs: Set<UInt32>
        if case .explicit(let ids) = desired.policy.selection {
            desiredExplicitIDs = ids
        } else {
            desiredExplicitIDs = []
        }
        let existingCustomEntitlementSections = Set(lines.compactMap { line -> String? in
            guard case .assignment(let section, let key, _, _) = line.kind,
                  section.hasPrefix("dlc."),
                  Self.isEntitlementKey(key) else {
                return nil
            }
            return section
        })

        for line in desiredDocument.lines {
            switch line.kind {
            case .section(let name):
                if !desiredSectionOrder.contains(name) {
                    desiredSectionOrder.append(name)
                }
            case .assignment(let section, let key, _, let rawValue):
                desiredAssignments[section, default: [:]][key] = rawValue
            case .blank, .comment:
                break
            }
        }

        var output: [String] = []
        var currentSection = ""
        var seenSections = Set<String>()
        var seenAssignments: [String: Set<String>] = [:]

        func appendMissingManagedAssignments(for section: String) {
            guard Self.isManagedSection(section), let desiredValues = desiredAssignments[section] else { return }
            let seen = seenAssignments[section] ?? []
            for key in Self.managedKeyOrder(for: section) {
                guard !seen.contains(key), let rawValue = desiredValues[key] else { continue }
                if Self.shouldPreserveExistingEntitlements(
                    section: section,
                    key: key,
                    desiredExplicitIDs: desiredExplicitIDs,
                    existingCustomEntitlementSections: existingCustomEntitlementSections
                ) {
                    continue
                }
                output.append("\(key) = \(rawValue)")
                seenAssignments[section, default: []].insert(key)
            }
        }

        for line in lines {
            switch line.kind {
            case .section(let name):
                appendMissingManagedAssignments(for: currentSection)
                currentSection = name
                seenSections.insert(name)
                output.append(line.raw)

            case .assignment(let section, let key, _, _):
                guard Self.isManagedKey(key, in: section) else {
                    output.append(line.raw)
                    continue
                }

                if let rawValue = desiredAssignments[section]?[key] {
                    if Self.shouldPreserveExistingEntitlements(
                        section: section,
                        key: key,
                        desiredExplicitIDs: desiredExplicitIDs,
                        existingCustomEntitlementSections: existingCustomEntitlementSections
                    ) {
                        output.append(line.raw)
                    } else {
                        output.append(Self.replacingAssignmentValue(in: line.raw, with: rawValue))
                    }
                    seenAssignments[section, default: []].insert(key)
                }
                // Managed keys that are no longer present in the desired configuration
                // are intentionally removed. Comments and unknown keys remain untouched.

            case .comment:
                output.append(line.raw)

            case .blank:
                output.append(line.raw)
            }
        }
        appendMissingManagedAssignments(for: currentSection)

        for section in desiredSectionOrder where !seenSections.contains(section) {
            guard Self.isManagedSection(section), let values = desiredAssignments[section] else { continue }
            if output.last?.isEmpty == false {
                output.append("")
            }
            output.append("[\(section)]")
            for key in Self.managedKeyOrder(for: section) {
                if let rawValue = values[key] {
                    output.append("\(key) = \(rawValue)")
                }
            }
        }

        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let hadTrailingNewline = text.hasSuffix("\n") || text.isEmpty
        var merged = output.joined(separator: newline)
        if hadTrailingNewline {
            merged += newline
        }
        return merged
    }

    private static func parseAssignment(_ input: Substring) -> (Substring, Substring)? {
        guard let separator = input.firstIndex(of: "=") else { return nil }
        return (input[..<separator], input[input.index(after: separator)...])
    }

    private static func parseSection(_ input: Substring) -> (Substring, Substring)? {
        guard input.first == "[",
              let closingBracket = input.firstIndex(of: "]") else { return nil }
        let nameStart = input.index(after: input.startIndex)
        return (input[nameStart..<closingBracket], input[input.index(after: closingBracket)...])
    }

    private static func parseLines(_ text: String) throws -> [Line] {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [Line] = []
        var currentSection = ""

        for (index, rawSlice) in rawLines.enumerated() {
            // split(separator:) produces a synthetic final empty element for a trailing newline.
            if index == rawLines.count - 1, rawSlice.isEmpty, text.hasSuffix("\n") {
                break
            }

            var raw = String(rawSlice)
            if raw.hasSuffix("\r") { raw.removeLast() }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let lineNumber = index + 1

            if trimmed.isEmpty {
                result.append(Line(number: lineNumber, raw: raw, kind: .blank))
                continue
            }

            if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                result.append(Line(number: lineNumber, raw: raw, kind: .comment(body)))
                continue
            }

            if trimmed.hasPrefix("[") {
                guard let parsed = parseSection(trimmed[...]) else {
                    throw RuntimeConfigValidationError(
                        line: lineNumber,
                        reason: "Malformed section header; expected [section]."
                    )
                }
                let name = String(parsed.0).trimmingCharacters(in: .whitespaces).lowercased()
                let trailing = String(parsed.1).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    throw RuntimeConfigValidationError(line: lineNumber, reason: "Section name cannot be empty.")
                }
                guard trailing.isEmpty else {
                    throw RuntimeConfigValidationError(line: lineNumber, reason: "Unexpected text after section header.")
                }
                currentSection = name
                result.append(Line(number: lineNumber, raw: raw, kind: .section(name: name)))
                continue
            }

            guard let parsed = parseAssignment(trimmed[...]) else {
                throw RuntimeConfigValidationError(
                    line: lineNumber,
                    reason: "Malformed assignment; expected key = value."
                )
            }
            let key = String(parsed.0).trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = String(parsed.1).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw RuntimeConfigValidationError(line: lineNumber, reason: "Key cannot be empty.")
            }
            guard !rawValue.isEmpty else {
                throw RuntimeConfigValidationError(line: lineNumber, key: qualifiedKey(section: currentSection, key: key), reason: "Value cannot be empty.")
            }
            let value = try decodeValue(rawValue, line: lineNumber, key: qualifiedKey(section: currentSection, key: key))
            result.append(
                Line(
                    number: lineNumber,
                    raw: raw,
                    kind: .assignment(section: currentSection, key: key, value: value, rawValue: rawValue)
                )
            )
        }

        return result
    }

    private static func decode(
        _ lines: [Line],
        fallbackAppID: UInt32?,
        expectedAppID: UInt32?,
        requireExplicitAppID: Bool
    ) throws -> RuntimeConfig {
        var values: [String: [String: (value: String, line: Int)]] = [:]
        var dlcNames: [UInt32: String] = [:]

        for line in lines {
            switch line.kind {
            case .assignment(let section, let key, let value, _):
                values[section, default: [:]][key] = (value, line.number)
                try validateKnownValue(section: section, key: key, value: value, line: line.number)

                if section.hasPrefix("dlc."), key == "name" {
                    guard let id = UInt32(section.dropFirst(4)) else {
                        throw RuntimeConfigValidationError(line: line.number, key: section, reason: "DLC section must use a numeric AppID, for example [dlc.447680].")
                    }
                    if let name = DLCInfo.normalizedName(value) {
                        dlcNames[id] = name
                    }
                }

            case .section(let name):
                if name.hasPrefix("dlc."), UInt32(name.dropFirst(4)) == nil {
                    throw RuntimeConfigValidationError(line: line.number, key: name, reason: "DLC section must use a numeric AppID, for example [dlc.447680].")
                }

            case .blank, .comment:
                break
            }
        }

        let explicitRuntimeAppID: UInt32?
        if let appIDEntry = values["runtime"]?["app_id"] {
            guard let parsed = UInt32(appIDEntry.value) else {
                throw RuntimeConfigValidationError(line: appIDEntry.line, key: "runtime.app_id", reason: "Expected an unsigned 32-bit Steam AppID.")
            }
            explicitRuntimeAppID = parsed
        } else {
            explicitRuntimeAppID = nil
        }

        if requireExplicitAppID, explicitRuntimeAppID == nil {
            let line = lines.first(where: {
                if case .section(let name) = $0.kind { return name == "runtime" }
                return false
            })?.number ?? 1
            throw RuntimeConfigValidationError(line: line, key: "runtime.app_id", reason: "Missing required [runtime] app_id.")
        }

        guard let appID = explicitRuntimeAppID ?? fallbackAppID else {
            throw RuntimeConfigValidationError(line: 1, key: "runtime.app_id", reason: "Missing required [runtime] app_id.")
        }

        if let expectedAppID, appID != expectedAppID {
            let line = values["runtime"]?["app_id"]?.line ?? 1
            throw RuntimeConfigValidationError(
                line: line,
                key: "runtime.app_id",
                reason: "Config AppID \(appID) does not match selected game \(expectedAppID)."
            )
        }

        let global = values["global"] ?? [:]
        var explicitOverrideDLCs = Set<UInt32>()

        for (name, sectionValues) in values where name.hasPrefix("dlc.") {
            guard let id = UInt32(name.dropFirst(4)) else { continue }
            if Self.entitlementKeys.contains(where: { sectionValues[$0] != nil }) {
                explicitOverrideDLCs.insert(id)
            }
        }

        let selection: DLCSelection
        if let entry = values["runtime"]?["launcher_selection"] {
            switch entry.value.lowercased() {
            case "all": selection = .all
            case "explicit": selection = .explicit(explicitOverrideDLCs)
            case "none": selection = .none
            default:
                throw RuntimeConfigValidationError(
                    line: entry.line,
                    key: "runtime.launcher_selection",
                    reason: "Expected all, explicit, or none; got '\(entry.value)'."
                )
            }
        } else {
            selection = .all
        }

        let globalPurchaseTime = try parsePurchaseTime(global["purchase_time"], key: "global.purchase_time") ?? .valve
        var dlcPurchaseTimes: [UInt32: RuntimePurchaseTime] = [:]
        for (name, sectionValues) in values where name.hasPrefix("dlc.") {
            guard let id = UInt32(name.dropFirst(4)), let entry = sectionValues["purchase_time"] else { continue }
            dlcPurchaseTimes[id] = try parsePurchaseTime(entry, key: "\(name).purchase_time") ?? .valve
        }

        let language: String?
        if let raw = global["language"]?.value,
           !raw.isEmpty,
           raw.caseInsensitiveCompare("valve") != .orderedSame {
            language = raw
        } else {
            language = nil
        }

        let lowViolence: Bool?
        switch global["low_violence"]?.value.lowercased() {
        case "true": lowViolence = true
        case "false": lowViolence = false
        default: lowViolence = nil
        }

        return RuntimeConfig(
            appID: appID,
            policy: RuntimePolicy(
                selection: selection,
                globalPurchaseTime: globalPurchaseTime,
                dlcPurchaseTimes: dlcPurchaseTimes,
                language: language,
                lowViolence: lowViolence
            ),
            configuredDLCNames: dlcNames
        )
    }

    private static func validateKnownValue(section: String, key: String, value: String, line: Int) throws {
        if section == "runtime", key == "app_id" {
            guard UInt32(value) != nil else {
                throw RuntimeConfigValidationError(line: line, key: "runtime.app_id", reason: "Expected an unsigned 32-bit Steam AppID.")
            }
            return
        }
        if section == "runtime", key == "launcher_selection" {
            guard ["all", "explicit", "none"].contains(value.lowercased()) else {
                throw RuntimeConfigValidationError(
                    line: line,
                    key: "runtime.launcher_selection",
                    reason: "Expected all, explicit, or none; got '\(value)'."
                )
            }
            return
        }

        let isPolicySection = section == "global" || section.hasPrefix("dlc.")
        guard isPolicySection else { return }

        if ["subscribed", "installed", "licensed"].contains(key) {
            guard ["true", "false", "valve"].contains(value.lowercased()) else {
                throw RuntimeConfigValidationError(
                    line: line,
                    key: qualifiedKey(section: section, key: key),
                    reason: "Expected true, false, or valve; got '\(value)'."
                )
            }
        } else if key == "low_violence", section == "global" {
            guard ["true", "false", "valve"].contains(value.lowercased()) else {
                throw RuntimeConfigValidationError(
                    line: line,
                    key: "global.low_violence",
                    reason: "Expected true, false, or valve; got '\(value)'."
                )
            }
        } else if key == "purchase_time" {
            _ = try parsePurchaseTime((value, line), key: qualifiedKey(section: section, key: key))
        }
    }

    private static func parsePurchaseTime(
        _ entry: (value: String, line: Int)?,
        key: String
    ) throws -> RuntimePurchaseTime? {
        guard let entry else { return nil }
        if entry.value.caseInsensitiveCompare("valve") == .orderedSame {
            return .valve
        }
        guard let timestamp = Int64(entry.value), timestamp >= 0 else {
            throw RuntimeConfigValidationError(
                line: entry.line,
                key: key,
                reason: "Expected valve or a non-negative Unix timestamp; got '\(entry.value)'."
            )
        }
        return .timestamp(timestamp)
    }

    private static func decodeValue(_ rawValue: String, line: Int, key: String) throws -> String {
        guard rawValue.first == "\"" else {
            if rawValue.contains("\"") {
                throw RuntimeConfigValidationError(line: line, key: key, reason: "Unexpected quote in unquoted value.")
            }
            return rawValue
        }

        var result = ""
        var escaped = false
        var closingQuoteIndex: String.Index?
        var index = rawValue.index(after: rawValue.startIndex)

        while index < rawValue.endIndex {
            let character = rawValue[index]
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                closingQuoteIndex = index
                break
            } else {
                result.append(character)
            }
            index = rawValue.index(after: index)
        }

        guard let closingQuoteIndex else {
            throw RuntimeConfigValidationError(line: line, key: key, reason: "Unterminated quoted value.")
        }
        guard !escaped else {
            throw RuntimeConfigValidationError(line: line, key: key, reason: "Quoted value ends with an incomplete escape.")
        }

        let trailingStart = rawValue.index(after: closingQuoteIndex)
        let trailing = rawValue[trailingStart...].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty else {
            throw RuntimeConfigValidationError(line: line, key: key, reason: "Unexpected text after quoted value.")
        }
        return result
    }

    private static let entitlementKeys = ["subscribed", "installed", "licensed"]

    private static func isEntitlementKey(_ key: String) -> Bool {
        entitlementKeys.contains(key)
    }

    private static func shouldPreserveExistingEntitlements(
        section: String,
        key: String,
        desiredExplicitIDs: Set<UInt32>,
        existingCustomEntitlementSections: Set<String>
    ) -> Bool {
        guard isEntitlementKey(key),
              section.hasPrefix("dlc."),
              let appID = UInt32(section.dropFirst(4)),
              desiredExplicitIDs.contains(appID) else {
            return false
        }
        return existingCustomEntitlementSections.contains(section)
    }

    private static func qualifiedKey(section: String, key: String) -> String {
        section.isEmpty ? key : "\(section).\(key)"
    }

    private static func isManagedSection(_ section: String) -> Bool {
        section == "runtime" || section == "global" || section.hasPrefix("dlc.")
    }

    private static func isManagedKey(_ key: String, in section: String) -> Bool {
        managedKeyOrder(for: section).contains(key)
    }

    private static func managedKeyOrder(for section: String) -> [String] {
        if section == "runtime" {
            return ["app_id", "launcher_selection"]
        }
        if section == "global" {
            return ["subscribed", "installed", "licensed", "language", "low_violence", "purchase_time"]
        }
        if section.hasPrefix("dlc.") {
            return ["name", "subscribed", "installed", "licensed", "purchase_time"]
        }
        return []
    }

    private static func replacingAssignmentValue(in rawLine: String, with rawValue: String) -> String {
        guard let equals = rawLine.firstIndex(of: "=") else { return rawLine }
        var valueStart = rawLine.index(after: equals)
        while valueStart < rawLine.endIndex, rawLine[valueStart].isWhitespace {
            valueStart = rawLine.index(after: valueStart)
        }
        return String(rawLine[..<valueStart]) + rawValue
    }
}
