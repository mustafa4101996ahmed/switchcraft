import SwiftUI
import UniformTypeIdentifiers
import SwitchcraftCore

struct SoundSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var importError: String?
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                List(selection: Binding(get: { settings.selectedPackID }, set: { if let id = $0 { settings.selectedPackID = id } })) {
                    ForEach(model.library.packs) { pack in
                        PackRow(pack: pack).tag(pack.id)
                    }
                }
                .frame(minHeight: 150)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 2)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
                HStack {
                    Button("Preview", systemImage: "play.fill") { model.previewSound() }
                    Spacer()
                    Button("Import Sound Pack…", action: chooseImport)
                    Button("Open Sound Pack Folder") { model.library.revealUserFolder() }
                    Menu("More") {
                        Button("Reload Packs") { model.reloadPacks() }
                        if let pack = model.library.pack(id: settings.selectedPackID), !pack.isBuiltIn {
                            Button("Move “\(pack.name)” to Trash", role: .destructive) { delete(pack) }
                        }
                    }
                    .fixedSize()
                }
            } header: {
                Text("Sound pack")
            } footer: {
                Text("Drop a .switchcraft folder onto the list to import it. Imported packs are stored in ~/Library/Application Support/Switchcraft/SoundPacks.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let message = importError ?? model.packMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let pack = model.library.pack(id: settings.selectedPackID) {
                Section("About this pack") {
                    if let description = pack.manifest.description { Text(description) }
                    if let credits = pack.manifest.credits {
                        Text(credits).font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Key-up sounds") { Text(pack.releaseFiles.contains { !$0.isEmpty } ? "Included" : "None") }
                }
            }
            if let pack = model.library.pack(id: settings.selectedPackID), !pack.warnings.isEmpty {
                Section("Pack warnings") {
                    ForEach(pack.warnings, id: \.self) { Text($0).font(.caption) }
                }
            }
            if !model.library.invalidPacks.isEmpty {
                Section("Packs that couldn't be loaded") {
                    ForEach(model.library.invalidPacks, id: \.self) { Text($0).font(.caption) }
                }
            }

            Section {
                Slider(value: $settings.volume, in: 0...1) { Text("Master volume") }
                Slider(value: $settings.stereoWidth, in: 0...1) {
                    Text("Stereo width")
                } minimumValueLabel: {
                    Text("Mono").font(.caption)
                } maximumValueLabel: {
                    Text("Wide").font(.caption)
                }
                Slider(value: $settings.roomAmbience, in: 0...1) {
                    Text("Room ambience")
                } minimumValueLabel: {
                    Text("Dry").font(.caption)
                } maximumValueLabel: {
                    Text("Roomy").font(.caption)
                }
                Toggle("Random sample variation", isOn: $settings.randomVariation)
                Text("Each key keeps its own recording, like a real board. Variation adds a barely audible ±0.5 % speed and ±0.5 dB level change per press.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Playback")
            } footer: {
                Text("Stereo width places every key where it sits on the keyboard, so the sound comes from under your finger. Room ambience adds the short reflections of a desk and room. Headphones show both best.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a .switchcraft sound pack folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPack(url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in importPack(url) }
        }
        return true
    }

    private func importPack(_ url: URL) {
        do {
            try model.importPack(from: url)
            importError = nil
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    private func delete(_ pack: SoundPack) {
        do {
            try model.library.delete(pack)
            model.settings.selectedPackID = SettingsStore.defaultPackID
        } catch {
            importError = "Couldn't remove the pack: \(error.localizedDescription)"
        }
    }
}

private struct PackRow: View {
    let pack: SoundPack

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name)
                Text([pack.manifest.category, pack.manifest.author, "\(pack.sampleCount) samples"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !pack.isBuiltIn {
                Text("Imported").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
