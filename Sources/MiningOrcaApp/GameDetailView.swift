@preconcurrency import AppKit
import SwiftUI
import MiningOrcaLauncherCore

struct GameDetailView: View {
    @ObservedObject var model: LauncherAppModel
    let snapshot: GameDetailSnapshot

    var body: some View {
        VStack(spacing: 0) {
            GameBannerHeader(
                game: snapshot.game,
                artwork: model.artworkByAppID[snapshot.game.appID]
            )

            GameTabStrip(selection: $model.selectedTab, dlcCount: snapshot.dlcs.dlcs.count)

            Group {
                switch model.selectedTab {
                case .overview:
                    OverviewView(model: model, snapshot: snapshot)
                case .dlcs:
                    DLCListView(model: model, snapshot: snapshot)
                case .advanced:
                    AdvancedConfigurationView(model: model)
                case .diagnostics:
                    DiagnosticsView(model: model, snapshot: snapshot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(CommitTextEditingOnOutsideClick())
        .alert(
            AppText.GameDetail.steamRunning,
            isPresented: $model.isSteamRunningPromptPresented
        ) {
            Button(AppText.GameDetail.steamRunningCancel, role: .cancel) {
                model.cancelSteamRunningPrompt()
            }
            Button(AppText.GameDetail.steamRunningContinue) {
                model.continueSteamRunningOperation()
            }
        } message: {
            Text(AppText.GameDetail.steamRunningMessage)
        }
    }
}

private struct CommitTextEditingOnOutsideClick: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.installMonitor()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var hostView: NSView?
        private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let window = self?.hostView?.window,
                      event.window === window,
                      let fieldEditor = window.firstResponder as? NSTextView,
                      fieldEditor.isFieldEditor,
                      let textField = fieldEditor.delegate as? NSTextField else {
                    return event
                }

                let point = textField.convert(event.locationInWindow, from: nil)
                guard !textField.bounds.contains(point) else {
                    return event
                }

                _ = window.makeFirstResponder(nil)
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

private struct GameBannerHeader: View {
    let game: SteamGame
    let artwork: GameArtworkImages?

    var body: some View {
        ZStack(alignment: .leading) {
            BannerMediaPlaceholder()

            HStack(spacing: 18) {
                GameArtwork(artwork: artwork)

                VStack(alignment: .leading, spacing: 6) {
                    Text(game.name)
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(1)

                    Text(AppText.GameDetail.appID(game.appID))
                        .foregroundStyle(.secondary)

                    Text(game.installDirectory.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 16)

                if let url = URL(string: "steam://run/\(game.appID)") {
                    Link(destination: url) {
                        Label(AppText.GameDetail.openInSteam, systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 22)
        }
        .frame(height: 160)
        .clipped()
    }
}

private struct BannerMediaPlaceholder: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.13),
                Color(nsColor: .windowBackgroundColor).opacity(0.96),
            ],
            startPoint: .trailing,
            endPoint: .leading
        )
        .overlay(alignment: .trailing) {
            if let image = BannerArtwork.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 540, height: 160)
                    .clipped()
                    .opacity(0.55)
                    .padding(.trailing, 180)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private enum BannerArtwork {
    static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "orca_banner", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("icons/orca_banner.png", isDirectory: false)
        return NSImage(contentsOf: developmentURL)
    }()
}

private struct GameArtwork: View {
    let artwork: GameArtworkImages?

    var body: some View {
        Group {
            if let image = artwork?.cover {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 112, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.quaternary)
        }
    }
}

private struct GameTabStrip: View {
    @Binding var selection: GameDetailTab
    let dlcCount: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(GameDetailTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(AppText.GameDetail.tabTitle(tab, dlcCount: dlcCount))
                        .fontWeight(selection == tab ? .semibold : .regular)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .frame(minWidth: 100)
                        .background(selection == tab ? Color.accentColor.opacity(0.10) : Color.clear)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

}
