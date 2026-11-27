import AppKit
import GamePortKit
import NXLibraryCore
import SwiftUI

/// Options for a Windows/PC game on Spotlight: how Play will run it, the other ways to play it, what
/// GamePort and the game's recipe set up (in plain words, with who chose each value), and the settings
/// a player may want to change.
struct HubGameOptionsSheet: View {
    @ObservedObject var gp = GamePortConsoleModel.shared
    let game: UnifiedHubGame
    let onOpenCatalog: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var profile: Profile? {
        if case .profile(let profile, _) = game.kind { return profile }
        return nil
    }

    private var recipe: Recipe? {
        switch game.kind {
        case .profile(_, let recipe), .ownedSteam(_, let recipe): return recipe
        case .crossOverBottle, .storefront: return nil
        }
    }

    /// What the game uses now, or what it will use once set up.
    private var setup: GameSetup? {
        if let profile { return try? gp.gameport.setup(for: profile.id) }
        guard let recipe, let engineID = gp.preferredWindowsEngineID(),
              let engine = try? gp.gameport.engines.engine(engineID) else { return nil }
        let preview = Profile(id: "preview", title: game.title, recipeID: recipe.id, engineID: engineID)
        return GameSetup.describe(WineRunner(paths: gp.gameport.paths, engine: engine, profile: preview, recipe: recipe))
    }

    var body: some View {
        let route = gp.playRoute(for: game)
        let others = gp.otherRoutes(for: game)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.title).font(.title2.bold())
                    Text(game.storeBadge).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    let clean = Self.runsOutsideGamePort(route)
                    playSection(route, others: others)
                    if !clean { historySection }
                    usesSection(route, clean: clean)
                    if let profile { settingsSection(profile) }
                    footer(clean: clean)
                }
                .padding(20)
            }
        }
        .frame(width: 640, height: 660)
        .disabled(gp.busy != nil)
    }

    // MARK: - Play

    private func playSection(_ route: HubPlayRoute, others: [HubPlayRoute]) -> some View {
        section("Play") {
            row(icon: "play.circle.fill", title: route.title == "Play" ? "Play runs it like this" : "Play does this",
                detail: route.how(engine: engineName, vac: vac))
            if !others.isEmpty {
                Text("Other ways to play").font(.subheadline.weight(.semibold)).padding(.top, 6)
                ForEach(Array(others.enumerated()), id: \.offset) { _, other in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(other.otherWayTitle)
                            Text(other.how(engine: engineName, vac: vac)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(other.isPlayable ? "Play" : "Go") {
                            dismiss()
                            if other == .storesSetup { onOpenCatalog() } else { gp.perform(other, for: game) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - How it ran

    private var sessions: [PlayRecord] { profile.map { gp.playSessions($0.id) } ?? [] }

    private var playsWindowsSteam: Bool {
        if case .windowsSteam = gp.playRoute(for: game) { return true }
        return false
    }

    private var fixes: [AutoFix] { profile.map { gp.gameport.autoFixes.fixes($0.id) } ?? [] }

    private var communityAdvice: CommunityAdvice? {
        game.steamAppID.flatMap { gp.gameport.communityAdvice(steamAppID: $0) }
    }

    private var verdicts: [CommunityVerdict] {
        game.steamAppID.flatMap { gp.communityVerdicts[$0] } ?? []
    }

    /// This Mac's last sessions and what other players reported, so a game that failed once is not a mystery.
    @ViewBuilder
    private var historySection: some View {
        let sessions = sessions
        let verdicts = verdicts
        section("How it ran") {
            if sessions.prefersWindowsSteamOverBridge {
                row(icon: "arrow.triangle.branch", title: playsWindowsSteam ? "Play uses Windows Steam for now" : "Windows Steam worked better",
                    detail: "The Steam Bridge did not work the last time it was tried, and Windows Steam did. "
                        + (playsWindowsSteam ? "The Bridge is still under Other ways to play."
                                             : "To play that way, pick Windows Steam under Other ways to play."))
            }
            if sessions.isEmpty {
                Text("Not played with GamePort on this Mac yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("On this Mac").font(.subheadline.weight(.semibold))
                ForEach(Array(sessions.prefix(4).enumerated()), id: \.offset) { _, session in
                    row(icon: icon(session.outcome), title: session.summary(), detail: setupText(session))
                }
            }
            ForEach(Array(fixes.prefix(3).enumerated()), id: \.offset) { _, fix in
                row(icon: fix.state == .undone ? "arrow.uturn.backward.circle" : "wand.and.stars",
                    title: fix.state == .trying ? "Trying an automatic fix" : "Automatic fix",
                    detail: fix.summary)
            }
            if let advice = communityAdvice, advice.prefersWindowsSteam {
                row(icon: "person.2.fill", title: "Other players: Windows Steam works better",
                    detail: "The Steam Bridge fails for most players with this game, while Windows Steam works"
                        + (playsWindowsSteam ? ", so Play uses Windows Steam." : ". To play that way, pick Windows Steam under Other ways to play."))
            }
            if !verdicts.isEmpty {
                Text("Other players").font(.subheadline.weight(.semibold)).padding(.top, 6)
                ForEach(verdicts.prefix(3)) { verdict in
                    Label(verdict.summary, systemImage: verdict.works > 0 ? "person.2.fill" : "person.2")
                        .font(.callout)
                }
            }
            Text(gp.telemetryEnabled
                 ? "Each session is also shared anonymously (the game, its setup, the Mac model and FPS; never your name, account or files), so every player gets better defaults. You can turn this off in Setup."
                 : "Sharing is off: sessions stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func icon(_ outcome: PlayRecord.Outcome) -> String {
        switch outcome {
        case .worked: return "checkmark.circle.fill"
        case .crashed: return "xmark.octagon.fill"
        case .didNotStart: return "exclamationmark.triangle.fill"
        case .closedEarly: return "stop.circle"
        }
    }

    private func setupText(_ session: PlayRecord) -> String {
        let engine = gp.installedEngines.first { $0.id == session.engineID }.map { GameSetup.shortName($0.manifest.displayName) }
            ?? session.engineID
        var parts = [GameSetup.rendererName(session.renderer), engine]
        if session.vulkanDriver != .moltenvk { parts.append(session.vulkanDriver.displayName) }
        if !session.problems.isEmpty { parts.append(session.problems.map(problemText).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func problemText(_ code: String) -> String {
        switch code {
        case "wine_exception": return "Windows error in the game"
        case "vulkan_error", "vulkan_query_unsupported": return "graphics error"
        case "game_exited": return "the game quit on its own"
        case "steam_not_started", "steam_gpu_crash": return "Steam did not start"
        default: return "error in the log"
        }
    }

    // MARK: - What this game uses

    /// Mac Steam (NotProton), CrossOver or the Mac version runs the game with its own settings: GamePort's
    /// sessions, recipe and Wine settings do not apply, so Options shows only what does.
    static func runsOutsideGamePort(_ route: HubPlayRoute) -> Bool {
        switch route {
        case .macSteam, .macSteamWindows, .crossOverBottle: return true
        default: return false
        }
    }

    private func usesSection(_ route: HubPlayRoute, clean: Bool) -> some View {
        section("What this game uses") {
            if gp.hasOwnRunner(game) {
                // On when Play runs it GamePort's way now, whether the player chose that or Play did.
                let onGamePort = !clean
                Toggle(isOn: Binding(get: { onGamePort }, set: { gp.setRunner($0 ? .gamePort : .own, game) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use GamePort's settings").fontWeight(.medium)
                        Text(onGamePort
                             ? "Play runs it with GamePort's Wine and the settings below, not \(ownRunnerName)."
                             : "Off: \(ownRunnerName) runs it with its own settings. Turn on to run it with GamePort's Wine settings instead.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            if let steam = route.steamRoute {
                setupRow(SetupLine("Steam", steam, why: steamWhy(route), origin: .gameport))
            }
            if !clean, let setup {
                if profile == nil {
                    Text("Not set up yet. These are the settings it will start with.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(setup.basics) { setupRow($0) }
                if !setup.tweaks.isEmpty {
                    Text("Changed for this game").font(.subheadline.weight(.semibold)).padding(.top, 6)
                    ForEach(setup.tweaks) { setupRow($0) }
                } else {
                    Text("Nothing else is changed for this game.").font(.caption).foregroundStyle(.secondary)
                }
                if let source = setup.source {
                    row(icon: statusIcon(setup.status), title: "Where these settings come from", detail: source)
                }
                if !setup.notes.isEmpty {
                    Text("Notes").font(.subheadline.weight(.semibold)).padding(.top, 6)
                    ForEach(setup.notes, id: \.self) { note in
                        Label(note, systemImage: "text.bubble").font(.callout)
                    }
                }
                if !setup.knownIssues.isEmpty {
                    Text("Known problems").font(.subheadline.weight(.semibold)).padding(.top, 6)
                    ForEach(Array(setup.knownIssues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(issue.symptom, systemImage: "exclamationmark.triangle").font(.callout)
                            if let fix = issue.fix { Text("Fix: \(fix)").font(.caption).foregroundStyle(.secondary) }
                            else if let cause = issue.cause { Text("Why: \(cause)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            } else if case .macSteam = route {
                Text("The Mac version runs natively. GamePort does not change anything.").font(.callout)
            } else if case .macSteamWindows(_, let tool) = route {
                Text("Mac Steam installed the Windows version and starts it with \(tool ?? "the Steam Play tool you set up") (for example NotProton). GamePort does not change anything; if the game does not start, Play switches to the Steam Bridge on the same files.")
                    .font(.callout)
            } else if case .crossOverBottle(let item) = route {
                Text("CrossOver runs this game from your bottle \u{201C}\(item.bottleName)\u{201D} with the settings you chose in CrossOver.")
                    .font(.callout)
            } else {
                Text("GamePort has no recipe for this game yet. It starts with safe defaults: \(GameSetup.rendererName(.dxmt)) graphics and MSync.")
                    .font(.callout)
            }
        }
    }

    private func steamWhy(_ route: HubPlayRoute) -> String {
        switch route {
        case .bridge: return "The game talks to your Mac Steam app through GamePort's Steam Bridge: no Windows Steam, achievements and Workshop work, and it starts fast."
        case .windowsSteam, .openWindowsSteam, .installWindowsSteam: return "A Windows Steam runs inside this game's own Windows copy, as on a PC. Needed for VAC multiplayer."
        case .macSteamWindows(_, let tool): return "Mac Steam starts the Windows version itself, with \(tool ?? "the Steam Play tool you set up")."
        default: return "Steam for Mac starts the Mac version."
        }
    }

    private func setupRow(_ line: SetupLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(line.label).foregroundStyle(.secondary)
                    Text(line.value).fontWeight(.semibold).textSelection(.enabled)
                }
                Text(line.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(originLabel(line.origin))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(originColor(line.origin).opacity(0.22), in: Capsule())
                .help(originHelp(line.origin))
        }
    }

    private func originLabel(_ origin: SetupLine.Origin) -> String {
        switch origin {
        case .gameport: return "GamePort"
        case .recipe: return "Recipe"
        case .player: return "You"
        case .community: return "Players"
        case .autoFix: return "Auto-fix"
        }
    }

    private func originColor(_ origin: SetupLine.Origin) -> Color {
        switch origin {
        case .gameport: return .gray
        case .recipe: return .blue
        case .player: return .green
        case .community: return .purple
        case .autoFix: return .orange
        }
    }

    private func originHelp(_ origin: SetupLine.Origin) -> String {
        switch origin {
        case .gameport: return "GamePort's default for every game."
        case .recipe: return "Set by this game's recipe."
        case .player: return "You changed this below."
        case .community: return "Other players' reports: enough Macs run the game well with this. Your own choice below always wins."
        case .autoFix: return "GamePort changed this by itself after a crash. It stays because the game worked afterwards; change it below any time."
        }
    }

    private func statusIcon(_ status: Recipe.Status?) -> String {
        switch status {
        case .verified: return "checkmark.seal.fill"
        case .community: return "person.2.fill"
        case .blocked: return "xmark.octagon.fill"
        case .untested, nil: return "questionmark.circle"
        }
    }

    // MARK: - Settings

    private func settingsSection(_ profile: Profile) -> some View {
        section("Change") {
            if gp.installedEngines.count > 1 {
                Picker("Engine", selection: Binding<String>(
                    get: { profile.engineID },
                    set: { id in
                        gp.job("Switching \(game.title) to another engine") { k, p in
                            let moved = try k.switchEngine(profile.id, to: id, progress: p)
                            return "\(game.title) now uses \(moved.engineID)"
                        }
                    }
                )) {
                    ForEach(gp.installedEngines, id: \.id) { Text(GameSetup.shortName($0.manifest.displayName)).tag($0.id) }
                }
                .help("Which Wine runs this game. A snapshot is taken first, so you can go back.")
            }
            Picker("Graphics", selection: Binding<Renderer>(
                get: { profile.renderer ?? recipe?.renderer ?? .dxmt },
                set: { r in gp.updateProfile(profile.id) { $0.renderer = r == recipe?.renderer ? nil : r } }
            )) {
                ForEach(Renderer.allCases, id: \.self) { Text(GameSetup.rendererName($0)).tag($0) }
            }
            HStack(spacing: 18) {
                Toggle("MetalFX upscaling", isOn: Binding(
                    get: { profile.metalFX ?? false },
                    set: { on in gp.updateProfile(profile.id) { $0.metalFX = on ? true : nil } }))
                Toggle("Performance cores", isOn: Binding(
                    get: { profile.performanceCores ?? true },
                    set: { on in gp.updateProfile(profile.id) { $0.performanceCores = on ? nil : false } }))
                Toggle("x87 acceleration", isOn: Binding(
                    get: { profile.x87Acceleration ?? false },
                    set: { on in gp.updateProfile(profile.id) { $0.x87Acceleration = on ? true : nil } }))
                Toggle("Metal HUD", isOn: Binding(
                    get: { profile.metalHUD },
                    set: { on in gp.updateProfile(profile.id) { $0.metalHUD = on } }))
                    .help("Shows Apple's frame rate and GPU overlay in the game.")
            }
            HStack {
                Button("Take Snapshot") {
                    gp.job("Snapshot \(game.title)") { k, _ in try k.profiles.createSnapshot(profile.id, name: nil).name }
                }
                .help("Saves this game's Windows copy so you can roll back after a change.")
                if recipe?.steamAppID != nil {
                    Button("Measure FPS (Lab)") {
                        dismiss()
                        gp.job("Lab Benchmark") { k, p in
                            let res = try await k.lab(profile.id, seconds: 45, progress: p)
                            return "Lab finished: \(res.verdict.rawValue)"
                        }
                    }
                }
                if let appID = game.steamAppID, gp.gameport.steamDepot.downloadedExecutable(appID: appID, preferredName: game.title) != nil {
                    Button("Update Game") {
                        dismiss()
                        gp.startSteamDownload(appID: appID, title: game.title, origin: .spotlight,
                                              vacNote: gp.isVACBlockedForBridge(game), update: true)
                    }
                    .help("Brings GamePort's copy up to date. Only changed files are downloaded.")
                }
                Button("Stop") { gp.job("Stopping") { k, _ in try k.stop(profile.id); return "Stopped" } }
            }
        }
    }

    private func footer(clean: Bool) -> some View {
        HStack {
            if !clean {
                Button("Stop All Windows Apps") {
                    dismiss()
                    gp.stopAllWindowsApps()
                }
                .help("Quits Windows Steam, games and any Wine processes left running, in every profile.")
            }
            if let place = gp.installPlace(for: game) {
                Button("Show in Finder") {
                    dismiss()
                    NSWorkspace.shared.activateFileViewerSelecting([place.folder])
                }
                .help("Shows the game's folder in Finder.")
            }
            Button("Hide from Library") {
                dismiss()
                gp.setHidden(true, game)
            }
            .help("Takes the game out of Spotlight, Collection and search. Bring it back in Settings → Library → Games.")
            Button("Change Artwork…") {
                dismiss()
                // The picker is a full-screen panel of the app shell (`AppShellView+Layers`), opened once this sheet is gone.
                DispatchQueue.main.async { NotificationCenter.default.post(name: .nxHubChangeArtwork, object: game) }
            }
            .help("Choose the cover, background and logo: Steam's own art, SteamGridDB, LaunchBox or a file.")
            Spacer()
            if !clean {
                Button(focusRecipeID == nil ? "Stores & Setup…" : "Advanced Settings…") {
                    dismiss()
                    gp.focusRecipeID = focusRecipeID
                    onOpenCatalog()
                }
            }
        }
    }

    private var focusRecipeID: String? {
        switch game.kind {
        case .profile(let profile, let recipe): return recipe?.id ?? profile.recipeID
        case .ownedSteam(_, let recipe): return recipe?.id
        case .crossOverBottle, .storefront: return nil
        }
    }

    private var engineName: String { gp.engineName(for: game) }

    /// Who runs the game when GamePort's settings are off.
    private var ownRunnerName: String {
        if case .crossOverBottle = game.kind { return "CrossOver" }
        if let appID = game.steamAppID, gp.externalEnv.macSteamWindowsGame(appID: appID) != nil {
            return gp.externalEnv.notProtonInstalled ? "Mac Steam with NotProton" : "Mac Steam"
        }
        return "CrossOver"
    }

    private var vac: Bool { gp.isVACBlockedForBridge(game) }

    // MARK: - Layout

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension Notification.Name {
    /// Opens Change Artwork for the `UnifiedHubGame` in the notification's object.
    static let nxHubChangeArtwork = Notification.Name("NXHubChangeArtwork")
}
