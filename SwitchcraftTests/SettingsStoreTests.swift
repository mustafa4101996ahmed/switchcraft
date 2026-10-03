import Foundation
import Testing
@testable import SwitchcraftCore

@MainActor
struct SettingsStoreTests {
    func freshDefaults() -> UserDefaults {
        let name = "switchcraft.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsAreSensible() {
        let s = SettingsStore(defaults: freshDefaults())
        #expect(s.isEnabled)
        #expect(!s.playRepeats)
        #expect(s.velocityMode == .accelerometer)
        #expect(s.selectedPackID == SettingsStore.defaultPackID)
        #expect(s.calibration == .factoryDefault)
        #expect(!s.hasCompletedOnboarding)
    }

    @Test func valuesPersistAcrossInstances() {
        let defaults = freshDefaults()
        let a = SettingsStore(defaults: defaults)
        a.isEnabled = false
        a.volume = 0.25
        a.selectedPackID = "deep-thock"
        a.velocityMode = .simulated
        a.simulationSource = .syntheticSignal
        a.curve.sensitivity = 0.9
        a.curve.gamma = 1.7
        a.window = CorrelationWindow(preMs: 20, postMs: 4)
        a.calibration = Calibration(noiseFloor: 0.001, soft: 0.004, normal: 0.009, hard: 0.02, isUserCalibrated: true)
        a.exclusions = [ExcludedApp(bundleID: "us.zoom.xos", name: "Zoom")]
        a.muteWhenMicActive = true
        a.playRepeats = true

        let b = SettingsStore(defaults: defaults)
        #expect(!b.isEnabled)
        #expect(b.volume == 0.25)
        #expect(b.selectedPackID == "deep-thock")
        #expect(b.velocityMode == .simulated)
        #expect(b.simulationSource == .syntheticSignal)
        #expect(b.curve.sensitivity == 0.9 && b.curve.gamma == 1.7)
        #expect(b.window == CorrelationWindow(preMs: 20, postMs: 4))
        #expect(b.calibration == a.calibration)
        #expect(b.exclusions.map(\.bundleID) == ["us.zoom.xos"])
        #expect(b.muteWhenMicActive && b.playRepeats)
    }

    @Test func pipelineConfigReflectsSettings() {
        let s = SettingsStore(defaults: freshDefaults())
        s.exclusions = [ExcludedApp(bundleID: "a", name: "A"), ExcludedApp(bundleID: "b", name: "B")]
        s.impactDecayMs = 20
        s.fixedVelocity = 0.7
        let c = s.pipelineConfig
        #expect(c.excludedBundleIDs == ["a", "b"])
        #expect(abs(c.impactDecay - 0.02) < 1e-12)
        #expect(c.fixedVelocity == 0.7)
        #expect(c.mapper.calibration == s.calibration)
    }

    @Test func corruptValuesFallBackToDefaults() {
        let defaults = freshDefaults()
        defaults.set(Data("garbage".utf8), forKey: "fk.volume")
        defaults.set(Data(#""not-a-mode""#.utf8), forKey: "fk.velocityMode")
        let s = SettingsStore(defaults: defaults)
        #expect(s.volume == 0.7)
        #expect(s.velocityMode == .accelerometer)
    }

    @Test func resetsRestoreDefaultsButKeepSensitivity() {
        let s = SettingsStore(defaults: freshDefaults())
        s.curve = VelocityCurve(sensitivity: 0.8, gain: 3, gamma: 2, minVelocity: 0.3, maxVelocity: 0.6)
        s.window.postMs = 0
        s.calibration.soft = 0.05
        s.resetAdvanced()
        s.resetCalibration()
        #expect(s.curve == VelocityCurve(sensitivity: 0.8))
        #expect(s.window == CorrelationWindow())
        #expect(s.calibration == .factoryDefault)
    }

    @Test func migratesFromThePreviousAppName() {
        let legacy = freshDefaults(), current = freshDefaults()
        let old = SettingsStore(defaults: legacy)
        old.volume = 0.33
        old.selectedPackID = "retro-terminal"
        old.exclusions = [ExcludedApp(bundleID: "us.zoom.xos", name: "Zoom")]
        SettingsStore.migrate(from: legacy, into: current)
        let migrated = SettingsStore(defaults: current)
        #expect(migrated.volume == 0.33)
        #expect(migrated.selectedPackID == "buckling-spring")
        #expect(migrated.exclusions.map(\.bundleID) == ["us.zoom.xos"])

        // Never overwrites settings that already exist.
        migrated.volume = 0.9
        SettingsStore.migrate(from: legacy, into: current)
        #expect(SettingsStore(defaults: current).volume == 0.9)
    }

    @Test func changesNotifyObserver() {
        let s = SettingsStore(defaults: freshDefaults())
        var count = 0
        s.onChange = { count += 1 }
        s.volume = 0.1
        s.isEnabled = false
        #expect(count == 2)
    }
}
