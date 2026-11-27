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
    /// A game's process comes up seconds before its window (Wine starting, a splash, shaders): the launch screen
    /// waits this long for the window after Steam or GamePort says the game runs, then leaves anyway.
    static let windowPatience: TimeInterval = 60
    /// Mac Steam's game shows no window of its own process this long after it started: any new game-sized window
    /// counts (a game whose window belongs to another of its programs).
    static let ownWindowPatience: TimeInterval = 20
    /// This long after the game's window appears, Steam or Arcane coming in front of it is not the player's doing
    /// (Steam shows its library as it hands over, Arcane's screen fades): the game is put back in front.
    static let frontGuard: TimeInterval = 20

    private var task: Task<Void, Never>?

    /// Starts following `start`, replacing any game followed before (one launch at a time, as for Arcane's games).
    func watch(_ start: HubPlayStart, model: GamePortConsoleModel, report: @escaping (Event) -> Void) {
        task?.cancel()
        let game = start.game
        let signal = Self.signal(for: start.route)
        task = Task { @MainActor in
            let started = Date()
            let statusCount = model.statusLog.count
            // Windows on screen before Play (Steam's, other apps') are never taken for the game's.
            let baseline = await Task.detached(priority: .utility) { HubWindowProbe.windowIDs() }.value
            var processSince: Date?
            var runningSince: Date?
            var windowSince: Date?
            var pid: pid_t?
            // Steam was out of view before Play (Keep Steam in the background): out of view again with the game.
            var hidesSteam = false
            var markers: [String] = []
            while !Task.isCancelled {
                let guarding = windowSince.map { Date().timeIntervalSince($0) < Self.frontGuard } ?? false
                try? await Task.sleep(for: .seconds(runningSince == nil || guarding ? 1 : 3))
                guard !Task.isCancelled else { return }
                let waited = Date().timeIntervalSince(started)
                if case .macSteam(let appID) = signal, let start = model.macSteamStart, start.appID == appID {
                    hidesSteam = start.steamWasOutOfView
                    markers = start.markers
                }
                if runningSince == nil {
                    // 1. Steam or GamePort says the game's process runs (the window way skips this).
                    if processSince == nil {
                        switch signal {
                        case .gamePort:
                            switch model.launchState {
                            case .running: processSince = Date()
                            case .needsAttention: report(.failed(game.id)); return
                            // Nothing started (another job held GamePort, or it refused at once).
                            case .idle where waited > 10 && model.busy == nil: report(.failed(game.id)); return
                            default: break
                            }
                            if processSince == nil, waited > Self.gamePortPatience { return }
                        case .macSteam(let appID):
                            if let start = model.macSteamStart, start.appID == appID {
                                if start.running { processSince = Date() }
                            } else if waited > 3 {
                                // Mac Steam did not start it (`macSteamDidNotStart` says what Play does next).
                                report(.failed(game.id)); return
                            }
                        case .window:
                            if model.statusLog.count > statusCount, model.statusLog.last?.hasPrefix("✗") == true {
                                report(.failed(game.id)); return
                            } else if waited > LaunchScreenView.ceiling {
                                return
                            }
                        }
                        if processSince == nil, signal != .window { continue }
                    } else if Self.isOver(signal, model: model, pid: nil) {
                        // The process quit before it showed a window: the start failed.
                        report(.failed(game.id)); return
                    }
                    // 2. The game's own window: the launch screen leaves only then, and the game comes to the front
                    // (Wine fills the screen and hides the menu bar only for the app in front).
                    let own = markers
                    let anyWindow = processSince.map { Date().timeIntervalSince($0) > Self.ownWindowPatience } ?? true
                    if let found = await Task.detached(priority: .utility, operation: { () -> HubWindowProbe.Window? in
                        if !own.isEmpty, let window = HubWindowProbe.newGameWindow(
                            excluding: baseline, pids: HubWindowProbe.processIDs(markers: own)) { return window }
                        return own.isEmpty || anyWindow ? HubWindowProbe.newGameWindow(excluding: baseline) : nil
                    }).value {
                        LaunchCoverTrace.event("Windows game window: \(found.owner) (pid \(found.pid))")
                        pid = found.pid
                        windowSince = Date()
                        runningSince = processSince ?? Date()
                        if hidesSteam { MacSteamStart.hideSteam() }
                        await HubWindowProbe.bringForward(found.pid)
                        report(.ready(game.id))
                    } else if let since = processSince, Date().timeIntervalSince(since) > Self.windowPatience {
                        runningSince = since
                        report(.ready(game.id))
                    }
                } else if let since = runningSince {
                    // The window way has only the window's process to tell; the others keep their own signal.
                    if Self.isOver(signal, model: model, pid: signal == .window ? pid : nil) {
                        // Steam puts its library in front as a game quits.
                        if hidesSteam { MacSteamStart.hideSteam(again: true) }
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
                    if guarding, let pid { await Self.keepInFront(pid, hidesSteam: hidesSteam) }
                }
            }
        }
    }

    /// While the game starts, Steam showing its library or Arcane coming back is put right: Steam out of view
    /// again (when it was before Play), the game in front again. Another app in front is the player's choice.
    private static func keepInFront(_ pid: pid_t, hidesSteam: Bool) async {
        let steam = NSRunningApplication.runningApplications(withBundleIdentifier: SteamPlayCoordinator.steamBundleID)
            .first { !$0.isTerminated }
        if hidesSteam, let steam, !steam.isHidden {
            let shown = await Task.detached(priority: .utility) { HubWindowProbe.hasVisibleWindow(pid: steam.processIdentifier) }.value
            if shown { MacSteamStart.hideSteam() }
        }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != pid else { return }
        let isSteam = front.bundleIdentifier == SteamPlayCoordinator.steamBundleID
        let isArcane = front.processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard isSteam || isArcane else { return }
        await HubWindowProbe.bringForward(pid)
    }

    /// The game is no longer running, by its way's own signal (its window's process for the window way).
    private static func isOver(_ signal: Signal, model: GamePortConsoleModel, pid: pid_t?) -> Bool {
        switch signal {
        case .gamePort:
            if case .running = model.launchState { return false }
            return true
        case .macSteam(let appID):
            return !(model.macSteamStart?.appID == appID && model.macSteamStart?.running == true)
        case .window:
            return pid.map { !HubWindowProbe.isAlive($0) } ?? true
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

    /// A window that appeared since `baseline` and looks like a game's; with `pids`, only one of those processes'.
    static func newGameWindow(excluding baseline: Set<CGWindowID>, pids: Set<pid_t>? = nil) -> Window? {
        let me = ProcessInfo.processInfo.processIdentifier
        return windows().first { window in
            !baseline.contains(window.id) && window.pid != me && isGameSized(window.size)
                && (pids.map { $0.contains(window.pid) } ?? !isLauncher(window.owner))
        }
    }

    /// The processes whose command line has one of `markers` (`MacSteamWindowsLaunch.markers`): the game's own,
    /// so a helper's or a tool's window (NotProton's, Wine's) is never taken for the game's.
    static func processIDs(markers: [String]) -> Set<pid_t> {
        guard !markers.isEmpty else { return [] }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return processIDs(inProcessList: String(decoding: data, as: UTF8.self), markers: markers)
    }

    static func processIDs(inProcessList list: String, markers: [String]) -> Set<pid_t> {
        Set(list.split(whereSeparator: \.isNewline).compactMap { line -> pid_t? in
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]) else { return nil }
            let command = trimmed[space...].lowercased()
            return markers.contains { command.contains($0) } ? pid : nil
        })
    }

    /// A window of `pid` is on screen (Steam's library, say, as opposed to Steam running with its window closed).
    static func hasVisibleWindow(pid: pid_t) -> Bool {
        windows().contains { $0.pid == pid && isGameSized($0.size) }
    }

    static func isGameSized(_ size: CGSize) -> Bool {
        size.width >= minimumSize.width && size.height >= minimumSize.height
    }

    static func isLauncher(_ owner: String) -> Bool {
        let name = owner.lowercased()
        return notTheGame.contains { name.contains($0) }
    }

    /// Brings the game's app to the front, over every other app: the player just pressed Play. Activation is
    /// cooperative (only the app in front can hand it over), so Arcane, whose launch screen is still up, takes the
    /// front for a moment when Steam or another app has it, then hands it to the game.
    @MainActor
    static func bringForward(_ pid: pid_t) async {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, !app.isActive else { return }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(250))
            guard !app.isTerminated else { return }
        }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
