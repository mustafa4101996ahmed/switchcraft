/// Diagnostics counters written by the impact queue, read by the UI at ≤ 30 Hz.
/// Holds key codes and groups only — never characters, never history beyond a few timestamps.
public final class PipelineStats: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var totalKeys = 0
        public var eventsPerSecond = 0
        public var lastKeyCode: UInt16?
        public var lastGroup: KeyGroup?
        public var lastMeasurement: ImpactMeasurement?
        public var lastVelocity: Double?
        public var lastVelocitySource: String = "—"
        /// Key event timestamp → sound handed to the engine (includes the correlation wait).
        public var lastKeyToTriggerMs: Double?
        public var averageKeyToTriggerMs: Double?
        /// Hardware event timestamp → Switchcraft received it.
        public var lastDeliveryMs: Double?
        public var mutedEvents = 0
        public var droppedEvents = 0
        public var fallbackEvents = 0
        public var offsetMedianMs: Double?
        public var offsetP90Ms: Double?
        /// Recent marker times for the debug graph.
        public var recentKeyTimes: [Double] = []
        public var recentImpacts: [(time: Double, peak: Double)] = []
    }

    private let lock = UnfairLock()
    private var snapshotValue = Snapshot()
    private var keyTimes = [Double](repeating: -.infinity, count: 64)
    private var keyTimeIndex = 0
    private var offsets = [Double](repeating: .nan, count: 64)
    private var offsetIndex = 0
    private var impacts = [(time: Double, peak: Double)](repeating: (-.infinity, 0), count: 32)
    private var impactIndex = 0

    public init() {}

    func recordKey(_ event: KeyEvent) {
        lock.withLock {
            snapshotValue.totalKeys += 1
            snapshotValue.lastKeyCode = event.keyCode
            snapshotValue.lastGroup = event.group
            snapshotValue.lastDeliveryMs = (event.receivedAt - event.time) * 1000
            keyTimes[keyTimeIndex] = event.time
            keyTimeIndex = (keyTimeIndex + 1) % keyTimes.count
        }
    }

    func recordMeasurement(_ m: ImpactMeasurement) {
        lock.withLock {
            snapshotValue.lastMeasurement = m
            guard m.outcome == .detected else { return }
            offsets[offsetIndex] = m.peakOffset * 1000
            offsetIndex = (offsetIndex + 1) % offsets.count
            impacts[impactIndex] = (m.peakTime, m.peak)
            impactIndex = (impactIndex + 1) % impacts.count
        }
    }

    func recordTrigger(velocity: Double, source: String, keyToTrigger: Double, usedFallback: Bool) {
        lock.withLock {
            snapshotValue.lastVelocity = velocity
            snapshotValue.lastVelocitySource = source
            let ms = keyToTrigger * 1000
            snapshotValue.lastKeyToTriggerMs = ms
            snapshotValue.averageKeyToTriggerMs = snapshotValue.averageKeyToTriggerMs.map { $0 * 0.9 + ms * 0.1 } ?? ms
            if usedFallback { snapshotValue.fallbackEvents += 1 }
        }
    }

    func recordMuted() { lock.withLock { snapshotValue.mutedEvents += 1 } }
    func recordDropped() { lock.withLock { snapshotValue.droppedEvents += 1 } }

    public func reset() {
        lock.withLock {
            snapshotValue = Snapshot()
            for i in keyTimes.indices { keyTimes[i] = -.infinity }
            for i in offsets.indices { offsets[i] = .nan }
            for i in impacts.indices { impacts[i] = (-.infinity, 0) }
        }
    }

    /// `now` on the MonotonicClock base; used for events/second.
    public func snapshot(now: Double) -> Snapshot {
        lock.withLock {
            var s = snapshotValue
            s.recentKeyTimes = keyTimes.filter { now - $0 < 3 }.sorted()
            s.eventsPerSecond = s.recentKeyTimes.filter { now - $0 <= 1 }.count
            s.recentImpacts = impacts.filter { now - $0.time < 3 }.sorted { $0.time < $1.time }
            let measured = offsets.filter { !$0.isNaN }.sorted()
            if !measured.isEmpty {
                s.offsetMedianMs = measured[measured.count / 2]
                s.offsetP90Ms = measured[min(measured.count - 1, measured.count * 9 / 10)]
            }
            return s
        }
    }
}
