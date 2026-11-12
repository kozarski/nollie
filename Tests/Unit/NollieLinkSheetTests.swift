#if os(macOS)
import Foundation
import Testing
@testable import Nollie

/// The Mac's pairing code shows only while Nollie is in front. A sheet opened while another app is in
/// front says the code is hidden, never that it couldn't make one.
@MainActor
struct NollieLinkSheetTests {
    @Test func aSheetOpenedBehindAnotherAppSaysTheCodeIsHidden() {
        let behind = NollieLinkSheet.mayShow(locked: false, appActive: false, screenLocked: false, sceneActive: true)
        #expect(!behind, "The window is on screen, but Nollie isn't the front app")
        #expect(NollieLinkSheet.codeState(linked: false, locked: false, mayShow: behind, code: nil, loading: false,
                                          issue: nil) == .hidden)
        #expect(NollieLinkSheet.codeState(linked: false, locked: false, mayShow: behind, code: nil, loading: false,
                                          issue: "Couldn't make a code.") == .hidden, "Hidden comes before a failed try")
    }

    @Test func inFrontTheCodeShowsAndAFailureSaysSo() {
        let front = NollieLinkSheet.mayShow(locked: false, appActive: true, screenLocked: false, sceneActive: true)
        #expect(front)
        #expect(NollieLinkSheet.codeState(linked: false, locked: false, mayShow: front, code: "nollie://x", loading: false,
                                          issue: nil) == .code("nollie://x"))
        #expect(NollieLinkSheet.codeState(linked: false, locked: false, mayShow: front, code: nil, loading: true, issue: nil) == .loading)
        if case .issue = NollieLinkSheet.codeState(linked: false, locked: false, mayShow: front, code: nil, loading: false, issue: nil) {
        } else { Issue.record("A code that couldn't be made says so") }
        #expect(!NollieLinkSheet.mayShow(locked: true, appActive: true, screenLocked: false, sceneActive: true))
        #expect(!NollieLinkSheet.mayShow(locked: false, appActive: true, screenLocked: true, sceneActive: true))
        #expect(NollieLinkSheet.codeState(linked: false, locked: true, mayShow: false, code: nil, loading: false, issue: nil) == .locked)
        #expect(NollieLinkSheet.codeState(linked: true, locked: false, mayShow: false, code: nil, loading: false, issue: nil) == .linked)
    }
}
#endif
