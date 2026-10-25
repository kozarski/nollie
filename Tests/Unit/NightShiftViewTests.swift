import Foundation
import SwiftUI
import Testing
@testable import Nollie
@testable import NollieCore

// The night shift and rehearsal cards on the new chat view: their words, the runs the person opens, and the picture
// made to share, which must never hold a personal word. See Docs/specs/night-shift.md.

/// A night with personal details in its titles and targets, beside plain ones.
func nightShiftSample(now: Date = Date(timeIntervalSince1970: 1_792_562_400)) -> ConversationPost {
    let started = now.addingTimeInterval(-4 * 3600)
    let brief = ConversationPost.Run(
        id: "cron:244c3b0b8e42:e-80", bot: "default", botName: "Nollie", title: "Morning brief for sam@example.com",
        outcome: .done, startedAt: started, finishedAt: started.addingTimeInterval(68),
        actions: [
            .init(tool: "terminal", target: "df -h", status: .done, receipt: .init(kind: .safe)),
            .init(tool: "write_file", target: "/Users/sam/Documents/taxes-2026.pdf", status: .done, receipt: .init(kind: .tool)),
            .init(tool: "terminal", target: "git push origin main", status: .done,
                  receipt: .init(kind: .always, detail: "git push", grantedAt: now.addingTimeInterval(-9 * 86_400))),
            .init(tool: "terminal", target: "ssh 192.168.1.30 'tail ~/logs/app.log'", status: .failed, receipt: .init(kind: .allowlist, detail: "ssh")),
            .init(tool: "web_extract", target: "news.example.com/item/42", status: .done, receipt: .init(kind: .tool)),
            .init(tool: "web_extract", target: "mybank.com", status: .done, receipt: .init(kind: .tool)),
            .init(tool: "browser_navigate", target: "portfolio-of-sam.net.", status: .done, receipt: .init(kind: .tool)),
        ])
    let export = ConversationPost.Run(
        id: "cron:export:e-41", bot: "career", botName: "Scout", title: "Call +1 (555) 123-4567 about order 99887766",
        outcome: .done, startedAt: started.addingTimeInterval(7200),
        actions: [
            .init(tool: "computer_use", target: "screenshot", status: .blocked, receipt: .init(kind: .blocked, detail: "mac")),
            .init(tool: "send_message", target: "token [hidden] to https://hooks.example.com/a?b=1", status: .done, receipt: nil),
        ])
    let night = ConversationPost.NightShift(from: now.addingTimeInterval(-12 * 3600), to: now,
                                            counts: .init(runs: 2, actions: 9, stopped: 1), runs: [brief, export])
    return ConversationPost(id: "night-2026-10-21", at: now, kind: .nightShift(night))
}

func rehearsalSample(state: ConversationPost.Rehearsal.State? = .ready, check: ConversationPost.Check? = nil,
                     pending: ConversationPostAction? = nil, problem: String? = nil) -> ConversationPost {
    ConversationPost(id: "rehearsal-career-3f2a9c-e-81", at: Date(timeIntervalSince1970: 1_792_561_000), kind: .rehearsal(.init(
        bot: "career", botName: "Scout", jobId: "3f2a9c", title: "Morning prices", schedule: "0 7 * * 1-5", state: state,
        check: check, outcome: .done,
        held: check == nil ? [.init(tool: "send_message", target: "Price drop on the SSD")] : [],
        looked: check == nil ? [.init(tool: "web_search", target: "2TB NVMe price"), .init(tool: "read_file", target: "notes/prices.md")] : [],
        reply: check == nil ? "The 2TB drive is down to 119. I would have sent you a note about it." : "")),
        pending: pending, problem: problem)
}

@MainActor @Suite struct NightShiftSkyTests {
    @Test func starsStayInPlaceWithDifferentSizesAndBrightnesses() {
        let stars = NightShiftSky.stars
        #expect(stars == NightShiftSky.makeStars())
        #expect(NightShiftSky.makeStars(seed: 42) == NightShiftSky.makeStars(seed: 42))
        #expect(NightShiftSky.makeStars(seed: 42) != NightShiftSky.makeStars(seed: 43))
        #expect(!stars.isEmpty)
        #expect(stars.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y)
            && $0.size > 0 && $0.size <= 3 && $0.opacity > 0 && $0.opacity <= 1 })
        #expect(Set(stars.map(\.size)).count > 1)
        #expect(Set(stars.map(\.opacity)).count > 1)
    }

    @Test func theSkyAndItsWordsStayNightInEitherAppearance() {
        var light = EnvironmentValues(), dark = EnvironmentValues()
        light.colorScheme = .light
        dark.colorScheme = .dark
        let colors = [NightShiftInk.top, NightShiftInk.middle, NightShiftInk.bottom, NightShiftInk.horizon,
                      NightShiftInk.solid, NightShiftInk.text, NightShiftInk.detail, NightShiftInk.warning,
                      NightShiftInk.moon, NightShiftInk.control]
        #expect(colors.map { $0.resolve(in: light) } == colors.map { $0.resolve(in: dark) })
    }

    @Test func wordsStayReadableOverTheHorizonAndStars() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let top = NightShiftInk.top.resolve(in: environment)
            let middle = NightShiftInk.middle.resolve(in: environment)
            let bottom = NightShiftInk.bottom.resolve(in: environment)
            let horizon = NightShiftInk.horizon.resolve(in: environment)
            let star = NightShiftInk.detail.resolve(in: environment)
            func sky(at y: Double) -> Color.Resolved {
                let gradient = y < 0.5 ? blend(top, middle, amount: y * 2)
                    : blend(middle, bottom, amount: (y - 0.5) * 2)
                // The full glow at every height is brighter than the actual fading horizon.
                return blend(gradient, horizon, amount: NightShiftSky.horizonOpacity)
            }
            var backgrounds = (0...100).map { sky(at: Double($0) / 100) }
            backgrounds += NightShiftSky.stars.map { blend(sky(at: $0.y), star, amount: $0.opacity) }
            backgrounds += [NightShiftInk.solid.resolve(in: environment), NightShiftInk.control.resolve(in: environment)]
            for color in [NightShiftInk.text, NightShiftInk.detail, NightShiftInk.warning] {
                let words = luminance(color.resolve(in: environment))
                for background in backgrounds {
                    let surface = luminance(background)
                    let contrast = (max(words, surface) + 0.05) / (min(words, surface) + 0.05)
                    #expect(contrast >= 4.5, "Night shift words need 4.5:1 contrast")
                }
            }
        }
    }

    private func blend(_ background: Color.Resolved, _ foreground: Color.Resolved, amount: Double) -> Color.Resolved {
        let t = Float(amount)
        return .init(red: background.red * (1 - t) + foreground.red * t,
                     green: background.green * (1 - t) + foreground.green * t,
                     blue: background.blue * (1 - t) + foreground.blue * t)
    }

    private func luminance(_ color: Color.Resolved) -> Double {
        0.2126 * Double(color.linearRed) + 0.7152 * Double(color.linearGreen) + 0.0722 * Double(color.linearBlue)
    }
}

@Suite struct NightShiftSharePictureTests {
    private let personal = ["sam@example.com", "/Users/sam", "taxes-2026", "192.168.1.30", "~/logs", "app.log",
                            "news.example.com", "item/42", "555", "123-4567", "99887766", "[hidden]", "hooks.example.com", "b=1",
                            "mybank", "portfolio-of-sam"]

    @Test func noPersonalWordSurvivesInThePicture() throws {
        let card = try #require(nightShiftSample().nightShift)
        let model = NightShiftShareModel(card)
        let words = model.words.joined(separator: "\n")
        for token in personal {
            #expect(!words.contains(token), "\(token) is in the picture")
        }
        // Every target and title the card had is in the picture, at the same length, with its parts in marks.
        let targets = card.runs.flatMap(\.actions).map(\.target)
        let drawn = model.runs.flatMap(\.actions).map { $0.target.map(\.text).joined() }
        #expect(drawn.map(\.count) == targets.map(\.count))
        #expect(model.runs.map { $0.title.map(\.text).joined().count } == card.runs.map { NightShiftWords.title(of: $0).count })
        for piece in model.runs.flatMap({ $0.actions.flatMap(\.target) + $0.title }) where piece.hidden {
            #expect(piece.text.allSatisfy { $0 == NightShiftShareModel.mark }, "\(piece.text)")
        }
    }

    @Test func botNamesReceiptsAndPlainTargetsStayClear() throws {
        let model = NightShiftShareModel(try #require(nightShiftSample().nightShift))
        #expect(model.runs[0].actions[0].target == [.init(text: "df -h", hidden: false)])
        #expect(model.runs[0].actions[2].target == [.init(text: "git push origin main", hidden: false)])
        #expect(model.runs[0].line.hasPrefix("Nollie · Done · "))
        #expect(model.runs[1].line.hasPrefix("Scout · Done · "))
        #expect(model.runs[0].actions.map(\.receipt).prefix(3) == ["Not a risky command", "Part of this schedule's tools",
                                                                   model.runs[0].actions[2].receipt])
        #expect(model.runs[0].actions[2].receipt.hasPrefix("You chose Always for this on "))
        #expect(model.runs[1].actions[0].receipt == "Stopped: schedules never use your Mac's screen")
        #expect(model.counts == "2 runs · 9 actions · 1 stopped")
        // The plain parts of a target that has a personal part stay readable around the marks.
        #expect(model.runs[1].actions[1].target.first == .init(text: "token ", hidden: false))
    }

    @Test func aPageToolsTargetIsHiddenWhole() throws {
        let model = NightShiftShareModel(try #require(nightShiftSample().nightShift))
        let pages = model.runs[0].actions.filter { $0.verb == "Looked at" || $0.verb == "Browsed" }.map(\.target)
        #expect(pages.count == 3)
        for target in pages {
            #expect(target.count == 1 && target[0].hidden, "\(target)")
        }
        // Other tools keep their plain words around the marks.
        #expect(NightShiftShareModel.target(of: .init(tool: "terminal", target: "curl mybank.com")).first == .init(text: "curl ", hidden: false))
    }

    @Test func aHeldActionSharesOnlyItsFirstLine() {
        let held = ConversationPost.Action(tool: "mcp__gmail__send_email",
                                           target: "Send with gmail: send email\nto: sam@example.com\nbody: Lunch on Friday?",
                                           status: .blocked, receipt: .init(kind: .held, detail: "ask_first"))
        let words = NightShiftShareModel.target(of: held).map(\.text).joined()
        #expect(words == "Send with gmail: send email")
        #expect(!words.contains("Lunch"))
    }

    @Test func theFacesAreDrawnNeverPhotos() {
        #expect(NightShiftShareView.face("default").photos == false)
        #expect(NightShiftShareView.face("default").animated == false)
    }

    @MainActor
    @Test func aBotWithoutPhotosDrawsItsFaceOverAChosenPhoto() throws {
        let profile = "sharephoto\(UUID().uuidString.prefix(8))"
        defer { if let url = BotAvatarStore.photoURL(for: profile) { try? FileManager.default.removeItem(at: url) } }
        func png(photos: Bool) throws -> Data {
            let renderer = ImageRenderer(content: BotAvatar(profile: profile, size: 30, override: .photo, animated: false, photos: photos))
            renderer.scale = 2
            return try #require(renderer.uiImage?.pngData())
        }
        let face = try png(photos: false)
        let red = ImageRenderer(content: Color.red.frame(width: 40, height: 40))
        try BotAvatarStore.savePhoto(try #require(red.uiImage?.pngData()), for: profile)
        #expect(BotAvatarStore.photo(for: profile) != nil)
        #expect(try png(photos: true) != face, "the chat shows the photo")
        #expect(try png(photos: false) == face, "the picture to share draws the face")
    }

    @Test func aBusyNightSaysHowManyRunsAreNotListed() {
        let run = ConversationPost.Run(id: "r", bot: "default", botName: "Nollie", title: "Busy")
        let model = NightShiftShareModel(.init(counts: .init(runs: 101, actions: 1), runs: [run], moreRuns: 100))
        #expect(model.moreRuns == "100 more runs not listed")
        #expect(model.words.contains("100 more runs not listed"))
        #expect(NightShiftShareModel(.init(counts: .init(runs: 1), runs: [run])).moreRuns == nil)
        #expect(NightShiftWords.moreRuns(1) == "1 more run not listed")
    }

    @Test func aLongRunIsCutWithACount() {
        let actions = (0..<12).map { ConversationPost.Action(tool: "terminal", target: "echo \($0)", status: .done, receipt: .init(kind: .safe)) }
        let run = ConversationPost.Run(id: "r", bot: "default", botName: "Nollie", title: "Busy", actions: actions, more: 30)
        let model = NightShiftShareModel(.init(counts: .init(runs: 1, actions: 42), runs: [run]))
        #expect(model.runs[0].actions.count == NightShiftShareModel.actionsPerRun)
        #expect(model.runs[0].more == 12 - NightShiftShareModel.actionsPerRun + 30)
    }
}

@Suite struct NightShiftWordsTests {
    @Test func countsSayWhatHappenedOrAQuietNight() {
        #expect(NightShiftWords.counts(.init(runs: 2, actions: 5, stopped: 1)) == "2 runs · 5 actions · 1 stopped")
        #expect(NightShiftWords.counts(.init(runs: 1, actions: 1, held: 2, unrecorded: 3)) == "1 run · 1 action · 2 held · 3 not recorded")
        #expect(NightShiftWords.counts(.init()) == "Quiet night. Nothing ran.")
    }

    @Test func aStoppedActionNeverReadsAsDone() {
        let blocked = ConversationPost.Action(tool: "computer_use", target: "click", status: .blocked, receipt: .init(kind: .blocked, detail: "mac"))
        let run = ConversationPost.Run(id: "r", bot: "default", botName: "Nollie", title: "")
        #expect(NightShiftWords.verb(blocked) == "Tried to use the screen for")
        #expect(NightShiftWords.sentence(verb: NightShiftWords.verb(blocked), target: blocked.target,
                                         receipt: NightShiftWords.receipt(blocked, in: run))
                == "Tried to use the screen for click. Stopped: schedules never use your Mac's screen.")
        // Without a target the verb stands alone.
        #expect(NightShiftWords.verb(.init(tool: "computer_use", status: .blocked)) == "Tried to use the screen")
        #expect(NightShiftWords.receipt(blocked, in: run) == "Stopped: schedules never use your Mac's screen")
        let command = ConversationPost.Action(tool: "terminal", target: "rm -rf build", status: .blocked, receipt: .init(kind: .blocked, detail: "risky"))
        #expect(NightShiftWords.verb(command) == "Tried to run")
        #expect(NightShiftWords.sentence(verb: NightShiftWords.verb(command), target: command.target,
                                         receipt: NightShiftWords.receipt(command, in: run))
                == "Tried to run rm -rf build. Stopped: a risky command needs your OK.")
    }

    @Test func anAskFirstHoldSaysItNeedsYourYes() {
        let run = ConversationPost.Run(id: "r", bot: "default", botName: "Nollie", title: "")
        let send = ConversationPost.Action(tool: "send_message", target: "Send with gmail: send email", status: .blocked,
                                           receipt: .init(kind: .held, detail: "ask_first"))
        #expect(NightShiftWords.receipt(send, in: run) == "Held: needs your yes")
        #expect(NightShiftWords.receipt(.init(tool: "send_message", status: .blocked, receipt: .init(kind: .held)), in: run) == "Held for you")
        // Its target already starts with its own verb: no "Tried to send" in front of it.
        #expect(NightShiftWords.verb(send) == "")
        #expect(NightShiftWords.sentence(verb: NightShiftWords.verb(send), target: send.target, receipt: NightShiftWords.receipt(send, in: run))
                == "Send with gmail: send email. Held: needs your yes.")
        let command = ConversationPost.Action(tool: "terminal", target: "Run this command:\nrm -rf build", status: .blocked,
                                              receipt: .init(kind: .held, detail: "ask_first"))
        #expect(NightShiftWords.verb(command) == "")
        #expect(NightShiftWords.heldByAskFirst(command))
        // An older hold, and a hold with nothing to show, keep their verb.
        #expect(NightShiftWords.verb(.init(tool: "send_message", target: "hi", status: .blocked, receipt: .init(kind: .held))) == "Tried to send")
        #expect(NightShiftWords.verb(.init(tool: "send_message", status: .blocked, receipt: .init(kind: .held, detail: "ask_first"))) == "Tried to send")
        let stopped = ConversationPost.Action(tool: "terminal", status: .blocked,
                                              receipt: ConversationPost.Receipt(kind: .blocked, detail: "ask_first"))
        #expect(stopped.receipt?.kind == .blocked)
        #expect(NightShiftWords.heldByAskFirst(stopped) == false)
        // A rehearsal says it will ask each time, even once the schedule is on.
        #expect(RehearsalCard.everyTime == "Needs your yes each time")
    }

    @Test func verbsFollowTheTool() {
        #expect(NightShiftWords.verbs("terminal") == ("Ran", "Run"))
        #expect(NightShiftWords.verbs("write_file") == ("Wrote", "Write"))
        #expect(NightShiftWords.verbs("web_search").0 == "Searched")
        #expect(NightShiftWords.verbs("read_file").0 == "Looked at")
        #expect(NightShiftWords.verbs("mcp__nollie_mac__click").0 == "Used the screen")
        #expect(NightShiftWords.verbs("computer_use", target: "screenshot") == ("Used the screen for", "Use the screen for"))
        #expect(NightShiftWords.verbs("terminal", target: "df -h") == ("Ran", "Run"))
        #expect(NightShiftWords.verbs("kanban_create").0 == "Used kanban create")
    }

    @Test func aReceiptNeverClaimsMoreThanItKnows() {
        let run = ConversationPost.Run(id: "r", kind: "board", bot: "default", botName: "Nollie", title: "")
        #expect(NightShiftWords.receipt(.init(tool: "kanban_complete", status: .done, receipt: .init(kind: .tool)), in: run) == "Part of this task's tools")
        #expect(NightShiftWords.receipt(.init(tool: "terminal", status: .done, receipt: nil), in: run) == "Allowed. Reason not recorded")
        #expect(NightShiftWords.receipt(.init(tool: "terminal", status: .failed, receipt: .init(kind: .safe)), in: run) == "Not a risky command · It failed")
        #expect(NightShiftWords.title(of: run) == "Board task")
    }

    @Test func theWindowSaysWhenItStarted() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(bySettingHour: 7, minute: 30, second: 0, of: Date()))
        #expect(NightShiftWords.since(now.addingTimeInterval(-3600), now: now).hasPrefix("Since "))
        #expect(!NightShiftWords.since(now.addingTimeInterval(-3600), now: now).hasSuffix("yesterday"))
        #expect(NightShiftWords.since(now.addingTimeInterval(-12 * 3600), now: now).hasSuffix(" yesterday"))
        #expect(!NightShiftWords.since(now.addingTimeInterval(-3 * 86_400), now: now).contains("yesterday"))
    }
}

extension ConversationListItemsTests {
    @Test func aRunOpenedOnACardChangesItsItem() {
        let post = nightShiftSample()
        let rows = [ConversationRow(id: "u", kind: .user(text: "hi", delivery: .sent)), ConversationRow(id: "post:\(post.id)", kind: .post(post))]
        let closed = ConversationListItem.make(transcript: rows, cards: [], activity: nil, atNewestEnd: true)
        let run = "cron:244c3b0b8e42:e-80"
        let open = ConversationListItem.make(transcript: rows, cards: [], activity: nil, atNewestEnd: true,
                                             expanded: [ConversationListItem.expandedKey(post: post.id, run: run),
                                                        ConversationListItem.expandedKey(post: "another", run: "cron:export:e-41")])
        #expect(open[1] == .post(rows[1], expanded: [run]), "only this post's runs, by run id")
        #expect(open[1].row == rows[1] && open[1].kind == "nightShift")
        let change = ConversationListChange(from: closed, to: open)
        #expect(change.sameOrder && change.changed == ["post:\(post.id)"], "the card is drawn and measured again")
        // A post is not one of your messages: the next message of yours starts a turn.
        let after = ConversationListItem.make(transcript: rows + [ConversationRow(id: "u2", kind: .user(text: "ok", delivery: .sent))],
                                              cards: [], activity: nil, atNewestEnd: true)
        #expect(after[2] == .row(ConversationRow(id: "u2", kind: .user(text: "ok", delivery: .sent)), startsTurn: true))
    }
}
