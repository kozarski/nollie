import Foundation

/// Decides which approvals earn a second tap when they are answered away from the chat (Lock
/// Screen, notification). Anything that writes, deletes, spends, sends or escalates is risky;
/// plain looking is not, so the extra question stays rare enough to mean something.
public enum ApprovalRisk {
    public static func isRisky(_ request: ApprovalRequest) -> Bool {
        if request.smartDenied == true { return true }
        let key = (request.patternKey ?? "")
        // Ask first rules only ever cover a send, a payment, a post or a delete.
        if key.hasPrefix(AskFirstAsk.rulePrefix) { return true }

        let tool = (request.toolName ?? "").lowercased()
        if changingTools.contains(tool) { return true }
        let command = (request.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if lookingTools.contains(tool), command.isEmpty { return false }

        let description = (request.description ?? "").lowercased()
        if alarmingStems.contains(where: description.contains) { return true }
        let lowerKey = key.lowercased()
        if keyHints.contains(where: lowerKey.contains) { return true }
        return command.isEmpty ? false : commandIsRisky(command)
    }

    // MARK: Lists

    /// Names written out as one string, split on spaces.
    private static func words(_ list: String) -> Set<String> {
        Set(list.split(separator: " ").map(String.init))
    }

    /// Phrases written out as one string, split on commas (a phrase may hold spaces).
    private static func phrases(_ list: String) -> [String] {
        list.split(separator: ",").map(String.init)
    }

    // MARK: Tools

    /// Tools that edit files or execute code.
    static let changingTools: Set<String> = Self.words(
        "apply_patch create_file delete_file edit_file execute_code move_file notebook_edit " +
        "patch rename_file write_file")
    /// Tools that only look around.
    static let lookingTools: Set<String> = Self.words(
        "get_page glob grep list_files read_file screenshot search_files " +
        "skill_view tool_search web_extract web_fetch web_search")

    // MARK: Words

    /// Stems that, in the gateway's warning or the bot's own description, mean something is
    /// written, removed, paid for, widened or sent out.
    static let alarmingStems: [String] = Self.phrases(
        "backup,billing,block device,boot,buy,chang," +
        "charg,checkout,chmod,chown,clean,credential," +
        "delet,deploy,destroy,destructive,disk,drop," +
        "email,encoded command,exfil,force,format,install," +
        "invoice,kill,migrat,modif,order,overwrit," +
        "partition,password,pay,permission,pipe,post," +
        "privileg,publish,purchas,push,rebase,reboot," +
        "recursive,registry,remote content,remov,reset,restart," +
        "root,secret,send,service,shadow,shred," +
        "shutdown,spend,ssh key,stop,subscri,sudo," +
        "token,transfer,truncat,uninstall,upgrade,upload," +
        "wipe,write")

    /// Fragments of the gateway's pattern key that point the same way.
    static let keyHints: [String] = Self.phrases(
        "chmod,chown,curl,dd,del,edit," +
        "exec,git push,git reset,install,kill,mkfs," +
        "patch,pay,rm,stripe,sudo,wget," +
        "write")

    // MARK: Commands

    /// Programs that are risky whatever they are given.
    private static let alwaysRisky: Set<String> = Self.words(
        "braintree chgrp chmod chown coinbase cp dd " +
        "doas fallocate fdisk halt icacls install kill " +
        "killall ln mail mailx msmtp mutt mv " +
        "networksetup nvram osascript parted paypal pkill pmset " +
        "poweroff reboot revolut rm rmdir rsync sendmail " +
        "setfacl shred shutdown square srm stop-process stripe " +
        "su sudo taskkill tee truncate unlink wipe " +
        "wipefs wise")

    /// Programs that are risky only with certain first words after them.
    private static let riskyVerbs: [String: Set<String>] = {
        var table: [String: Set<String>] = [
            "git": words("push reset restore clean rebase merge cherry-pick revert commit stash " +
                         "filter-branch filter-repo gc remote config branch tag checkout"),
            "kubectl": words("delete apply create replace patch edit rollout scale drain cordon taint exec"),
            "diskutil": words("erase partition zero"),
            "defaults": words("write"),
            "sysctl": words("-w"),
            "crontab": words("-r -e"),
            "scutil": words("--set"),
        ]
        let groups: [(programs: String, verbs: String)] = [
            ("pip pip3 pipx uv npm pnpm yarn bun gem cargo go brew apt apt-get yum dnf pacman apk snap " +
             "flatpak choco winget conda poetry",
             "install uninstall remove purge upgrade update add rm dist-upgrade autoremove link publish"),
            ("systemctl launchctl service sc sc.exe",
             "start stop restart reload enable disable delete unload load kickstart"),
            ("docker podman nerdctl",
             "rm rmi prune system volume network kill stop restart push run exec compose"),
            ("terraform tofu pulumi", "apply destroy import taint state"),
            ("aws gcloud az doctl linode-cli flyctl fly heroku vercel netlify wrangler",
             "create delete terminate run-instances deploy publish update start stop reboot resize purchase buy"),
        ]
        for group in groups {
            for program in words(group.programs) { table[program] = words(group.verbs) }
        }
        return table
    }()

    /// Database shells are judged by what they are told to run.
    private static let databaseShells: Set<String> = ["psql", "mysql", "sqlite3", "mongo", "mongosh", "redis-cli"]
    private static let databaseWrites: [String] = ["drop", "delete", "truncate", "update", "insert", "alter",
                                                   "flushall", "flushdb", "del"]

    /// Whole-line shapes that no program name catches.
    private static let lineShapes: [NSRegularExpression] = [
        #"(^|[^>])>{1,2}\s*[^&\s]"#,                                   // output sent into a file
        #"\b(sed|perl)\b[^|]*\s-[a-z]*i\b"#,                           // edited in place
        #"\bfind\b.*(\s-delete\b|\s-exec\s+(rm|mv|chmod|chown|shred)\b)"#,
        #"\bmkfs(\.\w+)?\b"#,
        #"\b(curl|wget|http|https|xh)\b.*(\s-X\s*(POST|PUT|PATCH|DELETE)\b|\s-[dFT]\s|\s--(data|form|upload-file|json|method)\b)"#,
        #"\|\s*(sh|bash|zsh|python\d?|node|iex)\b"#,                    // downloaded and run
        #"\b(pay|purchase|checkout|charge|refund|transfer|withdraw|top-?up)\b"#,
        #"(~|\$HOME|/root|/home/\w+)/\.(ssh|aws|gnupg|config/gh|netrc|hermes)\b"#,
        #"\.(env|pem|key|p12|keychain)\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    private static let shellBreaks = CharacterSet(charactersIn: ";&|\n`()")

    static func commandIsRisky(_ command: String) -> Bool {
        let whole = NSRange(command.startIndex..., in: command)
        if lineShapes.contains(where: { $0.firstMatch(in: command, range: whole) != nil }) { return true }

        // Each piece between shell separators starts with the program that will run.
        for piece in command.components(separatedBy: shellBreaks) {
            let words = piece.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
                .drop { $0.contains("=") && !$0.hasPrefix("-") }
            guard let first = words.first else { continue }
            let program = first.split(separator: "/").last.map(String.init) ?? first
            if alwaysRisky.contains(program) { return true }
            if let verbs = riskyVerbs[program], words.dropFirst().contains(where: verbs.contains) {
                if program != "git" || gitChangesThings(Array(words.dropFirst())) { return true }
            }
            if databaseShells.contains(program), databaseWrites.contains(where: { piece.lowercased().contains($0) }) {
                return true
            }
            if ["ssh", "scp", "sftp"].contains(program),
               piece.lowercased().split(whereSeparator: \.isWhitespace).contains(where: { ["rm", "mv", "dd", "sudo", "reboot", "kill"].contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Some git verbs only change things in certain forms (`checkout --`, `branch -d`, `stash drop`).
    private static func gitChangesThings(_ args: [String]) -> Bool {
        guard let verb = args.first(where: { !$0.hasPrefix("-") }) else { return false }
        switch verb {
        case "checkout": return args.contains("--")
        case "branch", "tag": return args.contains("-d")   // words are lowercased, so -D reads as -d
        case "remote": return args.contains { ["add", "remove", "set-url"].contains($0) }
        case "gc": return args.contains("--prune")
        case "stash": return args.contains { ["drop", "clear", "pop"].contains($0) }
        default: return true
        }
    }
}
