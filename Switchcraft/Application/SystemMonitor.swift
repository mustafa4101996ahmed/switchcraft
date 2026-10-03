import AppKit
import CoreAudio
import SwitchcraftCore

/// Sleep/wake, Fast User Switching, frontmost app (exclusions) and microphone activity.
@MainActor
final class SystemMonitor {
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    var onSessionActive: ((Bool) -> Void)?
    var onFrontmostChange: ((String?) -> Void)?
    var onMicrophoneChange: ((Bool) -> Void)?

    private(set) var microphoneInUse = false
    private var tokens: [NSObjectProtocol] = []
    private var micTimer: Timer?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observe(center, NSWorkspace.willSleepNotification) { $0.onSleep?() }
        observe(center, NSWorkspace.didWakeNotification) { $0.onWake?() }
        observe(center, NSWorkspace.sessionDidResignActiveNotification) { $0.onSessionActive?(false) }
        observe(center, NSWorkspace.sessionDidBecomeActiveNotification) { $0.onSessionActive?(true) }
        observe(center, NSWorkspace.didActivateApplicationNotification) {
            $0.onFrontmostChange?(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
        onFrontmostChange?(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Microphone polling only runs while "Mute while microphone is in use" is on.
    func setMicrophoneMonitoring(_ enabled: Bool) {
        micTimer?.invalidate()
        micTimer = nil
        guard enabled else {
            updateMicrophone(false)
            return
        }
        updateMicrophone(MicrophoneActivity.isAnotherProcessRecording())
        micTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMicrophone(MicrophoneActivity.isAnotherProcessRecording()) }
        }
    }

    private func updateMicrophone(_ inUse: Bool) {
        guard inUse != microphoneInUse else { return }
        microphoneInUse = inUse
        onMicrophoneChange?(inUse)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (SystemMonitor) -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        })
    }
}

/// Uses public CoreAudio properties only — no microphone permission and no audio is captured.
enum MicrophoneActivity {
    static func isAnotherProcessRecording() -> Bool {
        if #available(macOS 14.2, *) {
            return processes().contains { process in
                uint32(process, kAudioProcessPropertyIsRunningInput) != 0
                    && Int32(bitPattern: uint32(process, kAudioProcessPropertyPID)) != getpid()
            }
        }
        // Older systems: is the default input device running for anyone? (Switchcraft never records.)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        return uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0
    }

    @available(macOS 14.2, *)
    private static func processes() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }
}
