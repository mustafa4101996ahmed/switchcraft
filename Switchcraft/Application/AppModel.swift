import AppKit
import Observation
import ServiceManagement
import SwitchcraftCore

/// Composition root and UI-facing state. Owns the services; the realtime work happens on the
/// keyboard, sensor, impact and audio threads, never here.
@MainActor @Observable
final class AppModel {
    let settings = SettingsStore(legacySuite: "com.forcekeys.app")
    let permissions = PermissionsService()
    let library = SoundPackLibrary()
    let hardware = HardwareInfo.detect()
    @ObservationIgnored let audio = SoundEngine()
    @ObservationIgnored let sensor = HIDAccelerometer()
    @ObservationIgnored let keyboard = KeyboardMonitor()
    @ObservationIgnored let pipeline: TypingPipeline
    @ObservationIgnored let windows = WindowCoordinator()
    @ObservationIgnored let beepSuppressor = AlertBeepSuppressor()
    @ObservationIgnored private let hotKey = GlobalHotKey()
    @ObservationIgnored private let system = SystemMonitor()

    private(set) var sensorState: SensorState = .stopped
    private(set) var sensorMessage: String?
    private(set) var keyboardRunning = false
    private(set) var keyboardMessage: String?
    private(set) var audioMessage: String?
    private(set) var packMessage: String?
    private(set) var activePackName: String?
    private(set) var launchAtLoginEnabled = false
    private(set) var launchAtLoginMessage: String?
    private(set) var microphoneInUse = false
    private(set) var frontmostBundleID: String?

    @ObservationIgnored private var requestedPackID: String?
    @ObservationIgnored private var packGeneration = 0
    @ObservationIgnored private var sensorRunning = false
    @ObservationIgnored private var sensorDemand: Set<String> = []
    @ObservationIgnored private var sessionActive = true
    @ObservationIgnored private var micMonitoring = false

    init() {
        pipeline = TypingPipeline(output: audio)
        pipeline.setSensor(sensor)
        keyboard.onKeyEvent = { [pipeline, beepSuppressor] event in
            pipeline.handle(event)
            if !event.isRelease { beepSuppressor.keyPressed() }
        }
    }

    func start() {
        Log.app.info("Switchcraft starting on \(self.hardware.modelIdentifier, privacy: .public)")
        library.reload()
        startAudio()
        settings.onChange = { [weak self] in self?.settingsChanged() }
        permissions.onChange = { [weak self] _ in self?.startOrStopKeyboard() }
        sensor.onStateChange = { [weak self] state, message in
            Task { @MainActor in self?.sensorChanged(state, message) }
        }
        audio.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.audioMessage = self?.audio.lastError }
        }
        windows.onVisibilityChange = { [weak self] kind, visible in
            if kind == .diagnostics { self?.requireSensor("diagnostics", visible) }
            // Closing the guide counts as finishing it; it never comes back on its own.
            if kind == .onboarding && !visible { self?.settings.hasCompletedOnboarding = true }
        }
        configureSystemMonitor()
        settingsChanged()
        startOrStopKeyboard()
        refreshLaunchAtLogin()
        if !settings.hasCompletedOnboarding { windows.show(.onboarding, model: self) }
    }

    func shutdown() {
        beepSuppressor.restore()
        keyboard.stop()
        sensor.stop()
        audio.stop()
    }

    // MARK: Settings

    private func settingsChanged() {
        pipeline.setConfig(settings.pipelineConfig)
        audio.setVolume(settings.volume)
        audio.setRandomVariation(settings.randomVariation)
        audio.setStereoWidth(settings.stereoWidth)
        audio.setRoomAmbience(settings.roomAmbience)
        updateBeepSuppression()
        hotKey.setEnabled(settings.hotKeyEnabled) { [weak self] in self?.settings.isEnabled.toggle() }
        sensor.setMinimumNoiseFloor(settings.minimumNoiseFloor)
        if settings.muteWhenMicActive != micMonitoring {
            micMonitoring = settings.muteWhenMicActive
            system.setMicrophoneMonitoring(micMonitoring)
        }
        if settings.selectedPackID != requestedPackID { loadSelectedPack() }
        updateSensor()
    }

    /// What the user should know right now, in one line.
    enum ListeningStatus: Equatable {
        case listening
        case paused
        case mutedInApp(String)
        case mutedByMicrophone
        case needsPermission
        case notListening(String)
        case secureInput(SecureInputHolder)

        var text: String {
            switch self {
            case .listening: return "Listening"
            case .paused: return "Paused"
            case let .mutedInApp(name): return "Muted in \(name)"
            case .mutedByMicrophone: return "Muted while the microphone is in use"
            case .needsPermission: return "Keyboard access needed"
            case .notListening: return "Not listening"
            case let .secureInput(holder): return holder.isLockScreen ? "Blocked by macOS" : "Paused by \(holder.name)"
            }
        }

        /// One or two sentences on why, and what fixes it.
        var detail: String? {
            switch self {
            case let .notListening(reason):
                return reason
            case let .secureInput(holder) where holder.isLockScreen:
                return "The lock screen didn't let go of the keyboard, so macOS hides key presses from every app. Lock your Mac (⌃⌘Q) and unlock it with your password, not Touch ID."
            case let .secureInput(holder):
                let terminal = ["Terminal", "iTerm2"].contains(holder.name) ? " If no password is being asked for, turn off Secure Keyboard Entry in its app menu." : ""
                return "\(holder.name) turned on secure input, usually for a password. macOS hides key presses from every app until it's off." + terminal
            default:
                return nil
            }
        }

        var kind: StatusLabel.Kind {
            switch self {
            case .listening: return .good
            case .paused, .mutedInApp, .mutedByMicrophone: return .neutral
            case .needsPermission, .notListening: return .warning
            case let .secureInput(holder): return holder.isLockScreen ? .warning : .neutral
            }
        }
    }

    var listeningStatus: ListeningStatus {
        if !permissions.inputMonitoringGranted { return .needsPermission }
        if !settings.isEnabled { return .paused }
        if !keyboardRunning { return .notListening(keyboardMessage ?? "The keyboard listener isn't running.") }
        if let holder = permissions.secureInput { return .secureInput(holder) }
        if let id = frontmostBundleID, let app = settings.exclusions.first(where: { $0.bundleID == id }) {
            return .mutedInApp(app.name)
        }
        if settings.muteWhenMicActive && microphoneInUse { return .mutedByMicrophone }
        return .listening
    }

    var activePack: SoundPack? { library.pack(id: settings.selectedPackID) }

    var menuBarSymbolName: String {
        if !permissions.inputMonitoringGranted { return "exclamationmark.triangle" }
        if permissions.secureInput?.isLockScreen == true { return "exclamationmark.triangle" }
        return settings.isEnabled ? settings.menuBarSymbol : "speaker.slash"
    }

    /// The beep is only silenced while Switchcraft itself is audible (enabled, not in an excluded app).
    private func updateBeepSuppression() {
        let excluded = frontmostBundleID.map { id in settings.exclusions.contains { $0.bundleID == id } } ?? false
        beepSuppressor.isActive = sessionActive && settings.isEnabled && settings.silenceTypingBeep && !excluded
    }

    // MARK: Sound packs

    func loadSelectedPack() {
        let wanted = settings.selectedPackID
        requestedPackID = wanted
        guard let pack = library.pack(id: wanted) ?? library.pack(id: SettingsStore.defaultPackID) ?? library.packs.first else {
            packMessage = "No sound packs were found."
            return
        }
        packMessage = pack.id == wanted ? nil : "The selected pack is no longer available; using \(pack.name)."
        packGeneration += 1
        let generation = packGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try SampleBank.load(pack: pack, sampleRate: SoundEngine.internalSampleRate) }
            await self?.finishLoading(result, pack: pack, generation: generation)
        }
    }

    private func finishLoading(_ result: Result<SampleBank, Error>, pack: SoundPack, generation: Int) {
        guard generation == packGeneration else { return }
        switch result {
        case let .success(bank):
            audio.setBank(bank)
            activePackName = pack.name
        case let .failure(error):
            packMessage = error.localizedDescription
        }
    }

    func reloadPacks() {
        library.reload()
        requestedPackID = nil
        loadSelectedPack()
    }

    func importPack(from url: URL) throws {
        let pack = try library.importPack(from: url)
        settings.selectedPackID = pack.id
    }

    /// Soft → slam on a letter key, then the space bar, each with its key-up sound.
    func previewSound() {
        let steps: [(KeyGroup, Double)] = [(.alpha, 0.12), (.alpha, 0.38), (.alpha, 0.62), (.alpha, 0.9), (.space, 0.5)]
        let releases = settings.playReleases
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.25) { [audio] in
                audio.play(group: step.0, keyCode: SoundEngine.previewKeyCode, velocity: step.1, keyTime: 0)
            }
            guard releases else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.25 + 0.11) { [audio] in
                audio.playRelease(group: step.0, keyCode: SoundEngine.previewKeyCode, velocity: step.1, keyTime: 0)
            }
        }
    }

    // MARK: Audio

    func startAudio() {
        do {
            try audio.start()
            audioMessage = nil
        } catch {
            audioMessage = "The audio engine couldn't start: \(error.localizedDescription)"
        }
    }

    func restartAudio() {
        do {
            try audio.restart()
            audioMessage = nil
        } catch {
            audioMessage = "The audio engine couldn't restart: \(error.localizedDescription)"
        }
    }

    // MARK: Keyboard

    func startOrStopKeyboard() {
        guard sessionActive, permissions.inputMonitoringGranted else {
            keyboard.stop()
            keyboardRunning = false
            keyboardMessage = permissions.inputMonitoringGranted ? nil : "Input Monitoring permission is required."
            return
        }
        guard !keyboard.isRunning else {
            keyboardRunning = true
            return
        }
        do {
            try keyboard.start()
            keyboardRunning = true
            keyboardMessage = nil
        } catch {
            keyboardRunning = false
            keyboardMessage = error.localizedDescription
        }
    }

    // MARK: Sensor

    /// Effective state shown in the UI.
    var displayedSensorState: SensorState {
        if settings.velocityMode == .simulated && sensorDemand.isEmpty { return .simulation }
        if !hardware.accelerometerPresent { return .unsupported }
        return sensorState
    }

    /// The sensor runs only while something needs it: accelerometer mode, calibration or diagnostics.
    func updateSensor() {
        let wanted = sessionActive && hardware.accelerometerPresent
            && (settings.velocityMode == .accelerometer || !sensorDemand.isEmpty)
        if wanted && !sensorRunning {
            sensorRunning = true
            sensor.start()
        } else if !wanted && sensorRunning {
            sensorRunning = false
            sensor.stop()
        }
    }

    func requireSensor(_ client: String, _ needed: Bool) {
        if needed { sensorDemand.insert(client) } else { sensorDemand.remove(client) }
        updateSensor()
    }

    func restartSensor() {
        sensorRunning = false
        sensor.stop()
        updateSensor()
    }

    func sensorChanged(_ state: SensorState, _ message: String?) {
        sensorState = state
        sensorMessage = message
        Log.sensor.info("Sensor state \(state.rawValue, privacy: .public) \(message ?? "", privacy: .public)")
    }

    // MARK: Calibration

    func beginCalibration(_ session: CalibrationSession) {
        requireSensor("calibration", true)
        pipeline.setCalibrationSink { measurement in
            Task { @MainActor in session.record(measurement) }
        }
    }

    func endCalibration() {
        pipeline.setCalibrationSink(nil)
        requireSensor("calibration", false)
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginMessage = nil
        } catch {
            launchAtLoginMessage = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled
        if status == .requiresApproval {
            launchAtLoginMessage = "Approve Switchcraft in System Settings › General › Login Items."
        }
    }

    // MARK: System events

    private func configureSystemMonitor() {
        system.onFrontmostChange = { [weak self] bundleID in
            self?.frontmostBundleID = bundleID
            self?.pipeline.updateContext { $0.frontmostBundleID = bundleID }
            self?.updateBeepSuppression()
        }
        system.onMicrophoneChange = { [weak self] inUse in
            self?.microphoneInUse = inUse
            self?.pipeline.updateContext { $0.microphoneInUse = inUse }
        }
        system.onSleep = { [weak self] in
            Log.app.info("System will sleep; pausing sensor")
            self?.sensorRunning = false
            self?.sensor.stop()
        }
        system.onWake = { [weak self] in
            Log.app.info("System woke; revalidating audio, sensor and keyboard")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                self?.resumeAfterInterruption()
            }
        }
        system.onSessionActive = { [weak self] active in
            guard let self else { return }
            sessionActive = active
            updateBeepSuppression()
            if active {
                resumeAfterInterruption()
            } else {
                Log.app.info("User session inactive (Fast User Switching); pausing")
                keyboard.stop()
                keyboardRunning = false
                sensorRunning = false
                sensor.stop()
                audio.stop()
            }
        }
        system.start()
    }

    private func resumeAfterInterruption() {
        restartAudio()
        permissions.refresh()
        startOrStopKeyboard()
        restartSensor()
    }
}
