import AppKit
import Foundation
import MiningOrcaLauncherCore

struct GameArtworkImages {
    let portrait: NSImage?
    let hero: NSImage?
    let header: NSImage?
    let icon: NSImage?

    init(_ artwork: SteamArtwork) {
        portrait = artwork.portraitURL.flatMap(NSImage.init(contentsOf:))
        hero = artwork.heroURL.flatMap(NSImage.init(contentsOf:))
        header = artwork.headerURL.flatMap(NSImage.init(contentsOf:))
        icon = artwork.iconURL.flatMap(NSImage.init(contentsOf:))
    }

    var cover: NSImage? {
        portrait ?? header ?? hero
    }
    var sidebar: NSImage? {
        icon ?? portrait ?? header ?? hero
    }
}

struct GameDetailSnapshot: Sendable {
    let game: SteamGame
    let installation: LauncherGameState
    let configurationSource: RuntimeConfigSource
    let dlcs: DLCDiscoveryResult

    var configuration: RuntimeConfig? {
        configurationSource.configuration
    }
}

enum GameDetailTab: CaseIterable, Identifiable {
    case overview
    case dlcs
    case advanced
    case diagnostics

    var id: Self {
        self
    }
}
