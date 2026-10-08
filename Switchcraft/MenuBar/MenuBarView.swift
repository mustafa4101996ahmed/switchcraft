import SwiftUI
import SwitchcraftCore

/// The menu-bar panel: what you change every day, and a live view of how hard you're typing.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 12) {
            header(settings: $settings.isEnabled)

            if model.listeningStatus == .needsPermission {
                PermissionBanner()
            } else if let detail = model.listeningStatus.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Typing force")
                    Spacer()
                    if settings.velocityMode == .fixed {
                        Text("Fixed").foregroundStyle(.secondary)
                    } else if settings.velocityMode == .accelerometer && !model.displayedSensorState.isReadable {
                        Text("Sensor off · fixed").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                TypingForceMeter()
            }

            Divider()

            HStack(spacing: 8) {
                StemSwatch(hex: model.activePack?.manifest.color, size: 12)
                Picker("Switch", selection: $settings.selectedPackID) {
                    ForEach(model.library.packs) { pack in
                        Text(pack.name).tag(pack.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Which switch you hear")
            }

            slider("Volume", systemImage: "speaker.wave.2", value: $settings.volume)
            slider("Sensitivity", systemImage: "hand.tap", value: $settings.curve.sensitivity,
                   range: ("Soft", "Aggressive"),
                   help: "How hard you need to press to reach the loud end. Aggressive makes light typing sound harder.")

            Divider()

            // Rows keep their hover highlight inside the panel edge while their icons line up
            // with the labels above.
            VStack(alignment: .leading, spacing: 0) {
                row("Calibrate Typing Force…", systemImage: "dial.medium") { open(.calibration) }
                row("Settings…", systemImage: "gearshape") { open(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
                row("Diagnostics…", systemImage: "stethoscope") { open(.diagnostics) }
                row(model.updates.available.map { "Update to \($0.version)…" } ?? "Check for Updates…",
                    systemImage: model.updates.available == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle") {
                    NSApp.keyWindow?.close()
                    Task { await model.updates.check(userInitiated: true) }
                }
            }
            .padding(.horizontal, -6)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Launch at Login", systemImage: "power").labelStyle(FixedIconLabelStyle())
                    Spacer()
                    Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                row("Quit Switchcraft", systemImage: "xmark.circle") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, -6)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func header(settings isEnabled: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Switchcraft").font(.headline)
                StatusLabel(kind: model.listeningStatus.kind, text: model.listeningStatus.text)
                    .font(.callout)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Toggle("Enabled", isOn: isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Turn key sounds on or off (\(GlobalHotKey.display) from any app)")
        }
    }

    private func open(_ kind: WindowCoordinator.Kind) {
        // Close the menu-bar panel first so the new window comes to the front.
        NSApp.keyWindow?.close()
        model.windows.show(kind, model: model)
    }

    private func slider(_ title: String, systemImage: String, value: Binding<Double>,
                        range: (String, String)? = nil, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .labelStyle(FixedIconLabelStyle())
                .accessibilityHidden(true)
            Slider(value: value, in: 0...1) { Text(title) }
                .labelsHidden()
                .controlSize(.small)
                .help(help ?? title)
            if let range {
                HStack {
                    Text(range.0)
                    Spacer()
                    Text(range.1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

/// Shown wherever keyboard monitoring is blocked by a missing permission.
struct PermissionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusLabel(kind: .warning, text: "Switchcraft can't hear key presses yet")
                .font(.callout.weight(.semibold))
            Text("Allow Input Monitoring. Switchcraft reads which key was pressed, never what you type.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow…") { model.permissions.requestInputMonitoring() }
                Button("Open System Settings") { model.permissions.openInputMonitoringSettings() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
