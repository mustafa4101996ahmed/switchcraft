/// Immutable snapshot of everything the realtime path needs, swapped atomically from the UI.
/// The realtime path never touches `SettingsStore` or JSON.
public struct PipelineConfig: Equatable, Sendable {
    public var enabled = true
    public var playRepeats = false
    public var playReleases = true
    public var mode: VelocityMode = .accelerometer
    public var fixedVelocity = 0.5
    public var simulationSource: SimulationSource = .randomRange
    public var randomMin = 0.2
    public var randomMax = 0.9
    public var window = CorrelationWindow()
    public var detectionSNR = 4.0
    public var impactDecay = 0.015
    public var mapper = VelocityMapper()
    public var excludedBundleIDs: Set<String> = []
    public var muteWhenMicActive = false

    public init() {}
}

/// Live system facts the pipeline gates on (frontmost app, microphone).
public struct PipelineContext: Equatable, Sendable {
    public var frontmostBundleID: String?
    public var microphoneInUse = false

    public init(frontmostBundleID: String? = nil, microphoneInUse: Bool = false) {
        self.frontmostBundleID = frontmostBundleID
        self.microphoneInUse = microphoneInUse
    }
}
