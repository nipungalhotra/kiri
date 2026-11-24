import AppKit
import EventKit

// MARK: About you

/// Your name and the things you've asked Hoot to remember ("remember that I like short answers").
/// Kept only on this Mac (~/Library/Application Support/Kiri/profile.json, readable only by you) and
/// given to Claude at the start of each chat so Hoot answers the way you like.
enum UserProfile {
    struct Store: Codable { var name: String?; var facts: [String] = [] }

    static let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kiri")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile.json")
    }()

    static var store: Store {
        get { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store() }
        set {
            guard let d = try? JSONEncoder().encode(newValue) else { return }
            try? d.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// What Hoot calls you: the name you gave, else the first name of this Mac's account.
    static var name: String {
        if let n = store.name, !n.isEmpty { return n }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    static func remember(_ fact: String) {
        var s = store
        let f = fact.trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        guard !f.isEmpty, !s.facts.contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) else { return }
        s.facts.append(String(f.prefix(200)))
        if s.facts.count > 40 { s.facts.removeFirst(s.facts.count - 40) }
        store = s
    }

    /// Removes facts that mention all the given words. Returns what was removed.
    static func forget(_ about: String) -> [String] {
        let words = about.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        guard !words.isEmpty else { return [] }
        var s = store
        let gone = s.facts.filter { f in words.allSatisfy { f.lowercased().contains($0) } }
        s.facts.removeAll { gone.contains($0) }
        store = s
        return gone
    }

    /// The lines added to Claude's instructions.
    static var prompt: String {
        var out = ""
        if !name.isEmpty { out += " The user's name is \(name)." }
        let facts = store.facts
        if !facts.isEmpty { out += " Things the user asked you to remember about them: " + facts.map { "“\($0)”" }.joined(separator: "; ") + "." }
        return out
    }

    enum Request: Equatable { case callMe(String), remember(String), list, forget(String), forgetAll }

    static func parse(_ text: String) -> Request? {
        let t = QuickCommand.normalize(text)
        func rest(after prefixes: [String]) -> String? {
            for p in prefixes where t.hasPrefix(p) {
                let r = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                return r.count >= 2 ? r : nil
            }
            return nil
        }
        if let n = rest(after: ["call me ", "my name is ", "my name's "]), n.split(separator: " ").count <= 3 {
            // keep the user's own capitalisation
            let original = text.trimmingCharacters(in: CharacterSet(charactersIn: " .!").union(.whitespacesAndNewlines))
            let cap = original.split(separator: " ").suffix(n.split(separator: " ").count).joined(separator: " ")
            return .callMe(cap.prefix(1).uppercased() + cap.dropFirst())
        }
        if ["what do you remember about me", "what do you know about me", "what have you remembered", "what do you remember"].contains(t) { return .list }
        if ["forget everything about me", "forget everything you know about me", "forget all about me", "forget everything"].contains(t) { return .forgetAll }
        if let r = rest(after: ["forget that ", "forget about ", "don't remember that "]) { return .forget(r) }
        if t.hasPrefix("remember to ") { return nil }                 // a reminder: Claude/Reminders handle that
        if let r = rest(after: ["remember that ", "remember i ", "remember my ", "please remember ", "note that i ", "remember this: "]) {
            let lead = t.hasPrefix("remember i ") ? "I " : (t.hasPrefix("remember my ") ? "My " : "")
            let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(original.suffix(r.count))               // keep the user's own capitalisation
            return .remember(lead + (lead.isEmpty ? tail.prefix(1).uppercased() + tail.dropFirst() : tail))
        }
        return nil
    }
}

// MARK: Meetings

/// Notices meetings starting in about 5 minutes and remembers their video link ("join the meeting").
@MainActor
enum MeetingWatcher {
    private static var announced = Set<String>()
    /// The video link of the meeting Hoot last told you about.
    static var lastLink: URL?
    private static let store = EKEventStore()

    static var allowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    private static func todaysEvents() -> [EKEvent] {
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600), end: now.addingTimeInterval(3600), calendars: nil)
        return store.events(matching: pred).filter { !$0.isAllDay && $0.status != .canceled }
    }

    /// A meeting starting in the next ~5 minutes that hasn't been announced yet.
    static func upcoming() -> EKEvent? {
        guard allowed else { return nil }
        let now = Date()
        for e in todaysEvents() {
            let mins = e.startDate.timeIntervalSince(now) / 60
            guard mins > 0.5, mins <= 5.5, let id = e.eventIdentifier, !announced.contains(id) else { continue }
            announced.insert(id)
            return e
        }
        return nil
    }

    /// Are you in a meeting right now? (Hoot then only shows, never speaks, its heads-ups.)
    static var inMeeting: Bool {
        guard allowed else { return false }
        let now = Date()
        return todaysEvents().contains { $0.startDate <= now && $0.endDate > now && ($0.attendees?.count ?? 0) > 0 }
    }

    /// The link of a meeting happening now or starting within 15 minutes.
    static func currentLink() -> URL? {
        guard allowed else { return nil }
        let now = Date()
        return todaysEvents().filter { $0.startDate < now.addingTimeInterval(900) && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }.lazy.compactMap { link(for: $0) }.first
    }

    /// Zoom / Meet / Teams / Webex link in the event, if any.
    static func link(for e: EKEvent) -> URL? {
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://[\w.-]*(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|around\.co)/[^\s<>"')]+"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[r]))
    }
}

// MARK: Heads-ups

extension PetState {
    static var spokenHeadsUps: Bool { UserDefaults.standard.object(forKey: "spokenHeadsUps") as? Bool ?? true }

    /// Tell you about something that just happened: a bubble always, and out loud unless you're in
    /// quiet mode, in a meeting, or turned spoken heads-ups off. With `offersFix`, Hoot then listens
    /// a few seconds for "yes" / "fix it".
    func headsUp(_ spoken: String, offersFix: Bool = false) {
        guard speakReplies, !quiet, Self.spokenHeadsUps, !MeetingWatcher.inMeeting, !VoiceInput.shared.listening else { return }
        let line = Self.withName(spoken)
        if Voice.shared.isSpeaking { Voice.shared.enqueue(line) } else { Voice.shared.speak(line) }
        if offersFix { awaitYes() }
    }

    /// "Nipun, CI failed…" now and then, so it feels personal without being repetitive.
    static func withName(_ text: String, chance: Int = 3) -> String {
        let n = UserProfile.name
        guard !n.isEmpty, Int.random(in: 0..<chance) == 0 else { return text }
        return n + ", " + text.prefix(1).lowercased() + text.dropFirst()
    }

    /// After "Want me to fix it?": listen briefly; "yes" / "fix it" / "go ahead" starts the fix.
    private func awaitYes() {
        let started = Date()
        func check() {
            guard offerFix, !busy else { return }
            if Voice.shared.isSpeaking {
                if Date().timeIntervalSince(started) < 30 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() } }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.offerFix, !self.busy, !VoiceInput.shared.listening else { return }
                self.listenForYes()
            }
        }
        check()
    }

    private func listenForYes() {
        let mic = VoiceInput.shared
        mic.onFinished = { [weak self] words in
            guard let self else { return }
            self.activity = nil
            let t = QuickCommand.normalize(words)
            if Self.isYes(t) { self.fixTests() }
            else if !t.isEmpty, !Self.isNo(t) { self.sendSpoken(words) }
            else { self.settle() }
        }
        Task { @MainActor in
            guard (try? await mic.start()) != nil else { return }
            self.activity = "Listening… say “yes” to fix it"
        }
    }

    nonisolated static func isYes(_ t: String) -> Bool {
        ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "please", "yes please", "fix it", "go ahead", "do it", "yes fix it",
         "sure fix it", "please fix it", "help me", "take a look", "yes take a look", "look at it", "go for it"].contains(t)
    }
    nonisolated static func isNo(_ t: String) -> Bool {
        ["no", "nope", "not now", "later", "no thanks", "leave it", "never mind", "nah", "skip it"].contains(t)
    }

    /// Called once a minute: meeting heads-up.
    func checkMeetings() {
        guard let e = MeetingWatcher.upcoming() else { return }
        let title = e.title ?? "Your meeting"
        let mins = max(1, Int((e.startDate.timeIntervalSinceNow / 60).rounded()))
        MeetingWatcher.lastLink = MeetingWatcher.link(for: e)
        let join = MeetingWatcher.lastLink != nil
        Log.write("meeting heads-up (\(mins) min, link=\(join))")
        say("📅 “\(title.prefix(40))” starts in \(mins) min" + (join ? ". Say “join the meeting” 🎥" : ""), for: 20)
        note("📅 “\(title)” starts at \(e.startDate.formatted(date: .omitted, time: .shortened))")
        PetSignals.shared.surprise(for: 0.6)
        if speakReplies, !quiet, Self.spokenHeadsUps {
            let line = Self.withName("Your meeting \(title.prefix(60)) starts in \(mins) minute\(mins == 1 ? "" : "s").", chance: 1)
                + (join ? " Say join the meeting when you're ready." : "")
            if Voice.shared.isSpeaking { Voice.shared.enqueue(line) } else { Voice.shared.speak(line) }
        }
    }

    /// "call me …", "remember that …", "what do you remember about me", "forget that …".
    func handleProfileRequest(_ text: String) -> Bool {
        guard let r = UserProfile.parse(text) else { return false }
        messages.append(ChatMessage(role: .user, text: text))
        let reply: String
        switch r {
        case .callMe(let n):
            var s = UserProfile.store
            s.name = n
            UserProfile.store = s
            reply = "Got it, \(n). 🦉"
        case .remember(let f):
            UserProfile.remember(f)
            reply = "Noted 📝 I'll remember that."
        case .list:
            let facts = UserProfile.store.facts
            reply = "I call you \(UserProfile.name.isEmpty ? "friend" : UserProfile.name)." + (facts.isEmpty
                ? " You haven't asked me to remember anything yet. Try “remember that I like short answers”."
                : "\nYou asked me to remember:\n" + facts.map { "• \($0)" }.joined(separator: "\n"))
        case .forget(let about):
            let gone = UserProfile.forget(about)
            reply = gone.isEmpty ? "I didn't have anything about that." : "Forgotten 🧹 " + gone.map { "“\($0)”" }.joined(separator: ", ")
        case .forgetAll:
            var s = UserProfile.store
            s.facts = []
            UserProfile.store = s
            reply = "Done, I've forgotten everything you told me about you 🧹"
        }
        messages.append(ChatMessage(role: .kiri, text: reply))
        if !chatOpen { say(reply, for: 5) }
        feel(.happy, for: 2)
        if speakReplies && !quiet { Voice.shared.speak(reply) }
        if inConversation { continueConversation() }
        return true
    }
}
