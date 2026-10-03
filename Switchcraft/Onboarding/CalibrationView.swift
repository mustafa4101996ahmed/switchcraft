import Observation
import SwiftUI
import SwitchcraftCore

/// Quiet noise measurement, then soft / normal / hard presses; fits a `Calibration` from medians.
@MainActor @Observable
final class CalibrationSession {
    enum Phase: Equatable { case ready, quiet, soft, normal, hard, review }

    static let pressesPerPhase = 8

    private(set) var phase: Phase = .ready
    private(set) var soft: [Double] = []
    private(set) var normal: [Double] = []
    private(set) var hard: [Double] = []
    private(set) var noiseFloor = Calibration.factoryDefault.noiseFloor
    private(set) var lastMagnitude: Double?
    private(set) var result: Calibration?
    private(set) var errorMessage: String?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var active = false

    var count: Int {
        switch phase {
        case .soft: return soft.count
        case .normal: return normal.count
        case .hard: return hard.count
        default: return 0
        }
    }

    func start(model: AppModel) {
        self.model = model
        soft = []
        normal = []
        hard = []
        result = nil
        errorMessage = nil
        lastMagnitude = nil
        active = true
        model.beginCalibration(self)
        phase = .quiet
        Task { await measureQuietFloor(model) }
    }

    private func measureQuietFloor(_ model: AppModel) async {
        var floors: [Double] = []
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if let latest = model.sensor.ring.latest, MonotonicClock.now() - latest.time < 0.5 {
                floors.append(Double(latest.floor))
            }
        }
        guard active else { return }
        guard !floors.isEmpty else {
            errorMessage = "The accelerometer isn't delivering data (\(model.displayedSensorState.rawValue)). Calibration needs a readable sensor."
            phase = .review
            return
        }
        noiseFloor = floors.sorted()[floors.count / 2]
        phase = .soft
    }

    func record(_ measurement: ImpactMeasurement) {
        guard active, measurement.outcome == .detected else { return }
        lastMagnitude = measurement.magnitude
        switch phase {
        case .soft:
            soft.append(measurement.magnitude)
            if soft.count >= Self.pressesPerPhase { phase = .normal }
        case .normal:
            normal.append(measurement.magnitude)
            if normal.count >= Self.pressesPerPhase { phase = .hard }
        case .hard:
            hard.append(measurement.magnitude)
            if hard.count >= Self.pressesPerPhase { finish() }
        default:
            break
        }
    }

    private func finish() {
        do {
            result = try Calibration.fit(noiseFloor: noiseFloor, soft: soft, normal: normal, hard: hard)
        } catch {
            errorMessage = error.localizedDescription
        }
        phase = .review
    }

    func save() {
        if let result { model?.settings.calibration = result }
        stop()
    }

    func stop() {
        guard active else { return }
        active = false
        model?.endCalibration()
    }
}

struct CalibrationView: View {
    @Environment(AppModel.self) private var model
    var onFinish: () -> Void = {}
    @State private var session = CalibrationSession()
    @State private var practice = ""
    @FocusState private var practiceFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.phase {
            case .ready:
                Text("Teach Switchcraft how hard you type").font(.title3.weight(.semibold))
                Text("You'll type a few keys softly, normally and hard. Switchcraft measures the vibration each press makes in the MacBook's chassis. Nothing you type is kept.")
                    .foregroundStyle(.secondary)
                if !model.hardware.accelerometerPresent {
                    Label("This Mac has no compatible accelerometer, so calibration isn't available. Use Fixed velocity instead.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button("Start Calibration") { session.start(model: model) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hardware.accelerometerPresent)
            case .quiet:
                Label("Keep your hands off the Mac for two seconds…", systemImage: "hand.raised")
                ProgressView().controlSize(.small)
            case .soft, .normal, .hard:
                pressStep
            case .review:
                review
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .onDisappear { session.stop() }
    }

    private var pressStep: some View {
        let instruction: String
        switch session.phase {
        case .soft: instruction = "Type softly, one key at a time"
        case .normal: instruction = "Now type normally"
        default: instruction = "Now type hard"
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text(instruction).font(.title3.weight(.semibold))
            ProgressView(value: Double(session.count), total: Double(CalibrationSession.pressesPerPhase)) {
                Text("\(session.count) of \(CalibrationSession.pressesPerPhase) presses detected")
            }
            TextField("Type here", text: $practice)
                .textFieldStyle(.roundedBorder)
                .focused($practiceFocused)
                .onAppear { practiceFocused = true }
                .onChange(of: session.phase) { practice = "" }
            if let last = session.lastMagnitude {
                Text(String(format: "Last impact: %.1f mg", last * 1000)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("Presses below the noise floor aren't counted — press a little firmer if the count doesn't move.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Cancel") {
                session.stop()
                onFinish()
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result = session.result {
                Text("Calibration complete").font(.title3.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Noise floor", result.noiseFloor)
                    row("Soft", result.soft)
                    row("Normal", result.normal)
                    row("Hard", result.hard)
                }
                HStack {
                    Button("Save") {
                        session.save()
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Redo") { session.start(model: model) }
                }
            } else {
                Text("Calibration didn't finish").font(.title3.weight(.semibold))
                Text(session.errorMessage ?? "Unknown error").foregroundStyle(.secondary)
                HStack {
                    Button("Try Again") { session.start(model: model) }
                    Button("Close") {
                        session.stop()
                        onFinish()
                    }
                }
            }
        }
    }

    private func row(_ title: String, _ value: Double) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(String(format: "%.2f mg", value * 1000)).monospacedDigit()
        }
    }
}
