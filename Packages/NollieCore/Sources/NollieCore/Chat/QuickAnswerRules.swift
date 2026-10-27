import Foundation

/// Quick answers: the model built into this device answers small things while the person's helper on
/// the Mac is out of reach or not set up yet. It talks only. These rules are fixed, never the model's
/// judgement: what goes to the model, what is handed to the helper instead, and what a reply may say.
public enum QuickAnswerRules {
    /// Where a quick answer is offered.
    public enum Place: String, Sendable, CaseIterable {
        /// First setup on the Mac, while Hermes installs or the model downloads.
        case macSetup
        /// Setup on the iPhone or iPad, before it is paired with a Mac.
        case phoneSetup
        /// On the iPhone or iPad while the Mac can't be reached.
        case macAway

        /// Whether a question can be handed to the helper on the Mac from here.
        public var handsOff: Bool { self == .macAway }
    }

    /// Why a request goes to the helper rather than the model on this device.
    public enum Reason: String, Sendable {
        /// It does something: sends, buys, books, posts, deletes, sets a reminder.
        case action
        /// It needs the person's own things: calendar, mail, files, messages.
        case yourStuff
        /// It needs fresh facts from the internet.
        case lookUp
    }

    public enum Route: Equatable, Sendable {
        case answerHere
        case helper(Reason)
    }

    /// One question and its answer, oldest first, for the model's memory of the chat.
    public struct Exchange: Equatable, Sendable {
        public var question: String
        public var answer: String

        public init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    // MARK: When to offer

    /// How long the Mac has to stay out of reach before quick answers are offered, so a reconnect
    /// at launch never flashes the bar.
    public static let awayGrace: TimeInterval = 6

    /// Whether the iPhone offers quick answers for the connection it has. A sign-in problem has
    /// its own banner and fix, so it is left to that.
    public static func offersWhileAway(_ state: SocketState?, outOfReachFor seconds: TimeInterval) -> Bool {
        switch state {
        case nil, .open?, .authRejected?: return false
        case .failed?: return true
        case .reconnecting?, .connecting?, .idle?: return seconds >= awayGrace
        }
    }

    // MARK: Routing

    /// Decides whether this device's model may answer. Drafting and rewording stay here even when
    /// they mention sending; anything that would act, read the person's things or need the
    /// internet goes to the helper. When a request mixes both ("write it and send it"), the
    /// helper wins.
    public static func route(_ text: String) -> Route {
        let said = normalised(text)
        guard !said.isEmpty else { return .answerHere }
        if matches(said, Patterns.chained) { return .helper(.action) }
        let drafting = matches(said, Patterns.drafting)
        if !drafting, matches(said, Patterns.action) { return .helper(.action) }
        if matches(said, Patterns.yourStuff) { return .helper(.yourStuff) }
        if !drafting, matches(said, Patterns.lookUp) { return .helper(.lookUp) }
        return .answerHere
    }

    /// True when a reply says it did something it cannot do from here ("I've sent it", "I'll book
    /// that"). Such a reply is never shown; the fixed line for an action takes its place.
    public static func claimsAction(_ reply: String) -> Bool {
        matches(normalised(reply), Patterns.claim)
    }

    // MARK: Memory

    /// The latest exchanges that fit in `budget` characters, oldest first. The model's window is
    /// small, so each part is also cut to a sensible length.
    public static func window(_ exchanges: [Exchange], budget: Int) -> [Exchange] {
        var kept: [Exchange] = []
        var used = 0
        for exchange in exchanges.reversed() {
            let trimmed = Exchange(question: String(exchange.question.prefix(600)), answer: String(exchange.answer.prefix(900)))
            let cost = trimmed.question.count + trimmed.answer.count + 20
            guard used + cost <= budget else { break }
            used += cost
            kept.insert(trimmed, at: 0)
        }
        return kept
    }

    /// Characters of earlier chat to send with a question, from the model's window in tokens.
    /// About three characters a token, with room kept for the instructions and the answer.
    public static func memoryBudget(contextTokens: Int) -> Int {
        max(0, min((contextTokens - 1_600) * 3, 9_000))
    }

    // MARK: Words

    /// What the person sees when the request goes to the helper. Fixed text, never the model's.
    public static func helperLine(_ reason: Reason, place: Place) -> String {
        switch (reason, place) {
        case (.action, .macAway):
            String(localized: "Quick answers just talk. Nollie on your Mac can do that, and it asks before sending or buying anything.", table: "Core",
                   comment: "Safety: Nollie asks before sending or buying; keep exact meaning")
        case (.action, .macSetup):
            String(localized: "Quick answers just talk. Once setup is done, Nollie can do that, and it asks before sending or buying anything.", table: "Core",
                   comment: "Safety: Nollie asks before sending or buying; keep exact meaning")
        case (.action, .phoneSetup):
            String(localized: "Quick answers just talk. Once Nollie is set up on your Mac, it can do that, and it asks before sending or buying anything.", table: "Core",
                   comment: "Safety: Nollie asks before sending or buying; keep exact meaning")
        case (.yourStuff, .macAway):
            String(localized: "Quick answers can't see your calendar, mail or files. Nollie on your Mac can help with that.", table: "Core")
        case (.yourStuff, .macSetup):
            String(localized: "Quick answers can't see your calendar, mail or files. Once setup is done, Nollie can help with that.", table: "Core")
        case (.yourStuff, .phoneSetup):
            String(localized: "Quick answers can't see your calendar, mail or files. Once Nollie is set up on your Mac, it can help with that.", table: "Core")
        case (.lookUp, .macAway):
            String(localized: "Quick answers can't look things up online. Nollie on your Mac can help with that.", table: "Core")
        case (.lookUp, .macSetup):
            String(localized: "Quick answers can't look things up online. Once setup is done, Nollie can help with that.", table: "Core")
        case (.lookUp, .phoneSetup):
            String(localized: "Quick answers can't look things up online. Once Nollie is set up on your Mac, it can help with that.", table: "Core")
        }
    }

    // MARK: Matching

    private enum Patterns {
        /// Write-it-then-do-it requests.
        static let chained = [
            #"\b(and|then)\s+(send|email|text|post|share|book|order|buy|pay|schedule|delete)\b"#,
            #"\bsend it\b"#, #"\bpost it\b"#,
        ]
        /// Asking for something to be written, reworded or explained.
        static let drafting = [
            #"^(please\s+)?(can you\s+|could you\s+|help me\s+)?(draft|write|reword|rephrase|rewrite|proofread|polish|translate|summari[sz]e|shorten|tidy|improve|fix the wording|make (this|it))\b"#,
            #"\bhelp me (word|write|reply|respond|say)\b"#, #"\bhow (do|should|can) i (say|word|reply|respond|ask)\b"#,
            #"\bwhat should i (say|write|reply)\b"#,
        ]
        /// Doing something in the world or on the device.
        static let action = [
            #"^(please\s+)?((can|could|would|will) you\s+)?(please\s+)?(send|email|e-mail|text|message|call|ring|phone|facetime|buy|order|purchase|pay|book|reserve|post|tweet|publish|delete|remove|cancel|unsubscribe|schedule|forward|reply to|open|launch|turn (on|off)|switch (on|off)|download|install|play|set up|sign (me )?up|log ?in)\b"#,
            #"\bremind me\b"#, #"\bset (a|an|my) (alarm|reminder|timer)\b"#,
            #"\b(add|put)\b.*\b(to|in|on) (my |the )?(calendar|reminders|shopping list|to-do list|todo list|contacts|diary|basket|cart)\b"#,
            #"\b(put|create|make) (an? )?(event|reminder|appointment|meeting)\b"#,
        ]
        /// The person's own things.
        static let yourStuff = [
            #"\b(check|read|search|look (through|at|in)|open|find in|go through|clear|empty|tidy) (my|the) (calendar|email|emails|mail|inbox|messages|texts|files|documents|photos|reminders|contacts|notes|downloads|desktop)\b"#,
            #"\bwhat'?s (on|in) my (calendar|diary|schedule|inbox)\b"#, #"\bwhat is (on|in) my (calendar|diary|schedule|inbox)\b"#,
            #"\b(do|have) i (got|have) (any )?(meetings|appointments|emails|messages|plans)\b"#,
            #"\bmy (calendar|diary|inbox|emails|messages|files|reminders|contacts)\b"#,
            #"\bon (my|this) (mac|computer|screen)\b"#,
        ]
        /// Facts that change by the day.
        static let lookUp = [
            #"\b(latest|today'?s|tonight'?s|this week'?s|current|live)\s+(news|weather|score|scores|price|prices|results?|forecast|rates?)\b"#,
            #"\b(weather|forecast)\b.*\b(today|tomorrow|tonight|this week|weekend)\b"#,
            #"\b(search|google|look up|browse)\b"#, #"\b(what time does|is) .+ open\b"#, #"\bopen now\b"#,
            #"\bstock price\b"#, #"\bexchange rate\b"#,
        ]
        /// A reply that says it acted.
        static let claim = [
            #"\bi('ve| have)\s+(just\s+)?(sent|emailed|texted|messaged|called|booked|ordered|bought|paid|posted|deleted|removed|cancelled|canceled|scheduled|added|set up|set a|set an|created|forwarded|reminded|saved|opened|downloaded|installed|checked your|looked at your|read your)\b"#,
            #"\bi('ll| will)\s+(now\s+)?(send|email|text|message|call|book|order|buy|pay|post|delete|schedule|add|set|create|forward|remind|check your|look at your|read your)\b"#,
            #"\b(it'?s|it has been|that'?s|that has been|has been)\s+(sent|booked|ordered|posted|scheduled|added to your|deleted|cancelled)\b"#,
            #"\bi (sent|booked|ordered|bought|posted|scheduled|added|deleted|emailed|texted)\b"#,
        ]
    }

    private static func normalised(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!? "))
            .replacingOccurrences(of: #"^(hey |hi |ok |okay )?nollie[,:]?\s*"#, with: "", options: .regularExpression)
    }

    private static func matches(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
