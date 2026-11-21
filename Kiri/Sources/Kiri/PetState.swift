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
            updateWatcher()
            lastTestsPassed = nil
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

    /// Re-run tests automatically whenever a file in the project is saved.
    @Published var watchTests: Bool {
        didSet { UserDefaults.standard.set(watchTests, forKey: "watchTests"); updateWatcher() }
    }
    /// What "Fix it" will ask Claude (tests, a failed terminal command, ...).
    private var fixRequest: (prompt: String, display: String, cwd: URL?)?
    private var folderWatcher: FolderWatcher?
    private var terminalWatcher: TerminalWatcher?
    private var lastTestsPassed: Bool?
    /// Tool calls in the current Claude run, and the ones Claude Code refused.
    private var toolCalls: [String: (name: String, detail: String)] = [:]
    private var deniedCalls: [(name: String, detail: String)] = []
    private var pendingActions: [MacAction] = []

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

    /// Kiri's app ID changed from local.kiri.pet to app.kiri.hoot (a clean slate for macOS permissions).
    /// Carry the old settings over once.
    private static func migrateOldSettings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromLocalKiriPet"), let old = UserDefaults(suiteName: "local.kiri.pet") else { return }
        for key in ["projectPath", "allowEdits", "speakReplies", "character", "watchTests", "displayMode"] {
            if d.object(forKey: key) == nil, let v = old.object(forKey: key) { d.set(v, forKey: key) }
        }
        d.set(true, forKey: "migratedFromLocalKiriPet")
    }

    init() {
        Self.migrateOldSettings()
        allowEdits = UserDefaults.standard.bool(forKey: "allowEdits")
        speakReplies = UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true
        style = CharacterStyle(rawValue: UserDefaults.standard.string(forKey: "character") ?? "") ?? .owl
        watchTests = UserDefaults.standard.bool(forKey: "watchTests")
        if let path = UserDefaults.standard.string(forKey: "projectPath"),
           FileManager.default.fileExists(atPath: path) {
            projectURL = URL(fileURLWithPath: path)
        }
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refreshTestPlan()
        DispatchQueue.main.async { [weak self] in self?.checkBattery() }
        updateWatcher()
        terminalWatcher = TerminalWatcher { [weak self] failure in self?.terminalFailed(failure) }
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
        // worried about a low battery beats being sleepy
        mood = PetSignals.shared.batteryLow ? .sad : (isLate ? .sleepy : .idle)
    }

    private var warnedBattery = false

    /// Low battery (unplugged, at or below 20%) makes the owl worried until you plug in.
    func checkBattery() {
        guard let b = Battery.read() else { return }
        let signals = PetSignals.shared
        signals.batteryPercent = b.percent
        let low = b.onBattery && b.percent <= 20
        guard low != signals.batteryLow else { return }
        signals.batteryLow = low
        Log.write("battery \(b.percent)% onBattery=\(b.onBattery) low=\(low)")
        guard !busy, !testing, !offerFix else { return }
        if low {
            say("Battery at \(b.percent)% 🔋 please plug in!", mood: .sad, for: 8)
            if speakReplies && !warnedBattery { Voice.shared.speak("Your battery is at \(b.percent) percent. Please plug in!") }
            warnedBattery = true
        } else {
            warnedBattery = false
            say("Thanks for plugging in! ⚡", for: 4)
            feel(.happy, for: 2)
        }
    }

    private func tick() {
        checkBattery()
        guard !busy, !testing, !offerFix, mood == .idle || mood == .sleepy || (mood == .sad && PetSignals.shared.batteryLow) else { return }
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

    func runTests(silent: Bool = false) {
        Log.write(silent ? "tests triggered by a file save" : "run tests pressed")
        guard !testing else { return }
        guard let dir = projectURL else {
            if !silent { say("Pick a project folder first 📁", for: 4); chooseProject() }
            return
        }
        testing = true
        refreshTestPlan { [weak self] plan in
            guard let self else { return }
            self.testing = false
            guard let plan else {
                if !silent {
                    self.say("I couldn't find any tests in \(dir.lastPathComponent) 🤔", mood: .sad, for: 5)
                    self.feel(.sad, for: 3)
                }
                return
            }
            self.startTests(plan, in: dir, silent: silent)
        }
    }

    private func startTests(_ plan: TestRunner.Plan, in dir: URL, silent: Bool) {
        offerFix = false
        testing = true
        lastTestPlan = plan
        activity = "Running \(plan.label)…"
        mood = .working
        if !silent { say("Running \(plan.label)… 🤞", for: nil) }

        TestRunner.run(plan, in: dir, progress: { [weak self] p in
            guard let self, self.testing else { return }
            let line = "Running tests… \(p.passed) passed" + (p.failed > 0 ? " · \(p.failed) failed" : "")
            self.activity = line
            if !silent && !self.chatOpen { self.say(line, for: nil) }
        }) { [weak self] ok, output in
            guard let self else { return }
            Log.write("tests \(plan.label) passed=\(ok): \(TestRunner.summary(of: output))")
            self.testing = false
            self.activity = nil
            self.lastTestOutput = output
            let summary = TestRunner.summary(of: output)
            let changed = self.lastTestsPassed != ok
            self.lastTestsPassed = ok
            if ok {
                self.streak += 1
                if silent && !changed { self.bubble = nil; self.settle(); return }   // still green: stay quiet
                let cheer = ["All tests passed! 🎉", "Green everywhere! 🌿✨", "Perfect run! You're on fire 🔥"]
                self.say(cheer[(self.streak - 1) % cheer.count] + (self.streak > 1 ? " (\(self.streak) in a row)" : ""), for: 6)
                self.feel(.happy, for: 5)
                self.note("✅ Tests passed — \(summary)")
                if self.speakReplies { Voice.shared.speak("All tests passed! Nice work.") }
            } else {
                self.streak = 0
                if silent && !changed && !self.offerFix { self.mood = .sad; self.bubble = nil; return }  // still red: no repeat nag
                self.mood = .sad
                self.fixRequest = nil
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
        chatOpen = true
        if let req = fixRequest {
            fixRequest = nil
            send(req.prompt, shownAs: req.display, cwd: req.cwd)
            return
        }
        let tail = String(lastTestOutput.suffix(4000))
        let cmd = lastTestPlan?.label ?? "the tests"
        var prompt = "I ran \(cmd) and it failed. Here is the end of the output:\n\n```\n\(tail)\n```\n\nFind the cause and fix it."
        if !allowEdits { prompt += " (You can't edit files right now, so explain the fix and show the exact change.)" }
        send(prompt, shownAs: "Please fix the failing tests 🙏")
    }

    func dismissFix() {
        offerFix = false
        fixRequest = nil
        bubble = nil
        say("Okay! Ping me when you want help 💚", for: 3)
        settle()
    }

    // MARK: Background watching

    private func updateWatcher() {
        folderWatcher = nil
        guard watchTests, let dir = projectURL else { return }
        folderWatcher = FolderWatcher(folder: dir) { [weak self] in
            guard let self, !self.busy, !self.testing else { return }
            self.runTests(silent: true)
        }
        Log.write("watching \(dir.lastPathComponent) for saves")
    }

    private func terminalFailed(_ f: TerminalWatcher.Failure) {
        Log.write("terminal command failed (\(f.code)): \(f.command.prefix(120)) in \(f.dir)")
        guard !busy, !offerFix else { return }
        let dir = URL(fileURLWithPath: f.dir)
        fixRequest = (
            prompt: "In my terminal, the command `\(f.command)` failed with exit code \(f.code) in \(f.dir). "
                + "Figure out the likely cause (look at the files here if useful) and tell me how to fix it.",
            display: "Why did `\(f.command.prefix(60))` fail? 🤔",
            cwd: dir)
        offerFix = true
        mood = .sad
        say("`\(f.command.prefix(40))` failed (exit \(f.code)). Want me to look?", for: nil)
        if speakReplies { Voice.shared.speak("Your command failed. Want me to take a look?") }
    }

    /// Adds the small zsh hook that reports failed commands (only when the user clicks to do so).
    func setUpTerminalWatching() {
        if TerminalWatcher.isInstalled {
            say("Terminal watching is already on 👀", for: 4)
            return
        }
        guard Approval.ask("Watch your terminal for errors?",
                           "Kiri will add one line to ~/.zshrc that loads a tiny hook. When a command fails, the hook tells Kiri only the exit code, folder and command, so the owl can offer help.\n\nOpen a new terminal window afterwards.",
                           allow: "Add hook") else { return }
        do {
            try TerminalWatcher.install()
            note("Terminal watching is on. Open a new terminal window to start it.")
            say("I'm watching your terminal now 👀", for: 4)
        } catch {
            note("Couldn't add the terminal hook: \(error.localizedDescription)")
        }
    }

    // MARK: Chat with Claude

    /// A folder for chats when no project is chosen (Mac tasks, screen questions...).
    private static let workspace: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kiri/workspace")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func send(_ prompt: String, shownAs display: String? = nil, cwd: URL? = nil,
              extraAllowedTools: [String] = [], forceEdits: Bool = false, includeScreen: Bool? = nil) {
        Voice.shared.stop()
        Log.write("send pressed busy=\(busy) project=\(projectURL?.path ?? "nil")")
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        let dir = cwd ?? projectURL ?? Self.workspace
        let wantsScreen = includeScreen ?? ScreenHelp.wantsScreen(text)

        messages.append(ChatMessage(role: .user, text: (display ?? text) + (wantsScreen ? "  📸" : "")))
        busy = true
        offerFix = false
        toolCalls = [:]
        deniedCalls = []
        pendingActions = []
        activity = wantsScreen ? "Looking at your screen…" : "Thinking…"
        mood = .thinking
        if !chatOpen { say(wantsScreen ? "Looking at your screen… 👀" : "Thinking… 💭", for: nil) }

        guard wantsScreen else {
            startClaude(text, dir: dir, extraAllowedTools: extraAllowedTools, forceEdits: forceEdits, addDirs: [])
            return
        }
        // Just try: the "do I have permission?" check can say no on recent macOS even when access is granted.
        Log.write("screen preflight=\(ScreenHelp.hasPermission)")
        Task { @MainActor in
            do {
                let shot = try await ScreenHelp.capture()
                Log.write("screenshot \(shot.lastPathComponent)")
                let withShot = "\(text)\n\n(Screenshot of my screen right now: \(shot.path). Read it to see what I see.)"
                startClaude(withShot, dir: dir, extraAllowedTools: extraAllowedTools + ["Read(\(ScreenHelp.folder.path)/**)"],
                            forceEdits: forceEdits, addDirs: [ScreenHelp.folder])
            } catch {
                Log.write("screenshot failed: \(error.localizedDescription)")
                busy = false
                activity = nil
                ScreenHelp.requestPermission()
                note("To see your screen I need Screen Recording permission: System Settings → Privacy & Security → Screen & System Audio Recording → turn on Kiri, then quit and reopen Kiri and ask again.")
                say("I need permission to see your screen 🙈", mood: .sad, for: 6)
            }
        }
    }

    /// Ask about whatever is on screen right now.
    func askAboutScreen() {
        chatOpen = true
        send("What's on my screen? Explain it briefly and point out anything that looks wrong or needs my attention.",
             shownAs: "What's on my screen?", includeScreen: true)
    }

    private func startClaude(_ text: String, dir: URL, extraAllowedTools: [String], forceEdits: Bool, addDirs: [URL]) {
        claude.send(prompt: text, cwd: dir, sessionID: sessionID, allowEdits: allowEdits,
                    extraAllowedTools: extraAllowedTools, forceEdits: forceEdits, addDirs: addDirs) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() { claude.stop(); Voice.shared.stop() }

    private func handle(_ event: ClaudeEvent) {
        switch event {
        case .session(let id):
            sessionID = id
        case .text(let t):
            let (actions, cleaned) = MacAction.extract(from: t)
            pendingActions += actions
            if !cleaned.isEmpty { messages.append(ChatMessage(role: .kiri, text: cleaned)) }
            mood = .thinking
            activity = "Thinking…"
        case .retry(let n):
            activity = "Can't reach Claude, retrying (\(n))…"
        case .tool(let what):
            mood = .working
            activity = what
            if !chatOpen { say(what + "…", for: nil) }
        case .toolCall(let id, let name, let detail):
            toolCalls[id] = (name, detail)
        case .denied(let id, let tool):
            let call = toolCalls[id] ?? (tool, "")
            if !deniedCalls.contains(where: { $0.name == call.name && $0.detail == call.detail }) { deniedCalls.append(call) }
        case .done(let result, let isError, _):
            busy = false
            activity = nil
            if isError {
                note("Something went wrong: \(result ?? "unknown error")")
                say("Oops, that didn't work 😣", mood: .sad, for: 5)
                feel(.sad, for: 4)
                return
            }
            let spoken = result.map { MacAction.extract(from: $0).cleaned }
            if !chatOpen, let r = spoken, !r.isEmpty {
                let short = r.count > 90 ? String(r.prefix(90)) + "… (click me)" : r
                say(short, for: 10)
            } else {
                bubble = nil
            }
            if speakReplies, let r = spoken, !r.isEmpty { Voice.shared.speak(r) }
            feel(.happy, for: 2.5)
            let actions = pendingActions
            let denied = deniedCalls
            pendingActions = []
            deniedCalls = []
            Task { @MainActor in
                await self.runActions(actions)
                self.askToContinue(after: denied)
            }
        case .failed(let why):
            busy = false
            activity = nil
            note(why)
            if !chatOpen { say(why, for: 6) }
            feel(.sad, for: 3)
        }
    }

    // MARK: Mac actions & approvals

    private func runActions(_ actions: [MacAction]) async {
        for a in actions {
            mood = .working
            let result = await MacActions.run(a)
            Log.write("action \(a.kind) -> \(result)")
            note("🦉 \(result)")
            say(result, for: 5)
            if speakReplies { Voice.shared.speak(result) }
        }
        if !actions.isEmpty { feel(.happy, for: 2) }
    }

    /// Claude Code refused some tool calls: show exactly what Claude wanted and let the user allow it once.
    private func askToContinue(after denied: [(name: String, detail: String)]) {
        guard !denied.isEmpty else { return }
        let risky = ["rm ", "rm\t", "sudo", "git push", "--force", "curl ", "| sh", "|sh", "chmod", "mv ", "> /", "kill"]
        let lines = denied.map { call -> String in
            let warn = risky.contains { call.detail.contains($0) } ? "⚠️ " : ""
            switch call.name {
            case "Edit", "MultiEdit", "Write", "NotebookEdit":
                return "\(warn)• change file \((call.detail as NSString).lastPathComponent)"
            case "Bash": return "\(warn)• run: \(call.detail.prefix(120))"
            default: return "\(warn)• use \(call.name) \(call.detail.prefix(80))"
            }
        }.joined(separator: "\n")
        let hasRisk = lines.contains("⚠️")
        guard Approval.ask(hasRisk ? "⚠️ Claude wants to do something risky" : "Allow Claude to continue?",
                           "Claude wanted to:\n\n\(lines)\n\nAllow this once?",
                           allow: "Allow once") else {
            note("Okay, I didn't allow that.")
            return
        }
        var tools: [String] = []
        var edits = false
        for call in denied {
            switch call.name {
            case "Edit", "MultiEdit", "Write", "NotebookEdit": edits = true
            case "Bash": if !call.detail.isEmpty { tools.append("Bash(\(call.detail))") }
            default: tools.append(call.name)
            }
        }
        send("I approved what you asked for (\(denied.count) action\(denied.count == 1 ? "" : "s")). Please continue.",
             shownAs: "✅ Allowed once, continue", extraAllowedTools: tools, forceEdits: edits)
    }
}
