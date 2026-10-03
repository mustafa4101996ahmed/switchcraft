import Foundation

/// "Room ambience" without echo: a handful of short, damped stereo reflections, all within 15 ms
/// of the click. Reflections that close fuse with the direct sound (precedence effect) and read as
/// desk-and-room space; a reverb's reflections at 30–60 ms are heard as a separate slap-back.
///
/// Realtime-safe: buffers are preallocated, `process` never allocates or locks.
public final class EarlyReflections: @unchecked Sendable {
    /// Tap delays (ms) and gains per side, chosen with no common multiples so they don't ring.
    static let leftTaps: [(ms: Double, gain: Float)] = [(2.3, 0.42), (5.9, 0.30), (9.7, 0.21), (14.1, 0.13)]
    static let rightTaps: [(ms: Double, gain: Float)] = [(3.1, 0.40), (7.3, 0.28), (11.3, 0.19), (13.4, 0.12)]
    /// Longest possible echo: anything later would be heard as a separate repeat.
    public static let maxDelayMs = 15.0

    private let size: Int
    private let historyL: UnsafeMutablePointer<Float>
    private let historyR: UnsafeMutablePointer<Float>
    private var write = 0
    private let tapsL: [(offset: Int, gain: Float)]
    private let tapsR: [(offset: Int, gain: Float)]
    /// One-pole low-pass on the reflections: surfaces absorb the high-frequency click.
    private var lowL: Float = 0
    private var lowR: Float = 0
    private let damping: Float

    public init(sampleRate: Double) {
        size = Int((Self.maxDelayMs / 1000 * sampleRate).rounded(.up)) + 2
        historyL = .allocate(capacity: size)
        historyR = .allocate(capacity: size)
        historyL.initialize(repeating: 0, count: size)
        historyR.initialize(repeating: 0, count: size)
        tapsL = Self.leftTaps.map { (Int($0.ms / 1000 * sampleRate), $0.gain) }
        tapsR = Self.rightTaps.map { (Int($0.ms / 1000 * sampleRate), $0.gain) }
        damping = Float(exp(-2 * Double.pi * 4500 / sampleRate))
    }

    deinit {
        historyL.deallocate()
        historyR.deallocate()
    }

    /// Adds reflections in place. `amount` 0…1; at 0 the signal passes through untouched.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, amount: Float) {
        let wet = min(max(amount, 0), 1) * 0.55
        for i in 0..<frames {
            let dryL = left[i], dryR = right[i]
            historyL[write] = dryL
            historyR[write] = dryR
            if wet > 0 {
                // Cross-feed: the left ear hears reflections of both channels, so the space is stereo.
                var reflL: Float = 0, reflR: Float = 0
                for tap in tapsL {
                    let j = (write - tap.offset + size) % size
                    reflL += (historyL[j] * 0.7 + historyR[j] * 0.3) * tap.gain
                }
                for tap in tapsR {
                    let j = (write - tap.offset + size) % size
                    reflR += (historyR[j] * 0.7 + historyL[j] * 0.3) * tap.gain
                }
                lowL += (1 - damping) * (reflL - lowL)
                lowR += (1 - damping) * (reflR - lowR)
                left[i] = dryL + lowL * wet
                right[i] = dryR + lowR * wet
            }
            write = (write + 1) % size
        }
    }

    /// Clears the history (e.g. when every voice is stopped for a pack switch).
    public func reset() {
        historyL.update(repeating: 0, count: size)
        historyR.update(repeating: 0, count: size)
        lowL = 0
        lowR = 0
    }
}
