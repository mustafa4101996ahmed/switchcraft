import Foundation

/// Generates the four velocity layers from one full-force recording of a key.
///
/// A softer press bottoms out with less energy, so it loses high-frequency clack and level;
/// a slam adds low-end "thud" from the case and saturates slightly. Every layer comes from the
/// same hit, so crossfading two of them changes brightness and weight — never pitch or timing.
public enum LayerDerivation {
    public static func derive(_ hit: [Float], sampleRate: Double, layer: VelocityLayer) -> [Float] {
        switch layer {
        case .hard:
            return hit
        case .medium:
            var lowPass = Biquad.lowPass(cutoff: 6500, sampleRate: sampleRate)
            let gain = gainFactor(-2.5)
            return hit.map { Float(lowPass.process(Double($0))) * gain }
        case .soft:
            var first = Biquad.lowPass(cutoff: 2800, sampleRate: sampleRate)
            var second = first
            let gain = gainFactor(-6)
            var out = hit.map { Float(second.process(first.process(Double($0)))) * gain }
            // A soft press has a rounder onset: ramp the first 0.8 ms.
            let ramp = max(1, Int(0.0008 * sampleRate))
            for i in 0..<min(ramp, out.count) { out[i] *= Float(i) / Float(ramp) }
            return out
        case .slam:
            // +5 dB low shelf for the case thud, then tanh: +2 dB on typical levels, soft-saturating
            // peaks, and the output can never exceed ±1.
            var shelf = Biquad.lowShelf(frequency: 180, sampleRate: sampleRate, gainDb: 5)
            let drive = Double(gainFactor(2))
            return hit.map { Float(tanh(shelf.process(Double($0)) * drive)) }
        }
    }

    private static func gainFactor(_ db: Double) -> Float { Float(pow(10, db / 20)) }
}
