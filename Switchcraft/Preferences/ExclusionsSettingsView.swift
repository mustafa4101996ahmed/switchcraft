import SwiftUI
import UniformTypeIdentifiers
import SwitchcraftCore

struct ExclusionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    /// App URL/icon lookups done once per app, not on every redraw.
    @State private var icons: [String: NSImage] = [:]
    @State private var installedSuggestions: [(String, String)] = []

    private static let suggestions = [
        ("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.apple.logic10", "Logic Pro"), ("com.apple.garageband10", "GarageBand"),
    ]

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(settings.exclusions) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: icons[app.bundleID] ?? NSImage()).resizable().frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                            Text(app.name)
                            Spacer()
                            Text(app.bundleID).foregroundStyle(.secondary)
                        }
                        .tag(app.bundleID)
                    }
                }
                .frame(minHeight: 140)
                .onDeleteCommand(perform: removeSelected)
                .overlay {
                    if settings.exclusions.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "speaker.slash").font(.title2).foregroundStyle(.secondary)
                            Text("No muted apps")
                            Text("Add apps where key sounds would get in the way, like video calls or music software.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                HStack {
                    Button("Add App…", systemImage: "plus", action: chooseApp)
                    Button("Remove", systemImage: "minus", action: removeSelected)
                        .disabled(selection == nil)
                    Spacer()
                }
                let available = installedSuggestions.filter { suggestion in !settings.exclusions.contains { $0.bundleID == suggestion.0 } }
                if !available.isEmpty {
                    HStack {
                        Text("Suggestions:").foregroundStyle(.secondary)
                        ForEach(available, id: \.0) { suggestion in
                            Button(suggestion.1) { add(ExcludedApp(bundleID: suggestion.0, name: suggestion.1)) }
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Mute in these apps")
            } footer: {
                Text("Switchcraft stays quiet while one of these apps is in front. Everything else keeps working.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.muteWhenMicActive) {
                    Text("Mute while the microphone is in use")
                    Text("Checks every 2 seconds whether another app is recording. Switchcraft never opens the microphone and needs no microphone permission.")
                }
                if settings.muteWhenMicActive {
                    LabeledContent("Microphone") {
                        StatusLabel(kind: .neutral, text: model.microphoneInUse ? "In use: sounds muted" : "Not in use")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshLookups)
        .onChange(of: model.settings.exclusions) { refreshLookups() }
    }

    private func refreshLookups() {
        installedSuggestions = Self.suggestions.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }
        for app in model.settings.exclusions where icons[app.bundleID] == nil {
            icons[app.bundleID] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        }
    }

    private func add(_ app: ExcludedApp) {
        guard !model.settings.exclusions.contains(where: { $0.bundleID == app.bundleID }) else { return }
        model.settings.exclusions.append(app)
    }

    private func removeSelected() {
        guard let selection else { return }
        model.settings.exclusions.removeAll { $0.bundleID == selection }
        self.selection = nil
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            add(ExcludedApp(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")))
        }
    }
}
