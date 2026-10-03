import AVFoundation
import SwitchcraftCore

enum SampleBankError: Error, LocalizedError {
    case unreadable(String, String)
    case nothingDecoded(String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(file, reason): return "Couldn't decode \(file): \(reason)"
        case let .nothingDecoded(pack): return "No sample in \"\(pack)\" could be decoded."
        }
    }
}

/// A sound pack decoded to Float32 PCM at the engine's internal rate, held in RAM.
/// Mono files stay mono (panned by key position); stereo files keep their image.
/// Built off the main thread when a pack is selected; the keypress path only indexes into it.
final class SampleBank: @unchecked Sendable {
    struct Buffer: @unchecked Sendable {
        let left: UnsafeMutablePointer<Float>
        /// Same pointer as `left` for mono samples.
        let right: UnsafeMutablePointer<Float>
        let length: Int
        var isStereo: Bool { left != right }
    }

    let packID: String
    let packName: String
    let gain: Float
    /// Scales key-ups so they sit at least `releaseHeadroomDb` under the presses, whatever the
    /// recording's own balance (some packs recorded upstrokes almost as loud as downstrokes).
    let releaseTrim: Float
    static let releaseHeadroomDb: Float = 9
    let memoryBytes: Int
    /// `[KeyGroup.index][VelocityLayer.index]`, fallbacks already resolved.
    private let table: [[[Buffer]]]
    /// Key-up recordings per `KeyGroup.index`, fallbacks resolved; empty when the pack has none.
    private let releaseTable: [[Buffer]]
    private let owned: [Buffer]

    /// Longest sample kept; keyboard sounds are far shorter.
    static let maxSeconds = 2.0

    private init(pack: SoundPack, table: [[[Buffer]]], releaseTable: [[Buffer]], owned: [Buffer]) {
        packID = pack.id
        packName = pack.name
        gain = Float(pack.gain)
        self.table = table
        self.releaseTable = releaseTable
        self.owned = owned
        releaseTrim = Self.releaseTrim(presses: table[KeyGroup.alpha.index][VelocityLayer.hard.index],
                                       releases: releaseTable[KeyGroup.alpha.index])
        memoryBytes = owned.reduce(0) { $0 + $1.length * MemoryLayout<Float>.size * ($1.isStereo ? 2 : 1) }
    }

    deinit {
        for buffer in owned {
            buffer.left.deallocate()
            if buffer.isStereo { buffer.right.deallocate() }
        }
    }

    func buffers(_ group: KeyGroup, _ layer: VelocityLayer) -> [Buffer] { table[group.index][layer.index] }

    static func releaseTrim(presses: [Buffer], releases: [Buffer]) -> Float {
        func meanPeak(_ buffers: [Buffer]) -> Float {
            guard !buffers.isEmpty else { return 0 }
            return buffers.reduce(Float(0)) { sum, b in
                var peak: Float = 0
                for i in 0..<b.length { peak = max(peak, abs(b.left[i]), abs(b.right[i])) }
                return sum + peak
            } / Float(buffers.count)
        }
        let press = meanPeak(presses), release = meanPeak(releases)
        guard press > 0, release > 0 else { return 1 }
        let target = press * pow(10, -releaseHeadroomDb / 20)
        return min(1, target / release)
    }
    func releaseBuffers(_ group: KeyGroup) -> [Buffer] { releaseTable[group.index] }

    static func load(pack: SoundPack, sampleRate: Double) throws -> SampleBank {
        var raw: [URL: [[Float]]] = [:]
        var built: [String: Buffer] = [:]
        var owned: [Buffer] = []

        /// Decodes each file once; derived layers are built once per (file, layer).
        func buffers(for urls: [URL], layer: VelocityLayer?) -> [Buffer] {
            urls.compactMap { url in
                let key = url.path + "#" + (layer?.rawValue ?? "")
                if let buffer = built[key] { return buffer }
                do {
                    if raw[url] == nil { raw[url] = try decode(url, sampleRate: sampleRate) }
                    guard var channels = raw[url] else { return nil }
                    if let layer, pack.derivesLayers {
                        channels = channels.map { LayerDerivation.derive($0, sampleRate: sampleRate, layer: layer) }
                    }
                    let buffer = makeBuffer(channels)
                    built[key] = buffer
                    owned.append(buffer)
                    return buffer
                } catch {
                    Log.soundpack.error("\(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
        }

        var table = Array(repeating: Array(repeating: [Buffer](), count: VelocityLayer.count), count: KeyGroup.count)
        var releaseTable = Array(repeating: [Buffer](), count: KeyGroup.count)
        for group in KeyGroup.allCases {
            for layer in VelocityLayer.allCases {
                // Recorded layers are used as-is; only derived packs need a per-layer key.
                table[group.index][layer.index] = buffers(for: pack.resolve(group: group, layer: layer),
                                                          layer: pack.derivesLayers ? layer : nil)
            }
            releaseTable[group.index] = buffers(for: pack.resolveRelease(group: group), layer: nil)
        }
        guard !owned.isEmpty else { throw SampleBankError.nothingDecoded(pack.name) }
        let bank = SampleBank(pack: pack, table: table, releaseTable: releaseTable, owned: owned)
        Log.soundpack.info("Loaded \(pack.name, privacy: .public): \(owned.count) buffers, \(bank.memoryBytes / 1024) KB, key-up trim \(20 * log10(bank.releaseTrim), format: .fixed(precision: 1)) dB")
        return bank
    }

    private static func makeBuffer(_ channels: [[Float]]) -> Buffer {
        let length = channels.map(\.count).min() ?? 0
        func copy(_ samples: [Float]) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(length, 1))
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { pointer.update(from: base, count: length) }
            }
            return pointer
        }
        let left = copy(channels[0])
        let right = channels.count > 1 ? copy(channels[1]) : left
        return Buffer(left: left, right: right, length: length)
    }

    /// Any supported file → Float32 at `sampleRate`, one or two channels (more are downmixed to
    /// stereo), with a short fade-out so truncated files never click.
    static func decode(_ url: URL, sampleRate: Double) throws -> [[Float]] {
        let name = url.lastPathComponent
        do {
            let file = try AVAudioFile(forReading: url)
            let inFormat = file.processingFormat
            let channels = AVAudioChannelCount(min(inFormat.channelCount, 2))
            let frames = AVAudioFrameCount(min(file.length, AVAudioFramePosition(inFormat.sampleRate * maxSeconds)))
            guard frames > 1,
                  let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames),
                  let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                channels: channels, interleaved: false),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw SampleBankError.unreadable(name, "unsupported or empty audio")
            }
            try file.read(into: input, frameCount: frames)
            converter.downmix = true
            let capacity = AVAudioFrameCount(Double(frames) * sampleRate / inFormat.sampleRate) + 256
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
                throw SampleBankError.unreadable(name, "out of memory")
            }
            let fed = Locked(false)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if fed.get() {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                fed.set(true)
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, let data = output.floatChannelData, output.frameLength > 1 else {
                throw SampleBankError.unreadable(name, conversionError?.localizedDescription ?? "conversion failed")
            }
            let length = Int(output.frameLength)
            let fade = min(64, length)
            return (0..<Int(channels)).map { c in
                var samples = Array(UnsafeBufferPointer(start: data[c], count: length))
                for i in 0..<fade { samples[length - fade + i] *= Float(fade - i) / Float(fade) }
                return samples
            }
        } catch let error as SampleBankError {
            throw error
        } catch {
            throw SampleBankError.unreadable(name, error.localizedDescription)
        }
    }
}
