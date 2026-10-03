import AppKit
import SwiftUI
import SwitchcraftCore

@main
struct SwitchcraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.model.windows.show(.settings, model: delegate.model) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        BrandIcon.menuBarImage(model.menuBarSymbolName)
            .accessibilityLabel("Switchcraft")
            .accessibilityValue(model.listeningStatus.text)
    }
}

/// The Switchcraft glyph (Resources/MenuBarIcon*.png, drawn by Scripts/make-icon.swift) or an SF Symbol.
@MainActor
enum BrandIcon {
    static let glyph: NSImage = {
        let image = NSImage(named: "MenuBarIcon") ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = "Switchcraft switch"
        return image
    }()

    static func menuBarImage(_ symbol: String) -> Image {
        symbol == SettingsStore.brandSymbol ? Image(nsImage: glyph) : Image(systemName: symbol)
    }

    /// Straight from the bundle: `NSApp.applicationIconImage` can come from a stale icon cache.
    static var appIcon: Image { Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-snapshots"), index + 1 < CommandLine.arguments.count {
            Task { await SnapshotRenderer.run(model: model, to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            return
        }
        // Opens one real window without starting the keyboard tap or audio (visual checks).
        if let index = CommandLine.arguments.firstIndex(of: "--show-window"), index + 1 < CommandLine.arguments.count,
           let kind = WindowCoordinator.Kind(rawValue: CommandLine.arguments[index + 1]) {
            model.library.reload()
            model.windows.show(kind, model: model)
            return
        }
        #endif
        model.start()
    }

    /// Opening the app again (Finder, Spotlight) shows Settings, since there's no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.windows.show(.settings, model: model)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
