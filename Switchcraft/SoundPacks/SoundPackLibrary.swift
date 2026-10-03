import AppKit
import Observation
import SwitchcraftCore

/// Bundled packs (read-only, inside the app) plus user packs in
/// ~/Library/Application Support/Switchcraft/SoundPacks.
@MainActor @Observable
final class SoundPackLibrary {
    private(set) var packs: [SoundPack] = []
    /// Folders that failed validation: "name: reason".
    private(set) var invalidPacks: [String] = []
    let userDirectory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        userDirectory = support.appendingPathComponent("Switchcraft/SoundPacks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
            try Self.migrateLegacyPacks(from: support.appendingPathComponent("ForceKeys/SoundPacks"), to: userDirectory)
        } catch {
            Log.soundpack.error("Couldn't create \(self.userDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Packs imported under the app's previous name move here, renamed to the current extension.
    private static func migrateLegacyPacks(from legacy: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }
        for item in items where item.pathExtension == "forcekeys" {
            let target = destination.appendingPathComponent(item.deletingPathExtension().lastPathComponent)
                .appendingPathExtension(SoundPackLoader.fileExtension)
            if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: item, to: target) }
        }
    }

    var builtInDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("SoundPacks", isDirectory: true) }

    func reload() {
        var found: [SoundPack] = []
        var invalid: [String] = []
        for (directory, isBuiltIn) in [(builtInDirectory, true), (userDirectory, false)] {
            guard let directory,
                  let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            else { continue }
            for item in items where item.pathExtension == SoundPackLoader.fileExtension {
                do {
                    var pack = try SoundPackLoader.load(at: item, isBuiltIn: isBuiltIn)
                    if !isBuiltIn { pack.id = "user." + pack.id }
                    if found.contains(where: { $0.id == pack.id }) { pack.id += "." + item.lastPathComponent }
                    pack.warnings.forEach { Log.soundpack.notice("\(pack.name, privacy: .public): \($0, privacy: .public)") }
                    found.append(pack)
                } catch {
                    invalid.append("\(item.lastPathComponent): \(error.localizedDescription)")
                    Log.soundpack.error("Invalid pack \(item.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        packs = found.sorted { ($0.isBuiltIn ? 0 : 1, $0.name) < ($1.isBuiltIn ? 0 : 1, $1.name) }
        invalidPacks = invalid
    }

    func pack(id: String) -> SoundPack? { packs.first { $0.id == id } }

    /// Validates first, then copies the folder into the user directory. Returns the new pack.
    @discardableResult
    func importPack(from url: URL) throws -> SoundPack {
        let candidate = try SoundPackLoader.load(at: url)
        let base = candidate.manifest.name.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined().trimmingCharacters(in: .whitespaces)
        var destination = userDirectory.appendingPathComponent((base.isEmpty ? "Imported" : base) + ".switchcraft")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = userDirectory.appendingPathComponent("\(base) \(suffix).switchcraft")
            suffix += 1
        }
        try FileManager.default.copyItem(at: url, to: destination)
        Log.soundpack.info("Imported pack \(candidate.name, privacy: .public)")
        reload()
        let folder = destination.lastPathComponent
        guard let imported = packs.first(where: { !$0.isBuiltIn && $0.url.lastPathComponent == folder }) else {
            throw SoundPackError.noSamples
        }
        return imported
    }

    /// Moves a user pack to the Trash. Bundled packs can't be removed.
    func delete(_ pack: SoundPack) throws {
        guard !pack.isBuiltIn else { return }
        try FileManager.default.trashItem(at: pack.url, resultingItemURL: nil)
        reload()
    }

    func revealUserFolder() { NSWorkspace.shared.open(userDirectory) }
}
