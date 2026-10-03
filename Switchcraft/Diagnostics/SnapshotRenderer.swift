#if DEBUG
import AppKit
import SwiftUI
import SwitchcraftCore

/// Debug-only: renders every surface to PNG, light and dark, for design review.
///   Switchcraft.app/Contents/MacOS/Switchcraft --render-snapshots <dir>
/// Renders in-process (no screen-recording permission) and starts no keyboard tap or audio output.
@MainActor
enum SnapshotRenderer {
    static func run(model: AppModel, to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.library.reload()
        model.loadSelectedPack()
        model.requireSensor("snapshots", true)
        try? await Task.sleep(for: .seconds(2))
        model.sensorChanged(model.sensor.state, model.sensor.message) // start() normally wires this callback

        let surfaces: [(String, AnyView, CGSize?)] = [
            ("menubar", AnyView(MenuBarView()), nil),
            ("settings-general", AnyView(GeneralSettingsView().frame(width: 600, height: 520)), nil),
            ("settings-sound", AnyView(SoundSettingsView().frame(width: 600, height: 520)), nil),
            ("settings-typingforce", AnyView(TypingForceSettingsView().frame(width: 600, height: 520)), nil),
            ("settings-exclusions", AnyView(ExclusionsSettingsView().frame(width: 600, height: 520)), nil),
            ("settings-diagnostics", AnyView(DiagnosticsSummaryView().frame(width: 600, height: 520)), nil),
            ("settings-about", AnyView(AboutView().frame(width: 600, height: 520)), nil),
            ("settings-tabview", AnyView(SettingsView()), nil),
            ("diagnostics", AnyView(DiagnosticsView()), CGSize(width: 680, height: 900)),
            ("calibration", AnyView(CalibrationView()), nil),
        ] + OnboardingView.Step.allCases.map { step in
            ("onboarding-\(step.rawValue)-\(step.title.replacingOccurrences(of: " ", with: "-").lowercased())", AnyView(OnboardingView(step: step)), nil)
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for (surface, view, size) in surfaces {
                render(view.environment(model), size: size, appearance: appearance,
                       to: directory.appendingPathComponent("\(surface)-\(name).png"))
            }
        }
        print("Rendered \(surfaces.count * 2) snapshots to \(directory.path)")
        exit(0)
    }

    private static func render(_ view: some View, size: CGSize?, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        let frame = CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size ?? host.fittingSize)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
#endif
