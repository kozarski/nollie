import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// A chat joining its session again after the connection came back. A socket that dropped
/// meanwhile is only "not yet" (the next reconnect does it again); a slow gateway gets one more
/// ask before the banner; every other failure is said out loud.
@MainActor @Suite struct ReconnectReattachTests {
    private static let bannerStart = "could not be picked up again"

    private func openChat() throws -> ChatSession { try ChatFixtures.chat(stored: "session-a", named: "reattach") }

    private final class Asked { var times = 0 }

    @Test func aSocketThatDroppedIsStaleWithNoBanner() async throws {
        let chat = try openChat()
        let asked = Asked()
        chat.gatewayStandIn = { _, _ in asked.times += 1; throw SocketError.notConnected }
        await chat.reattachAfterReconnect()
        #expect(asked.times == 1)
        #expect(chat.stale)
        #expect(chat.banner == nil)
    }

    @Test func aSlowGatewayIsAskedAgainThenTheBannerShows() async throws {
        let chat = try openChat()
        let asked = Asked()
        chat.gatewayStandIn = { _, _ in asked.times += 1; throw SocketError.timeout("session.resume") }
        await chat.reattachAfterReconnect()
        #expect(asked.times == 2)
        #expect(chat.stale)
        #expect(chat.banner?.contains(Self.bannerStart) == true)
    }

    @Test func aClosedSocketWithAReasonIsSaid() async throws {
        let chat = try openChat()
        chat.gatewayStandIn = { _, _ in throw SocketError.closed(code: 1011, reason: "gateway fell over") }
        await chat.reattachAfterReconnect()
        #expect(chat.stale)
        #expect(chat.banner?.contains(Self.bannerStart) == true)
    }
}
