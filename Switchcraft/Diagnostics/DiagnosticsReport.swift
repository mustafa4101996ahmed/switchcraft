import Carbon
import Foundation
import SwitchcraftCore

/// Everything Diagnostics shows, as label/value rows. Contains key codes and groups only —
/// never characters. The exported text omits even the last key code.
@MainActor
struct DiagnosticsReport {
    struct Section: Identifiable {
        let title: String
        let rows: [(String, String)]
        var id: String { title }
    }

    let sections: [Section]

    init(model: AppModel, forExport: Bool = false) {
        let now = MonotonicClock.now()
        let stats = model.pipeline.stats.snapshot(now: now)
        let mixer = model.audio.mixer.stats
        let hw = model.hardware
        let latest = model.sensor.ring.latest
        let m = stats.lastMeasurement
        let settings = model.settings

        func mg(_ value: Double?) -> String { value.map { String(format: "%.2f mg", $0 * 1000) } ?? "—" }
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "—" }
        func g(_ value: Float?) -> String { value.map { String(format: "%+.4f g", $0) } ?? "—" }

        let ioFrames = model.audio.ioBufferFrames
        let outputRate = model.audio.outputSampleRate
        let outputLatencyMs = model.audio.presentationLatency * 1000
        let totalEstimate = mixer.averageKeyToRenderMs.map { $0 + outputLatencyMs }
        let fresh = latest.map { now - $0.time < 0.5 } ?? false

        var keyboardRows: [(String, String)] = [
            ("Listener", model.keyboardRunning ? "Running (listen-only event tap)" : "Stopped"),
            ("Permission", model.permissions.inputMonitoringGranted ? "Input Monitoring allowed" : "Input Monitoring not allowed"),
            ("Secure input", Self.secureInputRow(model.permissions.secureInput)),
            ("Events/sec", "\(stats.eventsPerSecond)"),
        ]
        if !forExport {
            keyboardRows.append(("Last key code", stats.lastKeyCode.map { "\($0)" } ?? "—"))
        }
        keyboardRows += [
            ("Last key group", stats.lastGroup?.displayName ?? "—"),
            ("Event delivery delay", ms(stats.lastDeliveryMs)),
            ("Keys processed", "\(stats.totalKeys)"),
            ("Muted by exclusions", "\(stats.mutedEvents)"),
        ]

        let helperConnection: String
        switch model.displayedSensorState {
        case .supported: helperConnection = "Direct IOKit HID access, no privileges"
        case .permissionRequired: helperConnection = "Direct access failed: try Restart Sensor, then Run Sensor Test"
        default: helperConnection = "—"
        }

        sections = [
            Section(title: "System", rows: [
                ("macOS", hw.osVersion),
                ("Mac model", hw.modelIdentifier),
                ("CPU", hw.cpuBrand),
                ("Architecture", hw.architecture + (hw.isAppleSilicon ? " (Apple Silicon)" : "")),
                ("Portable", hw.isLaptop ? "Yes" : "No"),
                ("Built-in keyboard", hw.hasBuiltInKeyboard ? "Yes" : "No"),
            ]),
            Section(title: "Keyboard", rows: keyboardRows),
            Section(title: "Accelerometer", rows: [
                ("Device", hw.accelerometerPresent ? "AppleSPUHIDDevice (page 0xFF00, usage 3)" : "Not found"),
                ("Available", hw.accelerometerPresent ? "Yes" : "No"),
                ("Readable", "\(model.displayedSensorState.displayName) (\(model.displayedSensorState.rawValue))" + (model.sensorMessage.map { ": \($0)" } ?? "")),
                ("Sample rate", model.sensor.measuredSampleRate > 0 ? String(format: "%.1f Hz (measured)", model.sensor.measuredSampleRate) : "—"),
                ("Raw X", fresh ? g(latest?.x) : "—"),
                ("Raw Y", fresh ? g(latest?.y) : "—"),
                ("Raw Z", fresh ? g(latest?.z) : "—"),
                ("Filtered magnitude", fresh ? mg(latest.map { Double($0.dynamic) }) : "—"),
                ("Noise floor", fresh ? mg(latest.map { Double($0.floor) }) : "—"),
                ("Peak (last key)", mg(m?.peak)),
                ("Signal / floor", m.map { String(format: "%.1f×", $0.snr) } ?? "—"),
                ("Last outcome", m?.outcome.rawValue ?? "—"),
                ("Impact offset vs key", stats.offsetMedianMs.map { String(format: "median %+.1f ms, p90 %+.1f ms", $0, stats.offsetP90Ms ?? 0) } ?? "—"),
            ]),
            Section(title: "Typing force", rows: [
                ("Mode", settings.velocityMode.displayName),
                ("Impact", mg(m?.magnitude)),
                ("Mapped velocity", stats.lastVelocity.map { String(format: "%.3f", $0) } ?? "—"),
                ("Current tier", stats.lastVelocity.map { VelocityMapper.layer(for: $0).displayName } ?? "—"),
                ("Source", stats.lastVelocitySource),
                ("Sensitivity", String(format: "%.2f", settings.curve.sensitivity)),
                ("Calibration", settings.calibration.isUserCalibrated ? "User calibrated" : "Factory defaults"),
                ("Fallbacks used", "\(stats.fallbackEvents)"),
            ]),
            Section(title: "Audio", rows: [
                ("Engine", model.audio.isRunning ? "Running" : "Stopped" + (model.audio.lastError.map { " — \($0)" } ?? "")),
                ("Sound pack", model.activePackName ?? "—"),
                ("Sample rate", String(format: "%.0f Hz output, %.0f Hz internal", outputRate, SoundEngine.internalSampleRate)),
                ("Buffer duration", ioFrames > 0 && outputRate > 0 ? String(format: "%u frames (%.2f ms)", ioFrames, Double(ioFrames) / outputRate * 1000) : "—"),
                ("Active voices", "\(mixer.activeVoices) (peak \(mixer.peakVoices) of \(VoiceMixer.maxVoices))"),
                ("Key → sound scheduled", ms(stats.averageKeyToTriggerMs)),
                ("Key → audio render", ms(mixer.averageKeyToRenderMs)),
                ("Output device latency", String(format: "%.1f ms", outputLatencyMs)),
                ("Estimated latency", totalEstimate.map { String(format: "%.1f ms (key event → speaker)", $0) } ?? "—"),
                ("Dropped events", "\(stats.droppedEvents + mixer.droppedTriggers) dropped, \(mixer.stolenVoices) voices stolen"),
                ("Limiter", String(format: "%.1f dB", mixer.limiterReductionDb)),
            ]),
            Section(title: "Helper", rows: [
                ("Installed", "Not required"),
                ("Running", "—"),
                ("Version", "—"),
                ("Connection", helperConnection),
            ]),
        ]
    }

    private static func secureInputRow(_ holder: SecureInputHolder?) -> String {
        guard IsSecureEventInputEnabled() else { return "Off" }
        guard let holder else { return "Active (checking who holds it)" }
        let suffix = holder.isLockScreen ? ": the lock screen is stuck; lock and unlock with your password" : ": key presses are hidden until it's released"
        return "Active, held by \(holder.name) (PID \(holder.pid))" + suffix
    }

    var text: String {
        var lines = ["Switchcraft diagnostics — \(Date().formatted(date: .abbreviated, time: .standard))",
                     "Contains no typed text and no key history."]
        for section in sections {
            lines.append("")
            lines.append(section.title.uppercased())
            for (label, value) in section.rows { lines.append("\(label): \(value)") }
        }
        return lines.joined(separator: "\n")
    }
}
