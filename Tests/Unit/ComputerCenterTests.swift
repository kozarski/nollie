#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import NollieCore
import Testing
@testable import Nollie

/// Ask, Show, Stop, with a recorded driver in place of the helper: nothing starts without the
/// person's yes, nothing runs unattended, risky actions wait for the person, and Stop or any
/// limit ends the helper.
@MainActor
@Suite(.serialized) struct ComputerCenterTests {
    final class Recorder: ComputerPresenting {
        var shown: [String] = []
        func showApproval() { shown.append("approval") }
        func showConfirmation() { shown.append("confirmation") }
        func hideCards() { shown.append("hide") }
        func showStop() { shown.append("stop") }
        func hideStop() { shown.append("hideStop") }
        func showPermissions() { shown.append("permissions") }
    }

    final class FakeDriver: ComputerDriving, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(session: String, tool: String, args: [String: Any])] = []
        private var _stops = 0
        var calls: [(session: String, tool: String, args: [String: Any])] { lock.withLock { _calls } }
        var stops: Int { lock.withLock { _stops } }
        var isRunning: Bool { lock.withLock { _stops == 0 } }

        private var _failNext = false
        var failNext: Bool { get { lock.withLock { _failNext } } set { lock.withLock { _failNext = newValue } } }

        func call(_ session: String, _ tool: String, _ args: [String: Any]) throws -> [String: Any] {
            let fail = lock.withLock { () -> Bool in defer { _failNext = false }; return _failNext }
            if fail { throw ComputerHelper.Failure.notReady }
            lock.withLock { _calls.append((session, tool, args)) }
            switch tool {
            case "list_windows":
                return ["structuredContent": ["windows": [["window_id": 7, "layer": 0, "is_on_screen": true]]]]
            case "get_window_state":
                // Screen points and screenshot pixels differ (a 0.5 scale here), as on a real Mac.
                let send: [String: Any] = ["element_token": "s00000001:1", "role": "AXButton", "label": "Send",
                                           "frame": ["x": 1010.0, "y": 510.0, "w": 100.0, "h": 40.0],
                                           "screenshot_frame": ["x": 10, "y": 10, "w": 50, "h": 20]]
                let bold: [String: Any] = ["element_token": "s00000001:2", "role": "AXButton", "label": "Bold",
                                           "frame": ["x": 1200.0, "y": 510.0, "w": 60.0, "h": 40.0],
                                           "screenshot_frame": ["x": 100, "y": 10, "w": 30, "h": 20]]
                let body: [String: Any] = ["element_token": "s00000001:3", "role": "AXTextArea", "label": "Body",
                                           "frame": ["x": 1010.0, "y": 600.0, "w": 400.0, "h": 300.0],
                                           "screenshot_frame": ["x": 10, "y": 55, "w": 200, "h": 150]]
                let link: [String: Any] = ["element_token": "s00000001:4", "element_index": 4, "role": "AXLink", "label": "Report",
                                           "frame": ["x": 1300.0, "y": 510.0, "w": 80.0, "h": 20.0],
                                           "screenshot_frame": ["x": 150, "y": 10, "w": 40, "h": 10]]
                let web: [String: Any] = ["element_token": "s00000001:5", "element_index": 5, "role": "AXLink", "label": "Docs",
                                          "frame": ["x": 1400.0, "y": 510.0, "w": 80.0, "h": 20.0],
                                          "screenshot_frame": ["x": 200, "y": 10, "w": 40, "h": 10]]
                // A picture inside a link, which the app itself reports as just a picture.
                let picture: [String: Any] = ["element_token": "s00000001:6", "element_index": 6, "parent_index": 4, "role": "AXImage",
                                              "label": "", "frame": ["x": 1500.0, "y": 510.0, "w": 20.0, "h": 20.0],
                                              "screenshot_frame": ["x": 250, "y": 10, "w": 10, "h": 10]]
                return ["structuredContent": ["tree_markdown": "[1] AXButton \"Send\"\n[2] AXButton \"Bold\"",
                                              "elements": [send, bold, body, link, web, picture]],
                        "content": [["type": "image", "data": ComputerCenterTests.picture, "mimeType": "image/png"]]]
            default:
                return ["content": [["type": "text", "text": "ok"]]]
            }
        }

        func stop() -> TimeInterval {
            lock.withLock { _stops += 1 }
            return 0
        }
    }

    final class Starts: @unchecked Sendable {
        private let lock = NSLock()
        private var _apps: [[ComputerTask.App]] = []
        var apps: [[ComputerTask.App]] { lock.withLock { _apps } }
        func record(_ apps: [ComputerTask.App]) { lock.withLock { _apps.append(apps) } }
    }

    /// The app as the live probe sees it, in screen points: the same three elements the look reports.
    nonisolated(unsafe) static var live: [ComputerAction.Target] = [
        .init(role: "AXButton", label: "Send", frame: CGRect(x: 1010, y: 510, width: 100, height: 40)),
        .init(role: "AXButton", label: "Bold", frame: CGRect(x: 1200, y: 510, width: 60, height: 40)),
        .init(role: "AXTextArea", label: "Body", frame: CGRect(x: 1010, y: 600, width: 400, height: 300)),
        .init(role: "AXLink", label: "Report", frame: CGRect(x: 1300, y: 510, width: 80, height: 20), url: "smb://server/share"),
        // The app now says this is a plain button: the look said link, and that stands.
        .init(role: "AXButton", label: "Docs", frame: CGRect(x: 1400, y: 510, width: 80, height: 20), url: "https://example.com/docs"),
        .init(role: "AXImage", label: nil, frame: CGRect(x: 1500, y: 510, width: 20, height: 20)),
    ]
    nonisolated(unsafe) static var liveFocused: ComputerAction.Target? = live[2]

    nonisolated static let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nollie-computer-tests")

    /// A real PNG of the window, 300 by 210 pixels (the window is 600 by 420 points at half scale).
    nonisolated static let picture: String = png(width: 300, height: 210)

    nonisolated static func png(width: Int, height: Int) -> String {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return (data as Data).base64EncodedString()
    }

    let center = ComputerCenter()
    let recorder = Recorder()
    let driver = FakeDriver()
    let starts = Starts()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        center.useTestScreen()
        center.presenter = recorder
        center.botName = { _ in "Scout" }
        center.helperAvailable = { true }
        center.permissionsGranted = { true }
        center.personPresent = { true }
        center.answerTimeout = 5
        center.verifySession = { request in
            .success(ComputerSessionFacts(chat: "career/" + request.sessionID, title: "Job hunt", source: "tui", callID: UUID().uuidString,
                                          platform: "Nollie"))
        }
        center.otherControl = { nil }
        center.otherControlNow = { nil }
        center.stillPending = { _, _ in true }
        center.isPrivate = { $0 == "private" }
        center.isWebApp = { _ in false }
        center.enabled = { true }
        center.usedCalls = ComputerUsedCalls(path: Self.scratch.appendingPathComponent("used-\(UUID().uuidString).json").path)
        center.authenticate = { _ in true }
        center.runningPID = { _ in 4242 }
        center.resolveShortcut = { _, key, _ in key == "f" ? ComputerAction.Shortcut(title: "Find…") : nil }
        center.isLocked = { false }
        center.inspect = { _, frame in
            // The app's own answer: what is at that spot now, or (no spot) the focused element.
            guard let frame else { return Self.liveFocused }
            return Self.live.first { $0.frame!.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        }
        center.resolveApp = { name in
            switch name {
            case "Notes": ComputerAppInfo(bundleID: "com.apple.Notes", name: "Notes", signer: "apple")
            case "Viewer": ComputerAppInfo(bundleID: "org.example.viewer", name: "Viewer", opensWebPages: true)
            case "Terminal": ComputerAppInfo(bundleID: "com.apple.Terminal", name: "Terminal")
            default: nil
            }
        }
        let driver = driver, starts = starts
        center.startHelper = { apps in starts.record(apps); return driver }
    }

    private func request(_ apps: [String], session: String = "20261019_200000_abc") -> ComputerStartRequest {
        ComputerStartRequest(sessionID: session, profile: "career", apps: apps, purpose: "Tidy the Downloads folder")
    }

    /// Starts a request and answers its card.
    private func start(_ apps: [String] = ["Notes"], answer: Bool? = true,
                       session: String = "20261019_200000_abc") async -> Result<ComputerTask, ComputerCenter.Refusal> {
        let center = center
        let pending = Task { await center.requestStart(request(apps, session: session)) }
        if let answer {
            await Self.until { center.approval != nil }
            center.answerApproval(answer)
        }
        return await pending.value
    }

    /// Waits for a condition for up to two seconds; a test that would wait forever fails instead.
    static func until(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting", sourceLocation: sourceLocation)
    }

    private func waitForStops(_ count: Int) async {
        for _ in 0..<200 where driver.stops < count { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aViewerFindsTheTasksChatByHermesOwnIds() async throws {
        // As Hermes files it: the chat that asked continues an earlier one, its first.
        center.verifySession = { _ in
            .success(ComputerSessionFacts(chat: "career/20261019_190000_root", title: "Job hunt", source: "tui", callID: UUID().uuidString,
                                          profile: "career", platform: "Nollie",
                                          lineage: ["20261019_200000_abc", "20261019_190000_root"]))
        }
        let parents = ["20261019_210000_new": "20261019_200000_abc", "20261019_220000_other": "20261019_100000_elsewhere"]
        let asked = LiveTestBox(0)
        center.parentSession = { profile, id in
            asked.withLock { $0 += 1 }
            return profile == "career" ? parents[id] : nil
        }
        let task = try await start().get()
        #expect(task.sessionID == "career/20261019_190000_root")
        // The chat that asked and its first session, as a viewer may name them, without asking Hermes.
        #expect(await center.isTaskChat(profile: "career", sessionID: "20261019_200000_abc"))
        #expect(await center.isTaskChat(profile: "career", sessionID: "20261019_190000_root"))
        #expect(asked.withLock { $0 } == 0)
        // Compressed since the task started: followed back through Hermes's parent link, then known.
        #expect(await center.isTaskChat(profile: "career", sessionID: "20261019_210000_new"))
        #expect(center.task?.isChat(profile: "career", sessionID: "20261019_210000_new") == true)
        // Another chat, another bot, or the stored key itself: never.
        #expect(!(await center.isTaskChat(profile: "career", sessionID: "20261019_220000_other")))
        #expect(!(await center.isTaskChat(profile: "work", sessionID: "20261019_200000_abc")))
        #expect(!(await center.isTaskChat(profile: "career", sessionID: "career/20261019_190000_root")))
        center.stop()
        #expect(!(await center.isTaskChat(profile: "career", sessionID: "20261019_200000_abc")), "No task, no chat")
    }

    @Test func approvalStartsTheHelperAndStopEndsIt() async throws {
        let task = try await start().get()
        #expect(recorder.shown == ["approval", "hide", "stop"])
        #expect(starts.apps.map { $0.map(\.bundleID) } == [["com.apple.Notes"]])
        #expect(center.task?.id == task.id)
        #expect(task.botName == "Scout")
        #expect(task.sessionID == "career/20261019_200000_abc")
        #expect(task.purpose == "Tidy the Downloads folder")

        center.stop()
        #expect(center.task == nil)
        #expect(center.lastEnd == .stopped)
        #expect(recorder.shown.last == "hideStop")
        await waitForStops(1)
        #expect(driver.stops == 1)
        let after = await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes"))
        #expect(throws: ComputerCenter.Refusal.self) { try after.get() }
        #expect(driver.calls.isEmpty)
    }

    /// The iPhone hears about a task it did not start, once, with the bot and its chat.
    @Test func aStartIsAnnouncedOnce() async throws {
        var announced: [ComputerTask] = []
        center.announceStart = { announced.append($0) }
        let task = try await start().get()
        #expect(announced.map(\.id) == [task.id])
        #expect(announced.first?.profile == task.profile)
        center.stop()
        #expect(announced.count == 1)
    }

    @Test func nothingStartsWithoutAYes() async {
        let declined = await start(answer: false)
        #expect(declined == .failure(.init(message: ComputerCenter.declined)))
        center.answerTimeout = 0.1
        let unanswered = await start(answer: nil)
        #expect(unanswered == .failure(.init(message: ComputerCenter.noAnswer)))
        #expect(starts.apps.isEmpty)
        #expect(center.task == nil)
        #expect(center.approval == nil)
    }

    @Test func neverUnattended() async {
        center.personPresent = { false }
        #expect(await start(answer: nil) == .failure(.init(message: ComputerCenter.unattended)))
        center.personPresent = { true }
        #expect(await start(answer: nil, session: "cron_board_20261019_070000") == .failure(.init(message: ComputerCenter.unattended)))
        #expect(await start(answer: nil, session: "") == .failure(.init(message: ComputerCenter.unattended)))
        #expect(recorder.shown.isEmpty)
        #expect(starts.apps.isEmpty)
    }

    @Test func missingPermissionsOpenTheWalkthroughInstead() async {
        center.permissionsGranted = { false }
        #expect(await start(answer: nil) == .failure(.init(message: ComputerCenter.needsPermissions)))
        #expect(recorder.shown == ["permissions"])
        center.helperAvailable = { false }
        #expect(await start(answer: nil) == .failure(.init(message: ComputerCenter.noHelper)))
        #expect(starts.apps.isEmpty)
    }

    @Test func refusedAppsNeverReachTheCard() async throws {
        let result = await start(["Terminal", "Nope"], answer: nil)
        let message = try #require({ if case let .failure(r) = result { r.message } else { nil } }())
        #expect(message.contains(ComputerAppRules.commands))
        #expect(message.contains("Nope: Not on this Mac."))
        #expect(recorder.shown.isEmpty)
        // Mixed: the card lists the usable app and says why the other can't be used.
        let pending = Task { await center.requestStart(request(["Notes", "Terminal"])) }
        await Self.until { center.approval != nil }
        #expect(center.approval?.apps.map(\.name) == ["Notes"])
        #expect(center.approval?.refused == [.init(name: "Terminal", reason: ComputerAppRules.commands)])
        center.answerApproval(false)
        _ = await pending.value
    }

    @Test func oneTaskAtATime() async throws {
        _ = try await start().get()
        #expect(await start(answer: nil, session: "20261019_200000_other") == .failure(.init(message: ComputerCenter.busy)))
        // The same chat asking again replaces its own task after a new yes.
        _ = try await start().get()
        await waitForStops(1)
        #expect(driver.stops == 1)
        center.stop()
    }

    @Test func riskyClicksWaitForThePerson() async throws {
        let task = try await start().get()
        let look = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        #expect(look == [.text("Element tokens for this look: s00000001:N for the row marked [N], like s00000001:3.\n[1] AXButton \"Send\"\n[2] AXButton \"Bold\""),
                         .image(base64: Self.picture, mimeType: "image/png")])
        #expect(driver.calls.map(\.tool) == ["list_windows", "get_window_state"])
        #expect(driver.calls.allSatisfy { $0.session == "use" })
        #expect(driver.calls[1].args["window_id"] as? Int == 7)

        // An ordinary click runs at once, and uses up the look.
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", element: "s00000001:2")).get()
        #expect(driver.calls.last?.tool == "click")
        #expect(driver.calls.last?.args["element_token"] as? String == "s00000001:2")
        let used = await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", element: "s00000001:1"))
        #expect(used == .failure(.init(message: ComputerCenter.staleElement)))
        let usedPoint = await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", x: 30, y: 20))
        #expect(usedPoint == .failure(.init(message: ComputerCenter.lookFirst)))
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        #expect(driver.calls.count == 5)

        // "Send" waits; a no means nothing reaches the app.
        let center = center
        let refused = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", element: "s00000001:1")) }
        await Self.until { center.confirmation != nil }
        #expect(center.confirmation?.sentence == "send something in Notes: click \u{201C}Send\u{201D}")
        #expect(center.confirmation?.check == "You're about to press \u{201C}Send\u{201D}.")
        center.answerConfirmation(false)
        await #expect(throws: ComputerCenter.Refusal.self) { try await refused.value.get() }
        #expect(driver.calls.count == 5)

        // A pixel click on the same button (screenshot pixels, read live in screen points) waits too.
        let allowed = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", x: 30, y: 20)) }
        await Self.until { center.confirmation != nil }
        center.answerConfirmation(true)
        _ = try await allowed.value.get()
        #expect(driver.calls.last?.tool == "click")
        #expect(driver.calls.last?.args["x"] as? Double == 30)
        #expect(driver.calls.last?.args["window_id"] as? Int == 7)
        #expect(driver.calls.count == 6)

        // Typing: only into a text field Nollie saw and the app confirms; keys as Nollie judged them.
        let untargeted = await center.perform(taskID: task.id, ComputerActRequest(kind: .type, app: "Notes", text: "x"))
        #expect(untargeted == .failure(.init(message: ComputerActionRules.typeNeedsElement)))
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        let intoButton = await center.perform(taskID: task.id, ComputerActRequest(kind: .type, app: "Notes", element: "s00000001:2", text: "x"))
        #expect(intoButton == .failure(.init(message: ComputerCenter.notAField)))
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .type, app: "Notes", element: "s00000001:3", text: "Milk")).get()
        #expect(driver.calls.last?.tool == "type_text")
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .key, app: "Notes", keys: ["Cmd", "F"])).get()
        #expect(driver.calls.last?.tool == "hotkey")
        #expect(driver.calls.last?.args["keys"] as? [String] == ["cmd", "f"])
        #expect(driver.calls.count == 10)

        // Stop while the person is deciding refuses the action, says why, and ends the task.
        let pending = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .key, app: "Notes", keys: ["kp_enter"])) }
        await Self.until { center.confirmation != nil }
        // Only one action at a time.
        let second = await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes"))
        #expect(second == .failure(.init(message: ComputerCenter.stillActing)))
        center.stop()
        #expect(await pending.value == .failure(.init(message: ComputerTask.End.stopped.message)))
        #expect(driver.calls.count == 10)
    }

    @Test func secretsAreCheckedWhereTheKeysActuallyGo() async throws {
        let task = try await start().get()
        defer { Self.liveFocused = Self.live[2] }
        // The focus sits in a password field: typing anywhere, or a letter key, is refused.
        Self.liveFocused = .init(role: "AXTextField", subrole: "AXSecureTextField", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        let typed = await center.perform(taskID: task.id, ComputerActRequest(kind: .type, app: "Notes", element: "s00000001:3", text: "x"))
        #expect(typed == .failure(.init(message: ComputerActionRules.secret)))
        let keyed = await center.perform(taskID: task.id, ComputerActRequest(kind: .key, app: "Notes", keys: ["h"]))
        #expect(keyed == .failure(.init(message: ComputerActionRules.secret)))
        // Nollie can't tell where a key goes: it doesn't press it.
        Self.liveFocused = nil
        let blind = await center.perform(taskID: task.id, ComputerActRequest(kind: .key, app: "Notes", keys: ["h"]))
        #expect(blind == .failure(.init(message: ComputerCenter.cantCheckKey)))
        #expect(driver.calls.map(\.tool) == ["list_windows", "get_window_state"])
        center.stop()
    }

    @Test func theBotsOwnInputDoesntCountAsAPerson() async throws {
        var clock = clock
        center.now = { clock }
        var idle: TimeInterval = 0
        center.secondsSinceInput = { idle }
        let task = try await start().get()
        // The person's last touch was at the start; the bot then acts every minute.
        for _ in 0..<4 {
            clock = clock.addingTimeInterval(60)
            _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
            _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .scroll, app: "Notes", element: "s00000001:3", direction: "down")).get()
            idle = 0  // the driver's events reset the idle clock at "now"
            #expect(center.personStillThere())
        }
        clock = clock.addingTimeInterval(61)
        idle = 61  // nobody since that last scroll, which was the bot's
        #expect(!center.personStillThere())
        center.stop()
    }

    @Test func viewOnlyAppsAreOnlyLookedAt() async throws {
        let task = try await start(["Viewer"]).get()
        #expect(task.apps.first?.viewOnly == true)
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Viewer")).get()
        #expect(driver.calls.allSatisfy { $0.session == "view" })
        let typed = await center.perform(taskID: task.id, ComputerActRequest(kind: .type, app: "Viewer", text: "hello"))
        #expect(typed == .failure(.init(message: ComputerActionRules.viewOnly)))
        let other = await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes"))
        #expect(throws: ComputerCenter.Refusal.self) { try other.get() }
        #expect(driver.calls.count == 2)
        center.stop()
    }

    @Test func limitsEndTheTask() async throws {
        var clock = clock
        center.now = { clock }
        let task = try await start().get()
        clock = clock.addingTimeInterval(5 * 60)
        let idle = await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes"))
        #expect(idle == .failure(.init(message: ComputerTask.End.idle.message)))
        #expect(center.task == nil)
        #expect(center.lastEnd == .idle)
        await waitForStops(1)
        #expect(driver.stops == 1)
        #expect(driver.calls.isEmpty)
    }

    @Test func theStopShortcutRegistersAndGoes() {
        let shortcut = ComputerStopShortcut.shared
        #expect(!shortcut.isRegistered)
        shortcut.register {}
        #expect(shortcut.isRegistered)
        shortcut.unregister()
        #expect(!shortcut.isRegistered)
    }

    @Test func onlyALiveChatOfThatBotGetsACard() async {
        center.verifySession = { _ in .failure(.init(message: ComputerSessionCheck.scheduled)) }
        #expect(await start(answer: nil) == .failure(.init(message: ComputerSessionCheck.scheduled)))
        #expect(recorder.shown.isEmpty)
        #expect(starts.apps.isEmpty)
        #expect(ComputerSessionCheck.judge(.object([:]), host: .dashboard) == ComputerSessionCheck.unknown)
        #expect(ComputerSessionCheck.judge(["source": "tui", "archived": true], host: .dashboard) == ComputerSessionCheck.unknown)
    }

    @Test func aStopWhileWaitingSaysWhyAndALateAnswerChangesNothing() async throws {
        let task = try await start().get()
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        let center = center
        let pending = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", element: "s00000001:1")) }
        await Self.until { center.confirmation != nil }
        let shown = try #require(center.confirmation?.id)
        center.answerConfirmation(true, id: UUID())  // a card that isn't showing
        #expect(center.confirmation?.id == shown)
        center.end(.idle)
        #expect(await pending.value == .failure(.init(message: ComputerTask.End.idle.message)))
        #expect(driver.calls.map(\.tool) == ["list_windows", "get_window_state"])
    }

    @Test func aBrokenHelperConnectionEndsTheTask() async throws {
        driver.failNext = true
        let task = try await start().get()
        let result = await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes"))
        #expect(result == .failure(.init(message: ComputerTask.End.helperExited.message)))
        #expect(center.task == nil)
        #expect(center.lastEnd == .helperExited)
    }

    @Test func aRequestNeedsItsOwnPendingCallInHermes() async {
        center.verifySession = { _ in .failure(.init(message: ComputerSessionCheck.noPendingCall)) }
        #expect(await start(answer: nil) == .failure(.init(message: ComputerSessionCheck.noPendingCall)))
        // One card per call: the same Hermes call can't open a second one.
        center.verifySession = { _ in .success(ComputerSessionFacts(chat: "career/root", title: "Job hunt", source: "tui", callID: "call-7")) }
        _ = await start(answer: false)
        #expect(await start(answer: nil) == .failure(.init(message: ComputerSessionCheck.noPendingCall)))
        #expect(starts.apps.isEmpty)
    }

    @Test func theCardShowsWhichChatAskedAndAllowNeedsThePerson() async throws {
        var proofs: [String] = []
        var passes = false
        center.authenticate = { reason in proofs.append(reason); return passes }
        let center = center
        let pending = Task { await center.requestStart(request(["Notes"])) }
        await Self.until { center.approval != nil }
        #expect(center.approval?.chatTitle == "Job hunt")
        #expect(center.approval?.platform == "Nollie")
        // Pressing Allow without Touch ID or the password does nothing.
        await center.allowWithOwner()
        #expect(center.approval != nil)
        passes = true
        await center.allowWithOwner()
        #expect(proofs == ["let Scout use Notes", "let Scout use Notes"])
        let task = try await pending.value.get()
        // Allow Once needs it too.
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        let risky = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", element: "s00000001:1")) }
        await Self.until { center.confirmation != nil }
        passes = false
        await center.allowOnceWithOwner(id: center.confirmation!.id)
        #expect(center.confirmation != nil)
        passes = true
        await center.allowOnceWithOwner(id: center.confirmation!.id)
        _ = try await risky.value.get()
        #expect(driver.calls.last?.tool == "click")
        center.stop()
    }

    @Test func anotherWayToDriveTheMacBlocksTheStart() async {
        center.otherControl = { "Mac control is on for Forager in its settings." }
        #expect(await start(answer: nil) == .failure(.init(message: "Mac control is on for Forager in its settings.")))
        #expect(recorder.shown.isEmpty)
        #expect(ComputerOtherControl.isDriver("/Users/x/.local/bin/cua-driver", ownHelper: "/A/Nollie Computer"))
        #expect(ComputerOtherControl.isDriver("/Applications/CuaDriver.app/Contents/MacOS/CuaDriver", ownHelper: "/A/Nollie Computer"))
        #expect(!ComputerOtherControl.isDriver("/A/Nollie Computer", ownHelper: "/A/Nollie Computer"))
        #expect(!ComputerOtherControl.isDriver("/Applications/Notes.app/Contents/MacOS/Notes", ownHelper: "/A/Nollie Computer"))
        #expect(ComputerOtherControl.isDriver("/Users/x/src/target/release/cua-driver-local", ownHelper: "/A/Nollie Computer"))
        // A renamed copy keeps its signature.
        #expect(ComputerOtherControl.isDriverIdentifier("com.trycua.driver"))
        #expect(ComputerOtherControl.isDriverIdentifier("com.coreykozarski.nollie.computer"))
        #expect(ComputerOtherControl.isDriverIdentifier("cua_driver-4f2a9c"))
        #expect(ComputerOtherControl.isDriverIdentifier("com.trycua.driver.local"))
        #expect(ComputerOtherControl.isDriverIdentifier("com.coreykozarski.nollie.demo.computer"))
        #expect(ComputerOtherControl.isDriverIdentifier("com.example.renamed-driver", team: "YCK386LBJ7"))
        #expect(!ComputerOtherControl.isDriverIdentifier("com.trycua.spaces.macos", team: "YCK386LBJ7"))
        #expect(!ComputerOtherControl.isDriverIdentifier("com.trycua.spaces.macos"))
        #expect(ComputerOtherControl.isDriverName("cua-driver"))
        #expect(!ComputerOtherControl.isDriverName("Notes"))
        #expect(!ComputerOtherControl.isDriverIdentifier(nil))
        // A socket that answers is a driver running, whatever its program is called.
        #expect(!ComputerOtherControl.answers(Self.scratch.appendingPathComponent("nothing.sock").path))
    }

    @Test func everythingIsCheckedAgainAfterTheYesAndEverySecond() async throws {
        // Something came on while the card was up.
        var other: String? = nil
        center.otherControl = { other }
        let center = center
        var pending = Task { await center.requestStart(request(["Notes"])) }
        await Self.until { center.approval != nil }
        other = "Mac control is on for Forager in its settings."
        center.answerApproval(true)
        #expect(await pending.value == .failure(.init(message: "Mac control is on for Forager in its settings.")))
        // The call was answered some other way meanwhile.
        other = nil
        center.stillPending = { _, _ in false }
        pending = Task { await center.requestStart(request(["Notes"])) }
        await Self.until { center.approval != nil }
        center.answerApproval(true)
        #expect(await pending.value == .failure(.init(message: ComputerSessionCheck.noPendingCall)))
        #expect(starts.apps.isEmpty)
        // A driver appears during a task: it ends within a second or so.
        center.stillPending = { _, _ in true }
        _ = try await start().get()
        var driverNow: String? = nil
        center.otherControlNow = { driverNow }
        driverNow = ComputerOtherControl.otherDriver
        for _ in 0..<300 where center.task != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(center.task == nil)
        #expect(center.lastEnd == .otherControl)
    }

    @Test func aTaskAnswersOnlyToTheProcessThatAskedForIt() async throws {
        let addOn = ComputerPeer(pid: 50, started: 100, host: .gateway, profile: "career")
        let other = ComputerPeer(pid: 51, started: 100, host: .gateway, profile: "career")
        var asked: [ComputerPeer?] = []
        center.verifySession = { request in
            asked.append(request.peer)
            return .success(ComputerSessionFacts(chat: "career/root", title: "Job hunt", source: "signal", callID: UUID().uuidString))
        }
        let center = center
        var start = request(["Notes"])
        start.peer = addOn
        let pending = Task { await center.requestStart(start) }
        await Self.until { center.approval != nil }
        #expect(center.approval?.platform == "Signal")
        center.answerApproval(true)
        let task = try await pending.value.get()
        #expect(asked == [addOn])
        // Another process with the task's id gets nothing, and can't end it.
        let stolen = await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes"), from: other)
        #expect(stolen == .failure(.init(message: ComputerCenter.ended)))
        let unknown = await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes"))
        #expect(unknown == .failure(.init(message: ComputerCenter.ended)))
        center.finish(taskID: task.id, from: other)
        #expect(center.task != nil)
        #expect(driver.calls.isEmpty)
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes"), from: addOn).get()
        center.finish(taskID: task.id, from: addOn)
        #expect(center.lastEnd == .finished)
    }

    @Test func offUntilThePersonTurnsItOnAndTheBotIsHermessOwn() async throws {
        // Off by default: nothing is checked, nothing shows.
        #expect(ComputerCenter().enabled() == UserDefaults.standard.bool(forKey: ComputerCenter.enabledKey))
        var on = false
        center.enabled = { on }
        var checked = 0
        center.verifySession = { request in
            checked += 1
            // Hermes files the chat under Forager, whatever the caller said.
            return .success(ComputerSessionFacts(chat: "forager/root", title: "Garden", source: "tui", callID: UUID().uuidString,
                                                 profile: "forager", platform: "Nollie"))
        }
        #expect(await start(answer: nil) == .failure(.init(message: ComputerCenter.off)))
        #expect(checked == 0)
        #expect(recorder.shown.isEmpty)
        on = true
        center.botName = { $0 == "forager" ? "Forager" : "Scout" }
        let center = center
        let pending = Task { await center.requestStart(request(["Notes"])) }
        await Self.until { center.approval != nil }
        #expect(center.approval?.botName == "Forager")
        center.answerApproval(true)
        let task = try await pending.value.get()
        #expect(task.profile == "forager")
        #expect(task.sessionID == "forager/root")
        // Turning it off ends a running task.
        on = false
        for _ in 0..<300 where center.task != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(center.task == nil)
        #expect(center.lastEnd == .stopped)
    }

    @Test func aPrivateBotNeverAsksAndUsedCallsStayUsed() async {
        var checked = 0
        center.verifySession = { _ in
            checked += 1
            return .success(ComputerSessionFacts(chat: "x/root", title: "t", source: "tui", callID: "call-9"))
        }
        let center = center
        let privateStart = Task { await center.requestStart(ComputerStartRequest(sessionID: "s1", profile: "private", apps: ["Notes"], purpose: "p")) }
        #expect(await privateStart.value == .failure(.init(message: ComputerSessionCheck.unknown)))
        #expect(checked == 0)
        // One card per Hermes call, also after Nollie restarts.
        _ = await start(answer: false)
        let restarted = ComputerCenter()
        restarted.usedCalls = ComputerUsedCalls(path: center.usedCalls.path)
        #expect(restarted.usedCalls.contains("x/root/call-9"))
        // Hermes's own fallback ids repeat across chats: a used id in one chat doesn't block another.
        #expect(!restarted.usedCalls.contains("x/other/call-9"))
    }

    @Test func escapesDuringACardAndMovedContentAreCaught() async throws {
        let clock = clock
        center.now = { clock }
        let task = try await start().get()
        // A step, then at once a risky click: the other app opening during the card ends the task.
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .scroll, app: "Notes", element: "s00000001:3", direction: "down")).get()
        // A wheel at the element, never its token (which would move focus).
        #expect(driver.calls.last?.args["element_token"] == nil)
        #expect(driver.calls.last?.args["x"] as? Double == 110)
        #expect(driver.calls.last?.args["window_id"] as? Int == 7)
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        let center = center
        let risky = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", element: "s00000001:1")) }
        await Self.until { center.confirmation != nil }
        center.appCameForward("com.apple.finder", at: clock)
        #expect(center.task != nil)
        center.answerConfirmation(true)
        #expect(await risky.value == .failure(.init(message: ComputerTask.End.otherApp.message)))
        #expect(center.lastEnd == .otherApp)
        #expect(!driver.calls.contains { $0.tool == "click" })
    }

    @Test func aPointClickIsCheckedAgainAfterTheYes() async throws {
        let task = try await start().get()
        defer { Self.live[0].frame = CGRect(x: 1010, y: 510, width: 100, height: 40) }
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        #expect(driver.calls.last?.args["tree_format"] as? String == "both")
        let center = center
        let click = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", x: 30, y: 20)) }
        await Self.until { center.confirmation != nil }
        // The window scrolled while the card was up: something else is under that spot now.
        Self.live[0].frame = CGRect(x: 1010, y: 540, width: 100, height: 40)
        center.answerConfirmation(true)
        #expect(await click.value == .failure(.init(message: ComputerCenter.lookFirst)))
        Self.live[0].frame = CGRect(x: 1010, y: 510, width: 100, height: 40)
        // The page changed the button's words while the card was up, by token too.
        defer { Self.live[0].label = "Send" }
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        let byToken = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", element: "s00000001:1")) }
        await Self.until { center.confirmation != nil }
        Self.live[0].label = "Delete workspace"
        center.answerConfirmation(true)
        #expect(await byToken.value == .failure(.init(message: ComputerCenter.lookFirst)))
        #expect(!driver.calls.contains { $0.tool == "click" })
        center.stop()
    }

    @Test func shortcutsNeverGoToAnAppBuiltOnAWebEngine() async throws {
        center.isWebApp = { _ in true }
        let task = try await start().get()
        let cmdF = await center.perform(taskID: task.id, ComputerActRequest(kind: .key, app: "Notes", keys: ["cmd", "f"]))
        #expect(cmdF == .failure(.init(message: ComputerActionRules.webShortcut)))
        center.stop()
    }

    @Test func theMainBotIsCalledDefault() {
        guard case let .start(request) = ComputerBroker.parse(["op": "start", "session_id": "s", "profile": "", "apps": ["Notes"], "purpose": "p"]) else {
            Issue.record("not a start")
            return
        }
        #expect(request.profile == "default")
    }

    @Test func focusMovingDuringACardIsCaught() async throws {
        let task = try await start().get()
        defer { Self.liveFocused = Self.live[2] }
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        let center = center
        // Return asks; while the card is up, focus moves onto a link.
        let enter = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .key, app: "Notes", keys: ["return"])) }
        await Self.until { center.confirmation != nil }
        Self.liveFocused = Self.live[3]
        center.answerConfirmation(true)
        #expect(await enter.value == .failure(.init(message: ComputerCenter.focusMoved)))
        // A typed line break the same way.
        Self.liveFocused = Self.live[2]
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        let typed = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .type, app: "Notes", element: "s00000001:3", text: "a\nb")) }
        await Self.until { center.confirmation != nil }
        Self.liveFocused = Self.live[0]
        center.answerConfirmation(true)
        #expect(await typed.value == .failure(.init(message: ComputerCenter.focusMoved)))
        #expect(!driver.calls.contains { ["press_key", "type_text"].contains($0.tool) })
        center.stop()
    }

    @Test func aStopDuringASlowCheckWinsAndTheMainThreadStaysFree() async throws {
        let task = try await start().get()
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        // The app takes its time to answer; Nollie asks it off the main thread.
        center.inspect = { _, frame in
            Thread.sleep(forTimeInterval: 0.4)
            return frame == nil ? Self.liveFocused : Self.live[1]
        }
        let center = center
        let click = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", element: "s00000001:2")) }
        try await Task.sleep(for: .milliseconds(100))
        center.stop()
        #expect(center.task == nil)
        #expect(await click.value == .failure(.init(message: ComputerTask.End.stopped.message)))
        #expect(!driver.calls.contains { $0.tool == "click" })
    }

    @Test func aSecondRequestCantSlipInWhileTheFirstLooksUpItsApps() async throws {
        // The first request has passed Hermes's checks and is now finding its apps, which takes a
        // moment: that is the gap a second request could slip through, leaving the first hanging.
        let lookup = Gate()
        center.resolveApp = { name in
            lookup.arrive()
            lookup.wait()
            return name == "Notes" ? ComputerAppInfo(bundleID: "com.apple.Notes", name: "Notes", signer: "apple") : nil
        }
        let center = center
        let first = Task { await center.requestStart(request(["Notes"])) }
        await Self.until { lookup.arrived }
        #expect(center.approval == nil)
        let second = await center.requestStart(request(["Notes"], session: "20261019_200000_other"))
        #expect(second == .failure(.init(message: ComputerCenter.asking)))
        lookup.open()
        await Self.until { center.approval != nil }
        #expect(center.approval?.request.sessionID == "20261019_200000_abc")
        center.answerApproval(true)
        _ = try await first.value.get()
        center.stop()
    }

    /// Blocks a background lookup until the test opens it.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var _arrived = false
        var arrived: Bool { lock.withLock { _arrived } }
        func arrive() { lock.withLock { _arrived = true } }
        func wait() { _ = semaphore.wait(timeout: .now() + 5) }
        func open() { semaphore.signal() }
    }

    @Test func oldGateReadingsCountAsOn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = now.addingTimeInterval(-5), old = now.addingTimeInterval(-30)
        #expect(ComputerOtherControl.judge(known: ["career"], couldDrive: ["career": false], readAt: fresh, now: now, driverRunning: false) == nil)
        #expect(ComputerOtherControl.judge(known: ["career"], couldDrive: ["career": false], readAt: old, now: now, driverRunning: false)
            == ComputerOtherControl.cantList)
        #expect(ComputerOtherControl.judge(known: ["career"], couldDrive: ["career": false], readAt: nil, now: now, driverRunning: false)
            == ComputerOtherControl.cantList)
        #expect(ComputerOtherControl.judge(known: ["career", "forager"], couldDrive: ["career": false], readAt: fresh, now: now, driverRunning: false)
            == String(format: ComputerOtherControl.cantCheckControl, "forager"))
        #expect(ComputerOtherControl.judge(known: ["career"], couldDrive: ["career": true], readAt: fresh, now: now, driverRunning: false)
            == String(format: ComputerOtherControl.systemControlOn, "career"))
        #expect(ComputerOtherControl.judge(known: ["career"], couldDrive: ["career": false], readAt: fresh, now: now, driverRunning: true)
            == ComputerOtherControl.otherDriver)
    }

    @Test func aKeyGoesOnlyWhereFocusAlreadyIs() async throws {
        let task = try await start().get()
        defer { Self.liveFocused = Self.live[2] }
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        // Typing could fall back to keys, which go where focus is: a line break there could press a link.
        Self.liveFocused = Self.live[3]
        let typed = await center.perform(taskID: task.id, ComputerActRequest(kind: .type, app: "Notes", element: "s00000001:3", text: "hi\n"))
        #expect(typed == .failure(.init(message: ComputerCenter.focusFirst)))
        // Scrolling needs a place.
        let nowhere = await center.perform(taskID: task.id, ComputerActRequest(kind: .scroll, app: "Notes", direction: "down"))
        #expect(nowhere == .failure(.init(message: ComputerCenter.scrollWhere)))
        // The token is the Body, but the focus is on the Send button: the key might land there.
        Self.liveFocused = Self.live[0]
        let elsewhere = await center.perform(taskID: task.id, ComputerActRequest(kind: .key, app: "Notes", element: "s00000001:3", keys: ["a"]))
        #expect(elsewhere == .failure(.init(message: ComputerCenter.focusFirst)))
        Self.liveFocused = Self.live[2]
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .key, app: "Notes", element: "s00000001:3", keys: ["a"])).get()
        #expect(driver.calls.last?.tool == "press_key")
        center.stop()
    }

    @Test func linksAskAndAnotherAppOpeningEndsTheTask() async throws {
        let clock = clock
        center.now = { clock }
        let task = try await start().get()
        // A link by token could be covered by another: links only by their spot.
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        let byToken = await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", element: "s00000001:5"))
        #expect(byToken == .failure(.init(message: ComputerCenter.linkByPoint)))
        // A link to a share is refused outright.
        let share = await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", x: 170, y: 15))
        #expect(share == .failure(.init(message: ComputerActionRules.otherLink)))
        // The look said link and the app now says button: it is still a link, and it asks.
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        let center = center
        let link = Task { await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", x: 220, y: 15)) }
        await Self.until { center.confirmation != nil }
        #expect(center.confirmation?.sentence == "open a link to example.com in Notes: \u{201C}https://example.com/docs\u{201D}")
        #expect(center.confirmation?.check == nil)
        // Switching apps while the card waits is the person's doing, not the bot's.
        center.appCameForward("com.apple.finder", at: clock)
        #expect(center.task != nil)
        center.answerConfirmation(false)
        _ = await link.value
        // A picture inside a link, by the driver's own tree, is the link too: no address, no click.
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        let picture = await center.perform(taskID: task.id, ComputerActRequest(kind: .click, app: "Notes", x: 255, y: 15))
        #expect(picture == .failure(.init(message: ComputerActionRules.unknownLink)))
        #expect(!driver.calls.contains { $0.tool == "click" })
        // The person switching apps is fine; an app opening right after the bot acted ends the task.
        center.appCameForward("com.apple.finder", at: Date(timeIntervalSince1970: 0))
        #expect(center.task != nil)
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .scroll, app: "Notes", element: "s00000001:3", direction: "down")).get()
        center.appCameForward("com.apple.finder", at: clock)
        #expect(center.task == nil)
        #expect(center.lastEnd == .otherApp)
    }

    @Test func driverArgumentsNeverReachTheWholeScreen() {
        let element = ComputerCenter.Element(pid: 5, windowID: 9, role: nil, label: nil, frame: nil,
                                             screenshotFrame: CGRect(x: 10, y: 20, width: 40, height: 20))
        let cases: [ComputerActRequest] = [
            .init(kind: .click, app: "A", x: 1, y: 2), .init(kind: .type, app: "A", element: "s00000001:1", text: "x"),
            .init(kind: .key, app: "A", keys: ["cmd", "f"]), .init(kind: .key, app: "A", keys: ["tab"]),
            .init(kind: .scroll, app: "A", direction: "sideways", amount: 500),
        ]
        let tools = cases.compactMap { ComputerCenter.driverArguments($0, pid: 5, element: element, lastWindow: 9) }
        #expect(tools.map(\.0) == ["click", "type_text", "hotkey", "press_key", "scroll"])
        for (_, args) in tools {
            #expect(args.values["pid"] == .int(5))
            #expect(args.values["scope"] == nil)
        }
        #expect(tools[2].1.values["keys"] == .strings(["cmd", "f"]))
        #expect(tools[4].1.values["direction"] == .string("down"))
        #expect(tools[4].1.values["amount"] == .int(20))
    }
}
#endif

#if os(macOS) && NOLLIE_DIRECT
// The broker only listens in the Direct edition; the App Store edition's sandbox has no /tmp for it.
/// The real add-on (Companions/nollie-mac/server.py, as Hermes would run it) talking to the real
/// broker and coordinator, with a recorded driver: the two sides speak the same protocol.
@MainActor
@Suite(.serialized) struct ComputerAddOnTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: ComputerAddOnTests.server.path)))
    func theAddOnReachesNollieAndBackThroughTheBroker() async throws {
        let center = ComputerCenter()
        center.useTestScreen()
        let recorder = ComputerCenterTests.Recorder()
        let driver = ComputerCenterTests.FakeDriver()
        center.presenter = recorder
        center.botName = { _ in "Scout" }
        center.helperAvailable = { true }
        center.permissionsGranted = { true }
        center.personPresent = { true }
        center.resolveApp = { $0 == "Notes" ? ComputerAppInfo(bundleID: "com.apple.Notes", name: "Notes", signer: "apple") : nil }
        center.startHelper = { _ in driver }
        center.verifySession = { _ in .success(ComputerSessionFacts(chat: "career/root", title: "Job hunt", source: "tui", callID: "call-1")) }
        center.otherControl = { nil }
        center.otherControlNow = { nil }
        center.stillPending = { _, _ in true }
        center.isPrivate = { _ in false }
        center.enabled = { true }
        center.usedCalls = ComputerUsedCalls(path: ComputerCenterTests.scratch.appendingPathComponent("used-\(UUID().uuidString).json").path)
        center.runningPID = { _ in 4242 }
        center.inspect = { _, _ in ComputerAction.Target(role: "AXButton", label: "Send", frame: CGRect(x: 1010, y: 510, width: 100, height: 40)) }
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("na-" + UUID().uuidString.prefix(6))
        let path = folder.appendingPathComponent("c.sock").path
        let broker = ComputerBroker()
        broker.start(path: path, center: center)
        defer { broker.stop(path: path); try? FileManager.default.removeItem(at: folder); center.stop() }

        // The person answers every card with a yes, as soon as it shows.
        let answering = Task { @MainActor in
            while !Task.isCancelled {
                if center.approval != nil { center.answerApproval(true) }
                if center.confirmation != nil { center.answerConfirmation(true) }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { answering.cancel() }

        // The model on this Mac: it clicks Send, then says it's done.
        let decider = ComputerScreenTests.Scripted([.click(1), .done("Sent the note.")])
        center.screenDecider = { _ in decider }
        let stamp: [String: Any] = ["session_id": "20261019_200000_abc", "profile": "career", "platform": "api_server"]
        let calls: [[String: Any]] = [
            ["name": "mac_start", "arguments": ["apps": ["Notes"], "task": "Look at Downloads", "_nollie": stamp]],
            ["name": "mac_do", "arguments": ["app": "Notes", "step": "send the note", "_nollie": stamp]],
            ["name": "mac_look", "arguments": ["app": "Notes", "_nollie": stamp]],
            ["name": "mac_do", "arguments": ["app": "Safari", "step": "type x", "_nollie": stamp]],
            ["name": "mac_done", "arguments": ["_nollie": stamp]],
            ["name": "mac_do", "arguments": ["app": "Notes", "step": "look", "_nollie": stamp]],
        ]
        let input = calls.enumerated().map { i, call in
            try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": i + 1, "method": "tools/call", "params": call])
        }.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        let output = try await Self.run(input: input, socket: path)
        let replies = output.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        try #require(replies.count == 6)
        func text(_ i: Int) -> String {
            ((replies[i]["result"] as? [String: Any])?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        }
        func failed(_ i: Int) -> Bool { (replies[i]["result"] as? [String: Any])?["isError"] as? Bool == true }
        #expect(!failed(0) && text(0).contains("Approved for this task: Notes."))
        // One short sentence back: never the picture, never the window's words.
        let step = (replies[1]["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        #expect(step.map { $0["type"] as? String } == ["text"])
        #expect(text(1) == "Done in Notes (1 action): Sent the note.")
        #expect(!text(1).contains("AXButton") && !text(1).contains(ComputerCenterTests.picture.prefix(40)))
        // The picture and the rows went to the model on this Mac only.
        #expect(decider.questions.first?.picture?.base64 == ComputerCenterTests.picture)
        #expect(decider.questions.first?.elements.contains("[1] AXButton \"Send\"") == true)
        #expect(recorder.shown.contains("confirmation"))
        #expect(failed(2))
        #expect(failed(3) && text(3).contains("isn't approved"))
        #expect(!failed(4))
        #expect(failed(5) && text(5).contains("mac_start"))
        #expect(driver.calls.map(\.tool) == ["list_windows", "get_window_state", "click", "list_windows", "get_window_state"])
        #expect(center.task == nil)
        #expect(center.lastEnd == .finished)
    }

    @Test func aRequestThatTakesTooLongIsAnsweredAndALateTaskEnds() async throws {
        let center = ComputerCenter()
        center.useTestScreen()
        let driver = ComputerCenterTests.FakeDriver()
        center.presenter = ComputerCenterTests.Recorder()
        center.botName = { _ in "Scout" }
        center.helperAvailable = { true }
        center.permissionsGranted = { true }
        center.personPresent = { true }
        center.enabled = { true }
        center.isPrivate = { _ in false }
        center.otherControl = { nil }
        center.otherControlNow = { nil }
        center.stillPending = { _, _ in true }
        center.usedCalls = ComputerUsedCalls(path: ComputerCenterTests.scratch.appendingPathComponent("used-\(UUID().uuidString).json").path)
        center.resolveApp = { $0 == "Notes" ? ComputerAppInfo(bundleID: "com.apple.Notes", name: "Notes", signer: "apple") : nil }
        center.startHelper = { _ in driver }
        // Hermes is slow to answer: longer than the broker waits.
        center.verifySession = { _ in
            try? await Task.sleep(for: .milliseconds(600))
            return .success(ComputerSessionFacts(chat: "career/root", title: "Job hunt", source: "tui", callID: UUID().uuidString))
        }
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("nb-" + UUID().uuidString.prefix(6))
        let path = folder.appendingPathComponent("c.sock").path
        let broker = ComputerBroker(requestLimit: 0.3)
        broker.start(path: path, center: center)
        defer { broker.stop(path: path); try? FileManager.default.removeItem(at: folder); center.stop() }
        let answering = Task { @MainActor in
            while !Task.isCancelled {
                if center.approval != nil { center.answerApproval(true) }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { answering.cancel() }
        let line = try JSONSerialization.data(withJSONObject: ["op": "start", "session_id": "s1", "profile": "career", "apps": ["Notes"], "purpose": "p"])
        let reply = try await Self.send(line, to: path)
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["error"] as? String == ComputerBroker.tooLong)
        // The approval that came too late started nothing anyone holds: it ends at once.
        for _ in 0..<300 where center.lastEnd == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(center.task == nil)
        #expect(center.lastEnd == .finished)
    }

    @Test func anActionThatTakesTooLongMayHaveBeenDone() async throws {
        let center = ComputerCenter()
        center.useTestScreen()
        let driver = ComputerCenterTests.FakeDriver()
        center.presenter = ComputerCenterTests.Recorder()
        center.botName = { _ in "Scout" }
        center.helperAvailable = { true }
        center.permissionsGranted = { true }
        center.personPresent = { true }
        center.enabled = { true }
        center.isPrivate = { _ in false }
        center.isWebApp = { _ in false }
        center.otherControl = { nil }
        center.otherControlNow = { nil }
        center.stillPending = { _, _ in true }
        center.usedCalls = ComputerUsedCalls(path: ComputerCenterTests.scratch.appendingPathComponent("used-\(UUID().uuidString).json").path)
        center.resolveApp = { $0 == "Notes" ? ComputerAppInfo(bundleID: "com.apple.Notes", name: "Notes", signer: "apple") : nil }
        center.startHelper = { _ in driver }
        center.runningPID = { _ in 4242 }
        center.inspect = { _, _ in ComputerAction.Target(role: "AXButton", label: "Send", frame: CGRect(x: 1010, y: 510, width: 100, height: 40)) }
        center.verifySession = { _ in .success(ComputerSessionFacts(chat: "career/root", title: "Job hunt", source: "tui", callID: UUID().uuidString)) }
        let starting = Task { await center.requestStart(ComputerStartRequest(sessionID: "s1", profile: "career", apps: ["Notes"], purpose: "p")) }
        for _ in 0..<200 where center.approval == nil { try? await Task.sleep(for: .milliseconds(10)) }
        center.answerApproval(true)
        let task = try await starting.value.get()
        _ = try await center.perform(taskID: task.id, ComputerActRequest(kind: .look, app: "Notes")).get()

        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("nb-" + UUID().uuidString.prefix(6))
        let path = folder.appendingPathComponent("c.sock").path
        let broker = ComputerBroker(requestLimit: 0.3)
        broker.start(path: path, center: center)
        defer { broker.stop(path: path); try? FileManager.default.removeItem(at: folder); center.stop() }
        // "Send" waits for the person, longer than the broker waits: the bot is told it may have happened.
        center.screenDecider = { _ in ComputerScreenTests.Scripted([.click(1), .done("")]) }
        let line = try JSONSerialization.data(withJSONObject: ["op": "do", "task": task.id, "app": "Notes", "step": "send it"])
        let reply = try await Self.send(line, to: path)
        #expect(reply["error"] as? String == ComputerBroker.tooLongMaybeDone)
        // It was waiting on the person's card, not stuck somewhere else.
        for _ in 0..<200 where center.confirmation == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(center.confirmation != nil)
        center.answerConfirmation(false)
        #expect(!driver.calls.contains { $0.tool == "click" })
    }

    /// One JSON line to a socket, one back.
    nonisolated static func send(_ line: Data, to path: String) async throws -> [String: Any] {
        let data = try await Task.detached { () throws -> Data in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (i, b) in Array(path.utf8).enumerated() { raw[i] = b }
            }
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw CocoaError(.fileNoSuchFile) }
            var out = line
            out.append(0x0A)
            _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
            var reply = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !reply.contains(0x0A) {
                let n = read(fd, &chunk, chunk.count)
                guard n > 0 else { break }
                reply.append(chunk, count: n)
            }
            return Data(reply.prefix { $0 != 0x0A })
        }.value
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    nonisolated static var server: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Companions/nollie-mac/server.py")
    }

    /// Runs the add-on as Hermes would (python3 -I server.py, MCP over stdio) and reads its replies.
    nonisolated static func run(input: Data, socket: String) async throws -> Data {
        try await Task.detached { () throws -> Data in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", server.path]
            process.environment = ["NOLLIE_MAC_SOCKET": socket, "PATH": "/usr/bin:/bin"]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            // The server answers one call at a time, in order, as Hermes sends them.
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
            let collected = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return collected
        }.value
    }
}
#endif

#if os(macOS)
extension ComputerCenter {
    /// The checks this Mac's screen needs, answered for tests: Notes and the viewer picked, a model
    /// on this Mac ready, the bot's Allow Mac control on, and the app's window 7 in front.
    func useTestScreen() {
        pickedApps = { ["com.apple.notes", "org.example.viewer"] }
        screenModel = { ComputerScreenModel(base: "http://127.0.0.1:9", key: "k", model: "qwen3.6-35b-a3b-test") }
        macControlOn = { _ in true }
        screenWindows = { [ComputerScreenWindow(id: 7, pid: 4242, layer: 0, bounds: CGRect(x: 1000, y: 500, width: 600, height: 420))] }
        frontmostPID = { 4242 }
        screenScale = { 2 }
        recordSession = { _ in }
    }
}
#endif
