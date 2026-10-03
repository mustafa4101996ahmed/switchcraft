import Observation
import SwiftUI
import SwitchcraftCore

/// Quiet noise measurement, then soft / normal / hard presses; fits a `Calibration` from medians.
@MainActor @Observable
final class CalibrationSession {
    enum Phase: Equatable { case ready, quiet, soft, normal, hard, review }

    static let pressesPerPhase = 8

    private(set) var phase: Phase = .ready {
        didSet { if phase != oldValue { announce() } }
    }
    private(set) var soft: [Double] = []
    private(set) var normal: [Double] = []
    private(set) var hard: [Double] = []
    private(set) var noiseFloor = Calibration.factoryDefault.noiseFloor
    private(set) var result: Calibration?
    private(set) var errorMessage: String?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var active = false

    var isRunning: Bool { [.quiet, .soft, .normal, .hard].contains(phase) }

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
            errorMessage = "The typing-force sensor isn't sending data (\(model.displayedSensorState.displayName)). Diagnostics can test it."
            phase = .review
            return
        }
        noiseFloor = floors.sorted()[floors.count / 2]
        phase = .soft
    }

    func record(_ measurement: ImpactMeasurement) {
        guard active, measurement.outcome == .detected else { return }
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
        stop()
    }

    func save() {
        if let result { model?.settings.calibration = result }
        stop()
    }

    /// Back to the start, nothing saved.
    func cancel() {
        stop()
        phase = .ready
    }

    func stop() {
        guard active else { return }
        active = false
        model?.endCalibration()
    }

    private func announce() {
        let text: String
        switch phase {
        case .quiet: text = "Keep your hands still"
        case .soft: text = "Now type softly"
        case .normal: text = "Now type normally"
        case .hard: text = "Now type hard"
        case .review: text = result != nil ? "Calibration complete" : "Calibration didn't finish"
        case .ready: return
        }
        AccessibilityNotification.Announcement(text).post()
    }
}

struct CalibrationView: View {
    @Environment(AppModel.self) private var model
    /// Inside onboarding the step header already names the task.
    var embedded = false
    var onRunningChange: (Bool) -> Void = { _ in }
    var onFinish: () -> Void = {}
    @State private var session = CalibrationSession()
    @State private var practice = ""
    @FocusState private var practiceFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.phase {
            case .ready: ready
            case .quiet:
                Label("Hands off the keyboard for two seconds…", systemImage: "hand.raised")
                ProgressView().controlSize(.small)
            case .soft, .normal, .hard: pressStep
            case .review: review
            }
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 480, alignment: .leading)
        .onChange(of: session.isRunning) { onRunningChange(session.isRunning) }
        .onDisappear { session.stop() }
    }

    @ViewBuilder
    private var ready: some View {
        if !embedded {
            Text("Teach Switchcraft how hard you type").font(.title3.weight(.semibold))
        }
        Text("Type a few keys softly, then normally, then hard. Switchcraft learns your range so soft presses sound soft and hard presses sound hard. Nothing you type is kept.")
            .fixedSize(horizontal: false, vertical: true)
        if model.hardware.accelerometerPresent {
            Button("Start Calibration") { session.start(model: model) }
                .keyboardShortcut(.defaultAction)
        } else {
            StatusLabel(kind: .warning, text: "This Mac has no typing-force sensor, so every key plays at one strength.")
        }
    }

    private var pressStep: some View {
        let instruction: String
        switch session.phase {
        case .soft: instruction = "Type softly, one key at a time"
        case .normal: instruction = "Now type normally"
        default: instruction = "Now type hard"
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(instruction).font(.title3.weight(.semibold))
            ProgressView(value: Double(session.count), total: Double(CalibrationSession.pressesPerPhase)) {
                Text("\(session.count) of \(CalibrationSession.pressesPerPhase) presses")
            }
            TextField("Type here", text: $practice)
                .textFieldStyle(.roundedBorder)
                .focused($practiceFocused)
                .onSubmit {} // Return is just another key press here, never a button.
                .onAppear { practiceFocused = true }
                .onChange(of: session.phase) { practice = "" }
            TypingForceMeter()
            Text("A press too light to feel isn't counted. If the number doesn't move, press a little firmer.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel") { session.cancel() }
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var review: some View {
        if let result = session.result {
            StatusLabel(kind: .good, text: "Calibrated").font(.title3.weight(.semibold))
            Text("Your soft, normal and hard presses now land in their own parts of the range. Type a few keys to hear it.")
                .fixedSize(horizontal: false, vertical: true)
            ResponseCurveView(mapper: VelocityMapper(calibration: result, curve: model.settings.curve))
                .frame(height: 110)
            TypingForceMeter()
            DisclosureGroup("Measured impacts") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    detail("Background vibration", result.noiseFloor)
                    detail("Soft", result.soft)
                    detail("Normal", result.normal)
                    detail("Hard", result.hard)
                }
                .padding(.top, 4)
            }
            HStack {
                Button("Redo") { session.start(model: model) }
                Spacer()
                Button("Save") {
                    session.save()
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
            }
        } else {
            StatusLabel(kind: .warning, text: "Calibration didn't finish").font(.title3.weight(.semibold))
            Text(session.errorMessage ?? "Something interrupted it.").fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Try Again") { session.start(model: model) }
                Button("Open Diagnostics…") { model.windows.show(.diagnostics, model: model) }
                Spacer()
                Button(embedded ? "Skip" : "Close") {
                    session.cancel()
                    onFinish()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func detail(_ title: String, _ value: Double) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(String(format: "%.1f mg", value * 1000)).monospacedDigit()
        }
    }
}
