import Foundation

/// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0): initialize, ping, tools/list, tools/call.
/// Every tool runs one of `Actions`, so it behaves exactly like the `notch` command.
enum MCP {
    struct Tool {
        let name: String, description: String
        let properties: [String: [String: String]]
        let required: [String]
        let run: ([String: Any]) -> Result<String, CLIError>
    }

    static let taskArg = ["type": "string", "description": "Task id from list_today (e.g. a1b2c3) or its title"]
    static let timeArg = ["type": "string", "description": "When: 5pm, 17:30, 30m, in 1h30m, or ISO 8601"]

    static let tools: [Tool] = coreTools + plannerTools

    static let coreTools: [Tool] = [
        Tool(name: "list_today",
             description: "Snapshot of the user's notch and Planner, read live: today's tasks with ids, estimates, time blocks and notes; completed today; overdue; tasks planned for coming days; someday; reminders; today's calendar events; focus timer. Call this first: it usually has everything needed to find a task.",
             properties: [:], required: []) { _ in .success(Actions.today()) },
        Tool(name: "add_task", description: "Add a task. Defaults to today's list on the notch; optionally set the day (or someday), project, due date, estimate, notes, weekly goal and a reminder.",
             properties: ["title": ["type": "string", "description": "Task title"],
                          "remind": timeArg,
                          "time_limit_minutes": ["type": "integer", "description": "Focus duration / estimate, in minutes"],
                          "day": dayArg, "due": dayArg, "project": projectArg,
                          "notes": ["type": "string", "description": "Details or context for the task"],
                          "goal": ["type": "string", "description": "This week's goal title to link"]],
             required: ["title"]) { a in
            ["day", "due", "project", "notes", "goal"].contains(where: { a[$0] != nil })
                ? PlannerActions.addTask(a)
                : Actions.add(a["title"] as? String ?? "", remind: a["remind"] as? String, limit: (a["time_limit_minutes"] as? NSNumber)?.intValue)
        },
        Tool(name: "complete_task", description: "Mark a task on the user's notch as done.",
             properties: ["task": taskArg], required: ["task"]) { a in Actions.complete(a["task"] as? String ?? "") },
        Tool(name: "set_reminder", description: "Set or change a task's reminder (a macOS notification). Use remind \"none\" to remove it.",
             properties: ["task": taskArg, "remind": timeArg], required: ["task", "remind"]) { a in
            Actions.remind(a["task"] as? String ?? "", at: a["remind"] as? String ?? "")
        },
        Tool(name: "move_to_tomorrow", description: "Move a task off today's list to tomorrow.",
             properties: ["task": taskArg], required: ["task"]) { a in Actions.tomorrow(a["task"] as? String ?? "") },
        Tool(name: "append_note", description: "Add a line to the notch's Notepad.",
             properties: ["text": ["type": "string", "description": "Text to add"]], required: ["text"]) { a in
            Actions.note(a["text"] as? String ?? "")
        },
        Tool(name: "read_notes", description: "Read today's Notepad text from the user's notch (read_note reads other days).",
             properties: [:], required: []) { _ in .success(Actions.notes()) },
    ]

    static func run() {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let reply = handle(msg) { write(reply) }
        }
    }

    /// Returns the reply, or nil for notifications (messages without an id).
    static func handle(_ msg: [String: Any]) -> [String: Any]? {
        guard let id = msg["id"] else { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]
        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func err(_ code: Int, _ message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]] }

        switch msg["method"] as? String {
        case "initialize":
            return ok(["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                       "capabilities": ["tools": [String: Any]()],
                       "serverInfo": ["name": "notch", "version": "1.0"],
                       "instructions": "Tools for the user's macOS notch app and its Planner: today's tasks, projects with plan pages, weekly goals, daily notes, and time blocks on the calendar. Call list_today first to get task ids; call get_project before working on a project; call read_day before block_time."])
        case "ping":
            return ok([String: Any]())
        case "tools/list":
            return ok(["tools": tools.map { t in
                ["name": t.name, "description": t.description,
                 "inputSchema": ["type": "object", "properties": t.properties, "required": t.required]] as [String: Any]
            }])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                return err(-32602, "Unknown tool")
            }
            let result = tool.run(params["arguments"] as? [String: Any] ?? [:])
            let (text, isError): (String, Bool) = switch result {
            case let .success(t): (t, false)
            case let .failure(e): (e.message, true)
            }
            return ok(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return err(-32601, "Method not found")
        }
    }

    static func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
