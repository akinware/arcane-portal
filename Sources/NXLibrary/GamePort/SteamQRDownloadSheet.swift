import AppKit
import CoreImage
import GamePortKit
import SwiftUI

/// One native in-app Steam download (GamePortKit `SteamQRDownloader`, powered by DepotDownloader).
struct SteamDownloadSession: Identifiable, Equatable {
    enum Origin: Equatable { case spotlight, console }

    enum Phase: Equatable {
        case preparing(String)
        case signIn(SteamQRCode)
        case downloading(percent: Double, detail: String)
        case completed(executable: URL?)
        case failed(String)
    }

    let id = UUID()
    let appID: Int
    let title: String
    let origin: Origin
    /// The game uses VAC: Bridge play is offline / local only.
    let vacNote: Bool
    var phase: Phase
    var account: String?
    var statusLine: String?
    /// Updating a game that is already downloaded (only changed files are fetched).
    var isUpdate = false
    /// After an update: false when the game was already up to date.
    var updateChanged: Bool?

    var isActive: Bool {
        switch phase {
        case .completed, .failed: return false
        default: return true
        }
    }

    var progress: Double? {
        if case .downloading(let pct, _) = phase { return pct }
        if case .completed = phase { return 100 }
        return nil
    }

    mutating func apply(_ event: SteamQRDownloadEvent) {
        switch event {
        case .installingTool(let msg):
            phase = .preparing(msg)
        case .status(let msg):
            switch phase {
            case .signIn, .downloading: statusLine = msg
            default: phase = .preparing(msg)
            }
        case .qrCode(let code):
            phase = .signIn(code)
            statusLine = nil
        case .waitingForMobileApproval:
            statusLine = "Waiting for approval in the Steam Mobile App…"
        case .signedIn(let acct):
            account = acct
            statusLine = nil
            phase = .preparing("Signed in as \(acct) — preparing download…")
        case .downloading(let pct, let detail):
            phase = .downloading(percent: pct, detail: detail)
        case .updateChecked(let changed):
            updateChanged = changed
        case .completed(_, let exe):
            phase = .completed(executable: exe)
        }
    }
}

/// Arcane Glass sheet: Steam Mobile QR sign-in, then a live download progress bar.
struct SteamQRDownloadSheet: View {
    @ObservedObject var gp = GamePortConsoleModel.shared

    var body: some View {
        Group {
            if let session = gp.steamDownload {
                content(session)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [SeleneTheme.glassSolid, SeleneTheme.scrim.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
        )
        .interactiveDismissDisabled(gp.steamDownload?.isActive == true)
    }

    @ViewBuilder
    private func content(_ session: SteamDownloadSession) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(session)

            switch session.phase {
            case .signIn(let code):
                signIn(code, status: session.statusLine)
            case .preparing(let message):
                working(message)
            case .downloading(let pct, let detail):
                downloading(percent: pct, detail: detail, status: session.statusLine)
            case .completed(let exe):
                completed(exe, updateChanged: session.updateChanged)
            case .failed(let message):
                failed(message)
            }

            if session.vacNote {
                Label("This game uses VAC. Without Windows Steam it is for offline and local matches only.", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 12))
                    .foregroundColor(.orange.opacity(0.95))
            }

            footer(session)
        }
    }

    private func header(_ session: SteamDownloadSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(SeleneTheme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.isUpdate ? "Update \(session.title)" : "Download \(session.title)")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(SeleneTheme.ink)
                    .lineLimit(1)
                Text(session.account.map { "Windows version · Steam account \($0)" } ?? "Windows version · no Windows Steam needed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SeleneTheme.ink60)
            }
            Spacer()
        }
    }

    private func signIn(_ code: SteamQRCode, status: String?) -> some View {
        HStack(alignment: .center, spacing: 22) {
            SteamQRCodeView(code: code)
                .frame(width: 196, height: 196)
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .accessibilityLabel("Steam sign-in QR code")

            VStack(alignment: .leading, spacing: 10) {
                Text("Scan with the Steam Mobile App to sign in once — no password needed")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(SeleneTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("In the Steam app, tap the shield (Steam Guard) and choose Scan a QR code. Arcane Portal remembers the sign-in, so later downloads start straight away.")
                    .font(.system(size: 12))
                    .foregroundColor(SeleneTheme.ink75)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status ?? "Waiting for approval in the Steam Mobile App…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SeleneTheme.ink82)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func working(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(SeleneTheme.ink90)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }

    private func downloading(percent: Double, detail: String, status: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.1f%%", percent))
                    .font(.system(size: 30, weight: .bold).monospacedDigit())
                    .foregroundColor(SeleneTheme.ink)
                Spacer()
                Text(status ?? "Downloading")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SeleneTheme.ink60)
                    .lineLimit(1)
            }
            GlassProgressBar(fraction: percent / 100)
                .frame(height: 10)
            Text(detail)
                .font(.system(size: 12).monospaced())
                .foregroundColor(SeleneTheme.ink75)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func completed(_ exe: URL?, updateChanged: Bool?) -> some View {
        let text: String
        switch updateChanged {
        case false?: text = "Already up to date — nothing to download"
        case true?: text = "Updated to the latest version — ready to play"
        case nil: text = exe.map { "Ready to play — \($0.lastPathComponent)" } ?? "Download finished"
        }
        return VStack(alignment: .leading, spacing: 10) {
            GlassProgressBar(fraction: 1).frame(height: 10)
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.green)
        }
    }

    private func failed(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func footer(_ session: SteamDownloadSession) -> some View {
        HStack(spacing: 10) {
            if case .signIn(let code) = session.phase, let url = code.url {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            Spacer()
            if session.isActive {
                if case .downloading = session.phase {
                    Button("Hide") { gp.dismissSteamDownload() }
                        .keyboardShortcut(.defaultAction)
                }
                Button("Cancel", role: .cancel) { gp.cancelSteamDownload() }
                    .keyboardShortcut(.cancelAction)
            } else if case .failed = session.phase {
                Button("Close") { gp.dismissSteamDownload() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { gp.retrySteamDownload() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Done") { gp.dismissSteamDownload() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Crisp QR code: regenerated natively by Core Image from the decoded Steam URL, or drawn
/// module-by-module from DepotDownloader's matrix when the URL could not be decoded.
struct SteamQRCodeView: View {
    let code: SteamQRCode

    var body: some View {
        if let url = code.url, let image = Self.render(url) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
        } else {
            Canvas { ctx, size in
                let n = CGFloat(code.size)
                guard n > 0 else { return }
                let cell = min(size.width, size.height) / n
                var path = Path()
                for (y, row) in code.modules.enumerated() {
                    for (x, dark) in row.enumerated() where dark {
                        path.addRect(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell))
                    }
                }
                ctx.fill(path, with: .color(.black))
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    static func render(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // Drop Core Image's 1-module margin; the white card provides the quiet zone.
        let trimmed = output.cropped(to: output.extent.insetBy(dx: 1, dy: 1))
        let scaled = trimmed.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

struct GlassProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(SeleneTheme.ink15)
                Capsule()
                    .fill(LinearGradient(colors: [SeleneTheme.focus, SeleneTheme.focus.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.height, geo.size.width * min(max(fraction, 0), 1)))
                    .shadow(color: SeleneTheme.focusGlow, radius: 6)
            }
        }
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

/// Compact row shown under Spotlight / in the Console while a hidden download keeps running.
struct SteamDownloadMiniStatus: View {
    @ObservedObject var gp = GamePortConsoleModel.shared
    let origin: SteamDownloadSession.Origin

    var body: some View {
        if let s = gp.steamDownload, s.origin == origin, !gp.steamDownloadPresented {
            HStack(spacing: 10) {
                Image(systemName: s.isActive ? "arrow.down.circle" : "exclamationmark.triangle.fill")
                    .foregroundColor(SeleneTheme.ink82)
                Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundColor(SeleneTheme.ink)
                if let pct = s.progress {
                    GlassProgressBar(fraction: pct / 100).frame(width: 160, height: 6)
                    Text(String(format: "%.0f%%", pct)).font(.system(size: 12).monospacedDigit()).foregroundColor(SeleneTheme.ink75)
                } else if case .failed = s.phase {
                    Text("Failed").font(.system(size: 12)).foregroundColor(.orange)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Button("Show") { gp.steamDownloadPresented = true }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(SeleneTheme.glass, in: Capsule())
        }
    }
}
