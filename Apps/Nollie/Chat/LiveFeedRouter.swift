import Foundation
import NollieCore

/// Where a Watch screen gets its live picture. On the Mac, a chat on this Mac's own Nollie Runtime
/// plays straight from the Mac's host, with no network in between; everything else (a linked
/// iPhone, another gateway, the demo) opens `/nollie/live` on the chat's gateway.
@MainActor
enum LiveFeedRouter {
    /// Set by the Mac app at launch. Answers the in-process feed for a chat on this Mac's own
    /// runtime, or nil when the chat lives somewhere else.
    static var local: ((_ connection: GatewayConnection, _ profile: String, _ sessionID: String) -> (any LiveFeed)?)?
}
