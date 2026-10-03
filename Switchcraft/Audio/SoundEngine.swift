import AVFoundation
import AudioToolbox
import CoreAudio
import SwitchcraftCore

enum SoundEngineError: Error, LocalizedError {
    case format

    var errorDescription: String? { "The audio format couldn't be created." }
}

/// AVAudioEngine host for the `VoiceMixer`. Configuration happens on the main thread;
/// `play` is safe from any thread and never allocates audio buffers or touches disk.
final class SoundEngine: SoundOutput, @unchecked Sendable {
    /// Samples are decoded once at this rate; the engine's mixer converts to the device rate,
    /// so device changes never require re-decoding.
    static let internalSampleRate = 48_000.0
    static let preferredIOFrames: UInt32 = 128

    let mixer = VoiceMixer()
    var onConfigurationChange: (@Sendable () -> Void)?

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?

    private let lock = UnfairLock()
    // Guarded by `lock`.
    private var bank: SampleBank?
    private var randomVariation = true
    private var stereoWidth = 0.6
    private var rng = SplitMix64(seed: 0x5EED)

    private(set) var isRunning = false
    private(set) var lastError: String?

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    func start() throws {
        if sourceNode == nil {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.internalSampleRate, channels: 2) else {
                throw SoundEngineError.format
            }
            let node = AVAudioSourceNode(format: format, renderBlock: Self.makeRenderBlock(mixer: mixer))
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sourceNode = node
            mixer.setSampleRate(Self.internalSampleRate)
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                self?.handleConfigurationChange()
            }
        }
        applyIOBufferSize()
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            lastError = nil
            Log.audio.info("Audio engine started: \(self.outputSampleRate, format: .fixed(precision: 0)) Hz, \(self.ioBufferFrames) frames")
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            Log.audio.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
    }

    func restart() throws {
        engine.stop()
        isRunning = false
        try start()
    }

    /// Built outside any actor so the closure isn't isolated to the main thread.
    private static func makeRenderBlock(mixer: VoiceMixer) -> AVAudioSourceNodeRenderBlock {
        { isSilence, timestamp, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let stamp = timestamp.pointee
            let hostTime = stamp.mFlags.contains(.hostTimeValid)
                ? MonotonicClock.seconds(fromTicks: stamp.mHostTime) : MonotonicClock.now()
            let audible = mixer.render(frames: Int(frameCount), hostTime: hostTime, left: left, right: right)
            isSilence.pointee = ObjCBool(!audible)
            return noErr
        }
    }

    private func handleConfigurationChange() {
        Log.audio.notice("Audio configuration changed (device switch, headphones, Bluetooth); restarting")
        do {
            try restart()
        } catch {
            lastError = error.localizedDescription
        }
        onConfigurationChange?()
    }

    /// Requests a 128-frame IO buffer (~2.7 ms at 48 kHz) for this process's output.
    private func applyIOBufferSize() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var frames = Self.preferredIOFrames
        let status = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                          &frames, UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            Log.audio.notice("Couldn't set IO buffer size (OSStatus \(status)); using the device default")
        }
    }

    // MARK: Configuration (main thread)

    func setBank(_ newBank: SampleBank) {
        let old = lock.withLock { () -> SampleBank? in
            let previous = bank
            bank = newBank
            return previous
        }
        mixer.stopAll()
        // A render cycle may still be reading the old samples; release them a moment later.
        if let old {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withExtendedLifetime(old) {} }
        }
    }

    var currentBank: SampleBank? { lock.withLock { bank } }

    func setVolume(_ volume: Double) {
        // Perceptual taper: the slider's middle sounds like half volume.
        mixer.setMasterGain(Float(pow(min(max(volume, 0), 1), 1.6)))
    }

    func setRandomVariation(_ enabled: Bool) { lock.withLock { randomVariation = enabled } }
    func setStereoWidth(_ width: Double) { lock.withLock { stereoWidth = width } }

    /// Early-reflection level, 0…1 (see `EarlyReflections`). 0 = completely dry.
    func setRoomAmbience(_ amount: Double) { mixer.setAmbience(Float(amount)) }

    // MARK: Diagnostics

    var outputSampleRate: Double { engine.outputNode.outputFormat(forBus: 0).sampleRate }

    var ioBufferFrames: UInt32 {
        guard let unit = engine.outputNode.audioUnit else { return 0 }
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, &size)
        return status == noErr ? frames : 0
    }

    /// Device + stream latency reported by CoreAudio for the output path.
    var presentationLatency: Double { engine.outputNode.presentationLatency }

    // MARK: SoundOutput (any thread)

    func play(group: KeyGroup, keyCode: UInt16, velocity: Double, keyTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let bank else { return }
        let v = min(max(velocity, 0), 1)
        let blend = LayerBlend(velocity: v)
        let (rate, jitter) = variation()
        // Loudness follows velocity; 0.5 leaves headroom for overlapping keys before the limiter.
        let loudness = Float(0.22 + 0.78 * v) * bank.gain * 0.5 * jitter
        let pick = self.pick(keyCode)
        enqueue(bank.buffers(group, blend.lower), gain: loudness * blend.lowerGain, pick: pick, rate: rate, keyCode: keyCode, keyTime: keyTime)
        enqueue(bank.buffers(group, blend.upper), gain: loudness * blend.upperGain, pick: pick, rate: rate, keyCode: keyCode, keyTime: keyTime)
    }

    func playRelease(group: KeyGroup, keyCode: UInt16, velocity: Double, keyTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let bank else { return }
        let (rate, jitter) = variation()
        // Same velocity curve as the press, times the pack's key-up trim: an upstroke is never
        // heard as a second press (that reads as an echo).
        let gain = Float(0.22 + 0.78 * min(max(velocity, 0), 1)) * bank.gain * bank.releaseTrim * 0.5 * jitter
        enqueue(bank.releaseBuffers(group), gain: gain, pick: self.pick(keyCode), rate: rate, keyCode: keyCode, keyTime: 0)
    }

    /// Each physical key keeps its own recording, like a real board (previews use key code 0xFFFF
    /// and get a random one). Call with `lock` held.
    private func pick(_ keyCode: UInt16) -> UInt64 {
        keyCode == Self.previewKeyCode ? rng.next() : (UInt64(keyCode) &* 0x9E37_79B9) >> 7
    }

    static let previewKeyCode: UInt16 = 0xFFFF

    /// ±0.5 % playback rate (subtle: real switches don't change pitch) and ±0.5 dB level.
    /// Call with `lock` held.
    private func variation() -> (rate: Float, gain: Float) {
        guard randomVariation else { return (1, 1) }
        return (1 + Float(rng.unit() - 0.5) * 0.01, 1 + Float(rng.unit() - 0.5) * 0.12)
    }

    /// Call with `lock` held.
    private func enqueue(_ buffers: [SampleBank.Buffer], gain: Float, pick: UInt64, rate: Float,
                         keyCode: UInt16, keyTime: Double) {
        guard gain > LayerBlend.audibleThreshold * 0.5, !buffers.isEmpty else { return }
        let buffer = buffers[Int(pick % UInt64(buffers.count))]
        let pan = buffer.isStereo ? KeyLayout.stereoGains(keyCode: keyCode, width: stereoWidth)
                                  : KeyLayout.monoGains(keyCode: keyCode, width: stereoWidth)
        mixer.enqueue(.init(left: UnsafePointer(buffer.left), right: UnsafePointer(buffer.right), length: buffer.length,
                            rate: rate, gainL: gain * pan.left, gainR: gain * pan.right, keyTime: keyTime))
    }
}
