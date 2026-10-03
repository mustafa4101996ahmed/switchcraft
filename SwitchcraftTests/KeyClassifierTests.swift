import Testing
@testable import SwitchcraftCore

struct KeyClassifierTests {
    @Test(arguments: [
        (UInt16(0), KeyGroup.alpha), (12, .alpha), (46, .alpha), // A, Q, M
        (18, .number), (29, .number), (82, .number), (92, .number), // 1, 0, keypad 0, keypad 9
        (49, .space),
        (36, .enter), (76, .enter), // return, keypad enter
        (51, .backspace), (117, .backspace), // delete, forward delete
        (48, .tab),
        (55, .modifier), (56, .modifier), (57, .modifier), (63, .modifier), (54, .modifier),
        (123, .arrow), (126, .arrow),
        (122, .function), (111, .function), (64, .function), // F1, F12, F17
        (53, .escape),
        (43, .punctuation), (47, .punctuation), (50, .punctuation), (24, .punctuation), // , . ` =
        (115, .other), (119, .other), (200, .other), // home, end, unknown
    ])
    func classifiesKeyCodes(code: UInt16, expected: KeyGroup) {
        #expect(KeyClassifier.group(for: code) == expected)
    }

    @Test func everyKeyCodeHasAGroup() {
        for code in UInt16(0)...UInt16(255) {
            _ = KeyClassifier.group(for: code) // must not trap
        }
    }

    @Test func groupIndicesAreUniqueAndDense() {
        let indices = KeyGroup.allCases.map(\.index)
        #expect(Set(indices).count == KeyGroup.count)
        #expect(indices.sorted() == Array(0..<KeyGroup.count))
        #expect(VelocityLayer.allCases.map(\.index) == [0, 1, 2, 3])
    }

    @Test func fallbacksAlwaysEndAtAlpha() {
        for group in KeyGroup.allCases where group != .alpha {
            #expect(group.fallbacks.last == .alpha)
            #expect(!group.fallbacks.contains(group))
        }
    }

    @Test func keyEventCarriesOnlyCodeAndGroup() {
        let event = KeyEvent(time: 1, receivedAt: 1.001, keyCode: 49, isRepeat: false)
        #expect(event.group == .space)
        #expect(event.keyCode == 49)
    }
}
