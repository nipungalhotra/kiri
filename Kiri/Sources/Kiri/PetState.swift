import AppKit
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, kiri, note }
    let id = UUID()
    let role: Role
    let text: String
}

/// Everything Kiri knows and feels. All UI reads from here.
@MainActor
final class PetState: ObservableObject {
    @Published var mood: Mood = .idle
    @Published var bubble: String?
    @Published var offerFix = false
    @Published var chatOpen = false { didSet { if chatOpen != oldValue { onChatToggle?(chatOpen) } } }
    @Published var messages: [ChatMessage] = []
    @Published var activity: String?
    @Published var busy = false
    @Published var testing = false
    @Published var streak = 0
    @Published var projectURL: URL? {
        didSet {
            UserDefaults.standard.set(projectURL?.path, forKey: "projectPath")
            refreshTestPlan()
        }
    }
    /// Read Claude's replies and test results out loud.
    @Published var speakReplies: Bool {
        didSet {
            UserDefaults.standard.set(speakReplies, forKey: "speakReplies")
            if !speakReplies { Voice.shared.stop() }
        }
    }

    @Published var allowEdits: Bool {
        didSet { UserDefaults.standard.set(allowEdits, forKey: "allowEdits") }
    }

    @Published var style: CharacterStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "character") }
    }

    /// Mouse is over the notch island (notch mode only).
    @Published var notchHover = false

    var onChatToggle: ((Bool) -> Void)?

    func useStyle(_ s: CharacterStyle) {
        style = s
        say("Hi! I'm \(s.title) now ✨", for: 3)
        feel(.happy, for: 2)
    }

    private let claude = ClaudeRunner()
    private var sessionID: String?
    private var lastTestOutput = ""
    private var lastTestPlan: TestRunner.Plan?
    private var bubbleToken = 0
    private var moodToken = 0
    private var saidGoodnight = false
    private var clock: Timer?

    var leaves: Int { min(1 + streak, 3) }
    /// The project's test command. Found in the background: reading a folder can trigger a macOS
    /// privacy prompt (e.g. for Downloads), and doing that on the main thread froze Kiri.
    @Published private(set) var testPlan: TestRunner.Plan?

    func refreshTestPlan(then done: ((TestRunner.Plan?) -> Void)? = nil) {
        guard let dir = projectURL else { testPlan = nil; done?(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = TestRunner.detect(in: dir)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.projectURL == dir else { return }
                self.testPlan = plan
                done?(plan)
            }
        }
    }

    private var isLate: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 23 || h < 5
    }

    init() {
        allowEdits = UserDefaults.standard.bool(forKey: "allowEdits")
        speakReplies = UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true
        style = CharacterStyle(rawValue: UserDefaults.standard.string(forKey: "character") ?? "") ?? .owl
        if let path = UserDefaults.standard.string(forKey: "projectPath"),
           FileManager.default.fileExists(atPath: path) {
            projectURL = URL(fileURLWithPath: path)
        }
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refreshTestPlan()
    }

    // MARK: Feelings & speech

    func greet() {
        Log.write("Kiri launched, style=\(style.rawValue)")
        settle()
        if isLate {
            say("Hi, I'm \(style.title) …it's late, but I'm here for you 😴", for: 7)
        } else if let p = projectURL {
            say("Hi, I'm \(style.title) Ready to help with \(p.lastPathComponent)!", for: 7)
        } else {
            say("Hi, I'm \(style.title) Click me to start!", for: 8)
        }
    }

    /// Show a speech bubble. `seconds == nil` keeps it until replaced.
    func say(_ text: String, mood newMood: Mood? = nil, for seconds: Double? = 6) {
        if let newMood { mood = newMood }
        bubble = text
        bubbleToken += 1
        let token = bubbleToken
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.bubbleToken == token else { return }
                self.bubble = nil
            }
        }
    }

    /// Show a mood for a while, then go back to resting.
    func feel(_ m: Mood, for seconds: Double) {
        mood = m
        moodToken += 1
        let token = moodToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.moodToken == token, !self.busy, !self.testing, !self.offerFix else { return }
            self.settle()
        }
    }

    /// `--mood working` (etc.) pins a mood, for testing how heavy each mood is.
    static let pinnedMood: Mood? = CommandLine.arguments.firstIndex(of: "--mood").flatMap {
        $0 + 1 < CommandLine.arguments.count ? Mood(rawValue: CommandLine.arguments[$0 + 1]) : nil }

    func settle() {
        moodToken += 1
        if let pinned = Self.pinnedMood { mood = pinned; return }
        mood = isLate ? .sleepy : .idle
    }

    private func tick() {
        guard !busy, !testing, !offerFix, mood == .idle || mood == .sleepy else { return }
        settle()
        if isLate && !saidGoodnight {
            saidGoodnight = true
            say("It's getting late… don't forget to sleep 😴", for: 8)
        }
        if !isLate { saidGoodnight = false }
    }

    func petTapped() {
        Log.write("pet tapped (chatOpen was \(chatOpen))")
        if mood == .sleepy && !chatOpen {
            say("Huh?! Oh — I'm awake, I'm awake! 👀", mood: .happy, for: 3)
            feel(.happy, for: 2)
        }
        chatOpen.toggle()
    }

    // MARK: Project

    func chooseProject() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this project"
        panel.message = "Pick the project folder Kiri should help with"
        if let projectURL { panel.directoryURL = projectURL }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectURL = url
        newChat()
        note("Now working in \(url.lastPathComponent).")
        refreshTestPlan { [weak self] plan in
            if let plan { self?.note("I found \(plan.label) in this project.") }
        }
        say("Ooh, \(url.lastPathComponent)! Let's go 🌱", mood: .happy, for: 4)
        feel(.happy, for: 2)
    }

    func newChat() {
        claude.stop()
        sessionID = nil
        messages = []
        offerFix = false
    }

    private func note(_ text: String) { messages.append(ChatMessage(role: .note, text: text)) }

    // MARK: Tests

    func runTests() {
        Log.write("run tests pressed")
        guard !testing else { return }
        guard let dir = projectURL else {
            say("Pick a project folder first 📁", for: 4)
            chooseProject()
            return
        }
        testing = true
        refreshTestPlan { [weak self] plan in
            guard let self else { return }
            self.testing = false
            guard let plan else {
                self.say("I couldn't find any tests in \(dir.lastPathComponent) 🤔", mood: .sad, for: 5)
                self.feel(.sad, for: 3)
                return
            }
            self.startTests(plan, in: dir)
        }
    }

    private func startTests(_ plan: TestRunner.Plan, in dir: URL) {
        offerFix = false
        testing = true
        lastTestPlan = plan
        activity = "Running \(plan.label)…"
        mood = .working
        say("Running \(plan.label)… 🤞", for: nil)

        TestRunner.run(plan, in: dir) { [weak self] ok, output in
            guard let self else { return }
            Log.write("tests \(plan.label) passed=\(ok): \(TestRunner.summary(of: output))")
            self.testing = false
            self.activity = nil
            self.lastTestOutput = output
            let summary = TestRunner.summary(of: output)
            if ok {
                self.streak += 1
                let cheer = ["All tests passed! 🎉", "Green everywhere! 🌿✨", "Perfect run! You're on fire 🔥"]
                self.say(cheer[(self.streak - 1) % cheer.count] + (self.streak > 1 ? " (\(self.streak) in a row)" : ""), for: 6)
                self.feel(.happy, for: 5)
                self.note("✅ Tests passed — \(summary)")
                if self.speakReplies { Voice.shared.speak("All tests passed! Nice work.") }
            } else {
                self.streak = 0
                self.mood = .sad
                self.offerFix = true
                self.say("Tests failed 😢 Want me to fix it?", for: nil)
                self.note("❌ Tests failed — \(summary)")
                if self.speakReplies { Voice.shared.speak("Some tests failed. Want me to fix it?") }
            }
        }
    }

    func fixTests() {
        Log.write("fix it pressed")
        offerFix = false
        bubble = nil
        let tail = String(lastTestOutput.suffix(4000))
        let cmd = lastTestPlan?.label ?? "the tests"
        var prompt = "I ran \(cmd) and it failed. Here is the end of the output:\n\n```\n\(tail)\n```\n\nFind the cause and fix it."
        if !allowEdits { prompt += " (You can't edit files right now, so explain the fix and show the exact change.)" }
        chatOpen = true
        send(prompt, shownAs: "Please fix the failing tests 🙏")
    }

    func dismissFix() {
        offerFix = false
        bubble = nil
        say("Okay! Ping me when you want help 💚", for: 3)
        settle()
    }

    // MARK: Chat with Claude

    func send(_ prompt: String, shownAs display: String? = nil) {
        Voice.shared.stop()
        Log.write("send pressed busy=\(busy) project=\(projectURL?.path ?? "nil")")
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        guard let dir = projectURL else {
            note("Pick a project folder first so I know which code to look at 📁")
            chooseProject()
            return
        }
        messages.append(ChatMessage(role: .user, text: display ?? text))
        busy = true
        offerFix = false
        activity = "Thinking…"
        mood = .thinking
        if !chatOpen { say("Thinking… 💭", for: nil) }

        claude.send(prompt: text, cwd: dir, sessionID: sessionID, allowEdits: allowEdits) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() { claude.stop(); Voice.shared.stop() }

    private func handle(_ event: ClaudeEvent) {
        switch event {
        case .session(let id):
            sessionID = id
        case .text(let t):
            messages.append(ChatMessage(role: .kiri, text: t.trimmingCharacters(in: .whitespacesAndNewlines)))
            mood = .thinking
            activity = "Thinking…"
        case .retry(let n):
            activity = "Can't reach Claude, retrying (\(n))…"
        case .tool(let what):
            mood = .working
            activity = what
            if !chatOpen { say(what + "…", for: nil) }
        case .done(let result, let isError, let denied):
            busy = false
            activity = nil
            if isError {
                note("Something went wrong: \(result ?? "unknown error")")
                say("Oops, that didn't work 😣", mood: .sad, for: 5)
                feel(.sad, for: 4)
                return
            }
            if denied > 0 && !allowEdits {
                note("I wanted to change files or run commands, but I'm not allowed. Turn on “Can edit files” and ask again.")
            }
            if !chatOpen, let r = result {
                let short = r.count > 90 ? String(r.prefix(90)) + "… (click me)" : r
                say(short, for: 10)
            } else {
                bubble = nil
            }
            if speakReplies, let r = result { Voice.shared.speak(r) }
            feel(.happy, for: 2.5)
        case .failed(let why):
            busy = false
            activity = nil
            note(why)
            if !chatOpen { say(why, for: 6) }
            feel(.sad, for: 3)
        }
    }
}
