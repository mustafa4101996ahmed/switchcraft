import AppKit
import CoreGraphics
import Observation
import SwitchcraftCore

/// Input Monitoring is the only permission Switchcraft needs (listen-only keyboard tap).
/// State is polled, not re-prompted, so the UI updates when the user flips the switch.
@MainActor @Observable
final class PermissionsService {
    private(set) var inputMonitoringGranted = CGPreflightListenEventAccess()
    /// Set while another app (or a stuck lock screen) hides keystrokes from keyboard listeners.
    private(set) var secureInput: SecureInputHolder?
    @ObservationIgnored private var secureInputTracker = SecureInputTracker()
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let holder = secureInputTracker.update(SecureInputProbe.holder(), now: MonotonicClock.now())
        if holder != secureInput {
            secureInput = holder
            Log.permissions.info("Secure input: \(holder.map { "held by \($0.name) (\($0.pid))" } ?? "released", privacy: .public)")
        }
        let granted = CGPreflightListenEventAccess()
        guard granted != inputMonitoringGranted else { return }
        inputMonitoringGranted = granted
        Log.permissions.info("Input Monitoring is now \(granted ? "granted" : "not granted", privacy: .public)")
        onChange?(granted)
    }

    /// Shows the system prompt the first time and adds Switchcraft to the Input Monitoring list.
    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
