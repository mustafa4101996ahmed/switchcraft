import SwiftUI
import SwitchcraftCore

/// Live debug graph: raw magnitude, filtered impulse signal, detection threshold, key events,
/// correlation windows and detected impacts. Redraws at ≤ 30 fps by copying the ring buffer;
/// the sensor thread is never touched or slowed down.
struct ImpactGraphView: View {
    let model: AppModel
    @State private var buffer = GraphBuffer()

    var body: some View {
        // Legend and plot refresh together (the scale label follows the data).
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                legendItem(.gray, "raw |a| − 1 g")
                legendItem(.accentColor, "filtered")
                legendItem(.orange, "threshold")
                legendItem(.green, "key event")
                legendItem(.red, "impact")
                Spacer()
                Text(buffer.scaleLabel).foregroundStyle(.secondary)
            }
            .font(.caption)
            .accessibilityHidden(true)
            Canvas { context, size in draw(in: &context, size: size) }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement()
            .accessibilityLabel("Live accelerometer graph")
            .accessibilityValue(buffer.summary)
        }
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 12, height: 3)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        model.sensor.ring.copyLatest(1800, into: &buffer.samples)
        let samples = buffer.samples
        guard let last = samples.last, MonotonicClock.now() - last.time < 1 else {
            buffer.summary = "No sensor data"
            context.draw(Text("No sensor data (\(model.displayedSensorState.displayName))").foregroundStyle(.secondary),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let end = last.time, span = 2.0, start = end - span
        let stats = model.pipeline.stats.snapshot(now: end)
        let settings = model.settings
        let peak = samples.reduce(Float(0)) { max($0, $1.dynamic, abs($1.rawMagnitude - 1)) }
        let scale = max(Double(peak) * 1.15, 0.01)
        buffer.scaleLabel = String(format: "%.0f mg full scale (√)", scale * 1000)
        buffer.summary = "\(stats.recentImpacts.filter { $0.time > start }.count) impacts and \(stats.recentKeyTimes.filter { $0 > start }.count) key presses in the last 2 seconds"

        let top: CGFloat = 4
        func x(_ t: Double) -> CGFloat { CGFloat((t - start) / span) * size.width }
        // Square-root axis keeps soft keystrokes visible next to desk bumps.
        func y(_ v: Double) -> CGFloat { top + (size.height - top) * (1 - CGFloat((max(v, 0) / scale).squareRoot())) }

        for keyTime in stats.recentKeyTimes where keyTime > start {
            let window = CGRect(x: x(keyTime - settings.window.pre), y: 0,
                                width: x(keyTime + settings.window.post) - x(keyTime - settings.window.pre), height: size.height)
            context.fill(Path(window), with: .color(.green.opacity(0.1)))
            var marker = Path()
            marker.move(to: CGPoint(x: x(keyTime), y: 0))
            marker.addLine(to: CGPoint(x: x(keyTime), y: size.height))
            context.stroke(marker, with: .color(.green), lineWidth: 1)
        }

        var raw = Path(), filtered = Path(), threshold = Path()
        for s in samples where s.time >= start {
            let px = x(s.time)
            let points = (CGPoint(x: px, y: y(Double(abs(s.rawMagnitude - 1)))),
                          CGPoint(x: px, y: y(Double(s.dynamic))),
                          CGPoint(x: px, y: y(Double(s.floor) * settings.detectionSNR)))
            if raw.isEmpty {
                raw.move(to: points.0)
                filtered.move(to: points.1)
                threshold.move(to: points.2)
            } else {
                raw.addLine(to: points.0)
                filtered.addLine(to: points.1)
                threshold.addLine(to: points.2)
            }
        }
        context.stroke(raw, with: .color(.secondary), lineWidth: 1)
        context.stroke(filtered, with: .color(.accentColor), lineWidth: 1.5)
        context.stroke(threshold, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        for impact in stats.recentImpacts where impact.time > start {
            let center = CGPoint(x: x(impact.time), y: y(impact.peak))
            context.stroke(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(.red), lineWidth: 1.5)
        }
    }
}

/// Reused across frames so drawing doesn't allocate a new array 30 times a second.
private final class GraphBuffer {
    var samples: [FilteredSample]
    var scaleLabel = ""
    var summary = "No sensor data"

    init() {
        samples = []
        samples.reserveCapacity(2048)
    }
}
