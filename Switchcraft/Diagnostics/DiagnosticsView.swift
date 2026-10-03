import SwiftUI
import UniformTypeIdentifiers
import SwitchcraftCore

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var sensorTestResult: String?
    @State private var testRunning = false
    @State private var copied = false
    @State private var showingTips = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.settings.showDebugGraph {
                        GroupBox("Live signal (last 2 s)") {
                            ImpactGraphView(model: model).frame(height: 200).padding(4)
                        }
                    }
                    // Text refreshes at 10 Hz, independent of the ~800 Hz sensor.
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        ReportGrid(report: DiagnosticsReport(model: model))
                    }
                    if let sensorTestResult {
                        GroupBox("Sensor test") {
                            Text(sensorTestResult).font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                Button(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc") { copy() }
                    .help("Copies the report. It contains no typed text and no key codes.")
                Button("Export Diagnostics…") { export() }
                Button("Troubleshooting", systemImage: "questionmark.circle") { showingTips.toggle() }
                    .labelStyle(.iconOnly)
                    .help("Troubleshooting tips")
                    .popover(isPresented: $showingTips, arrowEdge: .top) { TroubleshootingTips() }
                Spacer()
                Button(testRunning ? "Testing…" : "Run Sensor Test") { Task { await runSensorTest() } }
                    .disabled(testRunning)
                    .help("Three hands-off seconds: measures the sensor's rate and background vibration.")
                Menu("Actions") {
                    Button("Restart Audio Engine") { model.restartAudio() }
                    Button("Restart Sensor") { model.restartSensor() }
                    Button("Reset Counters") { model.pipeline.stats.reset() }
                }
                .fixedSize()
            }
            .padding(12)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 420, idealHeight: 640)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DiagnosticsReport(model: model, forExport: true).text, forType: .string)
        copied = true
        AccessibilityNotification.Announcement("Diagnostics copied").post()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Switchcraft Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticsReport(model: model, forExport: true).text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            sensorTestResult = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Three seconds of hands-off streaming: rate, noise floor and peaks, from the ring buffer.
    private func runSensorTest() async {
        testRunning = true
        defer { testRunning = false }
        guard model.hardware.accelerometerPresent else {
            sensorTestResult = "No compatible accelerometer on this Mac (UNSUPPORTED_SENSOR)."
            return
        }
        model.requireSensor("sensor-test", true)
        defer { model.requireSensor("sensor-test", false) }
        try? await Task.sleep(for: .milliseconds(300))
        let startCount = model.sensor.totalReports
        let start = MonotonicClock.now()
        sensorTestResult = "Keep your hands off the Mac for 3 seconds…"
        try? await Task.sleep(for: .seconds(3))
        let elapsed = MonotonicClock.now() - start
        let count = model.sensor.totalReports - startCount
        var samples: [FilteredSample] = []
        model.sensor.ring.copy(from: start, to: .infinity, into: &samples)
        guard count > 0, !samples.isEmpty else {
            sensorTestResult = "FAILED: no samples in \(String(format: "%.1f", elapsed)) s. State: \(model.displayedSensorState.displayName) (\(model.displayedSensorState.rawValue)). \(model.sensorMessage ?? "")"
            return
        }
        let dynamics = samples.map { Double($0.dynamic) }.sorted()
        let magnitudes = samples.map { Double($0.rawMagnitude) }
        let meanG = magnitudes.reduce(0, +) / Double(magnitudes.count)
        sensorTestResult = """
        PASSED
        Reports:        \(count) in \(String(format: "%.2f", elapsed)) s → \(String(format: "%.1f", Double(count) / elapsed)) Hz
        Gravity |a|:    \(String(format: "%.4f", meanG)) g (expect ≈ 1.0)
        Dynamic p50:    \(String(format: "%.3f", dynamics[dynamics.count / 2] * 1000)) mg
        Dynamic p99:    \(String(format: "%.3f", dynamics[dynamics.count * 99 / 100] * 1000)) mg
        Dynamic max:    \(String(format: "%.3f", (dynamics.last ?? 0) * 1000)) mg
        Noise floor:    \(String(format: "%.3f", Double(samples.last?.floor ?? 0) * 1000)) mg
        """
    }
}

private struct ReportGrid: View {
    let report: DiagnosticsReport

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 16) {
            ForEach(report.sections) { section in
                GroupBox(section.title) {
                    Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            GridRow(alignment: .firstTextBaseline) {
                                Text(row.0).foregroundStyle(.secondary).frame(width: 128, alignment: .leading)
                                Text(row.1).monospacedDigit().textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// The essentials of docs/TROUBLESHOOTING.md, inside the app.
private struct TroubleshootingTips: View {
    private let tips: [(String, String)] = [
        ("No sound when typing", "Check Input Monitoring in System Settings › Privacy & Security. After installing a new build, remove Switchcraft from that list and add it again."),
        ("Silent in one app", "Password fields hide keystrokes from every app, and apps on the Exclusions list are muted on purpose."),
        ("Every key sounds the same", "Measure with the accelerometer (Settings › Typing Force), then calibrate. A soft surface like a lap absorbs the impact; a desk works best."),
        ("Sounds feel late", "Lower “Listen after the key” in Typing Force › Advanced. Bluetooth headphones add their own delay."),
        ("Apps still beep", "Turn on “Silence the invalid key beep” in General. The first key of a burst can occasionally beat it."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(tips, id: \.0) { title, detail in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
