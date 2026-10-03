/// Maps macOS virtual key codes (physical positions, `kVK_*`) to sound groups.
/// Works on positions, so it is independent of the active keyboard layout.
public enum KeyClassifier {
    public static func group(for keyCode: UInt16) -> KeyGroup {
        switch keyCode {
        case 0...9, 11...17, 31, 32, 34, 35, 37, 38, 40, 45, 46:
            return .alpha
        case 18...23, 25, 26, 28, 29, 82...89, 91, 92:
            return .number
        case 49:
            return .space
        case 36, 76:
            return .enter
        case 51, 117:
            return .backspace
        case 48:
            return .tab
        case 54...63:
            return .modifier
        case 123...126:
            return .arrow
        case 64, 79, 80, 90, 96...101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122:
            return .function
        case 53:
            return .escape
        case 10, 24, 27, 30, 33, 39, 41...44, 47, 50, 65, 67, 69, 75, 78, 81, 93, 94, 95:
            return .punctuation
        default:
            return .other
        }
    }

    /// Modifier key codes arrive as `flagsChanged`, not `keyDown`.
    public static func isModifier(_ keyCode: UInt16) -> Bool { (54...63).contains(keyCode) }

    /// Caps Lock (57) reports one `flagsChanged` per press, so each one is a press.
    public static let capsLock: UInt16 = 57
}
