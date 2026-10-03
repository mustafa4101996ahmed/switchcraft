import Foundation
import Testing
@testable import SwitchcraftCore

/// Runs deterministic synthetic accelerometer fixtures through the production filter + analyzer.
struct ImpactDetectionTests {
    static let soft = 0.006, medium = 0.012, hard = 0.026, slam = 0.06

    /// Filters a whole fixture, then measures each key time like the pipeline would.
    func measure(_ events: [SyntheticSignals.Event], keys: [Double], duration: Double = 2,
                 noise: Double = 0.0004, window: CorrelationWindow = CorrelationWindow(), seed: UInt64 = 1) -> [ImpactMeasurement] {
        let filtered = SyntheticSignals.filter(SyntheticSignals.generate(duration: duration, noise: noise, events: events, seed: seed))
        var analyzer = ImpactAnalyzer(window: window)
        return keys.map { analyzer.measure(keyTime: $0, samples: SyntheticSignals.window(filtered, keyTime: $0, window: window)) }
    }

    @Test func softMediumHardSlamAreOrdered() {
        let strengths = [Self.soft, Self.medium, Self.hard, Self.slam]
        let keys = strengths.indices.map { 100.5 + Double($0) * 0.3 }
        let results = measure(zip(keys, strengths).map { .keypress(at: $0, strength: $1) }, keys: keys)
        #expect(results.allSatisfy { $0.outcome == .detected }, "\(results.map(\.outcome))")
        let magnitudes = results.map(\.magnitude)
        #expect(magnitudes == magnitudes.sorted())
        // Each step is clearly distinguishable, not noise.
        for i in 1..<magnitudes.count { #expect(magnitudes[i] > magnitudes[i - 1] * 1.4) }

        let velocities = magnitudes.map { VelocityMapper().velocity(forImpact: $0) }
        #expect(VelocityMapper.layer(for: velocities[0]) == .soft)
        #expect(VelocityMapper.layer(for: velocities[3]) == .slam)
        #expect(velocities[2] - velocities[0] > 0.3)
    }

    @Test(arguments: [0.004, 0.008, 0.015, 0.03, 0.05])
    func magnitudeTracksStrength(strength: Double) {
        let result = measure([.keypress(at: 100.6, strength: strength)], keys: [100.6])[0]
        #expect(result.outcome == .detected)
        #expect(result.magnitude > strength * 0.4 && result.magnitude < strength * 1.3, "\(result.magnitude) for \(strength)")
    }

    @Test func impactPeakLandsAfterKeyEvent() {
        let result = measure([.keypress(at: 100.7, strength: Self.hard)], keys: [100.7])[0]
        #expect(result.peakOffset > 0.003 && result.peakOffset <= 0.008, "offset \(result.peakOffset)")
    }

    @Test func deskBumpIsRejectedAsTooLarge() {
        let result = measure([.deskBump(at: 100.8, strength: 0.6)], keys: [100.8])[0]
        #expect(result.outcome == .rejectedTooLarge)
    }

    @Test func deskBumpWithoutKeyLeavesNextKeyUnaffected() {
        let alone = measure([.keypress(at: 101.3, strength: Self.medium)], keys: [101.3])[0]
        let afterBump = measure([.deskBump(at: 100.8, strength: 0.6), .keypress(at: 101.3, strength: Self.medium)], keys: [101.3])[0]
        #expect(afterBump.outcome == .detected)
        #expect(abs(afterBump.magnitude - alone.magnitude) < alone.magnitude * 0.25)
    }

    @Test func slowLaptopMovementIsNotAnImpact() {
        let results = measure([.slowMovement(start: 100.2, duration: 1.5, amplitude: 0.2, frequency: 1.5)], keys: [100.6, 100.95, 101.3])
        #expect(results.allSatisfy { $0.outcome == .belowNoise }, "\(results.map { ($0.outcome, $0.peak) })")
    }

    @Test func trackpadClickAloneIsBelowThreshold() {
        let result = measure([.trackpadClick(at: 100.6, strength: 0.002)], keys: [100.6])[0]
        #expect(result.outcome == .belowNoise)
    }

    @Test func trackpadClickBarelyChangesASimultaneousKeypress() {
        let alone = measure([.keypress(at: 100.6, strength: Self.soft)], keys: [100.6])[0]
        let both = measure([.keypress(at: 100.6, strength: Self.soft), .trackpadClick(at: 100.597, strength: 0.002)], keys: [100.6])[0]
        #expect(both.outcome == .detected)
        #expect(abs(both.magnitude - alone.magnitude) < alone.magnitude * 0.4)
    }

    @Test func rapidTypingKeepsEachKeyIndependent() {
        // 12.5 keys/s alternating light and firm presses.
        let keys = (0..<12).map { 100.4 + Double($0) * 0.08 }
        let strengths = keys.indices.map { $0.isMultiple(of: 2) ? 0.008 : 0.03 }
        let results = measure(zip(keys, strengths).map { .keypress(at: $0, strength: $1) }, keys: keys)
        #expect(results.allSatisfy { $0.outcome == .detected })
        for i in stride(from: 0, to: keys.count - 1, by: 2) {
            #expect(results[i + 1].magnitude > results[i].magnitude * 2, "pair \(i)")
        }
    }

    @Test func chordSharesOneImpulse() {
        // Two keys 3 ms apart, one physical impact: both get (about) the full magnitude.
        let results = measure([.keypress(at: 100.6, strength: 0.02)], keys: [100.6, 100.603])
        #expect(results.allSatisfy { $0.outcome == .detected })
        #expect(abs(results[0].magnitude - results[1].magnitude) < results[0].magnitude * 0.2)
    }

    @Test func impulseOutsideTheWindowIsIgnored() {
        let result = measure([.keypress(at: 100.9, strength: Self.hard)], keys: [100.6])[0]
        #expect(result.outcome == .belowNoise)
    }

    @Test func zeroPostWindowStillSeesTheFingerStrike() {
        let window = CorrelationWindow(preMs: 15, postMs: 0)
        let soft = measure([.keypress(at: 100.6, strength: Self.soft)], keys: [100.6], window: window)[0]
        let hard = measure([.keypress(at: 100.6, strength: Self.hard)], keys: [100.6], window: window)[0]
        #expect(soft.outcome == .detected && hard.outcome == .detected)
        #expect(hard.magnitude > soft.magnitude * 2)
    }

    @Test func noDataWhenTheWindowIsEmpty() {
        var analyzer = ImpactAnalyzer()
        #expect(analyzer.measure(keyTime: 5, samples: []).outcome == .noData)
    }

    @Test func backgroundVibrationRaisesTheFloorButHardKeysStillRegister() {
        let filtered = SyntheticSignals.filter(SyntheticSignals.generate(
            duration: 3, events: [.vibration(frequency: 120, amplitude: 0.0025), .keypress(at: 102.5, strength: Self.hard)]))
        let floorLater = Double(filtered[Int(2.3 * 800)].floor)
        #expect(floorLater > ImpactFilter.defaultFloor * 2, "floor rose to \(floorLater)")
        var analyzer = ImpactAnalyzer()
        let result = analyzer.measure(keyTime: 102.5, samples: SyntheticSignals.window(filtered, keyTime: 102.5, window: CorrelationWindow()))
        #expect(result.outcome == .detected)
        #expect(result.magnitude > 0.01)
    }

    @Test func noiseFloorAdaptsDownAndUp() {
        var quiet = ImpactFilter(initialFloor: 0.002, minimumFloor: 0.00001)
        for s in SyntheticSignals.generate(duration: 3, noise: 0.0001, events: []) { _ = quiet.process(s) }
        #expect(quiet.noiseFloor < 0.0004, "quiet floor \(quiet.noiseFloor)")

        var noisy = ImpactFilter(initialFloor: 0.0002, minimumFloor: 0.00001)
        for s in SyntheticSignals.generate(duration: 4, noise: 0.002, events: []) { _ = noisy.process(s) }
        #expect(noisy.noiseFloor > 0.0015 && noisy.noiseFloor < 0.006, "noisy floor \(noisy.noiseFloor)")
    }

    @Test func noiseFloorRespectsUserMinimum() {
        var filter = ImpactFilter(minimumFloor: 0.001)
        for s in SyntheticSignals.generate(duration: 2, noise: 0.00005, events: []) { _ = filter.process(s) }
        #expect(filter.noiseFloor >= 0.001)
    }

    @Test func gravityIsRemovedFromTheFirstSample() {
        let filtered = SyntheticSignals.filter(SyntheticSignals.generate(duration: 0.2, noise: 0, events: []))
        #expect(filtered.allSatisfy { $0.dynamic < 1e-6 })
    }

    @Test func simulatedImpactUsesTheRealPipeline() {
        let soft = SyntheticSignals.simulatedImpact(strength: Self.soft, seed: 3)
        let hard = SyntheticSignals.simulatedImpact(strength: Self.hard, seed: 3)
        #expect(soft.outcome == .detected && hard.outcome == .detected)
        #expect(hard.magnitude > soft.magnitude * 2)
    }

    @Test func fixturesAreDeterministic() {
        let a = SyntheticSignals.generate(duration: 0.5, events: [.keypress(at: 100.2, strength: 0.01)], seed: 9)
        let b = SyntheticSignals.generate(duration: 0.5, events: [.keypress(at: 100.2, strength: 0.01)], seed: 9)
        #expect(a == b)
    }
}
