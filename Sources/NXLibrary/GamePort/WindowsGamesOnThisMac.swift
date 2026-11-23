import Foundation
import GamePortKit

/// The first launch's count of Windows games already on this Mac: Steam games in CrossOver bottles, Windows
/// games that Mac Steam installed (NotProton) and GamePort's own games. Reads only; blocking, run it on a worker.
enum WindowsGamesOnThisMac {
    static func count() -> Int {
        let environment = ExternalDiscovery.scan()
        var steamApps = Set<Int>()
        for bottle in environment.crossoverBottles {
            for game in bottle.steamGames where game.fullyInstalled { steamApps.insert(game.appID) }
        }
        for game in environment.macSteamGames where game.platform == .windows && game.fullyInstalled {
            steamApps.insert(game.appID)
        }
        return steamApps.count + GamePort().profiles.all().count
    }
}
