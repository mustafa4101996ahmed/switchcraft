import SwiftUI
import SwitchcraftCore

/// The menu-bar panel. Compact, system controls only.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Switchcraft").font(.headline)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(settings.isEnabled ? "On" : "Off")
                    .foregroundStyle(.secondary)
                Toggle("Enabled", isOn: $settings.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if !model.permissions.inputMonitoringGranted {
                PermissionBanner()
            }

            Picker(selection: $settings.selectedPackID) {
                ForEach(model.library.packs) { pack in
                    Text(pack.name).tag(pack.id)
                }
            } label: {
                Label("Sound", systemImage: "speaker.wave.2")
            }

            labeledSlider("Volume", systemImage: "speaker.wave.3", value: $settings.volume)
            labeledSlider("Sensitivity", systemImage: "hand.tap", value: $settings.curve.sensitivity,
                          minLabel: "Soft", maxLabel: "Aggressive")

            VStack(alignment: .leading, spacing: 4) {
                Label("Velocity Detection", systemImage: "waveform.path")
                Picker("Velocity Detection", selection: $settings.velocityMode) {
                    ForEach(VelocityMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if settings.velocityMode == .accelerometer && !model.displayedSensorState.isReadable {
                    Text("Sensor unavailable — using fixed velocity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            menuButton("Calibrate Typing Force…", systemImage: "dial.medium") { open(.calibration) }
            menuButton("Settings…", systemImage: "gearshape") { open(.settings) }
            menuButton("Diagnostics…", systemImage: "stethoscope") { open(.diagnostics) }

            Divider()

            Toggle(isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) })) {
                Label("Launch at Login", systemImage: "power")
            }
            .toggleStyle(.checkbox)

            menuButton("Quit Switchcraft", systemImage: "xmark.circle") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 290)
    }

    private var statusColor: Color {
        guard model.settings.isEnabled else { return .secondary }
        return model.keyboardRunning ? .green : .orange
    }

    private func open(_ kind: WindowCoordinator.Kind) {
        // Close the menu-bar panel first so the new window comes to the front.
        NSApp.keyWindow?.close()
        model.windows.show(kind, model: model)
    }

    private func labeledSlider(_ title: String, systemImage: String, value: Binding<Double>,
                               minLabel: String? = nil, maxLabel: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
            Slider(value: value, in: 0...1) {
                Text(title)
            } minimumValueLabel: {
                Text(minLabel ?? "").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(maxLabel ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func menuButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shown wherever keyboard monitoring is blocked by a missing permission.
struct PermissionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Input Monitoring is off", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Switchcraft can't hear key presses until you allow Input Monitoring.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Allow…") { model.permissions.requestInputMonitoring() }
                Button("Open System Settings") { model.permissions.openInputMonitoringSettings() }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
