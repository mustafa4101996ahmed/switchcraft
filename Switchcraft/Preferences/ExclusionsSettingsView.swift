import SwiftUI
import UniformTypeIdentifiers
import SwitchcraftCore

struct ExclusionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    /// Offered as one-click suggestions when installed.
    private let suggestions = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.apple.logic10", "Logic Pro"),
        ("com.apple.garageband10", "GarageBand"),
    ]

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(settings.exclusions) { app in
                        HStack {
                            Image(nsImage: icon(for: app.bundleID)).resizable().frame(width: 18, height: 18)
                            Text(app.name)
                            Spacer()
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(app.bundleID)
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    Button("Add Application…", systemImage: "plus", action: chooseApp)
                    Button("Remove", systemImage: "minus") {
                        settings.exclusions.removeAll { $0.bundleID == selection }
                    }
                    .disabled(selection == nil)
                }
                let available = suggestions.filter { suggestion in
                    !settings.exclusions.contains { $0.bundleID == suggestion.0 }
                        && NSWorkspace.shared.urlForApplication(withBundleIdentifier: suggestion.0) != nil
                }
                if !available.isEmpty {
                    HStack {
                        Text("Suggestions:").foregroundStyle(.secondary)
                        ForEach(available, id: \.0) { suggestion in
                            Button(suggestion.1) {
                                settings.exclusions.append(ExcludedApp(bundleID: suggestion.0, name: suggestion.1))
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Mute in these applications")
            } footer: {
                Text("Sounds are muted while one of these apps is in front. Keyboard monitoring keeps running.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Mute while the microphone is in use", isOn: $settings.muteWhenMicActive)
                if settings.muteWhenMicActive {
                    LabeledContent("Microphone") { Text(model.microphoneInUse ? "In use by another app" : "Not in use") }
                }
            } footer: {
                Text("Checks CoreAudio's public “running input” state every 2 seconds. Switchcraft never opens or records the microphone and needs no microphone permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !model.settings.exclusions.contains(where: { $0.bundleID == id }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            model.settings.exclusions.append(ExcludedApp(bundleID: id, name: name))
        }
    }

    private func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
