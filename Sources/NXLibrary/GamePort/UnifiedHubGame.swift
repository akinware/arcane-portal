import AppKit
import CryptoKit
import Foundation
import GamePortKit
import NXLibraryCore

/// One unified PC/Mac game tile displayed directly on Arcane's main Spotlight carousel.
/// Combines GamePort PowerKit profiles, CrossOver bottle games, signed-in Mac Steam owned games,
/// Battle.net, Epic Games, GOG, and Heroic installs into a single native console row.
struct UnifiedHubGame: Identifiable, Equatable {
    enum Kind: Equatable {
        case profile(Profile, Recipe?)
        case ownedSteam(OwnedSteamGame, Recipe?)
        case crossOverBottle(CrossOverBottleLaunchItem)
        case storefront(StorefrontGame)
    }

    let id: UUID
    let title: String
    let runnerBadge: String
    let storeBadge: String
    let isReady: Bool
    let supportsMacOS: Bool
    let playtimeMinutes: Int
    let lastPlayed: Date?
    let steamAppID: Int?
    let localArtwork: LocalSteamArtwork?
    let remotePosterURL: URL?
    let remoteHeroURL: URL?
    let remoteLogoURL: URL?
    let antiCheat: AntiCheatEntry?
    let kind: Kind

    /// Deterministic UUID derived from a canonical string key so Spotlight's selection and saved
    /// row order remain stable across restarts.
    static func stableUUID(for key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The key of the player's own art (Game Options → Change Artwork), kept with Steam games' picks.
    /// A Steam game keeps its art by AppID, so the pick survives setting it up in GamePort.
    var artworkKey: String {
        steamAppID.map { "windows-steam-\($0)" } ?? "windows-\(id.uuidString)"
    }

    /// The art the player chose for this slot, if any.
    @MainActor
    func pickedArtwork(_ slot: ArtworkSlot) -> URL? {
        SteamPersonalizations.shared.artwork.url(titleID: artworkKey, slot: slot)
    }

    @MainActor
    var preferredTileURL: URL? {
        pickedArtwork(.cover) ?? localArtwork?.poster ?? localArtwork?.header ?? remotePosterURL
    }

    /// Steam's wide header: almost every app has one, unlike the portrait library cover.
    var steamHeaderURL: URL? {
        steamAppID.flatMap { URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\($0)/header.jpg") }
    }

    @MainActor
    var preferredHeroURL: URL? {
        pickedArtwork(.background) ?? localArtwork?.hero ?? localArtwork?.header ?? remoteHeroURL
    }

    @MainActor
    var preferredLogoURL: URL? {
        pickedArtwork(.logo) ?? localArtwork?.logo ?? remoteLogoURL
    }

    var playtimeSummary: String? {
        guard playtimeMinutes > 0 else { return nil }
        if playtimeMinutes < 60 { return "\(playtimeMinutes) min played" }
        let hours = Double(playtimeMinutes) / 60.0
        return String(format: "%.1f hrs played", hours)
    }

    /// Builds the deduplicated unified carousel list, ready games first, then owned Steam/Epic titles
    /// ordered by most recently played / playtime.
    static func buildAll(
        profiles: [Profile],
        recipes: [Recipe],
        externalEnv: ExternalEnvironment,
        crossOverInstallation: CrossOverInstallation?,
        crossOverGames: [CrossOverBottleLaunchItem],
        storefrontGames: [StorefrontGame],
        epicLibrary: [StorefrontGame],
        steamDepot: SteamDepotManager
    ) -> [UnifiedHubGame] {
        let recipeByID = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recipeByAppID = Dictionary(recipes.compactMap { r in r.steamAppID.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let ownedByAppID = Dictionary(externalEnv.macSteamOwnedGames.map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
        let cxLabel = crossOverInstallation.map { "CrossOver \($0.version ?? "")".trimmingCharacters(in: .whitespaces) } ?? "PowerKit"

        var items: [UnifiedHubGame] = []
        var seenAppIDs = Set<Int>()
        var seenStoreIDs = Set<String>()

        func steamRemoteURLs(_ appID: Int?) -> (poster: URL?, hero: URL?, logo: URL?) {
            guard let id = appID else { return (nil, nil, nil) }
            return (
                URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/library_600x900_2x.jpg"),
                URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/library_hero.jpg"),
                URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/logo.png")
            )
        }

        // 1. Ready GamePort profiles (Steam, Battle.net, etc.)
        for profile in profiles {
            let recipe = profile.recipeID.flatMap { recipeByID[$0] }
            let appID = recipe?.steamAppID
            if let appID { seenAppIDs.insert(appID) }
            let owned = appID.flatMap { ownedByAppID[$0] }
            let localArt = appID.map { ExternalDiscovery.localSteamArtwork(appID: $0) }
            let remote = steamRemoteURLs(appID)
            let ac = recipe.flatMap { AntiCheatDB.bundled.entry(for: $0) } ?? appID.flatMap { AntiCheatDB.bundled.entry(steamAppID: $0) }
            let runner = profile.engineID == CrossOverInstallation.engineID ? cxLabel : "PowerKit"
            let store = recipe?.launch == .battlenet ? "Battle.net" : "Steam"
            items.append(UnifiedHubGame(
                id: stableUUID(for: "hub:profile:\(profile.id)"),
                title: recipe?.title ?? profile.title,
                runnerBadge: runner,
                storeBadge: store,
                isReady: true,
                supportsMacOS: owned?.supportsMacOS ?? false,
                playtimeMinutes: owned?.playtimeMinutes ?? 0,
                lastPlayed: owned?.lastPlayed,
                steamAppID: appID,
                localArtwork: localArt,
                remotePosterURL: remote.poster,
                remoteHeroURL: remote.hero,
                remoteLogoURL: remote.logo,
                antiCheat: ac,
                kind: .profile(profile, recipe)
            ))
        }

        // 2. Existing CrossOver bottle games (1-click Play)
        for cxItem in crossOverGames {
            var appID: Int? = nil
            if case .steam(let id) = cxItem.kind {
                appID = id
                if seenAppIDs.contains(id) { continue }
                seenAppIDs.insert(id)
            }
            let owned = appID.flatMap { ownedByAppID[$0] }
            let localArt = appID.map { ExternalDiscovery.localSteamArtwork(appID: $0) }
            let remote = steamRemoteURLs(appID)
            let ac = appID.flatMap { AntiCheatDB.bundled.entry(steamAppID: $0) }
            items.append(UnifiedHubGame(
                id: stableUUID(for: "hub:cx:\(cxItem.id)"),
                title: cxItem.title,
                runnerBadge: cxLabel,
                storeBadge: "CrossOver · \(cxItem.bottleName)",
                isReady: true,
                supportsMacOS: owned?.supportsMacOS ?? false,
                playtimeMinutes: owned?.playtimeMinutes ?? 0,
                lastPlayed: owned?.lastPlayed,
                steamAppID: appID,
                localArtwork: localArt,
                remotePosterURL: remote.poster,
                remoteHeroURL: remote.hero,
                remoteLogoURL: remote.logo,
                antiCheat: ac,
                kind: .crossOverBottle(cxItem)
            ))
        }

        // 3. Installed Epic / GOG / Heroic games + owned Epic games
        for game in storefrontGames + epicLibrary {
            guard seenStoreIDs.insert(game.id).inserted else { continue }
            items.append(UnifiedHubGame(
                id: stableUUID(for: "hub:store:\(game.id)"),
                title: game.title,
                runnerBadge: cxLabel,
                storeBadge: game.store.displayName,
                isReady: game.isInstalled,
                supportsMacOS: false,
                playtimeMinutes: 0,
                lastPlayed: nil,
                steamAppID: nil,
                localArtwork: nil,
                remotePosterURL: game.artworkURL,
                remoteHeroURL: game.artworkURL,
                remoteLogoURL: nil,
                antiCheat: nil,
                kind: .storefront(game)
            ))
        }

        // 4. All signed-in Mac Steam owned games (enriched with appinfo.vdf titles & OS support)
        for owned in externalEnv.macSteamOwnedGames {
            guard !seenAppIDs.contains(owned.appID) else { continue }
            let recipe = recipeByAppID[owned.appID]
            guard let title = owned.title ?? recipe?.title, !title.isEmpty else { continue }
            seenAppIDs.insert(owned.appID)
            let localArt = ExternalDiscovery.localSteamArtwork(appID: owned.appID)
            let remote = steamRemoteURLs(owned.appID)
            let ac = recipe.flatMap { AntiCheatDB.bundled.entry(for: $0) } ?? AntiCheatDB.bundled.entry(steamAppID: owned.appID)
            let depotReady = steamDepot.downloadedExecutable(appID: owned.appID, preferredName: title) != nil
            // Any install in Mac Steam plays: the Mac version natively, a Windows version the way Mac Steam was set up.
            let macInstalled = externalEnv.macSteamGame(appID: owned.appID) != nil
            let windowsInMacSteam = externalEnv.macSteamWindowsGame(appID: owned.appID) != nil
            let runner: String
            if owned.supportsMacOS && externalEnv.macSteamNativeGame(appID: owned.appID) != nil {
                runner = "Mac Native"
            } else if windowsInMacSteam {
                runner = externalEnv.notProtonInstalled ? "Mac Steam · NotProton" : "Mac Steam"
            } else if owned.supportsMacOS {
                runner = "Mac Native · \(cxLabel)"
            } else {
                runner = cxLabel
            }
            items.append(UnifiedHubGame(
                id: stableUUID(for: "hub:steam:\(owned.appID)"),
                title: title,
                runnerBadge: runner,
                storeBadge: "Steam",
                isReady: macInstalled || depotReady,
                supportsMacOS: owned.supportsMacOS,
                playtimeMinutes: owned.playtimeMinutes,
                lastPlayed: owned.lastPlayed,
                steamAppID: owned.appID,
                localArtwork: localArt,
                remotePosterURL: remote.poster,
                remoteHeroURL: remote.hero,
                remoteLogoURL: remote.logo,
                antiCheat: ac,
                kind: .ownedSteam(owned, recipe)
            ))
        }

        return items
    }
}
