import Foundation
import NXLibraryCore
import ArcanePorting

/// A game the launch screen and the session card show: an nxnative build, a Steam game or a Windows game
/// (GamePort). They all read the same way; only where their art comes from differs (`GameArtLoader`).
enum PlayedGame: Equatable {
    case nxnative(PortedGame)
    case steam(CatalogGame)
    case windows(UnifiedHubGame)

    var id: UUID {
        switch self {
        case .nxnative(let game): return game.id
        case .steam(let game): return game.id
        case .windows(let game): return game.id
        }
    }

    var name: String {
        switch self {
        case .nxnative(let game): return game.name
        case .steam(let game): return game.name
        case .windows(let game): return game.title
        }
    }
}
