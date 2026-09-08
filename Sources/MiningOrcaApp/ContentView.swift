import SwiftUI
import MiningOrcaLauncherCore

struct ContentView: View {
    @ObservedObject var model: LauncherAppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .alert(
            AppText.Common.appName,
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(AppText.Common.ok, role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.selectedGameID },
            set: { newValue in
                model.selectedGameID = newValue
                model.selectedGameChanged()
            }
        )) {
            if model.isLoadingGames && model.games.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } else {
                Section(AppText.GameDetail.installedGames) {
                    ForEach(model.filteredGames) { game in
                        GameSidebarRow(
                            game: game,
                            artwork: model.artworkByAppID[game.appID]
                        )
                        .tag(game.appID)
                    }
                }
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: AppText.GameDetail.searchGames)
    }

    @ViewBuilder
    private var detail: some View {
        if model.isLoadingDetail {
            VStack(spacing: 12) {
                ProgressView()
                Text(AppText.GameDetail.loadingGameState)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot = model.detail {
            GameDetailView(model: model, snapshot: snapshot)
        } else if model.selectedGame != nil {
            EmptyStateView(
                title: AppText.GameDetail.gameStateUnavailable,
                systemImage: "exclamationmark.triangle",
                message: AppText.GameDetail.gameStateUnavailableMessage
            )
        } else {
            EmptyStateView(
                title: AppText.GameDetail.selectSteamGame,
                systemImage: "gamecontroller",
                message: AppText.GameDetail.selectSteamGameMessage
            )
        }
    }
}

private struct GameSidebarRow: View {
    let game: SteamGame
    let artwork: GameArtworkImages?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image = artwork?.sidebar {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "gamecontroller.fill")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.quaternary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .lineLimit(1)
                Text(String(game.appID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}