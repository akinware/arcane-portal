import AppKit
import GamePortKit
import NXLibraryCore
import SwiftUI

/// Arcane Selene-styled console overlay for Windows Games powered by `GamePortKit`.
/// Unifies GamePort's multi-engine Windows stack (CrossOver 26.3, Wine Staging 11.21, DXMT/DXVK/D3DMetal,
/// P-cores, Retina scaling, MetalFX, x87sidecar, AArchX, APFS snapshots, Lab, Self-Healing Play,
/// and live RAM-tier FPS verdicts) inside Arcane's dark-glass living-room interface.
struct WindowsGamesConsoleView: View {
    @ObservedObject var router: AppRouter
    @ObservedObject var gp = GamePortConsoleModel.shared
    let showsHints: Bool

    enum FilterTab: String, CaseIterable, Identifiable {
        case installed = "My Games"
        case epicGog = "Epic & GOG"
        case crossOver = "CrossOver"
        case battlenet = "Battle.net"
        case cod = "Call of Duty"
        case all = "All"
        case verified = "Verified"
        var id: String { rawValue }
    }

    @State private var tab: FilterTab = .installed
    @State private var query = ""
    @State private var selectedRecipeID: String?
    @State private var showAddSteam = false
    @State private var steamSearch = ""
    @State private var steamResults: [SteamStore.SearchResult] = []
    @State private var searchingSteam = false
    @State private var showTools = false
    @State private var showBridgeDownload = false
    @State private var bridgeSteamUser = ""
    @State private var authPrompt: StorefrontKind?
    @State private var authCode = ""
    @State private var gogDownloadID = ""

    private var filteredRecipes: [Recipe] {
        let base: [Recipe]
        switch tab {
        case .installed:
            let set = Set(gp.profiles.compactMap(\.recipeID))
            let mine = gp.recipes.filter { set.contains($0.id) }
            base = mine.isEmpty && query.isEmpty ? Array(gp.recipes.prefix(40)) : mine
        case .all:
            base = gp.recipes
        case .battlenet:
            base = gp.recipes.filter { $0.launch == .battlenet }
        case .verified:
            base = gp.recipes.filter { $0.status == .verified }
        case .cod:
            base = gp.recipes.filter { $0.title.localizedCaseInsensitiveContains("call of duty") }
        case .epicGog, .crossOver:
            base = []
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(base.prefix(80)) }
        let words = q.lowercased().split(separator: " ").map(String.init)
        return Array(gp.recipes.filter { r in
            let hay = "\(r.title) \(r.id) \(r.steamAppID.map(String.init) ?? "")".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }.prefix(80))
    }

    private var selectedRecipe: Recipe? {
        if let id = selectedRecipeID, let r = gp.recipes.first(where: { $0.id == id }) { return r }
        if let firstProfile = gp.profiles.first?.recipeID, let r = gp.recipes.first(where: { $0.id == firstProfile }) { return r }
        return filteredRecipes.first
    }

    var body: some View {
        ZStack {
            SeleneTheme.scrim.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Divider().background(SeleneTheme.ink15)
                HStack(spacing: 0) {
                    leftCatalogColumn
                        .frame(width: 340)
                    Divider().background(SeleneTheme.ink15)
                    if tab == .epicGog && query.isEmpty {
                        epicGogStage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if tab == .crossOver && query.isEmpty {
                        crossOverStage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        rightStageColumn
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if let busy = gp.busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.callout.weight(.medium)).foregroundStyle(.white)
                        if let last = gp.statusLog.last {
                            Text("· \(last)").font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Color.blue.opacity(0.28))
                } else if let last = gp.statusLog.last {
                    HStack {
                        Text(last).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 24).padding(.vertical, 6)
                    .background(Color.black.opacity(0.35))
                }
            }
        }
        .onAppear {
            gp.refresh()
            if selectedRecipeID == nil { selectedRecipeID = selectedRecipe?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nxWindowsGamesGamepadAction)) { note in
            guard let action = note.object as? GamepadAction else { return }
            switch action {
            case .cancel:
                SoundEffectService.shared.play(.back)
                router.back()
            case .navigateDown:
                stepSelection(by: 1)
            case .navigateUp:
                stepSelection(by: -1)
            case .confirm:
                if let r = selectedRecipe, let p = gp.profile(for: r), gp.busy == nil {
                    gp.launchGame(profile: p, recipe: r)
                }
            default:
                break
            }
        }
        .onExitCommand {
            SoundEffectService.shared.play(.back)
            router.back()
        }
        .sheet(isPresented: $showAddSteam) { addSteamSheet }
        .sheet(isPresented: $showBridgeDownload) { bridgeDownloadSheet }
        .sheet(item: $authPrompt) { kind in
            VStack(alignment: .leading, spacing: 12) {
                Text(kind == .epic ? "Sign In to Epic Games" : "Sign In to GOG").font(.headline)
                Text(kind == .epic
                     ? "Sign in on the Epic page that opened in your browser, copy the authorizationCode value, and paste it below."
                     : "Sign in on the GOG page that opened in your browser, copy the code= value from the final URL, and paste it below.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Authorization code", text: $authCode).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { authPrompt = nil }
                    Button("Connect") {
                        let code = authCode
                        authPrompt = nil
                        if kind == .epic { gp.signInEpic(code: code) }
                        else { gp.signInGOG(code: code) }
                    }.buttonStyle(.borderedProminent).disabled(authCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    private func stepSelection(by delta: Int) {
        let list = filteredRecipes
        guard !list.isEmpty else { return }
        let idx = list.firstIndex(where: { $0.id == selectedRecipe?.id }) ?? 0
        let next = min(max(idx + delta, 0), list.count - 1)
        selectedRecipeID = list[next].id
        SoundEffectService.shared.play(.focus)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                SoundEffectService.shared.play(.back)
                router.back()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.headline)
            }
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 2) {
                Text("Windows Games · GamePort").font(.title2.bold()).foregroundStyle(.white)
                Text("\(gp.profiles.count) ready · \(gp.recipes.count) catalog · \(gp.installedEngines.count) engines")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
            }

            Spacer()

            if gp.installedEngines.isEmpty || gp.steamBase == nil {
                Button {
                    gp.job("1-Click Setup") { k, p in try await k.guidedSetup(progress: p) }
                } label: {
                    Label("1-Click Setup", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(gp.busy != nil)
            }

            Button { showAddSteam = true } label: {
                Label("Add Steam Game…", systemImage: "plus")
            }
            .buttonStyle(.bordered)

            Button {
                router.openSettings(.gamePort)
            } label: {
                Label("Engines & SSD", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    // MARK: - Left Catalog Column

    private var leftCatalogColumn: some View {
        VStack(spacing: 10) {
            TextField("Search \(gp.recipes.count) Windows games…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14).padding(.top, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(FilterTab.allCases) { t in
                        let active = tab == t && query.isEmpty
                        Button(t.rawValue) {
                            tab = t
                            query = ""
                            SoundEffectService.shared.play(.click)
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(active ? Color.accentColor : Color.white.opacity(0.1), in: Capsule())
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 14)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if tab == .epicGog && query.isEmpty {
                        let allStoreGames = mergedEpicAndGOGGames
                        if allStoreGames.isEmpty {
                            Text("Sign in to Epic or GOG on the right to see your games here.")
                                .font(.caption).foregroundStyle(.white.opacity(0.6)).padding(14)
                        } else {
                            ForEach(allStoreGames) { g in
                                HStack(spacing: 10) {
                                    Image(systemName: g.isInstalled ? "play.circle.fill" : "arrow.down.circle")
                                        .foregroundStyle(g.isInstalled ? .green : .purple)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(g.title).font(.callout.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                                        Text("\(g.store.displayName) · \(g.isInstalled ? "Installed" : "Owned")")
                                            .font(.caption2).foregroundStyle(.white.opacity(0.6))
                                    }
                                    Spacer()
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    } else if tab == .crossOver && query.isEmpty {
                        if gp.crossOverGames.isEmpty {
                            Text(gp.crossOverInstallation != nil
                                 ? "CrossOver detected — no Steam/Battle.net/Epic/GOG bottle games found yet."
                                 : "CrossOver.app not installed. PowerKit engines handle everything automatically.")
                                .font(.caption).foregroundStyle(.white.opacity(0.6)).padding(14)
                        } else {
                            ForEach(gp.crossOverGames) { item in
                                Button { gp.launchCrossOverGame(item) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "shippingbox.fill").foregroundStyle(.orange)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title).font(.callout.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                                            Text("Bottle: \(item.bottleName)").font(.caption2).foregroundStyle(.orange.opacity(0.85))
                                        }
                                        Spacer()
                                        Image(systemName: "play.fill").font(.caption).foregroundStyle(.white.opacity(0.75))
                                    }
                                    .padding(8)
                                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        ForEach(filteredRecipes) { recipe in
                            catalogRow(recipe)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 16)
            }
        }
    }

    private func catalogRow(_ recipe: Recipe) -> some View {
        let isSelected = selectedRecipe?.id == recipe.id
        let hasProfile = gp.profile(for: recipe) != nil
        let fps = recipe.steamAppID.flatMap { gp.communityVerdicts[$0]?.first?.avgFPS }
        return Button {
            selectedRecipeID = recipe.id
            SoundEffectService.shared.play(.focus)
        } label: {
            HStack(spacing: 10) {
                posterThumb(appID: recipe.steamAppID)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.title)
                        .font(.callout.weight(isSelected ? .bold : .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if hasProfile {
                            Text("Ready").font(.caption2.bold()).foregroundStyle(.green)
                        }
                        Text(recipe.renderer.rawValue.uppercased())
                            .font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.6))
                        if let fps {
                            Text("· \(Int(fps.rounded())) FPS").font(.caption2).foregroundStyle(.cyan)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func posterThumb(appID: Int?) -> some View {
        if let appID, let url = GamePortConsoleModel.steamPosterURL(appID: appID) {
            AsyncImage(url: url) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 34, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 34, height: 48)
                .overlay(Image(systemName: "gamecontroller").font(.caption).foregroundStyle(.white.opacity(0.5)))
        }
    }

    // MARK: - Right Stage Column

    @ViewBuilder
    private var rightStageColumn: some View {
        if let recipe = selectedRecipe {
            let profile = gp.profile(for: recipe)
            let evidence = gp.evidence(for: recipe)
            let verdicts = recipe.steamAppID.flatMap { gp.communityVerdicts[$0] } ?? []
            let ac = AntiCheatDB.bundled.entry(for: recipe)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroBanner(recipe: recipe, profile: profile)

                    // Primary Action Row
                    actionRow(recipe: recipe, profile: profile)

                    // Live Launch Progress + Self-Healing Recovery Card
                    if let profile {
                        launchCard(profile: profile, recipe: recipe)
                    }

                    // Smart External Launchers (Obelisk for Linux-EAC, Siliconium for CoD, Mac Steam, CrossOver)
                    externalBar(recipe: recipe, ac: ac)

                    // Clean-Room Steam Bridge (Zero Windows Steam)
                    if let profile, recipe.launch != .battlenet, recipe.steamAppID != nil {
                        bridgeCard(profile: profile, recipe: recipe, ac: ac)
                    }

                    // 1-Click CrossOver Bottle Quick-Launch Strip (when CrossOver bottles have games)
                    if !gp.crossOverGames.isEmpty {
                        crossOverBottlesStrip
                    }

                    // 1-Click Epic / GOG / Heroic Quick-Launch Strip
                    if !gp.storefrontGames.isEmpty {
                        storefrontGamesStrip
                    }

                    // Compatibility + Live RAM-Tier Verdicts
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: evidence.level == .blocked ? "xmark.octagon.fill" : "checkmark.shield.fill")
                                .foregroundStyle(evidence.level == .blocked ? .red : .green)
                            Text(evidence.title).font(.headline).foregroundStyle(.white)
                        }
                        if let detail = evidence.detail {
                            Text(detail).font(.callout).foregroundStyle(.white.opacity(0.75))
                        }
                        if !verdicts.isEmpty {
                            Divider().background(SeleneTheme.ink15)
                            Text("Community RAM-Tier Results").font(.caption.bold()).foregroundStyle(.cyan)
                            ForEach(verdicts.prefix(4)) { v in
                                Text("• \(v.summary)").font(.caption).foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                    // Performance Pack + Lab + Snapshots (when profile exists)
                    if let profile {
                        performancePackCard(profile: profile, recipe: recipe)
                    }

                    if !recipe.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Game Notes").font(.headline).foregroundStyle(.white)
                            ForEach(recipe.notes, id: \.self) { note in
                                Text("• \(note)").font(.callout).foregroundStyle(.white.opacity(0.75))
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(24)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "desktopcomputer").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                Text("Select any Windows game to configure or play").foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func heroBanner(recipe: Recipe, profile: Profile?) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let appID = recipe.steamAppID, let url = GamePortConsoleModel.steamHeroURL(appID: appID) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(height: 190)
                .clipped()
                .overlay(
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                )
            } else {
                Color.white.opacity(0.07).frame(height: 130)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.title).font(.largeTitle.bold()).foregroundStyle(.white)
                HStack(spacing: 10) {
                    if let appID = recipe.steamAppID {
                        Text("Steam \(appID)").font(.caption.monospaced()).foregroundStyle(.white.opacity(0.8))
                    }
                    Text("Renderer: \((profile?.renderer ?? recipe.renderer).displayName)")
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
                    if let profile {
                        Text("· Engine: \(profile.engineID)").font(.caption.monospaced()).foregroundStyle(.cyan)
                    }
                }
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func actionRow(recipe: Recipe, profile: Profile?) -> some View {
        HStack(spacing: 12) {
            if gp.installedEngines.isEmpty {
                Button {
                    gp.job("1-Click Setup") { k, p in try await k.guidedSetup(progress: p) }
                } label: {
                    Label("Set up GamePort first", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else if let profile {
                if recipe.launch == .battlenet {
                    let bnInstalled = (try? gp.gameport.battleNet(for: profile.id).isInstalled) == true
                    if bnInstalled {
                        Button {
                            gp.job("Opening Battle.net (\(recipe.title))") { k, p in
                                _ = try k.openBattleNet(profile.id, progress: p)
                                return "Battle.net opened"
                            }
                        } label: {
                            Label("Open Battle.net", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        Button {
                            gp.job("Installing Battle.net") { k, p in
                                _ = try await k.battleNet(for: profile.id).install(progress: p)
                                return "Battle.net installer launched"
                            }
                        } label: {
                            Label("Install Battle.net", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                } else {
                    Button {
                        gp.launchGame(profile: profile, recipe: recipe)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)

                    Button {
                        gp.job("Opening Steam") { k, p in _ = try k.openSteam(profile.id, progress: p); return "Steam opened" }
                    } label: {
                        Label("Open Steam", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }

                Button {
                    gp.job("Stopping \(recipe.title)") { k, _ in try k.stop(profile.id); return "Stopped" }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered).controlSize(.large)

                if recipe.steamAppID != nil {
                    Button {
                        gp.job("Lab Benchmark (\(recipe.title))") { k, p in
                            let res = try await k.lab(profile.id, seconds: 45, progress: p)
                            if let stats = res.steady ?? res.whole {
                                return String(format: "%.0f FPS on %@ (%@)", stats.averageFPS, res.renderer.rawValue, res.verdict.rawValue)
                            }
                            return "Lab finished: \(res.verdict.rawValue)"
                        }
                    } label: {
                        Label("Benchmark FPS", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }
            } else {
                Button {
                    gp.job("Setting up \(recipe.title)") { k, p in
                        try k.createProfile(recipeID: recipe.id, progress: p).id
                    }
                } label: {
                    Label("Set up Windows Environment", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .disabled(gp.busy != nil)
    }

    @ViewBuilder
    private func launchCard(profile: Profile, recipe: Recipe) -> some View {
        switch gp.launchState {
        case .startingSteam(let id) where id == profile.id:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting Windows Steam…").foregroundStyle(.white)
            }.padding(12).background(Color.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        case .waitingForGame(let id, let title) where id == profile.id:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Launching \(title)…").foregroundStyle(.white)
            }.padding(12).background(Color.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        case .running(let id, let sec, let fps) where id == profile.id:
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill").foregroundStyle(.green)
                let fpsText = fps.map { " · \(Int($0.rounded())) FPS" } ?? ""
                Text("Running (\(sec)s)\(fpsText)").foregroundStyle(.white)
            }.padding(12).background(Color.green.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        case .needsAttention(let id, let diagnosis) where id == profile.id:
            VStack(alignment: .leading, spacing: 10) {
                Label(diagnosis.headline, systemImage: "wrench.and.screwdriver.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text(diagnosis.explanation).font(.callout).foregroundStyle(.white.opacity(0.8))
                ForEach(diagnosis.actions) { action in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title).font(.callout.bold()).foregroundStyle(.white)
                            Text(action.detail).font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        Button("Fix & Retry") {
                            gp.applyRecovery(action, to: profile, recipe: recipe, retry: true)
                        }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                HStack {
                    Button("Copy Diagnostic Report") {
                        let report = gp.gameport.diagnosticReport(profileID: profile.id, diagnosis: diagnosis)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        gp.say("✓ Copied redacted diagnostic report")
                    }.controlSize(.small)
                    Spacer()
                    Button("Dismiss") { gp.launchState = .idle }.controlSize(.small)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func externalBar(recipe: Recipe, ac: AntiCheatEntry?) -> some View {
        let showObelisk = ExternalEnvironment.suggestsObelisk(for: ac)
        let showSiliconium = ExternalEnvironment.suggestsSiliconium(steamAppID: recipe.steamAppID)
        let macGame = recipe.steamAppID.flatMap { gp.externalEnv.macSteamGame(appID: $0) }
        let cxBottle = recipe.steamAppID.flatMap { gp.externalEnv.crossoverBottle(containingAppID: $0) }

        if showObelisk || showSiliconium || macGame != nil || cxBottle != nil {
            VStack(alignment: .leading, spacing: 8) {
                if showObelisk {
                    HStack {
                        Label("Linux-supported anti-cheat (\(ac?.antiCheats.joined(separator: ", ") ?? "EAC/BattlEye")): can also run via Obelisk.",
                              systemImage: "shield.lefthalf.filled")
                            .font(.caption).foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        if let app = gp.externalEnv.obeliskApp {
                            Button("Run with Obelisk") { NSWorkspace.shared.open(app) }.controlSize(.small)
                        } else if let url = URL(string: ExternalEnvironment.obeliskWebsite) {
                            Link("Get Obelisk…", destination: url).font(.caption.bold())
                        }
                    }
                }
                if showSiliconium {
                    HStack {
                        Label("Also supported by Siliconium (Plutonium / IW4X / CoD4X / BOIII).",
                              systemImage: "bolt.circle.fill")
                            .font(.caption).foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        if let app = gp.externalEnv.siliconiumApp {
                            Button("Run with Siliconium") { NSWorkspace.shared.open(app) }.controlSize(.small)
                        } else if let url = URL(string: ExternalEnvironment.siliconiumWebsite) {
                            Link("Get Siliconium…", destination: url).font(.caption.bold())
                        }
                    }
                }
                if let macGame, let url = URL(string: "steam://rungameid/\(macGame.appID)") {
                    HStack {
                        Label("Installed in Mac Steam.", systemImage: "desktopcomputer")
                            .font(.caption).foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Button("Play in Mac Steam") { NSWorkspace.shared.open(url) }.controlSize(.small)
                    }
                }
                if let cxBottle, let appID = recipe.steamAppID, gp.externalEnv.crossoverApp != nil {
                    HStack {
                        Label("Installed in CrossOver bottle \"\(cxBottle.name)\".", systemImage: "shippingbox")
                            .font(.caption).foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Button("1-Click Play via CrossOver") {
                            gp.launchCrossOverGame(CrossOverBottleLaunchItem(
                                bottleName: cxBottle.name,
                                bottlePath: cxBottle.path,
                                title: recipe.title,
                                kind: .steam(appID: appID)
                            ))
                        }.controlSize(.small)
                    }
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func bridgeCard(profile: Profile, recipe: Recipe, ac: AntiCheatEntry?) -> some View {
        if let appID = recipe.steamAppID, gp.bridgeStatus.overlayInstalled {
            let vac = SteamBridge.vacDecision(for: ac)
            let downloadedExe = gp.gameport.steamDepot.downloadedExecutable(appID: appID, preferredName: recipe.title)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Label("Zero Windows Steam (GamePort Bridge)", systemImage: "bolt.horizontal.circle.fill")
                        .font(.callout.bold()).foregroundStyle(.cyan)
                    Spacer()
                    if case .blocked = vac {
                        Text("VAC game · use Windows Steam").font(.caption).foregroundStyle(.orange)
                    } else if let exe = downloadedExe {
                        Button("Play via Bridge") {
                            gp.launchViaBridge(profile: profile, recipe: recipe, executable: exe)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(!gp.bridgeStatus.isReadyToLaunch || gp.busy != nil)
                    } else {
                        Button(gp.bridgeStatus.steamCmdInstalled ? "Download Windows Depot" : "Install steamcmd") {
                            if gp.bridgeStatus.steamCmdInstalled {
                                showBridgeDownload = true
                            } else {
                                gp.job("Installing Valve steamcmd") { k, p in
                                    try await k.steamDepot.install(progress: p)
                                    return "Valve steamcmd installed"
                                }
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(gp.busy != nil)
                    }
                }
                if case .allowed = vac {
                    Text(downloadedExe != nil
                         ? "Depot ready (\(downloadedExe!.lastPathComponent)). \(gp.bridgeStatus.isReadyToLaunch ? "Connected to native Mac Steam." : "Install & run native Mac Steam.app to launch.")"
                         : "Downloads Windows files natively via Valve steamcmd (64-bit + 32-bit WoW64) without running Windows Steam in RAM.")
                    .font(.caption).foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(12)
            .background(Color.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var crossOverBottlesStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("1-Click CrossOver Bottle Games (\(gp.crossOverGames.count))", systemImage: "shippingbox.fill")
                .font(.caption.bold()).foregroundStyle(.orange)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(gp.crossOverGames.prefix(12)) { item in
                        Button {
                            gp.launchCrossOverGame(item)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill").font(.caption2)
                                Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                                Text("· \(item.bottleName)").font(.caption2).foregroundStyle(.white.opacity(0.65))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var mergedEpicAndGOGGames: [StorefrontGame] {
        var combined = gp.epicLibrary
        let epicIDs = Set(combined.map(\.id))
        for g in gp.storefrontGames where !epicIDs.contains(g.id) {
            combined.append(g)
        }
        return combined.sorted {
            if $0.isInstalled != $1.isInstalled { return $0.isInstalled }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private var epicGogStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Epic Games, GOG & Heroic").font(.largeTitle.bold()).foregroundStyle(.white)
                Text("Download Windows games natively at full macOS speed and launch straight on CrossOver.app (0 MB) or GamePort PowerKit — zero Epic Games Launcher or GOG Galaxy in RAM.")
                    .font(.callout).foregroundStyle(.white.opacity(0.75))

                HStack(spacing: 12) {
                    // Epic Games card
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Epic Games (legendary \(EpicStorefront.version))", systemImage: "gamecontroller.fill")
                            .font(.headline).foregroundStyle(.purple)
                        Text(gp.epicSignedIn ? "Connected\(gp.epicAccount.map { " as \($0)" } ?? "") · \(gp.epicLibrary.count) Windows titles" : (gp.epicInstalled ? "Installed · Ready to sign in" : "Native arm64 binary · 13.5 MB"))
                            .font(.caption).foregroundStyle(.white.opacity(0.75))
                        HStack {
                            if !gp.epicInstalled {
                                Button("Install legendary") {
                                    gp.job("Installing Epic legendary") { k, p in _ = try await k.epic.install(progress: p); return "Installed legendary" }
                                }.buttonStyle(.borderedProminent)
                            } else if !gp.epicSignedIn {
                                Button("Sign In to Epic") {
                                    NSWorkspace.shared.open(EpicStorefront.loginURL)
                                    authCode = ""
                                    authPrompt = .epic
                                }.buttonStyle(.borderedProminent)
                            } else {
                                Button("Refresh Library") { gp.refreshEpicLibrary() }.buttonStyle(.bordered)
                                Button("Sign Out") { try? gp.gameport.epic.signOut(); gp.refresh() }.buttonStyle(.bordered)
                            }
                        }.disabled(gp.busy != nil)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

                    // GOG card
                    VStack(alignment: .leading, spacing: 8) {
                        Label("GOG (gogdl \(GOGStorefront.version) · DRM-Free)", systemImage: "opticaldisc.fill")
                            .font(.headline).foregroundStyle(.cyan)
                        Text(gp.gogSignedIn ? "Connected · DRM-free native downloads" : (gp.gogInstalled ? "Installed · Ready to sign in" : "Native arm64 binary · 11.1 MB"))
                            .font(.caption).foregroundStyle(.white.opacity(0.75))
                        HStack {
                            if !gp.gogInstalled {
                                Button("Install gogdl") {
                                    gp.job("Installing GOG gogdl") { k, p in _ = try await k.gog.install(progress: p); return "Installed gogdl" }
                                }.buttonStyle(.borderedProminent)
                            } else if !gp.gogSignedIn {
                                Button("Sign In to GOG") {
                                    NSWorkspace.shared.open(GOGStorefront.loginURL)
                                    authCode = ""
                                    authPrompt = .gog
                                }.buttonStyle(.borderedProminent)
                            } else {
                                TextField("GOG Game ID", text: $gogDownloadID).textFieldStyle(.roundedBorder).frame(maxWidth: 130)
                                Button("Download") {
                                    let id = gogDownloadID
                                    gogDownloadID = ""
                                    gp.downloadGOGGame(gameID: id)
                                }.buttonStyle(.borderedProminent).disabled(gogDownloadID.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Sign Out") { gp.gameport.gog.signOut(); gp.refresh() }.buttonStyle(.bordered)
                            }
                        }.disabled(gp.busy != nil)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }

                let games = mergedEpicAndGOGGames
                if !games.isEmpty {
                    Text("Your Epic, GOG & Heroic Library (\(games.count))").font(.headline).foregroundStyle(.white)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(games) { game in
                            VStack(alignment: .leading, spacing: 8) {
                                if let url = game.artworkURL {
                                    AsyncImage(url: url) { phase in
                                        if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                                        else { Color.white.opacity(0.08) }
                                    }
                                    .frame(height: 120).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Text(game.title).font(.callout.bold()).foregroundStyle(.white).lineLimit(1)
                                Text(game.store.displayName).font(.caption2).foregroundStyle(.white.opacity(0.65))
                                HStack {
                                    if game.isInstalled {
                                        Button {
                                            gp.launchStorefrontGame(game)
                                        } label: {
                                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent).controlSize(.small)
                                    } else if game.store == .epic {
                                        Button {
                                            gp.downloadEpicGame(game)
                                        } label: {
                                            Label("Download", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered).controlSize(.small)
                                    }
                                }.disabled(gp.busy != nil)
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var crossOverStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("CrossOver Mode (0 MB Engine & 1-Click Bottles)").font(.largeTitle.bold()).foregroundStyle(.white)
                if let cx = gp.crossOverInstallation {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CrossOver \(cx.version ?? "") connected at \(cx.appURL.path)").font(.headline).foregroundStyle(.white)
                            Text("Available as a 0 MB system engine for all PowerKit, Epic, GOG & Steam Bridge games — plus 1-click bottle launch below.")
                                .font(.caption).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.title2).foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CrossOver.app not installed — GamePort PowerKit is active").font(.headline).foregroundStyle(.white)
                            Text("You don't need CrossOver! GamePort PowerKit runs your games with free built-in engines, DXMT/DXVK/D3DMetal, and APFS snapshots.")
                                .font(.caption).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }

                if !gp.crossOverGames.isEmpty {
                    Text("Discovered CrossOver Bottle Games (\(gp.crossOverGames.count))").font(.headline).foregroundStyle(.white)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(gp.crossOverGames) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                if case .steam(let appID) = item.kind, let url = GamePortConsoleModel.steamHeroURL(appID: appID) {
                                    AsyncImage(url: url) { phase in
                                        if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                                        else { Color.orange.opacity(0.12) }
                                    }
                                    .frame(height: 100).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Text(item.title).font(.callout.bold()).foregroundStyle(.white).lineLimit(1)
                                Text("Bottle: \(item.bottleName)").font(.caption2).foregroundStyle(.orange)
                                Button {
                                    gp.launchCrossOverGame(item)
                                } label: {
                                    Label("1-Click Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            }
                            .padding(12)
                            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var storefrontGamesStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("1-Click Epic / GOG / Heroic Games (\(gp.storefrontGames.count))", systemImage: "gamecontroller.fill")
                .font(.caption.bold()).foregroundStyle(.purple)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(gp.storefrontGames.prefix(12)) { game in
                        Button {
                            gp.launchStorefrontGame(game)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill").font(.caption2)
                                Text(game.title).font(.caption.weight(.semibold)).lineLimit(1)
                                Text("· \(game.store.displayName)").font(.caption2).foregroundStyle(.white.opacity(0.65))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.purple.opacity(0.22), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var bridgeDownloadSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download Windows Depot — \(selectedRecipe?.title ?? "Steam Game")").font(.headline)
            Text("Opens Terminal running Valve's official steamcmd so you can sign in with Steam Guard safely (GamePort never sees your password). Leave blank for anonymous free depots.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Steam username (or leave blank for anonymous)", text: $bridgeSteamUser)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showBridgeDownload = false }
                Button("Start Native Download") {
                    showBridgeDownload = false
                    if let r = selectedRecipe, let appID = r.steamAppID {
                        gp.launchInteractiveBridgeDownload(appID: appID, username: bridgeSteamUser, title: r.title)
                    }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func performancePackCard(profile: Profile, recipe: Recipe) -> some View {
        let snaps = gp.snapshots(for: profile)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Apple Silicon Performance Pack & Safety Net").font(.headline).foregroundStyle(.white)
            HStack(spacing: 16) {
                Picker("Renderer", selection: Binding<Renderer>(
                    get: { profile.renderer ?? recipe.renderer },
                    set: { r in gp.updateProfile(profile.id) { $0.renderer = r } }
                )) {
                    ForEach(Renderer.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }.frame(maxWidth: 220)

                Picker("Scaling", selection: Binding<Int>(
                    get: { profile.retinaMode == nil ? 0 : (profile.retinaMode == true ? 2 : 1) },
                    set: { v in gp.updateProfile(profile.id) { $0.retinaMode = v == 0 ? nil : (v == 2) } }
                )) {
                    Text("Auto").tag(0)
                    Text("1× Native (Faster)").tag(1)
                    Text("Retina HiDPI").tag(2)
                }.frame(maxWidth: 220)

                Picker("Runner", selection: Binding<ExecutionRunner>(
                    get: { profile.executionRunner ?? .rosetta },
                    set: { r in gp.updateProfile(profile.id) { $0.executionRunner = r == .rosetta ? nil : r } }
                )) {
                    ForEach(ExecutionRunner.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 200)
            }

            HStack(spacing: 20) {
                Toggle("P-Cores", isOn: Binding(
                    get: { profile.performanceCores ?? true },
                    set: { on in gp.updateProfile(profile.id) { $0.performanceCores = on } }
                ))
                Toggle("MetalFX", isOn: Binding(
                    get: { profile.metalFX == true },
                    set: { on in gp.updateProfile(profile.id) { $0.metalFX = on ? true : nil } }
                ))
                Toggle("x87sidecar", isOn: Binding(
                    get: { profile.x87Acceleration == true },
                    set: { on in gp.updateProfile(profile.id) { $0.x87Acceleration = on ? true : nil } }
                ))
                Toggle("Metal HUD", isOn: Binding(
                    get: { profile.metalHUD },
                    set: { on in gp.updateProfile(profile.id) { $0.metalHUD = on } }
                ))
            }.foregroundStyle(.white)

            Divider().background(SeleneTheme.ink15)

            HStack {
                Text("APFS Snapshots (\(snaps.count))").font(.callout.bold()).foregroundStyle(.white)
                Spacer()
                Button("Snapshot Now") {
                    gp.job("Snapshot \(profile.id)") { k, _ in try k.snapshot(profile.id).name }
                }.controlSize(.small).disabled(gp.busy != nil)
                if let latest = snaps.first {
                    Button("Rollback to \(latest.name)") {
                        gp.job("Rollback \(profile.id)") { k, _ in
                            _ = try k.restore(profile.id, snapshot: latest.name)
                            return "Restored \(latest.name)"
                        }
                    }.controlSize(.small).disabled(gp.busy != nil)
                }
                Button("Copy Diagnostic Report") {
                    let report = gp.gameport.diagnosticReport(profileID: profile.id)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    gp.say("✓ Copied redacted diagnostic report")
                }.controlSize(.small)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Add Any Steam Game Sheet

    private var addSteamSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Any Steam Windows Game").font(.title2.bold())
            HStack {
                TextField("Search Steam Store or paste App ID / URL…", text: $steamSearch)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSteamSearch() }
                Button("Search") { runSteamSearch() }.disabled(searchingSteam)
            }
            if searchingSteam { ProgressView("Searching Steam…") }
            List(steamResults) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.name).font(.headline)
                        Text("Steam App ID: \(item.id)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add") {
                        do {
                            let added = try gp.gameport.addCustomSteamGame(appID: item.id, title: item.name, renderer: .dxmt)
                            gp.refresh()
                            selectedRecipeID = added.id
                            tab = .all
                            showAddSteam = false
                            gp.say("✓ Added \(added.title)")
                        } catch {
                            gp.say("✗ \(error)")
                        }
                    }.buttonStyle(.borderedProminent)
                }
            }
            HStack {
                Spacer()
                Button("Close") { showAddSteam = false }
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }

    private func runSteamSearch() {
        let q = steamSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if let id = SteamStore.parseAppID(q) {
            searchingSteam = true
            Task {
                let title = (try? await SteamStore.fetchTitle(appID: id)) ?? "Steam Game \(id)"
                await MainActor.run {
                    steamResults = [SteamStore.SearchResult(id: id, name: title)]
                    searchingSteam = false
                }
            }
            return
        }
        searchingSteam = true
        Task {
            let results = (try? await SteamStore.search(q)) ?? []
            await MainActor.run {
                steamResults = results
                searchingSteam = false
            }
        }
    }
}
