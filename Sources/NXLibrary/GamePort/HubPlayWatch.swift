import AppKit
import CoreGraphics
import GamePortKit
import NXLibraryCore

/// A Windows game Play just started, for the launch screen and the session card (`HubPlayWatch`).
struct HubPlayStart {
    let game: UnifiedHubGame
    let route: HubPlayRoute
}

extension Notification.Name {
    /// Play started a Windows game; the object is a `HubPlayStart`.
    static let nxHubPlayStarted = Notification.Name("NXHubPlayStarted")
}

/// Follows one Windows game from Play to quit, the way Arcane follows its own games: says when the game is up
/// (the launch screen leaves), when the start failed (it leaves at once), and when the game quit (the session
/// card). Each way to play gives its own signal:
/// - Windows Steam and the Steam Bridge: GamePort's launch state, which watches the game itself.
/// - Mac Steam: GamePort's watch on the game's process (`MacSteamStart`).
/// - Every other way (CrossOver bottles, stores, Mac Steam's own Mac games): the game's first window, then its process.
@MainActor
final class HubPlayWatch {
    static let shared = HubPlayWatch()

    enum Event {
        case ready(UUID)
        case failed(UUID)
        case ended(SessionSummary)
    }

    enum Signal: Equatable {
        case gamePort
        case macSteam(appID: Int)
        case window
    }

    static func signal(for route: HubPlayRoute) -> Signal {
        switch route {
        case .windowsSteam, .profile, .bridge: return .gamePort
        case .macSteamWindows(let appID, _): return .macSteam(appID: appID)
        default: return .window
        }
    }

    /// GamePort's own launches can wait on a Steam update or sign-in for a long time; the session still counts.
    static let gamePortPatience: TimeInterval = 600

    private var task: Task<Void, Never>?

    /// Starts following `start`, replacing any game followed before (one launch at a time, as for Arcane's games).
    func watch(_ start: HubPlayStart, model: GamePortConsoleModel, report: @escaping (Event) -> Void) {
        task?.cancel()
        let game = start.game
        let signal = Self.signal(for: start.route)
        task = Task { @MainActor in
            let started = Date()
            let statusCount = model.statusLog.count
            let baseline = signal == .window ? await Task.detached(priority: .utility) { HubWindowProbe.windowIDs() }.value : []
            var runningSince: Date?
            var pid: pid_t?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(runningSince == nil ? 1 : 3))
                guard !Task.isCancelled else { return }
                let waited = Date().timeIntervalSince(started)
                if runningSince == nil {
                    switch signal {
                    case .gamePort:
                        switch model.launchState {
                        case .running: runningSince = Date()
                        case .needsAttention: report(.failed(game.id)); return
                        // Nothing started (another job held GamePort, or it refused at once).
                        case .idle where waited > 10 && model.busy == nil: report(.failed(game.id)); return
                        default: break
                        }
                        if runningSince == nil, waited > Self.gamePortPatience { return }
                    case .macSteam(let appID):
                        if let start = model.macSteamStart, start.appID == appID {
                            if start.running { runningSince = Date() }
                        } else if waited > 3 {
                            // Mac Steam did not start it (`macSteamDidNotStart` says what Play does next).
                            report(.failed(game.id)); return
                        }
                    case .window:
                        if let found = await Task.detached(priority: .utility, operation: {
                            HubWindowProbe.newGameWindowOwner(excluding: baseline)
                        }).value {
                            pid = found
                            runningSince = Date()
                        } else if model.statusLog.count > statusCount, model.statusLog.last?.hasPrefix("✗") == true {
                            report(.failed(game.id)); return
                        } else if waited > LaunchScreenView.ceiling {
                            return
                        }
                    }
                    if runningSince != nil { report(.ready(game.id)) }
                } else if let since = runningSince {
                    let over: Bool
                    switch signal {
                    case .gamePort:
                        if case .running = model.launchState { over = false } else { over = true }
                    case .macSteam(let appID):
                        over = !(model.macSteamStart?.appID == appID && model.macSteamStart?.running == true)
                    case .window:
                        over = pid.map { !HubWindowProbe.isAlive($0) } ?? true
                    }
                    guard over else { continue }
                    let now = Date()
                    let session = PlaySession(gameID: game.id, titleID: "", bundleID: nil, startedAt: since,
                                              endedAt: now, lastHeartbeatAt: now)
                    let before = TimeInterval(game.playtimeMinutes * 60)
                    if let summary = SessionSummary(session: session, gameID: game.id, gameName: game.title,
                                                    total: before + now.timeIntervalSince(since)) {
                        report(.ended(summary))
                    }
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// The windows on this Mac, for telling when a started game shows its own. Wine and CrossOver games are not
/// Mac apps with a bundle ID, so a new full-size window of another process is the sign; launchers' windows
/// (Steam, CrossOver, stores) and Arcane's own are left out.
enum HubWindowProbe {
    /// Window owners that are launchers or the system, never the game (lowercased, matched as substrings).
    static let notTheGame = ["steam", "crossover", "battle.net", "epic games", "epicgameslauncher", "galaxy",
                             "heroic", "launcher", "arcane portal", "nxlibrary", "finder", "dock", "window server",
                             "windowserver", "control center", "notification", "loginwindow", "systemuiserver",
                             "screencapture", "spotlight"]

    /// The smallest window that counts as a game's (splash screens and progress panels are smaller).
    static let minimumSize = CGSize(width: 480, height: 360)

    struct Window {
        let id: CGWindowID
        let pid: pid_t
        let owner: String
        let size: CGSize
    }

    static func windows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  // Wine and launchers keep hidden helper windows; a game's is on screen (its own Space is the
                  // active one once it is full screen).
                  (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
            return Window(id: id, pid: pid, owner: owner, size: rect.size)
        }
    }

    static func windowIDs() -> Set<CGWindowID> { Set(windows().map(\.id)) }

    /// The process of a window that appeared since `baseline` and looks like a game's.
    static func newGameWindowOwner(excluding baseline: Set<CGWindowID>) -> pid_t? {
        let me = ProcessInfo.processInfo.processIdentifier
        return windows().first { window in
            !baseline.contains(window.id) && window.pid != me && isGameSized(window.size) && !isLauncher(window.owner)
        }?.pid
    }

    static func isGameSized(_ size: CGSize) -> Bool {
        size.width >= minimumSize.width && size.height >= minimumSize.height
    }

    static func isLauncher(_ owner: String) -> Bool {
        let name = owner.lowercased()
        return notTheGame.contains { name.contains($0) }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
