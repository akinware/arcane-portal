import AppKit
import GamePortKit
import NXLibraryCore
import SwiftUI

/// Native Arcane Selene info view rendered directly below the main Spotlight carousel
/// whenever a unified Steam / CrossOver / PowerKit / Epic / GOG / Battle.net tile is focused.
struct UnifiedHubSpotlightInfo: View {
    @Environment(\.seleneCanvas) private var canvas
    @ObservedObject var gp = GamePortConsoleModel.shared

    let game: UnifiedHubGame
    let onOpenCatalog: () -> Void

    @State private var showOptionsSheet = false
    @State private var showBridgeDownloadSheet = false
    @State private var bridgeSteamUser = ""
    @State private var editingBridgeSteamUser = false

    private var downloadedDepotExe: URL? {
        guard let appID = game.steamAppID else { return nil }
        if let depot = gp.gameport.steamDepot.downloadedExecutable(appID: appID, preferredName: game.title) {
            return depot
        }
        // Also discover games already installed inside an existing GamePort profile's Steam folder
        if case .profile(let profile, _) = game.kind {
            let steamapps = gp.gameport.paths.profile(profile.id)
                .appendingPathComponent("prefix/drive_c/Program Files (x86)/Steam/steamapps", isDirectory: true)
            let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
            if let text = try? String(contentsOf: manifest, encoding: .utf8),
               let range = text.range(of: #""installdir"\s+"([^"]+)""#, options: .regularExpression) {
                let line = String(text[range])
                if let lastQuote = line.lastIndex(of: "\""),
                   let prevQuote = line[..<lastQuote].lastIndex(of: "\"") {
                    let installDirName = String(line[line.index(after: prevQuote)..<lastQuote])
                    let gameDir = steamapps.appendingPathComponent("common/\(installDirName)", isDirectory: true)
                    if let found = SteamDepotManager.discoverMainExecutable(in: gameDir, preferredName: game.title) {
                        return found
                    }
                }
            }
        }
        return nil
    }

    private var isVACBlockedForBridge: Bool {
        if case .blocked = SteamBridge.vacDecision(for: game.antiCheat) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: canvas.u(14)) {
            // Game logo (from local Steam librarycache logo.png) or bold Selene headline
            if let logoURL = game.preferredLogoURL, logoURL.isFileURL, let nsImg = NSImage(contentsOf: logoURL) {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: canvas.u(480), maxHeight: canvas.u(120), alignment: .leading)
                    .shadow(color: .black.opacity(0.55), radius: canvas.u(10))
            } else {
                Text(game.title)
                    .seleneFont(40, .bold)
                    .foregroundColor(SeleneTheme.ink)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.55), radius: canvas.u(8))
            }

            // Clean metadata row (zero jargon!)
            HStack(spacing: canvas.u(14)) {
                pillBadge(game.storeBadge, tint: .white.opacity(0.16))
                pillBadge(game.runnerBadge, tint: game.supportsMacOS ? Color.green.opacity(0.28) : Color.cyan.opacity(0.25))
                if let pt = game.playtimeSummary {
                    Text(pt)
                        .seleneFont(16, .medium)
                        .foregroundColor(SeleneTheme.ink82)
                }
                if let ac = game.antiCheat {
                    pillBadge(
                        ac.risk == .blocked ? "Anti-Cheat Blocked" : ac.antiCheats.joined(separator: ", "),
                        tint: ac.risk == .blocked ? Color.red.opacity(0.35) : Color.orange.opacity(0.28)
                    )
                }
            }

            // Primary + Secondary Arcane Glass Action Pills
            HStack(spacing: canvas.u(14)) {
                primaryActionButton

                if case .ownedSteam(let owned, _) = game.kind, owned.supportsMacOS,
                   let url = URL(string: "steam://install/\(owned.appID)") {
                    glassPill("Install Mac Native", icon: "desktopcomputer", prominent: false) {
                        NSWorkspace.shared.open(url)
                    }
                }

                if let appID = game.steamAppID, !isVACBlockedForBridge, gp.bridgeStatus.overlayInstalled {
                    if let exe = downloadedDepotExe {
                        glassPill("Play (No Win Steam)", icon: "bolt.horizontal.fill", prominent: false) {
                            launchBridgeForGame(appID: appID, exe: exe)
                        }
                    } else if !game.isReady {
                        glassPill("Download Depot", icon: "arrow.down.circle", prominent: false) {
                            openBridgeDownloadSheet()
                        }
                    }
                }

                glassPill("Options", icon: "slider.horizontal.3", prominent: false) {
                    showOptionsSheet = true
                }
            }
            .padding(.top, canvas.u(4))
            .disabled(gp.busy != nil)

            if let busy = gp.busy {
                HStack(spacing: canvas.u(10)) {
                    ProgressView().controlSize(.small)
                    Text(busy)
                        .seleneFont(15, .medium)
                        .foregroundColor(SeleneTheme.ink90)
                    if let last = gp.statusLog.last {
                        Text("· \(last)")
                            .seleneFont(14)
                            .foregroundColor(SeleneTheme.ink60)
                            .lineLimit(1)
                    }
                }
                .padding(.top, canvas.u(4))
            } else if let last = gp.statusLog.last, !last.isEmpty {
                let isErr = last.hasPrefix("✗")
                HStack(spacing: canvas.u(8)) {
                    Image(systemName: isErr ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: canvas.u(14)))
                        .foregroundColor(isErr ? .orange : .green)
                    Text(last)
                        .seleneFont(14, .medium)
                        .foregroundColor(isErr ? Color.orange.opacity(0.95) : SeleneTheme.ink82)
                        .lineLimit(2)
                }
                .padding(.top, canvas.u(4))
            }
        }
        .frame(width: canvas.u(960), alignment: .leading)
        .sheet(isPresented: $showOptionsSheet) { optionsSheet }
        .sheet(isPresented: $showBridgeDownloadSheet) { bridgeDownloadSheet }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch game.kind {
        case .profile(let profile, let recipe):
            if recipe?.launch == .battlenet {
                glassPill("Open Battle.net", icon: "play.fill", prominent: true) {
                    gp.job("Opening \(game.title)") { k, p in
                        _ = try k.openBattleNet(profile.id, progress: p)
                        return "Battle.net opened"
                    }
                }
            } else {
                let steamClient = try? gp.gameport.steam(for: profile.id)
                let hasWinSteam = steamClient?.isInstalled == true
                let isWinSteamGameInstalled = game.steamAppID.map { steamClient?.isGameInstalled(appID: $0) == true } ?? false

                if !isWinSteamGameInstalled, let exe = downloadedDepotExe, let appID = game.steamAppID, gp.bridgeStatus.isReadyToLaunch {
                    glassPill("Play (No Win Steam)", icon: "bolt.horizontal.fill", prominent: true) {
                        launchBridgeForGame(appID: appID, exe: exe)
                    }
                } else if !hasWinSteam && game.steamAppID != nil {
                    if isVACBlockedForBridge {
                        glassPill("Install Win Steam", icon: "square.and.arrow.down.fill", prominent: true) {
                            installWindowsSteam(profileID: profile.id)
                        }
                        glassPill("Download Offline (No Win Steam)", icon: "arrow.down.circle", prominent: false) {
                            openBridgeDownloadSheet()
                        }
                    } else {
                        glassPill("Download Game (No Win Steam)", icon: "arrow.down.circle.fill", prominent: true) {
                            openBridgeDownloadSheet()
                        }
                        glassPill("Install Win Steam", icon: "square.and.arrow.down", prominent: false) {
                            installWindowsSteam(profileID: profile.id)
                        }
                    }
                } else if hasWinSteam && !isWinSteamGameInstalled && game.steamAppID != nil {
                    if isVACBlockedForBridge {
                        glassPill("Open Steam to Install", icon: "arrow.down.circle.fill", prominent: true) {
                            gp.job("Opening Steam for \(game.title)") { k, p in
                                _ = try k.play(profile.id, progress: p)
                                return "Opened Steam window — sign in & install \(game.title)"
                            }
                        }
                        glassPill("Download Offline (No Win Steam)", icon: "bolt.horizontal", prominent: false) {
                            openBridgeDownloadSheet()
                        }
                    } else {
                        glassPill("Download Game (No Win Steam)", icon: "arrow.down.circle.fill", prominent: true) {
                            openBridgeDownloadSheet()
                        }
                        glassPill("Open Steam to Install", icon: "square.and.arrow.down", prominent: false) {
                            gp.job("Opening Steam for \(game.title)") { k, p in
                                _ = try k.play(profile.id, progress: p)
                                return "Opened Steam window — sign in & install \(game.title)"
                            }
                        }
                    }
                } else {
                    glassPill("Play", icon: "play.fill", prominent: true) {
                        if let recipe {
                            gp.launchGame(profile: profile, recipe: recipe)
                        } else {
                            gp.job("Starting \(game.title)") { k, p in
                                _ = try k.play(profile.id, progress: p)
                                return "Launched \(game.title)"
                            }
                        }
                    }
                }
            }

        case .crossOverBottle(let item):
            glassPill("Play", icon: "play.fill", prominent: true) {
                gp.launchCrossOverGame(item)
            }

        case .storefront(let sfGame):
            if sfGame.isInstalled {
                glassPill("Play", icon: "play.fill", prominent: true) {
                    gp.launchStorefrontGame(sfGame)
                }
            } else if sfGame.store == .epic {
                glassPill("Download", icon: "arrow.down.circle.fill", prominent: true) {
                    gp.downloadEpicGame(sfGame)
                }
            } else {
                glassPill("Stores & Setup", icon: "arrow.down.circle", prominent: true) {
                    onOpenCatalog()
                }
            }

        case .ownedSteam(let owned, let recipe):
            if gp.externalEnv.macSteamGame(appID: owned.appID) != nil,
               let url = URL(string: "steam://rungameid/\(owned.appID)") {
                glassPill("Play", icon: "play.fill", prominent: true) {
                    NSWorkspace.shared.open(url)
                }
            } else if let exe = downloadedDepotExe, gp.bridgeStatus.isReadyToLaunch, !isVACBlockedForBridge {
                glassPill("Play", icon: "play.fill", prominent: true) {
                    launchBridgeForGame(appID: owned.appID, exe: exe)
                }
            } else if owned.supportsMacOS, let url = URL(string: "steam://install/\(owned.appID)") {
                glassPill("Install & Play", icon: "arrow.down.circle.fill", prominent: true) {
                    NSWorkspace.shared.open(url)
                }
            } else {
                glassPill("Set Up (\(game.runnerBadge))", icon: "plus.circle.fill", prominent: true) {
                    setupOwnedSteamGame(owned: owned, recipe: recipe)
                }
            }
        }
    }

    private func openBridgeDownloadSheet() {
        let detected = ExternalDiscovery.macSteamAccountName()
        if let detected, !detected.isEmpty {
            bridgeSteamUser = detected
            editingBridgeSteamUser = false
            // 1-click native download for non-VAC games when Mac Steam account is already known —
            // no popup or editable username field to accidentally clear.
            if !isVACBlockedForBridge, let appID = game.steamAppID {
                gp.launchInteractiveBridgeDownload(appID: appID, username: detected, title: game.title)
                return
            }
        } else {
            editingBridgeSteamUser = true
        }
        showBridgeDownloadSheet = true
    }

    private func installWindowsSteam(profileID: String) {
        gp.job("Installing Windows Steam in \(game.title)") { k, p in
            let steam = try k.steam(for: profileID)
            try await steam.install(progress: p)
            _ = try k.openSteam(profileID, progress: p)
            return "Steam installed & opened"
        }
    }

    private func setupOwnedSteamGame(owned: OwnedSteamGame, recipe: Recipe?) {
        let preferredEngine = gp.preferredWindowsEngineID()
        let defaultRenderer: Renderer = (preferredEngine == CrossOverInstallation.engineID) ? .d3dmetal : .dxmt
        gp.job("Setting up \(game.title)") { k, p in
            let recipeID: String
            if let recipe {
                recipeID = recipe.id
            } else {
                let added = try k.addCustomSteamGame(appID: owned.appID, title: game.title, renderer: defaultRenderer)
                recipeID = added.id
            }
            let created = try k.createProfile(recipeID: recipeID, engineID: preferredEngine, progress: p)
            return "Ready: \(created.id)"
        }
    }

    private func launchBridgeForGame(appID: Int, exe: URL) {
        let preferredEngine = gp.preferredWindowsEngineID()
        let defaultRenderer: Renderer = (preferredEngine == CrossOverInstallation.engineID) ? .d3dmetal : .dxmt
        gp.job("Launching \(game.title) via Bridge") { k, p in
            let profileID: String
            if case .profile(let existing, _) = game.kind {
                profileID = existing.id
            } else {
                let recipeID: String
                if case .ownedSteam(_, let existingRecipe) = game.kind, let existingRecipe {
                    recipeID = existingRecipe.id
                } else {
                    recipeID = try k.addCustomSteamGame(appID: appID, title: game.title, renderer: defaultRenderer).id
                }
                let created = try k.createProfile(recipeID: recipeID, engineID: preferredEngine, progress: p)
                profileID = created.id
            }
            _ = try k.launchWithSteamBridge(profileID, executable: exe, progress: p)
            return "Launched \(exe.lastPathComponent)"
        }
    }

    private func pillBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .seleneFont(14, .semibold)
            .foregroundColor(SeleneTheme.ink)
            .padding(.horizontal, canvas.u(12))
            .padding(.vertical, canvas.u(5))
            .background(tint, in: Capsule())
    }

    private func glassPill(_ title: String, icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button {
            SoundEffectService.shared.play(.click)
            action()
        } label: {
            HStack(spacing: canvas.u(8)) {
                Image(systemName: icon)
                    .font(.system(size: canvas.u(16), weight: .semibold))
                Text(title)
                    .seleneFont(17, .semibold)
            }
            .foregroundColor(prominent ? .black : SeleneTheme.ink)
            .padding(.horizontal, canvas.u(22))
            .padding(.vertical, canvas.u(12))
            .background(
                Capsule()
                    .fill(prominent ? Color.white : SeleneTheme.glass)
                    .overlay(Capsule().strokeBorder(SeleneTheme.ink15, lineWidth: max(1, canvas.u(1))))
            )
            .shadow(color: .black.opacity(0.45), radius: canvas.u(8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Options Sheet (Advanced tuning tucked cleanly away from home screen)

    private var optionsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(game.title) — Options").font(.title3.bold())
                Spacer()
                Button("Done") { showOptionsSheet = false }
            }
            Text("Runner: \(game.runnerBadge) · Store: \(game.storeBadge)")
                .font(.callout).foregroundStyle(.secondary)

            if case .profile(let profile, let recipe) = game.kind {
                Divider()
                HStack(spacing: 14) {
                    Picker("Renderer", selection: Binding<Renderer>(
                        get: { profile.renderer ?? recipe?.renderer ?? .dxmt },
                        set: { r in gp.updateProfile(profile.id) { $0.renderer = r } }
                    )) {
                        ForEach(Renderer.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    Toggle("MetalFX", isOn: Binding(
                        get: { profile.metalFX ?? false },
                        set: { on in gp.updateProfile(profile.id) { $0.metalFX = on } }
                    ))
                    Toggle("P-Cores", isOn: Binding(
                        get: { profile.performanceCores ?? true },
                        set: { on in gp.updateProfile(profile.id) { $0.performanceCores = on } }
                    ))
                    Toggle("x87 JIT", isOn: Binding(
                        get: { profile.x87Acceleration ?? false },
                        set: { on in gp.updateProfile(profile.id) { $0.x87Acceleration = on } }
                    ))
                }
                HStack {
                    Button("Take APFS Snapshot") {
                        gp.job("Snapshot \(game.title)") { k, _ in
                            try k.profiles.createSnapshot(profile.id, name: nil).name
                        }
                    }
                    if recipe?.steamAppID != nil {
                        Button("Benchmark FPS (Lab)") {
                            gp.job("Lab Benchmark") { k, p in
                                let res = try await k.lab(profile.id, seconds: 45, progress: p)
                                return "Lab finished: \(res.verdict.rawValue)"
                            }
                        }
                    }
                    if let exe = downloadedDepotExe, gp.bridgeStatus.isReadyToLaunch {
                        Button(isVACBlockedForBridge ? "Play Offline via Bridge (No Win Steam)" : "Play via Bridge (No Win Steam)") {
                            showOptionsSheet = false
                            let overrideVAC = isVACBlockedForBridge
                            gp.job("Launching \(game.title) via Bridge") { k, p in
                                _ = try k.launchWithSteamBridge(profile.id, executable: exe, allowVACOverride: overrideVAC, progress: p)
                                return "Launched \(exe.lastPathComponent) via Bridge"
                            }
                        }
                    }
                    Button("Open Steam") {
                        gp.job("Opening Steam") { k, p in _ = try k.openSteam(profile.id, progress: p); return "Steam opened" }
                    }
                    Button("Stop") {
                        gp.job("Stopping") { k, _ in try k.stop(profile.id); return "Stopped" }
                    }
                }
            }

            Divider()
            HStack {
                if ExternalEnvironment.suggestsObelisk(for: game.antiCheat), let app = gp.externalEnv.obeliskApp {
                    Button("Run with Obelisk") { NSWorkspace.shared.open(app) }
                }
                if ExternalEnvironment.suggestsSiliconium(steamAppID: game.steamAppID), let app = gp.externalEnv.siliconiumApp {
                    Button("Run with Siliconium") { NSWorkspace.shared.open(app) }
                }
                Spacer()
                Button("Open Full Store Catalog & Setup…") {
                    showOptionsSheet = false
                    onOpenCatalog()
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var bridgeDownloadSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download Game — \(game.title)").font(.headline)
            Text("Downloads the Windows game files natively via Valve steamcmd (no Windows Steam client needed).")
                .font(.callout).foregroundStyle(.secondary)
            if isVACBlockedForBridge {
                Text("Note: This game uses VAC. Bridge Mode (No Win Steam) is for offline / local bot matches only — use Install Win Steam for online VAC matchmaking.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !editingBridgeSteamUser, !bridgeSteamUser.isEmpty {
                HStack {
                    Label("Using your logged-in Mac Steam account (\(bridgeSteamUser))", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.callout)
                    Spacer()
                    Button("Switch…") { editingBridgeSteamUser = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } else {
                TextField("Steam login username (blank for free demos)", text: $bridgeSteamUser)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { showBridgeDownloadSheet = false }
                Button("Start Native Download") {
                    showBridgeDownloadSheet = false
                    if let appID = game.steamAppID {
                        gp.launchInteractiveBridgeDownload(appID: appID, username: bridgeSteamUser, title: game.title)
                    }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Square glossy tile artwork rendered inside Arcane's `SpotlightRowView` for every `UnifiedHubGame`.
/// Uses instant 0 ms local Steam `librarycache` images first, falling back to Steam CDN / Epic art.
struct UnifiedHubTileArtwork: View {
    let game: UnifiedHubGame
    let side: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = game.preferredTileURL, url.isFileURL, let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
            } else if let url = game.preferredTileURL, !url.isFileURL {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholderFace
                    }
                }
                .frame(width: side, height: side)
            } else {
                placeholderFace
            }

            // Subtle bottom gradient + small status dot/badge so ready vs not-installed is clear at a glance
            LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .center, endPoint: .bottom)
                .frame(width: side, height: side)
                .allowsHitTesting(false)

            HStack(spacing: 4) {
                Circle()
                    .fill(game.isReady ? Color.green : Color.white.opacity(0.45))
                    .frame(width: max(5, side * 0.045), height: max(5, side * 0.045))
                Text(game.supportsMacOS ? "Mac" : (game.storeBadge == "Steam" ? game.runnerBadge : game.storeBadge))
                    .font(.system(size: max(9, side * 0.068), weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
            }
            .padding(.horizontal, max(6, side * 0.05))
            .padding(.vertical, max(3, side * 0.025))
            .background(.black.opacity(0.55), in: Capsule())
            .padding(max(6, side * 0.05))
        }
        .frame(width: side, height: side)
        .clipped()
    }

    private var placeholderFace: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.14, green: 0.18, blue: 0.28), Color(red: 0.08, green: 0.10, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(game.title)
                .font(.system(size: max(12, side * 0.095), weight: .bold))
                .foregroundColor(.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(max(10, side * 0.08))
        }
        .frame(width: side, height: side)
    }
}
