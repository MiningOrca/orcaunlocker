import Foundation
import MiningOrcaLauncherCore

enum DLCPolicyDraft: CaseIterable, Identifiable {
    case all
    case none
    case explicit

    var id: Self {
        self
    }

    var displayText: String {
        switch self {
        case .all: return AppText.Configuration.policyAll
        case .none: return AppText.Configuration.policyNone
        case .explicit: return AppText.Configuration.policyExplicit
        }
    }

    init(_ selection: DLCSelection) {
        switch selection {
        case .all:
            self = .all
        case .none:
            self = .none
        case .explicit:
            self = .explicit
        }
    }
}

enum DLCPurchaseTimeMode: CaseIterable, Identifiable {
    case inherit
    case valve
    case custom

    var id: Self {
        self
    }

    var displayText: String {
        switch self {
        case .inherit: return AppText.Configuration.purchaseTimeUseGlobal
        case .valve: return AppText.Configuration.purchaseTimeValve
        case .custom: return AppText.Configuration.purchaseTimeCustomDate
        }
    }
}

enum DLCPurchaseTimeDraft: Equatable {
    case inherit
    case valve
    case custom(String)

    var mode: DLCPurchaseTimeMode {
        switch self {
        case .inherit:
            return .inherit
        case .valve:
            return .valve
        case .custom:
            return .custom
        }
    }

    init(configValue: RuntimePurchaseTime) {
        switch configValue {
        case .valve:
            self = .valve
        case .timestamp(let timestamp):
            self = .custom(formatPurchaseDate(timestamp))
        }
    }
}

enum LowViolenceDraft: CaseIterable, Identifiable {
    case valve
    case enabled
    case disabled

    var id: Self {
        self
    }

    var displayText: String {
        switch self {
        case .valve: return AppText.Common.valveDefault
        case .enabled: return AppText.Common.on
        case .disabled: return AppText.Common.off
        }
    }

    init(_ value: Bool?) {
        switch value {
        case true:
            self = .enabled
        case false:
            self = .disabled
        case nil:
            self = .valve
        }
    }
}

struct ConfigurationDraft: Equatable {
    var transport: SteamTransport = .proxy
    var language = ""
    var lowViolence: LowViolenceDraft = .valve
    var purchaseTime = ""
    var dlcPolicy: DLCPolicyDraft = .all
    var selectedDLCIDs = Set<UInt32>()
    var dlcPurchaseTimes: [UInt32: DLCPurchaseTimeDraft] = [:]

    init() {
    }

    init(snapshot: GameDetailSnapshot) {
        let installedTransports = Set(snapshot.installation.states.compactMap(\.transport))
        if installedTransports.count == 1, let installed = installedTransports.first {
            transport = installed
        } else {
            transport = snapshot.installation.recommendedTransport ?? .proxy
        }

        let config = snapshot.configuration
        language = config?.policy.language ?? ""
        lowViolence = LowViolenceDraft(config?.policy.lowViolence)
        purchaseTime = Self.purchaseTimeText(config?.policy.globalPurchaseTime ?? .valve)
        dlcPolicy = DLCPolicyDraft(config?.policy.selection ?? .all)
        selectedDLCIDs = config?.policy.selection.selectedAppIDs ?? []
        dlcPurchaseTimes = config?.policy.dlcPurchaseTimes.mapValues(DLCPurchaseTimeDraft.init(configValue:)) ?? [:]
    }

    private static func purchaseTimeText(_ value: RuntimePurchaseTime) -> String {
        switch value {
        case .valve:
            return ""
        case .timestamp(let timestamp):
            return formatPurchaseDate(timestamp)
        }
    }
}

private func formatPurchaseDate(_ timestamp: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "dd.MM.yyyy"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
}
