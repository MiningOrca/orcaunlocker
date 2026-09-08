import AppKit
import SwiftUI
import MiningOrcaLauncherCore

struct DLCListView: View {
    @ObservedObject var model: LauncherAppModel
    let snapshot: GameDetailSnapshot
    @State private var searchText = ""

    private var filtered: [DLCInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return snapshot.dlcs.dlcs
        }
        return snapshot.dlcs.dlcs.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || String($0.appID).contains(query)
        }
    }

    private var knownDLCIDs: Set<UInt32> {
        Set(snapshot.dlcs.dlcs.map(\.appID))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppText.GameDetail.dlcsTitle).font(.title2.bold())
                    Text(
                        AppText.GameDetail.dlcListSummary(
                            detectedCount: snapshot.dlcs.dlcs.count,
                            policy: model.draft.dlcPolicy,
                            selectedCount: model.draft.selectedDLCIDs.count
                        )
                    ).foregroundStyle(.secondary)
                }
                Spacer(minLength: 24)
                if snapshot.dlcs.contentStorage == .separate,
                   let contentRootURL = snapshot.dlcs.contentRootURL {
                    Button(AppText.GameDetail.openDLCFilesFolder) {
                        _ = NSWorkspace.shared.open(contentRootURL)
                    }
                    .controlSize(.small)
                    .nativeHelp(contentRootURL.path)
                } else if snapshot.dlcs.contentStorage == .bundled {
                    Text(AppText.GameDetail.bundledDLCFiles)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .nativeHelp(AppText.GameDetail.bundledDLCFilesHelp)
                }
                TextField(AppText.GameDetail.searchDLCs, text: $searchText).textFieldStyle(.roundedBorder).frame(width: 240)
            }.padding(18)

            Divider()

            List(filtered) {
                dlc in
                DLCRowView(
                    dlc: dlc,
                    ownershipStatus: snapshot.dlcs.ownershipStatus(for: dlc.appID),
                    contentState: snapshot.dlcs.contentState(for: dlc.appID),
                    isSelected: model.isDLCSelected(dlc.appID),
                    purchaseTime: Binding(
                        get: {
                            model.dlcPurchaseTime(dlc.appID)
                        },
                        set: {
                            model.setDLCPurchaseTime(
                                $0,
                                for: dlc.appID,
                                knownDLCIDs: knownDLCIDs
                            )
                        }
                    ),
                    toggleSelection: {
                        model.setDLCSelected(
                            dlc.appID,
                            selected: !model.isDLCSelected(dlc.appID),
                            knownDLCIDs: knownDLCIDs
                        )
                    }
                )
            }
        }
    }

}

private struct DLCRowView: View {
    let dlc: DLCInfo
    let ownershipStatus: DLCOwnershipStatus
    let contentState: DLCContentState
    let isSelected: Bool
    @Binding var purchaseTime: DLCPurchaseTimeDraft
    let toggleSelection: () -> Void

    @State private var isHoveringSelectionArea = false
    @State private var isHoveringStoreButton = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill": "square").font(.system(size: 16, weight: .medium)).foregroundStyle(isSelected ? Color.accentColor: Color.secondary).accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(dlc.displayName)
                    HStack(spacing: 8) {
                        Text(String(dlc.appID)).font(.caption).foregroundStyle(.secondary)
                        switch contentState {
                        case .present:
                            Text(AppText.GameDetail.filesPresent)
                                .font(.caption)
                                .foregroundStyle(.green)
                        case .missing, .incomplete:
                            Text(AppText.GameDetail.filesProbablyMissing)
                                .font(.caption)
                                .foregroundStyle(.red)
                        case .unknown:
                            Text(AppText.GameDetail.filesUnknown)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer(minLength: 16)
            }.contentShape(Rectangle()).background {
                if isHoveringSelectionArea {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor.opacity(0.08)).padding(.horizontal, -6).padding(.vertical, -4)
                }
            }.onHover {
                isHoveringSelectionArea = $0
            }.onTapGesture(perform: toggleSelection).accessibilityElement(children: .combine).accessibilityLabel(dlc.displayName).accessibilityValue(isSelected ? AppText.GameDetail.selected : AppText.GameDetail.notSelected).accessibilityAddTraits(.isButton).accessibilityAction(named: Text(isSelected ? AppText.GameDetail.deselectDLC : AppText.GameDetail.selectDLC)) {
                toggleSelection()
            }

            DLCPurchaseTimeEditor(value: $purchaseTime)

            Group {
                if dlc.isFree == true {
                    steamStoreButton(
                        AppText.GameDetail.freeDLCStoreTitle,
                        color: Color(nsColor: .systemGreen)
                    ).nativeHelp(AppText.GameDetail.freeDLCStoreHelp)
                } else if ownershipStatus == .owned {
                    steamStoreButton(
                        AppText.GameDetail.ownedDLCStoreTitle,
                        color: Color(nsColor: .systemGreen)
                    ).nativeHelp(ownershipHelpText)
                } else if ownershipStatus == .notOwned {
                    steamStoreButton(
                        AppText.GameDetail.buyDLCStoreTitle,
                        color: .secondary,
                        highlightColor: Color(nsColor: .systemTeal)
                    ).nativeHelp(AppText.GameDetail.buyDLCStoreHelp)
                } else {
                    steamStoreButton(
                        AppText.GameDetail.unknownOwnershipStoreTitle,
                        color: .secondary
                    )
                }
            }.frame(width: 105, alignment: .trailing)
        }.padding(.vertical, 4)
    }

    private func steamStoreButton(_ title: String,
    color: Color,
    highlightColor: Color? = nil) -> some View {
        Button {
            openSteamStore(appID: dlc.appID)
        } label: {
            Text(title).foregroundStyle(
                isHoveringStoreButton ? (highlightColor ?? color): color
            )
        }.buttonStyle(.borderless).onHover {
            isHoveringStoreButton = $0
        }.animation(.easeOut(duration: 0.12), value: isHoveringStoreButton)
    }

    private var ownershipHelpText: String {
        switch ownershipStatus {
        case .owned:
            return AppText.GameDetail.ownershipOwnedHelp
        case .notOwned:
            return AppText.GameDetail.ownershipNotOwnedHelp
        case .unknown:
            return AppText.GameDetail.ownershipUnknownHelp
        }
    }
}

private func openSteamStore(appID: UInt32) {
    let workspace = NSWorkspace.shared

    if let steamURL = URL(string: "steam://store/\(appID)"),
    workspace.open(steamURL) {
        return
    }

    if let webURL = URL(string: "https://store.steampowered.com/app/\(appID)") {
        workspace.open(webURL)
    }
}

private struct DLCPurchaseTimeEditor: View {
    @Binding var value: DLCPurchaseTimeDraft

    var body: some View {
        HStack(spacing: 8) {
            Text(AppText.Configuration.purchaseDate).font(.caption).foregroundStyle(.secondary)

            Picker("", selection: modeBinding) {
                ForEach(DLCPurchaseTimeMode.allCases) {
                    mode in
                    Text(mode.displayText).tag(mode)
                }
            }.labelsHidden().frame(width: 125)

            if case .custom = value {
                TextField(AppText.Common.datePlaceholder, text: dateBinding).textFieldStyle(.roundedBorder).frame(width: 105)
            }
        }.nativeHelp(AppText.Configuration.purchaseDateHelp)
    }

    private var modeBinding: Binding<DLCPurchaseTimeMode> {
        Binding(
            get: {
                value.mode
            },
            set: {
                mode in
                switch mode {
                case .inherit:
                    value = .inherit
                case .valve:
                    value = .valve
                case .custom:
                    if case .custom = value {
                        return
                    }
                    value = .custom("")
                }
            }
        )
    }

    private var dateBinding: Binding<String> {
        Binding(
            get: {
                if case .custom(let text) = value {
                    return text
                }
                return ""
            },
            set: {
                value = .custom(formatPurchaseDateInput($0))
            }
        )
    }
}

struct AdvancedConfigurationView: View {
    @ObservedObject var model: LauncherAppModel

    var body: some View {
        // NavigationSplitView may measure its detail column without a finite vertical
        // proposal. A flexible text editor must not feed that unbounded measurement
        // back into the split view, otherwise the whole navigation hierarchy grows
        // beyond the actual window. GeometryReader is the containment boundary: it
        // takes the size assigned to the detail area and the editor only consumes the
        // finite space that remains inside it.
        GeometryReader {
            _ in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppText.Configuration.advancedConfiguration).font(.title2.bold())
                        Text(AppText.Configuration.rawConfiguration).foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(model.advancedConfigHasChanges ? AppText.Configuration.unsavedChanges : AppText.Configuration.saved).font(.caption).foregroundStyle(model.advancedConfigHasChanges ? Color.orange: Color.secondary)
                }

                if let url = model.advancedConfigURL {
                    Text(url.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }

                RawConfigurationEditor(text: $model.advancedConfigText).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(nsColor: .separatorColor))
                }.onChange(of: model.advancedConfigText) {
                    _ in
                    model.clearAdvancedConfigError()
                }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 260).layoutPriority(1)

                if let error = model.advancedConfigError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }

                HStack(spacing: 10) {
                    Text(AppText.Configuration.advancedConfigurationHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 20)

                    Button(AppText.Configuration.resetToGenerated) {
                        model.resetAdvancedConfigurationToGenerated()
                    }.disabled(model.isSavingAdvancedConfig || model.isOperationInProgress)

                    Button(model.isSavingAdvancedConfig ? AppText.Configuration.saving : AppText.Configuration.save) {
                        model.saveAdvancedConfiguration()
                    }.buttonStyle(.borderedProminent).disabled(!model.canSaveAdvancedConfig)
                }
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: LauncherAppModel
    let snapshot: GameDetailSnapshot

    var body: some View {
        // Like the raw editor, the live log is vertically flexible. Contain it in
        // the finite detail-column size so NavigationSplitView cannot use the log's
        // ideal height to grow the whole window hierarchy off-screen when notices
        // appear or operation state changes.
        GeometryReader {
            _ in
            VStack(spacing: 0) {
                controls.frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true).layoutPriority(2)

                Group {
                    if model.requiresSteamRepairForSelectedGame || !issues.isEmpty || model.debugLastCaptureURL != nil {
                        notices
                    } else {
                        Color.clear
                    }
                }.frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading).padding(.horizontal, 18).padding(.bottom, 6).fixedSize(horizontal: false, vertical: true).layoutPriority(1)

                runtimeLog.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 120).layoutPriority(-1).padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 18)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.task(id: snapshot.game.appID) {
            while !Task.isCancelled {
                await model.refreshDiagnosticLog()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                DiagnosticsPathRow(
                    label: snapshot.configurationSource.url.deletingLastPathComponent().lastPathComponent,
                    url: snapshot.configurationSource.url.deletingLastPathComponent()
                )

                Spacer(minLength: 12)

                Picker(AppText.Diagnostics.debugTransport, selection: $model.debugTransport) {
                    Text(AppText.Common.proxy).tag(SteamTransport.proxy)
                    Text(AppText.Common.inject).tag(SteamTransport.inject)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 150).disabled(model.isOperationInProgress).nativeHelp(AppText.Diagnostics.debugTransportHelp)

                Button(AppText.Diagnostics.checkNow) {
                    model.refreshSelectedGameStatusNow()
                }.disabled(model.isOperationInProgress || model.isLoadingDetail).nativeHelp(AppText.Diagnostics.checkNowHelp)

                if model.canStopDebug {
                    Button(AppText.Diagnostics.stopDebug) {
                        model.requestStopDebug()
                    }.buttonStyle(.borderedProminent)
                } else {
                    Button(AppText.Diagnostics.runDebug) {
                        model.requestRunDebug()
                    }.buttonStyle(.borderedProminent).disabled(!model.canRunDebug)
                }
            }

            if let steamAPIFolder {
                HStack(spacing: 10) {
                    DiagnosticsPathRow(
                        label: "Steam API",
                        url: steamAPIFolder
                    ).nativeHelp(steamAPIFolderHelp)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.requiresSteamRepairForSelectedGame {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(AppText.Diagnostics.waitingForSteamRepair).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(Array(issues.enumerated()), id: \.offset) {
                _, issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption).padding(.top, 2)
                    Text(issue).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }


            if let reportURL = model.debugLastCaptureURL {
                DiagnosticsReportRow(url: reportURL)
            }
        }
    }

    private var steamAPIFolder: URL? {
        snapshot.installation.steamAPITargetURLs.first?.deletingLastPathComponent()
    }

    private var steamAPIFolderHelp: String {
        AppText.Diagnostics.steamAPIFolderHelp(
            copyCount: snapshot.installation.steamAPITargetURLs.count
        )
    }

    private var runtimeLog: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(AppText.Diagnostics.runtimeLog).font(.headline)

                if model.diagnosticLogTruncated {
                    Text(AppText.Diagnostics.logTail).font(.caption).foregroundStyle(.secondary)
                }

                if let status = model.debugSessionStatusText {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            RuntimeLogTextView(
                lines: model.diagnosticLogLines,
                error: model.diagnosticLogError
            )
        }.background(.quaternary.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous)).overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.quaternary)
        }
    }

    private var issues: [String] {
        snapshot.installation.issues
    }
}

private struct RuntimeLogTextView: View {
    private enum ScrollAnchor: Hashable {
        case bottom
    }

    let lines: [String]
    let error: String?

    var body: some View {
        ScrollViewReader {
            proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    if let error {
                        Text(AppText.Diagnostics.unableToReadRuntimeLog(error)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    } else if lines.isEmpty {
                        Text(AppText.Diagnostics.emptyRuntimeLog).foregroundStyle(Color.white.opacity(0.50)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) {
                            _, line in
                            Text(line).foregroundStyle(Color.white.opacity(0.92)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Color.clear.frame(height: 0).id(ScrollAnchor.bottom)
                }.font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color.black).onAppear {
                proxy.scrollTo(ScrollAnchor.bottom, anchor: .bottom)
            }.onChange(of: lines.count) {
                _ in
                proxy.scrollTo(ScrollAnchor.bottom, anchor: .bottom)
            }
        }
    }
}

private struct DiagnosticsReportRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Text(AppText.Diagnostics.report).font(.callout).foregroundStyle(.secondary).frame(width: 116, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                _ = NSPasteboard.general.setString(url.path, forType: .string)
            } label: {
                HStack(spacing: 5) {
                    Text(url.lastPathComponent).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "doc.on.doc").font(.caption)
                }
            }.buttonStyle(.plain).foregroundStyle(Color.accentColor).nativeHelp(AppText.Diagnostics.copyReportPath)

            Button(AppText.Common.open) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }.controlSize(.small).nativeHelp(AppText.Diagnostics.showReportInFinder)

            Spacer(minLength: 0)
        }
    }
}

private struct DiagnosticsPathRow: View {
    let label: String
    let url: URL

    private var folderExists: Bool {
        FileSystem.default.isDirectory(url)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 116, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                _ = NSPasteboard.general.setString(url.path, forType: .string)
            } label: {
                HStack(spacing: 5) {
                    Text(url.path).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "doc.on.doc").font(.caption)
                }
            }.buttonStyle(.plain).foregroundStyle(Color.accentColor).nativeHelp(AppText.Diagnostics.copyFullPath)

            Button(AppText.Common.open) {
                _ = NSWorkspace.shared.open(url)
            }.controlSize(.small).disabled(!folderExists).nativeHelp(folderExists ? AppText.Diagnostics.openInFinder : AppText.Diagnostics.folderDoesNotExist)

            Spacer(minLength: 0)
        }
    }
}