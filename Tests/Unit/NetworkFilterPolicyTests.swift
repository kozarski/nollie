#if os(macOS)
import Foundation
import Testing
@testable import NollieCore

/// Papertrail's network filter, its rules without the system: what belongs to Hermes, what went around the
/// door, and whose it was.
struct NetworkFilterPolicyTests {
    typealias P = NetworkFilterPolicy
    private let runtime = P.Ancestor(pid: 100, parent: 1, isRuntime: true)
    private let hermes = P.Ancestor(pid: 200, parent: 100, isRuntime: false)
    private let curl = P.Ancestor(pid: 300, parent: 200, isRuntime: false)
    private let on = P.Switch(on: true)
    private let refusing = P.Switch(on: true, refuse: true)

    @Test func onlyHermessTreeGoingAroundTheDoorIsReported() {
        #expect(P.verdict(chain: [curl, hermes, runtime], remoteIsLoopback: false, switch: on) == .report)
        #expect(P.verdict(chain: [hermes, runtime], remoteIsLoopback: false, switch: refusing) == .refuse)
        // Through the door (loopback), Nollie Runtime's own (the door's upstream), and other apps: left alone.
        #expect(P.verdict(chain: [curl, hermes, runtime], remoteIsLoopback: true, switch: refusing) == .allow)
        #expect(P.verdict(chain: [runtime], remoteIsLoopback: false, switch: refusing) == .allow)
        #expect(P.verdict(chain: [P.Ancestor(pid: 9, parent: 1, isRuntime: false)], remoteIsLoopback: false, switch: refusing) == .allow)
        #expect(P.verdict(chain: [], remoteIsLoopback: false, switch: refusing) == .allow)
        // Off is off.
        #expect(P.verdict(chain: [curl, hermes, runtime], remoteIsLoopback: false, switch: .off) == .allow)
        // A tree deeper than the walk is not claimed.
        let deep = (0..<40).map { P.Ancestor(pid: Int32(1000 + $0), parent: Int32(1001 + $0), isRuntime: false) } + [runtime]
        #expect(P.verdict(chain: deep, remoteIsLoopback: false, switch: on) == .allow)
    }

    @Test func theSwitchIsOffUnlessItSaysOn() {
        #expect(P.Switch.read(nil) == .off)
        #expect(P.Switch.read(Data("{".utf8)) == .off)
        #expect(P.Switch.read(Data(#"{"version": 2, "on": true}"#.utf8)) == .off)
        #expect(P.Switch.read(Data(#"{"version": 1, "on": true, "refuse": true}"#.utf8)) == refusing)
        #expect(P.Switch.read(Data(#"{"version": 1, "on": true}"#.utf8)) == on)
        #expect(P.Switch.read(Data(#"{"version": 1}"#.utf8)) == .off)
        // Refuse means nothing without on.
        #expect(P.Switch.read(Data(#"{"version": 1, "on": false, "refuse": true}"#.utf8)) == .off)
    }

    @Test func loopbackIsThisMacOnly() {
        for host in ["127.0.0.1", "127.9.9.9", "::1", "[::1]", "localhost", "::ffff:127.0.0.1"] { #expect(P.isLoopback(host), "\(host)") }
        for host in ["10.0.0.1", "192.168.1.1", "example.com", "", "::ffff:10.0.0.1", "128.0.0.1"] { #expect(!P.isLoopback(host), "\(host)") }
    }

    @Test func procargsAreReadStrictly() {
        func blob(_ count: Int32, _ parts: [String], padding: Int = 3) -> Data {
            var data = withUnsafeBytes(of: count.littleEndian) { Data($0) }
            data.append(Data(parts[0].utf8) + Data([0]) + Data(repeating: 0, count: padding))
            for part in parts.dropFirst() { data.append(Data(part.utf8) + Data([0])) }
            return data
        }
        let parsed = P.arguments(blob(2, ["/usr/bin/curl", "curl", "https://a.example", "HOME=/Users/x", "HTTPS_PROXY=http://scout.terminal:s@127.0.0.1:1"]))
        #expect(parsed == .init(executable: "/usr/bin/curl", arguments: ["curl", "https://a.example"],
                                environment: ["HOME=/Users/x", "HTTPS_PROXY=http://scout.terminal:s@127.0.0.1:1"]))
        #expect(P.arguments(Data([1, 0])) == nil)
        #expect(P.arguments(blob(5, ["/bin/sh", "sh"])) == nil)
        #expect(P.arguments(Data([0, 0, 0, 0]) + Data("/bin/sh".utf8)) == nil)
    }

    @Test func theBotComesFromTheDoorLabelItStartedWith() {
        #expect(P.label(environment: ["PATH=/bin", "HTTPS_PROXY=http://scout.terminal:abc@127.0.0.1:4000"])! == ("scout", "terminal"))
        #expect(P.label(environment: ["https_proxy=http://default.hermes:abc@127.0.0.1:4000"])! == ("default", "hermes"))
        #expect(P.label(environment: ["HTTPS_PROXY=http://unplaced.program:abc@127.0.0.1:4000"]) == nil)
        #expect(P.label(environment: ["HTTPS_PROXY=http://their.proxy:3128"]) == nil)
        #expect(P.label(environment: ["HTTPS_PROXY=http://their.proxy:3128", "ALL_PROXY=http://wren.mcp:x@127.0.0.1:1"])! == ("wren", "mcp"))
        #expect(P.label(environment: []) == nil)
    }
}
#endif
