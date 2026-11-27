import AppKit
import GamePortKit
import NXLibraryCore

/// The one way the Play button starts a Windows/PC game, chosen by GamePort, plus the other ways the
/// game can be played (listed under Options). Spotlight's pill, A on the tile and Options all use this,
/// so they can never disagree.
enum HubPlayRoute: Equatable {
    /// The Mac version, through Mac Steam.
    case macSteam(appID: Int)
    /// A Mac version exists but is not installed: Mac Steam installs it.
    case installMac(appID: Int)
    /// The Windows version Mac Steam installed itself (only possible with Steam Play turned on, by NotProton
    /// or a similar tool): Mac Steam starts it with that tool. `tool` names it when GamePort recognizes it.
    case macSteamWindows(appID: Int, tool: String?)
    /// The Windows version GamePort downloaded, through the Steam Bridge (Mac Steam, no Windows Steam).
    case bridge(appID: Int, exe: URL, offline: Bool)
    /// Windows Steam inside the game's own Windows copy starts the game.
    case windowsSteam(profileID: String)
    /// A profile without a Steam game (custom program).
    case profile(profileID: String)
    case battleNet(profileID: String)
    /// Download the Windows version without Windows Steam (Steam Mobile QR sign-in once).
    case download(appID: Int)
    /// VAC games need Windows Steam: install it into the game's Windows copy.
    case installWindowsSteam(profileID: String)
    /// Windows Steam is there but the game is not: open Steam to install it.
    case openWindowsSteam(profileID: String)
    /// Put GamePort's download into Windows Steam's library (APFS clone, no extra space).
    case addToWindowsSteam(profileID: String)
    /// No profile yet: create the game's Windows copy.
    case setUp(appID: Int)
    case crossOverBottle(CrossOverBottleLaunchItem)
    /// Run a CrossOver bottle's game with GamePort's own Wine: the bottle is APFS-cloned into a profile once
    /// (seconds, no extra space; the bottle is never changed), then the game starts.
    case gamePortWine(CrossOverBottleLaunchItem)
    case storefront(StorefrontGame)
    case epicDownload(StorefrontGame)
    case storesSetup
    case obelisk(URL)
    case siliconium(URL)

    /// The pill's title.
    var title: String {
        switch self {
        case .macSteam, .macSteamWindows, .bridge, .windowsSteam, .profile, .crossOverBottle, .storefront, .gamePortWine: return "Play"
        case .installMac: return "Install"
        case .battleNet: return "Open Battle.net"
        case .download, .epicDownload: return "Download"
        case .installWindowsSteam: return "Install Steam"
        case .openWindowsSteam: return "Install in Steam"
        case .addToWindowsSteam: return "Add to Windows Steam"
        case .setUp: return "Set Up"
        case .storesSetup: return "Stores & Setup"
        case .obelisk: return "Play with Obelisk"
        case .siliconium: return "Play with Siliconium"
        }
    }

    /// The name used in "Other ways to play".
    var otherWayTitle: String {
        switch self {
        case .macSteam: return "Play the Mac version"
        case .installMac: return "Install the Mac version"
        case .macSteamWindows(_, let tool): return tool.map { "Play from Mac Steam (\($0))" } ?? "Play from Mac Steam"
        case .bridge(_, _, let offline): return offline ? "Play offline through Mac Steam" : "Play through Mac Steam (no Windows Steam)"
        case .windowsSteam: return "Play through Windows Steam"
        case .download: return "Download without Windows Steam"
        case .installWindowsSteam: return "Install Windows Steam for this game"
        case .openWindowsSteam: return "Open Windows Steam"
        case .addToWindowsSteam: return "Add this download to Windows Steam"
        case .crossOverBottle(let item): return "Play in CrossOver (\(item.bottleName))"
        case .gamePortWine: return "Play with GamePort's Wine instead of CrossOver"
        case .obelisk: return "Open Obelisk"
        case .siliconium: return "Open Siliconium"
        default: return title
        }
    }

    /// One line under the pills: how the game will run, in plain words.
    /// `vac`: the game uses Valve Anti-Cheat, which is why it needs Windows Steam at all.
    func how(engine: String = "Wine", vac: Bool = false) -> String {
        switch self {
        case .macSteam: return "Mac version · starts through Steam"
        case .installMac: return "A Mac version exists · Steam installs it"
        case .macSteamWindows(_, let tool):
            return tool.map { "Windows version in your Mac Steam · Mac Steam starts it with \($0)" }
                ?? "Windows version in your Mac Steam · Mac Steam starts it the way it was set up"
        case .bridge(_, _, let offline):
            return offline ? "Windows version · offline only, this game's anti-cheat needs Windows Steam online"
                           : "Windows version · runs with \(engine) · signed in through your Mac Steam"
        case .windowsSteam: return "Windows version · runs with \(engine) · started by Windows Steam"
        case .profile: return "Windows program · runs with \(engine)"
        case .battleNet: return "Windows version · runs with \(engine) · started by Battle.net"
        case .download: return "Not downloaded yet · GamePort downloads it with your Steam account, no Windows Steam needed"
        case .installWindowsSteam:
            return vac ? "This game uses VAC, so it needs Windows Steam. GamePort installs it for this game only."
                : "GamePort installs Windows Steam inside this game's own Windows copy, for this game only."
        case .openWindowsSteam:
            return vac ? "This game uses VAC · install it from Windows Steam" : "Opens Windows Steam in this game's Windows copy"
        case .addToWindowsSteam: return "Windows Steam can use GamePort's download without copying it"
        case .setUp: return "Not set up yet · GamePort prepares a Windows copy for it"
        case .crossOverBottle(let item): return "Installed in your CrossOver bottle \u{201C}\(item.bottleName)\u{201D} · runs with CrossOver"
        case .gamePortWine(let item):
            return "From your CrossOver bottle \u{201C}\(item.bottleName)\u{201D} · runs with GamePort's Wine, the bottle stays as it is"
        case .storefront(let game): return "Windows version · runs with \(engine) · \(game.store.displayName)"
        case .epicDownload: return "Not downloaded yet · Epic Games"
        case .storesSetup: return "Sign in to the store to download it"
        case .obelisk: return "This game's anti-cheat needs Obelisk"
        case .siliconium: return "Classic Call of Duty runs best with Siliconium"
        }
    }

    /// Plain words for the Steam row of "What this game uses".
    var steamRoute: String? {
        switch self {
        case .macSteam, .installMac: return "Mac Steam (Mac version)"
        case .macSteamWindows(_, let tool): return "Mac Steam, with \(tool ?? "its Steam Play tool")"
        case .bridge(_, _, let offline): return offline ? "Mac Steam through the Steam Bridge, offline" : "Mac Steam through the Steam Bridge"
        case .windowsSteam, .openWindowsSteam, .installWindowsSteam: return "Windows Steam inside this game's Windows copy"
        default: return nil
        }
    }
}

extension GamePortConsoleModel {
    /// The Windows program GamePort downloaded for this game (without Windows Steam), or the game's
    /// program inside the profile's Windows Steam library.
    func downloadedExecutable(for game: UnifiedHubGame) -> URL? {
        guard let appID = game.steamAppID else { return nil }
        if let depot = gameport.steamDepot.downloadedExecutable(appID: appID, preferredName: game.title) { return depot }
        guard case .profile(let profile, _) = game.kind,
              let steam = try? gameport.steam(for: profile.id), steam.isGameInstalled(appID: appID) else {
            return macSteamWindowsExecutable(appID: appID, title: game.title)
        }
        let manifest = steam.steamapps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8),
              let range = text.range(of: #""installdir"\s+"([^"]+)""#, options: .regularExpression) else { return nil }
        let line = String(text[range])
        guard let last = line.lastIndex(of: "\""), let previous = line[..<last].lastIndex(of: "\"") else { return nil }
        let folder = steam.steamapps.appendingPathComponent("common/\(line[line.index(after: previous)..<last])", isDirectory: true)
        return SteamDepotManager.discoverMainExecutable(in: folder, preferredName: game.title)
    }

    /// The program of the Windows version Mac Steam installed, so the Bridge can run the same files
    /// instead of downloading the game again.
    func macSteamWindowsExecutable(appID: Int, title: String) -> URL? {
        guard let folder = externalEnv.macSteamWindowsGame(appID: appID)?.folder else { return nil }
        return SteamDepotManager.discoverMainExecutable(in: folder, preferredName: title)
    }

    /// Mac Steam starts this game itself: the Windows version is in its library, and it did not fail to start it this time.
    private func macSteamWindowsRoute(_ appID: Int?) -> HubPlayRoute? {
        guard let appID, externalEnv.macSteamWindowsGame(appID: appID) != nil else { return nil }
        return .macSteamWindows(appID: appID, tool: externalEnv.notProtonInstalled ? "NotProton" : nil)
    }

    /// True for VAC games: the Bridge can only play them offline.
    func isVACBlockedForBridge(_ game: UnifiedHubGame) -> Bool {
        if case .blocked = SteamBridge.vacDecision(for: game.antiCheat) { return true }
        return false
    }

    /// The game is in the profile's Windows Steam library.
    private func windowsSteamHas(_ game: UnifiedHubGame, profileID: String) -> (hasSteam: Bool, hasGame: Bool) {
        guard let steam = try? gameport.steam(for: profileID) else { return (false, false) }
        return (steam.isInstalled, game.steamAppID.map { steam.isGameInstalled(appID: $0) } ?? false)
    }

    private func bottleItem(of game: UnifiedHubGame) -> CrossOverBottleLaunchItem? {
        if case .crossOverBottle(let item) = game.kind { return item }
        return nil
    }

    private func crossOverItem(for game: UnifiedHubGame) -> CrossOverBottleLaunchItem? {
        guard let appID = game.steamAppID else { return nil }
        return crossOverGames.first { $0.kind == .steam(appID: appID) }
    }

    /// What Play does for this game. Order of preference: the Mac version; anti-cheat helpers when the game
    /// cannot run otherwise; the Bridge (fastest start, no Windows Steam); Windows Steam; then whatever gets
    /// the game installed.
    func playRoute(for game: UnifiedHubGame) -> HubPlayRoute {
        let appID = game.steamAppID
        if let appID, externalEnv.macSteamNativeGame(appID: appID) != nil { return .macSteam(appID: appID) }
        // A Windows version Mac Steam installed itself runs the way the player set Mac Steam up (NotProton or
        // similar), unless that did not work this time. A GamePort profile for the game keeps its own way.
        let gamePort = usesGamePort(game)
        // The player chose NotProton's or CrossOver's own way in Options.
        if runner(for: game) == .own, let route = ownRunnerRoute(for: game) { return route }
        if !gamePort, case .ownedSteam = game.kind, let route = macSteamWindowsRoute(appID),
           let appID, !macSteamStartFailed.contains(appID) {
            return route
        }
        // Obelisk leads only when Wine alone cannot run the game.
        if game.antiCheat?.risk == .blocked,
           ExternalEnvironment.suggestsObelisk(for: game.antiCheat), let app = externalEnv.obeliskApp {
            return .obelisk(app)
        }
        if ExternalEnvironment.suggestsSiliconium(steamAppID: appID), let app = externalEnv.siliconiumApp {
            return .siliconium(app)
        }
        let vac = isVACBlockedForBridge(game)
        let exe = downloadedExecutable(for: game)
        let bridgeReady = bridgeStatus.isReadyToLaunch

        switch game.kind {
        case .crossOverBottle(let item):
            // Without a working CrossOver the bottle's Steam games still play, on GamePort's Wine.
            if crossOverInstallation?.hasExecutableWine != true || gamePort, case .steam = item.kind { return .gamePortWine(item) }
            return .crossOverBottle(item)
        case .storefront(let store):
            if store.isInstalled { return .storefront(store) }
            return store.store == .epic ? .epicDownload(store) : .storesSetup
        case .ownedSteam(let owned, _):
            if owned.supportsMacOS { return .installMac(appID: owned.appID) }
            if let exe, bridgeReady, !vac { return .bridge(appID: owned.appID, exe: exe, offline: false) }
            if !gamePort, let item = crossOverItem(for: game) { return bottleRoute(item) }
            // Files already on this Mac are never downloaded again: Mac Steam tries once more.
            if !gamePort, let route = macSteamWindowsRoute(appID) { return route }
            return vac ? .setUp(appID: owned.appID) : .download(appID: owned.appID)
        case .profile(let profile, let recipe):
            if recipe?.launch == .battlenet { return .battleNet(profileID: profile.id) }
            guard let appID else { return .profile(profileID: profile.id) }
            let win = windowsSteamHas(game, profileID: profile.id)
            // Windows Steam also wins when the Bridge failed the last time and Windows Steam worked.
            if win.hasGame && (vac || !bridgeReady || bridgeLikelyFails(profileID: profile.id, appID: appID)) {
                return .windowsSteam(profileID: profile.id)
            }
            // A profile without a copy of its own (no GamePort download, nothing in its Windows Steam) plays the
            // copy Mac Steam installed, the way Mac Steam was set up, unless that did not work this time.
            let ownCopy = win.hasGame || gameport.steamDepot.downloadedExecutable(appID: appID, preferredName: game.title) != nil
            if !ownCopy, !gamePort, let route = macSteamWindowsRoute(appID), !macSteamStartFailed.contains(appID) {
                return route
            }
            if let exe, bridgeReady, !vac {
                // A copy only in Windows Steam's library is still played through the Bridge: no Windows Steam start.
                return .bridge(appID: appID, exe: exe, offline: false)
            }
            if win.hasGame { return .windowsSteam(profileID: profile.id) }
            if !gamePort, let item = crossOverItem(for: game) { return bottleRoute(item) }
            if !gamePort, let route = macSteamWindowsRoute(appID) { return route }
            if !vac { return .download(appID: appID) }
            return win.hasSteam ? .openWindowsSteam(profileID: profile.id) : .installWindowsSteam(profileID: profile.id)
        }
    }

    /// The Bridge failed here last time while Windows Steam worked, or it fails for most other players
    /// (and has not worked on this Mac).
    func bridgeLikelyFails(profileID: String, appID: Int) -> Bool {
        let sessions = playSessions(profileID)
        if sessions.prefersWindowsSteamOverBridge { return true }
        guard sessions.lastConclusive(.bridge)?.outcome != .worked else { return false }
        return gameport.communityAdvice(steamAppID: appID)?.prefersWindowsSteam == true
    }

    private func bottleRoute(_ item: CrossOverBottleLaunchItem) -> HubPlayRoute {
        crossOverInstallation?.hasExecutableWine == true ? .crossOverBottle(item) : .gamePortWine(item)
    }

    /// Every other way this game can be played or installed, for Options.
    func otherRoutes(for game: UnifiedHubGame) -> [HubPlayRoute] {
        let primary = playRoute(for: game)
        var routes: [HubPlayRoute] = []
        let appID = game.steamAppID
        let vac = isVACBlockedForBridge(game)
        let exe = downloadedExecutable(for: game)
        if let appID {
            if externalEnv.macSteamNativeGame(appID: appID) != nil { routes.append(.macSteam(appID: appID)) }
            else if game.supportsMacOS { routes.append(.installMac(appID: appID)) }
            if let route = macSteamWindowsRoute(appID) { routes.append(route) }
            if let exe, bridgeStatus.isReadyToLaunch { routes.append(.bridge(appID: appID, exe: exe, offline: vac)) }
        }
        if case .profile(let profile, let recipe) = game.kind, recipe?.launch != .battlenet, appID != nil {
            let win = windowsSteamHas(game, profileID: profile.id)
            if win.hasGame { routes.append(.windowsSteam(profileID: profile.id)) }
            else if win.hasSteam, gameport.steamDepot.downloadedExecutable(appID: appID!, preferredName: game.title) != nil {
                routes.append(.addToWindowsSteam(profileID: profile.id))
            }
            if win.hasSteam { routes.append(.openWindowsSteam(profileID: profile.id)) }
            else { routes.append(.installWindowsSteam(profileID: profile.id)) }
        }
        if let appID, exe == nil, game.kind.isSteam { routes.append(.download(appID: appID)) }
        if let item = crossOverItem(for: game) ?? bottleItem(of: game) {
            if crossOverInstallation?.hasExecutableWine == true { routes.append(.crossOverBottle(item)) }
            if case .steam = item.kind, gameport.bottleProfile(for: item) == nil { routes.append(.gamePortWine(item)) }
        }
        if ExternalEnvironment.suggestsObelisk(for: game.antiCheat), let app = externalEnv.obeliskApp { routes.append(.obelisk(app)) }
        if ExternalEnvironment.suggestsSiliconium(steamAppID: appID), let app = externalEnv.siliconiumApp { routes.append(.siliconium(app)) }
        var seen: [HubPlayRoute] = [primary]
        return routes.filter { route in
            guard !seen.contains(route) else { return false }
            seen.append(route)
            return true
        }
    }

    /// Does what the route says.
    func perform(_ route: HubPlayRoute, for game: UnifiedHubGame) {
        guard busy == nil else { return }
        let title = game.title
        // The launch screen and the session card follow the game (`HubPlayWatch`). Posted before the route runs:
        // a route that hands over to another (an adopted bottle) posts again, and the later one is followed.
        if route.isPlayable {
            NotificationCenter.default.post(name: .nxHubPlayStarted, object: HubPlayStart(game: game, route: route))
        }
        switch route {
        case .macSteam(let appID):
            if let url = URL(string: "steam://rungameid/\(appID)") { NSWorkspace.shared.open(url) }
        case .installMac(let appID):
            if let url = URL(string: "steam://install/\(appID)") { NSWorkspace.shared.open(url) }
        case .macSteamWindows(let appID, _):
            startInMacSteam(appID: appID, game: game)
        case .bridge(let appID, let exe, let offline):
            launchBridge(game, appID: appID, exe: exe, allowVACOverride: offline)
        case .windowsSteam(let profileID), .profile(let profileID):
            if case .profile(let profile, let recipe?) = game.kind, profile.id == profileID {
                launchGame(profile: profile, recipe: recipe)
            } else {
                job("Starting \(title)") { k, p in _ = try k.play(profileID, progress: p); return "Launched \(title)" }
            }
        case .battleNet(let profileID):
            job("Opening \(title)") { k, p in _ = try k.openBattleNet(profileID, progress: p); return "Battle.net opened" }
        case .download(let appID):
            startSteamDownload(appID: appID, title: title, origin: .spotlight, vacNote: isVACBlockedForBridge(game))
        case .installWindowsSteam(let profileID):
            job("Installing Windows Steam for \(title)") { k, p in
                try await k.steam(for: profileID).install(progress: p)
                _ = try k.openSteam(profileID, progress: p)
                return "Windows Steam is installed and open"
            }
        case .openWindowsSteam(let profileID):
            job("Opening Windows Steam") { k, p in _ = try k.openSteam(profileID, progress: p); return "Windows Steam opened" }
        case .addToWindowsSteam(let profileID):
            job("Adding \(title) to Windows Steam") { k, p in
                _ = try k.addDepotToWindowsSteam(profileID, progress: p)
                return "\(title) is in Windows Steam's library"
            }
        case .setUp(let appID):
            let recipe: Recipe? = { if case .ownedSteam(_, let r) = game.kind { return r }; return nil }()
            let engineID = preferredWindowsEngineID()
            let renderer: Renderer = engineID == CrossOverInstallation.engineID ? .d3dmetal : .dxmt
            job("Setting up \(title)") { k, p in
                let recipeID = try recipe?.id ?? k.addCustomSteamGame(appID: appID, title: title, renderer: renderer).id
                return "Ready: \(try k.createProfile(recipeID: recipeID, engineID: engineID, progress: p).id)"
            }
        case .crossOverBottle(let item):
            launchCrossOverGame(item)
        case .gamePortWine(let item):
            if let profile = gameport.bottleProfile(for: item) { playAdoptedBottle(profile, game: game); return }
            job("Moving \(title) to GamePort's Wine", then: { [weak self] in
                guard let self, let profile = self.gameport.bottleProfile(for: item) else { return }
                self.playAdoptedBottle(profile, game: game)
            }) { k, p in
                _ = try k.adoptCrossOverBottleGame(item, progress: p)
                return "\(title) runs with GamePort's Wine now. Your CrossOver bottle is unchanged."
            }
        case .storefront(let store):
            launchStorefrontGame(store)
        case .epicDownload(let store):
            downloadEpicGame(store)
        case .storesSetup:
            break // Spotlight opens the Windows games screen for this one.
        case .obelisk(let app), .siliconium(let app):
            NSWorkspace.shared.open(app)
            say("Opened \(app.deletingPathExtension().lastPathComponent). Start \(title) from there.")
        }
    }

    /// Plays a bottle game that already has its GamePort profile: through the Bridge when it can (no Windows
    /// Steam start), else through the bottle's own Windows Steam, which came over signed in.
    private func playAdoptedBottle(_ profile: Profile, game: UnifiedHubGame) {
        let recipe = profile.recipeID.flatMap { id in recipes.first { $0.id == id } }
        let adopted = UnifiedHubGame(id: game.id, title: game.title, runnerBadge: game.runnerBadge, storeBadge: game.storeBadge,
                                     isReady: true, supportsMacOS: game.supportsMacOS, playtimeMinutes: game.playtimeMinutes,
                                     lastPlayed: game.lastPlayed, steamAppID: game.steamAppID, localArtwork: game.localArtwork,
                                     remotePosterURL: game.remotePosterURL, remoteHeroURL: game.remoteHeroURL,
                                     remoteLogoURL: game.remoteLogoURL, antiCheat: game.antiCheat, kind: .profile(profile, recipe))
        perform(playRoute(for: adopted), for: adopted)
    }

    /// Starts the game through the Steam Bridge, creating its profile first when it has none.
    private func launchBridge(_ game: UnifiedHubGame, appID: Int, exe: URL, allowVACOverride: Bool) {
        let engineID = preferredWindowsEngineID()
        let renderer: Renderer = engineID == CrossOverInstallation.engineID ? .d3dmetal : .dxmt
        let kind = game.kind
        let title = game.title
        launchViaBridge(title: title, executable: exe, allowVACOverride: allowVACOverride) { k, p in
            if case .profile(let existing, _) = kind { return existing.id }
            let recipeID: String
            if case .ownedSteam(_, let recipe?) = kind { recipeID = recipe.id }
            else { recipeID = try k.addCustomSteamGame(appID: appID, title: title, renderer: renderer).id }
            return try k.createProfile(recipeID: recipeID, engineID: engineID, progress: p).id
        }
    }

    /// The Wine that runs the game, in a couple of words.
    func engineName(for game: UnifiedHubGame) -> String {
        guard case .profile(let profile, _) = game.kind else {
            return preferredWindowsEngineID() == CrossOverInstallation.engineID ? "CrossOver" : "Wine"
        }
        if profile.engineID == CrossOverInstallation.engineID { return "your CrossOver" }
        return installedEngines.first { $0.id == profile.engineID }.map { GameSetup.shortName($0.manifest.displayName) } ?? "Wine"
    }

    // MARK: - Favorites

    private static let hubFavoritesKey = "GamePort.hubFavorites"

    var hubFavorites: Set<UUID> {
        let stored = AppData.preferences.stringArray(forKey: Self.hubFavoritesKey) ?? []
        return Set(stored.compactMap(UUID.init(uuidString:)))
    }

    func isFavorite(_ game: UnifiedHubGame) -> Bool { hubFavorites.contains(game.id) }

    func toggleFavorite(_ game: UnifiedHubGame) {
        objectWillChange.send()
        var set = hubFavorites
        if !set.insert(game.id).inserted { set.remove(game.id) }
        AppData.preferences.set(set.map(\.uuidString).sorted(), forKey: Self.hubFavoritesKey)
    }

    // MARK: - Hidden

    private static let hubHiddenKey = "GamePort.hubHidden"

    /// Windows games the player hid from Game options: out of Spotlight and search, back from Settings.
    var hubHidden: Set<UUID> {
        let stored = AppData.preferences.stringArray(forKey: Self.hubHiddenKey) ?? []
        return Set(stored.compactMap(UUID.init(uuidString:)))
    }

    func isHidden(_ game: UnifiedHubGame) -> Bool { hubHidden.contains(game.id) }

    private static let hubRunnerKey = "GamePort.hubRunner"

    /// Who runs a Windows game that Mac Steam (NotProton) or CrossOver can run with their own settings, as the
    /// player chose in Options (Use GamePort's settings). No choice: Play picks as usual.
    enum HubRunner: String { case gamePort, own }

    private var hubRunners: [String: String] {
        (AppData.preferences.dictionary(forKey: Self.hubRunnerKey) as? [String: String]) ?? [:]
    }

    func runner(for game: UnifiedHubGame) -> HubRunner? {
        hubRunners[game.id.uuidString].flatMap(HubRunner.init(rawValue:))
    }

    func usesGamePort(_ game: UnifiedHubGame) -> Bool { runner(for: game) == .gamePort }

    func setRunner(_ runner: HubRunner, _ game: UnifiedHubGame) {
        objectWillChange.send()
        var all = hubRunners
        all[game.id.uuidString] = runner.rawValue
        AppData.preferences.set(all, forKey: Self.hubRunnerKey)
    }

    /// The way Mac Steam (NotProton) or CrossOver runs this game with its own settings, when there is one.
    func ownRunnerRoute(for game: UnifiedHubGame) -> HubPlayRoute? {
        let crossOver = crossOverInstallation?.hasExecutableWine == true
        if case .crossOverBottle(let item) = game.kind { return crossOver ? .crossOverBottle(item) : nil }
        if let appID = game.steamAppID, !macSteamStartFailed.contains(appID), let route = macSteamWindowsRoute(appID) {
            return route
        }
        if crossOver, let item = crossOverItem(for: game) { return .crossOverBottle(item) }
        return nil
    }

    func hasOwnRunner(_ game: UnifiedHubGame) -> Bool { ownRunnerRoute(for: game) != nil }

    func setHidden(_ hidden: Bool, _ game: UnifiedHubGame) {
        objectWillChange.send()
        var set = hubHidden
        if hidden { set.insert(game.id) } else { set.remove(game.id) }
        AppData.preferences.set(set.map(\.uuidString).sorted(), forKey: Self.hubHiddenKey)
    }

    /// The hidden Windows games still found on this Mac, by name.
    var hiddenHubGames: [UnifiedHubGame] {
        let hidden = hubHidden
        return unifiedGames.filter { hidden.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The Windows games Spotlight, Collection and search show: not hidden, and not already in the library as a Steam game.
    func visibleHubGames(besidesSteamAppIDs existing: Set<Int>) -> [UnifiedHubGame] {
        let hidden = hubHidden
        return unifiedGames.filter { game in
            if hidden.contains(game.id) { return false }
            if let appID = game.steamAppID, existing.contains(appID) { return false }
            return true
        }
    }

    /// The Windows games a home tab (Spotlight's or Collection's) shows, after the library's own games.
    func visibleHubGames(filter: LibraryFilter, besidesSteamAppIDs existing: Set<Int>) -> [UnifiedHubGame] {
        let base = visibleHubGames(besidesSteamAppIDs: existing)
        switch filter {
        case .all: return base
        case .installed: return base.filter(\.isReady)
        case .recentlyPlayed: return base.filter { $0.lastPlayed != nil || $0.isReady }
        case .notPlayed: return base.filter { $0.playtimeMinutes == 0 }
        case .favorites: return base.filter { isFavorite($0) }
        }
    }
}

extension UnifiedHubGame.Kind {
    var isSteam: Bool {
        switch self {
        case .profile(_, let recipe): return recipe?.launch != .battlenet
        case .ownedSteam: return true
        case .crossOverBottle, .storefront: return false
        }
    }
}
