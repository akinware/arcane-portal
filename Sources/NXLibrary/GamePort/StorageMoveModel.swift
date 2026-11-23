import AppKit
import Foundation
import GamePortKit

/// Confirmation payload for moving GamePort's data folder to another drive or back to the internal SSD.
struct PendingStorageMove: Identifiable, Equatable {
    let id = UUID()
    let plan: StorageMovePlan
    let nonAPFSWarning: String?
}

/// Thread-safe cancellation flag polled by `StorageMove.perform`.
final class StorageMoveCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

extension GamePortConsoleModel {
    /// True while a game launch is in progress or a game is currently running.
    var isGameActiveForStorageMove: Bool {
        if launchState.isLaunching { return true }
        switch launchState {
        case .running, .closing:
            return true
        default:
            break
        }
        return macSteamStart != nil
    }

    /// Title shown in the Settings storage progress row while moving files.
    var storageMoveProgressTitle: String {
        let fraction = min(max(storageMoveProgress?.fraction ?? 0, 0), 1)
        let pct = Int((fraction * 100).rounded())
        return "Moving games… \(pct)%"
    }

    /// Subtitle shown in the Settings storage progress row while moving files.
    var storageMoveProgressSubtitle: String {
        guard let progress = storageMoveProgress else { return "Preparing to move files…" }
        let item = progress.currentItem.trimmingCharacters(in: .whitespacesAndNewlines)
        return item.isEmpty ? "Copying files…" : item
    }

    /// Verifies that no game is launching/running, no Steam download is active, and no other job or move is running.
    /// Logs a clear status message with `say(_:)` and returns `false` when a move cannot start.
    @discardableResult
    func canStartStorageMove() -> Bool {
        if isMovingStorage {
            say("✗ Already moving your GamePort folder. Wait for it to finish or cancel it first.")
            return false
        }
        if isGameActiveForStorageMove {
            say("✗ Cannot move your GamePort folder while a game is launching or running. Quit the game first.")
            return false
        }
        if let download = steamDownload, download.isActive {
            say("✗ Cannot move your GamePort folder while downloading \(download.title). Wait for the download to finish or cancel it first.")
            return false
        }
        if let busy {
            say("✗ Cannot move your GamePort folder while \(busy) is running.")
            return false
        }
        return true
    }

    /// Opens a folder picker and plans a move of the GamePort data folder to the chosen drive/folder.
    func chooseStorageMoveDestination() {
        guard canStartStorageMove() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder on an APFS drive (e.g. External SSD) to move your GamePort games, engines and Windows copies into."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        planStorageMove(to: chosen)
    }

    /// Plans a move of the GamePort data folder back to the internal SSD (`StoragePreference.anchorDirectory`).
    func planMoveToInternalStorage() {
        planStorageMove(to: StoragePreference.anchorDirectory)
    }

    /// Calls `StorageMove.plan(to:)` and presents the confirmation sheet, or logs the error with `say`.
    func planStorageMove(to destination: URL) {
        guard canStartStorageMove() else { return }
        do {
            let plan = try StorageMove.plan(to: destination)
            let warning = plan.destinationIsAPFS
                ? nil
                : StorageInfo.inspect(plan.destination, isCustom: true).warning
            pendingStorageMove = PendingStorageMove(plan: plan, nonAPFSWarning: warning)
        } catch {
            say("✗ \(error)")
        }
    }

    /// Dismisses the pending storage move confirmation without moving anything.
    func cancelPendingStorageMove() {
        pendingStorageMove = nil
    }

    /// Runs `StorageMove.perform` on a background task with live progress and cancellation support.
    func confirmStorageMove() {
        guard let pending = pendingStorageMove else { return }
        pendingStorageMove = nil
        guard canStartStorageMove() else { return }

        let plan = pending.plan
        let cancelBox = StorageMoveCancellationBox()
        storageMoveCancellation = cancelBox
        storageMoveCancelRequested = false
        storageMoveProgress = nil
        isMovingStorage = true
        busy = "Moving games (0%)"
        say("▶ Moving games to \(plan.destination.path)")

        Task.detached(priority: .userInitiated) {
            do {
                let info = try StorageMove.perform(
                    plan,
                    progress: { prog in
                        Task { @MainActor in
                            let model = GamePortConsoleModel.shared
                            guard model.isMovingStorage else { return }
                            model.storageMoveProgress = prog
                            let pct = Int((min(max(prog.fraction, 0), 1) * 100).rounded())
                            model.busy = "Moving games (\(pct)%)"
                        }
                    },
                    isCancelled: {
                        cancelBox.isCancelled
                    }
                )
                await MainActor.run {
                    self.finishStorageMove(movedTo: info.root, error: nil, wasCancelled: false)
                }
            } catch {
                let cancelled = cancelBox.isCancelled
                await MainActor.run {
                    self.finishStorageMove(movedTo: nil, error: error, wasCancelled: cancelled)
                }
            }
        }
    }

    /// Requests cancellation of the active storage move.
    func cancelStorageMove() {
        guard isMovingStorage else { return }
        storageMoveCancelRequested = true
        storageMoveCancellation?.cancel()
    }

    private func finishStorageMove(movedTo destination: URL?, error: Error?, wasCancelled: Bool) {
        isMovingStorage = false
        storageMoveProgress = nil
        storageMoveCancelRequested = false
        storageMoveCancellation = nil
        busy = nil

        if let destination {
            reloadStorage()
            say("✓ Moved your games to \(destination.path)")
        } else if let error {
            say("✗ \(error)")
        } else if wasCancelled {
            say("✗ Cancelled moving your games.")
        }
    }

    /// Switches to another folder without moving any existing games or engines.
    func chooseUseAnotherStorageFolder() {
        guard canStartStorageMove() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a folder on an APFS drive (e.g. External SSD) for GamePort games and engines. Nothing is moved."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        do {
            let info = try StorageInfo.setCustomRoot(chosen)
            reloadStorage()
            say(info.warning.map { "✗ \($0)" } ?? "✓ GamePort now keeps games in \(info.root.path)")
        } catch {
            say("✗ Could not use that folder: \(error)")
        }
    }

    /// Switches back to the internal SSD folder without moving any files from the external drive.
    func useInternalStorageWithoutMoving() {
        guard canStartStorageMove() else { return }
        _ = try? StorageInfo.resetToDefault()
        reloadStorage()
    }
}
