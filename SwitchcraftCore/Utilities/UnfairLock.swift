import os

/// Minimal heap-allocated `os_unfair_lock`. Critical sections in Switchcraft are a few
/// hundred nanoseconds; the audio render thread only ever uses `tryLock()`.
public final class UnfairLock: @unchecked Sendable {
    private let pointer: os_unfair_lock_t

    public init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always) public func lock() { os_unfair_lock_lock(pointer) }
    @inline(__always) public func unlock() { os_unfair_lock_unlock(pointer) }
    @inline(__always) public func tryLock() -> Bool { os_unfair_lock_trylock(pointer) }

    @inline(__always)
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// A value guarded by an `UnfairLock`.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = UnfairLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func get() -> Value { lock.withLock { value } }
    public func set(_ newValue: Value) { lock.withLock { value = newValue } }
    public func mutate<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}
