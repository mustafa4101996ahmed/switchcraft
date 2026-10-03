import Foundation
import Observation

/// All user preferences, persisted to UserDefaults as JSON. Local only.
@MainActor @Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any persisted change.
    @ObservationIgnored public var onChange: (() -> Void)?

    // General
    public var isEnabled: Bool { didSet { save(isEnabled, .isEnabled) } }
    public var menuBarSymbol: String { didSet { save(menuBarSymbol, .menuBarSymbol) } }
    public var playRepeats: Bool { didSet { save(playRepeats, .playRepeats) } }
    public var playReleases: Bool { didSet { save(playReleases, .playReleases) } }
    public var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, .hasCompletedOnboarding) } }
    /// ⌃⌥⌘K toggles Switchcraft from anywhere.
    public var hotKeyEnabled: Bool { didSet { save(hotKeyEnabled, .hotKeyEnabled) } }

    // Sound
    public var selectedPackID: String { didSet { save(selectedPackID, .selectedPackID) } }
    public var volume: Double { didSet { save(volume, .volume) } }
    public var randomVariation: Bool { didSet { save(randomVariation, .randomVariation) } }
    /// 0 = mono centre, 1 = keys spread across the full stereo field by keyboard position.
    public var stereoWidth: Double { didSet { save(stereoWidth, .stereoWidth) } }
    /// Small-room reflections mixed under the dry click, 0…1.
    public var roomAmbience: Double { didSet { save(roomAmbience, .roomAmbience) } }
    /// Mute the macOS alert sound during typing bursts (the "invalid key" beep).
    public var silenceTypingBeep: Bool { didSet { save(silenceTypingBeep, .silenceTypingBeep) } }

    // Typing force
    public var velocityMode: VelocityMode { didSet { save(velocityMode, .velocityMode) } }
    public var fixedVelocity: Double { didSet { save(fixedVelocity, .fixedVelocity) } }
    public var simulationSource: SimulationSource { didSet { save(simulationSource, .simulationSource) } }
    public var randomMin: Double { didSet { save(randomMin, .randomMin) } }
    public var randomMax: Double { didSet { save(randomMax, .randomMax) } }
    public var curve: VelocityCurve { didSet { save(curve, .curve) } }
    public var calibration: Calibration { didSet { save(calibration, .calibration) } }
    public var window: CorrelationWindow { didSet { save(window, .window) } }
    public var detectionSNR: Double { didSet { save(detectionSNR, .detectionSNR) } }
    public var minimumNoiseFloor: Double { didSet { save(minimumNoiseFloor, .minimumNoiseFloor) } }
    public var impactDecayMs: Double { didSet { save(impactDecayMs, .impactDecayMs) } }

    // Exclusions
    public var exclusions: [ExcludedApp] { didSet { save(exclusions, .exclusions) } }
    public var muteWhenMicActive: Bool { didSet { save(muteWhenMicActive, .muteWhenMicActive) } }

    // Diagnostics
    public var showDebugGraph: Bool { didSet { save(showDebugGraph, .showDebugGraph) } }

    public nonisolated static let defaultPackID = "cherry-mx-brown-pbt"
    /// `menuBarSymbol` value meaning "the Switchcraft glyph" rather than an SF Symbol name.
    public nonisolated static let brandSymbol = "switchcraft"

    enum Key: String {
        case isEnabled, menuBarSymbol, playRepeats, playReleases, hasCompletedOnboarding, hotKeyEnabled
        case selectedPackID, volume, randomVariation, stereoWidth, roomAmbience, silenceTypingBeep
        case velocityMode, fixedVelocity, simulationSource, randomMin, randomMax
        case curve, calibration, window, detectionSNR, minimumNoiseFloor, impactDecayMs
        case exclusions, muteWhenMicActive, showDebugGraph

        var defaultsKey: String { "fk." + rawValue }
    }

    /// `legacySuite`: preferences domain of the app's previous name; copied over once, on first launch.
    public init(defaults: UserDefaults = .standard, legacySuite: String? = nil) {
        self.defaults = defaults
        if let legacySuite, let legacy = UserDefaults(suiteName: legacySuite) {
            Self.migrate(from: legacy, into: defaults)
        }
        isEnabled = Self.load(.isEnabled, defaults, true)
        menuBarSymbol = Self.load(.menuBarSymbol, defaults, Self.brandSymbol)
        playRepeats = Self.load(.playRepeats, defaults, false)
        playReleases = Self.load(.playReleases, defaults, true)
        hasCompletedOnboarding = Self.load(.hasCompletedOnboarding, defaults, false)
        hotKeyEnabled = Self.load(.hotKeyEnabled, defaults, true)
        selectedPackID = Self.load(.selectedPackID, defaults, Self.defaultPackID)
        volume = Self.load(.volume, defaults, 0.7)
        randomVariation = Self.load(.randomVariation, defaults, true)
        stereoWidth = Self.load(.stereoWidth, defaults, 0.6)
        roomAmbience = Self.load(.roomAmbience, defaults, 0.3)
        silenceTypingBeep = Self.load(.silenceTypingBeep, defaults, true)
        velocityMode = Self.load(.velocityMode, defaults, .accelerometer)
        fixedVelocity = Self.load(.fixedVelocity, defaults, 0.5)
        simulationSource = Self.load(.simulationSource, defaults, .randomRange)
        randomMin = Self.load(.randomMin, defaults, 0.2)
        randomMax = Self.load(.randomMax, defaults, 0.9)
        curve = Self.load(.curve, defaults, VelocityCurve())
        calibration = Self.load(.calibration, defaults, .factoryDefault)
        window = Self.load(.window, defaults, CorrelationWindow())
        detectionSNR = Self.load(.detectionSNR, defaults, 4)
        minimumNoiseFloor = Self.load(.minimumNoiseFloor, defaults, 0.0002)
        impactDecayMs = Self.load(.impactDecayMs, defaults, 15)
        exclusions = Self.load(.exclusions, defaults, [])
        muteWhenMicActive = Self.load(.muteWhenMicActive, defaults, false)
        showDebugGraph = Self.load(.showDebugGraph, defaults, true)
    }

    /// Snapshot for the realtime path.
    public var pipelineConfig: PipelineConfig {
        var c = PipelineConfig()
        c.enabled = isEnabled
        c.playRepeats = playRepeats
        c.playReleases = playReleases
        c.mode = velocityMode
        c.fixedVelocity = fixedVelocity
        c.simulationSource = simulationSource
        c.randomMin = randomMin
        c.randomMax = randomMax
        c.window = window
        c.detectionSNR = detectionSNR
        c.impactDecay = impactDecayMs / 1000
        c.mapper = VelocityMapper(calibration: calibration, curve: curve)
        c.excludedBundleIDs = Set(exclusions.map(\.bundleID))
        c.muteWhenMicActive = muteWhenMicActive
        return c
    }

    public func resetAdvanced() {
        curve = VelocityCurve(sensitivity: curve.sensitivity)
        window = CorrelationWindow()
        detectionSNR = 4
        minimumNoiseFloor = 0.0002
        impactDecayMs = 15
    }

    public func resetCalibration() { calibration = .factoryDefault }

    /// Sound packs renamed when the bundled packs moved to real switch recordings.
    static let renamedPacks = [
        "classic-clicky": "cherry-mx-blue-pbt", "soft-tactile": "cherry-mx-brown-pbt",
        "linear": "cherry-mx-black-pbt", "deep-thock": "black-ink", "retro-terminal": "buckling-spring",
    ]

    /// Copies every `fk.` preference from the old domain when this one has none yet.
    static func migrate(from legacy: UserDefaults, into defaults: UserDefaults) {
        let isOurs: (String) -> Bool = { $0.hasPrefix("fk.") }
        guard !defaults.dictionaryRepresentation().keys.contains(where: isOurs) else { return }
        let old = legacy.dictionaryRepresentation().filter { isOurs($0.key) }
        guard !old.isEmpty else { return }
        for (key, value) in old { defaults.set(value, forKey: key) }
        if let data = defaults.data(forKey: Key.selectedPackID.defaultsKey),
           let id = try? JSONDecoder().decode(String.self, from: data), let renamed = renamedPacks[id] {
            defaults.set(try? JSONEncoder().encode(renamed), forKey: Key.selectedPackID.defaultsKey)
        }
        Log.app.info("Migrated \(old.count) settings from the previous app name")
    }

    private func save<T: Encodable>(_ value: T, _ key: Key) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key.defaultsKey)
        } catch {
            Log.app.error("Could not save setting \(key.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        onChange?()
    }

    private static func load<T: Decodable>(_ key: Key, _ defaults: UserDefaults, _ fallback: T) -> T {
        guard let data = defaults.data(forKey: key.defaultsKey) else { return fallback }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.app.error("Ignoring unreadable setting \(key.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return fallback
        }
    }
}
