import AppKit
import GamePortKit

/// A Windows game that Mac Steam installed itself (with NotProton or a similar tool), started by
/// asking Mac Steam, which then runs it the way it was set up to. GamePort only watches for the game.
struct MacSteamStart: Equatable {
    let appID: Int
    let title: String
    let since: Date
    var running = false
}

extension GamePortConsoleModel {
    /// Asks Mac Steam to start a Windows game from its own library and watches for the game's process.
    /// When the game has not come up after `MacSteamWindowsLaunch.patience`, Play switches to the next
    /// way for this game (the Steam Bridge on the same files when it can) and says so. A game that turns
    /// up later, before `watchLimit`, still counts as started.
    func startInMacSteam(appID: Int, game: UnifiedHubGame) {
        guard busy == nil else { return }
        guard let install = externalEnv.macSteamWindowsGame(appID: appID),
              let url = MacSteamWindowsLaunch.launchURL(appID: appID) else { return }
        if let current = macSteamStart, current.appID == appID { return }
        let title = game.title
        macSteamStartFailed.remove(appID)
        let exe = install.folder.flatMap { SteamDepotManager.discoverMainExecutable(in: $0, preferredName: title) }
        let markers = MacSteamWindowsLaunch.markers(installDir: install.installDir, executable: exe)
        SoundEffectService.shared.play(.launch)
        NSWorkspace.shared.open(url)
        let started = Date()
        macSteamStart = MacSteamStart(appID: appID, title: title, since: started)
        say("Asked Mac Steam to start \(title)")

        macSteamStartTask?.cancel()
        macSteamStartTask = Task { [weak self] in
            var seen = false
            var gone = 0
            var gaveUp = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                let running = await Task.detached(priority: .utility) { MacSteamWindowsLaunch.isRunning(markers: markers) }.value
                guard let self, !Task.isCancelled else { return }
                let waited = Date().timeIntervalSince(started)
                if running {
                    gone = 0
                    if !seen {
                        seen = true
                        self.macSteamStartFailed.remove(appID)
                        self.macSteamStart = MacSteamStart(appID: appID, title: title, since: started, running: true)
                        self.say("✓ \(title) is running, started by Mac Steam")
                    }
                } else if seen {
                    // Two checks in a row without it: the game was closed (one miss can be a restart).
                    gone += 1
                    if gone >= 2 { self.macSteamStart = nil; return }
                } else if !gaveUp, waited > MacSteamWindowsLaunch.patience {
                    gaveUp = true
                    self.macSteamStart = nil
                    self.macSteamStartFailed.insert(appID)
                    self.say("✗ " + self.macSteamDidNotStart(game))
                } else if waited > MacSteamWindowsLaunch.watchLimit {
                    return
                }
            }
        }
    }

    /// What to say when Mac Steam did not start the game, naming what Play does now.
    private func macSteamDidNotStart(_ game: UnifiedHubGame) -> String {
        let next = playRoute(for: game)
        let lead = "Mac Steam did not start \(game.title)."
        switch next {
        case .bridge: return lead + " Press Play to run it with the Steam Bridge instead, from the same files."
        case .windowsSteam: return lead + " Press Play to run it through Windows Steam instead."
        default: return lead + " Options lists the other ways to play it."
        }
    }
}
