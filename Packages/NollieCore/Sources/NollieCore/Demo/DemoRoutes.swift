import Foundation

/// The made-up pages of the demo that are not chats or the Board: settings, schedules, the
/// Night shift card and the Papertrail.
enum DemoRoutes {
    static let config: JSONValue = [
        "model": .string(DemoSeed.model),
        "approvals": ["mode": "smart", "timeout": 300, "cron_mode": "deny"],
        "agent": ["reasoning_effort": "medium", "max_iterations": 40],
        "display": ["streaming": true, "show_reasoning": true, "timestamps": false],
        "terminal": ["backend": "local"],
    ]

    static func modelOptions() -> JSONValue {
        let models: [JSONValue] = ["demo/assistant", "demo/assistant-mini"]
        return [
            "model": .string(DemoSeed.model), "provider": .string(DemoSeed.provider),
            "providers": [[
                "slug": .string(DemoSeed.provider), "name": "Demo", "authenticated": true, "is_current": true,
                "featured_models": .array(models), "models": .array(models),
                "capabilities": ["demo/assistant": ["fast": false, "reasoning": false, "can_disable_reasoning": false]],
            ]],
        ]
    }

    static func status() -> JSONValue {
        ["version": "demo", "gateway": ["status": "running", "pid": 1], "gateway_running": true, "gateway_state": "running",
         "active_sessions": 0, "auth_required": false, "auth_providers": [], "auth_flows": [],
         "memory": ["pressure": "ok", "gateway_rss_mb": 200, "system_available_mb": 8000],
         "disk": ["pressure": "ok", "free_mb": 180_000, "total_mb": 494_000, "used_percent": 41]]
    }

    static func profiles() -> JSONValue {
        .object(["profiles": .array(DemoSeed.bots.map { bot in
            ["name": .string(bot.name), "path": .string("/home/demo/.hermes/profiles/\(bot.name)"), "is_default": .bool(bot.name == "default"),
             "model": .string(DemoSeed.model), "provider": .string(DemoSeed.provider), "description": .string(bot.about),
             "display_name": .string(bot.display), "skill_count": 6, "has_env": true]
        })])
    }

    // MARK: Schedules

    static func schedules(now: Double) -> [JSONValue] {
        func when(_ offset: Double) -> JSONValue {
            let formatter = ISO8601DateFormatter()
            return .string(formatter.string(from: Date(timeIntervalSince1970: now + offset)))
        }
        return [
            ["job_id": "price-watch", "name": "Watch the Aero 5 price", "schedule": "0 9 * * 1",
             "prompt_preview": "Check the Aero 5 price and tell me if it changes.", "deliver": "local", "enabled": true, "state": "active",
             "next_run_at": when(2 * 86_400), "last_run_at": when(-5 * 86_400), "last_status": "ok", "profile": "scout"],
            ["job_id": "morning-plan", "name": "Morning plan", "schedule": "0 8 * * 1-5",
             "prompt_preview": "Plan my day from what I told you.", "deliver": "local", "enabled": true, "state": "active",
             "next_run_at": when(14 * 3600), "last_run_at": when(-10 * 3600), "last_status": "ok", "profile": "wren"],
        ]
    }

    // MARK: Night shift

    static func posts(now: Double) -> JSONValue {
        func action(_ tool: String, _ target: String, _ at: Double, status: String = "done", receipt: JSONValue = ["kind": "safe"]) -> JSONValue {
            ["tool": .string(tool), "target": .string(target), "status": .string(status), "at": .number(at), "receipt": receipt]
        }
        let start = now - 9 * 3600
        let runs: [JSONValue] = [
            ["id": "cron:price-watch:e-1", "kind": "schedule", "bot": "scout", "bot_name": "Scout", "title": "Watch the Aero 5 price",
             "outcome": "done", "started_at": .number(start), "finished_at": .number(start + 70),
             "actions": [action("web_search", "Aero 5 price", start + 10), action("web_extract", "Shop page", start + 30),
                         action("computer_use", "screenshot", start + 55, status: "blocked", receipt: ["kind": "blocked", "detail": "mac"])],
             "more": 0],
            ["id": "cron:morning-plan:e-2", "kind": "schedule", "bot": "wren", "bot_name": "Wren", "title": "Morning plan",
             "outcome": "done", "started_at": .number(start + 3600), "finished_at": .number(start + 3640),
             "actions": [action("write_file", "~/Notes/today.md", start + 3620, receipt: ["kind": "tool"])], "more": 0],
        ]
        let card: JSONValue = [
            "id": "night-demo", "kind": "night_shift", "at": .number(now - 3 * 3600), "unwatched": [], "runs": .array(runs),
            "counts": ["runs": 2, "actions": 4, "unrecorded": 0, "held": 0, "stopped": 1],
            "window": ["from": .number(now - 12 * 3600), "to": .number(now - 3 * 3600)],
        ]
        return ["version": 1, "posts": [card]]
    }

    // MARK: Papertrail

    /// What left the Mac today, for the bots that keep a record. The others have none.
    static func papertrail(bot: String, days: Int, now: Double) -> JSONValue? {
        guard ["default", "scout"].contains(bot) else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        func entry(_ id: String, _ ago: Double, calls: Int, searches: Int, pages: Int) -> JSONValue {
            ["id": .string(id), "at": .number(now - ago), "started_at": .number(now - ago - 40), "route": "online", "provider": .string(DemoSeed.provider),
             "provider_name": "Demo", "host": nil, "model": "assistant", "calls": .number(Double(calls)), "helpers": [], "services": [],
             "input_tokens": 9_000, "output_tokens": 600, "cache_read_tokens": 0, "reasoning_tokens": 0,
             "searches": .number(Double(searches)), "pages": .number(Double(pages)), "images": 0]
        }
        let entries: [JSONValue] = bot == "default"
            ? [entry("d1", 5 * 3600, calls: 3, searches: 1, pages: 0), entry("d2", 5 * 3600 + 200, calls: 2, searches: 0, pages: 0)]
            : [entry("s1", 3 * 3600, calls: 3, searches: 1, pages: 2)]
        return [
            "bot": .string(bot), "days": .number(Double(days)), "now": .number(now), "today_starts_at": .number(today),
            "tomorrow_starts_at": .number(today + 86_400), "since": .number(today - Double(days - 1) * 86_400),
            "recording_since": .number(today - 3 * 86_400), "stayed": ["today": 4, "window": 4],
            "left": ["today": .number(Double(entries.count)), "window": .number(Double(entries.count))],
            "entries": .array(entries), "more": 0,
        ]
    }
}
