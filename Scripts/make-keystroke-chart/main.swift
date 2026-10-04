// Renders docs/images/keystroke.svg: four presses (soft → slam) through Switchcraft's real impact
// filter, analyzer and velocity mapper. The presses are the synthetic keystroke model the unit
// tests use, shaped on a recording from a MacBook Air M5.
//
//   Scripts/make-keystroke-chart.sh   (compiles this with the SwitchcraftCore DSP sources)

import Foundation

let presses: [(name: String, strength: Double, color: String)] = [
    ("Soft", 0.006, "#A99BEA"), ("Medium", 0.012, "#7C67DA"), ("Hard", 0.026, "#4B2FB2"), ("Slam", 0.055, "#D9443B"),
]
let keyTime = 100.3
let window = CorrelationWindow()
let (fromMs, toMs) = (-20.0, 30.0)
let (width, height) = (820.0, 330.0)
let plot = (x: 56.0, y: 34.0, w: 560.0, h: 236.0)

var traces: [(name: String, color: String, points: [(Double, Double)], peak: (Double, Double), velocity: Double)] = []
var maxMg = 0.0
for press in presses {
    let filtered = SyntheticSignals.filter(SyntheticSignals.generate(duration: 0.5, events: [.keypress(at: keyTime, strength: press.strength)], seed: 7))
    var analyzer = ImpactAnalyzer(window: window)
    let m = analyzer.measure(keyTime: keyTime, samples: SyntheticSignals.window(filtered, keyTime: keyTime, window: window))
    let points = filtered.compactMap { s -> (Double, Double)? in
        let ms = (s.time - keyTime) * 1000
        return ms >= fromMs && ms <= toMs ? (ms, Double(s.dynamic) * 1000) : nil
    }
    maxMg = max(maxMg, points.map(\.1).max() ?? 0)
    traces.append((press.name, press.color, points, (m.peakOffset * 1000, m.peak * 1000), VelocityMapper().velocity(forImpact: m.magnitude)))
}
let top = (maxMg * 1.12 / 10).rounded(.up) * 10
func x(_ ms: Double) -> Double { plot.x + (ms - fromMs) / (toMs - fromMs) * plot.w }
func y(_ mg: Double) -> Double { plot.y + plot.h * (1 - mg / top) }
func f(_ v: Double) -> String { String(format: "%.1f", v) }

var svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(width)) \(Int(height))" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif">
<rect width="\(Int(width))" height="\(Int(height))" rx="12" fill="#FBFAFF"/>
<rect x="\(f(x(-window.preMs)))" y="\(f(plot.y))" width="\(f(x(window.postMs) - x(-window.preMs)))" height="\(f(plot.h))" fill="#6D44D6" fill-opacity="0.08"/>
<text x="\(f(x(-window.preMs)))" y="\(f(plot.y - 8))" font-size="11" fill="#5B4C8A">listening window −\(Int(window.preMs)) … +\(Int(window.postMs)) ms</text>

"""
for tick in stride(from: 0.0, through: top, by: top / 4) {
    svg += "<line x1=\"\(f(plot.x))\" x2=\"\(f(plot.x + plot.w))\" y1=\"\(f(y(tick)))\" y2=\"\(f(y(tick)))\" stroke=\"#E4E0F2\"/>\n"
    svg += "<text x=\"\(f(plot.x - 8))\" y=\"\(f(y(tick) + 4))\" font-size=\"11\" fill=\"#6E6880\" text-anchor=\"end\">\(Int(tick))</text>\n"
}
for ms in stride(from: fromMs, through: toMs, by: 10) {
    svg += "<text x=\"\(f(x(ms)))\" y=\"\(f(plot.y + plot.h + 18))\" font-size=\"11\" fill=\"#6E6880\" text-anchor=\"middle\">\(ms > 0 ? "+" : "")\(Int(ms)) ms</text>\n"
}
svg += "<text x=\"16\" y=\"\(f(plot.y + plot.h / 2))\" font-size=\"11\" fill=\"#6E6880\" transform=\"rotate(-90 16 \(f(plot.y + plot.h / 2)))\" text-anchor=\"middle\">impact (mg)</text>\n"
svg += "<line x1=\"\(f(x(0)))\" x2=\"\(f(x(0)))\" y1=\"\(f(plot.y))\" y2=\"\(f(plot.y + plot.h))\" stroke=\"#2EA44F\" stroke-width=\"1.5\" stroke-dasharray=\"4 3\"/>\n"
svg += "<text x=\"\(f(x(0) + 5))\" y=\"\(f(plot.y + 14))\" font-size=\"11\" fill=\"#2EA44F\">key event</text>\n"
for trace in traces {
    let path = trace.points.enumerated().map { "\($0.offset == 0 ? "M" : "L")\(f(x($0.element.0))) \(f(y($0.element.1)))" }.joined(separator: " ")
    svg += "<path d=\"\(path)\" fill=\"none\" stroke=\"\(trace.color)\" stroke-width=\"1.8\" stroke-linejoin=\"round\"/>\n"
    svg += "<circle cx=\"\(f(x(trace.peak.0)))\" cy=\"\(f(y(trace.peak.1)))\" r=\"3.5\" fill=\"\(trace.color)\"/>\n"
}
// Legend: what each press became.
svg += "<text x=\"640\" y=\"40\" font-size=\"12\" font-weight=\"600\" fill=\"#2A2140\">press → velocity</text>\n"
for (i, trace) in traces.enumerated() {
    let rowY = 66.0 + Double(i) * 30
    let tier = VelocityMapper.layer(for: trace.velocity).displayName.lowercased()
    svg += "<rect x=\"640\" y=\"\(f(rowY - 9))\" width=\"14\" height=\"4\" rx=\"2\" fill=\"\(trace.color)\"/>\n"
    svg += "<text x=\"662\" y=\"\(f(rowY - 3))\" font-size=\"12\" fill=\"#2A2140\">\(trace.name)</text>\n"
    svg += "<text x=\"662\" y=\"\(f(rowY + 12))\" font-size=\"11\" fill=\"#6E6880\">\(String(format: "%.2f", trace.velocity)) · \(tier) layer</text>\n"
}
svg += "<text x=\"640\" y=\"200\" font-size=\"11\" fill=\"#6E6880\">The finger strike starts before</text>\n"
svg += "<text x=\"640\" y=\"215\" font-size=\"11\" fill=\"#6E6880\">macOS reports the key; the</text>\n"
svg += "<text x=\"640\" y=\"230\" font-size=\"11\" fill=\"#6E6880\">bottom-out lands ~7 ms after.</text>\n"
svg += "</svg>\n"
try svg.write(toFile: CommandLine.arguments.dropFirst().first ?? "docs/images/keystroke.svg", atomically: true, encoding: .utf8)
print("Wrote keystroke chart: " + traces.map { "\($0.name) \(String(format: "%.2f", $0.velocity))" }.joined(separator: ", "))
