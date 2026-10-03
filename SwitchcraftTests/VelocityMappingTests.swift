import Foundation
import Testing
@testable import SwitchcraftCore

struct VelocityMappingTests {
    let mapper = VelocityMapper()

    @Test func calibrationAnchorsLandOnTargets() {
        let c = Calibration.factoryDefault
        #expect(abs(mapper.normalized(c.soft) - VelocityMapper.softTarget) < 1e-9)
        #expect(abs(mapper.normalized(c.normal) - VelocityMapper.normalTarget) < 1e-9)
        #expect(abs(mapper.normalized(c.hard) - VelocityMapper.hardTarget) < 1e-9)
        #expect(mapper.normalized(c.hard * VelocityMapper.slamRatio) == 1)
        #expect(mapper.normalized(c.noiseFloor) == 0)
    }

    @Test func mappingIsMonotonicAndContinuous() {
        var previous = -1.0
        var magnitude = 0.0001
        while magnitude < 0.3 {
            let v = mapper.velocity(forImpact: magnitude)
            #expect(v >= previous)
            if previous >= 0 { #expect(v - previous < 0.05, "jump at \(magnitude)") }
            previous = v
            magnitude *= 1.05
        }
    }

    @Test func outputStaysWithinMinAndMax() {
        var curve = VelocityCurve()
        curve.minVelocity = 0.2
        curve.maxVelocity = 0.8
        let m = VelocityMapper(curve: curve)
        #expect(abs(m.velocity(forImpact: 0) - 0.2) < 1e-9)
        #expect(abs(m.velocity(forImpact: 10) - 0.8) < 1e-9)
    }

    @Test func sensitivityMakesTheSamePressLouder() {
        var soft = VelocityCurve()
        soft.sensitivity = 0
        var aggressive = VelocityCurve()
        aggressive.sensitivity = 1
        let impact = Calibration.factoryDefault.normal
        let low = VelocityMapper(curve: soft).velocity(forImpact: impact)
        let mid = mapper.velocity(forImpact: impact)
        let high = VelocityMapper(curve: aggressive).velocity(forImpact: impact)
        #expect(low < mid && mid < high)
    }

    @Test func gammaBelowOneLiftsSoftPresses() {
        var curve = VelocityCurve()
        curve.gamma = 0.5
        let impact = Calibration.factoryDefault.soft
        #expect(VelocityMapper(curve: curve).velocity(forImpact: impact) > mapper.velocity(forImpact: impact))
    }

    @Test func tiers() {
        #expect(VelocityMapper.layer(for: 0.1) == .soft)
        #expect(VelocityMapper.layer(for: 0.3) == .medium)
        #expect(VelocityMapper.layer(for: 0.6) == .hard)
        #expect(VelocityMapper.layer(for: 0.9) == .slam)
        #expect(VelocityMapper.layer(for: 1.0) == .slam)
        #expect(VelocityMapper.layer(for: -1) == .soft)
    }

    @Test func blendGainsSumToOneAndMoveContinuously() {
        var previousPosition = -1.0
        for step in 0...400 {
            let v = Double(step) / 400
            let blend = LayerBlend(velocity: v)
            // Layers are the same hit at different intensities (correlated): linear gains, no +3 dB bulge.
            #expect(abs(blend.lowerGain + blend.upperGain - 1) < 1e-5)
            #expect(blend.upper.index == blend.lower.index + 1)
            // Weighted layer position never moves backwards and never jumps as velocity rises.
            let position = Double(blend.lower.index) + Double(blend.upperGain)
            #expect(position >= previousPosition - 1e-9)
            if previousPosition >= 0 { #expect(position - previousPosition < 0.02) }
            previousPosition = position
        }
    }

    @Test func blendAt037MixesNeighbouringLayers() {
        let blend = LayerBlend(velocity: 0.37)
        #expect(blend.lower == .soft && blend.upper == .medium)
        #expect(blend.upperGain > blend.lowerGain)
        #expect(blend.lowerGain > 0)
        // Exactly at the hard layer's centre: hard plays alone.
        let centre = LayerBlend(velocity: 0.625)
        #expect(centre.lower == .hard && centre.lowerGain > 0.999 && centre.upperGain < 0.001)
    }
}

struct CalibrationTests {
    @Test func fitsMedians() throws {
        let c = try Calibration.fit(noiseFloor: 0.0005,
                                    soft: [0.004, 0.005, 0.006, 0.05],
                                    normal: [0.010, 0.012, 0.011],
                                    hard: [0.03, 0.025, 0.028, 0.001])
        #expect(abs(c.soft - 0.0055) < 1e-9)
        #expect(abs(c.normal - 0.011) < 1e-9)
        #expect(abs(c.hard - 0.0265) < 1e-9)
        #expect(c.isUserCalibrated)
        #expect(c.soft < c.normal && c.normal < c.hard)
    }

    @Test func enforcesIncreasingAnchors() throws {
        let c = try Calibration.fit(noiseFloor: 0.0005, soft: [0.01, 0.01, 0.01], normal: [0.005, 0.005, 0.005], hard: [0.02, 0.02, 0.02])
        #expect(c.soft < c.normal && c.normal < c.hard)
    }

    @Test func requiresEnoughPresses() {
        #expect(throws: Calibration.FitError.notEnoughSamples(.medium, got: 1, need: 3)) {
            try Calibration.fit(noiseFloor: 0.0005, soft: [0.01, 0.01, 0.01], normal: [0.01], hard: [0.02, 0.02, 0.02])
        }
    }

    @Test func rejectsHardSofterThanSoft() {
        #expect(throws: Calibration.FitError.notSeparated) {
            try Calibration.fit(noiseFloor: 0.0005, soft: [0.02, 0.02, 0.02], normal: [0.01, 0.01, 0.01], hard: [0.01, 0.01, 0.01])
        }
    }

    @Test func calibrationChangesTheMapping() throws {
        // A light typist: their "hard" is the factory "normal".
        let light = try Calibration.fit(noiseFloor: 0.0006, soft: [0.003, 0.003, 0.003], normal: [0.006, 0.006, 0.006], hard: [0.012, 0.012, 0.012])
        let impact = 0.012
        #expect(VelocityMapper(calibration: light).velocity(forImpact: impact) > VelocityMapper().velocity(forImpact: impact))
    }
}
