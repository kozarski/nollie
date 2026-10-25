import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

@MainActor
@Suite struct HelperComputerTests {
    private func status(_ state: HelperComputerStatus.State = .off, on: Bool = false, setup: HelperComputerStatus.Setup = .ready,
                        hasComputer: Bool = false, busy: Bool = false, message: String? = nil) -> HelperComputerStatus {
        HelperComputerStatus(profile: "work", on: on, state: state, setup: setup, computerName: on || hasComputer ? "nollie-work" : nil,
                             hasComputer: hasComputer, busy: busy, message: message)
    }

    private func screen(_ status: HelperComputerStatus?, wantsOn: Bool = false, onMac: Bool = true,
                        run: HelperComputerSetupRun = .idle, working: Bool = false, error: String? = nil) -> HelperComputerScreen {
        HelperComputerPresentation.screen(status: status, error: error, wantsOn: wantsOn, onMac: onMac, run: run, working: working, name: "Scout")
    }

    @Test func theAddOnsAnswerDecodes() throws {
        let data = Data(#"{"profile":"work","on":true,"state":"getting_ready","setup":"ready","cua_version":"0.5.0","computer_name":"nollie-work","has_computer":true,"busy":true,"message":null,"step":"computer"}"#.utf8)
        let decoded = try JSONCoding.decoder.decode(HelperComputerStatus.self, from: data)
        #expect(decoded == HelperComputerStatus(profile: "work", on: true, state: .gettingReady, setup: .ready, cuaVersion: "0.5.0",
                                                computerName: "nollie-work", hasComputer: true, busy: true))
        for setup in ["no_cua", "old_cua", "cua_not_running", "no_runtime"] {
            let text = #"{"profile":"work","on":false,"state":"off","setup":"\#(setup)","has_computer":false,"busy":false}"#
            #expect(try JSONCoding.decoder.decode(HelperComputerStatus.self, from: Data(text.utf8)).setup.rawValue == setup)
        }
    }

    @Test func offByDefaultAndRemoveOnlyWhenAComputerIsLeft() {
        #expect(screen(status()) == .off(hasComputer: false, busy: false))
        #expect(screen(status(hasComputer: true)) == .off(hasComputer: true, busy: false))
        #expect(screen(status(.removing, hasComputer: true, busy: true)) == .off(hasComputer: true, busy: true))
        #expect(!HelperComputerPresentation.switchIsOn(status(), wantsOn: false))
        #expect(screen(nil) == .loading)
        #expect(screen(nil, error: "This needs Nollie's computer add-on on your Mac.") == .unavailable("This needs Nollie's computer add-on on your Mac."))
    }

    @Test func turningOnWithoutCuaGuidesOneStepAtATime() {
        guard case .setup(let mac) = screen(status(setup: .noCua), wantsOn: true) else { Issue.record("no guided step"); return }
        #expect(mac.line == "Your helpers' computers come from Cua, a free tool. Nollie can set it up for you.")
        #expect(mac.action == .setUp)
        #expect(mac.secondary == .notNow)
        guard case .setup(let phone) = screen(status(setup: .noCua), wantsOn: true, onMac: false) else { Issue.record("no phone step"); return }
        #expect(phone.action == nil)
        #expect(phone.line.contains("Open Nollie on your Mac"))
        #expect(HelperComputerPresentation.switchIsOn(status(setup: .noCua), wantsOn: true))
    }

    @Test func eachMissingPieceHasItsOwnPlainStep() {
        let expected: [(HelperComputerStatus.Setup, HelperComputerAction)] = [(.oldCua, .update), (.cuaNotRunning, .startCua), (.noRuntime, .finish)]
        for (setup, action) in expected {
            guard case .setup(let prompt) = screen(status(setup: setup), wantsOn: true) else { Issue.record("\(setup)"); continue }
            #expect(prompt.action == action)
        }
    }

    @Test func automaticSetupShowsProgressThenFallsBackPlainly() {
        #expect(screen(status(setup: .noCua), wantsOn: true, run: .working(.downloading, fraction: 0.4))
                == .settingUp(title: "Downloading Cua", fraction: 0.4))
        guard case .setup(let failed) = screen(status(setup: .noCua), wantsOn: true, run: .failed("The download didn't finish.")) else {
            Issue.record("no fallback"); return
        }
        #expect(failed.line.hasPrefix("The download didn't finish."))
        #expect(failed.action == .getCua)
        #expect(failed.secondary == .tryAgain)
        guard case .setup(let quit) = screen(status(setup: .oldCua), wantsOn: true, run: .needsQuit) else { Issue.record("no quit"); return }
        #expect(quit.action == .quitCua)
        guard case .setup(let manual) = screen(status(setup: .noCua), wantsOn: true, run: .unavailable) else { Issue.record("no manual"); return }
        #expect(manual.action == .getCua)
    }

    @Test func gettingReadyThenTheCardInPlainWords() {
        #expect(screen(status(.gettingReady, on: true, busy: true)) == .gettingReady("Getting Scout's computer ready. The first time takes a few minutes."))
        #expect(screen(status(setup: .ready), wantsOn: true) == .gettingReady("Getting Scout's computer ready. The first time takes a few minutes."))
        #expect(screen(status(.ready, on: true)) == .card(.ready, note: nil))
        #expect(screen(status(.ready, on: true), working: true) == .card(.working, note: nil))
        #expect(screen(status(.asleep, on: true)) == .card(.asleep, note: nil))
        guard case .card(.needsYou, let note) = screen(status(.needsYou, on: true, message: "Its computer is missing.")) else {
            Issue.record("no needs-you card"); return
        }
        #expect(note?.line == "Its computer is missing.")
        guard case .card(.needsYou, let fix) = screen(status(.needsYou, on: true, setup: .cuaNotRunning, message: "Cua isn't running on your Mac.")) else {
            Issue.record("no fix"); return
        }
        #expect(fix?.action == .startCua)
    }

    @Test func turningOffShowsTheSwitchOffAtOnce() {
        #expect(!HelperComputerPresentation.switchIsOn(status(.turningOff, on: true, busy: true), wantsOn: false))
        #expect(HelperComputerPresentation.switchIsOn(status(.ready, on: true), wantsOn: false))
    }

    @Test func noVisibleWordsUseJargonOrEmDashes() {
        var lines = [HelperComputerPresentation.title, HelperComputerPresentation.line, HelperComputerPresentation.gettingReady("Scout")]
        for setup in [HelperComputerStatus.Setup.noCua, .oldCua, .cuaNotRunning, .noRuntime] {
            for onMac in [true, false] { lines.append(HelperComputerPresentation.prompt(for: setup, onMac: onMac)?.line ?? "") }
        }
        lines += [HelperComputerAction.setUp, .update, .startCua, .finish, .getCua, .tryAgain, .quitCua, .notNow].map(\.title)
        lines += [HelperComputerSetupRun.Step.checking, .downloading, .installing, .starting, .preparing].map(\.title)
        for line in lines {
            #expect(!line.contains("\u{2014}"))
            for word in ["Space", "VM", "backend", "plugin", "Docker", "sandbox"] {
                #expect(!line.contains(word), "\(line)")
            }
        }
    }

    @Test func workingMeansACommandIsRunningOnItsComputer() {
        let prompt = TranscriptItem(id: "p", kind: .user(text: "Build it", attachments: []))
        func tool(_ name: String, _ status: ToolActivity.Status = .running) -> TranscriptItem {
            TranscriptItem(id: UUID().uuidString, kind: .tool(ToolActivity(id: UUID().uuidString, name: name, argsText: nil, status: status, resultText: nil)))
        }
        #expect(BotComputerActivity.usesOwnComputer(in: [prompt, tool("terminal")], isRunning: true))
        #expect(BotComputerActivity.usesOwnComputer(in: [prompt, tool("write_file")], isRunning: true))
        #expect(!BotComputerActivity.usesOwnComputer(in: [prompt, tool("terminal", .done)], isRunning: true))
        #expect(!BotComputerActivity.usesOwnComputer(in: [prompt, tool("web_search")], isRunning: true))
        #expect(!BotComputerActivity.usesOwnComputer(in: [prompt, tool("terminal")], isRunning: false))
        #expect(!BotComputerActivity.usesOwnComputer(in: [tool("terminal"), prompt], isRunning: true))
    }

    @Test func addOnRefusalsAreShownInItsOwnWords() {
        #expect(HelperComputerModel.plain(" Turn its computer off first. ") == "Turn its computer off first.")
        #expect(HelperComputerModel.plain("") == "That didn't work. Try again in a moment.")
    }

    #if os(macOS)
    @Test func theHelpersSetupPhasesMapToSteps() {
        #expect(CuaSetup.map(NollieCuaSetupResponse(phase: .downloading, fraction: 0.25)) == .working(.downloading, fraction: 0.25))
        #expect(CuaSetup.map(NollieCuaSetupResponse(phase: .preparing)) == .working(.preparing, fraction: nil))
        #expect(CuaSetup.map(NollieCuaSetupResponse(phase: .needsQuit)) == .needsQuit)
        #expect(CuaSetup.map(NollieCuaSetupResponse(phase: .failed, failure: "Couldn't put Cua in Applications.")) == .failed("Couldn't put Cua in Applications."))
        #expect(CuaSetup.map(NollieCuaSetupResponse(phase: .failed)) == .failed("Couldn't set up Cua by itself."))
        #expect(CuaSetup.map(NollieCuaSetupResponse(phase: .unavailable)) == .unavailable)
        #expect(CuaSetup.map(NollieCuaSetupResponse(phase: .done)) == .done)
    }

    @Test func withoutTheSetupServiceTheManualPathShows() async {
        let setup = CuaSetup()
        setup.isAvailable = true
        setup.request = { _ in throw ManagedRuntimeFailure.disconnected }
        await setup.start()
        #expect(setup.run == .unavailable)
    }
    #endif
}
