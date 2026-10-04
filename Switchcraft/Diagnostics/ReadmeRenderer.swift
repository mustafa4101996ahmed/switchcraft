#if DEBUG
import AppKit
import SwiftUI
import SwitchcraftCore

/// Debug-only: renders the README images from the real views, in memory.
///   Switchcraft.app/Contents/MacOS/Switchcraft --render-readme <dir>
@MainActor
enum ReadmeRenderer {
    /// While set, the force meter shows this level instead of live data (README stills only).
    static var demoLevel: Double?

    static func run(model: AppModel, to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.library.reload()
        model.loadSelectedPack()
        model.startOrStopKeyboard() // real "Listening" status; no audio engine runs in this mode
        model.requireSensor("readme", true)
        try? await Task.sleep(for: .seconds(1.5))
        model.sensorChanged(model.sensor.state, model.sensor.message)
        demoLevel = 0.71

        SnapshotRenderer.render(HeroImage().environment(model).environment(\.controlActiveState, .key),
                                size: CGSize(width: 1200, height: 680), appearance: .aqua,
                                to: directory.appendingPathComponent("hero.png"))
        SnapshotRenderer.render(InstallImage().environment(\.controlActiveState, .key),
                                size: CGSize(width: 760, height: 540), appearance: .aqua,
                                to: directory.appendingPathComponent("install.png"))
        model.keyboard.stop()
        model.requireSensor("readme", false)
        print("Rendered README images to \(directory.path)")
        exit(0)
    }
}

/// A macOS-style window frame around a view (README stills only).
private struct WindowFrame<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                    Spacer()
                }
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 18)
        .fixedSize() // as wide as its content, not the space available
    }
}

private struct HeroImage: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.43, green: 0.27, blue: 0.84), Color(red: 0.12, green: 0.06, blue: 0.28)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(alignment: .top, spacing: -14) {
                MenuBarView()
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 28, y: 16)
                    .zIndex(1)
                    .padding(.top, 70)
                WindowFrame(title: "Sound") {
                    SoundSettingsView().frame(width: 620, height: 500)
                }
                .padding(.top, 40)
            }
        }
        .frame(width: 1200, height: 680)
    }
}

private struct InstallImage: View {
    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.95, blue: 0.99)
            WindowFrame(title: "Switchcraft") {
                ZStack(alignment: .topLeading) {
                    if let background = NSImage(contentsOfFile: "build/dmg/background@2x.png") {
                        Image(nsImage: background).resizable().frame(width: 660, height: 400)
                    }
                    icon(NSImage(named: "AppIcon") ?? NSApp.applicationIconImage, label: "Switchcraft", center: CGPoint(x: 170, y: 160))
                    icon(NSWorkspace.shared.icon(forFile: "/Applications"), label: "Applications", center: CGPoint(x: 490, y: 160))
                }
                .frame(width: 660, height: 400)
            }
        }
        .frame(width: 760, height: 540)
    }

    private func icon(_ image: NSImage, label: String, center: CGPoint) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: image).resizable().frame(width: 112, height: 112)
            Text(label).font(.system(size: 13))
        }
        .position(x: center.x, y: center.y + 18)
    }
}
#endif
