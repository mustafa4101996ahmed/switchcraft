import AppKit
import Observation
import Sparkle

/// Sparkle reads the appcast published with each GitHub release at launch and once a day, and
/// installs updates in place: download, check the EdDSA signature, replace the app, relaunch.
/// Switchcraft's only network requests; nothing about the Mac or the typing is sent.
@MainActor @Observable
final class UpdateChecker: NSObject {
    /// A newer version a background check found, until the user has seen it.
    private(set) var availableVersion: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
    }

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// A window that takes focus mid-sentence would swallow keystrokes, so wait for a quiet moment.
    private func showWhenTypingPauses() async {
        while CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 5 {
            try? await Task.sleep(for: .seconds(5))
        }
        checkForUpdates()
    }
}

// Switchcraft has no Dock icon or main window, so it takes over showing updates Sparkle finds in the
// background ("gentle reminders"); updates found near launch Sparkle shows itself.
extension UpdateChecker: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        availableVersion = update.displayVersionString
        Task { await showWhenTypingPauses() }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }
}
