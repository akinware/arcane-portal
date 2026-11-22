import AppKit
import Foundation
import GamePortKit
import SwiftUI

/// Shared bridge connecting Arcane's Console UI to `GamePortKit`.
/// All real operations live in `GamePortKit` so CLI, GamePort.app, and Arcane stay 100% in sync.
@MainActor
final class GamePortConsoleModel: ObservableObject {
    static let shared = GamePortConsoleModel()

    var gameport = GamePort()
    @Published var checks: [GamePort.Check] = []
    @Published var engineCatalog: [EngineCatalogEntry] = []
    @Published var installedEngines: [InstalledEngine] = []
    @Published var recipes: [Recipe] = []
    @Published var profiles: [Profile] = []
    @Published var steamBase: SteamBase.Stamp?
    @Published var storageInfo: StorageInfo = StorageInfo.inspect(
        Paths.default().root,
        isCustom: StoragePreference.load().customRoot != nil
    )
    @Published var gptkAccepted = false
    @Published var telemetryEnabled = true
    @Published var x87Installed = false
    @Published var x87Version: String?
    @Published var aarchxInstalled = false
    @Published var aarchxVersion: String?
    @Published var bridgeStatus: SteamBridgeStatus = SteamBridge(paths: Paths.default()).status()
    @Published var crossOverInstallation: CrossOverInstallation?
    @Published var crossOverGames: [CrossOverBottleLaunchItem] = []
    @Published var externalEnv: ExternalEnvironment = .empty
    @Published var communityVerdicts: [Int: [CommunityVerdict]] = [:]
    @Published var launchState: LaunchState = .idle
    @Published var busy: String?
    @Published var statusLog: [String] = []

    private var profilesByRecipe: [String: Profile] = [:]
    private var labResultsByProfile: [String: [LabResult]] = [:]
    private var launchMonitorTask: Task<Void, Never>?

    init() {
        communityVerdicts = gameport.telemetry.loadCachedVerdicts()
        refresh()
        refreshCommunityVerdicts()
    }

    func reloadStorage() {
        gameport = GamePort()
        communityVerdicts = gameport.telemetry.loadCachedVerdicts()
        refresh()
        refreshCommunityVerdicts()
    }

    func refresh() {
        storageInfo = StorageInfo.inspect(gameport.paths.root, isCustom: StoragePreference.load().customRoot != nil)
        checks = gameport.doctor()
        installedEngines = gameport.engines.installed()
        engineCatalog = gameport.engineCatalog()
        recipes = gameport.catalog.sorted
        profiles = gameport.profiles.all()
        profilesByRecipe = Dictionary(
            profiles.compactMap { p in p.recipeID.map { ($0, p) } },
            uniquingKeysWith: { first, _ in first }
        )
        labResultsByProfile = profiles.reduce(into: [:]) { $0[$1.id] = gameport.profiles.labResults($1.id) }
        gptkAccepted = gameport.licenses.isAccepted("apple-gptk")
        telemetryEnabled = gameport.telemetry.load().enabled
        steamBase = (try? gameport.steamBase()).flatMap { $0.isReady ? $0.stamp : nil }
        x87Installed = gameport.x87sidecar.isInstalled
        x87Version = gameport.x87sidecar.versionString()
        aarchxInstalled = gameport.aarchx.isInstalled
        aarchxVersion = gameport.aarchx.versionString()
        bridgeStatus = gameport.steamBridge.status()
        crossOverInstallation = CrossOverSupport.detect()
        crossOverGames = CrossOverSupport.discoverBottleGames()
        externalEnv = ExternalDiscovery.scan()
    }

    func refreshCommunityVerdicts() {
        let telemetry = gameport.telemetry
        Task.detached(priority: .utility) {
            let fresh = await telemetry.refreshCommunityVerdicts()
            await MainActor.run { self.communityVerdicts = fresh }
        }
    }

    func profile(for recipe: Recipe) -> Profile? { profilesByRecipe[recipe.id] }

    func labResults(for profile: Profile) -> [LabResult] { labResultsByProfile[profile.id] ?? [] }

    func snapshots(for profile: Profile) -> [GamePortKit.Snapshot] {
        gameport.profiles.listSnapshots(profile.id)
    }

    func evidence(for recipe: Recipe) -> Evidence {
        let p = profile(for: recipe)
        return Evidence.of(
            recipe,
            results: p.flatMap { labResultsByProfile[$0.id] } ?? [],
            antiCheat: AntiCheatDB.bundled.entry(for: recipe)
        )
    }

    func say(_ line: String) {
        statusLog.append(line)
        if statusLog.count > 200 { statusLog.removeFirst(statusLog.count - 200) }
    }

    func launchCrossOverGame(_ item: CrossOverBottleLaunchItem) {
        do {
            _ = try CrossOverSupport.launch(item: item, installation: crossOverInstallation)
            say("✓ Launched \(item.title) via CrossOver bottle \"\(item.bottleName)\"")
        } catch {
            say("✗ \(error)")
        }
    }

    func launchViaBridge(profile: Profile, recipe: Recipe, executable: URL) {
        job("Launching \(recipe.title) via Bridge") { kit, progress in
            _ = try kit.launchWithSteamBridge(profile.id, executable: executable, progress: progress)
            return "Launched \(executable.lastPathComponent) via GamePort Bridge"
        }
    }

    func launchInteractiveBridgeDownload(appID: Int, username: String, title: String) {
        do {
            try gameport.steamDepot.launchInteractiveTerminalDownload(appID: appID, username: username)
            say("✓ Opened Terminal for native steamcmd download of \(title) (\(appID))")
        } catch {
            say("✗ \(error)")
        }
    }

    func job(_ title: String, _ work: @escaping @Sendable (GamePort, @escaping ProgressHandler) async throws -> String?) {
        guard busy == nil else { return }
        busy = title
        say("▶ \(title)")
        let kit = self.gameport
        Task.detached {
            let progress: ProgressHandler = { msg in Task { @MainActor in self.say("  \(msg)") } }
            do {
                let done = try await work(kit, progress)
                await MainActor.run { self.say("✓ \(done ?? title)") }
            } catch {
                await MainActor.run { self.say("✗ \(error)") }
            }
            await MainActor.run {
                self.busy = nil
                self.refresh()
            }
        }
    }

    func updateProfile(_ profileID: String, mutate: (inout Profile) -> Void) {
        do {
            var p = try gameport.profiles.load(profileID)
            mutate(&p)
            try gameport.profiles.save(p)
            refresh()
        } catch {
            say("✗ \(error)")
        }
    }

    func launchGame(profile: Profile, recipe: Recipe) {
        launchMonitorTask?.cancel()
        launchState = .startingSteam(profileID: profile.id)
        SoundEffectService.shared.play(.launch)
        let kit = self.gameport
        let steamLogs = try? kit.steam(for: profile.id).logs
        let cefLog = steamLogs?.appendingPathComponent("cef_log.txt")
        let bootstrapLog = steamLogs?.appendingPathComponent("bootstrap_log.txt")
        func fileSize(_ url: URL?) -> UInt64 {
            guard let url else { return 0 }
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        }
        let cefStart = fileSize(cefLog)
        let bootstrapStart = fileSize(bootstrapLog)

        job("Launching \(recipe.title)") { kit, progress in
            _ = try kit.play(profile.id, progress: progress)
            await MainActor.run {
                self.startLaunchWatcher(profile: profile, recipe: recipe, cefStart: cefStart, bootstrapStart: bootstrapStart)
            }
            return "Launch requested for \(recipe.title)"
        }
    }

    private func startLaunchWatcher(profile: Profile, recipe: Recipe, cefStart: UInt64, bootstrapStart: UInt64) {
        launchMonitorTask?.cancel()
        let kit = self.gameport
        launchMonitorTask = Task.detached(priority: .utility) {
            await kit.monitorLaunch(profile: profile, recipe: recipe, cefStart: cefStart, bootstrapStart: bootstrapStart) { state in
                Task { @MainActor in self.launchState = state }
            }
        }
    }

    func applyRecovery(_ action: RecoveryAction, to profile: Profile, recipe: Recipe, retry: Bool) {
        launchState = .idle
        job(action.title) { kit, progress in
            let msg = try kit.applyRecovery(action.kind, to: profile.id, progress: progress)
            if retry {
                let updated = try kit.profiles.load(profile.id)
                await MainActor.run { self.launchGame(profile: updated, recipe: recipe) }
            }
            return msg
        }
    }

    static func steamPosterURL(appID: Int) -> URL? {
        URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/library_600x900_2x.jpg")
    }

    static func steamHeroURL(appID: Int) -> URL? {
        URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/header.jpg")
    }
}
