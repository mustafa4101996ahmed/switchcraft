import CoreGraphics
import Foundation
import SwitchcraftCore

enum KeyboardMonitorError: Error, LocalizedError {
    case permissionDenied
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Input Monitoring permission hasn't been granted."
        case .tapCreationFailed:
            return "macOS refused the keyboard listener. If you just granted Input Monitoring, quit and reopen Switchcraft."
        }
    }
}

/// System-wide key down/up listener: a listen-only `CGEventTap` on its own thread.
///
/// Listen-only taps need Input Monitoring, not Accessibility. Only the key code, the autorepeat
/// flag and the timestamp are read; characters are never requested, stored or logged.
final class KeyboardMonitor: KeyEventSource, @unchecked Sendable {
    private let lock = UnfairLock()
    private var handler: (@Sendable (KeyEvent) -> Void)?
    private var running = false
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var finished: DispatchSemaphore?

    var onKeyEvent: (@Sendable (KeyEvent) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    var isRunning: Bool { lock.withLock { running } }

    func start() throws {
        guard !isRunning else { return }
        guard CGPreflightListenEventAccess() else { throw KeyboardMonitorError.permissionDenied }
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let created = Locked(false)
        lock.withLock { finished = done }
        let thread = Thread { [weak self] in
            self?.runTapLoop(ready: ready, created: created)
            done.signal()
        }
        thread.name = "com.switchcraft.keyboard"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        guard created.get() else { throw KeyboardMonitorError.tapCreationFailed }
        Log.keyboard.info("Keyboard monitor started (listen-only event tap)")
    }

    /// Stops the tap and waits (≤ 1 s) for its thread to finish, so `start()` can follow at once.
    func stop() {
        let (loop, done) = lock.withLock { (runLoop, finished) }
        guard let done else { return }
        if let loop { CFRunLoopStop(loop) }
        if done.wait(timeout: .now() + 1) == .timedOut {
            Log.keyboard.error("Keyboard thread did not stop within 1 s")
        }
        lock.withLock { finished = nil }
    }

    private func runTapLoop(ready: DispatchSemaphore, created: Locked<Bool>) {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: keyboardTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.keyboard.error("CGEvent.tapCreate failed")
            ready.signal()
            return
        }
        let loop = RunLoop.current.getCFRunLoop()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock {
            self.tap = tap
            self.runLoop = loop
            self.running = true
        }
        created.set(true)
        ready.signal()

        CFRunLoopRun()

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(tap)
        lock.withLock {
            self.tap = nil
            self.runLoop = nil
            self.running = false
        }
        Log.keyboard.info("Keyboard monitor stopped")
    }

    /// Called on the tap thread.
    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = lock.withLock({ self.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.keyboard.notice("Event tap was disabled by the system; re-enabled")
        case .keyDown:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            emit(event, keyCode: code, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            emit(event, keyCode: code, isRepeat: false, isRelease: true)
        case .flagsChanged:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            guard KeyClassifier.isModifier(code) else { return }
            // Device-dependent flag bits tell left/right presses from releases exactly.
            // Caps Lock reports one flagsChanged per physical press (no separate release).
            if code == KeyClassifier.capsLock {
                emit(event, keyCode: code, isRepeat: false)
            } else {
                emit(event, keyCode: code, isRepeat: false, isRelease: event.flags.rawValue & Self.deviceMask(for: code) == 0)
            }
        default:
            break
        }
    }

    private func emit(_ event: CGEvent, keyCode: UInt16, isRepeat: Bool, isRelease: Bool = false) {
        let now = MonotonicClock.now()
        // CGEvent timestamps are nanoseconds on the mach clock; synthetic events may carry 0.
        let time = event.timestamp == 0 ? now : MonotonicClock.seconds(fromNanoseconds: event.timestamp)
        lock.withLock { handler }?(KeyEvent(time: time, receivedAt: now, keyCode: keyCode, isRepeat: isRepeat, isRelease: isRelease))
    }

    /// NX_DEVICE*KEYMASK bits from IOLLEvent.h.
    static func deviceMask(for keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 59: return 0x0000_0001 // left control
        case 56: return 0x0000_0002 // left shift
        case 60: return 0x0000_0004 // right shift
        case 55: return 0x0000_0008 // left command
        case 54: return 0x0000_0010 // right command
        case 58: return 0x0000_0020 // left option
        case 61: return 0x0000_0040 // right option
        case 62: return 0x0000_2000 // right control
        case 63: return 0x0080_0000 // fn
        default: return 0
        }
    }
}

private func keyboardTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
