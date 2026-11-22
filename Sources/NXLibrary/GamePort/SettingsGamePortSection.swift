import AppKit
import GamePortKit
import NXLibraryCore
import SwiftUI
import UniformTypeIdentifiers

/// Native Selene Settings section for `Windows (GamePort)` inside Arcane's Settings sidebar.
@MainActor
struct SettingsGamePortSection: View {
    @ObservedObject var gp = GamePortConsoleModel.shared
    let onActions: ([SettingsRowAction]) -> Void

    var body: some View {
        VStack(spacing: 9) {
            SeleneButtonRow(
                "1-Click Guided Setup",
                subtitle: gp.installedEngines.isEmpty || gp.steamBase == nil
                    ? "Installs the default Windows engine and prepares the shared Steam base."
                    : "Ready · \(gp.installedEngines.count) engine(s) installed, Steam base ready.",
                buttonTitle: gp.busy != nil ? "Working…" : "Run Setup"
            ) {
                gp.job("Guided Setup") { k, p in try await k.guidedSetup(progress: p) }
            }.disabled(gp.busy != nil)

            SettingsSubheading("Storage & External APFS SSD")
            SeleneValueRow(
                "GamePort data folder",
                subtitle: "\(gp.storageInfo.volumeName) · \(gp.storageInfo.filesystem) · \(gp.storageInfo.freeSpaceLabel)",
                value: gp.storageInfo.root.path,
                actionTitle: "Choose SSD"
            ) {
                chooseStorageFolder()
            }
            if gp.storageInfo.isCustom {
                SeleneButtonRow("Reset storage to internal SSD", subtitle: "Returns GamePort data to ~/Library/Application Support/GamePort.", buttonTitle: "Reset") {
                    _ = try? StorageInfo.resetToDefault()
                    gp.reloadStorage()
                }
            }

            SettingsSubheading("Windows Engines (SHA-256 Verified)")
            ForEach(gp.engineCatalog) { entry in
                let status = [
                    entry.isInstalled ? "Installed" : "Available",
                    entry.isDefault ? "Default" : nil,
                    entry.manifest.arch.label,
                    "~\(entry.manifest.downloadSizeLabel)",
                ].compactMap { $0 }.joined(separator: " · ")

                SeleneRow(entry.manifest.displayName, id: "gp-engine-\(entry.id)", subtitle: status, verbatimTitle: true) {
                    HStack(spacing: 10) {
                        if entry.isInstalled && !entry.isDefault {
                            Button("Set Default") {
                                try? gp.gameport.engines.setDefaultEngine(entry.id)
                                gp.refresh()
                            }.buttonStyle(.plain).foregroundColor(SeleneTheme.glyph)
                        }
                        if entry.isBundled {
                            Button(entry.isInstalled ? "Reinstall" : "Install") {
                                let m = entry.manifest
                                gp.job("Installing \(m.id)") { k, p in try await k.engines.install(m, progress: p).id }
                            }.buttonStyle(.plain).foregroundColor(SeleneTheme.glyph).disabled(gp.busy != nil)
                        }
                    }
                }
            }
            SeleneButtonRow("Import engine manifest…", subtitle: "Install a custom CrossOver, WineHQ, or ARM64/FEX JSON manifest.", buttonTitle: "Import") {
                importEngineManifest()
            }.disabled(gp.busy != nil)

            SettingsSubheading("Apple D3DMetal & Performance Tools")
            SeleneToggleRow(
                "Apple D3DMetal Licence (DirectX 12)",
                subtitle: "Required to use Apple's Game Porting Toolkit D3DMetal renderer for DirectX 12 games.",
                info: "D3DMetal belongs to Apple and allows non-commercial evaluation on Apple hardware.",
                isOn: Binding(
                    get: { gp.gptkAccepted },
                    set: { on in
                        if on { try? gp.gameport.licenses.accept("apple-gptk") }
                        else { try? gp.gameport.licenses.revoke("apple-gptk") }
                        gp.refresh()
                    }
                )
            )
            SeleneButtonRow(
                "x87sidecar (Rosetta x87 JIT · 182 KB, MIT)",
                subtitle: gp.x87Installed ? "Installed (\(gp.x87Version ?? "ready")) — accelerates 32-bit/DX9 games under Rosetta." : "Not installed.",
                buttonTitle: gp.x87Installed ? "Remove" : "Install"
            ) {
                if gp.x87Installed {
                    try? gp.gameport.x87sidecar.remove()
                    gp.refresh()
                } else {
                    gp.job("Installing x87sidecar") { k, p in _ = try await k.x87sidecar.install(progress: p); return "x87sidecar installed" }
                }
            }.disabled(gp.busy != nil)

            SeleneButtonRow(
                "AArchX (No-Rosetta Runner · 7.7 MB, LGPL-2.1)",
                subtitle: gp.aarchxInstalled ? "Installed (\(gp.aarchxVersion ?? "ready")) — experimental macOS 26+ runner." : "Not installed.",
                buttonTitle: gp.aarchxInstalled ? "Remove" : "Install"
            ) {
                if gp.aarchxInstalled {
                    try? gp.gameport.aarchx.remove()
                    gp.refresh()
                } else {
                    gp.job("Installing AArchX") { k, p in _ = try await k.aarchx.install(progress: p); return "AArchX installed" }
                }
            }.disabled(gp.busy != nil)

            SettingsSubheading("External Launchers Detected")
            SeleneValueRow("Obelisk", subtitle: "Optional Linux anti-cheat runner (Rocket League, Elden Ring online).",
                           value: gp.externalEnv.hasObelisk ? "Installed" : "Not installed",
                           actionTitle: gp.externalEnv.hasObelisk ? "Open" : "Website") {
                if let app = gp.externalEnv.obeliskApp { NSWorkspace.shared.open(app) }
                else if let url = URL(string: ExternalEnvironment.obeliskWebsite) { NSWorkspace.shared.open(url) }
            }
            SeleneValueRow("Siliconium", subtitle: "Optional dedicated classic Call of Duty / Plutonium / IW4X app.",
                           value: gp.externalEnv.hasSiliconium ? "Installed" : "Not installed",
                           actionTitle: gp.externalEnv.hasSiliconium ? "Open" : "Website") {
                if let app = gp.externalEnv.siliconiumApp { NSWorkspace.shared.open(app) }
                else if let url = URL(string: ExternalEnvironment.siliconiumWebsite) { NSWorkspace.shared.open(url) }
            }
            SeleneValueRow("CrossOver", subtitle: "Detected CrossOver bottles.",
                           value: gp.externalEnv.hasCrossOver ? "\(gp.externalEnv.crossoverBottles.count) bottle(s)" : "Not installed",
                           actionTitle: "Refresh") {
                gp.refresh()
            }

            SettingsSubheading("Community Compatibility Sharing")
            SeleneToggleRow(
                "Share anonymous RAM-tier FPS results",
                subtitle: "Sends anonymous chip, RAM tier, renderer, and FPS verdicts — never Steam ID, username, or paths.",
                info: "Helps GamePort recommend the fastest renderer for M1–M5 Macs.",
                isOn: Binding(
                    get: { gp.telemetryEnabled },
                    set: { on in _ = try? gp.gameport.telemetry.setEnabled(on); gp.refresh() }
                )
            )
        }
        .onAppear {
            gp.refresh()
            onActions([
                .init(id: "gp-setup", title: "1-Click Guided Setup") {
                    gp.job("Guided Setup") { k, p in try await k.guidedSetup(progress: p) }
                },
                .init(id: "gp-storage", title: "Choose External SSD", activate: chooseStorageFolder),
            ])
        }
    }

    private func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a folder on an APFS drive (e.g. External SSD) for GamePort games and engines."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        _ = try? StorageInfo.setCustomRoot(chosen)
        gp.reloadStorage()
    }

    private func importEngineManifest() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a trusted GamePort engine manifest (.json)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        gp.job("Installing custom engine") { k, p in
            try await k.engines.install(EngineManifest.load(url), progress: p).id
        }
    }
}
