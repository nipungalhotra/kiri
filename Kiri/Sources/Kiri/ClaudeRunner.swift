import Foundation

enum ClaudeEvent {
    case session(String)
    case text(String)
    case tool(String)
    /// Final result: text, whether it was an error, and how many tool calls were refused.
    case done(String?, isError: Bool, denied: Int)
    case failed(String)
    /// Claude couldn't reach its server and is retrying (attempt number).
    case retry(Int)
    /// A tool call, with enough detail to ask the user about it later.
    case toolCall(id: String, name: String, detail: String)
    /// Claude Code refused a tool call (needs the user's approval).
    case denied(id: String, tool: String)
}

/// Runs the Claude Code CLI headlessly (`claude -p … --output-format stream-json`) inside the
/// chosen project and streams what it's doing back to Kiri.
final class ClaudeRunner {
    private var process: Process?

    static let persona = """
    You are Kiri (Hoot the owl), a friendly desktop pet on the user's Mac that helps them code and \
    with small Mac tasks. You usually run inside their project folder. Be warm, a little playful, and brief: \
    at most about 120 words of plain text (short code snippets are fine, no headings). \
    When you change files, say exactly which files you changed. \
    If the user mentions a screenshot path, read that image with the Read tool to see their screen. \
    MAC ACTIONS: Kiri can do these for the user. Only when the user asks for one, put it on its own line, \
    exactly like: KIRI_ACTION {"action":"open_app","name":"Safari"} \
    Available: open_app {name}; open_url {url}; reminder {title, due} where due is local ISO 8601 \
    like 2026-11-22T10:00 (optional); focus {on: true or false}; organize_folder {folder} where folder is \
    "Downloads", "Desktop" or an absolute path (sorts loose files into subfolders by type). \
    Never use shell commands for these. Kiri asks the user before anything risky, so just request the action \
    and tell the user briefly what you asked Kiri to do. \
    If a tool call is blocked for permission, don't explain settings: just say "Kiri will ask you to allow it" in one short line.
    """

    static let claudePath: String? = {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.npm-global/bin/claude", "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ]
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        let out = shell("command -v claude")
        return out.isEmpty ? nil : out
    }()

    /// The user's login-shell PATH, so `node`, `npm`, `python3`, `cargo` etc. resolve like in Terminal.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        // If Kiri itself was started from inside a Claude Code session, that session's private
        // login token and settings leak into our environment and break a standalone `claude` run.
        // Drop them so `claude` uses the user's own sign-in. (A normal launch has none of these.)
        if env["CLAUDECODE"] != nil {
            for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK")
                || ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "CLAUDE_EFFORT", "CLAUDE_PID"].contains(key)
                || key.hasPrefix("ANTHROPIC_DEFAULT_") {
                env.removeValue(forKey: key)
            }
        }
        var parts = shell("echo $PATH").split(separator: ":").map(String.init)
        if let c = claudePath { parts.insert((c as NSString).deletingLastPathComponent, at: 0) }
        parts += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        env["PATH"] = parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return env
    }()

    static let signInHelp = """
    I can't reach Claude. Please sign in: open Terminal, run `claude --setting-sources project,local`, \
    type /login, sign in, then try again.
    """

    /// The user's ~/.claude/settings.json can redirect the CLI to a local server (ANTHROPIC_BASE_URL).
    /// If that points at localhost and nothing is listening there, skip the user settings so the CLI
    /// uses the normal Claude login instead of retrying a dead address forever.
    static func shouldSkipUserSettings() -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any],
              let base = env["ANTHROPIC_BASE_URL"] as? String,
              let comps = URLComponents(string: base), let host = comps.host,
              ["localhost", "127.0.0.1", "::1"].contains(host) else { return false }
        let port = comps.port ?? (comps.scheme == "https" ? 443 : 80)
        return !isListening(port: port)
    }

    private static func isListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }

    static func shell(_ command: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func stop() { process?.terminate() }

    func send(prompt: String, cwd: URL, sessionID: String?, allowEdits: Bool,
              extraAllowedTools: [String] = [], forceEdits: Bool = false, addDirs: [URL] = [],
              onEvent: @escaping (ClaudeEvent) -> Void) {
        let deliver: (ClaudeEvent) -> Void = { e in
            switch e {
            case .session(let id): Log.write("claude session \(id)")
            case .text(let t): Log.write("claude text: \(t.prefix(300))")
            case .tool(let what): Log.write("claude tool: \(what)")
            case .done(let r, let err, let denied): Log.write("claude done error=\(err) denied=\(denied): \((r ?? "").prefix(300))")
            case .failed(let why): Log.write("claude FAILED: \(why)")
            case .retry(let n): Log.write("claude retry \(n)")
            case .toolCall(let id, let name, let detail): Log.write("claude toolCall \(id) \(name): \(detail.prefix(160))")
            case .denied(let id, let tool): Log.write("claude denied \(id) \(tool)")
            }
            DispatchQueue.main.async { onEvent(e) }
        }
        Log.write("claude start exe=\(Self.claudePath ?? "nil") cwd=\(cwd.path) edits=\(allowEdits) resume=\(sessionID ?? "-") prompt=\(prompt.prefix(120))")
        guard let exe = Self.claudePath else {
            deliver(.failed("I can't find the `claude` command. Install Claude Code first, then restart me."))
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        var args = ["-p", prompt,
                    "--output-format", "stream-json", "--verbose",
                    "--permission-mode", (allowEdits || forceEdits) ? "acceptEdits" : "default",
                    "--append-system-prompt", Self.persona]
        if let s = sessionID { args += ["--resume", s] }
        var allowed = extraAllowedTools
        if allowEdits {
            // Allow running the project's tests (and nothing else extra) so Claude can check its fix.
            allowed += ["Bash(python3 -m unittest:*)", "Bash(python3 -m pytest:*)", "Bash(pytest:*)",
                        "Bash(npm test:*)", "Bash(swift test:*)", "Bash(cargo test:*)", "Bash(go test:*)", "Bash(make test:*)"]
        }
        if !allowed.isEmpty { args += ["--allowedTools"] + allowed }
        for dir in addDirs { args += ["--add-dir", dir.path] }
        if Self.shouldSkipUserSettings() {
            args += ["--setting-sources", "project,local"]
            Log.write("user settings point at a local server that isn't running; skipping them")
        }
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = Self.environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        do { try p.run() } catch {
            deliver(.failed("Couldn't start Claude: \(error.localizedDescription)"))
            return
        }
        process = p

        DispatchQueue.global(qos: .userInitiated).async {
            var errData = Data()
            let errDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                errDone.signal()
            }

            var buffer = Data()
            var sawResult = false
            var gaveUp = false
            let handle = out.fileHandleForReading
            func flush(final: Bool) {
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    for e in Self.parse(line) {
                        if case .retry(let n) = e, n >= 3, !gaveUp {
                            gaveUp = true
                            p.terminate()
                            deliver(.failed(Self.signInHelp))
                            continue
                        }
                        if case .done = e { sawResult = true }
                        deliver(e)
                    }
                }
                if final, !buffer.isEmpty {
                    for e in Self.parse(buffer) {
                        if case .done = e { sawResult = true }
                        deliver(e)
                    }
                    buffer.removeAll()
                }
            }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                flush(final: false)
            }
            flush(final: true)
            p.waitUntilExit()
            errDone.wait()

            if !sawResult && !gaveUp {
                if p.terminationReason == .uncaughtSignal {
                    deliver(.failed("Okay, I stopped."))
                } else {
                    let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    deliver(.failed(msg.isEmpty ? "Claude exited with code \(p.terminationStatus)." : String(msg.suffix(400))))
                }
            }
        }
    }

    static func parse(_ line: Data) -> [ClaudeEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        switch type {
        case "system":
            let sub = obj["subtype"] as? String ?? "?"
            if sub != "init" {
                // retries, hook messages, etc. — record the raw line so problems are visible in the log
                let raw = String(data: line, encoding: .utf8) ?? ""
                Log.write("claude system \(sub): \(raw.prefix(500))")
            }
            if sub == "api_retry" { return [.retry(obj["attempt"] as? Int ?? 1)] }
            if sub == "permission_denied" {
                return [.denied(id: obj["tool_use_id"] as? String ?? "", tool: obj["tool_name"] as? String ?? "tool")]
            }
            if sub == "init", let s = obj["session_id"] as? String { return [.session(s)] }
        case "assistant":
            guard let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return [] }
            return content.flatMap { c -> [ClaudeEvent] in
                switch c["type"] as? String {
                case "text":
                    if let t = c["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [.text(t)] }
                case "tool_use":
                    let name = c["name"] as? String ?? "tool"
                    let input = c["input"] as? [String: Any] ?? [:]
                    let detail = (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["url"] as? String) ?? ""
                    return [.tool(describe(name: name, input: input)),
                            .toolCall(id: c["id"] as? String ?? "", name: name, detail: detail)]
                default: break
                }
                return []
            }
        case "result":
            var events: [ClaudeEvent] = []
            if let s = obj["session_id"] as? String { events.append(.session(s)) }
            let denied = (obj["permission_denials"] as? [Any])?.count ?? 0
            let result = obj["result"] as? String
            if let r = result, r.localizedCaseInsensitiveContains("not logged in") || r.contains("/login")
                || r.localizedCaseInsensitiveContains("invalid api key") || r.localizedCaseInsensitiveContains("failed to authenticate") {
                events.append(.failed(signInHelp))
            } else {
                events.append(.done(result, isError: (obj["is_error"] as? Bool) ?? false, denied: denied))
            }
            return events
        default: break
        }
        return []
    }

    /// Turns a tool call into a short, friendly progress line.
    static func describe(name: String, input: [String: Any]) -> String {
        func file(_ key: String) -> String {
            ((input[key] as? String).map { ($0 as NSString).lastPathComponent }) ?? "a file"
        }
        switch name {
        case "Read": return "Reading \(file("file_path"))"
        case "Edit", "MultiEdit": return "Editing \(file("file_path"))"
        case "Write": return "Writing \(file("file_path"))"
        case "Bash":
            let cmd = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return "Running \(cmd.prefix(40))"
        case "Grep", "Glob": return "Searching the code"
        case "WebSearch", "WebFetch": return "Looking it up online"
        case "TodoWrite": return "Making a plan"
        default: return "Using \(name)"
        }
    }
}
