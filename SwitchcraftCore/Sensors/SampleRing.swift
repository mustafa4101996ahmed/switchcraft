/// One processed accelerometer sample: raw axes (g), high-passed dynamic magnitude (g),
/// and the adaptive noise floor at that moment.
public struct FilteredSample: Sendable, Equatable {
    public var time: Double
    public var x: Float
    public var y: Float
    public var z: Float
    public var dynamic: Float
    public var floor: Float

    public init(time: Double, x: Float, y: Float, z: Float, dynamic: Float, floor: Float) {
        self.time = time
        self.x = x
        self.y = y
        self.z = z
        self.dynamic = dynamic
        self.floor = floor
    }

    public var rawMagnitude: Float { (x * x + y * y + z * z).squareRoot() }
}

/// Fixed-capacity ring of recent samples. One writer (sensor thread), several readers
/// (impact queue, diagnostics graph). Storage is preallocated; appends never allocate.
/// ponytail: unfair lock instead of a lock-free SPSC queue — critical sections are tens of
/// nanoseconds at ~800 Hz; switch to atomics if a reader ever shows up in a profile.
public final class SampleRing: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<FilteredSample>
    private var writeIndex = 0
    private var count = 0
    private let lock = UnfairLock()

    public init(capacity: Int = 4096) {
        self.capacity = max(capacity, 16)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: FilteredSample(time: 0, x: 0, y: 0, z: 0, dynamic: 0, floor: 0), count: self.capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    public func append(_ sample: FilteredSample) {
        lock.withLock {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            count = min(count + 1, capacity)
        }
    }

    public func reset() {
        lock.withLock {
            writeIndex = 0
            count = 0
        }
    }

    public var latest: FilteredSample? {
        lock.withLock { count == 0 ? nil : storage[(writeIndex - 1 + capacity) % capacity] }
    }

    public var latestTime: Double { latest?.time ?? -.infinity }

    /// Copies samples with `from <= time <= to`, oldest first, into `out` (cleared first).
    /// Reserve capacity in `out` up front to keep this allocation-free.
    public func copy(from: Double, to: Double, into out: inout [FilteredSample]) {
        out.removeAll(keepingCapacity: true)
        lock.withLock {
            // Times are monotonic: count back from the newest sample until we leave the window.
            var n = 0
            while n < count, storage[slot(n)].time >= from { n += 1 }
            var k = n - 1
            while k >= 0 {
                let s = storage[slot(k)]
                if s.time <= to { out.append(s) }
                k -= 1
            }
        }
    }

    /// Storage slot of the sample `age` positions before the newest one.
    @inline(__always) private func slot(_ age: Int) -> Int {
        (writeIndex - 1 - age + capacity * 2) % capacity
    }

    /// Copies the newest `n` samples, oldest first.
    public func copyLatest(_ n: Int, into out: inout [FilteredSample]) {
        out.removeAll(keepingCapacity: true)
        lock.withLock {
            var k = min(n, count) - 1
            while k >= 0 {
                out.append(storage[slot(k)])
                k -= 1
            }
        }
    }
}
