/// The app holding macOS secure keyboard input. While anyone holds it, macOS hides key presses
/// (but not modifier changes) from every keyboard listener, Switchcraft's included.
public struct SecureInputHolder: Equatable, Sendable {
    public var pid: Int32
    public var name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }

    /// loginwindow holding it outside the lock screen is a macOS glitch after unlocking:
    /// keys stay hidden from listeners until the Mac is locked and unlocked with a password.
    public var isLockScreen: Bool { name == "loginwindow" }
}

/// Decides when a holder is worth telling the user about. A password field is reported at once;
/// loginwindow only once it outlasts a normal unlock (it holds secure input briefly every time).
public struct SecureInputTracker: Sendable {
    public static let lockScreenGrace = 4.0

    private var current: SecureInputHolder?
    private var since = 0.0

    public init() {}

    public mutating func update(_ holder: SecureInputHolder?, now: Double) -> SecureInputHolder? {
        if holder != current {
            current = holder
            since = now
        }
        guard let holder else { return nil }
        return holder.isLockScreen && now - since < Self.lockScreenGrace ? nil : holder
    }
}
