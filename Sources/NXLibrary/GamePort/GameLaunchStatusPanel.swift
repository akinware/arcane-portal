import AppKit
import GamePortKit
import SwiftUI

/// Live Play status under Spotlight / in the Console: which step Windows Steam is on, how long it has
/// taken, and what to do when Steam waits on a hidden prompt or stops progressing.
struct GameLaunchStatusPanel: View {
    @ObservedObject var gp = GamePortConsoleModel.shared
    let profile: Profile
    let recipe: Recipe?
    var scale: CGFloat = 1

    private func u(_ v: CGFloat) -> CGFloat { v * scale }

    var body: some View {
        switch gp.launchState {
        case .startingSteam(let id) where id == profile.id:
            preparing(LaunchProgress(title: recipe?.title ?? profile.id, stage: .startingSteam, seconds: 0, secondsWithoutProgress: 0))
        case .waitingForGame(let id, let title) where id == profile.id:
            preparing(LaunchProgress(title: title, stage: .startingGame, seconds: 0, secondsWithoutProgress: 0))
        case .preparing(let id, let progress) where id == profile.id:
            preparing(progress)
        case .running(let id, let seconds, let fps) where id == profile.id:
            running(seconds: seconds, fps: fps)
        case .needsAttention(let id, let diagnosis) where id == profile.id:
            attention(diagnosis)
        case .closing(let id) where id == profile.id:
            HStack(spacing: u(10)) {
                ProgressView().controlSize(.small)
                Text("Game closed — shutting down Windows Steam (finishing Steam Cloud sync)…")
                    .font(.system(size: u(14), weight: .medium))
                    .foregroundColor(SeleneTheme.ink82)
            }
            .padding(.horizontal, u(16))
            .padding(.vertical, u(10))
            .background(SeleneTheme.glass, in: RoundedRectangle(cornerRadius: u(16), style: .continuous))
        default:
            EmptyView()
        }
    }

    // MARK: Preparing

    private func preparing(_ p: LaunchProgress) -> some View {
        VStack(alignment: .leading, spacing: u(10)) {
            HStack(spacing: u(10)) {
                if p.looksStuck {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: u(16), weight: .semibold))
                        .foregroundColor(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("\(p.bridgeStep ?? p.stage.title)…")
                    .font(.system(size: u(17), weight: .semibold))
                    .foregroundColor(SeleneTheme.ink)
                Text(Self.clock(p.seconds))
                    .font(.system(size: u(14), weight: .medium).monospacedDigit())
                    .foregroundColor(SeleneTheme.ink60)
                Spacer(minLength: 0)
            }

            if p.bridgeStep == nil {
                steps(current: p.stage)
            }

            Text(p.bridgeStep != nil
                    ? "Playing without Windows Steam — the game signs in through native Mac Steam."
                    : p.waitingForUser ?? (p.looksStuck
                    ? "Steam has been on this step for \(p.secondsWithoutProgress) seconds. Its window is hidden — open it to see what it is doing."
                    : p.stage.hint))
                .font(.system(size: u(13)))
                .foregroundColor(p.looksStuck ? Color.orange.opacity(0.95) : SeleneTheme.ink75)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: u(10)) {
                if p.looksStuck {
                    actionButton("Show Steam", icon: "macwindow", prominent: true) { showSteam() }
                }
                actionButton("Stop", icon: "stop.fill", prominent: false) { stop() }
            }
        }
        .padding(u(16))
        .frame(maxWidth: u(620), alignment: .leading)
        .background(SeleneTheme.glass, in: RoundedRectangle(cornerRadius: u(16), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: u(16), style: .continuous).strokeBorder(p.looksStuck ? Color.orange.opacity(0.5) : SeleneTheme.ink15))
        .animation(.easeOut(duration: 0.2), value: p.stage)
    }

    private func steps(current: SteamLaunchStage) -> some View {
        var shown = SteamLaunchStage.indicatorSteps
        if [.updatingGame, .syncingCloud].contains(current), let i = shown.firstIndex(of: .preparingGame) {
            shown.insert(current, at: i)
        }
        return HStack(spacing: u(6)) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, step in
                let done = step < current
                let active = step == current
                HStack(spacing: u(5)) {
                    Circle()
                        .fill(done ? Color.green : (active ? SeleneTheme.focus : SeleneTheme.ink25))
                        .frame(width: u(8), height: u(8))
                    Text(step.shortTitle)
                        .font(.system(size: u(12), weight: active ? .semibold : .regular))
                        .foregroundColor(active ? SeleneTheme.ink : (done ? SeleneTheme.ink75 : SeleneTheme.ink60))
                }
                if index < shown.count - 1 {
                    Rectangle()
                        .fill(done ? Color.green.opacity(0.6) : SeleneTheme.ink15)
                        .frame(width: u(18), height: max(1, u(1.5)))
                }
            }
        }
    }

    // MARK: Running / attention

    private func running(seconds: Int, fps: Double?) -> some View {
        HStack(spacing: u(10)) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: u(18)))
                .foregroundColor(.green)
            Text("Running")
                .font(.system(size: u(16), weight: .semibold))
                .foregroundColor(SeleneTheme.ink)
            Text(Self.clock(seconds) + (fps.map { " · \(Int($0.rounded())) FPS" } ?? ""))
                .font(.system(size: u(14)).monospacedDigit())
                .foregroundColor(SeleneTheme.ink60)
            Spacer(minLength: u(12))
            actionButton("Stop", icon: "stop.fill", prominent: false) { stop() }
        }
        .padding(.horizontal, u(16))
        .padding(.vertical, u(10))
        .frame(maxWidth: u(620), alignment: .leading)
        .background(SeleneTheme.glass, in: RoundedRectangle(cornerRadius: u(16), style: .continuous))
    }

    private func attention(_ diagnosis: LaunchDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: u(10)) {
            Label(diagnosis.headline, systemImage: "wrench.and.screwdriver.fill")
                .font(.system(size: u(16), weight: .semibold))
                .foregroundColor(.orange)
            Text(diagnosis.explanation)
                .font(.system(size: u(13)))
                .foregroundColor(SeleneTheme.ink82)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: u(10)) {
                if diagnosis.viaBridge {
                    actionButton("Try Again", icon: "arrow.clockwise", prominent: true) { gp.retryBridgeLaunch() }
                    actionButton("Open Mac Steam", icon: "macwindow", prominent: false) { openMacSteam() }
                } else {
                    if let recipe, let first = diagnosis.actions.first {
                        actionButton("\(first.title) & Retry", icon: "arrow.clockwise", prominent: true) {
                            gp.applyRecovery(first, to: profile, recipe: recipe, retry: true)
                        }
                    }
                    actionButton("Show Steam", icon: "macwindow", prominent: false) { showSteam() }
                }
                actionButton("Dismiss", icon: "xmark", prominent: false) { gp.launchState = .idle }
            }
        }
        .padding(u(16))
        .frame(maxWidth: u(620), alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: u(16), style: .continuous))
    }

    // MARK: Actions

    private func showSteam() {
        gp.job("Opening Windows Steam") { k, p in
            _ = try k.openSteam(profile.id, progress: p)
            return "Windows Steam window opened"
        }
    }

    private func openMacSteam() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MacSteam.bundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func stop() {
        gp.stopLaunch(profileID: profile.id)
    }

    private func actionButton(_ title: String, icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: u(6)) {
                Image(systemName: icon).font(.system(size: u(12), weight: .semibold))
                Text(title).font(.system(size: u(13), weight: .semibold))
            }
            .foregroundColor(prominent ? .black : SeleneTheme.ink)
            .padding(.horizontal, u(14))
            .padding(.vertical, u(7))
            .background(Capsule().fill(prominent ? Color.white : SeleneTheme.glassLight))
            .overlay(Capsule().strokeBorder(SeleneTheme.ink15))
        }
        .buttonStyle(.plain)
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
