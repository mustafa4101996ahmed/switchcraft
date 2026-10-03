import Foundation
import Testing
@testable import SwitchcraftCore

/// Velocity layers derived from one hit, and per-key stereo placement.
struct LayerDerivationTests {
    let rate = 48_000.0

    /// A clicky-ish hit: bright transient plus a low body, decaying over 60 ms.
    var hit: [Float] {
        (0..<Int(0.06 * rate)).map { i in
            let t = Double(i) / rate
            return Float(exp(-t / 0.01) * (0.5 * sin(2 * .pi * 4000 * t) + 0.3 * sin(2 * .pi * 150 * t)))
        }
    }

    func rms(_ x: [Float]) -> Double { (x.reduce(0) { $0 + Double($1 * $1) } / Double(x.count)).squareRoot() }
    /// Energy above ~3 kHz via a first difference (a crude high-pass).
    func brightness(_ x: [Float]) -> Double { rms(zip(x.dropFirst(), x).map { $0 - $1 }) }

    @Test func layersKeepLengthAndTiming() {
        for layer in VelocityLayer.allCases {
            #expect(LayerDerivation.derive(hit, sampleRate: rate, layer: layer).count == hit.count)
        }
        #expect(LayerDerivation.derive(hit, sampleRate: rate, layer: .hard) == hit)
    }

    @Test func softerLayersAreQuieterAndDarker() {
        let soft = LayerDerivation.derive(hit, sampleRate: rate, layer: .soft)
        let medium = LayerDerivation.derive(hit, sampleRate: rate, layer: .medium)
        #expect(rms(soft) < rms(medium) && rms(medium) < rms(hit))
        #expect(brightness(soft) / rms(soft) < brightness(medium) / rms(medium))
        #expect(brightness(medium) / rms(medium) < brightness(hit) / rms(hit))
    }

    @Test func slamIsHeavierButNeverClips() {
        let slam = LayerDerivation.derive(hit, sampleRate: rate, layer: .slam)
        #expect(rms(slam) > rms(hit))
        #expect(slam.allSatisfy { abs($0) <= 1 })
        let loud = LayerDerivation.derive(hit.map { $0 * 3 }, sampleRate: rate, layer: .slam)
        #expect(loud.allSatisfy { abs($0) <= 1 })
    }
}

struct KeyLayoutTests {
    @Test func keysSitWhereTheyAreOnTheBoard() {
        let a = KeyLayout.position(of: 0), l = KeyLayout.position(of: 37), space = KeyLayout.position(of: 49)
        #expect(a < 0.35 && l > 0.6 && abs(space - 0.5) < 0.05)
        #expect(KeyLayout.position(of: 53) < 0.1) // escape, far left
        #expect(KeyLayout.position(of: 124) > 0.9) // right arrow, far right
        #expect(KeyLayout.position(of: 999) == 0.5) // unknown → centre
        // Each row runs left to right.
        let qRow: [UInt16] = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35]
        #expect(qRow.map { KeyLayout.position(of: $0) } == qRow.map { KeyLayout.position(of: $0) }.sorted())
    }

    @Test func monoPanIsConstantPowerAndFollowsWidth() {
        for code: UInt16 in [0, 37, 49, 53, 124] {
            let g = KeyLayout.monoGains(keyCode: code, width: 0.8)
            #expect(abs(g.left * g.left + g.right * g.right - 1) < 1e-5)
        }
        let left = KeyLayout.monoGains(keyCode: 0, width: 1)
        #expect(left.left > left.right)
        let centred = KeyLayout.monoGains(keyCode: 0, width: 0)
        #expect(abs(centred.left - centred.right) < 1e-6)
    }

    @Test func stereoBalanceNeverBoostsAndCentreIsUntouched() {
        let space = KeyLayout.stereoGains(keyCode: 49, width: 1)
        #expect(abs(space.left - 1) < 0.1 && abs(space.right - 1) < 0.1)
        let right = KeyLayout.stereoGains(keyCode: 124, width: 1)
        #expect(right.right == 1 && right.left < 0.2)
    }
}

/// "Room ambience" must add space without an audible echo: every reflection inside 15 ms.
struct EarlyReflectionsTests {
    func impulseResponse(amount: Float, frames: Int = 4800) -> (left: [Float], right: [Float]) {
        let fx = EarlyReflections(sampleRate: 48_000)
        var left = [Float](repeating: 0, count: frames), right = left
        left[0] = 1
        right[0] = 1
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // Process in 128-frame blocks, like the render callback.
                var start = 0
                while start < frames {
                    let n = min(128, frames - start)
                    fx.process(left: l.baseAddress! + start, right: r.baseAddress! + start, frames: n, amount: amount)
                    start += n
                }
            }
        }
        return (left, right)
    }

    @Test func zeroAmountIsUntouched() {
        let (l, r) = impulseResponse(amount: 0)
        #expect(l[0] == 1 && r[0] == 1)
        #expect(l.dropFirst().allSatisfy { $0 == 0 } && r.dropFirst().allSatisfy { $0 == 0 })
    }

    @Test func reflectionsStayWithinFifteenMilliseconds() {
        let (l, r) = impulseResponse(amount: 1)
        let limit = Int(EarlyReflections.maxDelayMs / 1000 * 48_000)
        // The one-pole damping leaves a decaying tail; it must be far below any audible echo.
        let lateL = l[(limit + 240)...].map(abs).max() ?? 0 // 5 ms past the last tap
        let lateR = r[(limit + 240)...].map(abs).max() ?? 0
        #expect(lateL < 0.001 && lateR < 0.001, "tail \(lateL) / \(lateR)")
        // The dry click stays on time and dominant: no reflection reaches −6 dB of it.
        #expect(l[0] == 1)
        #expect((l[1...].map(abs).max() ?? 0) < 0.5)
    }

    @Test func spaceIsStereo() {
        let (l, r) = impulseResponse(amount: 1)
        #expect(zip(l, r).dropFirst().contains { abs($0 - $1) > 0.01 })
    }
}
