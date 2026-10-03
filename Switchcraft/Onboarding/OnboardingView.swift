import SwiftUI
import SwitchcraftCore

/// First run, built around the payoff: hearing your own soft and hard presses.
/// Hardware checks run silently and only get a step when something is wrong.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Step
    @State private var calibrating = false
    @State private var practice = ""
    @FocusState private var practiceFocused: Bool

    enum Step: String, CaseIterable {
        case welcome, keyboard, sensor, hear, calibrate, done

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .keyboard: return "Keyboard access"
            case .sensor: return "Typing force"
            case .hear: return "Hear it"
            case .calibrate: return "Calibrate"
            case .done: return "You're set"
            }
        }
    }

    init(step: Step = .welcome) {
        _step = State(initialValue: step)
    }

    /// The sensor step only appears when typing force can't be measured.
    private var sensorProblem: Bool {
        !model.hardware.accelerometerPresent || [.permissionRequired, .unsupported].contains(model.displayedSensorState)
    }

    private var steps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .sensor: return sensorProblem
            case .calibrate: return !sensorProblem
            default: return true
            }
        }
    }

    private var index: Int { steps.firstIndex(of: step) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title).font(.title2.weight(.semibold))
                Spacer()
                Text("Step \(index + 1) of \(steps.count)").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 480)
        .onAppear { model.requireSensor("onboarding", true) }
        .onDisappear { model.requireSensor("onboarding", false) }
    }

    private var footer: some View {
        HStack {
            if step == .welcome {
                Button("Skip Setup") { finish() }
            } else {
                Button("Back") { move(-1) }.disabled(calibrating)
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Get Started") { move(1) }.keyboardShortcut(.defaultAction)
            case .calibrate:
                // Never the default button: Return while typing must not skip calibration.
                Button("Skip") { move(1) }.disabled(calibrating)
            case .done:
                Button("Done") { finish() }.keyboardShortcut(.defaultAction)
            default:
                Button("Continue") { move(1) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func move(_ delta: Int) {
        let next = min(max(index + delta, 0), steps.count - 1)
        step = steps[next]
    }

    private func finish() {
        model.settings.hasCompletedOnboarding = true
        model.windows.close(.onboarding)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 14) {
                BrandIcon.appIcon.resizable().frame(width: 80, height: 80).accessibilityHidden(true)
                Text("Your MacBook keyboard, with the sound of a real mechanical switch.")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Switchcraft feels how hard each key lands through the MacBook's built-in motion sensor, so soft presses sound soft and hard presses sound hard.")
                    .fixedSize(horizontal: false, vertical: true)
                Label("Everything stays on this Mac. No network access, and the text you type is never recorded.", systemImage: "lock")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .keyboard:
            VStack(alignment: .leading, spacing: 14) {
                Text("Switchcraft needs Input Monitoring to know when a key is pressed. It reads which key it was, never what you type, and nothing leaves your Mac.")
                    .fixedSize(horizontal: false, vertical: true)
                StatusLabel(kind: model.permissions.inputMonitoringGranted ? .good : .warning,
                            text: model.permissions.inputMonitoringGranted ? "Input Monitoring is on" : "Input Monitoring is off")
                if !model.permissions.inputMonitoringGranted {
                    HStack {
                        Button("Allow Input Monitoring…") { model.permissions.requestInputMonitoring() }
                        Button("Open System Settings") { model.permissions.openInputMonitoringSettings() }
                    }
                    Text("Turn on Switchcraft in System Settings › Privacy & Security › Input Monitoring. This page updates by itself. If macOS asks you to quit and reopen Switchcraft, do that; setup picks up where you left off.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if case let .notListening(reason) = model.listeningStatus {
                    StatusLabel(kind: .warning, text: reason)
                }
            }
        case .sensor:
            VStack(alignment: .leading, spacing: 14) {
                StatusLabel(kind: .warning, text: model.hardware.accelerometerPresent
                            ? "macOS isn't letting Switchcraft read the motion sensor"
                            : "This Mac doesn't have the motion sensor Switchcraft uses")
                Text("Switchcraft still plays every key, at one fixed strength. On a supported MacBook, Diagnostics can show what's wrong.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use Fixed Strength") {
                    model.settings.velocityMode = .fixed
                    move(1)
                }
            }
        case .hear:
            hear
        case .calibrate:
            CalibrationView(embedded: true, onRunningChange: { calibrating = $0 }, onFinish: { move(1) })
        case .done:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: BrandIcon.glyph)
                        .resizable()
                        .frame(width: 26, height: 26)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    Text("Switchcraft lives in your menu bar, behind this icon.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Click it to change the switch, volume or sensitivity. \(GlobalHotKey.display) turns the sounds on or off from any app.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Keep typing: the bar shows how hard each key landed.").foregroundStyle(.secondary)
                TypingForceMeter()
            }
        }
    }

    private var hear: some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: 14) {
            Text("Type a few keys: a soft press, then a hard one.")
            TextField("Type here", text: $practice)
                .textFieldStyle(.roundedBorder)
                .focused($practiceFocused)
                .onSubmit {}
                .onAppear { practiceFocused = true }
            TypingForceMeter()
            if model.listeningStatus != .listening {
                HStack {
                    StatusLabel(kind: .warning, text: "Allow keyboard access to hear your own typing.")
                    Spacer()
                    Button("Play a Sample") { model.previewSound() }
                }
            }
            Divider()
            LabeledContent("Switch") {
                HStack(spacing: 8) {
                    StemSwatch(hex: model.activePack?.manifest.color, size: 12)
                    Picker("Switch", selection: $settings.selectedPackID) {
                        ForEach(model.library.packs) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
            LabeledContent("Volume") {
                Slider(value: $settings.volume, in: 0...1) { Text("Volume") }.labelsHidden().frame(width: 220)
            }
            if let message = model.audioMessage ?? model.packMessage {
                StatusLabel(kind: .warning, text: message)
            }
        }
    }
}
