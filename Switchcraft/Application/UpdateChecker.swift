import AppKit
import Observation
import SwitchcraftCore

/// Asks GitHub for the latest release at launch and once a day, and prompts when it's newer than
/// this build. Switchcraft's only network request: nothing about the Mac or the typing is sent.
@MainActor @Observable
final class UpdateChecker {
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/mustafa4101996ahmed/switchcraft/releases/latest")!

    /// A release newer than this build, once a check has found one.
    private(set) var available: LatestRelease?
    private let current = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? AppVersion("0")!
    @ObservationIgnored private var isChecking = false

    func start() {
        Task {
            while !Task.isCancelled {
                let reachedGitHub = await check(userInitiated: false)
                // Task.sleep counts time asleep too, so a Mac that sleeps overnight still checks daily.
                try? await Task.sleep(for: .seconds(reachedGitHub ? 24 * 3600 : 3600))
            }
        }
    }

    /// Returns false when GitHub couldn't be reached, so the daily schedule retries within the hour.
    @discardableResult
    func check(userInitiated: Bool) async -> Bool {
        guard !isChecking else { return true }
        isChecking = true
        defer { isChecking = false }
        let release: LatestRelease
        do {
            var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            release = try LatestRelease(gitHubJSON: data)
        } catch {
            Log.app.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            if userInitiated {
                show("Couldn't check for updates", "GitHub didn't answer. Check your internet connection and try again.")
            }
            return false
        }
        Log.app.info("Latest release \(release.version, privacy: .public), this build \(self.current, privacy: .public)")
        available = release.version > current ? release : nil
        if let available {
            await prompt(available, waitForTypingPause: !userInitiated)
        } else if userInitiated {
            show("Switchcraft is up to date", "Version \(current) is the latest release.")
        }
        return true
    }

    private func prompt(_ release: LatestRelease, waitForTypingPause: Bool) async {
        // A dialog that takes focus mid-sentence would swallow keystrokes, so wait for a quiet moment.
        while waitForTypingPause && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 5 {
            try? await Task.sleep(for: .seconds(5))
        }
        let alert = NSAlert()
        alert.messageText = "Switchcraft \(release.version) is available"
        alert.informativeText = "You have version \(current). Download the new version, quit Switchcraft, then drag the new one into Applications. Your settings stay as they are."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.downloadURL)
        }
    }

    private func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}
