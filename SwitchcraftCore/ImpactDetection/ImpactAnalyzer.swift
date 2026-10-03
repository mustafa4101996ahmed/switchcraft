import Foundation

/// Where to look for the chassis impulse relative to the key event timestamp.
/// Measured on a MacBook Air M5: the finger strike starts ~12 ms *before* the key event and the
/// bottom-out peak lands ~8 ms *after* it (p90 +17 ms). `postMs` is added latency in
/// accelerometer mode, so it is a trade-off the user can tune.
public struct CorrelationWindow: Codable, Equatable, Sendable {
    public var preMs: Double
    public var postMs: Double

    public init(preMs: Double = 15, postMs: Double = 8) {
        self.preMs = preMs
        self.postMs = postMs
    }

    public var pre: Double { max(preMs, 0) / 1000 }
    public var post: Double { max(postMs, 0) / 1000 }
}

public struct ImpactMeasurement: Equatable, Sendable {
    public enum Outcome: String, Sendable {
        /// A keystroke-shaped impulse was found in the window.
        case detected
        /// Nothing rose clearly above the noise floor (very soft press, or the sensor missed it).
        case belowNoise
        /// Far larger than any keystroke: desk bump, laptop moved or dropped.
        case rejectedTooLarge
        /// No sensor samples covered the window.
        case noData
    }

    public var outcome: Outcome
    /// Largest dynamic acceleration in the window (g).
    public var peak: Double
    /// Adaptive noise floor just before the window (g).
    public var floor: Double
    /// Impact used for velocity: peak above floor, minus the decaying tail of the previous impact.
    public var magnitude: Double
    /// RMS of the dynamic signal across the window (short-window energy).
    public var energy: Double
    /// Peak time relative to the key event (s).
    public var peakOffset: Double
    public var peakTime: Double
    public var sampleCount: Int

    public var snr: Double { floor > 0 ? peak / floor : 0 }

    public static let empty = ImpactMeasurement(outcome: .noData, peak: 0, floor: 0, magnitude: 0,
                                                energy: 0, peakOffset: 0, peakTime: 0, sampleCount: 0)
}

/// Window analysis around one key event. Lives on the impact queue (not thread-safe).
public struct ImpactAnalyzer: Sendable {
    public var window: CorrelationWindow
    /// Peak must exceed `floor × detectionSNR` to count as an impact.
    public var detectionSNR: Double
    /// Keystrokes on the measured MacBook peaked ≤ 0.06 g; desk bumps reached 0.9 g.
    public var maxPlausiblePeak: Double
    /// Time constant of the previous impact's tail, subtracted during fast typing ("Impact Decay").
    public var impactDecay: Double

    static let sameImpulse = 0.008

    private var lastImpactTime = -Double.infinity
    private var lastImpactMagnitude = 0.0

    public init(window: CorrelationWindow = CorrelationWindow(), detectionSNR: Double = 4,
                maxPlausiblePeak: Double = 0.3, impactDecay: Double = 0.015) {
        self.window = window
        self.detectionSNR = detectionSNR
        self.maxPlausiblePeak = maxPlausiblePeak
        self.impactDecay = impactDecay
    }

    /// `samples` must be the ring contents for `[keyTime - pre, keyTime + post]`, oldest first.
    public mutating func measure(keyTime: Double, samples: [FilteredSample]) -> ImpactMeasurement {
        guard let first = samples.first else { return .empty }

        var peak = 0.0
        var peakTime = first.time
        var sumSquares = 0.0
        for s in samples {
            let d = Double(s.dynamic)
            sumSquares += d * d
            if d > peak {
                peak = d
                peakTime = s.time
            }
        }
        let floor = Double(first.floor)
        let energy = (sumSquares / Double(samples.count)).squareRoot()

        // Peaks closer than `sameImpulse` are one physical impulse (e.g. a two-key chord), so they
        // share the full magnitude instead of the second key being reduced to the residual.
        let elapsed = peakTime - lastImpactTime
        let residual = elapsed > Self.sameImpulse && impactDecay > 0
            ? lastImpactMagnitude * exp(-elapsed / impactDecay) : 0
        let magnitude = max(0, peak - floor - residual)

        let outcome: ImpactMeasurement.Outcome
        if peak > maxPlausiblePeak {
            outcome = .rejectedTooLarge
        } else if peak < floor * detectionSNR || magnitude <= 0 {
            outcome = .belowNoise
        } else {
            outcome = .detected
            lastImpactTime = peakTime
            lastImpactMagnitude = peak - floor
        }

        return ImpactMeasurement(outcome: outcome, peak: peak, floor: floor, magnitude: magnitude,
                                 energy: energy, peakOffset: peakTime - keyTime, peakTime: peakTime,
                                 sampleCount: samples.count)
    }

    public mutating func reset() {
        lastImpactTime = -.infinity
        lastImpactMagnitude = 0
    }
}
