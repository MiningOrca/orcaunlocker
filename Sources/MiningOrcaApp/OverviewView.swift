import SwiftUI
import MiningOrcaLauncherCore

struct OverviewView: View {
    @ObservedObject var model: LauncherAppModel
    let snapshot: GameDetailSnapshot

    private let cardSpacing: CGFloat = 14

    var body: some View {
        ViewThatFits(in: .horizontal) {
            threeColumnLayout
            singleColumnLayout
        }
    }

    // Wide mode is intentionally non-scrollable. The three-column overview keeps
    // its intrinsic height and the operation log absorbs vertical compression.
    private var threeColumnLayout: some View {
        VStack(spacing: 0) {
            threeColumnOverview
                .layoutPriority(1)

            operationLog
                .frame(minHeight: 135, idealHeight: 180, maxHeight: .infinity)
        }
    }

    private var threeColumnOverview: some View {
        VStack(spacing: 0) {
            threeColumnCards
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

            actionRow
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // Once the horizontal layout falls back to one column, the entire Overview
    // becomes a single document: cards, actions, and the log scroll together.
    private var singleColumnLayout: some View {
        ScrollView {
            VStack(spacing: 0) {
                singleColumnCards
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                actionRow
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                // Give the embedded log a concrete viewport. Its own text view
                // still handles log-history scrolling, while the outer scroll view
                // moves the whole Overview document.
                operationLog
                    .frame(height: 180)
            }
        }
    }

    private var operationLog: some View {
        OperationLogView(
            appID: model.selectedGameID,
            entries: model.logs,
            onClear: model.clearLogs
        )
        .frame(maxWidth: 1100, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var threeColumnCards: some View {
        Grid(horizontalSpacing: cardSpacing, verticalSpacing: 0) {
            GridRow(alignment: .top) {
                InstallationStateCard(snapshot: snapshot)
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 280)

                ConfigurationCard(draft: $model.draft)
                    .frame(minWidth: 280, idealWidth: 310, maxWidth: 350)

                DLCConfigurationCard(
                    draft: $model.draft,
                    dlcCount: snapshot.dlcs.dlcs.count,
                    openDLCs: { model.selectedTab = .dlcs }
                )
                .frame(minWidth: 260, idealWidth: 290, maxWidth: 330)
            }
        }
    }

    private var singleColumnCards: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            InstallationStateCard(snapshot: snapshot)
            ConfigurationCard(draft: $model.draft)
            DLCConfigurationCard(
                draft: $model.draft,
                dlcCount: snapshot.dlcs.dlcs.count,
                openDLCs: { model.selectedTab = .dlcs }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRow: some View {
        HStack {
            Button(AppText.GameDetail.restoreOriginal) {
                model.requestRestore()
            }
            .buttonStyle(.bordered)
            .disabled(!model.canRestoreOriginal || model.isOperationInProgress)
            .nativeHelp(AppText.GameDetail.restoreOriginalHelp)

            Spacer()

            if model.isOperationInProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }

            Text(model.actionStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(AppText.GameDetail.applyChanges) {
                model.requestApply()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApplyChanges || model.isOperationInProgress)
            .nativeHelp(AppText.GameDetail.applyChangesHelp)
        }
        .padding(.horizontal, 2)
    }
}

private struct InstallationStateCard: View {
    let snapshot: GameDetailSnapshot

    var body: some View {
        OverviewCard(title: AppText.GameDetail.installationState) {
            VStack(spacing: 0) {
                stateRow(AppText.GameDetail.status, summary.status)
                Divider()
                stateRow(AppText.GameDetail.transport, summary.transport)
                Divider()
                stateRow(AppText.GameDetail.runtime, summary.runtime)
                Divider()
                stateRow(AppText.GameDetail.lowViolence, lowViolenceText(snapshot.configuration?.policy.lowViolence))
                Divider()
                stateRow(AppText.GameDetail.purchaseTime, purchaseTimeText(snapshot.configuration?.policy.globalPurchaseTime ?? .valve))
                Divider()
                stateRow(
                    AppText.GameDetail.dlcPolicy,
                    snapshot.configuration.map {
                        AppText.Configuration.selectionSummary(
                            $0.policy.selection,
                            totalKnown: snapshot.dlcs.dlcs.count
                        )
                    } ?? AppText.Common.valveBehavior
                )
            }
        }
    }

    private var summary: (status: String, transport: String, runtime: String) {
        guard !snapshot.installation.states.isEmpty else {
            return (AppText.GameDetail.noSteamAPITarget, "—", "—")
        }

        if snapshot.installation.hasBrokenState {
            return (AppText.GameDetail.broken, transportSummary, runtimeSummary)
        }
        if snapshot.installation.states.allSatisfy({ $0.kind == .untouched }) {
            return (AppText.GameDetail.original, AppText.Common.none, AppText.Common.none)
        }
        let kinds = Set(snapshot.installation.states.map(\.kind.rawValue))
        return (kinds.count == 1 ? AppText.GameDetail.installed : AppText.Common.mixed, transportSummary, runtimeSummary)
    }

    private var transportSummary: String {
        let values = Set(snapshot.installation.states.map { state in
            state.transport.map(AppText.Common.transportName) ?? AppText.Common.none
        })
        return values.count == 1 ? values.first! : AppText.Common.mixed
    }

    private var runtimeSummary: String {
        let values = Set(snapshot.installation.states.map { AppText.GameDetail.runtimeIdentity($0.runtimeIdentity) })
        return values.count == 1 ? values.first! : AppText.Common.mixed
    }

    private func stateRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 8)
    }
}

private struct ConfigurationCard: View {
    @Binding var draft: ConfigurationDraft

    private let controlWidth: CGFloat = 150
    private let labelWidth: CGFloat = 132

    var body: some View {
        OverviewCard(title: AppText.Configuration.configuration) {
            VStack(alignment: .leading, spacing: 16) {
                settingRow(AppText.Configuration.transport, help: AppText.Configuration.transportHelp) {
                    Picker("", selection: $draft.transport) {
                        Text(AppText.Common.proxy).tag(SteamTransport.proxy)
                        Text(AppText.Common.inject).tag(SteamTransport.inject)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: controlWidth)
                    .clipped()
                }

                settingRow(AppText.Configuration.lowViolence, help: AppText.Configuration.lowViolenceHelp) {
                    Picker("", selection: $draft.lowViolence) {
                        ForEach(LowViolenceDraft.allCases) { option in
                            Text(option.displayText).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: controlWidth)
                    .clipped()
                }

                settingRow(AppText.Configuration.purchaseTime, help: AppText.Configuration.purchaseTimeHelp) {
                    TextField(
                        AppText.Common.datePlaceholder,
                        text: Binding(
                            get: { draft.purchaseTime },
                            set: { draft.purchaseTime = formatPurchaseDateInput($0) }
                        )
                    )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: controlWidth)
                        .clipped()
                }
            }
        }
    }

    private func settingRow<Content: View>(
        _ title: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .nativeHelp(help)
            }
            .frame(width: labelWidth, alignment: .leading)

            content()
                .frame(width: controlWidth, alignment: .trailing)
        }
    }
}

private struct DLCConfigurationCard: View {
    @Binding var draft: ConfigurationDraft
    let dlcCount: Int
    let openDLCs: () -> Void

    var body: some View {
        OverviewCard(title: AppText.Configuration.dlcConfiguration) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 5) {
                    Text(AppText.Configuration.policy)
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .nativeHelp(AppText.Configuration.policyHelp)
                }

                Picker("", selection: $draft.dlcPolicy) {
                    ForEach(DLCPolicyDraft.allCases) { policy in
                        Text(policy.displayText).tag(policy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Text(AppText.Configuration.detectedDLCs(dlcCount))
                        .font(.headline)

                    Text(policyDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: openDLCs) {
                    Label(AppText.Configuration.configureDLCs, systemImage: "list.bullet")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var policyDescription: String {
        switch draft.dlcPolicy {
        case .all:
            return AppText.Configuration.allDLCsDescription
        case .none:
            return AppText.Configuration.noDLCOverridesDescription
        case .explicit:
            return AppText.Configuration.selectedDLCs(draft.selectedDLCIDs.count, totalCount: dlcCount)
        }
    }

}

private struct OverviewCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.leading, 12)

            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private func lowViolenceText(_ value: Bool?) -> String {
    switch value {
    case true: return AppText.Common.on
    case false: return AppText.Common.off
    case nil: return AppText.Common.valveDefault
    }
}

private func purchaseTimeText(_ value: RuntimePurchaseTime) -> String {
    switch value {
    case .valve:
        return AppText.Common.valveDefault
    case .timestamp(let timestamp):
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}
