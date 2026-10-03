import Foundation
import Testing
@testable import SwitchcraftCore

// MARK: - Mocks for the hardware boundaries

final class MockAccelerometer: AccelerometerService, @unchecked Sendable {
    let ring = SampleRing(capacity: 8192)
    var state: SensorState
    var measuredSampleRate: Double { 800 }
    private(set) var started = false

    init(state: SensorState = .supported, events: [SyntheticSignals.Event] = [], duration: Double = 2) {
        self.state = state
        for s in SyntheticSignals.filter(SyntheticSignals.generate(duration: duration, events: events)) { ring.append(s) }
    }

    func start() { started = true }
    func stop() { started = false }
}

final class MockKeyboard: KeyEventSource, @unchecked Sendable {
    var onKeyEvent: (@Sendable (KeyEvent) -> Void)?
    var isRunning = false
    func start() throws { isRunning = true }
    func stop() { isRunning = false }
    func press(_ code: UInt16, at time: Double, isRepeat: Bool = false) {
        onKeyEvent?(KeyEvent(time: time, receivedAt: time + 0.0002, keyCode: code, isRepeat: isRepeat))
    }
    func release(_ code: UInt16, at time: Double) {
        onKeyEvent?(KeyEvent(time: time, receivedAt: time + 0.0002, keyCode: code, isRepeat: false, isRelease: true))
    }
}

final class MockSoundOutput: SoundOutput, @unchecked Sendable {
    struct Play: Equatable { var group: KeyGroup; var velocity: Double; var keyTime: Double }
    private let plays = Locked<[Play]>([])
    private let releasePlays = Locked<[Play]>([])
    var played: [Play] { plays.get() }
    var released: [Play] { releasePlays.get() }
    func play(group: KeyGroup, keyCode: UInt16, velocity: Double, keyTime: Double) {
        plays.mutate { $0.append(Play(group: group, velocity: velocity, keyTime: keyTime)) }
    }
    func playRelease(group: KeyGroup, keyCode: UInt16, velocity: Double, keyTime: Double) {
        releasePlays.mutate { $0.append(Play(group: group, velocity: velocity, keyTime: keyTime)) }
    }
}

// MARK: - Pipeline / correlation tests

struct PipelineTests {
    /// A clock far in the future: the sensor ring already covers every window, so nothing waits.
    static let lateClock: @Sendable () -> Double = { 1e9 }

    func makePipeline(sensor: MockAccelerometer?, config: (inout PipelineConfig) -> Void = { _ in }) -> (TypingPipeline, MockKeyboard, MockSoundOutput) {
        let output = MockSoundOutput()
        let pipeline = TypingPipeline(output: output, clock: Self.lateClock)
        var c = PipelineConfig()
        config(&c)
        pipeline.setConfig(c)
        pipeline.setSensor(sensor)
        let keyboard = MockKeyboard()
        pipeline.attach(to: keyboard)
        return (pipeline, keyboard, output)
    }

    @Test func harderKeypressPlaysLouderVelocity() {
        let sensor = MockAccelerometer(events: [.keypress(at: 100.5, strength: 0.006), .keypress(at: 101.0, strength: 0.03)])
        let (pipeline, keyboard, output) = makePipeline(sensor: sensor)
        keyboard.press(0, at: 100.5)
        keyboard.press(49, at: 101.0)
        pipeline.waitUntilIdle()
        #expect(output.played.count == 2)
        #expect(output.played[0].group == .alpha && output.played[1].group == .space)
        #expect(output.played[1].velocity > output.played[0].velocity + 0.3)
        #expect(output.played[0].keyTime == 100.5)
        let stats = pipeline.stats.snapshot(now: 101.1)
        #expect(stats.lastVelocitySource == "accelerometer")
        #expect(stats.offsetMedianMs.map { $0 > 2 && $0 < 9 } == true)
    }

    @Test func repeatsAreSilentUnlessEnabled() {
        let sensor = MockAccelerometer(events: [.keypress(at: 100.5, strength: 0.01)])
        let (silent, keyboard, output) = makePipeline(sensor: sensor)
        keyboard.press(0, at: 100.5)
        keyboard.press(0, at: 100.6, isRepeat: true)
        silent.waitUntilIdle()
        #expect(output.played.count == 1)

        let (loud, keyboard2, output2) = makePipeline(sensor: sensor) { $0.playRepeats = true }
        keyboard2.press(0, at: 100.6, isRepeat: true)
        loud.waitUntilIdle()
        #expect(output2.played.count == 1)
    }

    @Test func releaseFollowsItsPressVelocity() {
        let sensor = MockAccelerometer(events: [.keypress(at: 100.5, strength: 0.03)])
        let (pipeline, keyboard, output) = makePipeline(sensor: sensor)
        keyboard.press(49, at: 100.5)
        keyboard.press(49, at: 100.6, isRepeat: true) // held: repeat stays silent
        keyboard.release(49, at: 100.7)
        keyboard.release(49, at: 100.8) // stray second release: nothing to pair with
        keyboard.release(0, at: 100.9) // release without a press (pressed before launch)
        pipeline.waitUntilIdle()
        #expect(output.played.count == 1)
        #expect(output.released.count == 1)
        #expect(output.released.first?.group == .space)
        #expect(output.released.first?.velocity == output.played.first?.velocity)
        #expect(pipeline.stats.snapshot(now: 101).totalKeys == 2) // presses only (incl. the repeat)
    }

    @Test func releasesCanBeTurnedOffAndRespectMutes() {
        let (pipeline, keyboard, output) = makePipeline(sensor: nil) { $0.mode = .fixed; $0.playReleases = false }
        keyboard.press(0, at: 1)
        keyboard.release(0, at: 1.1)
        pipeline.waitUntilIdle()
        #expect(output.played.count == 1 && output.released.isEmpty)

        var config = pipeline.currentConfig
        config.playReleases = true
        config.excludedBundleIDs = ["muted.app"]
        pipeline.setConfig(config)
        keyboard.press(0, at: 2)
        pipeline.waitUntilIdle()
        pipeline.updateContext { $0.frontmostBundleID = "muted.app" } // switched apps mid-press
        keyboard.release(0, at: 2.1)
        pipeline.waitUntilIdle()
        #expect(output.played.count == 2 && output.released.isEmpty)
    }

    @Test func excludedAppAndMicrophoneMute() {
        let (pipeline, keyboard, output) = makePipeline(sensor: nil) {
            $0.mode = .fixed
            $0.excludedBundleIDs = ["us.zoom.xos"]
            $0.muteWhenMicActive = true
        }
        pipeline.updateContext { $0.frontmostBundleID = "us.zoom.xos" }
        keyboard.press(0, at: 1)
        pipeline.waitUntilIdle()
        #expect(output.played.isEmpty)

        pipeline.updateContext { $0 = PipelineContext(frontmostBundleID: "com.apple.TextEdit", microphoneInUse: true) }
        keyboard.press(0, at: 2)
        pipeline.waitUntilIdle()
        #expect(output.played.isEmpty)

        pipeline.updateContext { $0.microphoneInUse = false }
        keyboard.press(0, at: 3)
        pipeline.waitUntilIdle()
        #expect(output.played.count == 1)
        #expect(pipeline.stats.snapshot(now: 3).mutedEvents == 2)
    }

    @Test func fixedModeIgnoresTheSensor() {
        let sensor = MockAccelerometer(events: [.keypress(at: 100.5, strength: 0.05)])
        let (pipeline, keyboard, output) = makePipeline(sensor: sensor) {
            $0.mode = .fixed
            $0.fixedVelocity = 0.33
        }
        keyboard.press(0, at: 100.5)
        pipeline.waitUntilIdle()
        #expect(output.played.map(\.velocity) == [0.33])
    }

    @Test func unsupportedSensorFallsBackToFixedVelocity() {
        let (pipeline, keyboard, output) = makePipeline(sensor: MockAccelerometer(state: .unsupported)) { $0.fixedVelocity = 0.42 }
        keyboard.press(0, at: 100.5)
        pipeline.waitUntilIdle()
        #expect(output.played.map(\.velocity) == [0.42])
        let stats = pipeline.stats.snapshot(now: 100.5)
        #expect(stats.lastVelocitySource.contains("sensor unavailable"))
        #expect(stats.fallbackEvents == 1)
    }

    @Test func deskBumpUsesRecentAverageInsteadOfSlam() {
        let sensor = MockAccelerometer(events: [.keypress(at: 100.4, strength: 0.012), .deskBump(at: 101.0, strength: 0.6)])
        let (pipeline, keyboard, output) = makePipeline(sensor: sensor)
        keyboard.press(0, at: 100.4)
        keyboard.press(0, at: 101.0)
        pipeline.waitUntilIdle()
        #expect(output.played.count == 2)
        #expect(output.played[1].velocity < 0.75)
        #expect(pipeline.stats.snapshot(now: 101).lastMeasurement?.outcome == .rejectedTooLarge)
    }

    @Test func disabledPlaysNothingButCalibrationStillMeasures() {
        let sensor = MockAccelerometer(events: [.keypress(at: 100.5, strength: 0.02)])
        let (pipeline, keyboard, output) = makePipeline(sensor: sensor) { $0.enabled = false; $0.mode = .fixed }
        let captured = Locked<[ImpactMeasurement]>([])
        pipeline.setCalibrationSink { m in captured.mutate { $0.append(m) } }
        keyboard.press(0, at: 100.5)
        pipeline.waitUntilIdle()
        #expect(output.played.isEmpty)
        #expect(captured.get().count == 1)
        #expect(captured.get().first?.outcome == .detected)
    }

    @Test func simulatedSourcesStayInRange() {
        let (random, keyboard, output) = makePipeline(sensor: nil) {
            $0.mode = .simulated
            $0.simulationSource = .randomRange
            $0.randomMin = 0.3
            $0.randomMax = 0.6
        }
        for i in 0..<50 {
            keyboard.press(0, at: Double(i))
            if i % 10 == 9 { random.waitUntilIdle() } // stay under the 32-event backlog limit
        }
        random.waitUntilIdle()
        #expect(output.played.count == 50)
        #expect(output.played.allSatisfy { (0.3...0.6).contains($0.velocity) })
        #expect(Set(output.played.map(\.velocity)).count > 10)

        let (synthetic, keyboard2, output2) = makePipeline(sensor: nil) {
            $0.mode = .simulated
            $0.simulationSource = .syntheticSignal
        }
        for i in 0..<20 {
            keyboard2.press(0, at: Double(i))
            if i % 10 == 9 { synthetic.waitUntilIdle() }
        }
        synthetic.waitUntilIdle()
        let velocities = output2.played.map(\.velocity)
        #expect(velocities.count == 20 && velocities.allSatisfy { (0...1).contains($0) })
        #expect((velocities.max() ?? 0) - (velocities.min() ?? 0) > 0.3)
    }

    @Test func backlogBeyondLimitIsDroppedNotDelayed() {
        let (pipeline, keyboard, output) = makePipeline(sensor: MockAccelerometer(duration: 0.1)) { $0.mode = .accelerometer }
        // The ring ends before these keys, so each one waits for the sensor: the queue backs up.
        let now = MonotonicClock.now()
        for i in 0..<60 { keyboard.press(0, at: now + Double(i) * 1e-4) }
        pipeline.waitUntilIdle()
        let stats = pipeline.stats.snapshot(now: now)
        #expect(stats.droppedEvents > 0)
        #expect(output.played.count + stats.droppedEvents == 60)
    }

    @Test func stalledSensorWaitIsBounded() {
        // Ring ends at ~100.5 s but the key is "now": the pipeline must give up after window + 6 ms.
        let sensor = MockAccelerometer(duration: 0.5)
        let output = MockSoundOutput()
        let pipeline = TypingPipeline(output: output)
        pipeline.setSensor(sensor)
        let now = MonotonicClock.now()
        let started = Date()
        pipeline.handle(KeyEvent(time: now, receivedAt: now, keyCode: 0, isRepeat: false))
        pipeline.waitUntilIdle()
        #expect(Date().timeIntervalSince(started) < 0.1)
        #expect(output.played.count == 1)
        #expect(pipeline.stats.snapshot(now: now).lastMeasurement?.outcome == .noData)
    }

    @Test func ringWindowCopyIsInclusiveAndOrdered() {
        let ring = SampleRing(capacity: 64)
        for i in 0..<100 { ring.append(FilteredSample(time: Double(i), x: 0, y: 0, z: 0, dynamic: Float(i), floor: 0)) }
        var out: [FilteredSample] = []
        ring.copy(from: 90, to: 95, into: &out)
        #expect(out.map(\.time) == [90, 91, 92, 93, 94, 95])
        ring.copy(from: 0, to: 1000, into: &out)
        #expect(out.count == 64 && out.first?.time == 36 && out.last?.time == 99)
        ring.copyLatest(3, into: &out)
        #expect(out.map(\.time) == [97, 98, 99])
        #expect(ring.latestTime == 99)
    }
}
