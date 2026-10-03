import SwiftUI
import SwitchcraftCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            SoundSettingsView()
                .tabItem { Label("Sound", systemImage: "speaker.wave.2") }
            TypingForceSettingsView()
                .tabItem { Label("Typing Force", systemImage: "hand.tap") }
            ExclusionsSettingsView()
                .tabItem { Label("Exclusions", systemImage: "nosign") }
            DiagnosticsSummaryView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 560)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    private let symbols = [SettingsStore.brandSymbol, "keyboard", "keyboard.fill", "waveform", "hand.tap"]

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Enable Switchcraft", isOn: $settings.isEnabled)
                Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
                if let message = model.launchAtLoginMessage {
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Button("Open Login Items") { model.permissions.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }
                Picker("Menu-bar icon", selection: $settings.menuBarSymbol) {
                    ForEach(symbols, id: \.self) { symbol in
                        BrandIcon.menuBarImage(symbol).tag(symbol)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Play key-up (release) sounds", isOn: $settings.playReleases)
                Toggle("Play key-repeat sounds", isOn: $settings.playRepeats)
                Toggle("Silence the “invalid key” beep while typing", isOn: $settings.silenceTypingBeep)
            } footer: {
                Text("Holding a key down doesn't hit the chassis again, so repeats are silent by default. The beep option mutes the macOS alert sound only during a typing burst and restores your alert volume a second after you stop, so other alerts still play.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Keyboard monitoring") {
                LabeledContent("Input Monitoring") {
                    Text(model.permissions.inputMonitoringGranted ? "Allowed" : "Not allowed")
                        .foregroundStyle(model.permissions.inputMonitoringGranted ? .green : .orange)
                }
                LabeledContent("Listener") { Text(model.keyboardRunning ? "Running" : "Stopped") }
                if let message = model.keyboardMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open Input Monitoring Settings") { model.permissions.openInputMonitoringSettings() }
                    Button("Show Welcome Guide") { model.windows.show(.onboarding, model: model) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DiagnosticsSummaryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Status") {
                LabeledContent("Accelerometer") { Text(model.displayedSensorState.rawValue) }
                LabeledContent("Keyboard listener") { Text(model.keyboardRunning ? "Running" : "Stopped") }
                LabeledContent("Audio engine") { Text(model.audio.isRunning ? "Running" : "Stopped") }
                LabeledContent("Sound pack") { Text(model.activePackName ?? "—") }
            }
            Section {
                Toggle("Show live sensor graph in Diagnostics", isOn: $settings.showDebugGraph)
                Button("Open Diagnostics…") { model.windows.show(.diagnostics, model: model) }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            BrandIcon.appIcon
                .resizable()
                .frame(width: 96, height: 96)
            Text("Switchcraft").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                .foregroundStyle(.secondary)
            Text("\(model.hardware.architecture) · \(model.hardware.modelIdentifier)")
                .font(.caption).foregroundStyle(.secondary)
            Text("Velocity-sensitive keyboard sounds driven by your MacBook's built-in accelerometer. Everything stays on this Mac: no network, no analytics, no typed text is ever recorded.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            GroupBox("Open-source acknowledgements") {
                Text("Accelerometer access is based on olvvier/apple-silicon-accelerometer (MIT License, © 2026 olvvier). Switch recordings come from tplai/kbsim (MIT License, © Thomas Lai); Switchcraft derives the velocity layers. Full license texts are in LICENSES/ in the source repository.")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 460)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
