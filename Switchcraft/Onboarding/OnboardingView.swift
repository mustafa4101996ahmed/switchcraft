import SwiftUI
import SwitchcraftCore

/// First-launch guide: welcome → hardware → permission → sensor → helper → audio → calibration → finish.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Step

    init(step: Step = .welcome) {
        _step = State(initialValue: step)
    }

    enum Step: Int, CaseIterable {
        case welcome, hardware, permission, sensor, helper, audio, calibration, finish

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .hardware: return "Hardware check"
            case .permission: return "Keyboard monitoring"
            case .sensor: return "Sensor check"
            case .helper: return "Sensor access"
            case .audio: return "Audio test"
            case .calibration: return "Typing-force calibration"
            case .finish: return "All set"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(step.title).font(.title2.weight(.semibold))
                Spacer()
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)").foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            Divider()
            HStack {
                if step != .welcome {
                    Button("Back") { move(-1) }
                }
                Spacer()
                if step == .finish {
                    Button("Done") {
                        model.settings.hasCompletedOnboarding = true
                        model.windows.close(.onboarding)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(step == .calibration ? "Skip" : "Continue") { move(1) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 500)
    }

    private func move(_ delta: Int) {
        step = Step(rawValue: step.rawValue + delta) ?? step
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 12) {
                BrandIcon.appIcon.resizable().frame(width: 72, height: 72)
                Text("Switchcraft turns your MacBook keyboard into a velocity-sensitive mechanical keyboard. Soft presses sound soft; hard presses sound hard.")
                Text("It measures how hard you type with the MacBook's built-in accelerometer, entirely on this Mac. No network access, no analytics, and the text you type is never recorded.")
                    .foregroundStyle(.secondary)
            }
        case .hardware:
            let hw = model.hardware
            VStack(alignment: .leading, spacing: 8) {
                check("Apple Silicon", hw.isAppleSilicon, detail: hw.cpuBrand)
                check("MacBook (portable)", hw.isLaptop, detail: hw.modelIdentifier)
                check("Built-in keyboard", hw.hasBuiltInKeyboard)
                check("Accelerometer (AppleSPUHIDDevice)", hw.accelerometerPresent)
                if !hw.accelerometerPresent {
                    Text("Without a compatible accelerometer, Switchcraft still plays sounds using Fixed or Simulated velocity.")
                        .foregroundStyle(.secondary)
                }
            }
        case .permission:
            VStack(alignment: .leading, spacing: 12) {
                Text("Switchcraft needs Input Monitoring to detect when a key is pressed. It processes key codes locally and doesn't record the text you type.")
                check("Input Monitoring", model.permissions.inputMonitoringGranted)
                if !model.permissions.inputMonitoringGranted {
                    HStack {
                        Button("Allow Input Monitoring…") { model.permissions.requestInputMonitoring() }
                        Button("Open System Settings") { model.permissions.openInputMonitoringSettings() }
                    }
                    Text("Turn on Switchcraft in System Settings › Privacy & Security › Input Monitoring. This page updates by itself. If macOS asks you to quit and reopen Switchcraft, do so.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let message = model.keyboardMessage {
                    Text(message).foregroundStyle(.orange)
                }
            }
        case .sensor:
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    check("Sensor readable", model.displayedSensorState == .supported, detail: model.displayedSensorState.rawValue)
                    if model.sensor.measuredSampleRate > 0 {
                        Text(String(format: "Streaming at %.0f samples per second (measured).", model.sensor.measuredSampleRate))
                    }
                    if let message = model.sensorMessage { Text(message).foregroundStyle(.secondary) }
                    Button("Retry") { model.restartSensor() }
                }
            }
            .onAppear { model.requireSensor("onboarding", true) }
            .onDisappear { model.requireSensor("onboarding", false) }
        case .helper:
            VStack(alignment: .leading, spacing: 10) {
                if model.displayedSensorState == .supported {
                    check("No helper needed", true)
                    Text("Switchcraft reads the accelerometer directly as your user account. Nothing runs as root and no administrator password is needed.")
                } else {
                    check("Sensor not readable", false, detail: model.displayedSensorState.rawValue)
                    Text("On this Mac the accelerometer couldn't be read directly. Switchcraft will use Fixed velocity. See docs/TROUBLESHOOTING.md for what to check.")
                        .foregroundStyle(.secondary)
                }
            }
        case .audio:
            @Bindable var settings = model.settings
            VStack(alignment: .leading, spacing: 12) {
                Text("Play a soft-to-hard sequence from the current sound pack.")
                Button("Play Test Sound", systemImage: "play.fill") { model.previewSound() }
                Slider(value: $settings.volume, in: 0...1) { Text("Volume") }
                if let message = model.audioMessage ?? model.packMessage {
                    Text(message).foregroundStyle(.orange)
                }
            }
        case .calibration:
            CalibrationView(onFinish: { move(1) })
        case .finish:
            VStack(alignment: .leading, spacing: 12) {
                Text("Switchcraft lives in the menu bar. Click its icon to change sounds, volume and sensitivity, or to open Settings and Diagnostics.")
                Text("Start typing anywhere to hear it.").foregroundStyle(.secondary)
            }
        }
    }

    private func check(_ title: String, _ ok: Bool, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(title)
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
    }
}
