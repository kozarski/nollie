import Foundation

/// What the demo starts with: four bots and a few chats, all made up for this. Every fact in a
/// chat comes from what the demo person says in it; the bots never claim anything they could not
/// know. Nothing here is real data, and none of it is read from the device or a gateway.
enum DemoSeed {
    struct Bot: Sendable {
        var name: String
        var display: String
        var about: String
        var main: String
    }

    /// One message in a stored chat. A tool step has a `name` and a short `context`.
    struct Row: Sendable {
        var id: Int
        var role: String
        var text: String
        var at: Double
        var name: String? = nil
        var context: String? = nil
        var args: JSONValue? = nil
    }

    struct Chat: Sendable {
        var id: String
        var profile: String
        var title: String
        var source = "ios"
        var startedAt: Double
        var lastActive: Double
        var pinned = false
        var archived = false
        var cwd = "/home/demo"
        var rows: [Row]
    }

    static let bots: [Bot] = [
        Bot(name: "default", display: "Nollie", about: "Your everyday helper", main: "demo-nollie-main"),
        Bot(name: "scout", display: "Scout", about: "Looks things up and compares them", main: "demo-scout-main"),
        Bot(name: "mason", display: "Mason", about: "Keeps small jobs moving", main: "demo-mason-main"),
        Bot(name: "wren", display: "Wren", about: "Plans days and keeps notes", main: "demo-wren-main"),
    ]

    static let model = "demo/assistant"
    static let provider = "demo"

    /// The approval Mason is waiting on when the demo opens.
    static let heldNote = "Hi Sam, I can meet at 10 on Thursday. See you then."

    static func chats(now: Double) -> [Chat] {
        let hour = 3600.0
        func rows(_ start: Double, _ items: [(String, String)], steps: [Int: (String, String)] = [:]) -> [Row] {
            var made: [Row] = []
            var clock = start
            for (index, item) in items.enumerated() {
                if let step = steps[index] {
                    made.append(Row(id: made.count + 1, role: "tool", text: "", at: clock, name: step.0, context: step.1))
                    clock += 4
                }
                made.append(Row(id: made.count + 1, role: item.0, text: item.1, at: clock))
                clock += 40
            }
            return made
        }

        let weekend = rows(now - 5 * hour, [
            ("user", "Can you help me find something fun to do this weekend? We're near Bath, it should rain on Sunday, and we have a dog."),
            ("assistant", """
            Happy to. Here is a simple shape for it.

            **Saturday (dry)**
            - A long dog walk in the morning
            - Lunch somewhere with outdoor seating

            **Sunday (rain)**
            - A museum or gallery that lets dogs in
            - A cosy pub afternoon

            Want me to look for specific places and keep the best three in a list?
            """),
            ("user", "Yes please, and keep it under £40 for the two of us."),
            ("assistant", "Will do. I'll keep the whole day under £40 and put the three best ideas here."),
        ], steps: [1: ("web_search", "things to do near Bath with a dog")])

        let gifts = rows(now - 30 * hour, [
            ("user", "I need a gift idea for my mum. She loves gardening and I can spend about £30."),
            ("assistant", """
            A few ideas around £30 for a keen gardener:

            - A good pair of pruning snips
            - A kneeling pad and gloves set
            - A pot of something she can grow on a windowsill

            I can compare a few shops for the snips if you like.
            """),
        ])

        let vacuums = rows(now - 3 * hour, [
            ("user", "I'm choosing between the Aero 5 (£249, 78 dB) and the Dustpro 300 (£259, 71 dB). We have two cats. Which should I get?"),
            ("assistant", """
            From what you told me, I'd lean towards the Dustpro 300. It's £10 more, and it's quieter at 71 dB against 78 dB, which matters if the cats dislike the noise.

            Pet hair is the bigger question, and I'd want to look at how each brush is made before saying more. Shall I read the product pages and come back with that?
            """),
        ], steps: [1: ("web_search", "Aero 5 and Dustpro 300 pet hair")])

        // The note for Sam is not here: Mason is in the middle of it, waiting for a yes.
        let sam = rows(now - 2 * hour, [
            ("user", "Hi Mason, can you help with a couple of small jobs this week?"),
            ("assistant", "Of course. Tell me what needs doing and I'll keep track of it."),
        ])

        let plan = rows(now - 2 * hour, [
            ("user", "Plan my day. I've got a call at 10, a dentist appointment at 3, and I want to fit in a run before dinner."),
            ("assistant", """
            Here is a shape for it:

            - **9:30** Get ready for your call
            - **10:00** Call
            - **11:00 to 2:30** Quiet time for your own work, with lunch in the middle
            - **3:00** Dentist
            - **5:30** Run, so you're back and showered before dinner

            Want a reminder for the call and the dentist?
            """),
        ])

        return [
            Chat(id: "demo-nollie-main", profile: "default", title: "Weekend plans", startedAt: now - 5 * hour, lastActive: now - 5 * hour + 130, rows: weekend),
            Chat(id: "demo-nollie-gifts", profile: "default", title: "A gift for Mum", startedAt: now - 30 * hour, lastActive: now - 30 * hour + 50, rows: gifts),
            Chat(id: "demo-scout-main", profile: "scout", title: "Aero 5 or Dustpro 300", startedAt: now - 3 * hour, lastActive: now - 3 * hour + 50, rows: vacuums),
            Chat(id: "demo-mason-main", profile: "mason", title: "Small jobs", startedAt: now - 2 * hour, lastActive: now - 2 * hour + 50, rows: sam),
            Chat(id: "demo-wren-main", profile: "wren", title: "Plan my day", startedAt: now - 2 * hour, lastActive: now - 2 * hour + 50, rows: plan),
        ]
    }
}
