import Foundation
import SwitchcraftCore

/// Polyphonic sample mixer that runs inside the CoreAudio render callback.
///
/// Realtime rules: voices and the trigger queue are preallocated; the render thread only ever
/// `tryLock`s (if a producer holds the lock, new triggers simply start one buffer later);
/// no allocation, no Objective-C, no I/O.
final class VoiceMixer: @unchecked Sendable {
    struct Trigger {
        var left: UnsafePointer<Float>
        /// Same as `left` for mono samples.
        var right: UnsafePointer<Float>
        var length: Int
        var rate: Float
        var gainL: Float
        var gainR: Float
        /// Key event time (MonotonicClock seconds), 0 for previews.
        var keyTime: Double
    }

    struct Stats: Sendable {
        var activeVoices = 0
        var peakVoices = 0
        var droppedTriggers = 0
        var stolenVoices = 0
        var renderCycles = 0
        var lastKeyToRenderMs: Double?
        var averageKeyToRenderMs: Double?
        var limiterReductionDb: Float = 0
    }

    private struct Voice {
        var data: UnsafePointer<Float>?
        var right: UnsafePointer<Float>?
        var length = 0
        var position: Float = 0
        var rate: Float = 1
        var gainL: Float = 0
        var gainR: Float = 0
    }

    static let maxVoices = 48
    static let queueCapacity = 128
    private static let limiterThreshold: Float = 0.89 // -1 dBFS

    private let lock = UnfairLock()
    // Guarded by `lock`.
    private let queue: UnsafeMutablePointer<Trigger>
    private var queueHead = 0
    private var queueCount = 0
    private var killRequested = false
    private var targetGain: Float = 0.7
    private var targetAmbience: Float = 0
    private var pendingRelease: Float?
    private var published = Stats()

    // Render-thread confined.
    private let voices: UnsafeMutablePointer<Voice>
    private var gain: Float = 0.7
    private var envelope: Float = 0
    private var release: Float = 0.9996
    private var local = Stats()
    private let reflections = EarlyReflections(sampleRate: SoundEngine.internalSampleRate)
    private var ambience: Float = 0
    /// Frames of reflection tail still sounding after the last voice ended.
    private var tailFrames = 0
    private static let tailLength = Int(EarlyReflections.maxDelayMs / 1000 * SoundEngine.internalSampleRate) + 64

    init() {
        queue = .allocate(capacity: Self.queueCapacity)
        voices = .allocate(capacity: Self.maxVoices)
        voices.initialize(repeating: Voice(), count: Self.maxVoices)
    }

    deinit {
        queue.deallocate()
        voices.deinitialize(count: Self.maxVoices)
        voices.deallocate()
    }

    /// Any thread. Returns false (and counts a drop) when the queue is full.
    @discardableResult
    func enqueue(_ trigger: Trigger) -> Bool {
        lock.withLock {
            guard queueCount < Self.queueCapacity else {
                published.droppedTriggers += 1
                return false
            }
            queue[(queueHead + queueCount) % Self.queueCapacity] = trigger
            queueCount += 1
            return true
        }
    }

    /// Silences everything at the next render cycle and discards queued triggers.
    func stopAll() {
        lock.withLock {
            killRequested = true
            queueCount = 0
        }
    }

    func setMasterGain(_ value: Float) { lock.withLock { targetGain = max(0, min(value, 1)) } }
    func setAmbience(_ value: Float) { lock.withLock { targetAmbience = max(0, min(value, 1)) } }

    func setSampleRate(_ rate: Double) {
        // 50 ms limiter release.
        let coefficient = Float(exp(-1 / (0.05 * max(rate, 8000))))
        lock.withLock { pendingRelease = coefficient }
    }

    var stats: Stats { lock.withLock { published } }

    /// Render thread. Writes `frames` samples to each channel; returns false when silent.
    func render(frames: Int, hostTime: Double, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)

        if lock.tryLock() {
            if let r = pendingRelease {
                release = r
                pendingRelease = nil
            }
            if killRequested {
                for i in 0..<Self.maxVoices { voices[i].data = nil }
                reflections.reset()
                tailFrames = 0
                killRequested = false
            }
            gain = targetGain
            ambience = targetAmbience
            while queueCount > 0 {
                startVoice(queue[queueHead], hostTime: hostTime)
                queueHead = (queueHead + 1) % Self.queueCapacity
                queueCount -= 1
            }
            local.renderCycles += 1
            let dropped = published.droppedTriggers
            published = local
            published.droppedTriggers = dropped
            lock.unlock()
        }

        var active = 0
        for v in 0..<Self.maxVoices where voices[v].data != nil {
            mix(&voices[v], frames: frames, left: left, right: right)
            if voices[v].data != nil { active += 1 }
        }
        local.activeVoices = active
        local.peakVoices = max(local.peakVoices, active)
        // Short early reflections (≤ 15 ms) for room depth; they fuse with the click, no echo.
        tailFrames = active > 0 ? Self.tailLength : tailFrames - frames
        if ambience > 0 {
            if tailFrames > 0 {
                reflections.process(left: left, right: right, frames: frames, amount: ambience)
            } else if tailFrames > -frames {
                reflections.reset() // silent: drop stale history so the next click starts clean
            }
        }
        guard active > 0 || tailFrames > 0 || envelope > 0.0001 else { return false }

        // Master gain, then an instant-attack peak limiter so overlapping voices never clip.
        var minGain: Float = 1
        for i in 0..<frames {
            let l = left[i] * gain, r = right[i] * gain
            let peak = max(abs(l), abs(r))
            envelope = peak > envelope ? peak : envelope * release + peak * (1 - release)
            let g = envelope > Self.limiterThreshold ? Self.limiterThreshold / envelope : 1
            minGain = min(minGain, g)
            left[i] = l * g
            right[i] = r * g
        }
        local.limiterReductionDb = minGain < 1 ? 20 * log10(minGain) : 0
        return true
    }

    private func startVoice(_ t: Trigger, hostTime: Double) {
        var slot = -1
        var mostPlayed: Float = -1
        var mostPlayedIndex = 0
        for i in 0..<Self.maxVoices {
            if voices[i].data == nil {
                slot = i
                break
            }
            let progress = voices[i].position / Float(max(voices[i].length, 1))
            if progress > mostPlayed {
                mostPlayed = progress
                mostPlayedIndex = i
            }
        }
        if slot < 0 {
            // Steal the voice furthest into its tail: the quietest-sounding one.
            slot = mostPlayedIndex
            local.stolenVoices += 1
        }
        voices[slot] = Voice(data: t.left, right: t.right, length: t.length, position: 0, rate: t.rate,
                             gainL: t.gainL, gainR: t.gainR)
        if t.keyTime > 0 {
            let ms = (hostTime - t.keyTime) * 1000
            local.lastKeyToRenderMs = ms
            local.averageKeyToRenderMs = local.averageKeyToRenderMs.map { $0 * 0.9 + ms * 0.1 } ?? ms
        }
    }

    /// Linear-interpolated playback (supports the small speed variations). Mono voices read the
    /// same buffer for both channels.
    private func mix(_ voice: inout Voice, frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard let dataL = voice.data else { return }
        let dataR = voice.right ?? dataL
        let last = voice.length - 1
        var position = voice.position
        for i in 0..<frames {
            let index = Int(position)
            if index >= last {
                voice.data = nil
                return
            }
            let fraction = position - Float(index)
            left[i] += (dataL[index] + (dataL[index + 1] - dataL[index]) * fraction) * voice.gainL
            right[i] += (dataR[index] + (dataR[index + 1] - dataR[index]) * fraction) * voice.gainR
            position += voice.rate
        }
        voice.position = position
    }
}
