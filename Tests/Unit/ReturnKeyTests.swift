import Foundation
import Testing
@testable import Nollie

/// How Return behaves in the composer on iPhone and iPad (the Mac uses its own field).
@Suite struct ReturnKeyTests {
    private func press(hardware: Bool, shift: Bool = false, command: Bool = false, returnSends: Bool) -> ComposerReturnRule.Action {
        ComposerReturnRule.action(hardware: hardware, shift: shift, command: command, returnSends: returnSends)
    }

    @Test func theOnScreenKeyBreaksTheLineUnlessTheSettingSaysSend() {
        #expect(press(hardware: false, returnSends: false) == .newline)
        #expect(press(hardware: false, returnSends: true) == .send)
    }

    @Test(arguments: [false, true])
    func aKeyboardSendsExceptWithShiftAndCommandAlwaysSends(returnSends: Bool) {
        #expect(press(hardware: true, returnSends: returnSends) == .send)
        #expect(press(hardware: true, shift: true, returnSends: returnSends) == .newline)
        #expect(press(hardware: true, command: true, returnSends: returnSends) == .send)
        // Shift-Return reported by the on-screen keyboard is a new line too.
        #expect(press(hardware: false, shift: true, returnSends: returnSends) == .newline)
    }
}
