import Foundation

/// key event → (wait for sensor window) → impact measurement → velocity → sound.
///
/// Runs on its own serial user-interactive queue: never on the main actor, never on the
/// sensor or keyboard threads. Events are processed and discarded; nothing is stored.
public final class TypingPipeline: @unchecked Sendable {
    public let stats = PipelineStats()

    private let queue = DispatchQueue(label: "com.switchcraft.impact", qos: .userInteractive)
    private let output: SoundOutput
    private let clock: @Sendable () -> Double
    private let config = Locked(PipelineConfig())
    private let context = Locked(PipelineContext())
    private let sensorBox = Locked<(any AccelerometerService)?>(nil)
    private let calibrationSink = Locked<(@Sendable (ImpactMeasurement) -> Void)?>(nil)
    private let pending = Locked(0)

    /// Backlog beyond this is dropped (counted in diagnostics) instead of playing late.
    static let maxPending = 32
    /// How long past the window end we wait for late sensor samples before using what we have.
    static let maxSensorWait = 0.006

    // Confined to `queue`.
    private var analyzer = ImpactAnalyzer()
    private var windowBuffer: [FilteredSample] = {
        var buffer: [FilteredSample] = []
        buffer.reserveCapacity(512)
        return buffer
    }()
    private var fallbackVelocity = 0.45
    /// Velocity of the last played press per key code, so its release matches; -1 = not playing.
    private var pressVelocity = [Double](repeating: -1, count: 256)
    private var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: Int(MonotonicClock.now() * 1e6)))

    public init(output: SoundOutput, clock: @escaping @Sendable () -> Double = MonotonicClock.now) {
        self.output = output
        self.clock = clock
    }

    public var currentConfig: PipelineConfig { config.get() }
    public func setConfig(_ newValue: PipelineConfig) { config.set(newValue) }
    public func updateContext(_ body: (inout PipelineContext) -> Void) { context.mutate(body) }
    public func setSensor(_ sensor: (any AccelerometerService)?) { sensorBox.set(sensor) }

    /// While set, every key press is measured with the sensor and reported here (calibration).
    public func setCalibrationSink(_ sink: (@Sendable (ImpactMeasurement) -> Void)?) { calibrationSink.set(sink) }

    public func attach(to source: some KeyEventSource) {
        source.onKeyEvent = { [weak self] event in self?.handle(event) }
    }

    /// Entry point from the keyboard thread. Returns immediately.
    public func handle(_ event: KeyEvent) {
        let accepted = pending.mutate { count -> Bool in
            guard count < Self.maxPending else { return false }
            count += 1
            return true
        }
        guard accepted else {
            stats.recordDropped()
            return
        }
        queue.async { [self] in
            process(event)
            pending.mutate { $0 -= 1 }
        }
    }

    /// Blocks until queued events are processed (tests, shutdown).
    public func waitUntilIdle() { queue.sync {} }

    private func process(_ event: KeyEvent) {
        let cfg = config.get()
        if event.isRelease {
            processRelease(event, cfg)
            return
        }
        stats.recordKey(event)
        if event.isRepeat && !cfg.playRepeats { return }

        let sink = calibrationSink.get()
        var measurement: ImpactMeasurement?
        if cfg.mode == .accelerometer || sink != nil, let sensor = sensorBox.get(), sensor.state.isReadable {
            let m = measure(event, ring: sensor.ring, cfg: cfg)
            stats.recordMeasurement(m)
            sink?(m)
            measurement = m
        }

        guard cfg.enabled else { return }
        if isMuted(cfg, context.get()) {
            stats.recordMuted()
            return
        }

        let (velocity, source, usedFallback) = velocity(for: cfg, measurement: measurement)
        output.play(group: event.group, keyCode: event.keyCode, velocity: velocity, keyTime: event.time)
        pressVelocity[Int(event.keyCode & 0xFF)] = velocity
        stats.recordTrigger(velocity: velocity, source: source, keyToTrigger: clock() - event.time,
                            usedFallback: usedFallback)
    }

    /// Releases only sound for presses that sounded, at the press's velocity.
    private func processRelease(_ event: KeyEvent, _ cfg: PipelineConfig) {
        let slot = Int(event.keyCode & 0xFF)
        let velocity = pressVelocity[slot]
        pressVelocity[slot] = -1
        guard velocity >= 0, cfg.enabled, cfg.playReleases, !isMuted(cfg, context.get()) else { return }
        output.playRelease(group: event.group, keyCode: event.keyCode, velocity: velocity, keyTime: event.time)
    }

    private func velocity(for cfg: PipelineConfig, measurement: ImpactMeasurement?) -> (Double, String, Bool) {
        switch cfg.mode {
        case .fixed:
            return (cfg.fixedVelocity, "fixed", false)
        case .accelerometer:
            guard let m = measurement else {
                return (cfg.fixedVelocity, "fixed (sensor unavailable)", true)
            }
            switch m.outcome {
            case .detected:
                let v = cfg.mapper.velocity(forImpact: m.magnitude)
                fallbackVelocity = fallbackVelocity * 0.8 + v * 0.2
                return (v, "accelerometer", false)
            case .belowNoise:
                return (cfg.mapper.velocity(forImpact: m.magnitude), "accelerometer (below noise)", false)
            case .rejectedTooLarge, .noData:
                return (fallbackVelocity, "recent average (\(m.outcome.rawValue))", true)
            }
        case .simulated:
            switch cfg.simulationSource {
            case .randomRange:
                let lo = min(cfg.randomMin, cfg.randomMax), hi = max(cfg.randomMin, cfg.randomMax)
                return (lo + (hi - lo) * rng.unit(), "simulated random", false)
            case .syntheticSignal:
                // Log-uniform strength between a very soft press and a slam, through the real DSP.
                let strength = exp(log(0.004) + (log(0.07) - log(0.004)) * rng.unit())
                let m = SyntheticSignals.simulatedImpact(strength: strength, seed: rng.next(), window: cfg.window)
                stats.recordMeasurement(m)
                return (cfg.mapper.velocity(forImpact: m.magnitude), "simulated signal", false)
            }
        }
    }

    private func measure(_ event: KeyEvent, ring: SampleRing, cfg: PipelineConfig) -> ImpactMeasurement {
        analyzer.window = cfg.window
        analyzer.detectionSNR = cfg.detectionSNR
        analyzer.impactDecay = cfg.impactDecay
        let windowEnd = event.time + cfg.window.post
        // The bottom-out impulse lands after the key event, so wait for samples covering the window.
        let giveUp = max(event.receivedAt, event.time) + cfg.window.post + Self.maxSensorWait
        while ring.latestTime < windowEnd && clock() < giveUp {
            usleep(250)
        }
        ring.copy(from: event.time - cfg.window.pre, to: windowEnd, into: &windowBuffer)
        return analyzer.measure(keyTime: event.time, samples: windowBuffer)
    }

    private func isMuted(_ cfg: PipelineConfig, _ ctx: PipelineContext) -> Bool {
        if let id = ctx.frontmostBundleID, cfg.excludedBundleIDs.contains(id) { return true }
        return cfg.muteWhenMicActive && ctx.microphoneInUse
    }
}
