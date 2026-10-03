import SwiftUI
import SwitchcraftCore

struct TypingForceSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdvanced = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Mode", selection: $settings.velocityMode) {
                    ForEach(VelocityMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                switch settings.velocityMode {
                case .accelerometer:
                    LabeledContent("Sensor") { Text(model.displayedSensorState.rawValue) }
                    if let message = model.sensorMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                case .fixed:
                    Slider(value: $settings.fixedVelocity, in: 0...1) { Text("Fixed velocity") }
                case .simulated:
                    Picker("Source", selection: $settings.simulationSource) {
                        ForEach(SimulationSource.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if settings.simulationSource == .randomRange {
                        Slider(value: $settings.randomMin, in: 0...1) { Text("Minimum") }
                        Slider(value: $settings.randomMax, in: 0...1) { Text("Maximum") }
                    } else {
                        Text("Each key press generates a synthetic accelerometer impulse of random strength and runs it through the real impact detector.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Velocity detection")
            }

            Section("Response") {
                Slider(value: $settings.curve.sensitivity, in: 0...1) {
                    Text("Sensitivity")
                } minimumValueLabel: {
                    Text("Soft").font(.caption)
                } maximumValueLabel: {
                    Text("Aggressive").font(.caption)
                }
                // The orange dot follows your latest key press (refreshed 5×/s).
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    ResponseCurveView(mapper: VelocityMapper(calibration: settings.calibration, curve: settings.curve),
                                      lastImpact: model.pipeline.stats.snapshot(now: MonotonicClock.now()).lastMeasurement?.magnitude)
                }
                .frame(height: 140)
            }

            Section("Calibration") {
                LabeledContent("Status") {
                    Text(settings.calibration.isUserCalibrated ? "Calibrated for this Mac" : "Factory defaults")
                }
                LabeledContent("Soft / normal / hard") {
                    Text(String(format: "%.1f / %.1f / %.1f mg", settings.calibration.soft * 1000,
                                settings.calibration.normal * 1000, settings.calibration.hard * 1000))
                        .monospacedDigit()
                }
                HStack {
                    Button("Calibrate…") { model.windows.show(.calibration, model: model) }
                    Button("Reset Calibration") { settings.resetCalibration() }
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    AdvancedControls()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Group {
            row("Noise floor (minimum)", value: $settings.minimumNoiseFloor, range: 0.00005...0.005, format: "%.2f mg", scale: 1000)
            row("Detection threshold", value: $settings.detectionSNR, range: 2...12, format: "%.1f × floor")
            row("Gain", value: $settings.curve.gain, range: 0.25...4, format: "%.2f ×")
            row("Gamma / curve", value: $settings.curve.gamma, range: 0.3...3, format: "%.2f")
            row("Minimum velocity", value: $settings.curve.minVelocity, range: 0...1, format: "%.2f")
            row("Maximum velocity", value: $settings.curve.maxVelocity, range: 0...1, format: "%.2f")
            row("Correlation window: before key", value: $settings.window.preMs, range: 0...40, format: "%.0f ms")
            row("Correlation window: after key", value: $settings.window.postMs, range: 0...25, format: "%.0f ms")
            row("Impact decay", value: $settings.impactDecayMs, range: 2...80, format: "%.0f ms")
            Text("“After key” is added latency in accelerometer mode: the bottom-out impulse lands ~8 ms after the key event on the measured MacBook. 0 ms uses only the finger-strike impulse that precedes the key event.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Restore Defaults") { settings.resetAdvanced() }
        }
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, scale: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).frame(width: 200)
                Text(String(format: format, value.wrappedValue * scale))
                    .monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
            }
        }
    }
}

/// Velocity (y) against impact magnitude on a log axis (x), with the calibration anchors.
struct ResponseCurveView: View {
    let mapper: VelocityMapper
    var lastImpact: Double?

    private let lowest = 0.0005, highest = 0.2

    var body: some View {
        Canvas { context, size in
            func x(_ magnitude: Double) -> CGFloat {
                CGFloat((log(magnitude) - log(lowest)) / (log(highest) - log(lowest))) * size.width
            }
            func y(_ velocity: Double) -> CGFloat { size.height * CGFloat(1 - velocity) }

            for tier in 1..<4 {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(Double(tier) * 0.25)))
                line.addLine(to: CGPoint(x: size.width, y: y(Double(tier) * 0.25)))
                context.stroke(line, with: .color(.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }
            var curve = Path()
            for step in 0...120 {
                let m = exp(log(lowest) + (log(highest) - log(lowest)) * Double(step) / 120)
                let point = CGPoint(x: x(m), y: y(mapper.velocity(forImpact: m)))
                step == 0 ? curve.move(to: point) : curve.addLine(to: point)
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 2)

            let anchors = [("soft", mapper.calibration.soft), ("normal", mapper.calibration.normal), ("hard", mapper.calibration.hard)]
            for (name, magnitude) in anchors {
                let point = CGPoint(x: x(magnitude), y: y(mapper.velocity(forImpact: magnitude)))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(.accentColor))
                context.draw(Text(name).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: point.x, y: point.y - 10))
            }
            if let lastImpact, lastImpact > 0 {
                let point = CGPoint(x: x(lastImpact), y: y(mapper.velocity(forImpact: lastImpact)))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(.orange))
            }
            context.draw(Text("impact →").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: size.width - 28, y: size.height - 8))
            context.draw(Text("velocity").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 24, y: 8))
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Response curve from impact strength to velocity")
    }
}
