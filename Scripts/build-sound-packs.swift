// Builds the bundled sound packs from openly licensed recordings of real switches.
//
//   Scripts/fetch-sound-sources.sh build/sources          # downloads the three sources below
//   xcrun swiftc -O Scripts/build-sound-packs.swift -o build/build-sound-packs
//   build/build-sound-packs build/sources SoundPacks
//
// Sources (see LICENSES/ and README › Credits):
//   kbsim      tplai/kbsim, MIT © Thomas Lai — one hit per keyboard row + Space/Enter/Backspace, with key-ups
//   mechvibes  hainguyents13/mechvibes, MIT © 2021 Hai Nguyen — every key of Cherry MX Red/Black/Brown/Blue,
//              ABS and PBT keycaps; each key slice holds the press followed by the release
//   freesound  CC0: "Mechanical keyboard clicking. Different keys" by humi74 (Cherry MX Clear, stereo),
//              "Typing Fast_A01" by bonesawmgraw (Cherry MX Silent)
//
// Output packs hold single full-force hits plus key-ups and set "deriveVelocityLayers", so the app
// generates soft/medium/hard/slam from each real hit at load time.

import AVFoundation

typealias Clip = [[Double]] // channels × frames

/// Stem colours shown as swatches in the app.
let stemColors: [String: String] = [
    "cherry-mx-red-abs": "#D9343A", "cherry-mx-red-pbt": "#D9343A", "cherry-mx-black-abs": "#2B2B2E",
    "cherry-mx-black-pbt": "#2B2B2E", "cherry-mx-brown-abs": "#8A5A35", "cherry-mx-brown-pbt": "#8A5A35",
    "cherry-mx-blue-abs": "#2F6FD6", "cherry-mx-blue-pbt": "#2F6FD6", "cherry-mx-clear": "#E6E6E6",
    "cherry-mx-silent": "#7A7F87", "holy-panda": "#F1E9DA", "topre": "#9AA0A6", "box-navy": "#24365F",
    "blue-alps": "#4F7FC0", "alpaca": "#F2A3C1", "nk-cream": "#EFE2C4", "turquoise": "#2AB3A6",
    "red-ink": "#C23B32", "black-ink": "#26262A", "buckling-spring": "#A7A9AC",
]

struct Pack {
    let id: String, name: String, category: String, description: String, credits: String
    var presses: [String: [Clip]] = [:] // group → hits
    var releases: [String: [Clip]] = [:]
    var rate = 44_100.0
}

// MARK: - Audio helpers

func decode(_ url: URL) throws -> (Clip, Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let n = Int(buffer.frameLength)
    let channels = (0..<Int(format.channelCount)).map { c in (0..<n).map { Double(data[c][$0]) } }
    // Effectively dual-mono files (side signal < 2 % of mid) are stored as mono.
    if channels.count == 2 {
        let side = rms(zip(channels[0], channels[1]).map { ($0 - $1) / 2 })
        let mid = rms(zip(channels[0], channels[1]).map { ($0 + $1) / 2 })
        if side < mid * 0.02 { return ([zip(channels[0], channels[1]).map { ($0 + $1) / 2 }], format.sampleRate) }
    }
    return (Array(channels.prefix(2)), format.sampleRate)
}

func mono(_ clip: Clip) -> [Double] {
    clip.count == 1 ? clip[0] : zip(clip[0], clip[1]).map { ($0 + $1) / 2 }
}

func slice(_ clip: Clip, _ range: Range<Int>) -> Clip {
    clip.map { channel in
        let lo = min(max(0, range.lowerBound), channel.count)
        return Array(channel[lo..<max(lo, min(channel.count, range.upperBound))])
    }
}

/// Clips shorter than 2 ms are segmentation leftovers, not sounds.
func usable(_ clip: Clip, rate: Double) -> Bool { (clip.first?.count ?? 0) > Int(0.002 * rate) }

/// 1 ms peak envelope.
func envelope(_ x: [Double], rate: Double) -> [Double] {
    let hop = max(1, Int(rate / 1000))
    return stride(from: 0, to: x.count, by: hop).map { i in x[i..<min(x.count, i + hop)].map(abs).max() ?? 0 }
}

/// Regions (in ms) where the envelope exceeds `threshold`, merging gaps shorter than `mergeMs`.
func events(_ env: [Double], threshold: Double, mergeMs: Int) -> [(start: Int, end: Int, peak: Double)] {
    var out: [(Int, Int, Double)] = []
    var i = 0
    while i < env.count {
        guard env[i] > threshold else { i += 1; continue }
        var end = i
        var quiet = 0
        var j = i
        while j < env.count && quiet <= mergeMs {
            if env[j] > threshold { end = j; quiet = 0 } else { quiet += 1 }
            j += 1
        }
        out.append((i, end, env[i...end].max() ?? 0))
        i = end + mergeMs + 1
    }
    return out
}

/// Starts 0.5 ms before the transient and ends once the tail is 50 dB down, with a 3 ms fade.
func trim(_ clip: Clip, rate: Double) -> Clip {
    let m = mono(clip)
    let peak = m.map(abs).max() ?? 0
    guard peak > 0, let onset = m.firstIndex(where: { abs($0) > peak * 0.03 }),
          let last = m.lastIndex(where: { abs($0) > peak * 0.003 }) else { return clip }
    var out = endAtFirstSilence(slice(clip, max(0, onset - Int(0.0005 * rate))..<min(m.count, last + Int(0.005 * rate))), rate: rate)
    let fade = min(Int(0.003 * rate), out[0].count)
    for c in out.indices {
        for i in 0..<fade { out[c][out[c].count - fade + i] *= Double(fade - i) / Double(fade) }
    }
    return out
}

/// Ends a hit at its first 10 ms of near-silence (< 4 % of its peak) after the attack, keeping 4 ms
/// of natural decay. Removes echo-like blips some source recordings carry ~50 ms after the hit,
/// while a clicky switch's click → bottom-out (7–14 ms apart) stays intact.
func endAtFirstSilence(_ clip: Clip, rate: Double) -> Clip {
    let env = envelope(mono(clip), rate: rate)
    guard let peak = env.max(), peak > 0, let top = env.firstIndex(of: peak) else { return clip }
    var run = 0
    for i in top..<env.count {
        run = env[i] < peak * 0.04 ? run + 1 : 0
        if run >= 10 {
            let end = min(clip[0].count, (i - 9 + 4) * max(1, Int(rate / 1000)))
            var out = slice(clip, 0..<end)
            let fade = min(Int(0.003 * rate), out[0].count)
            for c in out.indices {
                for k in 0..<fade { out[c][out[c].count - fade + k] *= Double(fade - k) / Double(fade) }
            }
            return out
        }
    }
    return clip
}

func rms(_ x: [Double]) -> Double { (x.reduce(0) { $0 + $1 * $1 } / Double(max(x.count, 1))).squareRoot() }

func wav(_ clip: Clip, rate: Double, gain: Double) -> Data {
    var data = Data()
    func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let channels = clip.count, frames = clip[0].count, bytes = frames * channels * 2
    data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(channels))
    put(UInt32(rate)); put(UInt32(rate) * UInt32(channels * 2)); put(UInt16(channels * 2)); put(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
    for i in 0..<frames {
        for c in 0..<channels { put(Int16((max(-1, min(1, clip[c][i] * gain)) * 32767).rounded())) }
    }
    return data
}

// MARK: - kbsim

let kbsimPacks: [(String, String, String, String, String)] = [
    ("holy-panda", "Holy Panda", "Tactile", "Holy Panda tactile switches: sharp, pronounced bump.", "holypanda"),
    ("topre", "Topre", "Electro-capacitive", "Topre rubber-dome-and-spring switches.", "topre"),
    ("box-navy", "Kailh Box Navy", "Clicky", "Heavy click-bar switches with a loud click.", "boxnavy"),
    ("blue-alps", "Alps SKCM Blue", "Clicky", "Vintage Alps clicky switches.", "bluealps"),
    ("alpaca", "Alpaca", "Linear", "Alpaca linear switches.", "alpaca"),
    ("nk-cream", "NovelKeys Cream", "Linear", "Self-lubricating POM linear switches.", "cream"),
    ("turquoise", "Turquoise Tealios", "Linear", "Turquoise Tealios linear switches.", "turquoise"),
    ("red-ink", "Gateron Red Ink", "Linear", "Gateron Red Ink linear switches.", "redink"),
    ("black-ink", "Gateron Black Ink", "Linear", "Black Ink linears: deep, heavy bottom-out.", "blackink"),
    ("buckling-spring", "Buckling Spring", "Vintage", "IBM Model M-style buckling springs, the classic terminal sound.", "buckling"),
]

func kbsim(_ dir: URL) throws -> [Pack] {
    let credits = "Recordings from tplai/kbsim, MIT License, Copyright (c) Thomas Lai."
    return try kbsimPacks.map { id, name, category, description, folder in
        var pack = Pack(id: id, name: name, category: category, description: description, credits: credits)
        let base = dir.appendingPathComponent(folder)
        for (file, group) in [("GENERIC_R0", "alpha"), ("GENERIC_R1", "alpha"), ("GENERIC_R2", "alpha"),
                              ("GENERIC_R3", "alpha"), ("GENERIC_R4", "alpha"), ("SPACE", "space"),
                              ("ENTER", "enter"), ("BACKSPACE", "backspace")] {
            let url = base.appendingPathComponent("press/\(file).mp3")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let (clip, rate) = try decode(url)
            pack.rate = rate
            pack.presses[group, default: []].append(trim(clip, rate: rate))
        }
        for (file, group) in [("GENERIC", "alpha"), ("SPACE", "space"), ("ENTER", "enter"), ("BACKSPACE", "backspace")] {
            let url = base.appendingPathComponent("release/\(file).mp3")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let (clip, rate) = try decode(url)
            pack.releases[group, default: []].append(trim(clip, rate: rate))
        }
        return pack
    }
}

// MARK: - mechvibes (one sprite, per-key [start ms, duration ms])

/// uiohook scancodes → Switchcraft groups.
func mechvibesGroup(_ code: Int) -> String? {
    switch code {
    case 16...25, 30...38, 44...50: return "alpha"
    case 2...11: return "number"
    case 12, 13, 26, 27, 39, 40, 41, 43, 51, 52, 53: return "punctuation"
    case 57: return "space"
    case 28, 3612: return "enter"
    case 14, 3667: return "backspace"
    case 15: return "tab"
    case 1: return "escape"
    case 29, 42, 54, 56, 58, 3613, 3640, 3675, 3676: return "modifier"
    case 59...68, 87, 88: return "function"
    case 57416, 57419, 57421, 57424: return "arrow"
    case 3655, 3657, 3663, 3665, 3666: return "other"
    default: return nil
    }
}

func mechvibes(_ dir: URL) throws -> [Pack] {
    let credits = "Recordings from hainguyents13/mechvibes, MIT License, Copyright (c) 2021 Hai Nguyen."
    var packs: [Pack] = []
    for colour in ["red", "black", "brown", "blue"] {
        for caps in ["abs", "pbt"] {
            let folder = dir.appendingPathComponent("cherrymx-\(colour)-\(caps)")
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("config.json"))) as? [String: Any]
            guard let defines = config?["defines"] as? [String: [Int]] else { continue }
            let (sprite, rate) = try decode(folder.appendingPathComponent("sound.ogg"))
            let kind = ["red": "Linear", "black": "Linear", "brown": "Tactile", "blue": "Clicky"][colour] ?? ""
            let feel = ["red": "light linear", "black": "heavy linear", "brown": "light tactile", "blue": "tactile clicky"][colour] ?? ""
            var pack = Pack(id: "cherry-mx-\(colour)-\(caps)", name: "Cherry MX \(colour.capitalized) · \(caps.uppercased())",
                            category: kind, description: "Cherry MX \(colour.capitalized), \(feel), with \(caps.uppercased()) keycaps. Every key recorded individually.",
                            credits: credits, rate: rate)
            for (codeString, span) in defines.sorted(by: { Int($0.key) ?? 0 < Int($1.key) ?? 0 }) {
                guard let code = Int(codeString), let group = mechvibesGroup(code), span.count == 2 else { continue }
                let start = Int(Double(span[0]) / 1000 * rate), end = Int(Double(span[0] + span[1]) / 1000 * rate)
                let keyClip = slice(sprite, start..<end)
                let ms = Int(rate / 1000)
                let (press, release) = splitPressRelease(envelope(mono(keyClip), rate: rate))
                let pressClip = trim(slice(keyClip, press.lowerBound * ms..<press.upperBound * ms), rate: rate)
                guard usable(pressClip, rate: rate) else { continue }
                pack.presses[group, default: []].append(pressClip)
                if let release {
                    let releaseClip = trim(slice(keyClip, release.lowerBound * ms..<release.upperBound * ms), rate: rate)
                    if usable(releaseClip, rate: rate) { pack.releases[group, default: []].append(releaseClip) }
                }
            }
            packs.append(pack)
        }
    }
    return packs
}

/// Each mechvibes key slice holds a press and then a release (ranges in 1 ms envelope bins).
/// The press ends at its first 12 ms of near-silence; the next sound after that is the key-up.
/// Two strong attacks ≥ 40 ms apart with no silence between them are cut at the quietest point.
func splitPressRelease(_ env: [Double]) -> (press: Range<Int>, release: Range<Int>?) {
    let smooth = env.indices.map { i in env[max(0, i - 1)...min(env.count - 1, i + 1)].max() ?? 0 }
    let peak = smooth.max() ?? 0
    // The press starts at the first real attack: a jump to ≥ 15 % of the peak that is ≥ 2.5× the
    // quietest point of the previous 8 ms. A previous key's ringing tail (slices can start
    // mid-sound) never jumps like that.
    guard peak > 0, let first = smooth.indices.first(where: { i in
        guard smooth[i] > peak * 0.15, i >= 2 else { return false }
        let before = smooth[max(0, i - 8)..<i].min() ?? 0
        return smooth[i] >= before * 2.5
    }) else { return (0..<env.count, nil) }
    // The press's own attack is the loudest point within 30 ms of its first rise.
    let attack = (first..<min(smooth.count, first + 30)).max { smooth[$0] < smooth[$1] } ?? first
    // Walk back to where the attack begins: stop at the dip before it (never climb into a tail).
    var onset = first
    while onset > 0 && smooth[onset - 1] > smooth[attack] * 0.05 && smooth[onset - 1] <= smooth[onset] { onset -= 1 }
    let quiet = peak * 0.04
    var pressEnd = env.count
    var run = 0
    for i in attack..<smooth.count {
        run = smooth[i] < quiet ? run + 1 : 0
        if run >= 12 { pressEnd = i - 11; break }
    }
    if let releaseStart = (pressEnd..<smooth.count).first(where: { smooth[$0] > peak * 0.06 }) {
        return (max(0, onset - 1)..<pressEnd, max(pressEnd, releaseStart - 2)..<env.count)
    }
    // No silence: look for a second strong attack ≥ 40 ms later and cut at the valley.
    if let second = (min(attack + 40, smooth.count)..<smooth.count).first(where: { smooth[$0] > peak * 0.15 && smooth[$0] == smooth[max(0, $0 - 6)...min(smooth.count - 1, $0 + 6)].max() }) {
        let valley = (attack..<second).min { smooth[$0] < smooth[$1] } ?? (attack + second) / 2
        return (max(0, onset - 1)..<valley, valley..<env.count)
    }
    return (max(0, onset - 1)..<pressEnd, nil)
}

// MARK: - Continuous recordings (onset segmentation)

/// Isolated press→release pairs: two events 40–300 ms apart with silence around them.
func pairedHits(_ clip: Clip, rate: Double, limit: Int) -> (presses: [Clip], releases: [Clip]) {
    let env = envelope(mono(clip), rate: rate)
    let noise = env.sorted()[env.count / 5]
    let found = events(env, threshold: max(noise * 8, (env.max() ?? 0) * 0.04), mergeMs: 25)
    var pairs: [(Int, Int, Double)] = []
    for i in found.indices.dropLast() {
        let a = found[i], b = found[i + 1]
        let gap = b.start - a.start
        let before = i > 0 ? a.start - found[i - 1].end : 10_000
        let after = i + 2 < found.count ? found[i + 2].start - b.end : 10_000
        if (40...300).contains(gap) && before > 350 && after > 350 { pairs.append((a.start, b.start, a.peak)) }
    }
    let ms = Int(rate / 1000)
    let best = pairs.sorted { $0.2 > $1.2 }.prefix(limit).sorted { $0.0 < $1.0 }
    return (best.map { trim(slice(clip, ($0.0 - 1) * ms..<($0.1 - 2) * ms), rate: rate) },
            best.map { trim(slice(clip, ($0.1 - 1) * ms..<($0.1 + 150) * ms), rate: rate) })
}

/// Fast typing: each onset up to the next one (≤ 60 ms), skipping outliers (space bar, bumps, releases).
func typingHits(_ clip: Clip, rate: Double, limit: Int) -> [Clip] {
    let env = envelope(mono(clip), rate: rate)
    let noise = env.sorted()[env.count / 5]
    let found = events(env, threshold: max(noise * 6, (env.max() ?? 0) * 0.04), mergeMs: 15)
    let median = found.map(\.peak).sorted()[found.count / 2]
    let ms = Int(rate / 1000)
    let hits = found.indices.compactMap { i -> (Int, Int, Double)? in
        let e = found[i]
        guard e.peak > median * 0.6, e.peak < median * 2.5 else { return nil }
        let next = i + 1 < found.count ? found[i + 1].start - 3 : e.start + 60
        guard next - e.start >= 40 else { return nil }
        return (e.start, min(next, e.start + 60), e.peak) // ≤ 60 ms: no neighbouring key-up
    }
    return hits.prefix(limit).map { trim(slice(clip, ($0.0 - 1) * ms..<$0.1 * ms), rate: rate) }
}

func freesound(_ dir: URL) throws -> [Pack] {
    var packs: [Pack] = []
    let clearURL = dir.appendingPathComponent("mx-clear.mp3")
    if FileManager.default.fileExists(atPath: clearURL.path) {
        let (clip, rate) = try decode(clearURL)
        var pack = Pack(id: "cherry-mx-clear", name: "Cherry MX Clear", category: "Tactile",
                        description: "Cherry MX Clear, heavy tactile. Stereo recording of individual key presses.",
                        credits: "“Mechanical keyboard clicking. Different keys” by humi74, freesound.org/s/412926, CC0 1.0.", rate: rate)
        let (presses, releases) = pairedHits(clip, rate: rate, limit: 24)
        pack.presses["alpha"] = presses
        pack.releases["alpha"] = releases
        packs.append(pack)
    }
    let silentURL = dir.appendingPathComponent("mx-silent.mp3")
    if FileManager.default.fileExists(atPath: silentURL.path) {
        let (clip, rate) = try decode(silentURL)
        var pack = Pack(id: "cherry-mx-silent", name: "Cherry MX Silent", category: "Silent",
                        description: "Cherry MX Silent switches (dampened). Cut from a fast-typing recording; no separate key-ups.",
                        credits: "“Typing Fast_A01” by bonesawmgraw, freesound.org/s/572978, CC0 1.0.", rate: rate)
        pack.presses["alpha"] = typingHits(clip, rate: rate, limit: 20)
        packs.append(pack)
    }
    return packs
}

// MARK: - Write

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: build-sound-packs <sources dir: kbsim/ mechvibes/ freesound/> <SoundPacks dir>")
    exit(64)
}
let sources = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
let fm = FileManager.default
let packs = try mechvibes(sources.appendingPathComponent("mechvibes")) + freesound(sources.appendingPathComponent("freesound"))
    + kbsim(sources.appendingPathComponent("kbsim"))

for pack in packs {
    let hits = pack.presses.values.joined().map(mono)
    guard !hits.isEmpty else { print("skipping \(pack.name): no hits"); continue }
    // Loudness-match on the presses (−21 dBFS RMS of the first 60 ms), then keep everything below −1 dBFS.
    let level = rms(hits.flatMap { $0.prefix(Int(0.06 * pack.rate)) })
    let peak = (Array(pack.presses.values.joined()) + Array(pack.releases.values.joined())).flatMap { $0.joined() }.map(abs).max() ?? 1
    let gain = min(pow(10, -21.0 / 20) / max(level, 1e-9), pow(10, -1.0 / 20) / max(peak, 1e-9))

    let url = output.appendingPathComponent(pack.id + ".switchcraft")
    try? fm.removeItem(at: url)
    var listing: [String: [String: [String]]] = [:]
    for (kind, groups) in [("hard", pack.presses), ("release", pack.releases)] {
        for (group, clips) in groups {
            for (i, clip) in clips.enumerated() {
                let path = "sounds/\(group)/\(kind)/\(i + 1).wav"
                let file = url.appendingPathComponent(path)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try wav(clip, rate: pack.rate, gain: gain).write(to: file)
                listing[group, default: [:]][kind, default: []].append(path)
            }
        }
    }
    let manifest: [String: Any] = [
        "formatVersion": 1, "id": pack.id, "name": pack.name, "category": pack.category,
        "description": pack.description, "credits": pack.credits, "gain": 1.0,
        "deriveVelocityLayers": true, "samples": listing, "color": stemColors[pack.id] ?? "#8E8E93",
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        .write(to: url.appendingPathComponent("manifest.json"))
    let presses = pack.presses.values.reduce(0) { $0 + $1.count }, releases = pack.releases.values.reduce(0) { $0 + $1.count }
    let channels = pack.presses.values.first?.first?.count ?? 1
    print(String(format: "%-26@ %3d presses %3d releases  %@  gain %+5.1f dB", pack.name as NSString, presses, releases,
                 (channels == 2 ? "stereo" : "mono  ") as NSString, 20 * log10(gain)))
}
