import Foundation

/// The notes themselves, newest first. One per release that changes something a person would notice.
/// Only what the version really does, in plain words; where something moved, say where it went.
extension WhatsNew {
    static var notes: [WhatsNewNote] {
        [
            WhatsNewNote(
                version: "1.3.3",
                lead: String(localized: "A small tidy-up this time. Here's what changed, and where to find it.",
                             comment: "What's new, 1.3.3: the opening line"),
                items: [
                    .init(id: "watch-board", symbol: "applewatch",
                          title: String(localized: "Board tasks on your wrist", comment: "What's new, 1.3.3"),
                          line: String(localized: "When a task needs your help, your Apple Watch now shows it.", comment: "What's new, 1.3.3"),
                          place: String(localized: "Apple Watch · below your crew", comment: "What's new, 1.3.3: where to find it"),
                          more: String(localized: "Open Nollie on your Watch and scroll down past your crew. You'll see each task that's waiting, and the helper holding it. To answer one, open the Board on your iPhone.",
                                       comment: "What's new, 1.3.3: the detail")),
                    .init(id: "on-your-mac", symbol: "macbook.and.iphone",
                          title: String(localized: "Clearer about what stays on your Mac", comment: "What's new, 1.3.3"),
                          line: String(localized: "Your iPhone now tells you when something is changed on your Mac.", comment: "What's new, 1.3.3"),
                          place: String(localized: "Schedules · Apps & access", comment: "What's new, 1.3.3: where to find it"),
                          more: String(localized: "An iPhone linked to your Mac can pause, run or delete a schedule. Editing one, and choosing what a helper may use, happen on your Mac. Those controls used to look ready and then not work. Now they're greyed, with a note saying why. To add a schedule from your iPhone, ask Nollie in the chat.",
                                       comment: "What's new, 1.3.3: the detail")),
                    .init(id: "computer", symbol: "cursorarrow.rays",
                          title: String(localized: "Nollie Computer, refreshed", comment: "What's new, 1.3.3"),
                          line: String(localized: "The part that lets a helper use the apps you approve is up to date.", comment: "What's new, 1.3.3"),
                          more: String(localized: "Nothing has moved, and there's nothing new to set up. A helper still asks before each task, and only uses the apps you say yes to.",
                                       comment: "What's new, 1.3.3: the detail"),
                          macOnly: true),
                ]),
        ]
    }
}
