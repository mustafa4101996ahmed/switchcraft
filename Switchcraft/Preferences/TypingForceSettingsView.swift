import SwiftUI
import SwitchcraftCore

struct TypingForceSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdvanced = false
    @State private var confirmingReset = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Measure with", selection: Binding(
                    get: { settings.velocityMode == .simulated ? .accelerometer : settings.velocityMode },
                    set: { settings.velocityMode = $0 })) {
                    Text("Accelerometer").tag(VelocityMode.accelerometer)
                    Text("Fixed strength").tag(VelocityMode.fixed)
                }
                .pickerStyle(.segmented)
                switch settings.velocityMode {
                case .accelerometer, .simulated:
                    LabeledContent("Sensor") {
                        StatusLabel(kind: model.displayedSensorState.isReadable ? .good : .warning,
                                    text: model.displayedSensorState.displayName)
                    }
                    if !model.displayedSensorState.isReadable && settings.velocityMode == .accelerometer {
                        Text("Every key plays at the fixed strength until the sensor works. Diagnostics can test it.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Use Fixed Strength") { settings.velocityMode = .fixed }
                            Button("Open Diagnostics…") { model.windows.show(.diagnostics, model: model) }
                        }
                    }
                case .fixed:
                    Slider(value: $settings.fixedVelocity, in: 0...1) {
                        Text("Strength")
                    } minimumValueLabel: {
                        Text("Soft")
                    } maximumValueLabel: {
                        Text("Slam")
                    }
                }
            } header: {
                Text("How typing force is measured")
            } footer: {
                Text("The accelerometer feels how hard each key hits the MacBook's case. Fixed plays every key at one strength.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Slider(value: $settings.curve.sensitivity, in: 0...1) {
                    Text("Sensitivity")
                } minimumValueLabel: {
                    Text("Soft")
                } maximumValueLabel: {
                    Text("Aggressive")
                }
                .help("Aggressive makes light typing sound harder; Soft needs firmer presses to reach the loud end.")
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    ResponseCurveView(mapper: VelocityMapper(calibration: settings.calibration, curve: settings.curve),
                                      lastImpact: model.pipeline.stats.snapshot(now: MonotonicClock.now()).lastMeasurement?.magnitude)
                }
                .frame(height: 150)
            } header: {
                Text("Response")
            } footer: {
                Text("How a key's impact (left to right) turns into soft to slam (bottom to top). The orange dot is your last key press.")
                    .foregroundStyle(.secondary)
            }

            Section("Calibration") {
                LabeledContent("Status") {
                    StatusLabel(kind: settings.calibration.isUserCalibrated ? .good : .neutral,
                                text: settings.calibration.isUserCalibrated ? "Calibrated for your typing" : "Factory settings")
                }
                HStack {
                    Button("Calibrate…") { model.windows.show(.calibration, model: model) }
                    Button("Reset to Factory Settings…") { confirmingReset = true }
                        .disabled(!settings.calibration.isUserCalibrated)
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    AdvancedControls()
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset your calibration?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { settings.resetCalibration() }
        } message: {
            Text("Switchcraft goes back to the factory soft, normal and hard levels. You can calibrate again any time.")
        }
    }
}

private struct AdvancedControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Group {
            row("Noise floor (minimum)", value: $settings.minimumNoiseFloor, range: 0.00005...0.005, unit: "mg", scale: 1000,
                help: "Vibrations below this never count as a key press.")
            row("Detection threshold", value: $settings.detectionSNR, range: 2...12, unit: "× noise",
                help: "How far above the background vibration an impact must rise.")
            row("Gain", value: $settings.curve.gain, range: 0.25...4, unit: "×", help: "Scales every impact before mapping.")
            row("Curve", value: $settings.curve.gamma, range: 0.3...3, unit: "γ",
                help: "Below 1 lifts soft presses; above 1 keeps them softer.")
            row("Softest press", value: Binding(get: { settings.curve.minVelocity },
                                                set: { settings.curve.minVelocity = min($0, settings.curve.maxVelocity) }),
                range: 0...1, unit: "", help: "The quietest a key can sound.")
            row("Hardest press", value: Binding(get: { settings.curve.maxVelocity },
                                                set: { settings.curve.maxVelocity = max($0, settings.curve.minVelocity) }),
                range: 0...1, unit: "", help: "The loudest a key can sound.")
            row("Listen before the key", value: $settings.window.preMs, range: 0...40, unit: "ms",
                help: "The finger strike starts about 12 ms before macOS reports the key.")
            row("Listen after the key", value: $settings.window.postMs, range: 0...25, unit: "ms",
                help: "Adds this much delay before the sound in exchange for catching the bottom-out. 8 ms captures 99 % of it.")
            row("Impact decay", value: $settings.impactDecayMs, range: 2...80, unit: "ms",
                help: "How long one impact keeps ringing into the next key during fast typing.")

            Picker("Developer simulation", selection: Binding(
                get: { settings.velocityMode == .simulated ? settings.simulationSource : nil },
                set: { source in
                    if let source {
                        settings.simulationSource = source
                        settings.velocityMode = .simulated
                    } else if settings.velocityMode == .simulated {
                        settings.velocityMode = .accelerometer
                    }
                })) {
                Text("Off").tag(SimulationSource?.none)
                ForEach(SimulationSource.allCases, id: \.self) { Text($0.displayName).tag(SimulationSource?.some($0)) }
            }
            .help("For testing without a sensor: invent a typing force for every key.")
            if settings.velocityMode == .simulated && settings.simulationSource == .randomRange {
                row("Random from", value: Binding(get: { settings.randomMin }, set: { settings.randomMin = min($0, settings.randomMax) }),
                    range: 0...1, unit: "", help: "Lowest simulated strength.")
                row("Random to", value: Binding(get: { settings.randomMax }, set: { settings.randomMax = max($0, settings.randomMin) }),
                    range: 0...1, unit: "", help: "Highest simulated strength.")
            }
            Button("Restore Defaults") { settings.resetAdvanced() }
        }
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String,
                     scale: Double = 1, help: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: range) { Text(title) }
                    .labelsHidden()
                    .frame(width: 180)
                TextField(title, value: Binding(get: { value.wrappedValue * scale },
                                                set: { value.wrappedValue = min(max($0 / scale, range.lowerBound), range.upperBound) }),
                          format: .number.precision(.fractionLength(scale == 1 && range.upperBound <= 4 ? 2 : 1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 56)
                Text(unit).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            }
        }
        .help(help)
    }
}

/// Velocity (y) against impact magnitude on a log axis (x), with the calibration anchors.
struct ResponseCurveView: View {
    let mapper: VelocityMapper
    var lastImpact: Double?

    private let lowest = 0.0005, highest = 0.2
    private let inset: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2 - 12)
            func x(_ magnitude: Double) -> CGFloat {
                plot.minX + CGFloat((log(magnitude) - log(lowest)) / (log(highest) - log(lowest))) * plot.width
            }
            func y(_ velocity: Double) -> CGFloat { plot.minY + plot.height * CGFloat(1 - velocity) }

            for tier in 1..<4 {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(Double(tier) * 0.25)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(Double(tier) * 0.25)))
                context.stroke(line, with: .color(.secondary.opacity(0.3)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }
            var curve = Path()
            for step in 0...120 {
                let m = exp(log(lowest) + (log(highest) - log(lowest)) * Double(step) / 120)
                let point = CGPoint(x: x(m), y: y(mapper.velocity(forImpact: m)))
                step == 0 ? curve.move(to: point) : curve.addLine(to: point)
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 2)

            // The curve rises left to right, so labels below-right of each anchor never touch it.
            for (name, magnitude) in [("soft", mapper.calibration.soft), ("normal", mapper.calibration.normal), ("hard", mapper.calibration.hard)] {
                let point = CGPoint(x: x(magnitude), y: y(mapper.velocity(forImpact: magnitude)))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(.accentColor))
                context.draw(Text(name).font(.caption).foregroundStyle(.secondary), at: CGPoint(x: point.x + 6, y: point.y + 4), anchor: .topLeading)
            }
            if let lastImpact, lastImpact > 0 {
                let point = CGPoint(x: x(min(max(lastImpact, lowest), highest)), y: y(mapper.velocity(forImpact: lastImpact)))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(.orange))
            }
            context.draw(Text("softer impact").font(.caption).foregroundStyle(.secondary),
                         at: CGPoint(x: plot.minX, y: size.height), anchor: .bottomLeading)
            context.draw(Text("harder impact").font(.caption).foregroundStyle(.secondary),
                         at: CGPoint(x: plot.maxX, y: size.height), anchor: .bottomTrailing)
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement()
        .accessibilityLabel("Response curve from impact to typing force")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let anchors = "Soft presses play at \(percent(mapper.calibration.soft)), normal at \(percent(mapper.calibration.normal)), hard at \(percent(mapper.calibration.hard))."
        guard let lastImpact, lastImpact > 0 else { return anchors }
        return anchors + " Your last press played at \(percent(lastImpact))."
    }

    private func percent(_ magnitude: Double) -> String { "\(Int(mapper.velocity(forImpact: magnitude) * 100)) percent" }
}
