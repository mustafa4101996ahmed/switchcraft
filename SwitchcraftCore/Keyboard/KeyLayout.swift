import Foundation

/// Horizontal position of each physical key (0 = left edge, 1 = right edge of a MacBook-style
/// ANSI keyboard), used to place its sound in the stereo field. Key codes are positions, so
/// this is independent of the typing layout.
public enum KeyLayout {
    /// Board width in key units (the number row is 15 units including Delete).
    private static let width = 15.0

    /// Position of the key's centre, 0…1. Unknown keys sit in the middle.
    public static func position(of keyCode: UInt16) -> Double {
        guard let units = centres[keyCode] else { return 0.5 }
        return min(max(units / width, 0), 1)
    }

    /// Key centres in key units from the left edge.
    private static let centres: [UInt16: Double] = {
        var map: [UInt16: Double] = [:]
        func row(_ codes: [UInt16], start: Double, step: Double = 1) {
            for (i, code) in codes.enumerated() { map[code] = start + Double(i) * step }
        }
        // Function row: Esc, F1…F12.
        row([53, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111], start: 0.6, step: 1.15)
        // ` 1 2 3 4 5 6 7 8 9 0 - =, then Delete (1.5 wide).
        row([50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24], start: 0.5)
        map[51] = 13.75
        // Tab (1.5 wide), Q…P [ ] \.
        map[48] = 0.75
        row([12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30], start: 2)
        map[42] = 14.25
        // Caps (1.75), A…L ; ', Return (1.75).
        map[57] = 0.875
        row([0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39], start: 2.25)
        map[36] = 14.1
        // Shift (2.25), Z…M , . /, right Shift.
        map[56] = 1.1
        row([6, 7, 8, 9, 11, 45, 46, 43, 47, 44], start: 2.75)
        map[60] = 14.0
        // Bottom row: fn, control, option, command, space, command, option, arrows.
        map[63] = 0.5
        map[59] = 1.5
        map[58] = 2.5
        map[55] = 3.75
        map[49] = 7.5
        map[54] = 11.25
        map[61] = 12.4
        map[62] = 12.4
        map[123] = 13.0
        map[125] = 14.0
        map[126] = 14.0
        map[124] = 15.0
        // Forward delete, home/end/page keys and the keypad sit on the far right.
        for code: UInt16 in [117, 115, 119, 116, 121, 114] { map[code] = 15 }
        map[10] = 0.5 // ISO § key, left of 1
        for code: UInt16 in [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92] { map[code] = 15 }
        return map
    }()

    /// Gains for a mono source panned by key position. Constant-power: the centre is −3 dB per
    /// side so a key sounds equally loud wherever it is.
    public static func monoGains(keyCode: UInt16, width: Double) -> (left: Float, right: Float) {
        let angle = (pan(keyCode: keyCode, width: width) + 1) * Double.pi / 4
        return (Float(cos(angle)), Float(sin(angle)))
    }

    /// Gains for a stereo source: balance toward the key's side, keeping the recording's own image.
    public static func stereoGains(keyCode: UInt16, width: Double) -> (left: Float, right: Float) {
        let p = pan(keyCode: keyCode, width: width)
        return (Float(min(1, 1 - p)), Float(min(1, 1 + p)))
    }

    /// −width (left) … +width (right).
    static func pan(keyCode: UInt16, width: Double) -> Double {
        (position(of: keyCode) * 2 - 1) * min(max(width, 0), 1)
    }
}
