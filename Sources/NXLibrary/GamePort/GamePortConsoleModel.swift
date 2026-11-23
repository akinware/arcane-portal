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
    /// The game the Windows games screen should show next time it opens (set by Spotlight's
    /// Options, cleared once the screen has selected it).
    @Published var focusRecipeID: String?
    /// The Windows game whose Options sheet is open on Spotlight (the pill, Y on a controller).
    @Published var hubOptionsGameID: UUID?
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
    @Published var bridgeStatus: SteamBridgeStatus = SteamBridgeStatus(
        macSteamInstalled: false,
        macSteamRunning: false,
        steamClientDylib: nil,
        steamClientHasX86_64: false,
        overlayDir: Paths.default().tools.appendingPathComponent("steam-bridge", isDirectory: true),
        overlayInstalled: false,
        probeExecutable: Paths.default().tools.appendingPathComponent("steam-bridge/bridge_probe.exe"),
        steamCmdInstalled: false
    )
    @Published var crossOverInstallation: CrossOverInstallation?
    @Published var crossOverGames: [CrossOverBottleLaunchItem] = []
    @Published var epicInstalled = false
    @Published var epicSignedIn = false
    @Published var epicAccount: String?
    @Published var gogInstalled = false
    @Published var gogSignedIn = false
    @Published var storefrontGames: [StorefrontGame] = []
    @Published var epicLibrary: [StorefrontGame] = []
    @Published var matchedOwnedSteamRecipes: [Recipe] = []
    @Published var unifiedGames: [UnifiedHubGame] = []
    @Published var unifiedGamesByID: [UUID: UnifiedHubGame] = [:]
    @Published var externalEnv: ExternalEnvironment = .empty
    @Published var communityVerdicts: [Int: [CommunityVerdict]] = [:]
    @Published var launchState: LaunchState = .idle
    @Published var busy: String?
    @Published var statusLog: [String] = []
    @Published var steamDownload: SteamDownloadSession?
    @Published var steamDownloadPresented = false

    private var profilesByRecipe: [String: Profile] = [:]
    private var labResultsByProfile: [String: [LabResult]] = [:]
    private var playSessionCache: [String: (modified: Date, sessions: [PlayRecord])] = [:]
    private var launchMonitorTask: Task<Void, Never>?
    private var steamDownloadTask: Task<Void, Never>?
    /// Watchdog that stops the launched game's Wine session if Arcane is force quit.
    private var launchGuard: Process?
    private var lastBridgeLaunch: (title: String, executable: URL, allowVACOverride: Bool, resolve: @Sendable (GamePort, @escaping ProgressHandler) throws -> String)?

    init() {
        communityVerdicts = gameport.telemetry.loadCachedVerdicts()
        // DepotDownloader is a separate process: quitting Arcane must not leave it downloading
        // on its own (a later download of the same game would then fight it for the files).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let model = GamePortConsoleModel.shared
                // Windows Steam / the game started from Arcane end with Arcane.
                if let profileID = model.launchState.profileID {
                    model.launchMonitorTask?.cancel()
                    try? model.gameport.stop(profileID)
                }
                model.launchGuard?.terminate()
                guard let s = model.steamDownload, s.isActive else { return }
                model.steamDownloadTask?.cancel()
                let dir = model.gameport.steamDepot.depotDirectory(appID: s.appID)
                model.gameport.steamQRDownloader.tool.stopRunning(directory: dir, timeout: 2)
            }
        }
        // Defer full disk/engine/Steam discovery off the static `shared` dispatch_once initializer
        // so SwiftUI never re-enters `shared` during startup layout.
        Task { @MainActor in
            self.refresh()
            self.refreshCommunityVerdicts()
        }
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
        epicInstalled = gameport.epic.isInstalled
        epicSignedIn = gameport.epic.isSignedIn
        gogInstalled = gameport.gog.isInstalled
        gogSignedIn = gameport.gog.isSignedIn
        storefrontGames = gameport.discoverStorefrontGames(includeUninstalledEpic: false)
        externalEnv = ExternalDiscovery.scan()
        let recipeByAppID = Dictionary(recipes.compactMap { r in r.steamAppID.map { ($0, r) } }, uniquingKeysWith: { first, _ in first })
        matchedOwnedSteamRecipes = externalEnv.macSteamOwnedGames.compactMap { recipeByAppID[$0.appID] }
        rebuildUnifiedGames()
        if epicInstalled && epicSignedIn {
            refreshEpicLibrary()
        } else {
            epicAccount = nil
            epicLibrary = []
        }
    }

    func rebuildUnifiedGames() {
        let list = UnifiedHubGame.buildAll(
            profiles: profiles,
            recipes: recipes,
            externalEnv: externalEnv,
            crossOverInstallation: crossOverInstallation,
            crossOverGames: crossOverGames,
            storefrontGames: storefrontGames,
            epicLibrary: epicLibrary,
            steamDepot: gameport.steamDepot
        )
        unifiedGames = list
        unifiedGamesByID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Prefers user's installed CrossOver.app (0 MB) when available unless another default is explicitly pinned.
    func preferredWindowsEngineID() -> String? {
        if let cx = crossOverInstallation, cx.hasExecutableWine {
            return CrossOverInstallation.engineID
        }
        return gameport.engines.defaultEngineID() ?? installedEngines.first?.id
    }

    /// A on a Windows game's tile: the same as its Play pill (`playRoute`).
    func activateUnifiedGame(_ game: UnifiedHubGame) {
        perform(playRoute(for: game), for: game)
    }

    func refreshEpicLibrary() {
        let epic = gameport.epic
        Task.detached(priority: .utility) {
            let acct = epic.accountDisplayName()
            let games = (try? epic.listGames(includeUninstalled: true)) ?? []
            await MainActor.run {
                self.epicAccount = acct
                self.epicLibrary = games
                self.rebuildUnifiedGames()
            }
        }
    }

    func refreshCommunityVerdicts() {
        let telemetry = gameport.telemetry
        Task.detached(priority: .utility) {
            // Reports that could not be sent before (offline) go out first.
            await telemetry.flushOutbox()
            let fresh = await telemetry.refreshCommunityVerdicts()
            await MainActor.run { self.communityVerdicts = fresh }
        }
    }

    func profile(for recipe: Recipe) -> Profile? { profilesByRecipe[recipe.id] }

    /// The profile's recent sessions, newest first (kept on this Mac). Re-read only when the file changes,
    /// since Spotlight asks on every redraw.
    func playSessions(_ profileID: String) -> [PlayRecord] {
        let file = gameport.playHistory.file(profileID)
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
        if let cached = playSessionCache[profileID], cached.modified == modified { return cached.sessions }
        let sessions = gameport.playHistory.sessions(profileID)
        playSessionCache[profileID] = (modified, sessions)
        return sessions
    }

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

    func launchStorefrontGame(_ game: StorefrontGame) {
        job("Launching \(game.title) (\(game.store.displayName))") { kit, progress in
            _ = try kit.launchStorefrontGame(game, progress: progress)
            return "Launched \(game.title)"
        }
    }

    func signInEpic(code: String) {
        job("Signing in to Epic Games") { kit, _ in
            try kit.epic.authenticate(authorizationCode: code)
            return "Signed in to Epic Games"
        }
    }

    func signInGOG(code: String) {
        job("Signing in to GOG") { kit, _ in
            try kit.gog.authenticate(authorizationCode: code)
            return "Signed in to GOG"
        }
    }

    func downloadEpicGame(_ game: StorefrontGame) {
        job("Downloading \(game.title) (Epic)") { kit, progress in
            _ = try await kit.epic.download(appName: game.appID, progress: progress)
            return "Downloaded \(game.title)"
        }
    }

    func downloadGOGGame(gameID: String) {
        job("Downloading GOG \(gameID)") { kit, progress in
            _ = try await kit.gog.download(gameID: gameID, progress: progress)
            return "Downloaded GOG game \(gameID)"
        }
    }

    func launchViaBridge(profile: Profile, recipe: Recipe, executable: URL, allowVACOverride: Bool = false) {
        launchViaBridge(title: recipe.title, executable: executable, allowVACOverride: allowVACOverride) { _, _ in profile.id }
    }

    /// Plays a game through the GamePort Steam Bridge (no Windows Steam): makes sure native Mac Steam
    /// is running and signed in (the game's Steam API needs it), starts the game, and follows it so a
    /// game that quits right away is explained instead of silently disappearing.
    /// `resolveProfile` returns the profile to use (it may create one).
    func launchViaBridge(
        title: String,
        executable: URL,
        allowVACOverride: Bool = false,
        resolveProfile: @escaping @Sendable (GamePort, @escaping ProgressHandler) throws -> String
    ) {
        if launchState.isLaunching { return }
        if case .running = launchState { return }
        guard busy == nil else { return }
        lastBridgeLaunch = (title, executable, allowVACOverride, resolveProfile)
        launchMonitorTask?.cancel()
        SoundEffectService.shared.play(.launch)
        job("Launching \(title) via Bridge") { kit, progress in
            let profileID = try resolveProfile(kit, progress)
            let started = Date()
            @Sendable func show(_ step: String) {
                let text = step.trimmingCharacters(in: CharacterSet(charactersIn: "… ."))
                Task { @MainActor in
                    if case .needsAttention = self.launchState { return }
                    self.launchState = .preparing(profileID: profileID, progress: LaunchProgress(
                        title: title, stage: .startingSteam, seconds: Int(Date().timeIntervalSince(started)),
                        secondsWithoutProgress: 0, bridgeStep: text))
                }
            }
            show("Getting Mac Steam ready")
            let gameLog = kit.profiles.logs(profileID).appendingPathComponent("bridge-game.log")
            let gameLogStart = (try? FileManager.default.attributesOfItem(atPath: gameLog.path)[.size] as? UInt64) ?? 0
            let process: Process
            do {
                process = try kit.launchWithSteamBridge(profileID, executable: executable, allowVACOverride: allowVACOverride) { msg in
                    progress(msg)
                    if !msg.hasPrefix("Automatic snapshot"), !msg.hasPrefix("Launching ") { show(msg) }
                }
            } catch {
                await MainActor.run {
                    self.launchState = .needsAttention(profileID: profileID, diagnosis: LaunchDiagnosis.bridgeLaunchFailed(error))
                }
                throw error
            }
            let guardProcess = try? kit.startOwnerExitGuard(profileID)
            await MainActor.run {
                self.launchGuard?.terminate()
                self.launchGuard = guardProcess
                self.startBridgeWatcher(profileID: profileID, title: title, process: process, gameLogStart: gameLogStart)
            }
            return "Started \(title) via the Steam Bridge (native Mac Steam)"
        }
    }

    /// Repeats the last Bridge launch (after fixing what stopped it, e.g. signing in to Mac Steam).
    func retryBridgeLaunch() {
        guard let last = lastBridgeLaunch else { launchState = .idle; return }
        launchState = .idle
        launchViaBridge(title: last.title, executable: last.executable, allowVACOverride: last.allowVACOverride, resolveProfile: last.resolve)
    }

    private func startBridgeWatcher(profileID: String, title: String, process: Process, gameLogStart: UInt64) {
        launchMonitorTask?.cancel()
        let kit = self.gameport
        launchMonitorTask = Task.detached(priority: .utility) {
            await kit.monitorBridgeLaunch(profileID: profileID, title: title, process: process, gameLogStart: gameLogStart) { state in
                Task { @MainActor in
                    self.launchState = state
                    if case .idle = state { self.endLaunchGuard() }
                    if case .needsAttention = state { self.endLaunchGuard() }
                }
            }
        }
    }

    // MARK: - Native in-app Steam download (Steam Mobile QR sign-in, no Windows Steam, no Terminal)

    /// Starts (or re-shows) the native in-app Windows game download for a Steam AppID.
    /// The first download shows a Steam Mobile App QR code; later ones reuse the remembered session.
    /// Downloads a game without Windows Steam, or with `update`, brings an already downloaded one
    /// up to date (only changed files are fetched; the game stays playable when nothing changed).
    func startSteamDownload(appID: Int, title: String, origin: SteamDownloadSession.Origin, vacNote: Bool = false, update: Bool = false) {
        if let current = steamDownload, current.isActive {
            if current.appID == appID {
                steamDownloadPresented = true
                return
            }
            say("✗ Already downloading \(current.title). Cancel it first to start \(title).")
            steamDownloadPresented = true
            return
        }
        let downloader = gameport.steamQRDownloader
        let account = ExternalDiscovery.macSteamAccountName()
        let silent = downloader.canSignInSilently(preferredAccount: account)
        let session = SteamDownloadSession(
            appID: appID,
            title: title,
            origin: origin,
            vacNote: vacNote,
            phase: .preparing(silent ? "Signing in to Steam…" : "Requesting a sign-in QR code…")
        )
        var started = session
        started.isUpdate = update
        steamDownload = started
        steamDownloadPresented = true
        say(update ? "▶ Checking \(title) for updates (Steam \(appID))" : "▶ Downloading \(title) (Steam \(appID))")
        let sessionID = session.id

        steamDownloadTask?.cancel()
        steamDownloadTask = Task { [weak self] in
            let stream = downloader.download(appID: appID, title: title, preferredAccount: account)
            do {
                for try await event in stream {
                    guard let self, self.steamDownload?.id == sessionID else { return }
                    self.steamDownload?.apply(event)
                    if case .completed(_, let exe) = event {
                        switch self.steamDownload?.updateChanged {
                        case false?: self.say("✓ \(title) is up to date")
                        case true?: self.say("✓ Updated \(title)")
                        case nil: self.say("✓ Downloaded \(title)\(exe.map { " (\($0.lastPathComponent))" } ?? "")")
                        }
                        self.refresh()
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        if self.steamDownload?.id == sessionID { self.dismissSteamDownload() }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.steamDownload?.id == sessionID else { return }
                self.steamDownload?.phase = .failed("\(error)")
                self.say("✗ \(title): \(error)")
                self.refresh()
            }
        }
    }

    /// Stops the running download (DepotDownloader is terminated) and closes the sheet.
    func cancelSteamDownload() {
        if let s = steamDownload, s.isActive { say("✗ Cancelled download of \(s.title)") }
        steamDownloadTask?.cancel()
        steamDownloadTask = nil
        steamDownload = nil
        steamDownloadPresented = false
        refresh()
    }

    /// Closes a finished / failed session. Active downloads keep running when only hidden.
    func dismissSteamDownload() {
        if steamDownload?.isActive == true {
            steamDownloadPresented = false
            return
        }
        steamDownloadTask = nil
        steamDownload = nil
        steamDownloadPresented = false
    }

    func retrySteamDownload() {
        guard let s = steamDownload else { return }
        steamDownload = nil
        startSteamDownload(appID: s.appID, title: s.title, origin: s.origin, vacNote: s.vacNote, update: s.isUpdate)
    }

    /// Forgets every remembered Steam QR sign-in (DepotDownloader's private token store).
    func signOutSteamDownloads() {
        gameport.steamQRDownloader.tool.signOutAll()
        say("✓ Signed out of in-app Steam downloads")
        refresh()
    }

    /// A sheet binding that only presents for one origin, so Spotlight and the Console never both show it.
    func steamDownloadSheetBinding(for origin: SteamDownloadSession.Origin) -> Binding<SteamDownloadSession?> {
        Binding(
            get: { [weak self] in
                guard let self, self.steamDownloadPresented, let s = self.steamDownload, s.origin == origin else { return nil }
                return s
            },
            set: { [weak self] value in
                if value == nil { self?.dismissSteamDownload() }
            }
        )
    }

    /// Runs `work` in the background with progress in the status line. `then` runs on the main actor after a
    /// successful job, once the lists are refreshed.
    func job(_ title: String, then: (@MainActor () -> Void)? = nil,
             _ work: @escaping @Sendable (GamePort, @escaping ProgressHandler) async throws -> String?) {
        guard busy == nil else { return }
        busy = title
        say("▶ \(title)")
        let kit = self.gameport
        Task.detached {
            let progress: ProgressHandler = { msg in Task { @MainActor in self.say("  \(msg)") } }
            let succeeded: Bool
            do {
                let done = try await work(kit, progress)
                await MainActor.run { self.say("✓ \(done ?? title)") }
                succeeded = true
            } catch {
                await MainActor.run { self.say("✗ \(error)") }
                succeeded = false
            }
            await MainActor.run { [succeeded] in
                self.busy = nil
                self.refresh()
                if succeeded { then?() }
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
        // A second press while Windows Steam is starting (or closing) would only queue another launch.
        if launchState.profileID == profile.id {
            switch launchState {
            case .startingSteam, .waitingForGame, .preparing, .running, .closing: return
            default: break
            }
        }
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
        let marks = kit.steamLaunchLogMarks(profile.id)

        job("Launching \(recipe.title)") { kit, progress in
            do {
                _ = try kit.play(profile.id, progress: progress)
            } catch {
                await MainActor.run { self.launchState = .idle }
                throw error
            }
            let guardProcess = try? kit.startOwnerExitGuard(profile.id)
            await MainActor.run {
                self.launchGuard?.terminate()
                self.launchGuard = guardProcess
                self.startLaunchWatcher(profile: profile, recipe: recipe, cefStart: cefStart, bootstrapStart: bootstrapStart, marks: marks)
            }
            return "Starting \(recipe.title) through Windows Steam"
        }
    }

    private func startLaunchWatcher(profile: Profile, recipe: Recipe, cefStart: UInt64, bootstrapStart: UInt64, marks: SteamLaunchLogMarks? = nil) {
        launchMonitorTask?.cancel()
        let kit = self.gameport
        launchMonitorTask = Task.detached(priority: .utility) {
            await kit.monitorLaunch(profile: profile, recipe: recipe, cefStart: cefStart, bootstrapStart: bootstrapStart,
                                    marks: marks, closeSteamWhenGameExits: true) { state in
                Task { @MainActor in
                    self.launchState = state
                    if case .idle = state { self.endLaunchGuard() }
                    if case .needsAttention = state { self.endLaunchGuard() }
                }
            }
        }
    }

    private func endLaunchGuard() {
        launchGuard?.terminate()
        launchGuard = nil
    }

    /// Stops every Windows program (all profiles, CrossOver bottles, and leftovers from earlier sessions).
    func stopAllWindowsApps() {
        launchMonitorTask?.cancel()
        launchMonitorTask = nil
        launchState = .idle
        endLaunchGuard()
        let kit = gameport
        Task.detached {
            let n = kit.stopAllWindowsProcesses()
            await MainActor.run {
                self.say(n == 0 ? "✓ No Windows apps were running" : "✓ Stopped \(n) Windows process\(n == 1 ? "" : "es")")
            }
        }
    }

    /// Stops a launch in progress or the running game (Windows Steam and the game in that profile).
    func stopLaunch(profileID: String) {
        launchMonitorTask?.cancel()
        launchMonitorTask = nil
        launchState = .idle
        endLaunchGuard()
        let kit = gameport
        Task.detached {
            do {
                try kit.stop(profileID)
                await MainActor.run { self.say("✓ Stopped") }
            } catch {
                await MainActor.run { self.say("✗ \(error)") }
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
