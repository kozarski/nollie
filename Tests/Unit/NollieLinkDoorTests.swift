#if os(macOS)
import CryptoKit
import Foundation
import Network
import Security
import Testing
@testable import NollieCore

/// The Nollie Link door from Nollie Runtime, compiled into this test bundle: its parser,
/// policies, offers and credentials, and the whole door on loopback in front of a fake Hermes.
struct NollieLinkDoorTests {
    // MARK: Parser

    private func head(_ lines: [String], body: String = "") -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    @Test func parserReadsAStrictRequest() throws {
        let request = try LinkDoorHTTP.parseRequest(head(["POST /api/sessions/abc/messages?profile=default HTTP/1.1",
                                                          "Host: 192.168.1.20:52345", "Content-Length: 2",
                                                          "X-Hermes-Session-Token:  abc ", "Accept: application/json"], body: "{}"))
        #expect(request.method == "POST")
        #expect(request.path == "/api/sessions/abc/messages")
        #expect(request.query == "profile=default")
        #expect(request.contentLength == 2)
        #expect(request.value("x-hermes-session-token") == "abc")
        #expect(!request.isWebSocketUpgrade)

        let socket = try LinkDoorHTTP.parseRequest(head(["GET /api/ws?token=abc HTTP/1.1", "Host: h", "Upgrade: websocket",
                                                         "Connection: keep-alive, Upgrade", "Sec-WebSocket-Version: 13",
                                                         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="]))
        #expect(socket.isWebSocketUpgrade)
        #expect(socket.queryItems.first?.value == "abc")
    }

    /// Each of these must be refused, and with the right kind of answer.
    @Test func parserRefusesMalformedCorpus() {
        let base = ["Host: h"]
        let corpus: [(String, Data)] = [
            ("bare LF", Data("GET / HTTP/1.1\nHost: h\n\n".utf8)),
            ("bare CR", Data("GET / HTTP/1.1\rHost: h\r\n\r\n".utf8)),
            ("HTTP/1.0", head(["GET / HTTP/1.0"] + base)),
            ("HTTP/2", head(["GET / HTTP/2"] + base)),
            ("lowercase method", head(["get / HTTP/1.1"] + base)),
            ("CONNECT", head(["CONNECT h:443 HTTP/1.1"] + base)),
            ("TRACE", head(["TRACE / HTTP/1.1"] + base)),
            ("absolute target", head(["GET http://h/api/status HTTP/1.1"] + base)),
            ("asterisk", head(["OPTIONS * HTTP/1.1"] + base)),
            ("two spaces", head(["GET  / HTTP/1.1"] + base)),
            ("missing version", head(["GET /"] + base)),
            ("no host", head(["GET / HTTP/1.1"])),
            ("two hosts", head(["GET / HTTP/1.1", "Host: a", "Host: b"])),
            ("empty host", head(["GET / HTTP/1.1", "Host:"])),
            ("folded header", head(["GET / HTTP/1.1", "Host: h", " folded"])),
            ("space before colon", head(["GET / HTTP/1.1", "Host : h"])),
            ("no colon", head(["GET / HTTP/1.1", "Host h"])),
            ("chunked", head(["POST /api/sessions HTTP/1.1", "Host: h", "Transfer-Encoding: chunked"])),
            ("two lengths", head(["POST /api/sessions HTTP/1.1", "Host: h", "Content-Length: 1", "Content-Length: 1"])),
            ("signed length", head(["POST /api/sessions HTTP/1.1", "Host: h", "Content-Length: +1"])),
            ("hex length", head(["POST /api/sessions HTTP/1.1", "Host: h", "Content-Length: 0x10"])),
            ("GET body", head(["GET /api/status HTTP/1.1", "Host: h", "Content-Length: 1"], body: "x")),
            ("expect", head(["POST /api/sessions HTTP/1.1", "Host: h", "Expect: 100-continue", "Content-Length: 1"])),
            ("dot segment", head(["GET /api/../env HTTP/1.1"] + base)),
            ("dot", head(["GET /api/./status HTTP/1.1"] + base)),
            ("encoded dot", head(["GET /api/%2e%2e/env HTTP/1.1"] + base)),
            ("encoded slash", head(["GET /api%2fenv HTTP/1.1"] + base)),
            ("encoded backslash", head(["GET /api%5cenv HTTP/1.1"] + base)),
            ("backslash", head(["GET /api\\env HTTP/1.1"] + base)),
            ("double slash", head(["GET //api/status HTTP/1.1"] + base)),
            ("empty segment", head(["GET /api//status HTTP/1.1"] + base)),
            ("bad escape", head(["GET /api/%zz HTTP/1.1"] + base)),
            ("NUL escape", head(["GET /api/%00 HTTP/1.1"] + base)),
            ("fragment", head(["GET /api/status#x HTTP/1.1"] + base)),
            ("NUL byte", Data("GET / HTTP/1.1\r\nHost: h\0\r\n\r\n".utf8)),
            ("non-ASCII header", head(["GET / HTTP/1.1", "Host: h", "X-Name: caf\u{e9}"])),
            ("upgrade h2c", head(["GET / HTTP/1.1", "Host: h", "Upgrade: h2c", "Connection: Upgrade"])),
            ("socket without key", head(["GET /api/ws HTTP/1.1", "Host: h", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Version: 13"])),
            ("socket short key", head(["GET /api/ws HTTP/1.1", "Host: h", "Upgrade: websocket", "Connection: Upgrade",
                                       "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: c2hvcnQ="])),
            ("socket version 8", head(["GET /api/ws HTTP/1.1", "Host: h", "Upgrade: websocket", "Connection: Upgrade",
                                       "Sec-WebSocket-Version: 8", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="])),
            ("socket POST", head(["POST /api/ws HTTP/1.1", "Host: h", "Upgrade: websocket", "Connection: Upgrade",
                                  "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="])),
            ("socket without connection", head(["GET /api/ws HTTP/1.1", "Host: h", "Upgrade: websocket",
                                                "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="])),
        ]
        for (name, data) in corpus {
            do {
                _ = try LinkDoorHTTP.parseRequest(data)
                Issue.record("accepted: \(name)")
            } catch {
                #expect(error != .incomplete, "\(name) should be refused, not waited out")
            }
        }
    }

    @Test func parserEnforcesSizeLimits() {
        let longHead = head(["GET / HTTP/1.1", "Host: h", "X-Pad: " + String(repeating: "a", count: 17_000)])
        #expect(throws: LinkDoorHTTP.Failure.headTooLarge) { try LinkDoorHTTP.parseRequest(longHead) }
        // A head that never ends is refused once it passes the limit, without waiting for more.
        let endless = Data(("GET / HTTP/1.1\r\nHost: h\r\n" + String(repeating: "X-A: b\r\n", count: 3000)).utf8)
        #expect(throws: LinkDoorHTTP.Failure.headTooLarge) { try LinkDoorHTTP.parseRequest(endless) }
        let many = head(["GET / HTTP/1.1", "Host: h"] + (0..<64).map { "X-\($0): v" })
        #expect(throws: LinkDoorHTTP.Failure.tooManyHeaders) { try LinkDoorHTTP.parseRequest(many) }
        let longTarget = head(["GET /" + String(repeating: "a", count: 5000) + " HTTP/1.1", "Host: h"])
        #expect(throws: LinkDoorHTTP.Failure.headTooLarge) { try LinkDoorHTTP.parseRequest(longTarget) }
        let bigBody = head(["POST /api/files/upload HTTP/1.1", "Host: h", "Content-Length: 67108865"])
        #expect(throws: LinkDoorHTTP.Failure.bodyTooLarge) { try LinkDoorHTTP.parseRequest(bigBody) }
        let hugeNumber = head(["POST /api/files/upload HTTP/1.1", "Host: h", "Content-Length: 99999999999999999999"])
        #expect(throws: LinkDoorHTTP.Failure.self) { try LinkDoorHTTP.parseRequest(hugeNumber) }
        #expect(throws: LinkDoorHTTP.Failure.incomplete) { try LinkDoorHTTP.parseRequest(Data("GET / HTTP/1.1\r\nHost: h\r\n".utf8)) }
        #expect(throws: LinkDoorHTTP.Failure.incomplete) { try LinkDoorHTTP.parseRequest(Data("GET / HTTP/1.1\r".utf8)) }
    }

    /// Seeded mutations of valid requests: whatever the parser accepts must still satisfy
    /// every rule, and nothing may crash or hang.
    @Test func parserSurvivesMutationFuzzing() {
        var generator = SeededGenerator(seed: 0x6E6F6C6C6965)
        let seeds = [
            head(["GET /api/status HTTP/1.1", "Host: 10.0.0.2:52345", "X-Hermes-Session-Token: " + String(repeating: "a", count: 64)]),
            head(["POST /api/sessions HTTP/1.1", "Host: h", "Content-Length: 5", "Content-Type: application/json"], body: "{\"a\"}"),
            head(["GET /api/ws?token=abc HTTP/1.1", "Host: h", "Upgrade: websocket", "Connection: Upgrade",
                  "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="]),
        ]
        let alphabet: [UInt8] = Array("\r\n :/%.?&=\0\t\\#".utf8) + [0x80, 0xFF, 0x7F]
        var accepted = 0
        for iteration in 0..<6000 {
            var bytes = [UInt8](seeds[iteration % seeds.count])
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                switch Int.random(in: 0..<4, using: &generator) {
                case 0: bytes[index] = alphabet.randomElement(using: &generator)!
                case 1: bytes.insert(alphabet.randomElement(using: &generator)!, at: index)
                case 2: if bytes.count > 1 { bytes.remove(at: index) }
                default: bytes[index] = UInt8.random(in: 0...255, using: &generator)
                }
            }
            guard let request = try? LinkDoorHTTP.parseRequest(Data(bytes)) else { continue }
            accepted += 1
            #expect(request.headLength <= bytes.count)
            #expect(LinkDoorHTTP.methods.contains(request.method))
            #expect(request.path.hasPrefix("/") && !request.path.contains("..") && !request.path.contains("\\"))
            #expect(!request.path.contains("//"))
            for header in request.headers {
                #expect(!header.name.isEmpty && !header.value.contains("\r") && !header.value.contains("\n"))
                #expect(header.value.unicodeScalars.allSatisfy { $0.value == 9 || (32...126).contains($0.value) })
            }
            #expect(request.values("host").count == 1)
            #expect(request.values("transfer-encoding").isEmpty)
        }
        #expect(accepted > 0)
    }

    @Test func responseHeadIsRewrittenToClose() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\nSet-Cookie: a=b\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let response = try LinkDoorHTTP.parseResponse(raw)
        #expect(response.status == 200)
        let text = String(decoding: LinkDoorPolicy.downstreamHead(response), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Connection: close\r\n") && text.contains("Content-Length: 2\r\n"))
        #expect(!text.contains("keep-alive") && !text.contains("Keep-Alive") && !text.contains("Set-Cookie"))
        #expect(throws: LinkDoorHTTP.Failure.self) { try LinkDoorHTTP.parseResponse(Data("HTTP/1.1 2000 OK\r\n\r\n".utf8)) }
        #expect(throws: LinkDoorHTTP.Failure.self) { try LinkDoorHTTP.parseResponse(Data("SSH-2.0\r\n\r\n".utf8)) }
    }

    // MARK: Policy

    @Test func sourceAddressesArePrivateOnly() {
        func v4(_ text: String, loopback: Bool = false) -> Bool {
            LinkDoorPolicy.allowsSource(.hostPort(host: .ipv4(IPv4Address(text)!), port: 1), allowLoopback: loopback)
        }
        func v6(_ text: String, loopback: Bool = false) -> Bool {
            LinkDoorPolicy.allowsSource(.hostPort(host: .ipv6(IPv6Address(text)!), port: 1), allowLoopback: loopback)
        }
        for allowed in ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.1", "192.168.1.30", "169.254.10.1",
                        "100.64.0.1", "100.127.255.254"] { #expect(v4(allowed), "\(allowed)") }
        for refused in ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "192.169.0.1", "100.63.255.255", "100.128.0.1",
                        "0.0.0.0", "255.255.255.255", "224.0.0.251", "127.0.0.1", "11.0.0.1"] { #expect(!v4(refused), "\(refused)") }
        #expect(v4("127.0.0.1", loopback: true))
        for allowed in ["fd7a:115c:a1e0::1", "fc00::1", "fe80::1", "febf::1", "::ffff:192.168.1.2"] { #expect(v6(allowed), "\(allowed)") }
        for refused in ["2001:4860:4860::8888", "::1", "::", "ff02::fb", "fec0::1", "::ffff:8.8.8.8", "::ffff:127.0.0.1", "2001:db8::1"] {
            #expect(!v6(refused), "\(refused)")
        }
        #expect(v6("::1", loopback: true))
        #expect(!LinkDoorPolicy.allowsSource(.hostPort(host: .name("studio.local", nil), port: 1), allowLoopback: true))
        #expect(!LinkDoorPolicy.allowsSource(.service(name: "x", type: "_nollie._tcp", domain: "local.", interface: nil), allowLoopback: true))
    }

    @Test func routeAllowlistRefusesAdminAndPluginManagement() {
        let allowed: [(String, String, Bool)] = [
            ("GET", "/api/status", false), ("GET", "/api/ws", true), ("GET", "/api/sessions", false),
            ("GET", "/api/sessions/search", false),
            ("GET", "/api/sessions/abc", false), ("PATCH", "/api/sessions/abc", false), ("DELETE", "/api/sessions/abc", false),
            ("GET", "/api/sessions/abc/messages", false),
            ("GET", "/api/profiles", false), ("POST", "/api/profiles", false), ("PATCH", "/api/profiles/scout", false),
            ("GET", "/api/profiles/scout/soul", false), ("PUT", "/api/profiles/scout/soul", false),
            ("PUT", "/api/profiles/scout/model", false), ("PUT", "/api/profiles/scout/description", false),
            ("GET", "/api/model/options", false), ("GET", "/api/config/schema", false), ("GET", "/api/media", false),
            ("GET", "/api/cron/jobs", false), ("GET", "/api/cron/jobs/abc", false), ("DELETE", "/api/cron/jobs/abc", false),
            ("POST", "/api/cron/jobs/abc/pause", false), ("POST", "/api/cron/jobs/abc/resume", false),
            ("POST", "/api/cron/jobs/abc/trigger", false),
            ("GET", "/api/plugins/kanban/board", false), ("POST", "/api/plugins/kanban/tasks", false),
            ("GET", "/api/plugins/kanban/events", true), ("GET", "/api/plugins/nollie-workflow/attention", false),
            ("GET", "/api/plugins/nollie-workflow/private-bots", false),
            ("GET", "/api/plugins/nollie-workflow/papertrail", false),
            ("GET", "/api/plugins/nollie-computer/preview", false), ("POST", "/nollie/link/claim", false),
            ("GET", "/api/plugins/nollie-workflow/posts", false), ("GET", "/api/plugins/nollie-workflow/sleep", false),
            ("POST", "/api/plugins/nollie-workflow/rehearsals/rehearsal-career-3f2a9c-e-81/turn-on", false),
            ("POST", "/api/plugins/nollie-workflow/rehearsals/rehearsal-career-3f2a9c-e-81/keep-off", false),
            ("POST", "/api/plugins/nollie-workflow/sign-ins/requests/0123456789abcdef0123456789abcdef/claim", false),
            ("GET", "/api/plugins/nollie-workflow/apple-data/bots", false), ("PUT", "/api/plugins/nollie-workflow/apple-data/bots", false),
            ("GET", "/api/plugins/nollie-workflow/payments/cards", false),
            ("GET", "/api/plugins/nollie-workflow/payments/bots", false), ("PUT", "/api/plugins/nollie-workflow/payments/bots", false),
            ("GET", "/nollie/live", true), ("POST", "/nollie/stop", false),
            ("POST", "/api/plugins/nollie-computer/take-over", false), ("POST", "/api/plugins/nollie-computer/hand-back", false),
            ("GET", "/nollie/link/hosts", false), ("POST", "/nollie/link/away/on", false), ("POST", "/nollie/link/away/off", false),
        ]
        for (method, path, socket) in allowed {
            #expect(LinkDoorPolicy.route(method: method, path: path, websocket: socket) != .refused, "\(method) \(path)")
        }
        #expect(LinkDoorPolicy.route(method: "POST", path: "/nollie/link/claim", websocket: false) == .claim)
        let refused: [(String, String, Bool)] = [
            ("GET", "/api/env", false), ("PUT", "/api/env", false), ("POST", "/api/env/reveal", false),
            ("GET", "/api/config", false), ("PUT", "/api/config", false), ("PUT", "/api/config/raw", false), ("GET", "/api/config/raw", false),
            // Files: Hermes's own file routes are not confined to a folder the door can enforce.
            ("GET", "/api/files", false), ("GET", "/api/files/read", false), ("GET", "/api/files/download", false),
            ("GET", "/api/files/stream", false), ("POST", "/api/files/upload", false), ("POST", "/api/files/upload-stream", false),
            ("POST", "/api/files/mkdir", false), ("DELETE", "/api/files", false), ("POST", "/api/chat/image-upload", false),
            // Scheduled tasks: reads and pause, resume, run and delete only.
            ("POST", "/api/cron/jobs", false), ("PUT", "/api/cron/jobs/abc", false), ("POST", "/api/cron/blueprints/instantiate", false),
            ("POST", "/api/cron/fire", false),
            // Sessions: one chat at a time, nothing in bulk.
            ("POST", "/api/sessions", false), ("POST", "/api/sessions/bulk-delete", false), ("POST", "/api/sessions/prune", false),
            ("POST", "/api/sessions/import", false), ("DELETE", "/api/sessions/empty", false), ("GET", "/api/sessions/empty/count", false),
            ("POST", "/api/sessions/owner-backfill", false), ("GET", "/api/sessions/abc/export", false),
            ("POST", "/api/sessions/abc/messages", false), ("DELETE", "/api/sessions/search", false),
            // Screens the app no longer has: session store statistics, the model page, voice and channels.
            ("GET", "/api/sessions/stats", false), ("GET", "/api/model/auxiliary", false), ("POST", "/api/model/set", false),
            ("POST", "/api/audio/transcribe", false), ("POST", "/api/audio/speak", false), ("GET", "/api/audio/speak-stream", true),
            ("GET", "/api/messaging/platforms", false),
            // Bots: never deleted from a phone.
            ("DELETE", "/api/profiles/scout", false), ("GET", "/api/profiles/scout/setup-command", false),
            ("PUT", "/api/plugins/nollie-workflow/private-bots", false), ("POST", "/api/plugins/nollie-crew/anything", false),
            ("POST", "/api/plugins/kanban/boards/import", false), ("POST", "/api/plugins/kanban/reset-state", false),
            ("POST", "/api/dashboard/agent-plugins/install", false), ("POST", "/api/dashboard/agent-plugins/kanban/enable", false),
            ("DELETE", "/api/dashboard/agent-plugins/kanban", false), ("GET", "/api/dashboard/plugins/hub", false),
            ("POST", "/api/dashboard/plugins/kanban/visibility", false), ("POST", "/api/mcp/servers", false),
            ("POST", "/api/mcp/catalog/install", false), ("POST", "/api/hermes/update", false),
            ("POST", "/api/gateway/restart", false), ("POST", "/api/gateway/stop", false), ("POST", "/api/ops/backup", false),
            ("GET", "/api/ops/backup/download", false), ("POST", "/api/ops/import", false), ("GET", "/api/logs", false),
            ("POST", "/api/auth/ws-ticket", false), ("POST", "/auth/password-login", false), ("GET", "/api/credentials/pool", false),
            ("POST", "/api/providers/oauth/x/start", false), ("POST", "/api/local-models/download", false),
            ("POST", "/api/nollie/local-model/reply-check", false), ("GET", "/api/fs/read-text", false),
            ("POST", "/api/fs/write-text", false), ("POST", "/api/git/review/push", false), ("POST", "/api/webhooks", false),
            ("POST", "/api/profiles/import", false), ("POST", "/api/profiles/scout/open-terminal", false),
            ("POST", "/api/profiles/scout/export", false), ("POST", "/api/skills/toggle", false),
            ("POST", "/api/tools/computer-use/permissions/grant", false), ("POST", "/api/plugins/nollie-pairing/invitations", false),
            ("GET", "/", false), ("GET", "/login", false), ("GET", "/dashboard-plugins/kanban/index.js", false),
            ("GET", "/api/ws", false), ("GET", "/api/status", true), ("GET", "/api/console", true), ("GET", "/api/pty", true),
            ("POST", "/api/status", false), ("GET", "/api/plugins/kanban", false), ("GET", "/nollie/link/claim", false),
            ("GET", "/api/sessionsX", false), ("GET", "/api/profiles/", false), ("GET", "/api/sessions//messages", false),
            // The main chat's cards: read, Turn on and Keep off only.
            ("POST", "/api/plugins/nollie-workflow/posts", false), ("DELETE", "/api/plugins/nollie-workflow/posts", false),
            ("PUT", "/api/plugins/nollie-workflow/sleep", false), ("GET", "/api/plugins/nollie-workflow/sleep/1", false),
            ("GET", "/api/plugins/nollie-workflow/posts/night-2026-10-21", false), ("GET", "/api/plugins/nollie-workflow/posts", true),
            ("GET", "/api/plugins/nollie-workflow/rehearsals/r1/turn-on", false), ("PUT", "/api/plugins/nollie-workflow/rehearsals/r1/keep-off", false),
            ("POST", "/api/plugins/nollie-workflow/rehearsals/r1", false), ("POST", "/api/plugins/nollie-workflow/rehearsals", false),
            ("POST", "/api/plugins/nollie-workflow/rehearsals/r1/run-now", false),
            ("POST", "/api/plugins/nollie-workflow/rehearsals/r1/x/turn-on", false),
            ("POST", "/api/plugins/nollie-workflow/rehearsals//turn-on", false),
            ("POST", "/api/plugins/nollie-workflow/rehearsals/bulk-delete/keep-off", false),
            ("POST", "/api/plugins/nollie-workflow/night-shift", false), ("PUT", "/api/plugins/nollie-workflow/settings", false),
            // Saved sign-ins: a phone only says it is answering; everything else is the Mac's.
            ("GET", "/api/plugins/nollie-workflow/sign-ins/sites", false), ("PUT", "/api/plugins/nollie-workflow/sign-ins/sites", false),
            ("GET", "/api/plugins/nollie-workflow/sign-ins/requests", false),
            ("GET", "/api/plugins/nollie-workflow/sign-ins/requests/abc", false),
            ("POST", "/api/plugins/nollie-workflow/sign-ins/requests/abc/start", false),
            ("POST", "/api/plugins/nollie-workflow/sign-ins/requests/abc/result", false),
            ("GET", "/api/plugins/nollie-workflow/sign-ins/requests/abc/claim", false),
            ("GET", "/api/plugins/nollie-workflow/sign-ins/history", false),
            // Calendar, Reminders and Contacts: a phone sees and sets the switches; requests and answers are the Mac's.
            ("GET", "/api/plugins/nollie-workflow/apple-data/requests", false), ("PUT", "/api/plugins/nollie-workflow/apple-data/mac", false),
            ("POST", "/api/plugins/nollie-workflow/apple-data/requests/abc/prepare", false),
            ("POST", "/api/plugins/nollie-workflow/apple-data/requests/abc/answer", false),
            ("POST", "/api/plugins/nollie-workflow/apple-data/bots", false),
            // Saved cards: a phone reads the labels and sets a helper's switch; it never sends cards, words a
            // payment, starts a fill or reads the requests and history.
            ("PUT", "/api/plugins/nollie-workflow/payments/cards", false),
            ("GET", "/api/plugins/nollie-workflow/payments/requests", false),
            ("GET", "/api/plugins/nollie-workflow/payments/requests/abc", false),
            ("POST", "/api/plugins/nollie-workflow/payments/requests/abc/prepare", false),
            ("POST", "/api/plugins/nollie-workflow/payments/requests/abc/refuse", false),
            ("POST", "/api/plugins/nollie-workflow/payments/requests/abc/start", false),
            ("POST", "/api/plugins/nollie-workflow/payments/requests/abc/result", false),
            ("POST", "/api/plugins/nollie-workflow/payments/requests/abc/clear", false),
            ("GET", "/api/plugins/nollie-workflow/payments/history", false),
            ("POST", "/api/plugins/nollie-workflow/payments/bots", false),
            // The live picture: the door's own socket, a GET upgrade at exactly one path.
            ("GET", "/nollie/live", false), ("HEAD", "/nollie/live", false), ("POST", "/nollie/live", false),
            ("PUT", "/nollie/live", false), ("PATCH", "/nollie/live", false), ("DELETE", "/nollie/live", false),
            ("POST", "/nollie/live", true), ("PUT", "/nollie/live", true), ("HEAD", "/nollie/live", true),
            ("GET", "/nollie/live/", true), ("GET", "/nollie/live/x", true), ("GET", "/nollie/live/live", true),
            ("GET", "/nollie//live", true), ("GET", "/nollie/live.json", true), ("GET", "/nollie/lives", true),
            ("GET", "/nollie", true), ("GET", "/nollie/", true), ("GET", "/Nollie/Live", true), ("GET", "/NOLLIE/LIVE", true),
            ("GET", "/nollie/live%2f", true), ("GET", "/nollie%2flive", true), ("GET", "/nollie/%6Cive", true),
            ("GET", "/nollie/live?x", true), ("GET", "/nollie/live ", true), ("GET", "//nollie/live", true),
            ("GET", "/api/nollie/live", true), ("GET", "/api/nollie/live", false), ("GET", "/api/plugins/nollie-computer/live", true),
            ("GET", "/api/plugins/nollie-computer/preview", true), ("GET", "/nollie/stop", true), ("GET", "/nollie/link/claim", true),
            ("GET", "/nollie/link/hosts", true), ("GET", "/nollie/link/away/on", true), ("GET", "/nollie/link/live", true),
            ("GET", "/nollie/live/hosts", true), ("GET", "/nollie/link/live", false),
            // Pictures are paused on the Mac by its own gateway's answer; a phone never asks or changes it.
            ("GET", "/api/plugins/nollie-computer/paused", false), ("POST", "/api/plugins/nollie-computer/paused", false),
            ("GET", "/api/plugins/nollie-computer/paused", true),
            // Away from home: the door's own routes, each with one method and never a socket.
            ("POST", "/nollie/link/hosts", false), ("PUT", "/nollie/link/hosts", false), ("DELETE", "/nollie/link/hosts", false),
            ("GET", "/nollie/link/away/on", false), ("GET", "/nollie/link/away/off", false), ("PUT", "/nollie/link/away/on", false),
            ("POST", "/nollie/link/away/on", true), ("POST", "/nollie/link/away/off", true), ("POST", "/nollie/link/away", false),
            ("POST", "/nollie/link/away/", false), ("POST", "/nollie/link/away/on/", false), ("POST", "/nollie/link/away/maybe", false),
            ("GET", "/nollie/link/hosts/", false), ("GET", "/nollie/link/Hosts", false), ("GET", "/api/nollie/link/hosts", false),
            ("GET", "/nollie/link/hosts%2f", false), ("GET", "//nollie/link/hosts", false),
            // Take over and Hand back: POST only, at exactly these paths.
            ("GET", "/api/plugins/nollie-computer/take-over", false), ("PUT", "/api/plugins/nollie-computer/hand-back", false),
            ("POST", "/api/plugins/nollie-computer/take-over", true), ("POST", "/api/plugins/nollie-computer/take-over/now", false),
            ("POST", "/api/plugins/nollie-computer/own-computer", false), ("POST", "/api/plugins/nollie-computer/takeover", false),
            // Stop: POST only, never a socket.
            ("GET", "/nollie/stop", false), ("POST", "/nollie/stop", true), ("POST", "/nollie/stop/", false),
        ]
        for (method, path, socket) in refused {
            #expect(LinkDoorPolicy.route(method: method, path: path, websocket: socket) == .refused, "\(method) \(path)")
        }
    }

    @Test func forwardedHeadSwapsCredentialsAndStripsOthers() throws {
        let device = String(repeating: "d", count: 64)
        let rest = try LinkDoorHTTP.parseRequest(head([
            "POST /api/sessions?profile=default&token=sneaky HTTP/1.1", "Host: 192.168.1.20:52345",
            "X-Hermes-Session-Token: " + device, "Authorization: Bearer x", "Cookie: session=1",
            "CF-Access-Client-Id: a", "X-Forwarded-For: 1.2.3.4", "Origin: https://evil.test", "Connection: X-Secret",
            "X-Secret: 1", "Content-Length: 2", "Accept: application/json",
        ], body: "{}"))
        #expect(LinkDoorPolicy.presentedCredential(rest) == device)
        let text = String(decoding: LinkDoorPolicy.upstreamHead(rest, port: 9119, token: "upstream"), as: UTF8.self)
        #expect(text.hasPrefix("POST /api/sessions?profile=default HTTP/1.1\r\nHost: 127.0.0.1:9119\r\n"))
        #expect(text.contains("X-Hermes-Session-Token: upstream\r\n") && text.contains("Content-Length: 2\r\n"))
        #expect(text.contains("Connection: close\r\n") && text.contains("Accept: application/json\r\n"))
        for gone in [device, "Bearer", "Cookie", "CF-Access", "X-Forwarded", "evil.test", "X-Secret", "sneaky", "192.168.1.20"] {
            #expect(!text.contains(gone), "\(gone)")
        }

        let socket = try LinkDoorHTTP.parseRequest(head([
            "GET /api/ws?token=\(device)&channel=a HTTP/1.1", "Host: h", "Upgrade: websocket", "Connection: Upgrade",
            "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        ]))
        #expect(LinkDoorPolicy.presentedCredential(socket) == device)
        let upgrade = String(decoding: LinkDoorPolicy.upstreamHead(socket, port: 9119, token: "upstream"), as: UTF8.self)
        #expect(upgrade.hasPrefix("GET /api/ws?channel=a&token=upstream HTTP/1.1\r\n"))
        #expect(upgrade.contains("Upgrade: websocket\r\n") && upgrade.contains("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"))
        #expect(!upgrade.contains(device))

        // Two different credentials, or a token in a plain request's query, are no credential.
        let conflicting = try LinkDoorHTTP.parseRequest(head([
            "GET /api/ws?token=a HTTP/1.1", "Host: h", "X-Hermes-Session-Token: b", "Upgrade: websocket", "Connection: Upgrade",
            "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        ]))
        #expect(LinkDoorPolicy.presentedCredential(conflicting) == nil)
        let queryOnly = try LinkDoorHTTP.parseRequest(head(["GET /api/status?token=\(device) HTTP/1.1", "Host: h"]))
        #expect(LinkDoorPolicy.presentedCredential(queryOnly) == nil)
        let twice = try LinkDoorHTTP.parseRequest(head(["GET /api/status HTTP/1.1", "Host: h", "X-Hermes-Session-Token: a", "X-Hermes-Session-Token: a"]))
        #expect(LinkDoorPolicy.presentedCredential(twice) == nil)
    }

    // MARK: Offers and devices

    @Test func offersAreSingleUseAndExpire() throws {
        let store = LinkDoorMemoryState()
        let devices = try LinkDoorDevices(store: store)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(throws: LinkDoorDevices.ClaimFailure.noOffer) { try devices.claim(secret: Data(count: 32), name: "Phone", now: start) }

        let offer = devices.makeOffer(now: start)
        #expect(offer.secret.count == 32)
        #expect(offer.expiresAt == start.addingTimeInterval(120))
        #expect(devices.offerState(now: start) == .open(expiresAt: offer.expiresAt))
        var wrong = offer.secret
        wrong[31] ^= 1
        #expect(throws: LinkDoorDevices.ClaimFailure.mismatch) { try devices.claim(secret: wrong, name: "Phone", now: start) }
        #expect(throws: LinkDoorDevices.ClaimFailure.mismatch) { try devices.claim(secret: offer.secret.prefix(16), name: "Phone", now: start) }
        #expect(throws: LinkDoorDevices.ClaimFailure.invalidName) { try devices.claim(secret: offer.secret, name: " \u{202E} ", now: start) }
        // A wrong guess leaves the offer open for the real phone.
        let (device, credential) = try devices.claim(secret: offer.secret, name: "Corey's iPhone", now: start.addingTimeInterval(60))
        #expect(device.name == "Corey's iPhone")
        #expect(devices.offerState(now: start) == .claimed(deviceID: device.id, name: "Corey's iPhone"))
        #expect(throws: LinkDoorDevices.ClaimFailure.noOffer) { try devices.claim(secret: offer.secret, name: "Again", now: start.addingTimeInterval(61)) }
        #expect(store.current?.devices.count == 1)
        #expect(store.current?.devices.first?.credentialHash == Data(SHA256.hash(data: LinkDoorDevices.hexBytes(credential)!)))
        #expect(!String(decoding: try JSONEncoder().encode(store.current), as: UTF8.self).contains(credential))

        let late = devices.makeOffer(now: start)
        #expect(devices.offerState(now: start.addingTimeInterval(121)) == .none)
        #expect(throws: LinkDoorDevices.ClaimFailure.expired) { try devices.claim(secret: late.secret, name: "Phone", now: start.addingTimeInterval(120)) }

        let replaced = devices.makeOffer(now: start)
        _ = devices.makeOffer(now: start)
        #expect(throws: LinkDoorDevices.ClaimFailure.mismatch) { try devices.claim(secret: replaced.secret, name: "Phone", now: start) }
        devices.cancelOffer()
        #expect(devices.offerState(now: start) == .none)
    }

    @Test func deviceCredentialsAreCheckedInFull() throws {
        let store = LinkDoorMemoryState()
        let devices = try LinkDoorDevices(store: store)
        let first = try devices.claim(secret: devices.makeOffer().secret, name: "Phone")
        let second = try devices.claim(secret: devices.makeOffer().secret, name: "iPad")
        #expect(first.credential != second.credential)
        #expect(first.credential.utf8.count == 64)
        #expect(devices.authenticate(first.credential) == first.device.id)
        #expect(devices.authenticate(second.credential) == second.device.id)
        var flipped = Array(first.credential)
        flipped[63] = flipped[63] == "0" ? "1" : "0"
        for bad in [String(flipped), "", String(first.credential.prefix(63)), first.credential + "00", first.credential.uppercased(),
                    String(repeating: "z", count: 64), String(repeating: "0", count: 64)] {
            #expect(devices.authenticate(bad) == nil, "\(bad.prefix(8))")
        }
        #expect(LinkDoorDevices.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!LinkDoorDevices.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!LinkDoorDevices.constantTimeEqual(Data([1, 2]), Data([1, 2, 3])))

        #expect(try devices.remove(first.device.id))
        #expect(devices.authenticate(first.credential) == nil)
        #expect(devices.authenticate(second.credential) == second.device.id)
        #expect(try !devices.remove(first.device.id))

        // State survives a restart; a store that can't save refuses the claim instead of linking.
        let reloaded = try LinkDoorDevices(store: store)
        #expect(reloaded.authenticate(second.credential) == second.device.id)
        #expect(reloaded.installTag == devices.installTag)
        store.failSaves = true
        #expect(throws: LinkDoorDevices.ClaimFailure.unsaved) { try reloaded.claim(secret: reloaded.makeOffer().secret, name: "Phone") }
    }

    @Test func stateFileIsPrivateAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nollie-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent("RuntimeService")
        let file = LinkDoorStateFile(directory: directory)
        #expect(try file.load() == nil)
        let devices = try LinkDoorDevices(store: file)
        try devices.savePort(52_345)
        let linked = try devices.claim(secret: devices.makeOffer().secret, name: "Phone")
        let saved = try #require(try file.load())
        #expect(saved.port == 52_345 && saved.devices.map(\.id) == [linked.device.id])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("link.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let text = try String(contentsOf: directory.appendingPathComponent("link.json"), encoding: .utf8)
        #expect(!text.contains(linked.credential))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent("link.json").path)
        #expect(throws: LinkDoorStateError.self) { try file.load() }
    }

    // MARK: Identity and pins

    @Test func identityPinMatchesItsCertificateAndRejectsOthers() throws {
        let name = "com.coreykozarski.nollie.link.test." + UUID().uuidString
        defer { LinkDoorIdentity.remove(name: name) }
        let identity = try LinkDoorIdentity.loadOrCreate(name: name)
        #expect(identity.pin.count == 32)
        #expect(try LinkDoorIdentity.loadOrCreate(name: name).pin == identity.pin)  // made once, then kept

        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity.identity, &certificate) == errSecSuccess)
        let trust = try Self.trust(for: try #require(certificate))
        #expect(NollieLinkPin.pin(of: try #require(certificate)) == identity.pin)
        #expect(NollieLinkPin.matches(trust, pin: identity.pin))
        #expect(NollieLinkPin.disposition(for: trust, pin: identity.pin) == .useCredential)

        // Another key, even with an identical-looking certificate, is a mismatch.
        let (otherKey, otherPublic) = try Self.ephemeralKey()
        let other = try #require(SecCertificateCreateWithData(nil, try LinkDoorIdentity.certificate(privateKey: otherKey, publicKey: otherPublic) as CFData))
        let otherTrust = try Self.trust(for: other)
        #expect(!NollieLinkPin.matches(otherTrust, pin: identity.pin))
        #expect(NollieLinkPin.disposition(for: otherTrust, pin: identity.pin) == .cancelAuthenticationChallenge)
        #expect(!NollieLinkPin.matches(trust, pin: Data(repeating: 0, count: 32)))
        #expect(!NollieLinkPin.matches(trust, pin: identity.pin.prefix(31)))
        #expect(LinkDoorIdentity.pin(of: otherPublic) == NollieLinkPin.pin(of: otherPublic))
    }

    static func eventually(seconds: Double = 2, _ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 20) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    static func ephemeralKey() throws -> (SecKey, SecKey) {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        return (key, try #require(SecKeyCopyPublicKey(key)))
    }

    static func trust(for certificate: SecCertificate) throws -> SecTrust {
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust) == errSecSuccess)
        return try #require(trust)
    }

    // MARK: The whole door

    /// A door on loopback in front of a fake Hermes. A fake phone links with a real offer and
    /// talks through the door with the app's own clients.
    @Test(.timeLimit(.minutes(1))) func phoneLinksEndToEndAndRemoveCutsItsSocket() async throws {
        let fixture = try await DoorFixture.start()
        defer { fixture.stop() }
        let door = fixture.door

        // The Mac shows an offer; the phone reads it from the code.
        let made = door.devices.makeOffer()
        try await door.refresh()
        let port = try #require(door.port)
        let offer = try NollieLinkOffer(macName: "Test Mac", pin: door.identity.pin, port: Int(port), hosts: ["192.168.1.20"],
                                        installTag: door.devices.installTag, secret: made.secret, expiresAt: made.expiresAt)
        let scanned = try NollieLinkOffer.parse(offer.urlString)
        #expect(await NollieLinkClient.probe(host: "127.0.0.1", port: Int(port), pin: scanned.pin))

        // A copy of the code with someone else's key never gets the secret.
        let forged = try NollieLinkOffer(macName: "Test Mac", pin: Data(repeating: 9, count: 32), port: Int(port), hosts: ["192.168.1.20"],
                                         installTag: door.devices.installTag, secret: made.secret, expiresAt: made.expiresAt)
        #expect(await !NollieLinkClient.probe(host: "127.0.0.1", port: Int(port), pin: forged.pin))
        await #expect(throws: NollieLinkError.identityMismatch) { try await NollieLinkClient.claim(forged, host: "127.0.0.1", deviceName: "Phone") }
        #expect(fixture.hermes.requests.isEmpty)

        let claim = try await NollieLinkClient.claim(scanned, host: "127.0.0.1", deviceName: "Test iPhone")
        #expect(claim.macName == "Test Mac")
        #expect(door.devices.offerState() == .claimed(deviceID: claim.deviceID, name: "Test iPhone"))
        await #expect(throws: NollieLinkError.expired) { try await NollieLinkClient.claim(scanned, host: "127.0.0.1", deviceName: "Again") }

        // The app's ordinary connection check runs through the door unchanged.
        let link = LinkedMac(macName: claim.macName, pin: scanned.pin, port: scanned.port, hosts: scanned.hosts,
                             installTag: scanned.installTag, deviceID: claim.deviceID)
        let connection = GatewayConnection(name: claim.macName, gateway: try link.gateway(host: "127.0.0.1"), authMode: .sessionToken, linkedMac: link)
        let secrets = GatewaySecrets(sessionToken: claim.credential, linkedDevice: true)
        let outcome = await ConnectionTester.run(connection: connection, secrets: secrets) { _ in }
        #expect(outcome.succeeded, "\(outcome.steps.map(\.status))")
        #expect(outcome.version == "fake")

        let seen = fixture.hermes.requests
        #expect(seen.map(\.line) == ["GET /api/status HTTP/1.1", "GET /api/profiles HTTP/1.1", "GET /api/ws?token=\(DoorFixture.upstreamToken) HTTP/1.1"])
        for request in seen {
            #expect(!request.head.contains(claim.credential))
            #expect(request.head.contains("Host: 127.0.0.1:\(fixture.hermes.port)\r\n"))
        }
        #expect(seen[0].head.contains("X-Hermes-Session-Token: \(DoorFixture.upstreamToken)\r\n"))

        // The check above used the offer's pin alone; nothing was trusted process-wide until
        // the app saves the link, as it does here.
        #expect(GatewayTrust.shared.pin(host: "127.0.0.1", port: Int(port)) == nil)
        GatewayTrust.shared.register(link, hosts: ["127.0.0.1"], owner: connection.id)
        defer { GatewayTrust.shared.forget(owner: connection.id) }

        // Unlinked, refused and unauthenticated requests stop at the door.
        let api = HermesAPI(gateway: connection.gateway, signer: RequestSigner(authMode: .sessionToken, secrets: secrets))
        await #expect(throws: HermesAPIError.self) { _ = try await api.get("/api/env") as JSONValue }
        let stranger = HermesAPI(gateway: connection.gateway, signer: RequestSigner(authMode: .sessionToken,
            secrets: .init(sessionToken: String(repeating: "0", count: 64), linkedDevice: true)))
        do { let _: JSONValue = try await stranger.get("/api/profiles"); Issue.record("a stranger got through") }
        catch let error as HermesAPIError { #expect(error.isUnauthorized) }
        #expect(fixture.hermes.requests.count == 3)

        // A live socket closes within a second of Remove.
        let session = HermesAPI.makeSession()
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: RequestSigner.websocketURL(gateway: connection.gateway, token: claim.credential, ticket: nil))
        socket.resume()
        let first = try await socket.receive()
        if case .string(let text) = first { #expect(text.contains("gateway.ready")) } else { Issue.record("no ready frame") }

        // Only the app's own JSON-RPC calls reach Hermes; anything else is answered by the door.
        try await socket.send(.string(#"{"jsonrpc":"2.0","id":41,"method":"shell.exec","params":{"command":"id"}}"#))
        let refusal = try await socket.receive()
        guard case .string(let refusalText) = refusal else { Issue.record("no refusal frame"); return }
        #expect(refusalText.contains("\"id\":41") && refusalText.contains("4403"))
        try await socket.send(.string(#"{"jsonrpc":"2.0","id":42,"method":"config.set","params":{"key":"yolo","value":"on"}}"#))
        guard case .string(let yolo) = try await socket.receive() else { Issue.record("no refusal frame"); return }
        #expect(yolo.contains("\"id\":42"))
        try await socket.send(.string(#"{"jsonrpc":"2.0","id":43,"method":"ping","params":{}}"#))
        #expect(await Self.eventually { fixture.hermes.socketTexts.contains { $0.contains("\"id\":43") } })
        #expect(!fixture.hermes.socketTexts.contains { $0.contains("shell.exec") || $0.contains("yolo") })

        // The connection check's own socket may still be closing.
        #expect(await Self.eventually { door.liveSessions(for: claim.deviceID) == 1 })
        let removedAt = ContinuousClock.now
        #expect(try door.remove(claim.deviceID))
        do {
            _ = try await socket.receive()
            Issue.record("the socket stayed open")
        } catch {
            #expect(ContinuousClock.now - removedAt < .seconds(1))
        }
        #expect(door.liveSessions(for: claim.deviceID) == 0)
        await #expect(throws: (any Error).self) { let _: JSONValue = try await api.get("/api/profiles") }

        // With nothing linked and no offer open, the door stops listening.
        try await door.refresh()
        #expect(!door.isListening)
    }

    @Test(.timeLimit(.minutes(1))) func refusedSourceNeverCompletesAHandshake() async throws {
        let fixture = try await DoorFixture.start(acceptLoopback: false)
        defer { fixture.stop() }
        _ = fixture.door.devices.makeOffer()
        try await fixture.door.refresh()
        let port = try #require(fixture.door.port)
        #expect(await !NollieLinkClient.probe(host: "127.0.0.1", port: Int(port), pin: fixture.door.identity.pin, timeout: 2))
        let counts = fixture.door.counts
        #expect(counts.refusedSources >= 1)
        #expect(counts.handshakes == 0)
    }

    @Test(.timeLimit(.minutes(1))) func doorAnswersWithoutHermesAndRefusesPipelining() async throws {
        let fixture = try await DoorFixture.start(upstream: false)
        defer { fixture.stop() }
        let door = fixture.door
        let linked = try door.devices.claim(secret: door.devices.makeOffer().secret, name: "Phone")
        try await door.refresh()
        let port = Int(try #require(door.port))
        let gateway = try GatewayURL.normalize("https://127.0.0.1:\(port)")
        let owner = UUID()
        GatewayTrust.shared.register(pin: door.identity.pin, host: "127.0.0.1", port: port, owner: owner)
        defer { GatewayTrust.shared.forget(owner: owner) }
        let api = HermesAPI(gateway: gateway, signer: RequestSigner(authMode: .sessionToken, secrets: .init(sessionToken: linked.credential, linkedDevice: true)))
        do { let _: JSONValue = try await api.get("/api/profiles"); Issue.record("no Hermes, yet an answer") }
        catch let error as HermesAPIError {
            guard case .http(let status, _) = error else { Issue.record("\(error)"); return }
            #expect(status == 503)
        }
        // Two requests in one write: the second is never read as a request.
        let raw = "GET /api/status HTTP/1.1\r\nHost: h\r\nX-Hermes-Session-Token: \(linked.credential)\r\n\r\nGET /api/env HTTP/1.1\r\nHost: h\r\n\r\n"
        let answer = try await RawTLS.exchange(port: port, pin: door.identity.pin, send: Data(raw.utf8))
        #expect(answer.hasPrefix("HTTP/1.1 400 "))
    }

    @Test func stopIsItsOwnRouteAndOnlyAPost() {
        #expect(LinkDoorPolicy.route(method: "POST", path: "/nollie/stop", websocket: false) == .stop)
        #expect(LinkDoorPolicy.route(method: "GET", path: "/nollie/stop", websocket: false) == .refused)
        #expect(LinkDoorPolicy.route(method: "GET", path: "/nollie/stop", websocket: true) == .refused)
        #expect(LinkDoorPolicy.route(method: "POST", path: "/nollie/stop/now", websocket: false) == .refused)
        #expect(LinkDoorPolicy.route(method: "POST", path: "/api/nollie/stop", websocket: false) == .refused)
    }

    @Test func liveIsItsOwnRouteAndOnlyASocket() {
        #expect(LinkDoorPolicy.route(method: "GET", path: "/nollie/live", websocket: true) == .live)
        for method in ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"] {
            #expect(LinkDoorPolicy.route(method: method, path: "/nollie/live", websocket: false) == .refused, "\(method)")
            if method != "GET" { #expect(LinkDoorPolicy.route(method: method, path: "/nollie/live", websocket: true) == .refused, "\(method)") }
        }
        for path in ["/nollie/live/", "/nollie/live/x", "/api/nollie/live", "/nollie/Live", "/api/plugins/nollie-computer/preview"] {
            #expect(LinkDoorPolicy.route(method: "GET", path: path, websocket: true) != .live, "\(path)")
        }
        // The preview stays a plain request, never a socket; the live path never reaches Hermes.
        #expect(LinkDoorPolicy.route(method: "GET", path: "/api/plugins/nollie-computer/preview", websocket: false) == .hermes)
        #expect(LinkDoorPolicy.route(method: "GET", path: "/api/plugins/nollie-computer/preview", websocket: true) == .refused)
    }

    @Test(.timeLimit(.minutes(1))) func stopFromALinkedPhoneIsRecordedAndNeverReachesHermes() async throws {
        let fixture = try await DoorFixture.start()
        defer { fixture.stop() }
        let door = fixture.door
        let linked = try door.devices.claim(secret: door.devices.makeOffer().secret, name: "Corey's iPhone")
        try await door.refresh()
        let port = Int(try #require(door.port))
        let pin = door.identity.pin
        #expect(door.lastStop == nil)

        // A stranger is turned away before anything is recorded.
        let stranger = try await RawTLS.exchange(port: port, pin: pin, send: Data("POST /nollie/stop HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n".utf8))
        #expect(stranger.hasPrefix("HTTP/1.1 401 "))
        #expect(door.lastStop == nil)

        // A body is refused: Stop carries nothing.
        let withBody = "POST /nollie/stop HTTP/1.1\r\nHost: h\r\nX-Hermes-Session-Token: \(linked.credential)\r\nContent-Length: 2\r\n\r\n{}"
        #expect(try await RawTLS.exchange(port: port, pin: pin, send: Data(withBody.utf8)).hasPrefix("HTTP/1.1 413 "))
        #expect(door.lastStop == nil)

        // The phone's press, through the same client the app uses, counts up once per press.
        let gateway = try GatewayURL.normalize("https://127.0.0.1:\(port)")
        let owner = UUID()
        GatewayTrust.shared.register(pin: pin, host: "127.0.0.1", port: port, owner: owner)
        defer { GatewayTrust.shared.forget(owner: owner) }
        let api = HermesAPI(gateway: gateway, signer: RequestSigner(authMode: .sessionToken, secrets: .init(sessionToken: linked.credential, linkedDevice: true)))
        let (body, http) = try await api.raw("POST", "/nollie/stop", body: nil, authenticated: true)
        #expect(http.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == #"{"stopped":true}"#)
        #expect(door.lastStop?.generation == 1)
        #expect(door.lastStop?.device == "Corey's iPhone")
        _ = try await api.raw("POST", "/nollie/stop", body: nil, authenticated: true)
        #expect(door.lastStop?.generation == 2)
        #expect(fixture.hermes.requests.isEmpty)
    }

    // MARK: Sockets

    private func clientFrame(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true, mask: Bool = true, rsv: UInt8 = 0) -> Data {
        var out = Data([(fin ? 0x80 : 0) | rsv | opcode])
        if payload.count < 126 { out.append((mask ? 0x80 : 0) | UInt8(payload.count)) }
        else { out.append(contentsOf: [(mask ? 0x80 : 0) | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]) }
        let key: [UInt8] = [1, 2, 3, 4]
        if mask { out.append(contentsOf: key) }
        out.append(contentsOf: payload.enumerated().map { mask ? $0.element ^ key[$0.offset & 3] : $0.element })
        return out
    }

    @Test func clientFramesAreReadStrictly() throws {
        var reader = LinkDoorWebSocket.ClientReader(maximumMessage: 1024)
        // A text message in two fragments with a ping between them, delivered a byte at a time.
        let stream = clientFrame(1, Array("hel".utf8), fin: false) + clientFrame(9, [7]) + clientFrame(0, Array("lo".utf8))
        var messages: [LinkDoorWebSocket.Message] = []
        for byte in stream { messages += try reader.feed(Data([byte])) }
        #expect(messages == [.ping(Data([7])), .text(Data("hello".utf8))])
        #expect(try reader.feed(clientFrame(8, [3, 232])) == [.close(Data([3, 232]))])

        let refused: [(String, Data, LinkDoorWebSocket.Failure)] = [
            ("unmasked", clientFrame(1, [65], mask: false), .protocolError("unmasked")),
            ("compressed", clientFrame(1, [65], rsv: 0x40), .protocolError("extension bits")),
            ("fragmented ping", clientFrame(9, [1], fin: false), .protocolError("control frame")),
            ("fragmented close", clientFrame(8, [3, 232], fin: false), .protocolError("control frame")),
            ("long ping", clientFrame(9, Array(repeating: 1, count: 126)), .protocolError("control frame")),
            ("unknown opcode", clientFrame(3, [1]), .protocolError("opcode")),
            ("stray continuation", clientFrame(0, [65]), .protocolError("continuation")),
            ("bad text", clientFrame(1, [0xC3, 0x28]), .protocolError("text")),
            ("too large", clientFrame(1, Array(repeating: 65, count: 1025)), .tooLarge),
            ("long length for a short frame", Data([0x81, 0xFE, 0, 5, 1, 2, 3, 4]) + Data(repeating: 0, count: 5), .protocolError("length")),
        ]
        for (name, data, failure) in refused {
            var fresh = LinkDoorWebSocket.ClientReader(maximumMessage: 1024)
            #expect(throws: failure, "\(name)") { try fresh.feed(data) }
        }
        var interleaved = LinkDoorWebSocket.ClientReader(maximumMessage: 1024)
        _ = try interleaved.feed(clientFrame(1, [65], fin: false))
        #expect(throws: LinkDoorWebSocket.Failure.protocolError("interleaved message")) { try interleaved.feed(clientFrame(1, [66])) }
        var growing = LinkDoorWebSocket.ClientReader(maximumMessage: 1024)
        _ = try growing.feed(clientFrame(1, Array(repeating: 65, count: 1000), fin: false))
        #expect(throws: LinkDoorWebSocket.Failure.tooLarge) { try growing.feed(clientFrame(0, Array(repeating: 65, count: 100))) }

        // Frames for Hermes are masked; the door's replies to the phone are not.
        var check = LinkDoorWebSocket.ClientReader(maximumMessage: 1 << 20)
        let big = Data(repeating: 66, count: 70_000)
        #expect(try check.feed(LinkDoorWebSocket.message(.text(big), masked: true)) == [.text(big)])
        #expect(LinkDoorWebSocket.message(.text(Data("x".utf8)), masked: false) == Data([0x81, 1, 0x78]))
    }

    @Test func serverFramesAreTrackedSoRepliesNeverSplitAMessage() {
        var tracker = LinkDoorWebSocket.ServerTracker()
        #expect(tracker.atBoundary)
        let whole = LinkDoorWebSocket.frame(opcode: 1, payload: Data(repeating: 65, count: 300), masked: false)
        tracker.consume(whole.prefix(3))
        #expect(!tracker.atBoundary)
        tracker.consume(whole.dropFirst(3))
        #expect(tracker.atBoundary)
        // A fragmented message holds the door's replies until its last fragment.
        tracker.consume(Data([0x01, 2, 65, 65]))
        #expect(!tracker.atBoundary)
        tracker.consume(Data([0x89, 0]))
        #expect(!tracker.atBoundary)
        tracker.consume(Data([0x80, 1, 65]))
        #expect(tracker.atBoundary)
        tracker.consume(Data([0x88, 0]))
        #expect(tracker.closed)
    }

    @Test func socketCallsAreLimitedToTheAppsOwn() {
        func decide(_ text: String) -> LinkDoorRPC.Decision { LinkDoorRPC.decide(Data(text.utf8)) }
        #expect(decide(#"{"jsonrpc":"2.0","id":1,"method":"prompt.submit","params":{"session_id":"a","text":"hi"}}"#) == .forward)
        #expect(decide(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#) == .forward)
        #expect(decide(#"{"jsonrpc":"2.0","id":3,"method":"config.set","params":{"key":"model","value":"x"}}"#) == .forward)
        #expect(decide(#"{"jsonrpc":"2.0","id":"s1","result":{"choice":"once"}}"#) == .forward)  // an approval answer
        for refused in [
            #"{"jsonrpc":"2.0","id":4,"method":"shell.exec","params":{"command":"id"}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"cli.exec","params":{}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"config.set","params":{"key":"yolo","value":"on"}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"config.set","params":{"key":"approvals.mode","value":"off"}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"config.get","params":{"key":"providers"}}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"vault.get","params":{}}"#,
            #"{"jsonrpc":"2.0","id":10,"method":"connectors.policy.set","params":{}}"#,
            #"{"jsonrpc":"2.0","id":11,"method":"approvals.mode","params":{}}"#,
            #"{"jsonrpc":"2.0","id":12,"method":"slash.exec","params":{"command":"/yolo"}}"#,
            #"{"jsonrpc":"2.0","id":13,"method":"command.dispatch","params":{"name":"plugins"}}"#,
            #"{"jsonrpc":"2.0","id":14,"method":"prompt.submit","params":["not","an","object"]}"#,
            #"{"jsonrpc":"2.0","id":15,"method":42}"#,
            #"[{"jsonrpc":"2.0","id":16,"method":"ping"}]"#,
            #"{"jsonrpc":"2.0","id":17,"result":{},"error":{}}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
            "not json",
        ] {
            guard case .refuse(let reply) = decide(refused) else { Issue.record("forwarded: \(refused)"); continue }
            let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
            #expect((object?["error"] as? [String: Any])?["code"] as? Int == LinkDoorRPC.refusedCode)
        }
        guard case .refuse(let reply) = decide(#"{"jsonrpc":"2.0","id":"abc","method":"shell.exec"}"#) else { return }
        #expect(String(decoding: reply, as: UTF8.self).contains(#""id":"abc""#))
    }

    /// Every JSON-RPC method the app sends must be classified for the door. A new call in the
    /// app fails here until it is added to `LinkDoorRPC.allowed` or `macOnly`.
    @Test func everyMethodTheAppSendsIsClassified() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let call = try NSRegularExpression(pattern: #"(?:\brpc|\bask|\.call)\(\s*"([a-z_]+(?:\.[a-z_]+)*)""#)
        let loop = try NSRegularExpression(pattern: #"for method in \[([^\]]*)\]"#)
        let name = try NSRegularExpression(pattern: #""([a-z_]+(?:\.[a-z_]+)+)""#)
        var found: Set<String> = []
        for folder in ["Packages/NollieCore/Sources", "Apps"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                // LocalModelAPI's call(_:_:) is HTTP, not JSON-RPC.
                if file.lastPathComponent == "LocalModelAPI.swift" { continue }
                let range = NSRange(text.startIndex..., in: text)
                for match in call.matches(in: text, range: range) { found.insert(String(text[Range(match.range(at: 1), in: text)!])) }
                for match in loop.matches(in: text, range: range) {
                    let list = String(text[Range(match.range(at: 1), in: text)!])
                    for item in name.matches(in: list, range: NSRange(list.startIndex..., in: list)) {
                        found.insert(String(list[Range(item.range(at: 1), in: list)!]))
                    }
                }
            }
        }
        // The scan sees the app's real calls, so an empty result can't pass.
        #expect(found.isSuperset(of: ["prompt.submit", "session.resume", "approval.respond", "ping", "projects.tree", "slash.exec"]))
        let classified = Set(LinkDoorRPC.allowed.keys).union(LinkDoorRPC.macOnly)
        #expect(found.subtracting(classified).isEmpty, "unclassified: \(found.subtracting(classified).sorted())")
        #expect(Set(LinkDoorRPC.allowed.keys).isDisjoint(with: LinkDoorRPC.macOnly))
        #expect(LinkDoorPolicy.strippedHeaders.contains("sec-websocket-extensions"))
    }

    // MARK: Listening and crowding

    @Test(.timeLimit(.minutes(1))) func stopWinsOverAStartInProgressAndStartsAreShared() async throws {
        let fixture = try await DoorFixture.start()
        defer { fixture.stop() }
        let door = fixture.door
        async let first = door.start()
        async let second = door.start()
        let ports = try await [first, second]
        #expect(ports[0] == ports[1] && door.isListening)

        door.stop()
        #expect(!door.isListening)
        // Starts overtaken by stop, in many interleavings: a start that lost never leaves a
        // listener behind, and at most one listener is ever up.
        for round in 0..<25 {
            let racing = Task { try await door.start() }
            if round % 2 == 0 { await Task.yield() }
            door.stop()
            if (try? await racing.value) == nil { #expect(!door.isListening) }
            #expect(door.readyListenerCount <= 1)
            door.stop()
        }
        #expect(await Self.eventually { door.readyListenerCount == 0 })
        #expect(door.port == nil)
        // And the door can start again afterwards, on a port nobody else shares.
        let again = try await door.start()
        #expect(door.port == again && door.isListening)
    }

    @Test(.timeLimit(.minutes(1))) func strangersCantCrowdOutLinkedPhones() async throws {
        let fixture = try await DoorFixture.start { $0.perSourceUnauthenticated = 2; $0.unauthenticatedTimeout = 1 }
        defer { fixture.stop() }
        let door = fixture.door
        let linked = try door.devices.claim(secret: door.devices.makeOffer().secret, name: "Phone")
        let port = Int(try await door.start())
        // Two idle handshakes from one address fill its share; a third is turned away.
        let idle = [try await RawTLS.open(port: port, pin: door.identity.pin), try await RawTLS.open(port: port, pin: door.identity.pin)]
        defer { idle.forEach { $0.cancel() } }
        #expect(await Self.eventually { door.unauthenticatedSessions == 2 })
        _ = try? await RawTLS.open(port: port, pin: door.identity.pin)
        #expect(await Self.eventually { door.refusedBusyCount >= 1 })
        // The unproven ones are closed at the deadline, and the linked phone gets in again.
        #expect(await Self.eventually(seconds: 4) { door.unauthenticatedSessions == 0 })
        let raw = "GET /api/status HTTP/1.1\r\nHost: h\r\nX-Hermes-Session-Token: \(linked.credential)\r\n\r\n"
        let answer = try await RawTLS.exchange(port: port, pin: door.identity.pin, send: Data(raw.utf8))
        #expect(answer.hasPrefix("HTTP/1.1 200 "))

        // A claim whose body never arrives is closed by the same deadline.
        let slow = try await RawTLS.open(port: port, pin: door.identity.pin)
        defer { slow.cancel() }
        slow.send(content: Data("POST /nollie/link/claim HTTP/1.1\r\nHost: h\r\nContent-Length: 100\r\n\r\n{".utf8), completion: .contentProcessed { _ in })
        #expect(await Self.eventually { door.unauthenticatedSessions == 1 })
        #expect(await Self.eventually(seconds: 4) { door.unauthenticatedSessions == 0 })
    }
}

// MARK: Away from home and Take over

extension NollieLinkDoorTests {
    @Test func askFirstAllowsOnlyReadingAndChangingOneBotsSwitch() {
        let path = "/api/plugins/nollie-computer/ask-first"
        for method in ["GET", "PUT"] {
            #expect(LinkDoorPolicy.route(method: method, path: path, websocket: false) == .hermes)
        }
        for method in ["POST", "PATCH", "DELETE"] {
            #expect(LinkDoorPolicy.route(method: method, path: path, websocket: false) == .refused)
        }
        #expect(LinkDoorPolicy.route(method: "GET", path: path, websocket: true) == .refused)
        #expect(LinkDoorPolicy.route(method: "PUT", path: path + "/all", websocket: false) == .refused)
        #expect(LinkDoorPolicy.allowsQuery(path: path, query: "profile=default"))
        #expect(LinkDoorPolicy.allowsQuery(path: path, query: "profile=night-owl_2"))
        for bad in [nil, "", "profile=", "profile=a&profile=b", "profile=default&enabled=false", "profile=../x"] {
            #expect(!LinkDoorPolicy.allowsQuery(path: path, query: bad))
        }
    }

    @Test func memoryAllowsOnlyItsOwnRoutesAndOneBot() {
        let base = "/api/plugins/nollie-workflow/memory"
        let allowed: [(String, String)] = [("GET", base), ("POST", base + "/notes"), ("PUT", base + "/notes"),
                                           ("DELETE", base + "/notes"), ("PUT", base + "/switch")]
        for (method, path) in allowed {
            #expect(LinkDoorPolicy.route(method: method, path: path, websocket: false) == .hermes, "\(method) \(path)")
            #expect(LinkDoorPolicy.route(method: method, path: path, websocket: true) == .refused, "\(method) \(path)")
        }
        let refused: [(String, String)] = [
            ("POST", base), ("PUT", base), ("DELETE", base), ("PATCH", base + "/notes"), ("GET", base + "/notes"),
            ("GET", base + "/switch"), ("POST", base + "/switch"), ("DELETE", base + "/switch"),
            ("GET", base + "/notes/abc"), ("PUT", base + "/notes/abc"), ("DELETE", base + "/notes/abc"),
            ("GET", base + "/files"), ("GET", base + "s"), ("GET", base + "/"), ("GET", "/api/plugins/nollie-workflow/memory%2fnotes"),
            // Hermes's own memory routes stay shut: provider changes and resets that delete the files.
            ("GET", "/api/memory"), ("PUT", "/api/memory/provider"), ("POST", "/api/memory/reset"),
            ("GET", "/api/memory/providers"), ("GET", "/api/fs/read-text"), ("POST", "/api/fs/write-text"),
        ]
        for (method, path) in refused {
            #expect(LinkDoorPolicy.route(method: method, path: path, websocket: false) == .refused, "\(method) \(path)")
        }
        for path in [base, base + "/notes", base + "/switch"] {
            #expect(LinkDoorPolicy.allowsQuery(path: path, query: "bot=default"))
            #expect(LinkDoorPolicy.allowsQuery(path: path, query: "bot=night-owl_2"))
            for bad in [nil, "", "bot=", "bot=default&on_this_mac=true", "on_this_mac=true&bot=default", "on_this_mac=true",
                        "bot=a&bot=b", "profile=default", "bot=../x", "bot=a%2Fb", "bot=" + String(repeating: "a", count: 65), "bot"] {
                #expect(!LinkDoorPolicy.allowsQuery(path: path, query: bad), "\(path) \(bad ?? "nil")")
            }
        }
        // The profile-only routes keep their own rule.
        #expect(!LinkDoorPolicy.allowsQuery(path: "/api/plugins/nollie-computer/ask-first", query: "bot=default"))
        #expect(LinkDoorPolicy.allowsQuery(path: "/api/plugins/nollie-computer/ask-first", query: "profile=default"))
    }

    @Test func takeOverAndHandBackPassAsPostsWithOnlyAProfile() {
        for path in ["/api/plugins/nollie-computer/take-over", "/api/plugins/nollie-computer/hand-back"] {
            #expect(LinkDoorPolicy.route(method: "POST", path: path, websocket: false) == .hermes)
            #expect(LinkDoorPolicy.route(method: "GET", path: path, websocket: false) == .refused)
            #expect(LinkDoorPolicy.route(method: "DELETE", path: path, websocket: false) == .refused)
            #expect(LinkDoorPolicy.route(method: "GET", path: path, websocket: true) == .refused)
            #expect(LinkDoorPolicy.route(method: "POST", path: path + "/now", websocket: false) == .refused)
            #expect(LinkDoorPolicy.allowsQuery(path: path, query: "profile=default"))
            #expect(LinkDoorPolicy.allowsQuery(path: path, query: "profile=night-owl_2"))
            for bad in [nil, "", "profile=", "profile=a&profile=b", "profile=default&x=1", "x=1", "profile=../x",
                        "profile=a%2Fb", "profile=" + String(repeating: "a", count: 65), "profile"] {
                #expect(!LinkDoorPolicy.allowsQuery(path: path, query: bad), "\(bad ?? "nil")")
            }
        }
        // Everything else keeps its query as before.
        #expect(LinkDoorPolicy.allowsQuery(path: "/api/sessions", query: "limit=5&profile=x"))
        for other in ["/api/plugins/nollie-computer/own-computer", "/api/plugins/nollie-computer/takeover",
                      "/api/plugins/nollie-computer/take-over/../preview"] {
            #expect(LinkDoorPolicy.route(method: "POST", path: other, websocket: false) == .refused)
        }
    }

    @Test func awayRoutesAreTheDoorsOwn() {
        #expect(LinkDoorPolicy.route(method: "GET", path: "/nollie/link/hosts", websocket: false) == .hosts)
        #expect(LinkDoorPolicy.route(method: "POST", path: "/nollie/link/hosts", websocket: false) == .refused)
        #expect(LinkDoorPolicy.route(method: "POST", path: "/nollie/link/away/on", websocket: false) == .awayOn)
        #expect(LinkDoorPolicy.route(method: "POST", path: "/nollie/link/away/off", websocket: false) == .awayOff)
        #expect(LinkDoorPolicy.route(method: "GET", path: "/nollie/link/away/on", websocket: false) == .refused)
        #expect(LinkDoorPolicy.route(method: "GET", path: "/nollie/link/hosts", websocket: true) == .refused)
        #expect(LinkDoorPolicy.route(method: "POST", path: "/nollie/link/away", websocket: false) == .refused)
        #expect(LinkDoorPolicy.route(method: "GET", path: "/api/nollie/link/hosts", websocket: false) == .refused)
    }

    @Test func tailnetSourcesAreToldApart() {
        func v4(_ text: String) -> Bool { LinkDoorPolicy.isTailnetSource(.hostPort(host: .ipv4(IPv4Address(text)!), port: 1)) }
        func v6(_ text: String) -> Bool { LinkDoorPolicy.isTailnetSource(.hostPort(host: .ipv6(IPv6Address(text)!), port: 1)) }
        #expect(v4("100.64.0.1") && v4("100.101.102.103") && v4("100.127.255.254"))
        #expect(!v4("100.63.255.255") && !v4("100.128.0.1") && !v4("192.168.1.20") && !v4("10.0.0.5"))
        #expect(v6("fd7a:115c:a1e0::1234:5678") && v6("::ffff:100.101.102.103"))
        #expect(!v6("fd00::1") && !v6("fe80::1") && !v6("fd7a:115c:a1e1::1"))
        // The door still admits all of them as private when away from home is on.
        #expect(LinkDoorPolicy.allowsIPv4([100, 101, 102, 103], allowLoopback: false))
        #expect(LinkDoorPolicy.allowsIPv6(Array(IPv6Address("fd7a:115c:a1e0::1")!.rawValue), allowLoopback: false))
        #expect(LinkDoorPolicy.isTailnetHost("studio.tail1234.ts.net") && LinkDoorPolicy.isTailnetHost("100.101.102.103"))
        #expect(LinkDoorPolicy.isTailnetHost("fd7a:115c:a1e0::1") && !LinkDoorPolicy.isTailnetHost("studio.local"))
    }

    @Test func awayIsOffForANewMacAndKeptForPhonesLinkedBefore() throws {
        let fresh = LinkDoorMemoryState()
        #expect(try LinkDoorDevices(store: fresh).away == false)
        #expect(fresh.current?.away == false)

        let device = LinkDoorDevices.Device(id: UUID(), name: "Phone", credentialHash: Data(repeating: 1, count: 32), linkedAt: Date())
        let older = LinkDoorMemoryState(LinkDoorDevices.State(installTag: "0123456789abcdef", devices: [device]))
        #expect(try LinkDoorDevices(store: older).away == true)
        #expect(older.current?.away == true)
        // Decided once: a phone linked later doesn't turn it on at the next start.
        let empty = LinkDoorMemoryState(LinkDoorDevices.State(installTag: "0123456789abcdef"))
        let devices = try LinkDoorDevices(store: empty)
        _ = try devices.claim(secret: devices.makeOffer().secret, name: "Phone")
        #expect(try LinkDoorDevices(store: empty).away == false)

        try devices.setAway(true, host: .some("studio.tail1234.ts.net"))
        #expect(empty.current?.away == true && empty.current?.awayHost == "studio.tail1234.ts.net")
        try devices.setAway(false)
        #expect(empty.current?.away == false && empty.current?.awayHost == "studio.tail1234.ts.net")
        try devices.setAway(false, host: .some(nil))
        #expect(empty.current?.awayHost == nil)
    }

    @Test(.timeLimit(.minutes(1))) func linkedPhoneLearnsHostsAndSwitchingOffDropsTheTailnet() async throws {
        let fixture = try await DoorFixture.start()
        defer { fixture.stop() }
        let door = fixture.door
        door.hostsProvider = { (["192.168.1.20", "studio.local", "studio.tail1234.ts.net", "100.101.102.103"], "ready") }
        let linked = try door.devices.claim(secret: door.devices.makeOffer().secret, name: "Corey's iPhone")
        try await door.refresh()
        let port = Int(try #require(door.port))
        let pin = door.identity.pin

        let stranger = try await RawTLS.exchange(port: port, pin: pin, send: Data("GET /nollie/link/hosts HTTP/1.1\r\nHost: h\r\n\r\n".utf8))
        #expect(stranger.hasPrefix("HTTP/1.1 401 "))

        let gateway = try GatewayURL.normalize("https://127.0.0.1:\(port)")
        let owner = UUID()
        GatewayTrust.shared.register(pin: pin, host: "127.0.0.1", port: port, owner: owner)
        defer { GatewayTrust.shared.forget(owner: owner) }
        let api = HermesAPI(gateway: gateway, signer: RequestSigner(authMode: .sessionToken, secrets: .init(sessionToken: linked.credential, linkedDevice: true)))

        // Off (a new Mac): only home hosts go out, whatever the helper found.
        var (body, http) = try await api.raw("GET", NollieLinkClient.hostsPath, body: nil, authenticated: true)
        #expect(http.statusCode == 200)
        var reply = try #require(NollieLinkHostsReply.decode(body))
        #expect(reply == NollieLinkHostsReply(hosts: ["192.168.1.20", "studio.local"], away: false, tailscale: "ready"))

        (body, http) = try await api.raw("POST", NollieLinkClient.awayOnPath, body: nil, authenticated: true)
        reply = try #require(NollieLinkHostsReply.decode(body))
        #expect(reply.away && reply.hosts.contains("studio.tail1234.ts.net") && reply.hosts.contains("100.101.102.103"))
        #expect(door.devices.away)

        (body, http) = try await api.raw("POST", NollieLinkClient.awayOffPath, body: nil, authenticated: true)
        reply = try #require(NollieLinkHostsReply.decode(body))
        #expect(!reply.away && !reply.hosts.contains { NollieTailnet.isTailnetHost($0) })
        #expect(!door.devices.away)

        // A body is refused, and none of this reaches Hermes.
        let withBody = "POST /nollie/link/away/on HTTP/1.1\r\nHost: h\r\nX-Hermes-Session-Token: \(linked.credential)\r\nContent-Length: 2\r\n\r\n{}"
        #expect(try await RawTLS.exchange(port: port, pin: pin, send: Data(withBody.utf8)).hasPrefix("HTTP/1.1 413 "))
        #expect(!door.devices.away)
        #expect(fixture.hermes.requests.isEmpty)
    }

    @Test func theAwayKeySwapIsItsOwnRouteAndThePhoneNeverReachesPapertrailsWriter() {
        #expect(LinkDoorPolicy.route(method: "POST", path: "/nollie/link/seal", websocket: false) == .seal)
        for (method, path, socket) in [("GET", "/nollie/link/seal", false), ("PUT", "/nollie/link/seal", false),
                                       ("POST", "/nollie/link/seal", true), ("POST", "/nollie/link/seal/", false),
                                       ("POST", "/api/nollie/link/seal", false), ("POST", "/nollie/link/Seal", false)] {
            #expect(LinkDoorPolicy.route(method: method, path: path, websocket: socket) == .refused, "\(method) \(path)")
        }
        // Only the Mac app records what it sent through iCloud.
        #expect(LinkDoorPolicy.route(method: "POST", path: "/api/plugins/nollie-workflow/papertrail/icloud", websocket: false) == .refused)
        #expect(LinkDoorPolicy.route(method: "GET", path: "/api/plugins/nollie-workflow/papertrail", websocket: false) == .hermes)
    }

    @Test(.timeLimit(.minutes(1))) func aLinkedPhoneSwapsAwayKeysAndOnlyPublicKeysPass() async throws {
        let fixture = try await DoorFixture.start()
        defer { fixture.stop() }
        let door = fixture.door
        let linked = try door.devices.claim(secret: door.devices.makeOffer().secret, name: "Corey's iPhone")
        try await door.refresh()
        let port = Int(try #require(door.port))
        let pin = door.identity.pin
        let phone = AwayKey()
        let body = Data(#"{"key":"\#(AwayBase64URL.encode(phone.publicKey))"}"#.utf8)

        let stranger = "POST /nollie/link/seal HTTP/1.1\r\nHost: h\r\nContent-Length: \(body.count)\r\n\r\n" + String(decoding: body, as: UTF8.self)
        #expect(try await RawTLS.exchange(port: port, pin: pin, send: Data(stranger.utf8)).hasPrefix("HTTP/1.1 401 "))

        let gateway = try GatewayURL.normalize("https://127.0.0.1:\(port)")
        let owner = UUID()
        GatewayTrust.shared.register(pin: pin, host: "127.0.0.1", port: port, owner: owner)
        defer { GatewayTrust.shared.forget(owner: owner) }
        let api = HermesAPI(gateway: gateway, signer: RequestSigner(authMode: .sessionToken, secrets: .init(sessionToken: linked.credential, linkedDevice: true)))

        // Before the Mac app gave its key, the door says to open Nollie on the Mac.
        var (reply, http) = try await api.raw("POST", NollieLinkClient.sealPath, body: (body, "application/json"), authenticated: true, answers: [503])
        #expect(http.statusCode == 503)
        #expect(door.devices.devices.first?.awayKey == nil)

        let mac = AwayKey()
        try door.devices.setAwayMacKey(mac.publicKey)
        (reply, http) = try await api.raw("POST", NollieLinkClient.sealPath, body: (body, "application/json"), authenticated: true)
        #expect(http.statusCode == 200)
        let answer = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: String])
        #expect(answer == ["key": AwayBase64URL.encode(mac.publicKey)])
        #expect(door.devices.devices.first?.awayKey == phone.publicKey)

        // Both ends now make the same channel.
        let phoneEnd = try AwayChannel(own: phone, side: .phone, otherPublic: try #require(AwayBase64URL.decode(answer["key"] ?? "")))
        let macEnd = try AwayChannel(own: mac, side: .mac, otherPublic: try #require(door.devices.devices.first?.awayKey))
        #expect(phoneEnd.macTag == macEnd.macTag && phoneEnd.phoneTag == macEnd.phoneTag)

        // Odd bodies are refused and change nothing.
        for bad in [#"{"key":"short"}"#, #"{"key":"\#(AwayBase64URL.encode(phone.publicKey))","extra":1}"#, #"{}"#, "not json"] {
            (_, http) = try await api.raw("POST", NollieLinkClient.sealPath, body: (Data(bad.utf8), "application/json"), authenticated: true, answers: [400])
            #expect(http.statusCode == 400, "\(bad)")
        }
        #expect(door.devices.devices.first?.awayKey == phone.publicKey)

        // A new Mac key forgets the phones' keys: each swaps again at home.
        try door.devices.setAwayMacKey(AwayKey().publicKey)
        #expect(door.devices.devices.first?.awayKey == nil)
        #expect(fixture.hermes.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func takeOverReachesHermesOnlyWithAProfile() async throws {
        let fixture = try await DoorFixture.start()
        defer { fixture.stop() }
        let door = fixture.door
        let linked = try door.devices.claim(secret: door.devices.makeOffer().secret, name: "Corey's iPhone")
        try await door.refresh()
        let port = Int(try #require(door.port))
        func post(_ target: String) async throws -> String {
            let raw = "POST \(target) HTTP/1.1\r\nHost: h\r\nX-Hermes-Session-Token: \(linked.credential)\r\nContent-Length: 2\r\n\r\n{}"
            return try await RawTLS.exchange(port: port, pin: door.identity.pin, send: Data(raw.utf8))
        }
        #expect(try await post("/api/plugins/nollie-computer/take-over?profile=default&cmd=x").hasPrefix("HTTP/1.1 403 "))
        #expect(try await post("/api/plugins/nollie-computer/hand-back").hasPrefix("HTTP/1.1 403 "))
        #expect(fixture.hermes.requests.isEmpty)
        // The fake Hermes has no add-on, so its 404 shows the request got there.
        #expect(try await post("/api/plugins/nollie-computer/take-over?profile=default").hasPrefix("HTTP/1.1 404 "))
        #expect(try await post("/api/plugins/nollie-computer/hand-back?profile=default").hasPrefix("HTTP/1.1 404 "))
        #expect(fixture.hermes.requests.map(\.line) == ["POST /api/plugins/nollie-computer/take-over?profile=default HTTP/1.1",
                                                        "POST /api/plugins/nollie-computer/hand-back?profile=default HTTP/1.1"])
    }
}

// MARK: Fixtures

/// A locked value that escaping callbacks may share.
final class DoorTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = 0xBF58_476D_1CE4_E5B9 &* (z ^ (z >> 30))
        z = 0x94D0_49BB_1331_11EB &* (z ^ (z >> 27))
        return z ^ (z >> 31)
    }
}

struct DoorFixture {
    static let upstreamToken = String(repeating: "e", count: 64)
    let door: LinkDoor
    let hermes: FakeHermes
    let identityName: String

    static func start(acceptLoopback: Bool = true, upstream: Bool = true,
                      tune: (inout LinkDoor.Configuration) -> Void = { _ in }) async throws -> DoorFixture {
        let hermes = try await FakeHermes.start()
        let name = "com.coreykozarski.nollie.link.test." + UUID().uuidString
        let identity = try LinkDoorIdentity.loadOrCreate(name: name)
        let devices = try LinkDoorDevices(store: LinkDoorMemoryState())
        let port = hermes.port
        var configuration = LinkDoor.Configuration(name: "Test Mac", port: 0, loopbackOnly: true, acceptLoopback: acceptLoopback, advertise: false)
        tune(&configuration)
        let door = LinkDoor(configuration: configuration, identity: identity, devices: devices) {
            upstream ? LinkDoor.Upstream(port: port, token: upstreamToken) : nil
        }
        return DoorFixture(door: door, hermes: hermes, identityName: name)
    }

    func stop() {
        door.stop()
        hermes.stop()
        LinkDoorIdentity.remove(name: identityName)
    }
}

/// Just enough Hermes: status, profiles, and a socket that says it is ready, all on loopback.
final class FakeHermes: @unchecked Sendable {
    struct Seen: Sendable { let line: String; let head: String }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "nollie.tests.fake-hermes")
    private let seen = DoorTestBox<[Seen]>([])
    private let texts = DoorTestBox<[String]>([])
    private(set) var port = 0
    var requests: [Seen] { seen.withLock { $0 } }
    /// What the phone's socket messages looked like once they reached Hermes.
    var socketTexts: [String] { texts.withLock { $0 } }

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> FakeHermes {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let fake = FakeHermes(listener: try NWListener(using: parameters))
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

    func stop() { listener.cancel() }

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
            let line = String(head.split(separator: "\r\n").first ?? "")
            self.seen.withLock { $0.append(Seen(line: line, head: head)) }
            self.answer(connection, line: line, head: head)
        }
    }

    private func answer(_ connection: NWConnection, line: String, head: String) {
        if line.hasPrefix("GET /api/ws") {
            let key = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) } ?? ""
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            var reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
            let ready = Data(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready"}}"#.utf8)
            reply.append(contentsOf: [0x81, UInt8(ready.count)])
            reply.append(ready)
            connection.send(content: reply, completion: .contentProcessed { _ in
                self.drain(connection, reader: LinkDoorWebSocket.ClientReader(maximumMessage: 1 << 20))
            })
            return
        }
        let body: String
        switch line {
        case "GET /api/status HTTP/1.1": body = #"{"version":"fake","auth_required":false}"#
        case "GET /api/profiles HTTP/1.1": body = #"{"profiles":[]}"#
        default: body = #"{"detail":"not here"}"#
        }
        let status = body.contains("not here") ? "404 Not Found" : "200 OK"
        let reply = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func drain(_ connection: NWConnection, reader: LinkDoorWebSocket.ClientReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var reader = reader
            if let messages = try? reader.feed(data ?? Data()) {
                for case .text(let text) in messages { self.texts.withLock { $0.append(String(decoding: text, as: UTF8.self)) } }
            }
            if complete || error != nil { connection.cancel() } else { self.drain(connection, reader: reader) }
        }
    }
}

/// One raw exchange over pinned TLS, for what URLSession would never send.
enum RawTLS {
    /// A pinned TLS connection that has finished its handshake and then sits idle.
    static func open(port: Int, pin: Data) async throws -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            complete(NollieLinkPin.matches(sec_trust_copy_ref(trust).takeRetainedValue(), pin: pin))
        }, .global())
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: NWParameters(tls: tls))
        let queue = DispatchQueue(label: "nollie.tests.raw-open")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWConnection, Error>) in
            let once = DoorTestBox(Optional(continuation))
            @Sendable func finish(_ result: Result<NWConnection, Error>) { once.withLock { $0?.resume(with: result); $0 = nil } }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(connection))
                case .failed(let error): finish(.failure(error))
                case .waiting(let error): connection.cancel(); finish(.failure(error))
                case .cancelled: finish(.failure(NWError.posix(.ECANCELED)))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { connection.cancel(); finish(.failure(NWError.posix(.ETIMEDOUT))) }
        }
    }

    static func exchange(port: Int, pin: Data, send: Data) async throws -> String {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            complete(NollieLinkPin.matches(sec_trust_copy_ref(trust).takeRetainedValue(), pin: pin))
        }, .global())
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: NWParameters(tls: tls))
        defer { connection.cancel() }
        let queue = DispatchQueue(label: "nollie.tests.raw-tls")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = DoorTestBox(Optional(continuation))
            @Sendable func finish(_ result: Result<String, Error>) { once.withLock { $0?.resume(with: result); $0 = nil } }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: send, completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                        if let data { finish(.success(String(decoding: data, as: UTF8.self))) }
                        else { finish(.failure(error ?? NWError.posix(.ECONNRESET))) }
                    }
                case .failed(let error): finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { finish(.failure(NWError.posix(.ETIMEDOUT))) }
        }
    }
}
#endif
