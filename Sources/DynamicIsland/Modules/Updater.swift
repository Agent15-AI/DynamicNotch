import AppKit
import Sparkle

/// Updates from the GitHub releases, by Sparkle: checked once a day and from
/// "Check for Updates…" in the capsule's menu. Each release carries a signed
/// appcast, and `SUFeedURL` points at the latest one.
///
/// An update found while you are busy in another app is offered in the island,
/// not in a window over your work. Clicking the island opens Sparkle's window.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    func start() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func check() {
        // An accessory app's windows open behind the app in front otherwise.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in HUD.shared.show(.update(version: version), for: 10) }
    }
}
