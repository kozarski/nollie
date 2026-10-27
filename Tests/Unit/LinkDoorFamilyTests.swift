#if os(macOS)
import CryptoKit
import Foundation
import Network
import Testing
@testable import NollieCore

/// Sharing a helper at home, enforced at the Nollie Link door: roles, what a member may reach, their
/// socket both ways, asks routed to the owner, and removal. The door's sources are compiled into this
/// bundle; the end-to-end cases run it on loopback in front of a fake Hermes.
struct LinkDoorFamilyTests {
    private let sam = UUID()

    private func access(helpers: [String] = ["career-sam"], privateNames: Set<String>? = [], chats: [LinkDoorDevices.Chat] = [],
                        small: Bool = false, kinds: Set<String> = []) -> LinkDoorMemberAccess {
        var made = LinkDoorMemberAccess(device: sam, member: .init(person: "Sam", helpers: helpers, small: small, chats: chats, locked: helpers,
                                                                  lockVersion: LinkDoorFamily.lockVersion),
                                        privateNames: privateNames)
        made.smallKinds = kinds
        return made
    }

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    private func refused(_ decision: LinkDoorMemberSocket.Up) -> Bool { if case .refuse = decision { true } else { false } }

    // MARK: Roles and state

    @Test func devicesLinkedBeforeSharingAreOwners() throws {
        let old = #"{"version":1,"installTag":"0123456789abcdef","away":false,"devices":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Corey's iPhone","credentialHash":"AAAA","linkedAt":1760000000}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let state = try decoder.decode(LinkDoorDevices.State.self, from: Data(old.utf8))
        let devices = try LinkDoorDevices(store: LinkDoorMemoryState(state))
        #expect(devices.devices.count == 1)
        #expect(devices.member(devices.devices[0].id) == nil)
        #expect(devices.members.isEmpty)
    }

    @Test func anInviteMakesAMemberAndAnOrdinaryCodeAnOwner() throws {
        let store = LinkDoorMemoryState()
        let devices = try LinkDoorDevices(store: store)
        let owner = try devices.claim(secret: devices.makeOffer().secret, name: "Corey's iPhone")
        #expect(owner.device.member == nil)

        let offer = devices.makeOffer(invite: .init(person: "Sam", helpers: ["career-sam"]))
        let member = try devices.claim(secret: offer.secret, name: "Sam's iPhone")
        #expect(member.device.member == .init(person: "Sam", helpers: ["career-sam"], locked: ["career-sam"], lockVersion: LinkDoorFamily.lockVersion))
        #expect(member.device.member?.small == false)
        #expect(devices.members.map(\.id) == [member.device.id])

        // Kept on disk, and read back the same.
        devices.addChat(.init(id: "20261026_120000_ab12cd", profile: "career-sam"), for: member.device.id)
        let again = try LinkDoorDevices(store: LinkDoorMemoryState(store.current))
        #expect(again.member(member.device.id)?.chats == [.init(id: "20261026_120000_ab12cd", profile: "career-sam")])
        #expect(again.member(owner.device.id) == nil)
    }

    @Test func changingHelpersForgetsChatsWithTheOnesTakenAway() throws {
        let devices = try LinkDoorDevices(store: LinkDoorMemoryState())
        let made = try devices.claim(secret: devices.makeOffer(invite: .init(person: "Sam", helpers: ["career-sam", "forager-sam"])).secret, name: "Sam's iPhone")
        let id = made.device.id
        devices.addChat(.init(id: "a1", profile: "career-sam"), for: id)
        devices.addChat(.init(id: "b1", profile: "forager-sam"), for: id)
        devices.addChat(.init(id: "a1", profile: "career-sam"), for: id)
        #expect(devices.member(id)?.chats.count == 2)
        #expect(try devices.updateMember(id, helpers: ["career-sam"], small: true))
        #expect(devices.member(id)?.chats == [.init(id: "a1", profile: "career-sam")])
        #expect(devices.member(id)?.small == true)
        // An owner's phone has no member record to change.
        let owner = try devices.claim(secret: devices.makeOffer().secret, name: "Corey's iPhone")
        #expect(try !devices.updateMember(owner.device.id, small: true))
    }

    @Test func aMembersChatsAreCapped() throws {
        let devices = try LinkDoorDevices(store: LinkDoorMemoryState())
        let id = try devices.claim(secret: devices.makeOffer(invite: .init(person: "Sam", helpers: ["career-sam"])).secret, name: "Sam's iPhone").device.id
        for index in 0..<(LinkDoorDevices.maximumChats + 5) { devices.addChat(.init(id: "c\(index)", profile: "career-sam"), for: id) }
        let chats = try #require(devices.member(id)?.chats)
        #expect(chats.count == LinkDoorDevices.maximumChats)
        #expect(chats.first?.id == "c5")
    }

    // MARK: Private helpers

    @Test func privateHelpersAreNeverShareable() {
        for name in ["private", "moss", "Moss", "moss-sam", "private_notes"] {
            #expect(LinkDoorFamily.isPrivate(name, list: []), "\(name)")
        }
        #expect(LinkDoorFamily.isPrivate("diary", list: ["diary"]))
        #expect(LinkDoorFamily.isPrivate("diary-sam", list: ["diary"]))
        #expect(!LinkDoorFamily.isPrivate("career-sam", list: ["diary"]))
        // A member is refused everything while the list can't be read.
        #expect(!access(privateNames: nil).allows(profile: "career-sam"))
        #expect(access().allows(profile: "career-sam"))
        #expect(!access(privateNames: ["career-sam"]).allows(profile: "career-sam"))
        #expect(!access().allows(profile: "career"))
    }

    @Test func profileNamesFollowHermesGrammar() {
        for good in ["career", "career-sam", "a", "x_1"] { #expect(LinkDoorFamily.validProfile(good)) }
        for bad in ["", "Career", "-x", "_x", "a/b", "a b", String(repeating: "a", count: 65), "café"] { #expect(!LinkDoorFamily.validProfile(bad), "\(bad)") }
    }

    // MARK: Routes per role

    @Test func familyRoutesAreTheDoorsOwn() {
        let id = UUID()
        #expect(LinkDoorFamily.route(method: "GET", path: "/nollie/family/me", websocket: false) == .me)
        #expect(LinkDoorFamily.route(method: "GET", path: "/nollie/family", websocket: false) == .overview)
        #expect(LinkDoorFamily.route(method: "POST", path: "/nollie/family/invite", websocket: false) == .invite)
        #expect(LinkDoorFamily.route(method: "PUT", path: "/nollie/family/members/\(id.uuidString)", websocket: false) == .update(id))
        #expect(LinkDoorFamily.route(method: "DELETE", path: "/nollie/family/members/\(id.uuidString)", websocket: false) == .remove(id))
        #expect(LinkDoorFamily.route(method: "POST", path: "/nollie/family/asks/srq-0123456789ab", websocket: false) == .answer("srq-0123456789ab"))
        for (method, path) in [("POST", "/nollie/family/me"), ("GET", "/nollie/family/invite"), ("PUT", "/nollie/family/members/x"),
                               ("POST", "/nollie/family/asks/a.b"), ("GET", "/nollie/family/"), ("GET", "/nollie/family/me/x"),
                               ("DELETE", "/nollie/family")] {
            #expect(LinkDoorFamily.route(method: method, path: path, websocket: false) == .refused, "\(method) \(path)")
        }
        #expect(LinkDoorFamily.route(method: "GET", path: "/nollie/family/me", websocket: true) == .refused)
        #expect(LinkDoorFamily.isFamilyPath("/nollie/family") && LinkDoorFamily.isFamilyPath("/nollie/family/x"))
        #expect(!LinkDoorFamily.isFamilyPath("/nollie/familyx"))
        // The owner's own allowlist doesn't know these paths: only the door answers them.
        #expect(LinkDoorPolicy.route(method: "GET", path: "/nollie/family", websocket: false) == .refused)
    }

    @Test func membersGetTheirOwnShortAllowlist() {
        func decide(_ method: String, _ target: String, socket: Bool = false) -> LinkDoorFamily.MemberRoute {
            let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
            return LinkDoorFamily.memberRoute(method: method, path: parts[0], query: parts.count > 1 ? parts[1] : nil, websocket: socket)
        }
        #expect(decide("GET", "/api/status") == .pass)
        #expect(decide("GET", "/api/health") == .pass)
        #expect(decide("GET", "/api/profiles") == .profiles)
        #expect(decide("GET", "/api/sessions?profile=career-sam&limit=20&archived=exclude") == .chats(profile: "career-sam"))
        #expect(decide("GET", "/api/sessions/20261026_1_ab?profile=career-sam") == .chat(.init(id: "20261026_1_ab", profile: "career-sam")))
        #expect(decide("PATCH", "/api/sessions/20261026_1_ab?profile=career-sam") == .chat(.init(id: "20261026_1_ab", profile: "career-sam")))
        #expect(decide("DELETE", "/api/sessions/20261026_1_ab?profile=career-sam") == .chat(.init(id: "20261026_1_ab", profile: "career-sam")))
        #expect(decide("GET", "/api/sessions/20261026_1_ab/messages?profile=career-sam&limit=50") == .chat(.init(id: "20261026_1_ab", profile: "career-sam")))
        #expect(decide("GET", "/api/ws", socket: true) == .socket)

        // Everything an owner may do beyond chatting, and every trick on the chat routes.
        let refusedTargets: [(String, String)] = [
            ("GET", "/api/profiles?profile=default"), ("POST", "/api/profiles"), ("GET", "/api/profiles/active"),
            ("PUT", "/api/profiles/career-sam/soul"), ("GET", "/api/profiles/career-sam/soul"), ("PATCH", "/api/profiles/career-sam"),
            ("GET", "/api/sessions"), ("GET", "/api/sessions?profile=career-sam&profile=default"),
            ("GET", "/api/sessions?profile=career-sam&cwd_prefix=/"), ("GET", "/api/sessions?profile=Career"),
            ("GET", "/api/sessions/search?profile=career-sam&q=x"),
            ("GET", "/api/sessions/20261026_1_ab"), ("GET", "/api/sessions/20261026_1_ab?profile=career-sam&full=1"),
            ("POST", "/api/sessions/20261026_1_ab?profile=career-sam"), ("GET", "/api/sessions/20261026_1_ab/messages"),
            ("GET", "/api/sessions/20261026_1_ab/latest-descendant?profile=career-sam"),
            ("GET", "/api/plugins/nollie-workflow/papertrail?bot=career-sam"), ("GET", "/api/plugins/nollie-workflow/memory?bot=career-sam"),
            ("GET", "/api/plugins/nollie-workflow/payments/cards"), ("GET", "/api/plugins/nollie-workflow/private-bots"),
            ("GET", "/api/plugins/nollie-workflow/posts"), ("GET", "/api/plugins/nollie-workflow/attention"),
            ("GET", "/api/plugins/kanban/board"), ("GET", "/api/cron/jobs"), ("POST", "/api/cron/jobs/x/trigger"),
            ("GET", "/api/media?path=/x"), ("GET", "/api/media/proxy?url=x"), ("GET", "/api/analytics/usage"),
            ("GET", "/api/skills"), ("GET", "/api/config/schema"), ("GET", "/api/model/options"),
            ("POST", "/api/plugins/nollie-computer/take-over?profile=career-sam"), ("GET", "/api/plugins/nollie-computer/preview"),
            ("GET", "/api/env"), ("GET", "/"), ("GET", "/api"),
        ]
        for (method, target) in refusedTargets { #expect(decide(method, target) == .refused, "\(method) \(target)") }
        #expect(decide("GET", "/api/plugins/kanban/events", socket: true) == .refused)
    }

    // MARK: A member's socket, phone to Hermes

    @Test func aMemberMayOnlyStartChatsWithSharedHelpers() {
        var socket = LinkDoorMemberSocket()
        let ok = socket.up(json(["jsonrpc": "2.0", "id": 1, "method": "session.create", "params": ["profile": "career-sam", "cols": 80]]), access: access())
        #expect(ok.0 == .forward)
        for params: [String: Any] in [
            ["profile": "career"],                                     // the owner's own Scout
            ["profile": "moss"], ["profile": "private"],               // never shareable
            ["cols": 80],                                              // no helper named
            ["profile": "career-sam", "cwd": "/Users/corey"],          // a folder on the Mac
            ["profile": "career-sam", "cwd_explicit": true],
            ["profile": "career-sam", "messages": [["role": "user", "content": "x"]]],
            ["profile": "career-sam", "parent_session_id": "20261020_1"],
            ["profile": "career-sam", "model": "other"], ["profile": "career-sam", "follow_profile_config": true],
        ] {
            #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": 2, "method": "session.create", "params": params]), access: access()).0), "\(params)")
        }
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": 3, "method": "session.create", "params": ["profile": "career-sam"]]),
                                  access: access(privateNames: ["career-sam"])).0))
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": 4, "method": "session.create", "params": ["profile": "career-sam"]]),
                                  access: access(privateNames: nil)).0))
        // A create without an id can't be followed, so it is refused.
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "method": "session.create", "params": ["profile": "career-sam"]]), access: access()).0))
    }

    @Test func aMemberMayOnlyOpenTheirOwnChats() {
        var socket = LinkDoorMemberSocket()
        let mine = LinkDoorDevices.Chat(id: "20261026_1_ab", profile: "career-sam")
        let theirs = access(chats: [mine])
        #expect(socket.up(json(["jsonrpc": "2.0", "id": 1, "method": "session.resume", "params": ["session_id": mine.id, "profile": "career-sam", "cols": 80]]), access: theirs).0 == .forward)
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": 2, "method": "session.resume", "params": ["session_id": "20261020_1_owner", "profile": "career-sam"]]), access: theirs).0))
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": 3, "method": "session.resume", "params": ["session_id": mine.id, "profile": "career"]]), access: theirs).0))
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": 4, "method": "session.resume", "params": ["session_id": mine.id]]), access: theirs).0))
        // A helper taken away (or marked Private) closes their old chats too.
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": 5, "method": "session.resume", "params": ["session_id": mine.id, "profile": "career-sam"]]),
                                  access: access(helpers: [], chats: [mine])).0))
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": 6, "method": "session.resume", "params": ["session_id": mine.id, "profile": "career-sam"]]),
                                  access: access(privateNames: ["career-sam"], chats: [mine])).0))
    }

    /// Opens a chat on a member socket: create, then Hermes's answer, as the door sees both.
    private func opened(_ socket: inout LinkDoorMemberSocket, access: LinkDoorMemberAccess, sid: String = "sid-1",
                        stored: String = "20261026_1_ab") -> [LinkDoorMemberSocket.Effect] {
        _ = socket.up(json(["jsonrpc": "2.0", "id": 7, "method": "session.create", "params": ["profile": "career-sam", "cols": 80]]), access: access)
        let answer = socket.down(json(["jsonrpc": "2.0", "id": 7, "result": ["session_id": sid, "stored_session_id": stored, "message_count": 0]]), access: access)
        #expect(answer.forward)
        return answer.effects
    }

    @Test func chatCallsNeedAChatThisConnectionOpened() {
        var socket = LinkDoorMemberSocket()
        let member = access()
        let send = json(["jsonrpc": "2.0", "id": 10, "method": "prompt.submit", "params": ["session_id": "sid-1", "profile": "career-sam", "text": "Hello"]])
        #expect(refused(socket.up(send, access: member).0))
        #expect(opened(&socket, access: member) == [.chat(.init(id: "20261026_1_ab", profile: "career-sam"))])
        #expect(socket.up(send, access: member).0 == .forward)
        #expect(socket.up(json(["jsonrpc": "2.0", "id": 11, "method": "session.interrupt", "params": ["session_id": "sid-1"]]), access: member).0 == .forward)
        #expect(socket.up(json(["jsonrpc": "2.0", "id": 12, "method": "image.attach_bytes", "params": ["session_id": "sid-1", "content_base64": "AAAA", "ext": "png"]]), access: member).0 == .forward)

        for (method, params) in [
            ("prompt.submit", ["session_id": "sid-2", "text": "x"]),                                 // someone else's live chat
            ("prompt.submit", ["session_id": "sid-1", "profile": "career", "text": "x"]),             // the wrong helper
            ("prompt.submit", ["session_id": "sid-1", "text": ["parts": []]]),                       // not plain text
            ("prompt.submit", ["session_id": "sid-1", "text": "x", "confirm_truncate": true]),
            ("pdf.attach", ["session_id": "sid-1", "path": "/Users/corey/taxes.pdf"]),
            ("file.attach", ["session_id": "sid-1", "path": "/etc/hosts"]),
            ("session.workspace.move", ["session_id": "sid-1", "cwd": "/"]),
            ("session.context_breakdown", ["session_id": "sid-1"]),
            ("config.set", ["key": "model", "value": "x"]), ("config.get", ["key": "profile"]),
            ("profiles.list", [:]), ("projects.list", [:]), ("commands.catalog", [:]),
            ("slash.exec", ["command": "/yolo"]), ("shell.exec", ["command": "id"]), ("request.answer", ["id": "srq-1", "result": [:]]),
            ("session.branch_stored", ["parent_session_id": "20261020_1"]),
        ] as [(String, [String: Any])] {
            #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": 20, "method": method, "params": params]), access: member).0), "\(method) \(params)")
        }
        // Helper made Private while the chat is open: the next call is refused.
        #expect(refused(socket.up(send, access: access(privateNames: ["career-sam"])).0))
    }

    // MARK: A member's socket, Hermes to phone

    @Test func hermesFramesReachAMemberOnlyWhenTheyAreTheirs() {
        var socket = LinkDoorMemberSocket()
        let member = access()
        #expect(socket.down(json(["jsonrpc": "2.0", "method": "event", "params": ["type": "gateway.ready"]]), access: member).forward)
        #expect(!socket.down(json(["jsonrpc": "2.0", "method": "event", "params": ["type": "skin.changed", "session_id": ""]]), access: member).forward)
        #expect(!socket.down(json(["jsonrpc": "2.0", "method": "event", "params": ["type": "message.delta", "session_id": "sid-1", "payload": ["text": "hi"]]]), access: member).forward)
        // An answer to a call nobody on this connection made.
        #expect(!socket.down(json(["jsonrpc": "2.0", "id": 99, "result": ["sessions": []]]), access: member).forward)
        _ = opened(&socket, access: member)
        #expect(socket.down(json(["jsonrpc": "2.0", "method": "event", "params": ["type": "message.delta", "session_id": "sid-1", "payload": ["text": "hi"]]]), access: member).forward)
        #expect(!socket.down(json(["jsonrpc": "2.0", "method": "event", "params": ["type": "message.delta", "session_id": "sid-owner", "payload": ["text": "x"]]]), access: member).forward)
        // Only questions and approvals; never a password or a secret.
        #expect(socket.down(json(["jsonrpc": "2.0", "id": "srq-aaaaaaaaaaaa", "method": "clarify", "params": ["session_id": "sid-1", "question": "Which one?"]]), access: member).forward)
        for method in ["sudo", "secret", "vault.unlock", "preview.read", "terminal.read", "tour"] {
            #expect(!socket.down(json(["jsonrpc": "2.0", "id": "srq-bbbbbbbbbbbb", "method": method, "params": ["session_id": "sid-1"]]), access: member).forward, "\(method)")
        }
        #expect(!socket.down(Data("not json".utf8), access: member).forward)
        // Hermes moved the chat to a new stored id: the member may open it by that id too.
        let moved = socket.down(json(["jsonrpc": "2.0", "method": "event", "params": ["type": "session.info", "session_id": "sid-1", "payload": ["stored_session_id": "20261026_2_cd"]]]), access: member)
        #expect(moved.forward)
        #expect(moved.effects == [.chat(.init(id: "20261026_2_cd", profile: "career-sam"))])
        // Frames for a chat whose helper became Private stop at once.
        #expect(!socket.down(json(["jsonrpc": "2.0", "method": "event", "params": ["type": "message.delta", "session_id": "sid-1"]]), access: access(privateNames: ["career-sam"])).forward)
    }

    // MARK: Asks

    private let approval: [String: Any] = ["session_id": "sid-1", "request_id": "ap-1", "description": "Send an email to Grandma",
                                           "command": "mail grandma@example.com", "pattern_key": "plugin_rule:nollie-ask-first:send:1",
                                           "choices": ["once", "deny"]]

    @Test func aMembersApprovalBecomesAnAskForTheOwner() throws {
        var socket = LinkDoorMemberSocket()
        let member = access()
        _ = opened(&socket, access: member)
        let seen = socket.down(json(["jsonrpc": "2.0", "id": "srq-0123456789ab", "method": "approval", "params": approval]), access: member)
        // The member still sees it, to show "Waiting for Corey".
        #expect(seen.forward)
        guard case .ask(let ask)? = seen.effects.first else { Issue.record("no ask"); return }
        #expect(ask.id == "srq-0123456789ab")
        #expect(ask.approvalID == "ap-1")
        #expect(ask.person == "Sam" && ask.profile == "career-sam" && ask.chat == "20261026_1_ab" && ask.device == sam)
        #expect(!ask.small)
        let shown = try #require(try JSONSerialization.jsonObject(with: ask.request) as? [String: Any])
        #expect(shown["description"] as? String == "Send an email to Grandma")
        #expect(shown["session_id"] == nil)

        // Their own Allow is refused, in every form; Session and Always too.
        for choice in ["once", "session", "always"] {
            #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": "srq-0123456789ab", "result": ["choice": choice]]), access: member).0), "\(choice)")
            #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": 30, "method": "approval.respond", "params": ["session_id": "sid-1", "request_id": "ap-1", "choice": choice]]), access: member).0))
        }
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": 31, "method": "approval.respond", "params": ["session_id": "sid-1", "choice": "deny", "all": true]]), access: member).0))
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": "srq-0123456789ab", "error": ["code": -32601, "message": "no"]]), access: member).0))
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": "srq-0123456789ab", "result": ["choice": "deny", "all": true]]), access: member).0))
        // Never mind passes, and the ask is gone.
        let never = socket.up(json(["jsonrpc": "2.0", "id": "srq-0123456789ab", "result": ["choice": "deny"]]), access: member)
        #expect(never.0 == .forward)
        #expect(never.1 == [.askGone("srq-0123456789ab")])
        // Answered once only.
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": "srq-0123456789ab", "result": ["choice": "deny"]]), access: member).0))
    }

    @Test func smallYesesCoverOnlySmallKindsAndNeverAskFirst() {
        var kinds = Set<String>(["read_only_example"])
        #expect(!LinkDoorFamily.isSmall(["pattern_key": "read_only_example"]))                     // the shipped list is empty
        #expect(LinkDoorFamily.isSmall(["pattern_key": "read_only_example"], kinds: kinds))
        #expect(!LinkDoorFamily.isSmall([:], kinds: kinds))
        #expect(!LinkDoorFamily.isSmall(["pattern_key": "read_only_example", "pattern_keys": ["execute_code"]], kinds: kinds))
        kinds.insert("plugin_rule:nollie-ask-first:send:1")
        kinds.insert("cua:click:background")
        #expect(!LinkDoorFamily.isSmall(["pattern_key": "plugin_rule:nollie-ask-first:send:1"], kinds: kinds))
        #expect(!LinkDoorFamily.isSmall(["pattern_key": "cua:click:background"], kinds: kinds))
        #expect(LinkDoorFamily.smallKinds.isEmpty)

        var socket = LinkDoorMemberSocket()
        let off = access(kinds: ["read_only_example"])
        let on = access(small: true, kinds: ["read_only_example"])
        _ = opened(&socket, access: on)
        var small = approval
        small["pattern_key"] = "read_only_example"
        _ = socket.down(json(["jsonrpc": "2.0", "id": "srq-111111111111", "method": "approval", "params": small]), access: on)
        _ = socket.down(json(["jsonrpc": "2.0", "id": "srq-222222222222", "method": "approval", "params": approval]), access: on)
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": "srq-111111111111", "result": ["choice": "once"]]), access: off).0))
        #expect(socket.up(json(["jsonrpc": "2.0", "id": "srq-111111111111", "result": ["choice": "once"]]), access: on).0 == .forward)
        #expect(refused(socket.up(json(["jsonrpc": "2.0", "id": "srq-222222222222", "result": ["choice": "once"]]), access: on).0))
    }

    @Test func asksAreTakenBackWhenHermesWithdrawsThem() {
        var socket = LinkDoorMemberSocket()
        let member = access()
        _ = opened(&socket, access: member)
        _ = socket.down(json(["jsonrpc": "2.0", "id": "srq-0123456789ab", "method": "approval", "params": approval]), access: member)
        let cancel = socket.down(json(["jsonrpc": "2.0", "method": "event", "params": ["type": "request.cancel", "session_id": "sid-1",
                                                                                       "payload": ["id": "srq-0123456789ab", "method": "approval", "reason": "resolved"]]]), access: member)
        #expect(cancel.forward)
        #expect(cancel.effects == [.askGone("srq-0123456789ab")])
    }

    @Test func aResumedChatsWaitingApprovalIsAnAskToo() {
        var socket = LinkDoorMemberSocket()
        let mine = LinkDoorDevices.Chat(id: "20261026_1_ab", profile: "career-sam")
        let member = access(chats: [mine])
        _ = socket.up(json(["jsonrpc": "2.0", "id": 5, "method": "session.resume", "params": ["session_id": mine.id, "profile": "career-sam"]]), access: member)
        let snapshot = socket.down(json(["jsonrpc": "2.0", "id": 5, "result": [
            "session_id": "sid-9", "stored_session_id": mine.id,
            "open_requests": [["id": "srq-0123456789ab", "method": "approval", "params": approval.merging(["session_id": "sid-9"]) { $1 }]],
        ]]), access: member)
        #expect(snapshot.forward)
        guard case .ask(let ask)? = snapshot.effects.first else { Issue.record("no ask"); return }
        #expect(ask.chat == mine.id && ask.approvalID == "ap-1")
    }

    @Test func theAsksListKeepsOnePerApprovalAndForgetsARemovedMember() {
        let asks = LinkDoorAsks()
        let other = UUID()
        func ask(_ id: String, _ device: UUID) -> LinkDoorAsk {
            LinkDoorAsk(id: id, approvalID: "ap-" + id, device: device, person: "Sam", profile: "career-sam", chat: "c", request: Data("{}".utf8), small: false, at: Date())
        }
        asks.add(ask("srq-1", sam))
        asks.add(ask("srq-1", sam))
        asks.add(ask("srq-2", other))
        #expect(asks.all.count == 2)
        #expect(asks.find("ap-srq-1")?.id == "srq-1")
        #expect(asks.removeAll(for: sam).map(\.id) == ["srq-1"])
        #expect(asks.all.map(\.id) == ["srq-2"])
        #expect(asks.remove("srq-2") != nil)
        #expect(asks.all.isEmpty)
    }

    @Test func membersSeeOnlySharedHelpersWithAFewFields() throws {
        let body = json(["profiles": [
            ["name": "default", "display_name": "Nollie", "path": "/Users/corey/.hermes", "skill_count": 40],
            ["name": "career", "display_name": "Scout"], ["name": "moss", "display_name": "Moss"],
            ["name": "career-sam", "display_name": "Scout", "path": "/Users/corey/x", "model": "m", "has_env": true],
        ]])
        let filtered = try #require(LinkDoorFamily.filterProfiles(body, access: access(helpers: ["career-sam", "moss"])))
        let object = try #require(try JSONSerialization.jsonObject(with: filtered) as? [String: Any])
        let profiles = try #require(object["profiles"] as? [[String: Any]])
        #expect(profiles.count == 1)
        #expect(profiles[0]["name"] as? String == "career-sam")
        #expect(profiles[0]["path"] == nil && profiles[0]["has_env"] == nil)
        #expect(profiles[0]["display_name"] as? String == "Scout")
    }

    // MARK: Household copies

    @Test func aCopysLockDownKeepsWhatWasOffAndDropsTheMacsReach() {
        let fresh = LinkDoorFamily.lockedToolsets(existing: nil)
        #expect(fresh == LinkDoorFamily.householdDropped)
        for name in ["terminal", "code_execution", "file", "browser", "computer_use", "session_search", "cronjob", "skills",
                     "nollie_calendar", "nollie_contacts", "nollie_payments", "nollie_sign_in", "mcp-cua", "connections", "discord"] {
            #expect(fresh.contains(name), "\(name)")
        }
        // Only talk, the web, questions, a to-do list, speech, pictures and its own memory stay.
        for kept in LinkDoorFamily.householdKept { #expect(!fresh.contains(kept), "\(kept)") }
        #expect(LinkDoorFamily.householdKept == ["web", "search", "clarify", "todo", "tts", "image_gen", "memory", "context_engine"])
        let merged = LinkDoorFamily.lockedToolsets(existing: ["tts", "terminal"])
        #expect(merged.first == "tts" && merged.filter { $0 == "terminal" }.count == 1)
        #expect(LinkDoorFamily.lockedToolsets(existing: "tts, x_search").prefix(2) == ["tts", "x_search"])
        #expect(LinkDoorFamily.isLockedDown(merged))
        #expect(!LinkDoorFamily.isLockedDown(["terminal", "file"]))
        #expect(!LinkDoorFamily.isLockedDown(nil))
    }

    @Test func everyOtherToolsetAndEveryMCPServerIsDroppedToo() {
        let required = LinkDoorFamily.requiredDrops(listed: ["web", "memory", "tts", "gmail", "drive_reader", "terminal"],
                                                   mcpServers: ["gmail", "filesystem"])
        // The owner's accounts, reads and sends alike: a plugin's toolsets and each MCP server.
        for name in ["gmail", "drive_reader", "mcp-gmail", "mcp-filesystem", "connections"] { #expect(required.contains(name), "\(name)") }
        for kept in ["web", "memory", "tts"] { #expect(!required.contains(kept), "\(kept)") }
        #expect(required.filter { $0 == "terminal" }.count == 1)
        let written = LinkDoorFamily.lockedToolsets(existing: ["image_gen"], required: required)
        #expect(LinkDoorFamily.isLockedDown(written, required: required))
        #expect(!LinkDoorFamily.isLockedDown(LinkDoorFamily.householdDropped, required: required))
    }

    @Test func theHouseholdCopyIsNamedForThePersonInHermessGrammar() {
        #expect(LinkDoorFamily.copyName(helper: "career", person: "Sam") == "career-sam")
        #expect(LinkDoorFamily.copyName(helper: "career", person: "Zoë Ann") == "career-zoeann")
        #expect(LinkDoorFamily.copyName(helper: "career", person: "🙂") == "career-home")
        let long = LinkDoorFamily.copyName(helper: String(repeating: "a", count: 64), person: "Alexandria-Rose")
        #expect(long.count <= 64 && long.hasSuffix("-alexandriarose"))
        #expect(LinkDoorFamily.validProfile(long))
    }

    @Test func onlyLockedDownCopiesAreReachable() {
        let never = LinkDoorMemberAccess(device: sam, member: .init(person: "Sam", helpers: ["career-sam"]), privateNames: [])
        #expect(!never.allows(profile: "career-sam"))
        // Locked down under the earlier rules (connected accounts kept): not reachable until locked again.
        let earlier = LinkDoorMemberAccess(device: sam, member: .init(person: "Sam", helpers: ["career-sam"], locked: ["career-sam"]),
                                           privateNames: [])
        #expect(!earlier.allows(profile: "career-sam"))
        let now = LinkDoorMemberAccess(device: sam, member: .init(person: "Sam", helpers: ["career-sam"], locked: ["career-sam"],
                                                                  lockVersion: LinkDoorFamily.lockVersion), privateNames: [])
        #expect(now.allows(profile: "career-sam"))
    }

    /// A member linked by the earlier build: a copy made by the phone, never locked down.
    private func olderMember(_ helpers: [String], locked: [String]? = nil) throws -> (LinkDoorDevices, UUID, String) {
        let credential = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let id = UUID()
        let device = LinkDoorDevices.Device(id: id, name: "Sam's iPhone", credentialHash: Data(SHA256.hash(data: credential)),
                                            linkedAt: Date(), lastActive: nil, member: .init(person: "Sam", helpers: helpers, locked: locked))
        let devices = try LinkDoorDevices(store: LinkDoorMemoryState(.init(installTag: "0123456789abcdef", devices: [device], away: false)))
        return (devices, id, credential.map { String(format: "%02x", $0) }.joined())
    }

    @Test(.timeLimit(.minutes(1))) func copiesMadeBeforeAreLockedDownOnTheirNextUse() async throws {
        let (devices, id, credential) = try olderMember(["career-sam"])
        let fixture = try await FamilyDoorFixture.start(devices: devices)
        defer { fixture.stop() }
        #expect(devices.member(id)?.locked == nil)
        let profiles: JSONValue = try await fixture.api(credential).get("/api/profiles")
        #expect(profiles["profiles"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["career-sam"])
        #expect(LinkDoorFamily.isLockedDown(fixture.hermes.disabled("career-sam")))
        #expect(devices.member(id)?.locked == ["career-sam"])
        #expect(devices.member(id)?.lockVersion == LinkDoorFamily.lockVersion)
        // Once is enough: the owner may change the copy afterwards as an ordinary bot on the Mac.
        let writes = fixture.hermes.configWrites
        let _: JSONValue = try await fixture.api(credential).get("/api/profiles")
        #expect(fixture.hermes.configWrites == writes)
    }

    @Test(.timeLimit(.minutes(1))) func copiesLockedUnderTheEarlierRulesLoseTheOwnersAccountsOnce() async throws {
        // As 66f5df9 left them: locked, connected accounts and MCP servers still on.
        let (devices, id, credential) = try olderMember(["career-sam"], locked: ["career-sam"])
        let fixture = try await FamilyDoorFixture.start(devices: devices)
        defer { fixture.stop() }
        let profiles: JSONValue = try await fixture.api(credential).get("/api/profiles")
        #expect(profiles["profiles"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["career-sam"])
        let dropped = try #require(fixture.hermes.disabled("career-sam"))
        for name in ["connections", "gmail", "mcp-gmail", "mcp-drive", "terminal"] { #expect(dropped.contains(name), "\(name)") }
        for kept in ["web", "memory"] { #expect(!dropped.contains(kept), "\(kept)") }
        #expect(dropped.first == "tts")
        #expect(devices.member(id)?.lockVersion == LinkDoorFamily.lockVersion)
        let writes = fixture.hermes.configWrites
        let _: JSONValue = try await fixture.api(credential).get("/api/profiles")
        #expect(fixture.hermes.configWrites == writes)
    }

    @Test(.timeLimit(.minutes(1))) func aCopyThatCantBeLockedDownIsNeverReached() async throws {
        let (devices, id, credential) = try olderMember(["career-bob"])
        let fixture = try await FamilyDoorFixture.start(devices: devices)
        defer { fixture.stop() }
        fixture.hermes.refuseConfig("career-bob")
        let before = fixture.hermes.requests.count
        let (_, http) = try await fixture.api(credential).raw("GET", "/api/profiles", body: nil, authenticated: true, answers: [503])
        #expect(http.statusCode == 503)
        #expect(!fixture.hermes.requests.dropFirst(before).contains { $0.line.hasPrefix("GET /api/profiles") })
        #expect(devices.member(id)?.locked == nil)
        // Nor is it shared with anyone new.
        let owner = try devices.claim(secret: devices.makeOffer().secret, name: "Corey's iPhone")
        let body = try JSONSerialization.data(withJSONObject: ["person": "Bob", "helpers": ["career"]])
        let (_, refused) = try await fixture.api(owner.credential).raw("POST", "/nollie/family/invite", body: (body, "application/json"),
                                                                        authenticated: true, answers: [503])
        #expect(refused.statusCode == 503)
        #expect(!devices.hasOpenOffer)
    }

    // MARK: End to end on loopback

    @Test(.timeLimit(.minutes(1))) func aMemberReachesOnlyTheirHelperAndTheOwnersRoutesStayTheOwners() async throws {
        let fixture = try await FamilyDoorFixture.start()
        defer { fixture.stop() }
        let door = fixture.door
        let owner = try door.devices.claim(secret: door.devices.makeOffer().secret, name: "Corey's iPhone")
        let member = try door.devices.claim(secret: door.devices.makeOffer(invite: .init(person: "Sam", helpers: ["career-sam"])).secret, name: "Sam's iPhone")
        door.devices.addChat(.init(id: "20261026_1_ab", profile: "career-sam"), for: member.device.id)
        try await door.refresh()
        let samAPI = fixture.api(member.credential)
        let coreyAPI = fixture.api(owner.credential)

        // Who am I.
        let me: JSONValue = try await samAPI.get("/nollie/family/me")
        #expect(me["role"]?.stringValue == "member")
        #expect(me["owner"]?.stringValue == "Corey")
        #expect(me["helpers"] == .array([.string("career-sam")]))
        let mine: JSONValue = try await coreyAPI.get("/nollie/family/me")
        #expect(mine["role"]?.stringValue == "owner")

        // Helpers: only the shared one.
        let profiles: JSONValue = try await samAPI.get("/api/profiles")
        #expect(profiles["profiles"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["career-sam"])

        // Their own chat is listed and readable; the owner's never reaches Hermes.
        let list: JSONValue = try await samAPI.get("/api/sessions", query: [URLQueryItem(name: "limit", value: "20")], profile: "career-sam")
        #expect(list["sessions"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["20261026_1_ab"])
        #expect(list["sessions"]?.arrayValue?.first?["system_prompt"] == nil)
        let messages: JSONValue = try await samAPI.get("/api/sessions/20261026_1_ab/messages", profile: "career-sam")
        #expect(messages["messages"] != nil)
        let before = fixture.hermes.requests.count
        for (path, profile) in [("/api/sessions/20261020_9_owner/messages", "career-sam"), ("/api/sessions/20261026_1_ab/messages", "career"),
                                ("/api/sessions", "career"), ("/api/plugins/nollie-workflow/papertrail", "career-sam"),
                                ("/api/plugins/nollie-workflow/memory", "career-sam"), ("/api/cron/jobs", "career-sam")] {
            let (_, http) = try await samAPI.raw("GET", path, profile: profile, body: nil, authenticated: true, answers: [403, 404])
            #expect(http.statusCode == 403 || http.statusCode == 404, "\(path) \(profile)")
        }
        #expect(!fixture.hermes.requests.dropFirst(before).contains { $0.line.contains("owner") || $0.line.contains("papertrail") || $0.line.contains("memory") || $0.line.contains("cron") })
        // The owner's routes are the owner's.
        for (method, path) in [("GET", "/nollie/family"), ("POST", "/nollie/stop"), ("POST", "/nollie/link/away/on"),
                               ("DELETE", "/nollie/family/members/\(owner.device.id.uuidString)")] {
            let (_, http) = try await samAPI.raw(method, path, body: nil, authenticated: true, answers: [403, 404])
            #expect(http.statusCode == 403, "\(method) \(path)")
        }
        #expect(door.lastStop == nil)
        #expect(door.devices.devices.count == 2)
        // Where to find the Mac: home only.
        let hosts: JSONValue = try await samAPI.get("/nollie/link/hosts")
        #expect(hosts["away"]?.boolValue == false)

        // The owner sees Sam, and can't share a Private or missing helper.
        let overview: JSONValue = try await coreyAPI.get("/nollie/family")
        #expect(overview["members"]?.arrayValue?.first?["person"]?.stringValue == "Sam")
        for (helpers, status) in [(["moss"], 403), (["diary"], 403), (["nobody"], 404), ([String](), 400)] {
            let body = try JSONSerialization.data(withJSONObject: ["person": "Alex", "helpers": helpers])
            let (_, http) = try await coreyAPI.raw("POST", "/nollie/family/invite", body: (body, "application/json"), authenticated: true, answers: [400, 403, 404])
            #expect(http.statusCode == status, "\(helpers)")
        }
        let body = try JSONSerialization.data(withJSONObject: ["person": "Alex", "helpers": ["career"]])
        let (data, http) = try await coreyAPI.raw("POST", "/nollie/family/invite", body: (body, "application/json"), authenticated: true)
        #expect(http.statusCode == 200)
        let code = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(code["owner"] as? String == "Corey")
        #expect(code["helpers"] as? [String] == ["Scout"])
        #expect((code["hosts"] as? [String])?.allSatisfy { !NollieTailnet.isTailnetHost($0) } == true)
        #expect(door.devices.hasOpenOffer)
        // Alex's own copy was made from the owner's Scout and locked down; the owner's Scout wasn't touched.
        #expect(fixture.hermes.created == ["career-alex": "career"])
        #expect(LinkDoorFamily.isLockedDown(fixture.hermes.disabled("career-alex")))
        #expect(fixture.hermes.disabled("career") == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aMembersApprovalGoesToTheOwnerAndRemovalCutsThemOff() async throws {
        let fixture = try await FamilyDoorFixture.start()
        defer { fixture.stop() }
        let door = fixture.door
        let owner = try door.devices.claim(secret: door.devices.makeOffer().secret, name: "Corey's iPhone")
        let member = try door.devices.claim(secret: door.devices.makeOffer(invite: .init(person: "Sam", helpers: ["career-sam"])).secret, name: "Sam's iPhone")
        try await door.refresh()
        // The door reads the Private list before a member's socket opens.
        _ = await door.family.privateNames()

        let session = HermesAPI.makeSession()
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: RequestSigner.websocketURL(gateway: fixture.gateway, token: member.credential, ticket: nil))
        socket.resume()
        guard case .string(let ready) = try await socket.receive() else { Issue.record("no ready frame"); return }
        #expect(ready.contains("gateway.ready"))

        // Someone else's helper: the door answers.
        try await socket.send(.string(#"{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"profile":"career","cols":80}}"#))
        guard case .string(let refusal) = try await socket.receive() else { Issue.record("no refusal"); return }
        #expect(refusal.contains("4403") && refusal.contains("\"id\":1"))
        // Their own: Hermes answers, and the door learns the chat.
        try await socket.send(.string(#"{"jsonrpc":"2.0","id":2,"method":"session.create","params":{"profile":"career-sam","cols":80}}"#))
        guard case .string(let created) = try await socket.receive() else { Issue.record("no answer"); return }
        #expect(created.contains("sid-1"))
        #expect(door.devices.member(member.device.id)?.chats == [.init(id: "20261026_1_ab", profile: "career-sam")])

        // Hermes says something about an owner's chat on the same Hermes: it never reaches Sam.
        fixture.hermes.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"sid-owner","payload":{"text":"secret"}}}"#)
        // Scout wants to send an email: Sam sees it, the owner gets the ask.
        fixture.hermes.push(#"{"jsonrpc":"2.0","id":"srq-0123456789ab","method":"approval","params":{"session_id":"sid-1","request_id":"ap-1","description":"Send an email to Grandma","pattern_key":"plugin_rule:nollie-ask-first:send:1","choices":["once","deny"]}}"#)
        guard case .string(let asked) = try await socket.receive() else { Issue.record("no approval frame"); return }
        #expect(asked.contains("srq-0123456789ab") && !asked.contains("secret"))
        #expect(await NollieLinkDoorTests.eventually { door.asks.all.count == 1 })

        // Sam's Allow is the door's to refuse.
        try await socket.send(.string(#"{"jsonrpc":"2.0","id":"srq-0123456789ab","result":{"choice":"once"}}"#))
        guard case .string(let no) = try await socket.receive() else { Issue.record("no refusal"); return }
        #expect(no.contains("4403"))
        #expect(!fixture.hermes.socketTexts.contains { $0.contains("\"choice\":\"once\"") })

        // The owner's phone sees the ask and allows it; Hermes gets the answer.
        let coreyAPI = fixture.api(owner.credential)
        let overview: JSONValue = try await coreyAPI.get("/nollie/family")
        let ask = try #require(overview["asks"]?.arrayValue?.first)
        #expect(ask["person"]?.stringValue == "Sam")
        #expect(ask["helper"]?.stringValue == "career-sam")
        #expect(ask["request"]?["description"]?.stringValue == "Send an email to Grandma")
        let samAPI = fixture.api(member.credential)
        let choice = try JSONSerialization.data(withJSONObject: ["choice": "once"])
        let (_, samTry) = try await samAPI.raw("POST", "/nollie/family/asks/srq-0123456789ab", body: (choice, "application/json"), authenticated: true, answers: [403])
        #expect(samTry.statusCode == 403)
        let (_, allowed) = try await coreyAPI.raw("POST", "/nollie/family/asks/srq-0123456789ab", body: (choice, "application/json"), authenticated: true)
        #expect(allowed.statusCode == 200)
        #expect(fixture.hermes.socketTexts.contains { $0.contains("approval.respond") && $0.contains("\"request_id\":\"ap-1\"") && $0.contains("\"choice\":\"once\"") })
        #expect(door.asks.all.isEmpty)

        // Another ask, then Remove: Sam's socket closes at once and the ask is answered Deny.
        fixture.hermes.push(#"{"jsonrpc":"2.0","id":"srq-ffffffffffff","method":"approval","params":{"session_id":"sid-1","request_id":"ap-2","description":"Delete a file","choices":["once","deny"]}}"#)
        _ = try await socket.receive()
        #expect(await NollieLinkDoorTests.eventually { door.asks.all.count == 1 })
        let removedAt = ContinuousClock.now
        let (_, removed) = try await coreyAPI.raw("DELETE", "/nollie/family/members/\(member.device.id.uuidString)", body: nil, authenticated: true)
        #expect(removed.statusCode == 200)
        do {
            while true { _ = try await socket.receive() }
        } catch {
            #expect(ContinuousClock.now - removedAt < .seconds(1))
        }
        #expect(door.liveSessions(for: member.device.id) == 0)
        #expect(door.asks.all.isEmpty)
        #expect(await NollieLinkDoorTests.eventually { fixture.hermes.socketTexts.contains { $0.contains("\"request_id\":\"ap-2\"") && $0.contains("\"choice\":\"deny\"") } })
        await #expect(throws: (any Error).self) { let _: JSONValue = try await samAPI.get("/nollie/family/me") }
    }
}

/// A door on loopback in front of a fake Hermes that knows a few helpers, a Private list and two chats.
struct FamilyDoorFixture {
    let door: LinkDoor
    let hermes: FamilyFakeHermes
    let identityName: String
    let gateway: GatewayURL
    let trustOwner = UUID()

    static func start(devices given: LinkDoorDevices? = nil) async throws -> FamilyDoorFixture {
        let hermes = try await FamilyFakeHermes.start()
        let name = "com.coreykozarski.nollie.link.test." + UUID().uuidString
        let identity = try LinkDoorIdentity.loadOrCreate(name: name)
        let devices = try given ?? LinkDoorDevices(store: LinkDoorMemoryState())
        let port = hermes.port
        let configuration = LinkDoor.Configuration(name: "Test Mac", port: 0, loopbackOnly: true, acceptLoopback: true, advertise: false, owner: "Corey")
        let door = LinkDoor(configuration: configuration, identity: identity, devices: devices) {
            LinkDoor.Upstream(port: port, token: DoorFixture.upstreamToken)
        }
        door.hostsProvider = { (["192.168.1.20", "studio.local", "studio.tail1234.ts.net"], "ready") }
        _ = devices.makeOffer()
        let listening = try await door.start()
        devices.cancelOffer()
        let gateway = try GatewayURL.normalize("https://127.0.0.1:\(listening)")
        let fixture = FamilyDoorFixture(door: door, hermes: hermes, identityName: name, gateway: gateway)
        GatewayTrust.shared.register(pin: identity.pin, host: "127.0.0.1", port: Int(listening), owner: fixture.trustOwner)
        return fixture
    }

    func api(_ credential: String) -> HermesAPI {
        HermesAPI(gateway: gateway, signer: RequestSigner(authMode: .sessionToken, secrets: .init(sessionToken: credential, linkedDevice: true)))
    }

    func stop() {
        GatewayTrust.shared.forget(owner: trustOwner)
        door.stop()
        hermes.stop()
        LinkDoorIdentity.remove(name: identityName)
    }
}

/// Hermes for sharing tests: helpers, the Private list, chats, and a socket that answers chat calls
/// and can be told to send the phone a frame.
final class FamilyFakeHermes: @unchecked Sendable {
    struct Seen: Sendable { let line: String; let head: String }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "nollie.tests.family-hermes")
    private let seen = DoorTestBox<[Seen]>([])
    private let texts = DoorTestBox<[String]>([])
    private let sockets = DoorTestBox<[NWConnection]>([])
    /// Each profile's `agent.disabled_toolsets` as the door wrote it, copies made, and profiles whose
    /// config can't be written.
    private let configs = DoorTestBox<[String: [String]]>(["career-sam": ["tts"]])
    private let made = DoorTestBox<[String: String]>([:])
    private let refused = DoorTestBox<Set<String>>([])
    private let writes = DoorTestBox(0)
    private(set) var port = 0
    var created: [String: String] { made.withLock { $0 } }
    var configWrites: Int { writes.withLock { $0 } }
    func disabled(_ profile: String) -> [String]? { configs.withLock { $0[profile] } }
    func refuseConfig(_ profile: String) { refused.withLock { _ = $0.insert(profile) } }
    var requests: [Seen] { seen.withLock { $0 } }
    var socketTexts: [String] { texts.withLock { $0 } }

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> FamilyFakeHermes {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let fake = FamilyFakeHermes(listener: try NWListener(using: parameters))
        fake.listener.newConnectionHandler = { [weak fake] connection in fake?.serve(connection) }
        fake.port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let once = DoorTestBox(Optional(continuation))
            fake.listener.stateUpdateHandler = { [weak fake] state in
                switch state {
                case .ready: once.withLock { $0?.resume(returning: Int(fake?.listener.port?.rawValue ?? 0)); $0 = nil }
                case .failed(let error): once.withLock { $0?.resume(throwing: error); $0 = nil }
                default: break
                }
            }
            fake.listener.start(queue: fake.queue)
        }
        return fake
    }

    func stop() {
        listener.cancel()
        sockets.withLock { $0.forEach { $0.cancel() }; $0 = [] }
    }

    /// Sends every phone socket that is open one text frame from Hermes.
    func push(_ text: String) {
        let frame = LinkDoorWebSocket.message(.text(Data(text.utf8)), masked: false)
        for socket in sockets.withLock({ $0 }) { socket.send(content: frame, completion: .contentProcessed { _ in }) }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error == nil && !complete { self.read(connection, buffer) } else { connection.cancel() }
                return
            }
            let head = String(decoding: buffer[..<end.upperBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = buffer[end.upperBound...]
            guard body.count >= length else {
                if error == nil && !complete { self.read(connection, buffer) } else { connection.cancel() }
                return
            }
            let line = String(head.split(separator: "\r\n").first ?? "")
            self.seen.withLock { $0.append(Seen(line: line, head: head)) }
            self.answer(connection, line: line, head: head, body: Data(body.prefix(length)))
        }
    }

    private func answer(_ connection: NWConnection, line: String, head: String, body sent: Data = Data()) {
        if line.hasPrefix("GET /api/ws") {
            let key = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) } ?? ""
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            var reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
            reply.append(LinkDoorWebSocket.message(.text(Data(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready"}}"#.utf8)), masked: false))
            sockets.withLock { $0.append(connection) }
            connection.send(content: reply, completion: .contentProcessed { _ in
                self.drain(connection, reader: LinkDoorWebSocket.ClientReader(maximumMessage: 1 << 20))
            })
            return
        }
        let method = String(line.split(separator: " ").first ?? "")
        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let path = target.split(separator: "?").first.map(String.init) ?? target
        let profile = URLComponents(string: target)?.queryItems?.first { $0.name == "profile" }?.value ?? ""
        let fields = (try? JSONSerialization.jsonObject(with: sent)) as? [String: Any] ?? [:]
        var body: String
        switch (method, path) {
        case ("POST", "/api/profiles"):
            let name = fields["name"] as? String ?? "", from = fields["clone_from"] as? String ?? ""
            made.withLock { $0[name] = from }
            body = #"{"ok":true}"#
        case ("GET", "/api/config"):
            let list = configs.withLock { $0[profile] } ?? []
            // Every copy carries the owner's MCP servers, as Hermes's profile copy does.
            let config: [String: Any] = ["agent": ["disabled_toolsets": list],
                                         "mcp_servers": ["gmail": ["command": "gmail-mcp"], "drive": ["url": "https://example.invalid/mcp"]]]
            body = String(decoding: try! JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        case ("GET", "/api/tools/toolsets"):
            body = #"[{"name":"web"},{"name":"terminal"},{"name":"file"},{"name":"memory"},{"name":"tts"},{"name":"connections"},{"name":"gmail"}]"#
        case ("PUT", "/api/config"):
            if refused.withLock({ $0.contains(profile) }) {
                body = #"{"detail":"not here"}"#
            } else {
                let agent = ((fields["config"] as? [String: Any])?["agent"] as? [String: Any])?["disabled_toolsets"] as? [String] ?? []
                configs.withLock { $0[profile] = agent }
                writes.withLock { $0 += 1 }
                body = #"{"ok":true}"#
            }
        default:
            body = route(path)
        }
        if path == "/api/profiles", method == "GET" {
            // Copies the door made show up in the list, as Hermes's own would.
            var object = try! JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
            var list = object["profiles"] as! [[String: Any]]
            for name in made.withLock({ $0.keys.sorted() }) where !list.contains(where: { $0["name"] as? String == name }) {
                list.append(["name": name, "display_name": "Scout"])
            }
            object["profiles"] = list
            body = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let status = body.contains("not here") ? "404 Not Found" : "200 OK"
        let reply = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func route(_ path: String) -> String {
        let body: String
        switch path {
        case "/api/status": body = #"{"version":"fake"}"#
        case "/api/plugins/nollie-workflow/private-bots": body = #"{"profiles":["diary"],"saved":true}"#
        case "/api/profiles":
            body = #"{"profiles":[{"name":"default","display_name":"Nollie","path":"/Users/corey/.hermes"},{"name":"career","display_name":"Scout"},{"name":"career-sam","display_name":"Scout"},{"name":"career-bob","display_name":"Scout"},{"name":"moss"},{"name":"diary"}]}"#
        case "/api/sessions/20261026_1_ab":
            body = #"{"id":"20261026_1_ab","title":"Birthday ideas","started_at":1761480000,"last_active":1761480100,"system_prompt":"You are Scout"}"#
        case "/api/sessions/20261026_1_ab/messages": body = #"{"messages":[]}"#
        default: body = #"{"detail":"not here"}"#
        }
        return body
    }

    /// Records what the phone sent and answers the calls a chat makes.
    private func drain(_ connection: NWConnection, reader: LinkDoorWebSocket.ClientReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var reader = reader
            if let messages = try? reader.feed(data ?? Data()) {
                for case .text(let text) in messages {
                    self.texts.withLock { $0.append(String(decoding: text, as: UTF8.self)) }
                    self.reply(to: text, on: connection)
                }
            }
            if complete || error != nil { connection.cancel() } else { self.drain(connection, reader: reader) }
        }
    }

    private func reply(to text: Data, on connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: text) as? [String: Any], let method = object["method"] as? String,
              let id = object["id"] else { return }
        let result: [String: Any]
        switch method {
        case "session.create": result = ["session_id": "sid-1", "stored_session_id": "20261026_1_ab", "message_count": 0, "messages": []]
        case "approval.respond": result = ["resolved": 1]
        default: result = [:]
        }
        let answer = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        connection.send(content: LinkDoorWebSocket.message(.text(answer), masked: false), completion: .contentProcessed { _ in })
    }
}
#endif
