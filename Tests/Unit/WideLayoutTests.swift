import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Nollie

/// The wide layout's arithmetic: how the list, chat and panel share the width, how a fold in use
/// moves the dividing line, and the measurements the chat takes from its own window.
@MainActor @Suite struct SplitLayoutTests {
    @Test func aWideWindowGivesTheListAboutAThird() {
        let layout = SplitLayout.make(width: 1194)
        #expect(layout.list == .init(x: 0, width: 398))
        #expect(layout.chat == .init(x: 398, width: 796))
        #expect(layout.panel == nil)
        #expect(!layout.listCovered)
        // An open iPhone Duo: a third would be narrower than a phone, so the list keeps a phone's width.
        #expect(SplitLayout.make(width: 951).list == .init(x: 0, width: 340))
    }

    @Test func theListKeepsToComfortableLimits() {
        #expect(SplitLayout.make(width: 1376).list.width == SplitLayout.listMax)
        #expect(SplitLayout.make(width: 700).list.width == SplitLayout.listMin)
        // Never more than half, however narrow.
        #expect(SplitLayout.make(width: 500).list.width == 250)
    }

    @Test func aPanelTakesTheRightHalfAndTheChatTheLeft() {
        let layout = SplitLayout.make(width: 1000, panelOpen: true)
        #expect(layout.chat == .init(x: 0, width: 500))
        #expect(layout.panel == .init(x: 500, width: 500))
        #expect(layout.listCovered)
        #expect(!layout.expanded)
    }

    @Test func anExpandedPanelCoversTheWholeWidthWithTheChatStillLaidOutBeneath() {
        let layout = SplitLayout.make(width: 1000, panelOpen: true, expanded: true)
        #expect(layout.panel == .init(x: 0, width: 1000))
        #expect(layout.chat == .init(x: 0, width: 500))
        #expect(layout.expanded)
    }

    @Test func halfOpenTheColumnsMeetAtTheCreaseAndNothingSitsOnIt() {
        let layout = SplitLayout.make(width: 951, fold: 465...486)
        #expect(layout.list == .init(x: 0, width: 465))
        #expect(layout.chat == .init(x: 486, width: 465))
        #expect(layout.list.maxX <= 465 && layout.chat.x >= 486)
    }

    @Test func halfOpenAPanelStaysInItsHalfEvenWhenAskedToSpreadOut() {
        let layout = SplitLayout.make(width: 951, fold: 465...486, panelOpen: true, expanded: true)
        #expect(layout.chat == .init(x: 0, width: 465))
        #expect(layout.panel == .init(x: 486, width: 465))
        #expect(!layout.expanded)
    }

    @Test func aFoldOutsideTheWindowIsIgnored() {
        #expect(SplitLayout.make(width: 600, fold: 0...10) == SplitLayout.make(width: 600))
        #expect(SplitLayout.make(width: 600, fold: 590...620) == SplitLayout.make(width: 600))
    }

    @Test func onlyAnUprightCreaseNearTheMiddleCounts() {
        let size = CGSize(width: 951, height: 669)
        // The book posture: a strip down the middle.
        #expect(SplitLayout.fold(in: [CGRect(x: 465, y: 0, width: 21, height: 669)], size: size) == 465...486)
        // Held the other way: a crease across the screen.
        #expect(SplitLayout.fold(in: [CGRect(x: 0, y: 320, width: 951, height: 21)], size: size) == nil)
        // Something small near an edge is not a fold.
        #expect(SplitLayout.fold(in: [CGRect(x: 900, y: 0, width: 20, height: 669)], size: size) == nil)
        #expect(SplitLayout.fold(in: [], size: size) == nil)
        #expect(SplitLayout.fold(in: [CGRect(x: 465, y: 0, width: 21, height: 669)], size: .zero) == nil)
    }

    @Test func theSplitNeedsARegularWidthAndRoom() {
        #expect(SplitLayout.showsSplit(regularWidth: true, width: 951))
        #expect(!SplitLayout.showsSplit(regularWidth: false, width: 951))
        #expect(!SplitLayout.showsSplit(regularWidth: true, width: 507))
    }
}

/// The panel beside the chat: what it shows, spreading out, and the fold keeping it in its half.
@MainActor @Suite struct SidePanelHostTests {
    @Test func showingReplacesWhatWasThereAndStartsHalfWidth() {
        let host = SidePanelHost()
        host.show("one") { EmptyView() }
        host.toggleExpanded()
        #expect(host.expanded)
        host.show("two") { EmptyView() }
        #expect(host.page?.id == "two")
        #expect(!host.expanded)
        host.close()
        #expect(!host.isOpen && !host.expanded)
    }

    @Test func aFoldInUseFoldsAnExpandedPanelBackAndKeepsItSo() {
        let host = SidePanelHost()
        host.show("watch") { EmptyView() }
        host.toggleExpanded()
        host.canExpand = false
        #expect(!host.expanded)
        host.toggleExpanded()
        #expect(!host.expanded)
        host.canExpand = true
        host.toggleExpanded()
        #expect(host.expanded)
    }
}

/// Measurements the chat takes from its own window and frame rather than the screen.
@MainActor @Suite struct ChatGeometryTests {
    @Test func cardsAreCappedByTheChatTheyAreIn() {
        #if os(iOS)
        #expect(HTMLCard.heightCap(viewport: 900) == 540)
        #expect(HTMLCard.heightCap(viewport: 300) == 240)
        #expect(HTMLCard.heightCap(viewport: 0) == 480)
        #else
        #expect(HTMLCard.heightCap(viewport: 900) == 480)
        #endif
    }

    @Test func theAttachPanelFitsTheRoomAboveTheComposer() {
        #expect(AttachPanel.height(natural: 400, estimate: 300, room: .infinity) == 400)
        #expect(AttachPanel.height(natural: 0, estimate: 300, room: .infinity) == 300)
        #expect(AttachPanel.height(natural: 400, estimate: 300, room: 250) == 250)
        // Never squeezed below two rows; past that it scrolls.
        #expect(AttachPanel.height(natural: 400, estimate: 300, room: 40) == 132)
    }

    @Test func outlandishDockAndHeaderHeightsAreDiscarded() {
        var metrics = ThreadMetrics()
        metrics.container = 800
        #expect(metrics.plausibleDock(120))
        #expect(metrics.plausibleDock(500))
        #expect(!metrics.plausibleDock(700))
        #expect(!metrics.plausibleDock(0))
        #expect(metrics.plausibleHeader(140))
        #expect(!metrics.plausibleHeader(780))
        // Before the frame is measured, anything real goes.
        metrics.container = 0
        #expect(metrics.plausibleDock(700))
    }

    #if os(iOS)
    @Test func theThreadTopFollowsTheWindowsOwnSafeArea() {
        var metrics = ThreadMetrics()
        metrics.header = 96
        metrics.safeTop = 24
        #expect(metrics.thread.top == 120)
        metrics.dockTop = 600
        #expect(metrics.roomAboveDock == 464)  // 600 less the header, the safe area and a margin
    }

    @Test func aDockedKeyboardRaisesTheDockByItsHeightPastTheHomeIndicator() {
        let window = CGRect(x: 0, y: 0, width: 951, height: 669)
        let keyboard = CGRect(x: 0, y: 669 - 300, width: 951, height: 300)
        #expect(ThreadMetrics.keyboardRise(keyboard, in: window, safeBottom: 20) == 280)
        // Going away: below the window.
        #expect(ThreadMetrics.keyboardRise(keyboard.offsetBy(dx: 0, dy: 300), in: window, safeBottom: 20) == 0)
    }

    @Test func keyboardsThatAreNotDockedAreIgnored() {
        let window = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        // A floating keyboard in the middle of the window.
        #expect(ThreadMetrics.keyboardRise(CGRect(x: 300, y: 500, width: 320, height: 250), in: window, safeBottom: 20) == nil)
        // A full-window rectangle.
        #expect(ThreadMetrics.keyboardRise(window, in: window, safeBottom: 20) == nil)
        // A window with no height yet.
        #expect(ThreadMetrics.keyboardRise(CGRect(x: 0, y: 0, width: 10, height: 10), in: .zero, safeBottom: 0) == nil)
    }

    @Test func aKeyboardBelowAShortWindowLeavesItAlone() {
        // A window that stops above the keyboard (a resized iPad window) is not covered by it.
        let window = CGRect(x: 0, y: 0, width: 700, height: 600)
        let keyboard = CGRect(x: 0, y: 700, width: 700, height: 300)
        #expect(ThreadMetrics.keyboardRise(keyboard, in: window, safeBottom: 0) == 0)
    }
    #endif
}
