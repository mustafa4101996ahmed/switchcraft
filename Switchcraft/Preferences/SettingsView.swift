import SwiftUI
import SwitchcraftCore

/// Settings panes, shown as macOS toolbar tabs by `WindowCoordinator`.
enum SettingsPane: String, CaseIterable {
    case general, sound, typingForce, exclusions, diagnostics, about

    static let size = CGSize(width: 620, height: 500)

    var title: String {
        switch self {
        case .general: return "General"
        case .sound: return "Sound"
        case .typingForce: return "Typing Force"
        case .exclusions: return "Exclusions"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .sound: return "speaker.wave.2"
        case .typingForce: return "hand.tap"
        case .exclusions: return "nosign"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .sound: SoundSettingsView()
        case .typingForce: TypingForceSettingsView()
        case .exclusions: ExclusionsSettingsView()
        case .diagnostics: DiagnosticsSummaryView()
        case .about: AboutView()
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    private let symbols: [(String, String)] = [
        (SettingsStore.brandSymbol, "Switchcraft switch"), ("keyboard", "Keyboard outline"),
        ("keyboard.fill", "Keyboard filled"), ("waveform", "Waveform"), ("hand.tap", "Tapping finger"),
    ]

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle(isOn: $settings.isEnabled) {
                    Text("Enable Switchcraft")
                    Text("From any app: \(GlobalHotKey.display)")
                }
                Toggle(isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Launch at Login")
                    if let message = model.launchAtLoginMessage { Text(message) }
                }
                if model.launchAtLoginMessage != nil {
                    Button("Open Login Items Settings") { model.permissions.openLoginItemsSettings() }
                }
                Picker("Menu-bar icon", selection: $settings.menuBarSymbol) {
                    ForEach(symbols, id: \.0) { symbol, name in
                        BrandIcon.menuBarImage(symbol).accessibilityLabel(name).help(name).tag(symbol)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Sounds") {
                Toggle(isOn: $settings.playReleases) {
                    Text("Play key-up sounds")
                    Text("The switch's upstroke as you lift each key, like a real board.")
                }
                Toggle(isOn: $settings.playRepeats) {
                    Text("Play key-repeat sounds")
                    Text("Holding a key doesn't strike the switch again, so repeats are silent by default.")
                }
            }

            Section("System") {
                Toggle(isOn: $settings.silenceTypingBeep) {
                    Text("Silence the “invalid key” beep while typing")
                    Text("Lowers the macOS alert volume only while you type and restores it a second after you stop. Other alerts play normally, and your level comes back even if Switchcraft quits.")
                }
                Toggle(isOn: $settings.hotKeyEnabled) {
                    Text("Turn Switchcraft on and off with \(GlobalHotKey.display)")
                }
            }

            Section("Keyboard access") {
                LabeledContent("Input Monitoring") {
                    StatusLabel(kind: model.permissions.inputMonitoringGranted ? .good : .warning,
                                text: model.permissions.inputMonitoringGranted ? "Allowed" : "Not allowed")
                }
                LabeledContent("Status") {
                    StatusLabel(kind: model.listeningStatus.kind, text: model.listeningStatus.text)
                }
                if let detail = model.listeningStatus.detail {
                    Text(detail).foregroundStyle(.secondary)
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
                LabeledContent("Keyboard") {
                    StatusLabel(kind: model.listeningStatus.kind, text: model.listeningStatus.text)
                }
                LabeledContent("Typing-force sensor") {
                    StatusLabel(kind: model.displayedSensorState.isReadable ? .good : .neutral,
                                text: model.displayedSensorState.displayName)
                }
                LabeledContent("Audio") {
                    StatusLabel(kind: model.audio.isRunning ? .good : .warning, text: model.audio.isRunning ? "Playing" : "Stopped")
                }
                LabeledContent("Switch") {
                    HStack(spacing: 6) {
                        StemSwatch(hex: model.activePack?.manifest.color)
                        Text(model.activePackName ?? "—")
                    }
                }
            }
            Section {
                Toggle("Show the live sensor graph in Diagnostics", isOn: $settings.showDebugGraph)
                Button("Open Diagnostics…") { model.windows.show(.diagnostics, model: model) }
            } footer: {
                Text("Diagnostics shows every sensor, timing and audio value, runs a sensor test and exports a report without any typed text.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutView: View {
    @Environment(AppModel.self) private var model

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "—") (\(info?["CFBundleVersion"] as? String ?? "—"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                BrandIcon.appIcon.resizable().frame(width: 72, height: 72).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Switchcraft").font(.title2.weight(.semibold))
                    Text(version).foregroundStyle(.secondary)
                    Text("\(model.hardware.cpuBrand) · \(model.hardware.modelIdentifier)").foregroundStyle(.secondary)
                }
            }
            Text("Velocity-sensitive mechanical keyboard sounds, driven by your MacBook's built-in accelerometer. Everything stays on this Mac: no network access, no analytics, and the text you type is never recorded.")
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    credit("Accelerometer access", "olvvier/apple-silicon-accelerometer", "MIT", "https://github.com/olvvier/apple-silicon-accelerometer")
                    credit("Cherry MX Red, Black, Brown, Blue", "hainguyents13/mechvibes", "MIT", "https://github.com/hainguyents13/mechvibes")
                    credit("Other switches", "tplai/kbsim", "MIT", "https://github.com/tplai/kbsim")
                    credit("Cherry MX Clear", "humi74 on Freesound", "CC0", "https://freesound.org/s/412926/")
                    credit("Cherry MX Silent", "bonesawmgraw on Freesound", "CC0", "https://freesound.org/s/572978/")
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Acknowledgements")
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func credit(_ what: String, _ source: String, _ license: String, _ url: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(what).frame(width: 220, alignment: .leading)
            if let link = URL(string: url) {
                Link(source, destination: link)
            }
            Spacer()
            Text(license).foregroundStyle(.secondary)
        }
    }
}
