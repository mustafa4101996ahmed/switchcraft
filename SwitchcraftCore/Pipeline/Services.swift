/// Hardware boundaries. Production implementations live in the app target; tests use mocks.

/// Streams filtered accelerometer samples into `ring`.
public protocol AccelerometerService: AnyObject, Sendable {
    var ring: SampleRing { get }
    var state: SensorState { get }
    /// Measured callback rate, not an assumed one.
    var measuredSampleRate: Double { get }
    func start()
    func stop()
}

/// Global key down/up source. Delivers key codes and timestamps only.
public protocol KeyEventSource: AnyObject, Sendable {
    var onKeyEvent: (@Sendable (KeyEvent) -> Void)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

/// The sound engine as seen by the pipeline. `play` must be callable from any thread.
public protocol SoundOutput: AnyObject, Sendable {
    /// `keyCode` places the sound in the stereo field and picks that key's own recording.
    func play(group: KeyGroup, keyCode: UInt16, velocity: Double, keyTime: Double)
    /// Key-up sound; `velocity` is the velocity of the matching press.
    func playRelease(group: KeyGroup, keyCode: UInt16, velocity: Double, keyTime: Double)
}
