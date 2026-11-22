import AppKit
import GamePortKit
import NXLibraryCore
import SwiftUI

/// A Windows/PC game's head on Spotlight, in the same Selene layout as Arcane's own games: the logo,
/// one Play pill (GamePort picks the way, `HubPlayRoute`), Options and favorite, the stats line, and
/// one quiet line saying how the game will run. Everything else lives in Options.
struct UnifiedHubSpotlightInfo: View {
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.seleneReduceMotion) private var reduceMotion
    @ObservedObject var gp = GamePortConsoleModel.shared

    let game: UnifiedHubGame
    var releaseYear: String? = nil
    var focused: Int? = nil
    var onPill: (Int) -> Void = { _ in }
    var onHoverPill: (Int) -> Void = { _ in }
    let onOpenCatalog: () -> Void

    @State private var logo: NSImage?
    @State private var shown = true
    @State private var restShown = true
    @State private var slid = true

    private var route: HubPlayRoute { gp.playRoute(for: game) }

    private var profile: Profile? {
        if case .profile(let profile, _) = game.kind { return profile }
        return nil
    }

    var body: some View {
        let route = route
        VStack(alignment: .leading, spacing: 0) {
            GameLogoArea(title: game.title, logo: logo)
                .offset(x: slid ? 0 : canvas.u(SpotlightGameInfoView.logoSlideDistance))
                .opacity(shown ? 1 : 0)
            VStack(alignment: .leading, spacing: 0) {
                GamePrimaryActions(primaryTitle: primaryTitle(route),
                                   isFavorite: gp.isFavorite(game),
                                   focused: focused,
                                   primaryEnabled: primaryEnabled,
                                   primaryWaveDots: isStarting,
                                   onAction: onPill, onHover: onHoverPill)
                    .padding(.leading, canvas.u(2)).padding(.top, canvas.u(18))
                SeleneStatsRow(items: stats)
                    .padding(.leading, canvas.u(4)).padding(.top, canvas.u(26))
                howLine(route)
                    .padding(.leading, canvas.u(4)).padding(.top, canvas.u(18))
                activity
                    .padding(.leading, canvas.u(4)).padding(.top, canvas.u(10))
                SteamDownloadMiniStatus(origin: .spotlight)
            }
            .opacity(restShown ? 1 : 0)
        }
        .frame(width: canvas.u(900), alignment: .leading)
        .onAppear { reveal() }
        .task(id: game.id) { await loadLogo() }
        .sheet(isPresented: optionsPresented) {
            HubGameOptionsSheet(game: game, onOpenCatalog: onOpenCatalog)
        }
        .sheet(item: gp.steamDownloadSheetBinding(for: .spotlight)) { _ in SteamQRDownloadSheet() }
    }

    // MARK: - Play pill

    private var isStarting: Bool {
        guard let id = profile?.id, gp.launchState.profileID == id else { return false }
        return gp.launchState.isLaunching
    }

    private var isRunning: Bool {
        guard let id = profile?.id, case .running(let running, _, _) = gp.launchState else { return false }
        return running == id
    }

    private var isClosing: Bool {
        guard let id = profile?.id, case .closing(let closing) = gp.launchState else { return false }
        return closing == id
    }

    private func primaryTitle(_ route: HubPlayRoute) -> String {
        if isStarting { return "Starting" }
        if isRunning { return "Running" }
        if isClosing { return "Closing" }
        return route.title
    }

    private var primaryEnabled: Bool {
        gp.busy == nil && !isStarting && !isRunning && !isClosing
    }

    // MARK: - Stats and the route line

    private var stats: [SeleneStat] {
        var items = [
            SeleneStat.text("PLAYTIME", LibraryPresentation.duration(TimeInterval(game.playtimeMinutes * 60))),
            SeleneStat.text("LAST PLAYED", LibraryPresentation.relative(game.lastPlayed, now: Date())),
        ]
        if game.kind.isSteam {
            items.append(.platform(SteamPlatformLogo.platformName))
        } else {
            items.append(SeleneStat(label: "PLATFORM", value: .text(game.storeBadge)))
        }
        if let releaseYear { items.append(.text("RELEASED", releaseYear)) }
        return items
    }

    /// "Windows version · runs with CrossOver · signed in through your Mac Steam", plus an anti-cheat warning.
    private func howLine(_ route: HubPlayRoute) -> some View {
        VStack(alignment: .leading, spacing: canvas.u(6)) {
            Label {
                Text(route.how(engine: engineName))
            } icon: {
                Image(systemName: route.isPlayable ? "checkmark.seal.fill" : "info.circle")
            }
            .seleneFont(15, .medium)
            .foregroundColor(SeleneTheme.ink75)
            if let ac = game.antiCheat, ac.risk != .caution {
                Label { Text(ac.summary) } icon: { Image(systemName: "exclamationmark.shield.fill") }
                    .seleneFont(15, .medium)
                    .foregroundColor(Color.orange.opacity(0.95))
                    .lineLimit(2)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: canvas.u(4))
    }

    private var engineName: String { gp.engineName(for: game) }

    /// Launch progress, a running job, or the last message.
    @ViewBuilder
    private var activity: some View {
        if let profile, gp.launchState.profileID == profile.id {
            GameLaunchStatusPanel(profile: profile, recipe: recipeOfProfile, scale: canvas.u(1))
        } else if let busy = gp.busy {
            HStack(spacing: canvas.u(10)) {
                ProgressView().controlSize(.small)
                Text(busy).seleneFont(15, .medium).foregroundColor(SeleneTheme.ink90)
                if let last = gp.statusLog.last {
                    Text("· \(last)").seleneFont(14).foregroundColor(SeleneTheme.ink60).lineLimit(1)
                }
            }
        } else if let last = gp.statusLog.last, last.hasPrefix("✗") {
            Label { Text(last.dropFirst(2)) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .seleneFont(14, .medium)
                .foregroundColor(Color.orange.opacity(0.95))
                .lineLimit(2)
        }
    }

    private var recipeOfProfile: Recipe? {
        if case .profile(_, let recipe) = game.kind { return recipe }
        return nil
    }

    private var optionsPresented: Binding<Bool> {
        Binding(get: { gp.hubOptionsGameID == game.id },
                set: { if !$0, gp.hubOptionsGameID == game.id { gp.hubOptionsGameID = nil } })
    }

    // MARK: - Art and motion

    private func loadLogo() async {
        logo = nil
        var url = game.preferredLogoURL.flatMap { $0.isFileURL ? $0 : nil }
        if url == nil, let appID = game.steamAppID.flatMap({ UInt32(exactly: $0) }) {
            url = await SteamMetadataService.shared.image(appID: appID, slot: .logo, remote: game.remoteLogoURL)
        }
        guard !Task.isCancelled, let url else { return }
        let image = await GameArtLoader.decodeLogo(at: url)
        guard !Task.isCancelled, let image else { return }
        withAnimation(.easeOut(duration: 0.3)) { logo = image }
    }

    /// The same arrival as Arcane's own games: the logo fades and slides in, the rest follows it.
    private func reveal() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { shown = false; restShown = false; slid = reduceMotion }
        DispatchQueue.main.async {
            withAnimation(SpotlightGameInfoView.logoFade) { shown = true }
            withAnimation(SpotlightGameInfoView.restMotion) { restShown = true }
            if !reduceMotion { withAnimation(SpotlightGameInfoView.logoSlide) { slid = true } }
        }
    }
}

extension HubPlayRoute {
    /// The route starts the game (rather than installing or setting it up).
    var isPlayable: Bool {
        switch self {
        case .macSteam, .bridge, .windowsSteam, .profile, .battleNet, .crossOverBottle, .gamePortWine, .storefront, .obelisk, .siliconium:
            return true
        default:
            return false
        }
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
