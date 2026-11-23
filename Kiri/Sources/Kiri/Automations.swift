import AppKit
import Foundation

/// Things Hoot does on a schedule, set up by just saying them:
///   "every day at 9am brief me" · "every weekday at 6pm run tests" · "every hour check my PRs"
///   "every 30 minutes run tests" · "list automations" · "stop automation 2" / "stop all automations"
struct Automation: Codable, Identifiable, Equatable {
    enum Repeat: Codable, Equatable { case daily(hour: Int, minute: Int, weekdaysOnly: Bool), every(minutes: Int) }
    var id = UUID()
    var command: String
    var repeatRule: Repeat
    var lastRun: Date?

    var label: String {
        switch repeatRule {
        case .daily(let h, let m, let wd):
            let time = String(format: "%d:%02d %@", h % 12 == 0 ? 12 : h % 12, m, h < 12 ? "am" : "pm")
            return "\(wd ? "Weekdays" : "Every day") at \(time): \(command)"
        case .every(let mins):
            return (mins % 60 == 0 ? "Every \(mins / 60 == 1 ? "hour" : "\(mins / 60) hours")" : "Every \(mins) minutes") + ": \(command)"
        }
    }

    /// Is it time to run (checked once a minute)?
    func isDue(at now: Date) -> Bool {
        let cal = Calendar.current
        switch repeatRule {
        case .daily(let h, let m, let wd):
            if wd, cal.isDateInWeekend(now) { return false }
            guard let target = cal.date(bySettingHour: h, minute: m, second: 0, of: now), now >= target,
                  now.timeIntervalSince(target) < 3600 else { return false }        // up to an hour late (e.g. Mac was asleep)
            return lastRun.map { !cal.isDate($0, inSameDayAs: now) || $0 < target } ?? true
        case .every(let mins):
            return lastRun.map { now.timeIntervalSince($0) >= Double(mins * 60) - 20 } ?? true
        }
    }
}

enum Automations {
    static var all: [Automation] {
        get { (UserDefaults.standard.data(forKey: "automations")).flatMap { try? JSONDecoder().decode([Automation].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "automations") }
    }

    enum Request: Equatable { case add(Automation), list, remove(Int), removeAll }

    /// Understands "every day at 9am brief me", "every weekday at 18:30 run tests", "every hour check my PRs".
    static func parse(_ text: String) -> Request? {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?").union(.whitespacesAndNewlines))
        if ["list automations", "show automations", "my automations", "what are my automations"].contains(t) { return .list }
        if ["stop all automations", "delete all automations", "remove all automations", "clear automations"].contains(t) { return .removeAll }
        if let m = t.range(of: #"^(?:stop|delete|remove) automation (\d+)$"#, options: .regularExpression) {
            return Int(t[m].split(separator: " ").last ?? "").map { .remove($0) }
        }
        let ns = t as NSString
        let full = NSRange(location: 0, length: ns.length)
        // every N minutes / every hour / every N hours
        if let re = try? NSRegularExpression(pattern: #"^every (?:(\d+) )?(minutes?|mins?|hours?)[ ,:]+(.{3,})$"#),
           let m = re.firstMatch(in: t, range: full) {
            let n = m.range(at: 1).location != NSNotFound ? Int(ns.substring(with: m.range(at: 1))) ?? 1 : 1
            let unit = ns.substring(with: m.range(at: 2))
            let mins = unit.hasPrefix("h") ? n * 60 : n
            guard mins >= 5 else { return nil }                        // not more often than every 5 minutes
            return .add(Automation(command: ns.substring(with: m.range(at: 3)), repeatRule: .every(minutes: mins)))
        }
        // every day / every weekday / every morning at 9(:30)(am|pm)
        if let re = try? NSRegularExpression(pattern: #"^every (day|weekday|morning|evening|night)(?: at (\d{1,2})(?:(?::|\.)(\d{2}))? ?(am|pm|a\.m\.|p\.m\.)?)?[ ,:]+(.{3,})$"#),
           let m = re.firstMatch(in: t, range: full) {
            let when = ns.substring(with: m.range(at: 1))
            var hour = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) ?? 9 : (when == "evening" ? 18 : (when == "night" ? 21 : 9))
            let minute = m.range(at: 3).location != NSNotFound ? Int(ns.substring(with: m.range(at: 3))) ?? 0 : 0
            if m.range(at: 4).location != NSNotFound {
                let pm = ns.substring(with: m.range(at: 4)).hasPrefix("p")
                if pm && hour < 12 { hour += 12 }
                if !pm && hour == 12 { hour = 0 }
            } else if (when == "evening" || when == "night") && hour < 12 { hour += 12 }
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return .add(Automation(command: ns.substring(with: m.range(at: 5)),
                                   repeatRule: .daily(hour: hour, minute: minute, weekdaysOnly: when == "weekday")))
        }
        return nil
    }
}

extension PetState {
    /// Handles "every day at …" style requests. Returns true if it was one.
    func handleAutomationRequest(_ text: String) -> Bool {
        guard let r = Automations.parse(text) else { return false }
        chatOpen = true
        messages.append(ChatMessage(role: .user, text: text))
        var list = Automations.all
        switch r {
        case .add(let a):
            list.append(a)
            Automations.all = list
            messages.append(ChatMessage(role: .kiri, text: "⏰ Got it! \(a.label)\nSay “list automations” to see them, or “stop automation \(list.count)” to remove it."))
            feel(.happy, for: 2)
        case .list:
            messages.append(ChatMessage(role: .kiri, text: list.isEmpty
                ? "No automations yet. Try “every day at 9am brief me” or “every hour check my PRs”."
                : "Your automations:\n" + list.enumerated().map { "\($0.offset + 1). \($0.element.label)" }.joined(separator: "\n")))
        case .remove(let n):
            guard (1...max(1, list.count)).contains(n), n <= list.count else { note("There's no automation \(n)."); return true }
            let gone = list.remove(at: n - 1)
            Automations.all = list
            note("🗑 Removed: \(gone.label)")
        case .removeAll:
            Automations.all = []
            note("🗑 Removed all automations.")
        }
        return true
    }

    /// Called once a minute: run anything that's due (when Kiri isn't busy).
    func runDueAutomations() {
        var list = Automations.all
        guard !list.isEmpty else { return }
        let now = Date()
        for i in list.indices where list[i].isDue(at: now) {
            guard !busy, !testing else { return }        // try again next minute
            list[i].lastRun = now
            Automations.all = list
            let cmd = list[i].command
            Log.write("automation run: \(Log.secret(cmd))")
            note("⏰ Automation: \(cmd)")
            runAutomationCommand(cmd)
            return                                         // one at a time
        }
    }

    private func runAutomationCommand(_ cmd: String) {
        let t = cmd.lowercased()
        if t.contains("run tests") || t.contains("run the tests") || t == "test" || t == "tests" { runTests(silent: false); return }
        if t.contains("check my pr") || t.contains("check prs") || t.contains("check pull requests") { checkPRsNow(); return }
        send(cmd)                                          // built-ins ("brief me", custom commands) or Claude
    }
}
