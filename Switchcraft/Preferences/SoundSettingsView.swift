import SwiftUI
import UniformTypeIdentifiers
import SwitchcraftCore

struct SoundSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var importError: String?
    @State private var isDropTargeted = false
    @State private var confirmingDelete: SoundPack?

    /// Switch families in a sensible browsing order; imported packs last.
    private static let categoryOrder = ["Linear", "Tactile", "Clicky", "Silent", "Electro-capacitive", "Vintage"]

    private var groups: [(title: String, packs: [SoundPack])] {
        let builtIn = model.library.packs.filter(\.isBuiltIn)
        var result = Self.categoryOrder.compactMap { category -> (String, [SoundPack])? in
            let packs = builtIn.filter { $0.manifest.category == category }
            return packs.isEmpty ? nil : (category, packs)
        }
        let others = builtIn.filter { !Self.categoryOrder.contains($0.manifest.category ?? "") }
        if !others.isEmpty { result.append(("Other", others)) }
        let imported = model.library.packs.filter { !$0.isBuiltIn }
        if !imported.isEmpty { result.append(("Imported", imported)) }
        return result
    }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Playback") {
                Slider(value: $settings.volume, in: 0...1) { Text("Volume") }
                Slider(value: $settings.stereoWidth, in: 0...1) {
                    Text("Stereo width")
                } minimumValueLabel: {
                    Text("Mono")
                } maximumValueLabel: {
                    Text("Wide")
                }
                .help("Places each key where it sits on the keyboard, so the sound comes from under your finger.")
                Slider(value: $settings.roomAmbience, in: 0...1) {
                    Text("Room ambience")
                } minimumValueLabel: {
                    Text("Dry")
                } maximumValueLabel: {
                    Text("Roomy")
                }
                .help("Short desk-and-room reflections that blend into each click. Never an echo.")
                Toggle(isOn: $settings.randomVariation) {
                    Text("Natural variation")
                    Text("A barely audible ±0.5 % speed and ±0.5 dB change per press. Each key keeps its own recording.")
                }
            }

            Section {
                List(selection: Binding(get: { settings.selectedPackID }, set: { if let id = $0 { settings.selectedPackID = id } })) {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.packs) { pack in
                                PackRow(pack: pack, isSelected: pack.id == settings.selectedPackID) { model.previewSound() }
                                    .tag(pack.id)
                            }
                        }
                    }
                }
                .frame(height: 230)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 2)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
                HStack {
                    Button("Import Sound Pack…", action: chooseImport)
                    Button("Open Sound Pack Folder") { model.library.revealUserFolder() }
                    Spacer()
                    Menu("More") {
                        Button("Reload Packs") { model.reloadPacks() }
                        if let pack = model.activePack, !pack.isBuiltIn {
                            Button("Move “\(pack.name)” to Trash…", role: .destructive) { confirmingDelete = pack }
                        }
                    }
                    .fixedSize()
                }
            } header: {
                Text("Switch")
            } footer: {
                Text("Drop a .switchcraft folder on the list to import it. Imported packs live in ~/Library/Application Support/Switchcraft/SoundPacks.")
                    .foregroundStyle(.secondary)
            }

            if let message = importError ?? model.packMessage {
                StatusLabel(kind: .warning, text: message)
            }
            if let pack = model.activePack {
                Section("About this switch") {
                    if let description = pack.manifest.description { Text(description) }
                    LabeledContent("Recordings") {
                        Text("\(pack.sampleCount) key presses" + (pack.releaseFiles.contains { !$0.isEmpty } ? " + key-ups" : ""))
                    }
                    if let credits = pack.manifest.credits {
                        Text(credits).foregroundStyle(.secondary)
                    }
                    ForEach(pack.warnings, id: \.self) { StatusLabel(kind: .warning, text: $0) }
                }
            }
            if !model.library.invalidPacks.isEmpty {
                Section("Packs that couldn't be loaded") {
                    ForEach(model.library.invalidPacks, id: \.self) { StatusLabel(kind: .warning, text: $0) }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Move “\(confirmingDelete?.name ?? "")” to the Trash?", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let pack = confirmingDelete { delete(pack) }
            }
        } message: {
            Text("You can restore it from the Trash and import it again.")
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
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
    let isSelected: Bool
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StemSwatch(hex: pack.manifest.color, size: 12)
            Text(pack.name)
            Spacer()
            if isSelected {
                Button(action: preview) {
                    Image(systemName: "play.circle.fill").imageScale(.large)
                }
                .buttonStyle(.borderless)
                .help("Play soft to slam")
                .accessibilityLabel("Preview \(pack.name)")
            }
        }
        .padding(.vertical, 1)
    }
}
