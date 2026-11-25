import SwiftUI
import AppKit
import NXLibraryCore

extension Notification.Name {
    static let nxFindGameGamepadAction = Notification.Name("NXFindGameGamepadAction")
    /// Posted with the picked game's UUID; the home screen selects it.
    static let nxFindGameSelect = Notification.Name("NXFindGameSelect")
}

/// Find a game (View hold or ⌘F): a pill field over a glass scrim, square results as you type.
struct FindGameView: View {
    @ObservedObject var router: AppRouter
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var playSessions: PlaySessionStore
    let artwork: ArtworkStore
    /// Windows games (CrossOver, Mac Steam, GamePort, other stores) are found too.
    @ObservedObject private var hub = GamePortConsoleModel.shared

    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.seleneReduceMotion) private var reduceMotion
    @State private var query = ""
    /// nil while the field has focus; otherwise the result under focus.
    @State private var focused: Int?
    @State private var keyMonitor: Any?
    @FocusState private var fieldFocused: Bool

    private static let columns = 6
    private static let limit = 12

    /// A library game or a Windows game.
    enum Result: Identifiable {
        case catalog(CatalogGame)
        case hub(UnifiedHubGame)

        var id: UUID {
            switch self {
            case .catalog(let game): return game.id
            case .hub(let game): return game.id
            }
        }

        var name: String {
            switch self {
            case .catalog(let game): return game.name
            case .hub(let game): return game.title
            }
        }
    }

    private var results: [Result] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let catalog = LibraryQuery(filter: .all, searchText: query)
            .applyCatalog(to: viewModel.visibleCatalogGames, history: playSessions)
        let steamAppIDs = Set(viewModel.visibleCatalogGames.compactMap { $0.steamGame.map { Int($0.appID) } })
        let needle = Self.normalized(query)
        let windows = hub.visibleHubGames(besidesSteamAppIDs: steamAppIDs)
            .filter { Self.normalized($0.title).contains(needle) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Array((catalog.map(Result.catalog) + windows.map(Result.hub)).prefix(Self.limit))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack(alignment: .top) {
            SeleneTheme.scrim.opacity(0.82)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: canvas.u(40)) {
                field
                grid
                Spacer(minLength: 0)
            }
            .padding(.top, canvas.u(110))
            .padding(.horizontal, canvas.u(120))
            VStack {
                Spacer()
                SeleneHintsBar(right: [
                    HintItem(.b, L10n.text("Close")) { close() },
                    HintItem(.a, L10n.text("Select"))
                ], bottom: SeleneBottomScrim.hintsBottom)
            }
        }
        .onAppear {
            fieldFocused = true
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: query) { focused = nil }
        .onChange(of: results.map(\.id)) { focused = nil }
        .onReceive(NotificationCenter.default.publisher(for: .nxFindGameGamepadAction)) { note in
            guard let action = note.object as? GamepadAction else { return }
            handle(action)
        }
    }

    private var field: some View {
        HStack(spacing: canvas.u(14)) {
            MaterialIconView(.search, size: 24)
                .foregroundColor(SeleneTheme.ink60)
            TextField(L10n.text("Find a game"), text: $query)
                .textFieldStyle(.plain)
                .seleneFont(19)
                .foregroundColor(SeleneTheme.ink)
                .focused($fieldFocused)
                .onSubmit { pick(results.first) }
        }
        .padding(.leading, canvas.u(26))
        .padding(.top, canvas.u(11))
        .padding(.trailing, canvas.u(26))
        .padding(.bottom, canvas.u(13))
        .frame(width: canvas.u(720))
        .background(RoundedRectangle(cornerRadius: canvas.u(22), style: .continuous).fill(SeleneTheme.glass))
        .overlay(RoundedRectangle(cornerRadius: canvas.u(22), style: .continuous)
            .strokeBorder(focused == nil ? SeleneTheme.focus : SeleneTheme.ink15, lineWidth: max(1, canvas.u(2))))
    }

    @ViewBuilder private var grid: some View {
        let games = results
        if !query.isEmpty && games.isEmpty {
            Text(L10n.text("No games match."))
                .seleneFont(19)
                .foregroundColor(SeleneTheme.ink60)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(canvas.u(160)), spacing: canvas.u(28)),
                                     count: Self.columns),
                      spacing: canvas.u(28)) {
                ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                    tile(game, selected: focused == index)
                        .onTapGesture { pick(game) }
                }
            }
        }
    }

    private func tile(_ game: Result, selected: Bool) -> some View {
        VStack(spacing: canvas.u(10)) {
            Group {
                switch game {
                case .catalog(let game):
                    if let native = game.nxnativeGame { SpotlightTileArtwork(game: native, side: canvas.u(160), artwork: artwork) }
                    else { CatalogNativeArtwork(game: game, role: .square) }
                case .hub(let game):
                    UnifiedHubTileArtwork(game: game, side: canvas.u(160))
                }
            }
                .frame(width: canvas.u(160), height: canvas.u(160))
                .clipShape(RoundedRectangle(cornerRadius: canvas.u(12), style: .continuous))
                .overlay(SeleneTileRing(cornerRadius: canvas.u(12), active: selected))
                .scaleEffect(selected && !reduceMotion ? 1.06 : 1)
                .animation(reduceMotion ? nil : SeleneTheme.quick, value: selected)
            Text(game.name)
                .seleneFont(15, selected ? .semibold : .regular)
                .foregroundColor(selected ? SeleneTheme.ink : SeleneTheme.ink60)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: canvas.u(160))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.name)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Input

    private func handle(_ action: GamepadAction) {
        let count = results.count
        switch action {
        case .navigateDown:
            if let index = focused {
                if index + Self.columns < count { move(to: index + Self.columns) }
            } else if count > 0 {
                fieldFocused = false
                move(to: 0)
            }
        case .navigateUp:
            if let index = focused {
                if index >= Self.columns {
                    move(to: index - Self.columns)
                } else {
                    focused = nil
                    fieldFocused = true
                }
            }
        case .navigateLeft:
            if let index = focused, index > 0 { move(to: index - 1) }
        case .navigateRight:
            if let index = focused, index + 1 < count { move(to: index + 1) }
        case .confirm:
            let games = results
            pick(focused.flatMap { games.indices.contains($0) ? games[$0] : nil } ?? games.first)
        case .cancel, .viewHold:
            close()
        default:
            break
        }
    }

    private func move(to index: Int) {
        focused = index
        SoundEffectService.shared.play(.focus)
    }

    private func pick(_ game: Result?) {
        guard let game else { return }
        SoundEffectService.shared.play(.click)
        router.isSearchPresented = false
        // Windows games are on Spotlight and Collection: from anywhere else, Spotlight opens on the game.
        if case .hub = game, router.route != .library, router.route != .collection {
            router.requestSpotlightSelect(game.id)
            router.showLibrary()
            return
        }
        // The home screen applies its own landing rule.
        NotificationCenter.default.post(name: .nxFindGameSelect, object: game.id)
    }

    private func close() {
        SoundEffectService.shared.play(.back)
        router.isSearchPresented = false
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard router.isSearchPresented, !router.isMenuPresented,
                  viewModel.alertMessage == nil, viewModel.settingsNotice == nil else { return event }
            let typing = fieldFocused
            switch event.keyCode {
            case 53:                                   // Esc
                handle(.cancel)
            case 125:                                  // Down
                handle(.navigateDown)
            case 126:                                  // Up
                if typing { return event }
                handle(.navigateUp)
            case 123:                                  // Left
                if typing { return event }
                handle(.navigateLeft)
            case 124:                                  // Right
                if typing { return event }
                handle(.navigateRight)
            case 36, 76:                               // Return
                if typing { return event }
                handle(.confirm)
            case 49:                                   // Space
                if typing { return event }
                handle(.confirm)
            default:
                return event
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
