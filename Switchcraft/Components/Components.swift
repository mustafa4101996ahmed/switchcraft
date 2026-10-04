import SwiftUI
import SwitchcraftCore

extension Color {
    /// "#RRGGBB" → Color; nil for anything else.
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// The switch's stem colour, as a small dot. The hairline keeps black and white stems visible on
/// any background.
struct StemSwatch: View {
    let hex: String?
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Color(hex: hex) ?? .secondary)
            .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Status with colour carried by the symbol only, so the text keeps full contrast.
struct StatusLabel: View {
    enum Kind {
        case good, warning, neutral

        var symbol: String {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .neutral: return "minus.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .good: return .green
            case .warning: return .orange
            case .neutral: return .secondary
            }
        }
    }

    let kind: Kind
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: kind.symbol).foregroundStyle(kind.tint)
        }
    }
}

/// Menu-like row: full-width hit area, hover and pressed highlight, fixed icon column.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(FixedIconLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(configuration.isPressed ? AnyShapeStyle(.tertiary) : hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Icons in one 18 pt column so labels line up whatever the symbol's width.
struct FixedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 18, alignment: .center)
            configuration.title
        }
    }
}

/// Live typing force: the last key's velocity on the soft → slam scale, fading after the press.
/// Makes the product's core idea visible: press harder and the bar jumps further.
struct TypingForceMeter: View {
    @Environment(AppModel.self) private var model
    var showsCaption = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let reading = currentReading()
            meter(level: reading.level, velocity: reading.velocity, recent: reading.recent)
        }
    }

    private func currentReading() -> (level: Double, velocity: Double, recent: Bool) {
        #if DEBUG
        if let demo = ReadmeRenderer.demoLevel { return (demo, demo, true) }
        #endif
        let now = MonotonicClock.now()
        let snapshot = model.pipeline.stats.snapshot(now: now)
        let age = snapshot.recentKeyTimes.last.map { now - $0 } ?? .infinity
        let velocity = snapshot.lastVelocity ?? 0
        let level = age.isFinite ? velocity * exp(-max(age - 0.12, 0) / 0.45) : 0
        return (level, velocity, age < 3)
    }

    private func meter(level: Double, velocity: Double, recent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, proxy.size.width * min(level, 1)))
                    ForEach(1..<4) { tier in
                        Rectangle()
                            .fill(.background.opacity(0.9))
                            .frame(width: 1.5)
                            .offset(x: proxy.size.width * Double(tier) / 4)
                    }
                }
            }
            .frame(height: 8)
            if showsCaption {
                HStack {
                    ForEach(VelocityLayer.allCases, id: \.self) { layer in
                        Text(layer.displayName)
                            .fontWeight(recent && VelocityMapper.layer(for: velocity) == layer ? .semibold : .regular)
                            .foregroundStyle(recent && VelocityMapper.layer(for: velocity) == layer ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: layer == .soft ? .leading : layer == .slam ? .trailing : .center)
                    }
                }
                .font(.caption)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Typing force")
        .accessibilityValue(recent ? "\(VelocityMapper.layer(for: velocity).displayName), \(Int(velocity * 100)) percent" : "No recent key press")
    }
}
