import Foundation

/// Deterministic synthetic accelerometer signals. Used by unit tests and by the
/// "Synthetic impact signals" simulation source, which runs them through the real DSP.
///
/// The keypress shape mirrors what was measured on a MacBook Air M5: a finger-strike burst
/// starting ~10 ms before the key event and a stronger bottom-out burst peaking ~7 ms after it.
public enum SyntheticSignals {
    public static let sampleRate = 800.0

    public enum Event: Sendable {
        /// `strength` ≈ resulting peak dynamic acceleration in g (soft ≈ 0.006, hard ≈ 0.03).
        case keypress(at: Double, strength: Double)
        case deskBump(at: Double, strength: Double)
        case slowMovement(start: Double, duration: Double, amplitude: Double, frequency: Double)
        case trackpadClick(at: Double, strength: Double)
        /// Continuous vibration, e.g. speakers or a fan.
        case vibration(frequency: Double, amplitude: Double)
    }

    public static func generate(start: Double = 100, duration: Double, noise: Double = 0.0004,
                                events: [Event], seed: UInt64 = 1,
                                sampleRate: Double = sampleRate) -> [AccelSample] {
        var rng = SplitMix64(seed: seed)
        let count = Int(duration * sampleRate)
        var out: [AccelSample] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let t = start + Double(i) / sampleRate
            var x = noise * rng.gaussian(), y = noise * rng.gaussian(), z = -1 + noise * rng.gaussian()
            for event in events {
                let (dx, dy, dz) = contribution(of: event, at: t)
                x += dx
                y += dy
                z += dz
            }
            out.append(AccelSample(time: t, x: Float(x), y: Float(y), z: Float(z)))
        }
        return out
    }

    public static func filter(_ samples: [AccelSample], sampleRate: Double = sampleRate,
                              minimumFloor: Double = 0.0002) -> [FilteredSample] {
        var f = ImpactFilter(sampleRate: sampleRate, minimumFloor: minimumFloor)
        return samples.map { f.process($0) }
    }

    /// Samples inside `window` around `keyTime`, oldest first (what the ring would return).
    public static func window(_ samples: [FilteredSample], keyTime: Double,
                              window: CorrelationWindow) -> [FilteredSample] {
        samples.filter { $0.time >= keyTime - window.pre && $0.time <= keyTime + window.post }
    }

    /// One keypress of `strength`, measured end-to-end through the production filter + analyzer.
    public static func simulatedImpact(strength: Double, seed: UInt64,
                                       window: CorrelationWindow = CorrelationWindow()) -> ImpactMeasurement {
        let keyTime = 100.3
        let raw = generate(duration: 0.4, events: [.keypress(at: keyTime, strength: strength)], seed: seed)
        var analyzer = ImpactAnalyzer(window: window)
        let filtered = filter(raw)
        return analyzer.measure(keyTime: keyTime, samples: Self.window(filtered, keyTime: keyTime, window: window))
    }

    // MARK: - Event models

    private static func contribution(of event: Event, at t: Double) -> (Double, Double, Double) {
        switch event {
        case let .keypress(at, strength):
            // ×2.1: an 800 Hz-sampled 230 Hz burst with a 1 ms attack peaks at ~0.47 of its amplitude,
            // so this makes `strength` ≈ the measured peak.
            let strike = burst(t - (at - 0.010), amplitude: strength * 0.55 * 2.1, frequency: 170, decay: 0.003)
            let bottom = burst(t - (at + 0.005), amplitude: strength * 2.1, frequency: 230, decay: 0.005)
            let v = strike + bottom
            return (v * 0.40, v * 0.45, v * 0.80)
        case let .deskBump(at, strength):
            let low = burst(t - at, amplitude: strength, frequency: 15, decay: 0.05)
            let high = burst(t - at, amplitude: strength * 0.6, frequency: 120, decay: 0.01)
            return (low * 0.3 + high * 0.3, low * 0.3 + high * 0.3, low + high)
        case let .slowMovement(start, duration, amplitude, frequency):
            guard t >= start, t <= start + duration else { return (0, 0, 0) }
            let phase = (t - start) / duration
            let envelope = 0.5 - 0.5 * cos(2 * .pi * phase)
            let v = amplitude * envelope * sin(2 * .pi * frequency * (t - start))
            return (v, v * 0.6, v * 0.2)
        case let .trackpadClick(at, strength):
            let v = burst(t - at, amplitude: strength, frequency: 150, decay: 0.004)
            return (v * 0.5, v * 0.5, v * 0.7)
        case let .vibration(frequency, amplitude):
            let v = amplitude * sin(2 * .pi * frequency * t)
            return (v * 0.3, v * 0.3, v)
        }
    }

    /// Damped sinusoid with a 1 ms attack, starting at dt = 0.
    private static func burst(_ dt: Double, amplitude: Double, frequency: Double, decay: Double) -> Double {
        guard dt >= 0, dt < decay * 12 else { return 0 }
        return amplitude * min(1, dt / 0.001) * exp(-dt / decay) * sin(2 * .pi * frequency * dt + .pi / 2)
    }
}

/// Small deterministic PRNG (also used on realtime paths: no allocation, no locks).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    public mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
