import AppKit
import SwiftUI

/// Opens the utility windows on demand. AppKit-managed so nothing appears at launch on macOS 14
/// (SwiftUI `Window` scenes can't suppress their launch window before macOS 15).
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    enum Kind: String {
        case settings, diagnostics, onboarding, calibration

        var title: String {
            switch self {
            case .settings: return "General"
            case .diagnostics: return "Switchcraft Diagnostics"
            case .onboarding: return "Welcome to Switchcraft"
            case .calibration: return "Calibrate Typing Force"
            }
        }
    }

    var onVisibilityChange: ((Kind, Bool) -> Void)?
    private var windows: [Kind: NSWindow] = [:]

    func show(_ kind: Kind, model: AppModel) {
        if let window = windows[kind] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window: NSWindow
        switch kind {
        case .settings:
            window = NSWindow(contentViewController: settingsController(model: model))
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
        case .diagnostics:
            window = NSWindow(contentViewController: NSHostingController(rootView: DiagnosticsView().environment(model)))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 620, height: 420)
        case .onboarding:
            window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView().environment(model)))
            window.styleMask = [.titled, .closable, .miniaturizable]
        case .calibration:
            let view = CalibrationView(onFinish: { [weak self] in self?.close(.calibration) })
            window = NSWindow(contentViewController: NSHostingController(rootView: view.environment(model)))
            window.styleMask = [.titled, .closable, .miniaturizable]
        }
        window.title = kind.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !window.setFrameUsingName("Switchcraft." + kind.rawValue) { window.center() }
        window.setFrameAutosaveName("Switchcraft." + kind.rawValue)
        windows[kind] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        onVisibilityChange?(kind, true)
    }

    func close(_ kind: Kind) { windows[kind]?.close() }

    /// Toolbar-style tabs, the standard macOS Settings layout; the window title follows the tab.
    private func settingsController(model: AppModel) -> NSViewController {
        let tabs = SettingsTabController()
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: pane.view
                .frame(width: SettingsPane.size.width, height: SettingsPane.size.height)
                .environment(model))
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        return tabs
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = windows.first(where: { $0.value === window })?.key else { return }
        // Drop the window so its SwiftUI state (and any calibration session) is torn down.
        windows[kind] = nil
        onVisibilityChange?(kind, false)
    }
}

/// Keeps the Settings window titled after the selected pane, like System Settings-style panels.
private final class SettingsTabController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? "Settings"
    }
}
