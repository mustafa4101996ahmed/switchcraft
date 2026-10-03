import Foundation

/// Physical key families. Sound packs can record each group separately.
public enum KeyGroup: String, CaseIterable, Codable, Sendable {
    case alpha, number, space, enter, backspace, tab, modifier, arrow, function, escape, punctuation, other

    /// Lookup order when a pack has no recordings for this group. `alpha` is the universal last resort.
    public var fallbacks: [KeyGroup] {
        switch self {
        case .alpha: return []
        case .number, .punctuation, .other: return [.alpha]
        case .space: return [.enter, .other, .alpha]
        case .enter: return [.space, .other, .alpha]
        case .backspace: return [.enter, .other, .alpha]
        case .tab, .modifier, .arrow, .function, .escape: return [.other, .alpha]
        }
    }

    /// Stable index without allocating (`allCases` builds an array on every call).
    public var index: Int {
        switch self {
        case .alpha: return 0
        case .number: return 1
        case .space: return 2
        case .enter: return 3
        case .backspace: return 4
        case .tab: return 5
        case .modifier: return 6
        case .arrow: return 7
        case .function: return 8
        case .escape: return 9
        case .punctuation: return 10
        case .other: return 11
        }
    }

    public static let count = 12
    public var displayName: String { rawValue.capitalized }
}

/// Recorded velocity layers. Playback crossfades between adjacent layers.
public enum VelocityLayer: String, CaseIterable, Codable, Sendable, Comparable {
    case soft, medium, hard, slam

    public var index: Int {
        switch self {
        case .soft: return 0
        case .medium: return 1
        case .hard: return 2
        case .slam: return 3
        }
    }

    public static let count = 4

    public static func at(_ index: Int) -> VelocityLayer {
        switch index {
        case ..<1: return .soft
        case 1: return .medium
        case 2: return .hard
        default: return .slam
        }
    }

    public static func < (lhs: VelocityLayer, rhs: VelocityLayer) -> Bool { lhs.index < rhs.index }
    public var displayName: String { rawValue.capitalized }
}

public enum VelocityMode: String, CaseIterable, Codable, Sendable {
    case accelerometer, fixed, simulated

    public var displayName: String {
        switch self {
        case .accelerometer: return "Accelerometer"
        case .fixed: return "Fixed"
        case .simulated: return "Simulated"
        }
    }
}

/// Developer simulation sources (used when `VelocityMode.simulated`).
public enum SimulationSource: String, CaseIterable, Codable, Sendable {
    case randomRange, syntheticSignal

    public var displayName: String {
        switch self {
        case .randomRange: return "Random range"
        case .syntheticSignal: return "Synthetic impact signals"
        }
    }
}

public enum SensorState: String, Sendable {
    case supported = "SUPPORTED"
    case permissionRequired = "SENSOR_PERMISSION_REQUIRED"
    case unsupported = "UNSUPPORTED_SENSOR"
    case simulation = "SIMULATION_MODE"
    case stopped = "STOPPED"

    public var isReadable: Bool { self == .supported }
}

/// One accelerometer reading in g, timestamped on the `MonotonicClock` base.
public struct AccelSample: Sendable, Equatable {
    public var time: Double
    public var x: Float
    public var y: Float
    public var z: Float

    public init(time: Double, x: Float, y: Float, z: Float) {
        self.time = time
        self.x = x
        self.y = y
        self.z = z
    }
}

/// A key press or release. Holds a key code only — never a character.
public struct KeyEvent: Sendable, Equatable {
    /// Hardware event time (from `CGEvent.timestamp`), seconds on the `MonotonicClock` base.
    public var time: Double
    /// When Switchcraft received the event.
    public var receivedAt: Double
    public var keyCode: UInt16
    public var group: KeyGroup
    public var isRepeat: Bool
    /// Key-up (the switch's upstroke sound).
    public var isRelease: Bool

    public init(time: Double, receivedAt: Double, keyCode: UInt16, isRepeat: Bool, isRelease: Bool = false) {
        self.time = time
        self.receivedAt = receivedAt
        self.keyCode = keyCode
        self.group = KeyClassifier.group(for: keyCode)
        self.isRepeat = isRepeat
        self.isRelease = isRelease
    }
}

public struct ExcludedApp: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}
