import AppKit
import SwitchcraftCore

/// Silences the macOS alert sound only while you're typing, so the "invalid key" beep an app plays
/// for an unhandled key press is muted, while every other alert plays normally.
///
/// The first key press of a burst sets the system alert volume to 0 (≈3 ms, pre-warmed AppleScript;
/// in-process "set volume" needs no Automation permission). The user's level is restored
/// `idleDelay` after the last key press, on quit, and on the next launch after a crash
/// (the saved level is persisted until restored).
@MainActor
final class AlertBeepSuppressor {
    nonisolated static let idleDelay = 1.0
    private static let savedVolumeKey = "fk.savedAlertVolume"

    /// Set by the owner; off = never touch the alert volume.
    var isActive = false {
        didSet { if !isActive { restore() } }
    }

    private let defaults: UserDefaults
    private let lastPress = Locked(0.0)
    private var timer: Timer?
    private var muteScript: NSAppleScript?
    private var readScript: NSAppleScript?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A previous run that crashed mid-burst left alerts muted: put them back first.
        restore()
        muteScript = Self.compile("set volume alert volume 0")
        readScript = Self.compile("alert volume of (get volume settings)")
        _ = currentVolume() // warm up Standard Additions so the first mute is fast
    }

    /// Called on the keyboard thread for every key press. Cheap: one lock, at most one main-queue hop.
    nonisolated func keyPressed() {
        let wasIdle = lastPress.mutate { last -> Bool in
            let now = MonotonicClock.now()
            defer { last = now }
            return now - last > Self.idleDelay
        }
        guard wasIdle else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.beginBurst() } }
    }

    private func beginBurst() {
        guard isActive else { return }
        if defaults.object(forKey: Self.savedVolumeKey) == nil {
            guard let volume = currentVolume(), volume > 0 else { return } // already silent: nothing to do
            defaults.set(volume, forKey: Self.savedVolumeKey)
            run(muteScript)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreIfIdle() }
        }
    }

    private func restoreIfIdle() {
        if MonotonicClock.now() - lastPress.get() >= Self.idleDelay { restore() }
    }

    /// Puts the user's alert volume back if Switchcraft lowered it. Safe to call any time.
    func restore() {
        timer?.invalidate()
        timer = nil
        guard let saved = defaults.object(forKey: Self.savedVolumeKey) as? Int else { return }
        run(Self.compile("set volume alert volume \(saved)"))
        defaults.removeObject(forKey: Self.savedVolumeKey)
    }

    private func currentVolume() -> Int? {
        guard let readScript else { return nil }
        var error: NSDictionary?
        let result = readScript.executeAndReturnError(&error)
        if let error { Log.app.error("Reading alert volume failed: \(error, privacy: .public)") }
        return error == nil ? Int(result.int32Value) : nil
    }

    private func run(_ script: NSAppleScript?) {
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error { Log.app.error("Changing alert volume failed: \(error, privacy: .public)") }
    }

    private static func compile(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        if let error { Log.app.error("AppleScript compile failed: \(error, privacy: .public)") }
        return script
    }
}
