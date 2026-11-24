import Foundation

/// An optional small AI model running on this Mac (through Ollama), for quick answers in about a second.
/// Hoot uses it only for small talk and simple questions; anything about code, files, the screen or the web
/// still goes to Claude. Nothing here leaves the Mac. Without Ollama, Kiri works exactly as before.
///
/// Set up: `brew install ollama` (or the app from ollama.com), then `ollama pull llama3.2:3b`.
enum LocalBrain {
    enum Route: Equatable { case command(QuickCommand), answer(String), claude }

    static let defaultModel = "llama3.2:3b"
    static var model: String { UserDefaults.standard.string(forKey: "localModel") ?? defaultModel }
    static var enabled: Bool { UserDefaults.standard.object(forKey: "useLocalModel") as? Bool ?? true }
    private static let base = URL(string: "http://127.0.0.1:11434")!

    /// Cached "is Ollama running with the model?" (checked at most once a minute).
    nonisolated(unsafe) private static var cached: (ok: Bool, at: Date)?

    static func isReady() async -> Bool {
        guard enabled else { return false }
        if let c = cached, Date().timeIntervalSince(c.at) < 60 { return c.ok }
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 1.5
        var ok = false
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = obj["models"] as? [[String: Any]] {
            let want = model.contains(":") ? model : model + ":latest"
            ok = models.contains { ($0["name"] as? String) == want || ($0["model"] as? String) == want }
        }
        cached = (ok, Date())
        return ok
    }

    /// Words that mean "this needs Claude" — skip the local model so there's no extra wait.
    static func clearlyNeedsClaude(_ text: String) -> Bool {
        let t = text.lowercased()
        let words = ["code", "bug", "test", "fix", "function", "file", "folder", "project", "repo", "commit", "error", "build",
                     "screen", "this page", "website", "search", "look up", "latest", "news", "weather", "remind", "email", "mail",
                     "calendar", "meeting", "write a", "refactor", "explain this", "pull request", " pr", "branch", "install", "run ",
                     "wallpaper", "organi", "download", "focus", "plan my", "brief"]
        return words.contains { t.contains($0) } || t.contains(".") && t.range(of: #"\.\w{1,5}\b"#, options: .regularExpression) != nil
    }

    static let instructions = """
    You are the quick brain of Hoot, a witty owl assistant on the user's Mac. Decide how to handle the user's message \
    and reply with JSON only.
    1. If it is one of these Mac controls, reply {"command": "<the matching phrase>"} using exactly one of: \
    "volume up", "volume down", "volume <0-100>", "mute", "unmute", "minimise this", "minimise <app name>", \
    "full screen", "move this to the left", "move this to the right", "maximise", "hide everything else", \
    "play", "pause", "next song", "previous song", "timer <number> minutes", "timer <number> seconds", \
    "what time is it", "what's the date", "battery", "open <app name>".
    2. If it is small talk or a simple general-knowledge question you can answer well in one or two short spoken \
    sentences without looking at files, the screen, the internet, the calendar or anything recent, reply \
    {"answer": "<your answer: friendly, confident, a little dry humour, max 2 sentences, no markdown>"}.
    3. Anything else (code, projects, files, the screen, the web, current events, reminders, email, multi-step tasks, \
    or anything you are unsure about) reply {"claude": true}.
    """

    /// Ask the local model how to handle `text`. Returns nil if it isn't available or took too long.
    static func route(_ text: String) async -> Route? {
        guard await isReady() else { return nil }
        let body: [String: Any] = [
            "model": model, "stream": false, "format": "json", "keep_alive": "30m",
            "options": ["temperature": 0.2, "num_predict": 120],
            "messages": [["role": "system", "content": instructions + UserProfile.prompt], ["role": "user", "content": text]],
        ]
        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let started = Date()
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (obj["message"] as? [String: Any])?["content"] as? String else {
            Log.write("local model: no answer")
            return nil
        }
        Log.write(String(format: "local model answered in %.1fs", Date().timeIntervalSince(started)))
        return parseReply(content)
    }

    static func parseReply(_ content: String) -> Route? {
        guard let d = content.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if let c = j["command"] as? String {
            let phrase = c.replacingOccurrences(of: #"^timer (\d+)"#, with: "timer for $1", options: .regularExpression)
            return QuickCommand.parse(phrase).map { .command($0) } ?? .claude
        }
        if let a = j["answer"] as? String, !a.trimmingCharacters(in: .whitespaces).isEmpty { return .answer(a.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .claude
    }
}
