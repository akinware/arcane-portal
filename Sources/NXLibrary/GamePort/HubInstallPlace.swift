import Foundation
import GamePortKit

/// Where a Windows game's files are on this Mac, for its Details: size on disk, Installed in, Reveal in Finder.
struct HubInstallPlace: Equatable {
    let folder: URL
    /// What the store or Steam reported; nil when nothing did (folders are not measured on every redraw).
    let sizeBytes: Int64?
    /// Who put the files there, before the volume's name ("Steam · Macintosh HD"); nil for GamePort's own copy.
    let installer: String?
}

extension GamePortConsoleModel {
    /// The game's folder when GamePort knows it without reading the disk at length: the Windows version in Mac
    /// Steam's library, a store's install, or GamePort's downloaded copy. Profiles and CrossOver bottles keep
    /// the game inside a Windows drive with everything else, so they show no place.
    func installPlace(for game: UnifiedHubGame) -> HubInstallPlace? {
        if case .storefront(let store) = game.kind, let path = store.installPath {
            return HubInstallPlace(folder: path, sizeBytes: store.sizeBytes, installer: game.storeBadge)
        }
        guard let appID = game.steamAppID else { return nil }
        if let install = externalEnv.macSteamWindowsGame(appID: appID), let folder = install.folder {
            return HubInstallPlace(folder: folder, sizeBytes: install.sizeOnDisk, installer: "Steam")
        }
        // GamePort's download, once finished (a download in progress has every file's full size already).
        let depot = gameport.steamDepot.depotDirectory(appID: appID)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: depot.path, isDirectory: &isFolder), isFolder.boolValue,
              SteamDepotManager.isDownloadComplete(appID: appID, in: depot) else { return nil }
        let manifest = try? String(contentsOf: SteamDepotManager.appManifestURL(appID: appID, in: depot), encoding: .utf8)
        return HubInstallPlace(folder: depot, sizeBytes: manifest.flatMap(Self.sizeOnDisk), installer: nil)
    }

    /// `"SizeOnDisk" "<bytes>"` from a Steam app manifest.
    static func sizeOnDisk(inManifest text: String) -> Int64? {
        guard let range = text.range(of: #""SizeOnDisk"\s+"(\d+)""#, options: .regularExpression) else { return nil }
        return Int64(text[range].filter(\.isNumber))
    }
}
