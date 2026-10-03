import Foundation

/// User-facing response shaping ("Sensitivity" plus the Advanced controls).
public struct VelocityCurve: Codable, Equatable, Sendable {
    /// 0 = soft (needs harder typing), 0.5 = neutral, 1 = aggressive.
    public var sensitivity: Double
    public var gain: Double
    /// Exponent applied to the normalized velocity: < 1 lifts soft presses, > 1 compresses them.
    public var gamma: Double
    public var minVelocity: Double
    public var maxVelocity: Double

    public init(sensitivity: Double = 0.5, gain: Double = 1, gamma: Double = 1,
                minVelocity: Double = 0.05, maxVelocity: Double = 1) {
        self.sensitivity = sensitivity
        self.gain = gain
        self.gamma = gamma
        self.minVelocity = minVelocity
        self.maxVelocity = maxVelocity
    }
}

/// Impact magnitude (g) → velocity 0…1. Interpolates in log-magnitude through the calibration
/// anchors, so the curve is continuous (no hard tier switches).
public struct VelocityMapper: Equatable, Sendable {
    public var calibration: Calibration
    public var curve: VelocityCurve

    /// Where each calibration reference lands on the 0…1 scale.
    public static let softTarget = 0.15
    public static let normalTarget = 0.42
    public static let hardTarget = 0.70
    /// Impacts this many times the hard reference saturate at 1.0 (slam).
    public static let slamRatio = 2.5

    public init(calibration: Calibration = .factoryDefault, curve: VelocityCurve = VelocityCurve()) {
        self.calibration = calibration
        self.curve = curve
    }

    /// Multiplier applied by the Sensitivity slider: 0 → ×0.35, 0.5 → ×1, 1 → ×2.8.
    public var sensitivityScale: Double { pow(2, (min(max(curve.sensitivity, 0), 1) - 0.5) * 3) }

    public func velocity(forImpact magnitude: Double) -> Double {
        let scaled = max(magnitude, 0) * max(curve.gain, 0) * sensitivityScale
        let shaped = pow(normalized(scaled), max(curve.gamma, 0.05))
        let lo = min(max(curve.minVelocity, 0), 1)
        let hi = max(min(curve.maxVelocity, 1), lo)
        return lo + (hi - lo) * shaped
    }

    /// Piecewise-linear in log space: 2×floor → 0, soft → 0.15, normal → 0.42, hard → 0.70,
    /// 2.5×hard → 1.0.
    public func normalized(_ magnitude: Double) -> Double {
        // Anchors forced strictly increasing; plain lets keep the per-keypress path allocation-free.
        let m0 = max(calibration.noiseFloor, 1e-6) * 2
        let m1 = max(calibration.soft, m0 * 1.01)
        let m2 = max(calibration.normal, m1 * 1.01)
        let m3 = max(calibration.hard, m2 * 1.01)
        let m4 = max(calibration.hard * Self.slamRatio, m3 * 1.01)

        func lerp(_ a: Double, _ b: Double, _ va: Double, _ vb: Double) -> Double {
            va + (vb - va) * (log(magnitude) - log(a)) / (log(b) - log(a))
        }
        switch magnitude {
        case ...m0: return 0
        case ...m1: return lerp(m0, m1, 0, Self.softTarget)
        case ...m2: return lerp(m1, m2, Self.softTarget, Self.normalTarget)
        case ...m3: return lerp(m2, m3, Self.normalTarget, Self.hardTarget)
        case ...m4: return lerp(m3, m4, Self.hardTarget, 1)
        default: return 1
        }
    }

    /// Conceptual tier for display: 0–0.25 soft, 0.25–0.5 medium, 0.5–0.75 hard, 0.75–1 slam.
    public static func layer(for velocity: Double) -> VelocityLayer {
        VelocityLayer.at(Int(min(max(velocity, 0), 0.999) * 4))
    }
}

/// Linear crossfade between the two velocity layers adjacent to a velocity (gains sum to 1).
/// Linear, not equal-power: layers are normally the same hit at different intensities, so they're
/// correlated and equal-power gains would bulge +3 dB mid-fade. Layer centres: 0.125 / 0.375 / 0.625 / 0.875.
public struct LayerBlend: Equatable, Sendable {
    public var lower: VelocityLayer
    public var upper: VelocityLayer
    public var lowerGain: Float
    public var upperGain: Float

    public init(velocity: Double) {
        let position = min(max(velocity * 4 - 0.5, 0), 3)
        let index = min(Int(position), 2)
        let fraction = position - Double(index)
        lower = VelocityLayer.at(index)
        upper = VelocityLayer.at(index + 1)
        lowerGain = Float(1 - fraction)
        upperGain = Float(fraction)
    }

    /// Below this a layer is not worth a voice.
    public static let audibleThreshold: Float = 0.03
}
