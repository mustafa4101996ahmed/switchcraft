import Foundation

/// Second-order section (RBJ / bilinear Butterworth).
struct Biquad: Sendable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    static func highPass(cutoff: Double, sampleRate: Double) -> Biquad {
        let fc = min(max(cutoff, 0.1), sampleRate * 0.45)
        let w = tan(Double.pi * fc / sampleRate)
        let n = 1 / (1 + 2.0.squareRoot() * w + w * w)
        var q = Biquad()
        q.b0 = n
        q.b1 = -2 * n
        q.b2 = n
        q.a1 = 2 * (w * w - 1) * n
        q.a2 = (1 - 2.0.squareRoot() * w + w * w) * n
        return q
    }

    static func lowPass(cutoff: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate
        let alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        var f = Biquad()
        f.b0 = (1 - c) / 2 / a0
        f.b1 = (1 - c) / a0
        f.b2 = (1 - c) / 2 / a0
        f.a1 = -2 * c / a0
        f.a2 = (1 - alpha) / a0
        return f
    }

    /// RBJ low shelf, shelf slope 1.
    static func lowShelf(frequency: Double, sampleRate: Double, gainDb: Double) -> Biquad {
        let a = pow(10, gainDb / 40), w = 2 * Double.pi * frequency / sampleRate, c = cos(w)
        let k = 2 * a.squareRoot() * sin(w) / 2 * 2.0.squareRoot()
        let a0 = (a + 1) + (a - 1) * c + k
        var f = Biquad()
        f.b0 = a * ((a + 1) - (a - 1) * c + k) / a0
        f.b1 = 2 * a * ((a - 1) - (a + 1) * c) / a0
        f.b2 = a * ((a + 1) - (a - 1) * c - k) / a0
        f.a1 = -2 * ((a - 1) + (a + 1) * c) / a0
        f.a2 = ((a + 1) + (a - 1) * c - k) / a0
        return f
    }

    /// Primes the state as if the input had been `value` forever (avoids a start-up transient
    /// from the ~1 g gravity step).
    mutating func prime(with value: Double) {
        x1 = value
        x2 = value
        y1 = 0
        y2 = 0
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}

/// Streaming per-sample stage, run on the sensor thread:
/// raw XYZ → 2nd-order high-pass per axis (removes gravity and slow laptop movement)
/// → dynamic magnitude → adaptive noise floor.
public struct ImpactFilter: Sendable {
    public static let defaultCutoff = 25.0
    public static let defaultFloor = 0.0006

    public private(set) var sampleRate: Double
    public private(set) var cutoff: Double
    public private(set) var noiseFloor: Double
    /// User-adjustable lower bound for the adaptive floor ("Noise Floor" in Advanced settings).
    public var minimumFloor: Double

    private var hx: Biquad
    private var hy: Biquad
    private var hz: Biquad
    private var primed = false

    /// Floor falls quickly toward quiet samples and rises slowly, with impulses clipped to 3×
    /// the floor so keystrokes barely move it while sustained vibration (speakers, fans) does.
    private let fallRate = 0.01
    private let riseRate = 0.004

    public init(sampleRate: Double = 800, cutoff: Double = defaultCutoff,
                initialFloor: Double = defaultFloor, minimumFloor: Double = 0.0002) {
        self.sampleRate = sampleRate
        self.cutoff = cutoff
        self.noiseFloor = max(initialFloor, minimumFloor)
        self.minimumFloor = minimumFloor
        hx = .highPass(cutoff: cutoff, sampleRate: sampleRate)
        hy = hx
        hz = hx
    }

    public mutating func process(_ s: AccelSample) -> FilteredSample {
        let x = Double(s.x), y = Double(s.y), z = Double(s.z)
        if !primed {
            hx.prime(with: x)
            hy.prime(with: y)
            hz.prime(with: z)
            primed = true
        }
        let dx = hx.process(x), dy = hy.process(y), dz = hz.process(z)
        let dynamic = (dx * dx + dy * dy + dz * dz).squareRoot()

        if dynamic < noiseFloor {
            noiseFloor += (dynamic - noiseFloor) * fallRate
        } else {
            noiseFloor += (min(dynamic, noiseFloor * 3) - noiseFloor) * riseRate
        }
        noiseFloor = max(noiseFloor, minimumFloor)

        return FilteredSample(time: s.time, x: s.x, y: s.y, z: s.z,
                              dynamic: Float(dynamic), floor: Float(noiseFloor))
    }
}
