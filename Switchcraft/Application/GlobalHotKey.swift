import Carbon
import SwitchcraftCore

/// ⌃⌥⌘K toggles Switchcraft from any app. Carbon hot keys need no permission and never see other
/// keystrokes: macOS only reports this one combination.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    static let display = "⌃⌥⌘K"

    func setEnabled(_ enabled: Bool, action: @escaping () -> Void) {
        self.action = action
        enabled ? register() : unregister()
    }

    private func register() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action?() }
            return noErr
        }, 1, &spec, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x5357_4346), id: 1) // "SWCF"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey | cmdKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { Log.app.error("Couldn't register \(Self.display, privacy: .public) (OSStatus \(status))") }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
