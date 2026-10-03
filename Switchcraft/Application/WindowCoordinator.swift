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
            case .settings: return "Switchcraft Settings"
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
        let root: AnyView
        switch kind {
        case .settings: root = AnyView(SettingsView())
        case .diagnostics: root = AnyView(DiagnosticsView())
        case .onboarding: root = AnyView(OnboardingView())
        case .calibration: root = AnyView(CalibrationView(onFinish: { [weak self] in self?.close(.calibration) }))
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root.environment(model)))
        window.title = kind.title
        window.styleMask = kind == .diagnostics ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[kind] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        onVisibilityChange?(kind, true)
    }

    func close(_ kind: Kind) { windows[kind]?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = windows.first(where: { $0.value === window })?.key else { return }
        // Drop the window so its SwiftUI state (and any calibration session) is torn down.
        windows[kind] = nil
        onVisibilityChange?(kind, false)
    }
}
