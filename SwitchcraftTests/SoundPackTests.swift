import Foundation
import Testing
@testable import SwitchcraftCore

/// Builds throwaway pack folders. The loader validates structure only, so files need not be real audio.
struct TempPack {
    let url: URL

    init(manifest: String?, files: [String]) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("fk-\(UUID().uuidString).switchcraft")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let manifest { try manifest.write(to: url.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8) }
        for file in files {
            let fileURL = url.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x52, 0x49, 0x46, 0x46]).write(to: fileURL)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

struct SoundPackTests {
    @Test func parsesExplicitManifest() throws {
        let pack = try TempPack(manifest: """
        {"formatVersion": 1, "id": "my-pack", "name": "My Keyboard", "author": "User", "category": "Tactile", "gain": 0.8,
         "samples": {"alpha": {"soft": ["a/s1.wav", "a/s2.wav"], "hard": ["a/h.caf"]}, "space": {"medium": ["sp.aiff"]}}}
        """, files: ["a/s1.wav", "a/s2.wav", "a/h.caf", "sp.aiff"])
        defer { pack.remove() }
        let loaded = try SoundPackLoader.load(at: pack.url)
        #expect(loaded.id == "my-pack")
        #expect(loaded.name == "My Keyboard")
        #expect(loaded.gain == 0.8)
        #expect(loaded.sampleCount == 4)
        #expect(loaded.files[KeyGroup.alpha.index][VelocityLayer.soft.index].count == 2)
        #expect(loaded.warnings.isEmpty)
    }

    @Test func discoversFolderLayoutWithoutSampleList() throws {
        let pack = try TempPack(manifest: #"{"formatVersion": 1, "name": "Discovered"}"#,
                                files: ["sounds/alpha/soft/1.wav", "sounds/alpha/slam/1.WAV", "sounds/enter/hard/x.caf", "sounds/alpha/soft/readme.txt"])
        defer { pack.remove() }
        let loaded = try SoundPackLoader.load(at: pack.url)
        #expect(loaded.sampleCount == 3)
        #expect(loaded.id == pack.url.deletingPathExtension().lastPathComponent)
        #expect(loaded.files[KeyGroup.enter.index][VelocityLayer.hard.index].count == 1)
    }

    @Test func rejectsMissingManifest() throws {
        let pack = try TempPack(manifest: nil, files: ["sounds/alpha/soft/1.wav"])
        defer { pack.remove() }
        #expect(throws: SoundPackError.missingManifest) { try SoundPackLoader.load(at: pack.url) }
    }

    @Test func rejectsBadVersionNameAndGain() throws {
        for (json, expected) in [
            (#"{"formatVersion": 2, "name": "X"}"#, SoundPackError.unsupportedFormatVersion(2)),
            (#"{"formatVersion": 1, "name": "  "}"#, SoundPackError.missingName),
            (#"{"formatVersion": 1, "name": "X", "gain": 9}"#, SoundPackError.invalidGain),
        ] {
            let pack = try TempPack(manifest: json, files: ["sounds/alpha/soft/1.wav"])
            defer { pack.remove() }
            #expect(throws: expected) { try SoundPackLoader.load(at: pack.url) }
        }
    }

    @Test func rejectsMalformedJSON() throws {
        let pack = try TempPack(manifest: "{ not json", files: [])
        defer { pack.remove() }
        #expect(throws: SoundPackError.self) { try SoundPackLoader.load(at: pack.url) }
    }

    @Test func blocksPathTraversalAndBadFiles() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("fk-outside-\(UUID().uuidString).wav")
        try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let pack = try TempPack(manifest: """
        {"formatVersion": 1, "name": "Evil", "samples": {"alpha": {"soft": [
          "../\(outside.lastPathComponent)", "\(outside.path)", "ok.wav", "missing.wav", "notes.mp3"]}}}
        """, files: ["ok.wav", "notes.mp3"])
        defer { pack.remove() }
        let loaded = try SoundPackLoader.load(at: pack.url)
        #expect(loaded.sampleCount == 1)
        #expect(loaded.files[KeyGroup.alpha.index][VelocityLayer.soft.index].first?.lastPathComponent == "ok.wav")
        #expect(loaded.warnings.count == 4)
        #expect(loaded.warnings.contains { $0.contains("outside the pack") })
        #expect(loaded.warnings.contains { $0.contains("relative") })
        #expect(loaded.warnings.contains { $0.contains("missing") })
        #expect(loaded.warnings.contains { $0.contains(".wav, .aiff or .caf") })
    }

    @Test func rejectsPackWithNoUsableSamples() throws {
        let pack = try TempPack(manifest: #"{"formatVersion": 1, "name": "Empty", "samples": {"alpha": {"soft": ["gone.wav"]}}}"#, files: [])
        defer { pack.remove() }
        #expect(throws: SoundPackError.noSamples) { try SoundPackLoader.load(at: pack.url) }
    }

    @Test func warnsAboutUnknownNames() throws {
        let pack = try TempPack(manifest: #"{"formatVersion": 1, "name": "W", "samples": {"alpha": {"soft": ["a.wav"], "loud": ["a.wav"]}, "joystick": {"soft": ["a.wav"]}}}"#,
                                files: ["a.wav"])
        defer { pack.remove() }
        let loaded = try SoundPackLoader.load(at: pack.url)
        #expect(loaded.warnings.count == 2)
    }

    @Test func fallsBackToNearestLayerThenGroupChain() throws {
        let pack = try TempPack(manifest: """
        {"formatVersion": 1, "name": "Sparse", "samples": {
          "alpha": {"soft": ["as.wav"], "hard": ["ah.wav"]},
          "enter": {"slam": ["es.wav"]}}}
        """, files: ["as.wav", "ah.wav", "es.wav"])
        defer { pack.remove() }
        let loaded = try SoundPackLoader.load(at: pack.url)
        func name(_ g: KeyGroup, _ l: VelocityLayer) -> String? { loaded.resolve(group: g, layer: l).first?.lastPathComponent }
        #expect(name(.alpha, .soft) == "as.wav")
        #expect(name(.alpha, .medium) == "as.wav") // tie between soft and hard → softer
        #expect(name(.alpha, .slam) == "ah.wav")
        #expect(name(.enter, .soft) == "es.wav") // enter has only slam: nearest layer within the group wins
        #expect(name(.backspace, .soft) == "es.wav") // backspace → enter
        #expect(name(.number, .hard) == "ah.wav") // number → alpha
        #expect(name(.space, .medium) == "es.wav") // space → enter
    }

    @Test func parsesReleaseLayerWithGroupFallback() throws {
        let pack = try TempPack(manifest: #"{"formatVersion": 1, "name": "R", "credits": "Me"}"#,
                                files: ["sounds/alpha/hard/1.wav", "sounds/alpha/release/up.wav", "sounds/space/release/up.wav"])
        defer { pack.remove() }
        let loaded = try SoundPackLoader.load(at: pack.url)
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.manifest.credits == "Me")
        #expect(loaded.sampleCount == 1) // releases don't count as press samples
        #expect(loaded.resolveRelease(group: .space).first?.path.contains("space") == true)
        #expect(loaded.resolveRelease(group: .number).first?.path.contains("alpha") == true)
        #expect(loaded.resolveRelease(group: .enter).first?.path.contains("space") == true) // enter → space
    }

    @Test func derivedLayersPoolEveryPressRecording() throws {
        let pack = try TempPack(manifest: #"{"formatVersion": 1, "name": "D", "deriveVelocityLayers": true}"#,
                                files: ["sounds/alpha/hard/1.wav", "sounds/alpha/hard/2.wav", "sounds/alpha/soft/3.wav", "sounds/space/hard/s.wav"])
        defer { pack.remove() }
        let loaded = try SoundPackLoader.load(at: pack.url)
        #expect(loaded.derivesLayers)
        for layer in VelocityLayer.allCases {
            #expect(Set(loaded.resolve(group: .alpha, layer: layer).map(\.lastPathComponent)) == ["1.wav", "2.wav", "3.wav"])
            #expect(loaded.resolve(group: .space, layer: layer).map(\.lastPathComponent) == ["s.wav"])
        }
    }

    @Test func releaseOnlyPackIsRejected() throws {
        let pack = try TempPack(manifest: #"{"formatVersion": 1, "name": "R"}"#, files: ["sounds/alpha/release/up.wav"])
        defer { pack.remove() }
        #expect(throws: SoundPackError.noSamples) { try SoundPackLoader.load(at: pack.url) }
    }

    @Test func bundledPacksAreValid() throws {
        // Repo layout: <root>/SwitchcraftTests/this file, <root>/SoundPacks.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("SoundPacks")
        let packs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "switchcraft" }
        #expect(packs.count == 20)
        let ids = try packs.map { try SoundPackLoader.load(at: $0, isBuiltIn: true).id }
        for colour in ["red", "black", "brown", "blue"] {
            #expect(ids.contains("cherry-mx-\(colour)-abs") && ids.contains("cherry-mx-\(colour)-pbt"))
        }
        #expect(ids.contains("cherry-mx-clear") && ids.contains("cherry-mx-silent"))
        #expect(ids.contains(SettingsStore.defaultPackID))
        for url in packs {
            let pack = try SoundPackLoader.load(at: url, isBuiltIn: true)
            #expect(pack.warnings.isEmpty, "\(pack.name): \(pack.warnings)")
            #expect(pack.derivesLayers)
            #expect(pack.manifest.credits.map { $0.contains("MIT") || $0.contains("CC0") } == true)
            if pack.id != "cherry-mx-silent" {
                #expect(!pack.resolveRelease(group: .alpha).isEmpty, "\(pack.name) has no key-up sound")
            }
            // Every velocity layer derives from the same hits, in the same order (coherent crossfades).
            let names = VelocityLayer.allCases.map { pack.files[KeyGroup.alpha.index][$0.index].map(\.lastPathComponent) }
            #expect(Set(names.map { $0.joined(separator: ",") }).count == 1)
            for group in KeyGroup.allCases {
                for layer in VelocityLayer.allCases {
                    #expect(!pack.resolve(group: group, layer: layer).isEmpty)
                }
            }
        }
    }
}
