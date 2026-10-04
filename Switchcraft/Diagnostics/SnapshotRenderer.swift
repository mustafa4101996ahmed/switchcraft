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

        let pane = { (p: SettingsPane) in AnyView(p.view.frame(width: SettingsPane.size.width, height: SettingsPane.size.height)) }
        let surfaces: [(String, AnyView, CGSize?)] = [
            ("menubar", AnyView(MenuBarView()), nil),
            ("diagnostics", AnyView(DiagnosticsView()), CGSize(width: 680, height: 640)),
            ("calibration", AnyView(CalibrationView()), nil),
        ] + SettingsPane.allCases.map { ("settings-\($0.rawValue)", pane($0), nil) }
          + OnboardingView.Step.allCases.enumerated().map { index, step in
            ("onboarding-\(index)-\(step.rawValue)", AnyView(OnboardingView(step: step)), nil)
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

    static func render(_ view: some View, size: CGSize?, appearance: NSAppearance.Name, to url: URL) {
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
