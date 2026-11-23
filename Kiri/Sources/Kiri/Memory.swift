import AppKit
import EventKit
import Foundation

// MARK: Project memory

/// What you worked on in each project, kept only on this Mac (~/Library/Application Support/Kiri/memory,
/// readable only by you). Used for "Morning! Yesterday you were…" and to remind Claude of earlier work.
/// Turn off in 🦉 → Remember My Work.
enum ProjectMemory {
    struct Entry: Codable {
        let date: Date
        let ask: String
        let outcome: String
    }
    struct Store: Codable {
        var entries: [Entry] = []
        var testsPassed: Bool?
        var testsDate: Date?
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "rememberWork") as? Bool ?? true }

    static let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kiri/memory")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }()

    static func file(for project: URL) -> URL {
        let name = project.lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let hash = project.path.utf8.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1) }
        return folder.appendingPathComponent("\(name)-\(String(hash, radix: 16)).json")
    }

    static func load(_ project: URL) -> Store {
        guard let data = try? Data(contentsOf: file(for: project)),
              let s = try? JSONDecoder().decode(Store.self, from: data) else { return Store() }
        return s
    }

    private static func save(_ s: Store, _ project: URL) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let url = file(for: project)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func record(_ project: URL?, ask: String, outcome: String) {
        guard enabled, let project else { return }
        var s = load(project)
        let clean = { (t: String, n: Int) in String(t.replacingOccurrences(of: "\n", with: " ").prefix(n)) }
        s.entries.append(Entry(date: Date(), ask: clean(ask, 160), outcome: clean(outcome, 200)))
        if s.entries.count > 30 { s.entries.removeFirst(s.entries.count - 30) }
        save(s, project)
    }

    static func recordTests(_ project: URL?, passed: Bool) {
        guard enabled, let project else { return }
        var s = load(project)
        s.testsPassed = passed
        s.testsDate = Date()
        save(s, project)
    }

    static func forget(_ project: URL) { try? FileManager.default.removeItem(at: file(for: project)) }

    /// A few lines Claude gets at the start of a new chat, so it knows what happened before.
    static func context(for project: URL?) -> String? {
        guard enabled, let project else { return nil }
        let recent = load(project).entries.suffix(5)
        guard !recent.isEmpty else { return nil }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        let lines = recent.map { "- \(df.string(from: $0.date)): asked “\($0.ask)” → \($0.outcome)" }.joined(separator: "\n")
        return "(Kiri's notes from earlier sessions in this project, for context only:\n\(lines))"
    }

    /// "Morning! Yesterday you were fixing login. Tests were failing." — only once a day, after earlier work.
    static func morningLine(for project: URL?) -> String? {
        guard enabled, let project else { return nil }
        let s = load(project)
        guard let last = s.entries.last, !Calendar.current.isDateInToday(last.date) else { return nil }
        let when = Calendar.current.isDateInYesterday(last.date) ? "Yesterday" : "Last time"
        var line = "\(when) you were working on “\(last.ask.prefix(60))”."
        if let ok = s.testsPassed { line += ok ? " Tests were green ✅" : " Tests were still failing ❌" }
        return line
    }
}

// MARK: Daily brief

enum DailyBrief {
    /// Calendar, reminders, GitHub, tests and battery in a few friendly lines. Built on your Mac, not sent anywhere.
    @MainActor
    static func compose(project: URL?, testsPassed: Bool?, prs: [PRWatcher.PR]) async -> String {
        let h = Calendar.current.component(.hour, from: Date())
        var lines = [h < 12 ? "Good morning! ☀️ Here's your day:" : (h < 18 ? "Good afternoon! Here's where things are:" : "Good evening! Here's your day so far:")]
        let store = EKEventStore()
        let cal = Calendar.current
        let now = Date()
        let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now

        if (try? await store.requestFullAccessToEvents()) == true {
            let events = store.events(matching: store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil))
                .filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
            if events.isEmpty { lines.append("📅 No more meetings today.") }
            else {
                let next = events.prefix(3).map { "\($0.startDate.formatted(date: .omitted, time: .shortened)) \($0.title ?? "Event")" }
                lines.append("📅 \(events.count) meeting\(events.count == 1 ? "" : "s") left: " + next.joined(separator: ", "))
            }
        } else {
            lines.append("📅 Allow Calendar in 🦉 → Setup Check… to hear your meetings.")
        }

        if (try? await store.requestFullAccessToReminders()) == true {
            let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfDay, calendars: nil)
            let titles: [String] = await withCheckedContinuation { c in
                store.fetchReminders(matching: pred) { r in c.resume(returning: (r ?? []).compactMap { $0.title }) }
            }
            lines.append(titles.isEmpty ? "⏰ Nothing due today." : "⏰ Due: " + titles.prefix(4).joined(separator: ", ") + (titles.count > 4 ? " +\(titles.count - 4) more" : ""))
        }

        let gh = await Task.detached { () -> Int? in
            let r = GitHub.run(["api", "notifications", "--jq", "length"], in: URL(fileURLWithPath: NSHomeDirectory()))
            return r.code == 0 ? Int(r.out) : nil
        }.value
        if let gh { lines.append(gh == 0 ? "🐙 No unread GitHub notifications." : "🐙 \(gh) unread GitHub notification\(gh == 1 ? "" : "s").") }
        let red = prs.filter { $0.ciState == "failed" }
        if !red.isEmpty { lines.append("🔴 CI failing on " + red.map { "#\($0.number)" }.joined(separator: ", ")) }

        if let project {
            if let ok = testsPassed { lines.append(ok ? "✅ \(project.lastPathComponent) tests are passing." : "❌ \(project.lastPathComponent) tests are failing. Want me to fix them?") }
            if let m = ProjectMemory.morningLine(for: project) ?? ProjectMemory.load(project).entries.last.map({ "Last thing we did: “\($0.ask.prefix(60))”." }) {
                lines.append("🦉 " + m)
            }
        }
        if let mail = await Task.detached(operation: { mailSummary() }).value { lines.append(mail) }
        if let b = Battery.read(), b.onBattery { lines.append("🔋 Battery \(b.percent)%.") }
        return lines.joined(separator: "\n")
    }
}

extension DailyBrief {
    /// Unread mail from the Mail app (works with Gmail or any account added to Mail). Only when Mail is
    /// already open, so Kiri never launches it; macOS asks once whether Kiri may read Mail.
    nonisolated static func mailSummary() -> String? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty else { return nil }
        let script = """
        tell application "Mail"
            set n to unread count of inbox
            set out to (n as string)
            if n > 0 then
                set total to count of messages of inbox
                if total > 40 then set total to 40
                set msgs to (messages 1 thru total of inbox)
                set k to 0
                repeat with m in msgs
                    if read status of m is false then
                        set k to k + 1
                        set out to out & linefeed & (extract name from sender of m) & " — " & subject of m
                        if k ≥ 3 then exit repeat
                    end if
                end repeat
            end if
            return out
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        let lines = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let n = Int(lines.first ?? "") else { return nil }
        if n == 0 { return "📧 Inbox zero! No unread mail." }
        let top = lines.dropFirst().map { "   • " + $0.prefix(70) }.joined(separator: "\n")
        return "📧 \(n) unread email\(n == 1 ? "" : "s")" + (top.isEmpty ? "." : ", latest:\n" + top)
    }
}

// MARK: Focus coach

/// Counts minutes of active coding (a code editor or terminal in front and you're typing/clicking).
/// After 90 minutes it suggests a short break. Turn off in 🦉 → Break Reminders.
@MainActor
final class FocusCoach {
    private(set) var minutes = 0
    static let breakAfter = 90
    static let codingApps: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.Terminal",
        "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.sublimetext.4", "com.exafunction.windsurf",
        "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.google.android.studio", "com.github.atom",
        "com.anthropic.claudefordesktop", "com.openai.codex",
    ]
    static var enabled: Bool { UserDefaults.standard.object(forKey: "breakReminders") as? Bool ?? true }

    /// Call once a minute. Returns true when it's time to suggest a break.
    func minuteTick() -> Bool {
        guard Self.enabled else { minutes = 0; return false }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > 300 { minutes = 0; return false }          // you already took a break
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard idle < 120, Self.codingApps.contains(front) || front.hasPrefix("com.jetbrains.") else { return false }
        minutes += 1
        if minutes >= Self.breakAfter { minutes = 0; return true }
        return false
    }
}
