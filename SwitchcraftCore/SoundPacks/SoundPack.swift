import Foundation

/// `manifest.json` at the root of a `.switchcraft` pack folder. See docs/SOUNDPACK_FORMAT.md.
public struct SoundPackManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var id: String?
    public var name: String
    public var author: String?
    public var description: String?
    public var category: String?
    /// Attribution for the recordings (shown in Settings).
    public var credits: String?
    /// Linear gain applied to every sample in the pack (default 1).
    public var gain: Double?
    /// When true, every press recording is a full-force hit and Switchcraft generates the
    /// soft/medium/hard/slam layers from it at load time (see `LayerDerivation`).
    public var deriveVelocityLayers: Bool?
    /// group → layer → relative file paths. Layers: soft, medium, hard, slam, plus optional
    /// `release` (key-up). When omitted, `sounds/<group>/<layer>/*` is scanned.
    public var samples: [String: [String: [String]]]?

    public static let supportedFormatVersion = 1

    public init(formatVersion: Int = supportedFormatVersion, id: String? = nil, name: String,
                author: String? = nil, description: String? = nil, category: String? = nil,
                credits: String? = nil, gain: Double? = nil, deriveVelocityLayers: Bool? = nil,
                samples: [String: [String: [String]]]? = nil) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.author = author
        self.description = description
        self.category = category
        self.credits = credits
        self.gain = gain
        self.deriveVelocityLayers = deriveVelocityLayers
        self.samples = samples
    }
}

/// A validated pack: every listed file exists, is inside the pack and has a supported extension.
public struct SoundPack: Identifiable, Equatable, Sendable {
    public var id: String
    public var manifest: SoundPackManifest
    public var url: URL
    public var isBuiltIn: Bool
    /// Indexed by `KeyGroup.index`, then `VelocityLayer.index`.
    public var files: [[[URL]]]
    /// Key-up recordings, indexed by `KeyGroup.index`.
    public var releaseFiles: [[URL]]
    /// Non-fatal problems (unknown group names, skipped files…).
    public var warnings: [String]

    public var name: String { manifest.name }
    /// Layers are generated from single hits; `files` then holds the same hits in every layer.
    public var derivesLayers: Bool { manifest.deriveVelocityLayers ?? false }
    public var gain: Double { manifest.gain ?? 1 }
    public var sampleCount: Int { files.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } } }

    /// Recordings for `group`/`layer`, falling back to the nearest recorded layer, then to the
    /// group's fallback chain, then to any group with recordings.
    public func resolve(group: KeyGroup, layer: VelocityLayer) -> [URL] {
        for g in [group] + group.fallbacks {
            if let urls = nearestLayer(in: g, to: layer) { return urls }
        }
        for g in KeyGroup.allCases {
            if let urls = nearestLayer(in: g, to: layer) { return urls }
        }
        return []
    }

    /// Key-up recordings for `group`, following the group fallback chain. Empty = no release sound.
    public func resolveRelease(group: KeyGroup) -> [URL] {
        ([group] + group.fallbacks).lazy.map { releaseFiles[$0.index] }.first { !$0.isEmpty } ?? []
    }

    private func nearestLayer(in group: KeyGroup, to layer: VelocityLayer) -> [URL]? {
        let layers = files[group.index]
        let ordered = VelocityLayer.allCases.sorted {
            let da = abs($0.index - layer.index), db = abs($1.index - layer.index)
            // Ties prefer the softer layer: a too-quiet sample is less jarring than a too-loud one.
            return da == db ? $0.index < $1.index : da < db
        }
        return ordered.lazy.map { layers[$0.index] }.first { !$0.isEmpty }
    }
}

public enum SoundPackError: Error, Equatable, LocalizedError {
    case missingManifest
    case unreadableManifest(String)
    case unsupportedFormatVersion(Int)
    case missingName
    case noSamples
    case invalidGain

    public var errorDescription: String? {
        switch self {
        case .missingManifest: return "The folder has no manifest.json."
        case let .unreadableManifest(reason): return "manifest.json could not be read: \(reason)"
        case let .unsupportedFormatVersion(v): return "Format version \(v) isn't supported (expected 1)."
        case .missingName: return "The manifest needs a non-empty \"name\"."
        case .noSamples: return "The pack contains no usable .wav, .aiff or .caf samples."
        case .invalidGain: return "\"gain\" must be between 0 and 4."
        }
    }
}

public enum SoundPackLoader {
    public static let fileExtension = "switchcraft"
    public static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "caf"]
    static let maxFileBytes = 10 * 1024 * 1024

    public static func load(at url: URL, isBuiltIn: Bool = false,
                            fileManager: FileManager = .default) throws -> SoundPack {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw SoundPackError.missingManifest }

        let manifest: SoundPackManifest
        do {
            manifest = try JSONDecoder().decode(SoundPackManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw SoundPackError.unreadableManifest(String(describing: error))
        }
        guard manifest.formatVersion == SoundPackManifest.supportedFormatVersion else {
            throw SoundPackError.unsupportedFormatVersion(manifest.formatVersion)
        }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SoundPackError.missingName
        }
        if let gain = manifest.gain, !(0...4).contains(gain) { throw SoundPackError.invalidGain }

        var warnings: [String] = []
        var files = Array(repeating: Array(repeating: [URL](), count: VelocityLayer.count), count: KeyGroup.count)
        var releases = Array(repeating: [URL](), count: KeyGroup.count)
        let listing = manifest.samples ?? discover(in: root, fileManager: fileManager)

        for (groupName, layers) in listing.sorted(by: { $0.key < $1.key }) {
            guard let group = KeyGroup(rawValue: groupName.lowercased()) else {
                warnings.append("Unknown key group \"\(groupName)\" ignored.")
                continue
            }
            for (layerName, paths) in layers.sorted(by: { $0.key < $1.key }) {
                let isRelease = layerName.lowercased() == "release"
                let layer = VelocityLayer(rawValue: layerName.lowercased())
                guard isRelease || layer != nil else {
                    warnings.append("Unknown velocity layer \"\(layerName)\" in \(groupName) ignored.")
                    continue
                }
                for path in paths {
                    switch validateSample(path, root: root, fileManager: fileManager) {
                    case let .success(file):
                        if let layer {
                            files[group.index][layer.index].append(file)
                        } else {
                            releases[group.index].append(file)
                        }
                    case let .failure(problem):
                        warnings.append(problem.message)
                    }
                }
            }
        }
        guard files.contains(where: { $0.contains { !$0.isEmpty } }) else { throw SoundPackError.noSamples }
        if manifest.deriveVelocityLayers == true {
            // Pool every press recording of a group; each becomes a source for all four layers.
            for g in files.indices {
                var pooled: [URL] = []
                for url in files[g].joined() where !pooled.contains(url) { pooled.append(url) }
                files[g] = Array(repeating: pooled, count: VelocityLayer.count)
            }
        }
        if files[KeyGroup.alpha.index].allSatisfy(\.isEmpty) {
            warnings.append("No \"alpha\" samples: other groups will stand in for letter keys.")
        }
        return SoundPack(id: manifest.id ?? root.deletingPathExtension().lastPathComponent,
                         manifest: manifest, url: root, isBuiltIn: isBuiltIn, files: files,
                         releaseFiles: releases, warnings: warnings)
    }

    struct SampleProblem: Error { let message: String }

    /// Rejects absolute paths, `..` escapes, symlinks out of the pack, missing/oversized files and
    /// unsupported formats.
    static func validateSample(_ path: String, root: URL, fileManager: FileManager) -> Result<URL, SampleProblem> {
        guard !path.hasPrefix("/"), !path.contains("\\") else {
            return .failure(SampleProblem(message: "Sample path \"\(path)\" must be relative to the pack."))
        }
        let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else {
            return .failure(SampleProblem(message: "Sample path \"\(path)\" points outside the pack."))
        }
        guard audioExtensions.contains(file.pathExtension.lowercased()) else {
            return .failure(SampleProblem(message: "\"\(path)\" isn't .wav, .aiff or .caf."))
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return .failure(SampleProblem(message: "Sample \"\(path)\" is missing."))
        }
        if let size = attributes[.size] as? Int, size > maxFileBytes {
            return .failure(SampleProblem(message: "Sample \"\(path)\" is larger than 10 MB."))
        }
        return .success(file)
    }

    /// Builds a listing from `sounds/<group>/<layer>/<file>`.
    static func discover(in root: URL, fileManager: FileManager) -> [String: [String: [String]]] {
        var listing: [String: [String: [String]]] = [:]
        let sounds = root.appendingPathComponent("sounds")
        guard let groups = try? fileManager.contentsOfDirectory(atPath: sounds.path) else { return listing }
        for group in groups where !group.hasPrefix(".") {
            let groupURL = sounds.appendingPathComponent(group)
            guard let layers = try? fileManager.contentsOfDirectory(atPath: groupURL.path) else { continue }
            for layer in layers where !layer.hasPrefix(".") {
                let layerURL = groupURL.appendingPathComponent(layer)
                guard let names = try? fileManager.contentsOfDirectory(atPath: layerURL.path) else { continue }
                let audio = names.filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                if !audio.isEmpty {
                    listing[group, default: [:]][layer] = audio.sorted().map { "sounds/\(group)/\(layer)/\($0)" }
                }
            }
        }
        return listing
    }
}
