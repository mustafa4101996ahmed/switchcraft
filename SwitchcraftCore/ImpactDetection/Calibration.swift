import Foundation

/// Per-machine reference impact magnitudes (g above the noise floor).
public struct Calibration: Codable, Equatable, Sendable {
    public var noiseFloor: Double
    public var soft: Double
    public var normal: Double
    public var hard: Double
    public var isUserCalibrated: Bool

    public init(noiseFloor: Double, soft: Double, normal: Double, hard: Double, isUserCalibrated: Bool) {
        self.noiseFloor = noiseFloor
        self.soft = soft
        self.normal = normal
        self.hard = hard
        self.isUserCalibrated = isUserCalibrated
    }

    /// From keystrokes recorded on a MacBook Air M5 (p10 / p50 / p90 peak above floor).
    public static let factoryDefault = Calibration(noiseFloor: 0.0006, soft: 0.006, normal: 0.012,
                                                   hard: 0.026, isUserCalibrated: false)

    public enum FitError: Error, Equatable, LocalizedError {
        case notEnoughSamples(VelocityLayer, got: Int, need: Int)
        case notSeparated

        public var errorDescription: String? {
            switch self {
            case let .notEnoughSamples(layer, got, need):
                return "Only \(got) \(layer.rawValue) presses were detected; \(need) are needed."
            case .notSeparated:
                return "Hard presses weren't stronger than soft presses. Try again with a clearer difference."
            }
        }
    }

    /// Medians are robust against the odd mis-detected press.
    public static func fit(noiseFloor: Double, soft: [Double], normal: [Double], hard: [Double],
                           minimumSamples: Int = 3) throws -> Calibration {
        for (layer, values) in [(VelocityLayer.soft, soft), (.medium, normal), (.hard, hard)]
        where values.count < minimumSamples {
            throw FitError.notEnoughSamples(layer, got: values.count, need: minimumSamples)
        }
        let s = median(soft), n = median(normal), h = median(hard)
        guard h > s else { throw FitError.notSeparated }
        // Keep the anchors strictly increasing even when "normal" lands outside soft…hard.
        let normal = min(max(n, s * 1.15), h / 1.15)
        let hard = max(h, normal * 1.15)
        return Calibration(noiseFloor: max(noiseFloor, 1e-5), soft: s, normal: max(normal, s * 1.05),
                           hard: hard, isUserCalibrated: true)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
